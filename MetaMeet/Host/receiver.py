#!/usr/bin/env python3
"""Authenticated, idempotent MetaMeet receiver. Bind only to a Tailscale address."""
import argparse
import base64
import hashlib
import hmac
import io
import json
import math
import os
from pathlib import Path
import re
import ssl
import threading
import time
import uuid
import wave
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MAX_BODY = 12 * 1024 * 1024


def atomic_json(path, value):
    path = Path(path)
    tmp = path.with_name(path.name + '.tmp')
    with open(tmp, 'w', encoding='utf-8') as f:
        json.dump(value, f, ensure_ascii=False, allow_nan=False)
        f.flush(); os.fsync(f.fileno())
    os.replace(tmp, path)
    fd = os.open(path.parent, os.O_DIRECTORY)
    try: os.fsync(fd)
    finally: os.close(fd)


def finite(value, low, high):
    return type(value) in (int, float) and math.isfinite(value) and low <= value <= high


def validate(payload):
    if payload.get('version') != 1 or not finite(payload.get('revision'), 0, 1e12):
        raise ValueError('invalid version or revision')
    m = payload['meeting']
    if str(uuid.UUID(m['id'])).upper() != m['id']:
        raise ValueError('invalid meeting id')
    if not isinstance(m['title'], str) or len(m['title']) > 1000 or not isinstance(m['notes'], str) or len(m['notes']) > 100000:
        raise ValueError('invalid text')
    if not finite(m['created'], 0, 1e12) or (m.get('ended') is not None and not finite(m['ended'], m['created'], 1e12)):
        raise ValueError('invalid meeting time')
    if not isinstance(m['events'], list) or len(m['events']) > 20000 or any(not isinstance(x, str) or len(x) > 4000 for x in m['events']):
        raise ValueError('invalid events')
    if not isinstance(m['chunks'], list) or len(m['chunks']) > 50000:
        raise ValueError('too many chunks')
    chunks = {}; end = 0
    for c in m['chunks']:
        ident = c['id']
        if type(ident) is not int or not 0 <= ident <= 999999 or ident in chunks or c['filename'] != f'{ident:06d}.wav':
            raise ValueError('invalid chunk id or filename')
        if not finite(c['start'], 0, 7 * 86400) or not finite(c['duration'], 0.00001, 60) or c['start'] + 0.002 < end:
            raise ValueError('invalid or overlapping chunk time')
        end = c['start'] + c['duration']; chunks[ident] = c
    audio = payload['audio']
    if not isinstance(audio, list) or len(audio) > 60:
        raise ValueError('invalid batch size')
    decoded = {}; total = 0
    for a in audio:
        ident = a['id']
        if type(ident) is not int or ident not in chunks or ident in decoded:
            raise ValueError('unknown or duplicate audio')
        raw = base64.b64decode(a['audio'], validate=True)
        digest = hashlib.sha256(raw).hexdigest()
        if not hmac.compare_digest(digest, a['sha256']):
            raise ValueError('audio checksum mismatch')
        with wave.open(io.BytesIO(raw), 'rb') as w:
            if (w.getnchannels(), w.getsampwidth(), w.getframerate(), w.getcomptype()) != (1, 2, 16000, 'NONE'):
                raise ValueError('unsupported WAV')
            frames = w.getnframes(); pcm = w.readframes(frames)
            if len(pcm) != frames * 2 or abs(frames / 16000 - chunks[ident]['duration']) > 0.002:
                raise ValueError('truncated WAV or wrong duration')
        total += len(raw)
        if total > 4 * 1024 * 1024: raise ValueError('audio batch too large')
        decoded[ident] = (raw, digest, chunks[ident])
    return m, decoded


class Conflict(Exception): pass


class Store:
    def __init__(self, root):
        self.root = Path(root); self.root.mkdir(parents=True, exist_ok=True)
        self.lock = threading.Lock()

    def accept(self, body, digest):
        if not hmac.compare_digest(hashlib.sha256(body).hexdigest(), digest):
            raise ValueError('batch checksum mismatch')
        payload = json.loads(body); meeting, audio = validate(payload)
        with self.lock:
            folder = self.root / meeting['id']; folder.mkdir(exist_ok=True)
            state_path = folder / 'receipt.json'
            state = json.loads(state_path.read_text()) if state_path.exists() else {'revision': -1, 'received': {}}
            # Validate ALL conflicts before mutating any audio or manifest.
            for ident, (raw, sha, metadata) in audio.items():
                path = folder / metadata['filename']; known = state['received'].get(str(ident))
                if known and (known['sha256'] != sha or known['chunk'] != metadata):
                    raise Conflict('existing audio differs')
                if path.exists() and hashlib.sha256(path.read_bytes()).hexdigest() != sha:
                    raise Conflict('existing file differs')
            if payload['revision'] >= state['revision']:
                for c in meeting['chunks']:
                    known = state['received'].get(str(c['id']))
                    if known and known['chunk'] != c: raise Conflict('existing timing differs')
                previous = state.get('meeting', {})
                if previous.get('ended') is not None and meeting.get('ended') is None:
                    raise Conflict('cannot reopen finalized meeting')
                previous_ids = {c['id'] for c in previous.get('chunks', [])}
                if not previous_ids.issubset({c['id'] for c in meeting['chunks']}):
                    raise Conflict('manifest cannot remove original audio')
            for ident, (raw, sha, metadata) in audio.items():
                path = folder / metadata['filename']
                if not path.exists():
                    tmp = path.with_suffix('.part')
                    with open(tmp, 'wb') as f: f.write(raw); f.flush(); os.fsync(f.fileno())
                    os.replace(tmp, path)
                state['received'][str(ident)] = {'sha256': sha, 'chunk': metadata}
            if payload['revision'] >= state['revision']:
                state['revision'] = payload['revision']; state['meeting'] = meeting
            state['updated'] = time.time()
            atomic_json(state_path, state)
        return len(audio)


class Server(ThreadingHTTPServer):
    daemon_threads = True
    def __init__(self, address, store, token, key_file=None):
        self.store = store; self.token = token; self.key_file = key_file
        super().__init__(address, Handler)

    def get_request(self):
        connection, address = super().get_request()
        print(json.dumps({'event': 'connection', 'peer': address[0]}), flush=True)
        return connection, address

    def handle_error(self, request, client_address):
        # Never print request data or credentials in tracebacks.
        print(json.dumps({'event': 'connection_failed', 'peer': client_address[0]}), flush=True)


class Handler(BaseHTTPRequestHandler):
    def setup(self):
        self.request.settimeout(45)
        if isinstance(self.request, ssl.SSLSocket):
            try:
                self.request.do_handshake()
            except (ssl.SSLError, OSError) as error:
                print(json.dumps({'event': 'tls_failed', 'peer': self.client_address[0],
                                  'error_type': type(error).__name__,
                                  'reason': getattr(error, 'reason', None)}), flush=True)
                raise
        super().setup()
    def log_message(self, fmt, *args): pass  # No credentials, query strings or meeting titles in logs.
    def reply(self, code, obj, digest=None):
        route = ('health' if self.path == '/v1/health' else
                 'translation-key' if self.path == '/v1/translation-key' else
                 'batch' if self.path.startswith('/v1/batches/') else 'other')
        print(json.dumps({'event': 'response', 'peer': self.client_address[0],
                          'route': route, 'status': code}), flush=True)
        body = json.dumps(obj).encode()
        self.send_response(code); self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body))); self.send_header('Cache-Control', 'no-store')
        if digest: self.send_header('X-Content-SHA256', digest)
        self.end_headers(); self.wfile.write(body)
    def authorized(self):
        if not hmac.compare_digest(self.headers.get('Authorization', ''), 'Bearer ' + self.server.token):
            self.reply(401, {'error': 'unauthorized'}); return False
        return True
    def do_GET(self):
        if not self.authorized(): return
        if self.path == '/v1/health': self.reply(200, {'service': 'metameet', 'version': 1})
        else: self.reply(404, {'error': 'not found'})
    def do_PUT(self):
        if not self.authorized(): return
        if self.path == '/v1/translation-key':
            if not self.server.key_file:
                self.reply(403, {'error': 'translation not configured'}); return
            try:
                length = int(self.headers.get('Content-Length', '0'))
                if not 1 <= length <= 512: raise ValueError('length')
                key = self.rfile.read(length).decode('ascii').strip()
                # Provider keys are opaque: punctuation is valid, but HTTP controls are not.
                if not 20 <= len(key) <= 512 or any(not 33 <= ord(c) <= 126 for c in key):
                    raise ValueError('key')
                target = Path(self.server.key_file)
                with self.server.store.lock:
                    temp = target.with_suffix('.tmp')
                    fd = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
                    with os.fdopen(fd, 'w') as f: f.write(key); f.flush(); os.fsync(f.fileno())
                    os.replace(temp, target)
                self.reply(200, {'configured': True})
            except (ValueError, UnicodeError):
                raw_length = self.headers.get('Content-Length', '')
                length_hint = int(raw_length) if raw_length.isdecimal() and len(raw_length) < 8 else None
                print(json.dumps({'event': 'translation_key_rejected',
                                  'content_length': length_hint,
                                  'chunked': self.headers.get('Transfer-Encoding', '').lower() == 'chunked'}), flush=True)
                self.reply(400, {'error': 'invalid key'})
            except OSError: self.reply(503, {'error': 'storage unavailable'})
            return
        if not re.fullmatch(r'/v1/batches/[0-9a-f]{64}', self.path):
            self.reply(404, {'error': 'not found'}); return
        digest = self.path.rsplit('/', 1)[1]
        try:
            length = int(self.headers.get('Content-Length', '0'))
            if not 0 < length <= MAX_BODY or self.headers.get('Transfer-Encoding'):
                self.reply(413, {'error': 'invalid body length'}); return
            body = self.rfile.read(length)
            if len(body) != length: raise ValueError('incomplete body')
            count = self.server.store.accept(body, digest)
            self.reply(200, {'received': count}, digest)
        except Conflict:
            self.reply(409, {'error': 'conflict; originals preserved'})
        except (ValueError, KeyError, TypeError, AttributeError, wave.Error, EOFError):
            self.reply(400, {'error': 'invalid batch'})
        except OSError:
            self.reply(503, {'error': 'storage unavailable'})


def main():
    parser = argparse.ArgumentParser(); parser.add_argument('--config', required=True); args = parser.parse_args()
    config = json.loads(Path(args.config).read_text())
    import ipaddress
    if ipaddress.ip_address(config['bind']) not in ipaddress.ip_network('100.64.0.0/10'):
        raise SystemExit('Bind must be a Tailscale IPv4 address')
    if len(config['token']) < 32: raise SystemExit('Token too short')
    os.umask(0o077)
    server = Server((config['bind'], config.get('port', 8766)), Store(config['root']), config['token'], config.get('translation_key_file'))
    tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    tls.minimum_version = ssl.TLSVersion.TLSv1_2
    tls.load_cert_chain(config['certificate'], config['private_key'])
    server.socket = tls.wrap_socket(server.socket, server_side=True, do_handshake_on_connect=False)
    server.serve_forever()

if __name__ == '__main__': main()

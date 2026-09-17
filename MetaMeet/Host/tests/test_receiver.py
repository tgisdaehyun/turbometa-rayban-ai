import base64
import copy
import hashlib
import io
import json
from pathlib import Path
import sys
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
import uuid
import wave
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from receiver import Store, Server, Conflict


def fixture():
    out = io.BytesIO()
    with wave.open(out, 'wb') as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(16000); w.writeframes(b'\0\0' * 16000)
    raw = out.getvalue()
    return {'version': 1, 'revision': 1000, 'meeting': {
        'id': str(uuid.uuid4()).upper(), 'title': '회의', 'created': 800000000, 'ended': 800000003,
        'events': [], 'notes': '', 'chunks': [{'id': 0, 'filename': '000000.wav', 'start': 0, 'duration': 1}]},
        'audio': [{'id': 0, 'sha256': hashlib.sha256(raw).hexdigest(), 'audio': base64.b64encode(raw).decode()}]}


def encode(p):
    data = json.dumps(p).encode(); return data, hashlib.sha256(data).hexdigest()


class ReceiverTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.store = Store(self.tmp.name); self.payload = fixture()
    def tearDown(self): self.tmp.cleanup()
    def test_retry_after_lost_response_is_idempotent_even_after_restart(self):
        body, digest = encode(self.payload)
        self.assertEqual(self.store.accept(body, digest), 1)
        Store(self.tmp.name).accept(body, digest)
        folder = Path(self.tmp.name) / self.payload['meeting']['id']
        self.assertEqual(len(list(folder.glob('*.wav'))), 1)
        self.assertEqual(len(json.loads((folder / 'receipt.json').read_text())['received']), 1)
    def test_deleted_meeting_is_not_recreated_by_mobile_retry(self):
        (Path(self.tmp.name)/'.deleted-meetings.json').write_text(json.dumps([self.payload['meeting']['id']]))
        store = Store(self.tmp.name)
        self.assertEqual(store.accept(*encode(self.payload)), 0)
        self.assertFalse((Path(self.tmp.name)/self.payload['meeting']['id']).exists())
        new = fixture()
        self.assertEqual(store.accept(*encode(new)), 1)
        self.assertTrue((Path(self.tmp.name)/new['meeting']['id']/'receipt.json').exists())
    def test_rejects_corruption_traversal_and_bad_timing(self):
        for change in ['sha', 'path', 'duration', 'nan', 'id']:
            p = copy.deepcopy(self.payload)
            if change == 'sha': p['audio'][0]['sha256'] = 'a'*64
            if change == 'path': p['meeting']['chunks'][0]['filename'] = '../escape.wav'
            if change == 'duration': p['meeting']['chunks'][0]['duration'] = 3
            if change == 'nan': p['meeting']['chunks'][0]['start'] = float('nan')
            if change == 'id': p['meeting']['id'] = '../evil'
            with self.assertRaises(ValueError): self.store.accept(*encode(p))
        self.assertEqual(list(Path(self.tmp.name).iterdir()), [])
    def test_conflict_preserves_original(self):
        self.store.accept(*encode(self.payload))
        p = copy.deepcopy(self.payload); p['meeting']['chunks'][0]['start'] = 10
        with self.assertRaises(Conflict): self.store.accept(*encode(p))
        receipt = json.loads((Path(self.tmp.name)/p['meeting']['id']/'receipt.json').read_text())
        self.assertEqual(receipt['received']['0']['chunk']['start'], 0)
    def test_old_retry_cannot_replace_final_manifest(self):
        old = copy.deepcopy(self.payload); old['revision'] = 999; old['meeting']['ended'] = None
        self.store.accept(*encode(self.payload)); self.store.accept(*encode(old))
        receipt = json.loads((Path(self.tmp.name)/old['meeting']['id']/'receipt.json').read_text())
        self.assertIsNotNone(receipt['meeting']['ended'])
    def test_partial_batch_does_not_claim_missing_audio(self):
        p = copy.deepcopy(self.payload)
        p['meeting']['chunks'].append({'id': 1, 'filename': '000001.wav', 'start': 3, 'duration': 1})
        self.store.accept(*encode(p))
        state = json.loads((Path(self.tmp.name)/p['meeting']['id']/'receipt.json').read_text())
        self.assertEqual(set(state['received']), {'0'})
    def test_translation_key_is_private_and_never_echoed(self):
        target = Path(self.tmp.name)/'provider.key'
        server = Server(('127.0.0.1', 0), self.store, 'test-token', str(target))
        t = threading.Thread(target=server.serve_forever, daemon=True); t.start()
        try:
            value = b'opaque.provider/key+with=punctuation-test-only'
            url = f'http://127.0.0.1:{server.server_port}/v1/translation-key'
            req = urllib.request.Request(url, data=value, method='PUT', headers={'Authorization': 'Bearer test-token'})
            with urllib.request.urlopen(req) as response: self.assertNotIn(value, response.read())
            self.assertEqual(target.read_bytes(), value)
            self.assertEqual(target.stat().st_mode & 0o777, 0o600)
            for invalid in [b'too-short', b'provider-key-with embedded-space',
                            b'provider-key-with\r\nHeader: injected', b'x' * 513]:
                bad = urllib.request.Request(url, data=invalid, method='PUT', headers={'Authorization': 'Bearer test-token'})
                with self.assertRaises(urllib.error.HTTPError) as e: urllib.request.urlopen(bad)
                self.assertEqual(e.exception.code, 400)
                self.assertEqual(target.read_bytes(), value)
        finally: server.shutdown(); server.server_close(); t.join()
    def test_http_auth_and_checksum_acknowledgment(self):
        server = Server(('127.0.0.1', 0), self.store, 'test-token')
        t = threading.Thread(target=server.serve_forever, daemon=True); t.start()
        try:
            body, digest = encode(self.payload)
            url = f'http://127.0.0.1:{server.server_port}/v1/batches/{digest}'
            with self.assertRaises(urllib.error.HTTPError) as e:
                urllib.request.urlopen(urllib.request.Request(url, data=body, method='PUT'))
            self.assertEqual(e.exception.code, 401)
            request = urllib.request.Request(url, data=body, method='PUT', headers={'Authorization': 'Bearer test-token'})
            with urllib.request.urlopen(request) as response:
                self.assertEqual(response.headers['X-Content-SHA256'], digest)
            bad = urllib.request.Request(url, data=body+b'x', method='PUT', headers={'Authorization': 'Bearer test-token'})
            with self.assertRaises(urllib.error.HTTPError) as e: urllib.request.urlopen(bad)
            self.assertEqual(e.exception.code, 400)
        finally: server.shutdown(); server.server_close(); t.join()

if __name__ == '__main__': unittest.main()

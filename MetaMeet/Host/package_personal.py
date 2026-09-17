#!/usr/bin/env python3
"""Add private host pairing to a CI IPA locally; re-sign this output before installation."""
import argparse
import json
import os
from pathlib import Path
import ssl
import tempfile
import zipfile


def package(ipa, output, config):
    private = json.dumps({'url': f"https://{config['bind']}:{config.get('port', 8766)}", 'token': config['token']}).encode()
    output = Path(output)
    with zipfile.ZipFile(ipa) as source:
        roots = {n.split('/')[1] for n in source.namelist() if n.startswith('Payload/') and '.app/' in n}
        if len(roots) != 1: raise ValueError('Expected one app')
        app = 'Payload/' + roots.pop() + '/'
        expected = ssl.PEM_cert_to_DER_cert(Path(config['certificate']).read_text())
        if source.read(app+'HostCertificate.der') != expected: raise ValueError('IPA and host certificates do not match')
        placeholder = source.getinfo(app+'EmbeddedHostConfig.json')
        # Private from creation; preserve the previous output if packaging fails.
        with tempfile.NamedTemporaryFile(dir=output.parent, delete=False) as f: temp = Path(f.name)
        try:
            with zipfile.ZipFile(temp, 'w', zipfile.ZIP_DEFLATED) as dest:
                for item in source.infolist():
                    if item.filename == app+'EmbeddedHostConfig.json': continue
                    dest.writestr(item, source.read(item.filename))
                dest.writestr(placeholder, private)
            os.replace(temp, output)
        finally:
            temp.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(); parser.add_argument('ipa'); parser.add_argument('output'); parser.add_argument('--config', required=True); args = parser.parse_args()
    package(args.ipa, args.output, json.loads(Path(args.config).read_text()))
    print('Private IPA created; sign locally before installing. Do not publish this file.')

if __name__ == '__main__': main()

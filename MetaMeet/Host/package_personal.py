#!/usr/bin/env python3
"""Add private host pairing to a CI IPA locally; re-sign this output before installation."""
import argparse
import json
from pathlib import Path
import zipfile
p = argparse.ArgumentParser(); p.add_argument('ipa'); p.add_argument('output'); p.add_argument('--config', required=True); args=p.parse_args()
c = json.loads(Path(args.config).read_text())
private = json.dumps({'url': f"https://{c['bind']}:{c.get('port', 8766)}", 'token': c['token']}).encode()
with zipfile.ZipFile(args.ipa) as source, zipfile.ZipFile(args.output, 'w', zipfile.ZIP_DEFLATED) as dest:
    roots = {n.split('/')[1] for n in source.namelist() if n.startswith('Payload/') and '.app/' in n}
    if len(roots) != 1: raise SystemExit('Expected one app')
    app = 'Payload/' + roots.pop() + '/'
    for item in source.infolist():
        if item.filename == app+'EmbeddedHostConfig.json': continue
        dest.writestr(item, source.read(item.filename))
    dest.writestr(app+'EmbeddedHostConfig.json', private)
Path(args.output).chmod(0o600)
print('Private IPA created; sign locally before installing. Do not publish this file.')

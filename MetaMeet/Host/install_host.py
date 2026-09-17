#!/usr/bin/env python3
"""Install user services and private config. Never prints tokens or provider keys."""
import json
import os
from pathlib import Path
import secrets
import shutil
import subprocess
import sys

home = Path.home(); private = home/'.local/share/metameet-host'
private.mkdir(mode=0o700, parents=True, exist_ok=True)
root = home/'Downloads/MetaMeet/HostInbox'; root.mkdir(mode=0o700, parents=True, exist_ok=True)
config_path = private/'config.json'
config = json.loads(config_path.read_text()) if config_path.exists() else {
    'bind': '100.126.27.18', 'port': 8766, 'token': secrets.token_urlsafe(32), 'root': str(root),
    'certificate': str(private/'host.crt'), 'private_key': str(private/'host.key'),
    'model_path': str(home/'.local/share/metameet-transcription/models/large-v3'),
    'translation_key_file': str(private/'gemini.key'), 'translation_model': 'gemini-3.6-flash'}
if not Path(config['certificate']).is_file() or not Path(config['private_key']).is_file():
    raise SystemExit('Generate the host certificate and matching iOS HostCertificate.der first.')
for name in ['receiver.py', 'worker.py']:
    shutil.copyfile(Path(__file__).with_name(name), private/name)
config_path.write_text(json.dumps(config, indent=2)); config_path.chmod(0o600)
venv = home/'.local/share/metameet-transcription/.venv'
python = venv/'bin/python'
if not python.is_file(): raise SystemExit('Install faster-whisper CUDA runtime first.')
libs = ':'.join(str(p) for p in sorted(venv.glob('lib/python*/site-packages/nvidia/*/lib')))
units = home/'.config/systemd/user'; units.mkdir(parents=True, exist_ok=True)
for name, executable, script in [('receiver', Path(sys.executable), 'receiver.py'), ('worker', python, 'worker.py')]:
    environment = f'Environment="LD_LIBRARY_PATH={libs}"\n' if name == 'worker' else ''
    text = f'''[Unit]
Description=MetaMeet {name}
After=network-online.target

[Service]
Type=simple
ExecStart={executable} -u {private/script} --config {config_path}
Restart=on-failure
RestartSec=15
UMask=0077
NoNewPrivileges=true
PrivateTmp=true
{environment}
[Install]
WantedBy=default.target
'''
    (units/f'metameet-{name}.service').write_text(text)
subprocess.run(['systemctl', '--user', 'daemon-reload'], check=True)
subprocess.run(['systemctl', '--user', 'enable', '--now', 'metameet-receiver.service', 'metameet-worker.service'], check=True)
print('Installed receiver and worker. Private configuration:', config_path)

import json
from pathlib import Path
import ssl
import tempfile
import unittest
import zipfile
from package_personal import package

class PackagingTests(unittest.TestCase):
    def test_private_archive_preserves_resource_permissions_and_checks_certificate(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            der = (Path(__file__).parents[2]/'HostCertificate.der').read_bytes()
            (root/'host.crt').write_text(ssl.DER_cert_to_PEM_cert(der))
            config = {'bind': '100.126.27.18', 'token': 'fake-token', 'certificate': str(root/'host.crt')}
            with zipfile.ZipFile(root/'test.ipa', 'w') as archive:
                info = zipfile.ZipInfo('Payload/MetaMeet.app/EmbeddedHostConfig.json'); info.external_attr = 0o100644 << 16
                archive.writestr(info, '{}'); archive.writestr('Payload/MetaMeet.app/HostCertificate.der', der)
            output = root/'private.ipa'; package(root/'test.ipa', output, config)
            with zipfile.ZipFile(output) as archive:
                info = archive.getinfo('Payload/MetaMeet.app/EmbeddedHostConfig.json')
                self.assertEqual(info.external_attr >> 16 & 0o777, 0o644)
                self.assertEqual(json.loads(archive.read(info))['token'], 'fake-token')
                self.assertIsNone(archive.testzip())
            self.assertEqual(output.stat().st_mode & 0o777, 0o600)
            before = output.read_bytes()
            (root/'host.crt').write_text(ssl.DER_cert_to_PEM_cert(b'wrong-certificate'))
            with self.assertRaises(ValueError): package(root/'test.ipa', output, config)
            self.assertEqual(output.read_bytes(), before)

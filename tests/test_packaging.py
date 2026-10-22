"""Exercise real build.sh packaging with fake macOS/compiler/signing commands.
These tests do NOT compile Swift, validate a signature or produce a usable TIPA.
"""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).parents[1]


class PackagingTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        shutil.copy2(ROOT / 'build.sh', self.root / 'build.sh')
        shutil.copytree(ROOT / 'ValidationRelay', self.root / 'ValidationRelay')
        (self.root / 'bin').mkdir()
        self.env = os.environ.copy()
        self.env['PATH'] = str(self.root / 'bin') + os.pathsep + self.env['PATH']
        self.env['FIXTURE_MINIMUM_OS'] = '15.0'
        self.command('uname', '#!/bin/sh\necho Darwin\n')
        self.command('xcrun', '''#!/usr/bin/env python3
import pathlib,sys
if sys.argv[1] == 'swiftc':
 p=pathlib.Path(sys.argv[-1]); p.write_text('#!/bin/sh\\nexit 0\\n'); p.chmod(0o755)
sys.exit(0)
''')
        self.command('xcodebuild', '''#!/usr/bin/env python3
import os,pathlib,plistlib
p=pathlib.Path('DerivedData/ValidationRelay/Build/Products/Release-iphoneos/ValidationRelay.app')
p.mkdir(parents=True,exist_ok=True)
(p/'ValidationRelay').write_bytes(b'FAKE-EXECUTABLE-NOT-IOS')
(p/'Info.plist').write_bytes(plistlib.dumps({'MinimumOSVersion':os.environ['FIXTURE_MINIMUM_OS'],'CFBundleExecutable':'ValidationRelay'}))
''')
        self.command('ldid', '''#!/usr/bin/env python3
import os,sys,pathlib
if sys.argv[1]=='-e':
 sys.stdout.buffer.write(b'<?xml version="1.0"?><plist version="1.0"><dict/></plist>' if os.environ.get('FIXTURE_BAD_ENTITLEMENTS') else pathlib.Path('ValidationRelay/ValidationRelay.entitlements').read_bytes())
''')

    def command(self, name, source):
        path = self.root / 'bin' / name
        path.write_text(source)
        path.chmod(0o755)

    def build(self):
        return subprocess.run(['bash', 'build.sh'], cwd=self.root, env=self.env, capture_output=True, text=True)

    def test_payload_and_fresh_archive(self):
        result = self.build()
        self.assertEqual(result.returncode, 0, result.stderr)
        artifact = self.root / 'dist/ValidationRelay.tipa'
        with zipfile.ZipFile(artifact, 'a') as archive: archive.writestr('stale-fixture', b'x')
        result = self.build()
        self.assertEqual(result.returncode, 0, result.stderr)
        with zipfile.ZipFile(artifact) as archive:
            self.assertIn('Payload/ValidationRelay.app/ValidationRelay', archive.namelist())
            self.assertNotIn('stale-fixture', archive.namelist())
        self.assertTrue((self.root/'dist/ValidationRelay.tipa.sha256').exists())

    def test_incompatible_target_stops_packaging(self):
        self.assertEqual(self.build().returncode, 0)
        self.env['FIXTURE_MINIMUM_OS'] = '17.2'
        result = self.build()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root/'dist/ValidationRelay.tipa').exists())

    def test_missing_entitlements_stops_packaging(self):
        self.assertEqual(self.build().returncode, 0)
        self.env['FIXTURE_BAD_ENTITLEMENTS'] = '1'
        result = self.build()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root/'dist/ValidationRelay.tipa').exists())


if __name__ == '__main__': unittest.main()

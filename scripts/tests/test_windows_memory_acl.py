"""Exercise the actual private-memory ACL program on synthetic Windows files."""
import base64
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


@unittest.skipUnless(sys.platform == 'win32', 'Requires actual Windows ACLs')
class WindowsMemoryAclTests(unittest.TestCase):
    def test_atomic_directory_and_inherited_file_policy(self):
        source = (ROOT / 'src/services/windowsPrivateMemoryAcl.ts').read_text(encoding='utf-8')
        match = re.search(r'export const WINDOWS_MEMORY_ACL_SCRIPT = String\.raw`(.*?)`;', source, re.S)
        self.assertIsNotNone(match, 'The authoritative constant ACL program must be present')
        script = match.group(1)
        self.assertLess(len(script), 16384)
        executable = Path(os.environ.get('SystemRoot', r'C:\Windows')) / 'System32/WindowsPowerShell/v1.0/powershell.exe'
        self.assertTrue(executable.is_absolute() and executable.is_file())

        def check(kind, item):
            result = subprocess.run([str(executable), '-NoLogo', '-NoProfile', '-NonInteractive', '-Command', script],
                                    input=json.dumps({'kind': kind, 'path': str(item)}), text=True,
                                    encoding='utf-8', errors='replace', capture_output=True, timeout=10,
                                    creationflags=subprocess.CREATE_NO_WINDOW)
            diagnostic_data = {'stage': kind, 'status': result.returncode,
                               'stdout': result.stdout[:4096], 'stderr': result.stderr[:4096]}
            if result.returncode != 0:
                # Keep the actual production transport failing. Compare only the
                # constant program's documented quoting-safe transport to isolate
                # a command-line parsing failure from an ACL-policy rejection.
                encoded = base64.b64encode(script.encode('utf-16-le')).decode('ascii')
                comparison = subprocess.run([str(executable), '-NoLogo', '-NoProfile', '-NonInteractive', '-EncodedCommand', encoded],
                                            input=json.dumps({'kind': kind, 'path': str(item)}), text=True,
                                            encoding='utf-8', errors='replace', capture_output=True, timeout=10,
                                            creationflags=subprocess.CREATE_NO_WINDOW)
                diagnostic_data['encodedComparison'] = {'status': comparison.returncode,
                    'stdout': comparison.stdout[:4096], 'stderr': comparison.stderr[:4096]}
            diagnostic = json.dumps(diagnostic_data)
            self.assertEqual(result.returncode, 0, diagnostic)
            self.assertEqual(result.stdout.strip(), '{"ok":true}', diagnostic)

        with tempfile.TemporaryDirectory(prefix='quenderin-synthetic-acl-') as temporary:
            directory = Path(temporary) / 'approved-memories'
            check('directory', directory)
            check('directory', directory)  # Existing safe paths are verified.
            original = directory / 'synthetic-empty-file'
            with original.open('x', encoding='utf-8'):
                pass
            check('file', original)
            published = directory / 'synthetic-published-file'
            os.link(original, published)
            check('file', published)


if __name__ == '__main__':
    unittest.main()

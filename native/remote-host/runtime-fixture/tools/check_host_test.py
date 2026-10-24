"""Guard-only fake Git checkout tests; no upstream packages are executed."""
import hashlib
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

from check_host import ALIASES, COMPANIONS, verify_checkout


class SourceGuardTests(unittest.TestCase):
    def setUp(self):
        self.owned = tempfile.TemporaryDirectory(prefix='source-guard-', dir=os.environ['QUENDERIN_GUARD_SCRATCH'])
        self.base = Path(self.owned.name)
        self.checkout = self.base / 'checkout'
        self.checkout.mkdir()
        self.companion = self.base / 'companion'
        self.companion.mkdir()
        self.files = {
            'package.json': '{"private":true}',
            'tsconfig.json': '{}',
            'packages/plugin/package.json': '{"type":"module"}',
            'packages/protocol/package.json': '{"type":"module"}',
            'packages/plugin/tsconfig.json': '{}',
            'packages/plugin/src/harness-remote-bridge.ts': "import { value } from './safe-error.js'\nexport const bridge=value\n",
            'packages/plugin/src/typert-gateway-switch.ts': "import { value } from './safe-error.js'\nexport const gateway=value\n",
            'packages/plugin/src/safe-error.ts': 'export const value=1\n',
            'packages/plugin/src/service.ts': 'export const service=1\n',
            'packages/plugin/src/server-connection.ts': 'export const server=1\n',
            'packages/plugin/src/connection-controller.ts': 'export const connection=1\n',
            'packages/protocol/src/index.ts': 'export const protocol=1\n',
        }
        for path in set(ALIASES.values()).difference(COMPANIONS):
            self.files.setdefault(path, 'export const fixture=1\n')
        for relative, text in self.files.items():
            path = self.checkout / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text)
        self.git('init', '-q')
        self.git('add', '.')
        self.git('-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '-q', '--no-gpg-sign', '-m', 'Guard-only pinned fixture')
        patches = ['packages/plugin/src/' + name for name in ['harness-remote-bridge.ts', 'service.ts', 'server-connection.ts', 'connection-controller.ts']]
        self.spec = {'revision': self.git('rev-parse', 'HEAD').decode().strip(), 'files': {path: hashlib.sha256(self.files[path].encode()).hexdigest() for path in patches}}
        self.transform = lambda _path, source: '// approved patch\n' + source
        for relative in patches:
            (self.checkout / relative).write_text(self.transform(relative, self.files[relative]))
        for path, name in COMPANIONS.items():
            value = 'export const policy=1\n'
            (self.companion / name).write_text(value)
            (self.checkout / path).write_text(value)

    def git(self, *args):
        env = {'PATH': '/usr/bin:/bin', 'GIT_CONFIG_NOSYSTEM': '1', 'GIT_CONFIG_GLOBAL': '/dev/null', 'GIT_TERMINAL_PROMPT': '0'}
        return subprocess.check_output(['git', '-C', str(self.checkout), *args], stderr=subprocess.PIPE, env=env)

    def verify(self):
        return verify_checkout(self.checkout, self.spec, self.transform, self.companion)

    def tearDown(self):
        self.owned.cleanup()

    def test_exact_patch_and_policy_only_pass(self):
        self.assertGreater(self.verify()['runtimeSourceClosure'], 0)

    def test_dirty_switch_rejected(self):
        (self.checkout / 'packages/plugin/src/typert-gateway-switch.ts').write_text('export const fakeGateway=true\n')
        with self.assertRaisesRegex(ValueError, 'Unapproved Host source'):
            self.verify()

    def test_dirty_protocol_rejected(self):
        (self.checkout / 'packages/protocol/src/index.ts').write_text('export const forgedProtocol=true\n')
        with self.assertRaisesRegex(ValueError, 'Unapproved Host source'):
            self.verify()

    def test_dirty_transitive_source_rejected(self):
        (self.checkout / 'packages/plugin/src/safe-error.ts').write_text('export const value=2\n')
        with self.assertRaisesRegex(ValueError, 'Unapproved Host source'):
            self.verify()

    def test_extra_source_shadow_rejected(self):
        (self.checkout / 'packages/plugin/src/safe-error.js').write_text('export const value=2\n')
        with self.assertRaisesRegex(ValueError, 'Extra Host source'):
            self.verify()

    def test_source_symlink_rejected(self):
        file = self.checkout / 'packages/plugin/src/typert-gateway-switch.ts'
        file.unlink()
        file.symlink_to(self.checkout / 'packages/plugin/src/safe-error.ts')
        with self.assertRaisesRegex(ValueError, 'Linked source'):
            self.verify()

    def test_changed_manifest_rejected(self):
        (self.checkout / 'packages/plugin/package.json').write_text('{"type":"commonjs"}')
        with self.assertRaisesRegex(ValueError, 'Unapproved Host source or manifest'):
            self.verify()

    def test_extra_manifest_rejected(self):
        (self.checkout / 'packages/plugin/tsconfig.injected.json').write_text('{}')
        with self.assertRaisesRegex(ValueError, 'Extra package or TypeScript manifest'):
            self.verify()

    def test_rebuilt_unimported_dist_is_allowed(self):
        dist = self.checkout / 'packages/plugin/dist'
        dist.mkdir()
        (dist / 'index.js').write_text('// rebuilt output outside source aliases\n')
        self.verify()


if __name__ == '__main__':
    unittest.main()

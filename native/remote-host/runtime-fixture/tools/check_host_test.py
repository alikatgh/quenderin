"""Guard-only fake Git checkout tests; no upstream packages are executed."""
import hashlib
import json
import os
from pathlib import Path
import runpy
import shutil
import subprocess
import sys
import tempfile
import unittest

from check_host import ALIASES, COMPANIONS, verify_checkout, verify_built_protocol


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


class ProtocolPackagingTests(unittest.TestCase):
    """Exercise the actual package script; a stub compiler isolates its JS-copy boundary.

    Full TypeScript compilation and plugin bundling remain hosted checks. The stub
    deliberately emits an entry with the real relative wire import, but no JS copy,
    matching the observed tsc packaging behavior without installing a compiler.
    """
    def setUp(self):
        self.owned = tempfile.TemporaryDirectory(prefix='protocol-package-', dir=os.environ['QUENDERIN_GUARD_SCRATCH'])
        self.base = Path(self.owned.name)
        self.checkout = self.base / 'checkout'
        self.project = self.checkout / 'packages/protocol'
        (self.project / 'src').mkdir(parents=True)
        self.companion = Path(__file__).resolve().parents[2]
        self.original = (self.companion / 'tests/fixtures/upstream-protocol-package.json').read_text()
        spec = json.loads((self.companion / 'upstream.json').read_text())
        self.assertEqual(hashlib.sha256(self.original.encode()).hexdigest(), spec['files']['packages/protocol/package.json'])
        self.transform = runpy.run_path(str(self.companion / 'tools/prepare_host.py'))['transform']
        self.wire = self.project / 'src/quenderin-bot-read-wire.mjs'
        self.wire.write_bytes((self.companion / self.wire.name).read_bytes())
        binary = self.base / 'bin'
        binary.mkdir()
        compiler = binary / 'tsc'
        compiler.write_text('#!/usr/bin/env python3\nfrom pathlib import Path\n'
                            'Path("dist").mkdir(exist_ok=True)\n'
                            'Path("dist/index.js").write_text("import { assertBotReadWireBytes } from \'./quenderin-bot-read-wire.mjs\';\\nassertBotReadWireBytes(\'{}\');\\n")\n')
        compiler.chmod(0o700)
        self.node = shutil.which('node')
        self.assertIsNotNone(self.node)
        self.env = {'PATH': os.pathsep.join([str(binary), str(Path(self.node).parent), str(Path(sys.executable).parent), '/usr/bin', '/bin'])}

    def tearDown(self):
        self.owned.cleanup()

    def build(self, patched):
        source = self.transform('packages/protocol/package.json', self.original) if patched else self.original
        (self.project / 'package.json').write_text(source)
        return subprocess.run(['sh', '-c', json.loads(source)['scripts']['build']], cwd=self.project,
                              env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=5)

    def import_built(self):
        return subprocess.run([self.node, 'dist/index.js'], cwd=self.project, env=self.env,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=5)

    def test_original_build_omits_runtime_module_and_built_import_fails(self):
        self.assertEqual(self.build(False).returncode, 0)
        imported = self.import_built()
        self.assertNotEqual(imported.returncode, 0)
        self.assertIn(b'ERR_MODULE_NOT_FOUND', imported.stderr)
        with self.assertRaisesRegex(ValueError, 'missing or invalid'):
            verify_built_protocol(self.checkout, self.companion)

    def test_prepared_package_build_copies_exact_wire_and_imports(self):
        self.assertEqual(self.build(True).returncode, 0)
        self.assertEqual(self.import_built().returncode, 0)
        self.assertEqual((self.project / 'dist' / self.wire.name).read_bytes(), self.wire.read_bytes())
        self.assertEqual(verify_built_protocol(self.checkout, self.companion)['wireSHA256'], hashlib.sha256(self.wire.read_bytes()).hexdigest())

    def test_prepared_build_fails_if_required_source_module_is_missing(self):
        self.wire.unlink()
        self.assertNotEqual(self.build(True).returncode, 0)

    def test_built_guard_rejects_a_changed_copy(self):
        self.assertEqual(self.build(True).returncode, 0)
        (self.project / 'dist' / self.wire.name).write_text('// unapproved replacement\n')
        with self.assertRaisesRegex(ValueError, 'differs'):
            verify_built_protocol(self.checkout, self.companion)

    def test_built_guard_rejects_a_linked_copy(self):
        self.assertEqual(self.build(True).returncode, 0)
        built = self.project / 'dist' / self.wire.name
        built.unlink()
        built.symlink_to(self.wire)
        with self.assertRaisesRegex(ValueError, 'Linked source'):
            verify_built_protocol(self.checkout, self.companion)

    def test_built_guard_requires_the_entry_to_reference_the_wire_guard(self):
        self.assertEqual(self.build(True).returncode, 0)
        (self.project / 'dist/index.js').write_text('export const placeholder = true\n')
        with self.assertRaisesRegex(ValueError, 'does not reference'):
            verify_built_protocol(self.checkout, self.companion)


if __name__ == '__main__':
    unittest.main()

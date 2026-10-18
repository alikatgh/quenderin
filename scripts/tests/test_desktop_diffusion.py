"""Source-only staging/provenance failure fixtures. No compiler or model download."""
import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
import build_desktop_diffusion as build


class DesktopDiffusionTests(unittest.TestCase):
    def setUp(self):
        base = os.environ.get('QUENDERIN_DIFFUSION_TEST_SCRATCH') or os.environ.get('RUNNER_TEMP')
        if not base:
            raise RuntimeError('Use registered QUENDERIN_DIFFUSION_TEST_SCRATCH or hosted RUNNER_TEMP')
        self.temp = tempfile.TemporaryDirectory(prefix='desktop-diffusion-fixture-', dir=base)
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.stage = self.root / 'stage'
        self.stage.mkdir()
        self.lock, _ = build.runtime.manifests()
        self.os_name, self.arch = build.host()
        for name in build.names(self.os_name):
            path = self.stage / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b'synthetic fixture, never executable')
        self.stamp = dict(version=1, abiVersion=self.lock['abiVersion'], revision=self.lock['revision'],
                          platform=self.os_name, arch=self.arch, files=build.inventory(self.stage))
        self.save()

    def save(self):
        (self.stage / build.STAMP).write_text(json.dumps(self.stamp))

    def verify(self, **kwargs):
        with patch.object(build.runtime, 'verify_library') as exports, patch.object(build, 'dependency_check') as dependencies, patch.object(build, 'windows_tools'), patch.object(build, 'run', return_value=json.dumps(dict(abiVersion=self.lock['abiVersion'], revision=self.lock['revision']))) as run:
            result = build.verify(self.stage, **kwargs)
            self.assertEqual(exports.call_count, 1)
            self.assertEqual(dependencies.call_count, 1)
            self.assertEqual(run.call_args.args[0][-1], '--version')
            return result

    def test_sealed_inventory_probes_actual_cli_exports_and_dependencies(self):
        self.assertEqual(self.verify()['revision'], self.lock['revision'])

    def test_missing_stage_fails_without_running_binary(self):
        with self.assertRaisesRegex(ValueError, 'Build/stage'):
            build.verify(self.root / 'missing')

    def test_each_provenance_field_mismatch_is_rejected(self):
        for key, wrong in [('revision', 'a' * 40), ('abiVersion', 99), ('platform', 'wrong'), ('arch', 'wrong'), ('version', 2)]:
            with self.subTest(key=key):
                original = self.stamp[key]; self.stamp[key] = wrong; self.save()
                with self.assertRaisesRegex(ValueError, 'provenance mismatch'):
                    self.verify()
                self.stamp[key] = original; self.save()

    def test_modified_missing_and_extra_files_fail_seal(self):
        cli = self.stage / build.names(self.os_name)[0]
        original = cli.read_bytes()
        for action in ['modify', 'remove', 'extra']:
            with self.subTest(action=action):
                if action == 'modify': cli.write_bytes(b'changed')
                if action == 'remove': cli.unlink()
                if action == 'extra': (self.stage / 'untrusted.dll').write_bytes(b'extra')
                with self.assertRaisesRegex(ValueError, 'seal mismatch'):
                    self.verify()
                if action == 'extra': (self.stage / 'untrusted.dll').unlink()
                cli.write_bytes(original)

    def test_cli_source_mismatch_is_rejected(self):
        with patch.object(build.runtime, 'verify_library'), patch.object(build, 'windows_tools'), patch.object(build, 'run', return_value='{"abiVersion":1,"revision":"wrong"}'):
            with self.assertRaisesRegex(ValueError, 'different pinned runtime'):
                build.verify(self.stage)

    def test_symlink_escape_and_hidden_payload_are_rejected(self):
        linked = self.stage / 'escape'
        linked.symlink_to(self.root, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, 'escapes'):
            build.inventory(self.stage)
        linked.unlink()
        (self.stage / '.untrusted').write_bytes(b'hidden')
        with self.assertRaisesRegex(ValueError, 'Hidden'):
            build.inventory(self.stage)

    def test_stage_symlink_is_rejected(self):
        linked = self.root / 'linked'
        linked.symlink_to(self.stage, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, 'Build/stage'):
            build.verify(linked)

    def test_existing_work_or_destination_cannot_be_overwritten(self):
        with patch.object(build.runtime, 'fetch') as fetch:
            with self.assertRaisesRegex(ValueError, 'must be new'):
                build.build(self.root, self.root / 'new')
            with self.assertRaisesRegex(ValueError, 'must be new'):
                build.build(self.root / 'new', self.stage)
            fetch.assert_not_called()

    def test_unresolved_linux_dependencies_fail_closed(self):
        for output in ['libstdc++.so.6 => not found', 'unrecognized output']:
            with self.assertRaises(ValueError):
                build.linux_dependencies(output)
        self.assertEqual(build.linux_dependencies(' linux-vdso.so.1 (0x123)\n libc.so.6 => /lib/libc.so.6 (0x123)\n /lib/ld-linux-x86-64.so.2 (0x123)'), {'libc.so.6': Path('/lib/libc.so.6')})

    def test_joint_load_never_silently_skips_missing_prism_libraries(self):
        with self.assertRaisesRegex(ValueError, 'exactly one actual Prism'):
            build.joint_load(self.stage, self.root / 'missing-prism')


if __name__ == '__main__':
    unittest.main()

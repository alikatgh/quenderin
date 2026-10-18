"""Source-only staging/provenance failure fixtures. No compiler or model download."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
import build_desktop_diffusion as build

SPEC = importlib.util.spec_from_file_location('desktop_macho_fixtures', SCRIPTS / 'tests/test_prism_apple_runtime.py')
macho_fixtures = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(macho_fixtures)


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
            path.write_bytes(macho_fixtures.thin('arm64' if self.arch == 'arm64' else 'x86_64', 1,
                executable=name == build.names('mac')[0]) if self.os_name == 'mac' else b'synthetic fixture, never executable')
        self.stamp = dict(version=1, abiVersion=self.lock['abiVersion'], revision=self.lock['revision'],
                          platform=self.os_name, arch=self.arch, files=build.inventory(self.stage))
        if self.os_name == 'mac':
            self.stamp['machoPayloads'] = build.macho_payloads(self.stage)
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

    def test_linux_dependency_paths_may_contain_spaces_and_parentheses(self):
        self.assertEqual(build.linux_dependencies(' libquenderin_diffusion.so => /tmp/My build (fixture)/libquenderin_diffusion.so (0x123)\n /tmp/My loader (fixture)/ld-linux-x86-64.so.2 (0x456)'), {
            'libquenderin_diffusion.so': Path('/tmp/My build (fixture)/libquenderin_diffusion.so')})

    def mac_fixture(self):
        self.stamp.update(platform='mac', arch='arm64')
        for index, name in enumerate(build.names('mac')):
            binary = self.stage / name
            binary.parent.mkdir(parents=True, exist_ok=True)
            binary.write_bytes(macho_fixtures.thin('arm64', 1, executable=index == 0))
        self.stamp.update(files=build.inventory(self.stage), machoPayloads=build.macho_payloads(self.stage))
        self.save()

    def test_mac_packaged_code_changes_fail_even_with_matching_version_and_exports(self):
        self.mac_fixture()
        for index, name in enumerate(build.names('mac')):
            with self.subTest(binary=name), patch.object(build, 'host', return_value=('mac', 'arm64')):
                binary = self.stage / name
                binary.write_bytes(macho_fixtures.thin('arm64', 1, signed=True, code=b'tampered executable code', executable=index == 0))
                with self.assertRaisesRegex(ValueError, 'payload changed'):
                    self.verify(packaged=True)
                binary.write_bytes(macho_fixtures.thin('arm64', 1, executable=index == 0))

    def test_mac_packaged_signature_only_changes_preserve_payload(self):
        self.mac_fixture()
        for index, name in enumerate(build.names('mac')):
            (self.stage / name).write_bytes(macho_fixtures.thin('arm64', 1, signed=True, executable=index == 0))
        signature = self.stage / 'QuenderinDiffusion.framework/Versions/A/_CodeSignature/CodeResources'
        signature.parent.mkdir(); signature.write_bytes(b'synthetic signature resources')
        with patch.object(build, 'host', return_value=('mac', 'arm64')):
            self.verify(packaged=True)
            with self.assertRaisesRegex(ValueError, 'seal mismatch'):
                self.verify(packaged=False)

    def test_mac_packaged_other_resources_keep_exact_hashes(self):
        self.mac_fixture()
        resource = self.stage / 'runtime-LICENSE.txt'
        resource.write_bytes(b'sealed license')
        self.stamp['files'] = build.inventory(self.stage); self.save()
        resource.write_bytes(b'tampered license')
        with patch.object(build, 'host', return_value=('mac', 'arm64')):
            with self.assertRaisesRegex(ValueError, 'seal mismatch'):
                self.verify(packaged=True)
        resource.write_bytes(b'sealed license')
        extra = self.stage / 'QuenderinDiffusion.framework/Versions/A/_CodeSignature/untrusted'
        extra.parent.mkdir(); extra.write_bytes(b'not a signature resource')
        with patch.object(build, 'host', return_value=('mac', 'arm64')):
            with self.assertRaisesRegex(ValueError, 'seal mismatch'):
                self.verify(packaged=True)

    def test_mac_seal_without_payload_identities_fails_closed(self):
        self.mac_fixture(); self.stamp.pop('machoPayloads'); self.save()
        with patch.object(build, 'host', return_value=('mac', 'arm64')):
            with self.assertRaisesRegex(ValueError, 'missing Mach-O payload'):
                self.verify(packaged=True)

    def test_joint_load_never_silently_skips_missing_prism_libraries(self):
        with self.assertRaisesRegex(ValueError, 'active lastBuild.json metadata'):
            build.joint_load(self.stage, self.root / 'missing-prism')

    def prism_fixture(self, os_name=None, arch=None):
        os_name, arch = (os_name, arch) if os_name else build.host()
        package = self.root / ('node-llama-cpp-' + os_name)
        local = package / 'llama/localBuilds'
        revision = json.loads((build.ROOT / 'shared/prism-runtime.json').read_text())['revision']
        folder = f'{os_name}-{arch}-release-PrismML-Eng llama.cpp {revision}'
        active = local / folder; release = active / 'Release'
        release.mkdir(parents=True)
        (package / 'package.json').write_text(json.dumps(dict(name='node-llama-cpp', version='3.19.1')))
        (package / 'llama/lastBuild.json').write_text(json.dumps(dict(folderName=folder)))
        options = dict(platform=os_name, arch=arch, gpu=False, customCmakeOptions={},
                       llamaCpp=dict(repo='PrismML-Eng/llama.cpp', release=revision))
        (release / '_nlcBuildMetadata.json').write_text(json.dumps(dict(buildOptions=options)))
        (active / 'buildDone.status').write_bytes(b'')
        addon = release / 'llama-addon.node'; addon.write_bytes(b'active-compiled-addon-fixture')
        variant = 'PrismML-Eng_llama.cpp_' + revision
        prefix, suffix = ('', '.dll') if os_name == 'win' else ('lib', '.dylib' if os_name == 'mac' else '.so')
        ggml = release / (prefix + 'ggml-base' + suffix)
        llama = release / (prefix + 'llama.' + variant + suffix)
        for binary in (ggml, llama):
            binary.write_bytes((binary.name + '-active-fixture').encode())
            for directory in (active / 'bin', active / 'llama.cpp/bin'):
                directory.mkdir(parents=True, exist_ok=True)
                (directory / binary.name).write_bytes(binary.read_bytes())
        # This real adjacent library matched the previous *llama* glob too.
        (release / (prefix + 'llama-common' + suffix)).write_bytes(b'not-the-llama-runtime')
        # An inactive build must never select or veto the actual loaded build.
        inactive = local / 'inactive-build/bin'; inactive.mkdir(parents=True)
        (inactive / ggml.name).write_bytes(b'different-inactive-runtime')
        probe = dict(folderName=folder, addonPath=str(addon), addonSha256=build.sha(addon), binVariant=variant)
        return local, active, release, ggml, llama, probe

    def test_active_release_selects_exact_runtime_with_identical_bin_copies_and_llama_common(self):
        for os_name, arch in [('linux','x64'), ('win','x64'), ('mac','arm64')]:
            with self.subTest(platform=os_name), patch.object(build, 'host', return_value=(os_name,arch)):
                local, _, release, ggml, llama, probe = self.prism_fixture(os_name, arch)
                with patch.object(build, 'probe_active_prism', return_value=probe):
                    selected = build.active_prism_libraries(local)
                self.assertEqual(selected['ggml'], ggml)
                self.assertEqual(selected['llama'], llama)
                self.assertEqual(selected['llama'].parent, release)
                self.assertNotIn('common', selected['llama'].name)

    def test_mismatched_active_build_copies_are_rejected_instead_of_chosen(self):
        local, active, _, ggml, llama, probe = self.prism_fixture()
        for binary in (ggml, llama):
            with self.subTest(library=binary.name), patch.object(build, 'probe_active_prism', return_value=probe):
                copy = active / 'bin' / binary.name
                copy.write_bytes(b'mismatched retained build output')
                with self.assertRaisesRegex(ValueError, 'Mismatched retained active Prism dependency copy: bin/'):
                    build.active_prism_libraries(local)
                copy.write_bytes(binary.read_bytes())

    def test_active_release_missing_dependency_cannot_fall_back_to_retained_bin_copy(self):
        local, _, _, ggml, _, probe = self.prism_fixture()
        ggml.unlink()
        with patch.object(build, 'probe_active_prism', return_value=probe):
            with self.assertRaisesRegex(ValueError, 'missing or unsafe beside the loaded addon'):
                build.active_prism_libraries(local)

    def test_probe_must_bind_the_actual_loaded_addon_path_and_digest(self):
        local, active, _, _, _, probe = self.prism_fixture()
        for field, wrong in [('folderName','another-build'), ('addonPath',str(active / 'bin/llama-addon.node')), ('addonSha256','0'*64)]:
            with self.subTest(field=field), patch.object(build, 'probe_active_prism', return_value={**probe, field:wrong}):
                with self.assertRaisesRegex(ValueError, 'Actually loaded Prism addon does not match'):
                    build.active_prism_libraries(local)

    def test_active_build_metadata_must_match_pinned_cpu_target(self):
        local, _, release, _, _, _ = self.prism_fixture()
        metadata_path = release / '_nlcBuildMetadata.json'
        metadata = json.loads(metadata_path.read_text())
        for field, wrong in [('gpu','cuda'), ('platform','wrong'), ('arch','wrong'), ('llamaCpp',dict(repo='ggml-org/llama.cpp',release='wrong'))]:
            with self.subTest(field=field), patch.object(build, 'probe_active_prism') as probe:
                metadata_path.write_text(json.dumps(dict(buildOptions={**metadata['buildOptions'],field:wrong})))
                with self.assertRaisesRegex(ValueError, 'does not match the pinned CPU'):
                    build.active_prism_libraries(local)
                probe.assert_not_called()
        metadata_path.write_text(json.dumps(metadata))

    def test_active_folder_cannot_escape_local_builds(self):
        local, _, _, _, _, _ = self.prism_fixture()
        (local.parent / 'lastBuild.json').write_text('{"folderName":"../outside"}')
        with self.assertRaisesRegex(ValueError, 'Invalid active Prism lastBuild folderName'):
            build.active_prism_libraries(local)

    def test_both_joint_child_orders_receive_only_the_proven_exact_dependency_paths(self):
        local, _, _, ggml, llama, probe = self.prism_fixture()
        with patch.object(build, 'probe_active_prism', return_value=probe), patch.object(build, 'run') as run:
            result = build.joint_load(self.stage, local)
        self.assertTrue(result['jointLoad']); self.assertEqual(result['orders'],2)
        calls = [call.args[0] for call in run.call_args_list]
        self.assertEqual([args[args.index('--order')+1] for args in calls], ['prism-first','image-first'])
        for args in calls:
            self.assertEqual(args[args.index('--prism-library')+1], ggml)
            self.assertEqual(args[args.index('--llama-library')+1], llama)

    def test_embedded_active_addon_probe_has_valid_node_syntax(self):
        result = subprocess.run(['node','--input-type=module','--check'], input=build.ACTIVE_PRISM_PROBE,
                                text=True,capture_output=True,timeout=10)
        self.assertEqual(result.returncode,0,result.stderr)


if __name__ == '__main__':
    unittest.main()

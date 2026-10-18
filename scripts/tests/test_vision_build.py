"""Vision resource sealing failure tests; synthetic bytes, no native builds."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import build_vision_runtime as vision
NINJA = shutil.which('ninja') or os.environ.get('QUENDERIN_TEST_NINJA')

class AppleVisionConfigureTests(unittest.TestCase):
    """Run the actual pre-project/deferred hook with tiny shared-runtime targets."""
    def configure(self, *, missing=None, rejected=False, abi=1, multiconfig=False):
        if not shutil.which('cmake') or not (shutil.which('clang++') or shutil.which('c++')):
            self.skipTest('CMake and host C++ compiler required')
        temp = tempfile.TemporaryDirectory(prefix='apple-vision-configure-', dir=os.environ.get('RUNNER_TEMP') or os.environ.get('TMPDIR'))
        self.addCleanup(temp.cleanup); root = Path(temp.name)
        bridge = root/'native/vision'; bridge.mkdir(parents=True)
        shutil.copyfile(vision.ROOT/'native/vision/apple-runtime.cmake', bridge/'apple-runtime.cmake')
        # A deferred subdirectory must never execute, even if someone reintroduces it.
        (bridge/'CMakeLists.txt').write_text('message(FATAL_ERROR "Unexpected bridge subdirectory execution")\n')
        for name in ('quenderin_vision.cpp', 'vision_safety.cpp', 'quenderin_vision.h'):
            (bridge/name).write_text('// Synthetic configure fixture, never compiled.\n')
        scripts = root/'scripts'; scripts.mkdir()
        provenance = vision.runtime.provenance(); provenance['visionABI'] = abi
        (scripts/'prepare_prism_runtime.py').write_text(
            'import json,sys\n'
            + 'assert sys.argv[1:] == ["verify", "--source", ' + repr(str(root)) + ']\n'
            + ('sys.stderr.write("fixture source identity mismatch");sys.exit(13)\n' if rejected else 'print(' + repr(json.dumps(provenance)) + ')\n'))
        targets = []
        for name in ('llama', 'ggml', 'mtmd', 'vendor::hash'):
            if name == missing: continue
            targets.append('add_library(vendor-hash INTERFACE)\nadd_library(vendor::hash ALIAS vendor-hash)' if name == 'vendor::hash' else f'add_library({name} INTERFACE)')
        (root/'CMakeLists.txt').write_text('cmake_minimum_required(VERSION 3.22)\nproject(apple_vision_fixture LANGUAGES CXX)\n'
            + '\n'.join(targets) + r'''
function(check_bridge)
  if(NOT TARGET quenderin_vision)
    message(FATAL_ERROR "Deferred bridge target missing")
  endif()
  get_target_property(links quenderin_vision LINK_LIBRARIES)
  if(NOT links STREQUAL "llama;mtmd;vendor::hash")
    message(FATAL_ERROR "Bridge did not share the existing verified runtime: ${links}")
  endif()
  get_target_property(archive quenderin_vision ARCHIVE_OUTPUT_DIRECTORY)
  if(NOT archive STREQUAL "${CMAKE_BINARY_DIR}/quenderin-vision")
    message(FATAL_ERROR "Pinned framework archive layout changed: ${archive}")
  endif()
  get_target_property(definitions quenderin_vision COMPILE_DEFINITIONS)
  file(WRITE "${CMAKE_BINARY_DIR}/definitions.txt" "${definitions}")
  file(GENERATE OUTPUT "${CMAKE_BINARY_DIR}/archive-$<CONFIG>.txt" CONTENT "$<TARGET_FILE:quenderin_vision>")
endfunction()
cmake_language(DEFER CALL check_bridge)
''')
        args = ['cmake', '-S', str(root), '-B', str(root/'build'),
                '-DCMAKE_PROJECT_TOP_LEVEL_INCLUDES=' + str(bridge/'apple-runtime.cmake'),
                '-DQUENDERIN_VISION_SOURCE_DIR=' + str(bridge), '-DPRISM_SOURCE_DIR=' + str(root),
                '-DPython3_EXECUTABLE=' + sys.executable]
        if multiconfig: args += ['-G', 'Ninja Multi-Config', '-DCMAKE_MAKE_PROGRAM=' + NINJA]
        result = subprocess.run(args, capture_output=True, text=True, timeout=40)
        return root, result

    def test_pre_project_hook_adds_only_bridge_after_shared_targets_and_preserves_archive_identity(self):
        root, result = self.configure()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        definitions = (root/'build/definitions.txt').read_text()
        self.assertIn('QUENDERIN_VISION_REVISION="' + vision.runtime.provenance()['revision'] + '"', definitions)
        self.assertIn('QUENDERIN_VISION_PATCH_SHA256="' + vision.runtime.provenance()['visionPatchSha256'] + '"', definitions)
        self.assertIn('/quenderin-vision/', (root/'build/archive-.txt').read_text().replace('\\', '/'))

    @unittest.skipUnless(NINJA, 'Multi-config archive fixture requires Ninja')
    def test_release_archive_matches_pinned_framework_merger(self):
        root, result = self.configure(multiconfig=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('/quenderin-vision/Release/', (root/'build/archive-Release.txt').read_text().replace('\\', '/'))

    def test_missing_existing_runtime_dependencies_fail_closed(self):
        for dependency in ('llama', 'ggml', 'mtmd', 'vendor::hash'):
            with self.subTest(dependency=dependency):
                _, result = self.configure(missing=dependency)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('existing verified ' + dependency + ' target', result.stdout + result.stderr)

    def test_source_provenance_and_vision_abi_are_required_before_target_creation(self):
        _, rejected = self.configure(rejected=True)
        self.assertNotEqual(rejected.returncode, 0)
        self.assertIn('source provenance rejected', rejected.stdout + rejected.stderr)
        _, old = self.configure(abi=0)
        self.assertNotEqual(old.returncode, 0)
        self.assertIn('Vision source ABI 1 is required', old.stdout + old.stderr)

class AndroidVisionConfigureTests(unittest.TestCase):
    def test_actual_jni_and_vision_cmake_share_one_runtime_with_consistent_link_signatures(self):
        if not shutil.which('cmake') or not (shutil.which('clang++') or shutil.which('c++')):
            self.skipTest('CMake and host C++ compiler required')
        with tempfile.TemporaryDirectory(prefix='android-vision-configure-', dir=os.environ.get('RUNNER_TEMP') or os.environ.get('TMPDIR')) as temporary:
            root = Path(temporary); jni = root/'android/jni'; jni.mkdir(parents=True)
            bridge = root/'native/vision'; bridge.mkdir(parents=True)
            scripts = root/'scripts'; scripts.mkdir()
            upstream = root/'prism'; upstream.mkdir(); (upstream/'include').mkdir()
            (upstream/'include/llama.h').write_text('// Configure-only synthetic header.\n')
            (upstream/'CMakeLists.txt').write_text('add_library(llama INTERFACE)\nadd_library(ggml INTERFACE)\nadd_library(mtmd INTERFACE)\nadd_library(vendor-hash INTERFACE)\nadd_library(vendor::hash ALIAS vendor-hash)\n')
            (scripts/'prepare_prism_runtime.py').write_text('import sys\nassert sys.argv[1:] == ["verify", "--source", ' + repr(str(upstream)) + ']\nprint(' + repr(json.dumps(vision.runtime.provenance())) + ')\n')
            shutil.copyfile(vision.ROOT/'native/vision/CMakeLists.txt', bridge/'CMakeLists.txt')
            for name in ('quenderin_vision.cpp', 'vision_safety.cpp', 'quenderin_vision.h'):
                (bridge/name).write_text('// Configure fixture; never compiled.\n')
            for name in ('llama_jni.cpp', 'vision_jni.cpp'):
                (jni/name).write_text('// Configure fixture; never compiled.\n')
            source = (vision.ROOT/'android/jni/CMakeLists.txt').read_text()
            (jni/'CMakeLists.txt').write_text(source + r'''
get_target_property(jni_links quenderin_llama LINK_LIBRARIES)
if(NOT jni_links STREQUAL "quenderin_vision;llama;ggml;android;log")
  message(FATAL_ERROR "JNI target does not share its one runtime: ${jni_links}")
endif()
get_target_property(vision_links quenderin_vision LINK_LIBRARIES)
if(NOT vision_links STREQUAL "llama;mtmd;vendor::hash")
  message(FATAL_ERROR "Vision target uses another engine: ${vision_links}")
endif()
''')
            result = subprocess.run(['cmake', '-S', str(jni), '-B', str(root/'build'), '-DQUENDERIN_PRISM_RUNTIME=ON', '-DLLAMA_DIR=' + str(upstream), '-DPython3_EXECUTABLE=' + sys.executable], capture_output=True, text=True, timeout=40)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

class VisionHostTests(unittest.TestCase):
    def test_linux_armv7_packaging_host_is_recognized(self):
        with patch.object(vision.platform, 'system', return_value='Linux'), patch.object(vision.platform, 'machine', return_value='armv7l'):
            self.assertEqual(vision.host(), ('linux', 'armv7l'))

class VisionSealTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='vision-seal-fixture-'); self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.executable = self.directory / 'quenderin-vision-cli'; self.executable.write_bytes(b'unsigned fixture bytes')
        self.notice = self.directory / 'THIRD_PARTY_NOTICES.txt'; self.notice.write_text('fixture license')
        self.payload = {'arm64': {'platform': 1, 'minimumOS': 0, 'sha256': 'payload-fixture'}}
        self.stamp = dict(platform='mac', arch='arm64', source=vision.runtime.provenance(), bytes=self.executable.stat().st_size,
            sha256=vision.sha(self.executable), visionModelsSha256=vision.sha(vision.ROOT/'shared/vision-models.json'), noticesSha256=vision.sha(self.notice), machoPayload=self.payload)
        self.save()
        for owner, name, value in ((vision, 'host', ('mac', 'arm64')), (vision, 'probe', {}), (vision, 'dependencies', None), (vision.apple_runtime, 'macho_payload', self.payload)):
            obj = patch.object(owner, name, return_value=value); obj.start(); self.addCleanup(obj.stop)
    def save(self): (self.directory/vision.STAMP).write_text(json.dumps(self.stamp))
    def test_unsigned_and_packaged_identity(self):
        vision.verify(self.directory); vision.verify(self.directory, packaged=True)
        vision.probe.assert_called(); vision.dependencies.assert_called()
    def test_signature_only_mutation_requires_packaged_mode_and_same_payload(self):
        self.executable.write_bytes(b'resigned fixture bytes with a changed signature')
        with self.assertRaisesRegex(ValueError, 'whole-file'): vision.verify(self.directory)
        vision.verify(self.directory, packaged=True)
        vision.apple_runtime.macho_payload.return_value = {'arm64': {'platform': 1, 'minimumOS': 0, 'sha256': 'different-code'}}
        with self.assertRaisesRegex(ValueError, 'code or architecture'): vision.verify(self.directory, packaged=True)
    def test_other_architecture_and_source_patch_are_rejected(self):
        self.stamp['source']['visionPatchSha256'] = '0'*64; self.save()
        with self.assertRaises(ValueError): vision.verify(self.directory)
    def test_extra_file_and_modified_notice_are_rejected(self):
        extra = self.directory/'unexpected.so'; extra.write_bytes(b'wrong engine')
        with self.assertRaisesRegex(ValueError, 'unexpected'): vision.verify(self.directory)
        extra.unlink()
        self.notice.write_text('changed license')
        with self.assertRaisesRegex(ValueError, 'notices'): vision.verify(self.directory)
    def test_descriptor_change_is_rejected(self):
        self.stamp['visionModelsSha256'] = '0'*64; self.save()
        with self.assertRaises(ValueError): vision.verify(self.directory)

if __name__ == '__main__': unittest.main()

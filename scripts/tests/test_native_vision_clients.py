"""Tiny host builds exercise actual Swift and JNI clients against the exact C ABI, no weights."""
from pathlib import Path
import json
import os
import platform
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
FIXTURES = ROOT / 'scripts/tests/fixtures/native-vision'
LOCK = json.loads((ROOT / 'shared/prism-runtime.json').read_text())


def run(arguments, *, timeout=45):
    result = subprocess.run(list(map(str, arguments)), capture_output=True, text=True, timeout=timeout)
    if result.returncode:
        raise AssertionError('Command failed: ' + str(arguments[0]) + '\n' + result.stdout[-4000:] + result.stderr[-6000:])
    return result.stdout


def compiler():
    tool = shutil.which('clang++') or shutil.which('c++')
    if not tool:
        raise unittest.SkipTest('Host C++ compiler unavailable')
    return tool


def defines():
    return ['-DFIXTURE_VISION_REVISION="' + LOCK['revision'] + '"',
            '-DFIXTURE_VISION_SHA="' + LOCK['visionPatch']['sha256'] + '"']


class NativeVisionClientTests(unittest.TestCase):
    def scratch(self):
        directory = tempfile.TemporaryDirectory(prefix='native-vision-client-', dir=os.environ.get('RUNNER_TEMP') or os.environ.get('TMPDIR'))
        self.addCleanup(directory.cleanup)
        folder = Path(directory.name)
        inputs = folder / '模型 🌲'; inputs.mkdir()
        return folder, inputs

    @unittest.skipUnless(platform.system() == 'Darwin' and shutil.which('swiftc'), 'Swift host fixture requires macOS')
    def test_real_swift_adapter_c_abi_lifetime_and_cancellation(self):
        folder, inputs = self.scratch()
        module = folder / 'module'; module.mkdir()
        (module / 'shim.h').write_text('#include "' + str(ROOT / 'native/vision/quenderin_vision.h') + '"\n'
                                      'int qv_fixture_active(void); int qv_fixture_created(void); int qv_fixture_freed(void);\n')
        (module / 'module.modulemap').write_text('module llama { header "shim.h" export * }\n')
        stub = folder / 'stub.o'
        run([compiler(), '-std=c++17', '-I', ROOT / 'native/vision', *defines(), '-c', FIXTURES / 'stub.cpp', '-o', stub])
        executable = folder / 'swift-client'
        run(['swiftc', '-module-cache-path', folder / 'module-cache', '-swift-version', '6', '-D', 'QUENDERIN_VISION_LLAMA', '-I', module,
             ROOT / 'apple/QuenderinKit/Sources/QuenderinKit/VisionModels.swift',
             ROOT / 'apple/QuenderinKit/Sources/QuenderinKit/VisionEngine.swift', FIXTURES / 'client.swift',
             stub, '-Xlinker', '-lc++', '-o', executable])
        self.assertIn('PASS: Swift actual C ABI', run([executable, inputs], timeout=10))

    @unittest.skipUnless(platform.system() in ('Darwin', 'Linux') and shutil.which('kotlinc') and shutil.which('kotlin'), 'JVM host compiler unavailable')
    def test_real_kotlin_jni_adapter_c_abi_utf8_lifetime_and_cancellation(self):
        folder, inputs = self.scratch()
        if platform.system() == 'Darwin':
            java_home = Path(run(['/usr/libexec/java_home', '-v', '21']).strip())
            include_os, library, linker = 'darwin', folder / 'libquenderin_llama.dylib', '-dynamiclib'
        else:
            javac = shutil.which('javac')
            if not javac:
                self.skipTest('JDK headers unavailable')
            java_home = Path(javac).resolve().parents[1]
            include_os, library, linker = 'linux', folder / 'libquenderin_llama.so', '-shared'
        include = folder / 'include'; include.mkdir()
        (include / 'ggml-backend.h').write_text('extern "C" void ggml_backend_load_all_from_path(const char*);\n')
        run([compiler(), '-std=c++17', '-fPIC', linker, '-pthread', '-DFIXTURE_JNI', *defines(),
             '-I', ROOT / 'native/vision', '-I', include, '-I', java_home / 'include', '-I', java_home / 'include' / include_os,
             ROOT / 'android/jni/vision_jni.cpp', FIXTURES / 'stub.cpp', '-o', library])
        core = ROOT / 'android/quenderin-core/src/main/kotlin/ai/quenderin/core'
        jar = folder / 'vision-clients.jar'
        run(['kotlinc', core / 'VisionEngine.kt', core / 'VisionModels.kt', core / 'NativeModelResources.kt',
             FIXTURES / 'VisionVerify.kt', '-d', jar])
        self.assertIn('PASS: Kotlin actual JNI/C ABI', run(['kotlin', '-J-Djava.library.path=' + str(folder), '-classpath', jar,
             'ai.quenderin.core.VisionVerifyKt', inputs], timeout=10))


if __name__ == '__main__':
    unittest.main()

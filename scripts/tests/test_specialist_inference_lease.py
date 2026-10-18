"""Real coordination implementations with small host delegates; no model weights or devices."""
from pathlib import Path
import os
import platform
import shutil
import subprocess
import tempfile
import unittest
ROOT = Path(__file__).resolve().parents[2]


def run(args, timeout=45):
    result = subprocess.run(list(map(str, args)), capture_output=True, text=True, timeout=timeout)
    if result.returncode:
        raise AssertionError(result.stdout[-2000:] + result.stderr[-6000:])
    return result.stdout


class SpecialistLeaseTests(unittest.TestCase):
    def scratch(self):
        scratch = tempfile.TemporaryDirectory(prefix='specialist-lease-', dir=os.environ.get('RUNNER_TEMP') or os.environ.get('TMPDIR'))
        self.addCleanup(scratch.cleanup)
        return Path(scratch.name)

    @unittest.skipUnless(platform.system() == 'Darwin' and shutil.which('swiftc'), 'Swift host compiler unavailable')
    def test_actual_swift_coordination(self):
        scratch = self.scratch(); core = ROOT / 'apple/QuenderinKit/Sources/QuenderinKit'
        run(['swiftc', '-swift-version', '6', '-module-cache-path', scratch / 'module-cache',
             core / 'InferenceEngine.swift', core / 'SpecialistInferenceLease.swift', core / 'ModelIntegrity.swift',
             core / 'ModelArtifactReceipts.swift', ROOT / 'scripts/tests/fixtures/specialist-lease/client.swift',
             '-o', scratch / 'verify'])
        self.assertIn('PASS: actual Swift exclusive lease', run([scratch / 'verify', scratch], timeout=10))

    @unittest.skipUnless(shutil.which('kotlinc') and shutil.which('kotlin'), 'Kotlin host compiler unavailable')
    def test_actual_kotlin_coordination(self):
        scratch = self.scratch(); core = ROOT / 'android/quenderin-core/src/main/kotlin/ai/quenderin/core'
        run(['kotlinc', *sorted(core.glob('*.kt')), ROOT / 'android/quenderin-core/src/verify/SpecialistLeaseVerify.kt', '-d', scratch / 'verify.jar'])
        self.assertIn('PASS: actual Kotlin exclusive lease', run(['kotlin', '-classpath', scratch / 'verify.jar',
            'ai.quenderin.core.SpecialistLeaseVerifyKt', scratch], timeout=10))


if __name__ == '__main__':
    unittest.main()

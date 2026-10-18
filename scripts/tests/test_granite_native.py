"""Tiny native client fixtures: synthetic GGUF metadata, no weight downloads/native runtime build."""
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import struct
import subprocess
import tempfile
import unittest
ROOT = Path(__file__).resolve().parents[2]
LOCK = json.loads((ROOT / 'shared/prism-runtime.json').read_text())

def run(args, timeout=45):
    result = subprocess.run(list(map(str, args)), capture_output=True, text=True, timeout=timeout)
    if result.returncode: raise AssertionError(result.stdout[-2000:] + result.stderr[-6000:])
    return result.stdout

def gguf(embedding):
    def string(value):
        data = value.encode(); return struct.pack('<Q', len(data)) + data
    fields = [('general.architecture', 8, string('graniteswitch')),
              ('graniteswitch.block_count', 4, struct.pack('<I', 40)),
              ('graniteswitch.embedding_length', 4, struct.pack('<I', embedding))]
    data = b'GGUF' + struct.pack('<IQQ', 3, 0, len(fields))
    for key, kind, value in fields: data += string(key) + struct.pack('<I', kind) + value
    return data.ljust(1024, b'\0')

class GraniteNativeTests(unittest.TestCase):
    def scratch(self):
        directory = tempfile.TemporaryDirectory(prefix='granite-client-', dir=os.environ.get('RUNNER_TEMP') or os.environ.get('TMPDIR'))
        self.addCleanup(directory.cleanup); root = Path(directory.name)
        for name, embedding in [('converted.gguf', 4096), ('wrong.gguf', 3072)]:
            data = gguf(embedding); (root / name).write_bytes(data)
            receipt = {'version': 1, 'source': {'repository': 'ibm-granite/granite-switch-4.1-8b', 'revision': '0d1625d16df2d54cafb6bc5cb0650aec043f77d6', 'weightLayers': 40},
                       'runtime': {'repository': LOCK['repository'], 'revision': LOCK['revision'], 'graniteConverterPatchId': LOCK['graniteConverterPatch']['id'], 'graniteConverterPatchSha256': LOCK['graniteConverterPatch']['sha256']},
                       'outtype': 'f16', 'bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest()}
            (root / (name + '.quenderin.json')).write_text(json.dumps(receipt))
        return root
    @unittest.skipUnless(platform.system() == 'Darwin' and shutil.which('swiftc'), 'Swift host compiler unavailable')
    def test_actual_swift_proof_import_metadata_and_client(self):
        root = self.scratch(); core = ROOT / 'apple/QuenderinKit/Sources/QuenderinKit'
        run(['swiftc', '-swift-version', '6', '-module-cache-path', root / 'cache', core / 'Granite41.swift', core / 'GraniteNativeEngine.swift', core / 'GraniteChatView.swift', core / 'GGUFModelMetadata.swift', core / 'ModelIntegrity.swift', core / 'ModelArtifactReceipts.swift', ROOT / 'scripts/tests/fixtures/granite-native/client.swift', '-o', root / 'verify'])
        self.assertIn('PASS: Swift actual Granite', run([root / 'verify', root], 10))
    @unittest.skipUnless(shutil.which('kotlinc') and shutil.which('kotlin'), 'Kotlin host compiler unavailable')
    def test_actual_kotlin_core_proof_import_and_metadata(self):
        root = self.scratch(); core = ROOT / 'android/quenderin-core/src/main/kotlin/ai/quenderin/core'
        run(['kotlinc', *sorted(core.glob('*.kt')), ROOT / 'android/quenderin-core/src/verify/GraniteVerify.kt', '-d', root / 'verify.jar'])
        self.assertIn('PASS: Kotlin actual Granite', run(['kotlin', '-classpath', root / 'verify.jar', 'ai.quenderin.core.GraniteVerifyKt', root], 10))
if __name__ == '__main__': unittest.main()

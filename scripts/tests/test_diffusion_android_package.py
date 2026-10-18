import hashlib
import importlib.util
import json
import os
from pathlib import Path
import struct
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('android_image', ROOT / 'scripts/verify_diffusion_android_package.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def elf(names=(), alignment=16384):
    strings = b'\0' + b''.join(n.encode() + b'\0' for n in names)
    dynamic = [(1, 1 + sum(len(n) + 1 for n in names[:i])) for i in range(len(names))]
    dynamic += [(5, 0x300), (10, len(strings)), (0, 0)]
    result = bytearray(0x300 + len(strings))
    result[:16] = b'\x7fELF\x02\x01\x01' + bytes(9)
    struct.pack_into('<HHIQQQIHHHHHH', result, 16, 3, 183, 1, 0, 64, 0, 0, 64, 56, 2, 0, 0, 0)
    struct.pack_into('<IIQQQQQQ', result, 64, 1, 5, 0, 0, 0, len(result), len(result), alignment)
    struct.pack_into('<IIQQQQQQ', result, 120, 2, 6, 0x200, 0x200, 0, len(dynamic)*16, len(dynamic)*16, 8)
    for index, entry in enumerate(dynamic): struct.pack_into('<qQ', result, 0x200 + index*16, *entry)
    result[0x300:] = strings
    return bytes(result)


class AndroidPackageTests(unittest.TestCase):
    def test_dependencies_and_16k_alignment(self):
        self.assertEqual(module.elf_dependencies(elf(('libc.so', 'libquenderin_diffusion.so'))),
                         {'libc.so', 'libquenderin_diffusion.so'})

    def test_4k_and_malformed_elf_are_rejected(self):
        for data in (elf(alignment=4096), elf()[:90], b'not an ELF'):
            with self.assertRaises(ValueError): module.elf_dependencies(data)

    def with_package(self, mutate, core=None, bundle=False):
        scratch = os.environ.get('QUENDERIN_DIFFUSION_TEST_SCRATCH') or os.environ.get('RUNNER_TEMP')
        if not scratch: raise RuntimeError('Use registered session scratch or hosted RUNNER_TEMP')
        with tempfile.TemporaryDirectory(dir=scratch, prefix='android-package-fixture-') as temp:
            root = Path(temp); libs = root / 'jniLibs'; (libs / 'arm64-v8a').mkdir(parents=True)
            files = {'libquenderin_diffusion.so': core or elf(('libc.so', 'libm.so')),
                     'libquenderin_diffusion_jni.so': elf(('libquenderin_diffusion.so', 'libc.so'))}
            lock = json.loads((ROOT / 'shared/diffusion-runtime.json').read_text())
            stamp = {key:lock[key] for key in ('revision', 'abiVersion', 'submodules')}
            stamp.update(androidStl='c++_static', files={n:hashlib.sha256(b).hexdigest() for n,b in files.items()})
            for name, data in files.items(): (libs / 'arm64-v8a' / name).write_bytes(data)
            (libs / 'quenderin-diffusion-runtime.json').write_text(json.dumps(stamp))
            packaged = dict(files); mutate(packaged)
            apk = root / ('app.aab' if bundle else 'app.apk')
            with zipfile.ZipFile(apk, 'w') as output:
                for name, data in packaged.items(): output.writestr(('base/lib/arm64-v8a/' if bundle else 'lib/arm64-v8a/') + name, data)
            return module.verify(libs, apk)

    def test_actual_package_contains_exact_two_libraries(self):
        self.assertEqual(len(self.with_package(lambda _:None)['verified']), 2)

    def test_actual_aab_has_exact_image_libraries(self):
        self.assertEqual(len(self.with_package(lambda _:None, bundle=True)['verified']), 2)

    def test_missing_packaged_image_library_is_rejected(self):
        with self.assertRaisesRegex(ValueError, 'Missing'):
            self.with_package(lambda files:files.pop('libquenderin_diffusion.so'))

    def test_stale_packaged_image_library_is_rejected(self):
        with self.assertRaisesRegex(ValueError, 'differs'):
            self.with_package(lambda files:files.update({'libquenderin_diffusion.so':elf(('libc++_shared.so',))}))

    def test_dependency_closure_cannot_assume_shared_stl(self):
        with self.assertRaisesRegex(ValueError, 'shared STL'):
            self.with_package(lambda _:None, core=elf(('libc++_shared.so',)))

    def test_transitive_dependency_must_be_in_package(self):
        with self.assertRaisesRegex(ValueError, 'Missing'):
            self.with_package(lambda _:None, core=elf(('libunpackaged.so',)))

    def test_actual_package_alignment_is_checked_after_hash(self):
        with self.assertRaisesRegex(ValueError, '16 KiB'):
            self.with_package(lambda _:None, core=elf(alignment=4096))


if __name__ == '__main__': unittest.main()

"""Inert archive/readelf-output fixtures only; no native build or SDK loads."""
import hashlib
import json
import pathlib
import sys
import tempfile
import time
import unittest
from unittest.mock import patch
import zipfile

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / "tools"))
from native_audit import inspect_native, parse_readelf, python_evidence

READELF = """ELF Header:
  Machine:                           Advanced Micro Devices X86-64
Dynamic section at offset 0x1234 contains 4 entries:
 0x0000000000000001 (NEEDED)             Shared library: [libc.so.6]
 0x0000000000000001 (NEEDED)             Shared library: [libnvshmem_host.so.3]
 0x000000000000000e (SONAME)             Library soname: [libfixture.so]
 0x000000000000001d (RUNPATH)            Library runpath: [$ORIGIN/../lib]
"""


class NativeAudit(unittest.TestCase):
    def test_readelf_dynamic_dependencies_are_data(self):
        parsed = parse_readelf(READELF)
        self.assertEqual(parsed["needed"], ["libc.so.6", "libnvshmem_host.so.3"])
        self.assertEqual(parsed["soname"], ["libfixture.so"])
        self.assertEqual(parsed["runpath"], ["$ORIGIN/../lib"])
        with self.assertRaisesRegex(ValueError, "Unparsed"):
            parse_readelf(READELF.replace("[libc.so.6]", "missing-brackets"))
        with self.assertRaisesRegex(ValueError, "ELF header"):
            parse_readelf("not readelf data")

    def test_python_loader_references_are_parsed_without_execution(self):
        raw = b"import ctypes\nraise RuntimeError('must never run')\nctypes.CDLL('libnvshmem_host.so.3')\n"
        evidence = python_evidence("max", "max/engine/api.py", raw)
        self.assertEqual(evidence["imports"], ["ctypes"])
        self.assertEqual(evidence["sharedMemoryReferences"][0]["line"], 3)
        self.assertEqual(evidence["sha256"], hashlib.sha256(raw).hexdigest())

    def test_archive_elf_inspection_never_executes_its_payload(self):
        with tempfile.TemporaryDirectory(prefix="quenderin-max-native-guard-") as directory:
            root = pathlib.Path(directory)
            packages = []
            for name, members in [
                ("max-core", {"modular/lib/libmax.so": b"\x7fELF-inert-nvshmem-data",
                              "max/engine/api.py": b"from max import _core\nraise RuntimeError('never run')\n"}),
                ("max-shmem-libs", {"modular/lib/libnvshmem_host.so.3": b"\x7fELF-inert-nvshmem-host"}),
            ]:
                path = root / (name + ".whl")
                with zipfile.ZipFile(path, "w") as wheel:
                    for filename, data in members.items():
                        wheel.writestr(filename, data)
                packages.append({"name": name, "version": "26.7.0", "filename": path.name,
                                 "size": path.stat().st_size, "sha256": hashlib.sha256(path.read_bytes()).hexdigest()})
            calls = []
            def inert_readelf(command, **kwargs):
                self.assertEqual(command[0], "/usr/bin/readelf")
                self.assertGreater(kwargs["deadline"], time.monotonic())
                calls.append(command)
                if command[1:] == ["--version"]:
                    return b"GNU readelf (inert fixture)\n", b""
                candidate = pathlib.Path(command[-1])
                self.assertEqual(candidate.read_bytes()[:4], b"\x7fELF")
                self.assertEqual(candidate.stat().st_mode & 0o111, 0)
                return READELF.encode(), b""
            with patch("native_audit.bounded", side_effect=inert_readelf):
                facts = inspect_native({"packages": packages, "maximum_uncompressed_bytes": 4096}, root, root / "inspection")
            self.assertEqual(len(calls), 3)
            self.assertFalse((root / "inspection").exists())
            self.assertFalse(facts["sdkCodeExecuted"])
            self.assertFalse(facts["cpuOmissionAdmitted"])
            self.assertEqual(len(facts["elfs"]), 2)
            self.assertEqual(facts["maxShmemPackagePayloads"], ["modular/lib/libnvshmem_host.so.3"])
            self.assertEqual(facts["retainedDirectNvshmemDependencyBlockers"][0]["path"], "modular/lib/libmax.so")
            self.assertEqual(facts["elfs"][0]["sharedMemoryByteMarkers"]["nvshmem"], 1)
            digest = facts.pop("evidenceSHA256")
            self.assertEqual(digest, hashlib.sha256(json.dumps(facts, sort_keys=True, separators=(",", ":")).encode()).hexdigest())

    def test_failed_readelf_removes_owned_temporary_elf(self):
        with tempfile.TemporaryDirectory(prefix="quenderin-max-native-guard-") as directory:
            root = pathlib.Path(directory)
            path = root / "inert.whl"
            with zipfile.ZipFile(path, "w") as wheel:
                wheel.writestr("libinert.so", b"\x7fELF-inert")
            package = {"name": "max-core", "version": "26.7.0", "filename": path.name,
                       "size": path.stat().st_size, "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}
            with patch("native_audit.bounded", side_effect=[(b"GNU readelf fixture\n", b""), ValueError("bounded readelf failure")]):
                with self.assertRaisesRegex(ValueError, "bounded readelf failure"):
                    inspect_native({"packages": [package], "maximum_uncompressed_bytes": 4096}, root, root / "inspection")
            self.assertFalse((root / "inspection").exists())


if __name__ == "__main__":
    unittest.main()

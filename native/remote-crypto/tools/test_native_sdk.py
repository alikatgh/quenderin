import copy
from pathlib import Path
import struct
import tempfile
import unittest

import native_sdk as sdk


class NativeSDKReceiptTests(unittest.TestCase):
    def setUp(self):
        self.files = {"kotlin/" + sdk.KOTLIN: "a" * 64,
                      "jniLibs/arm64-v8a/libquenderin_remote_crypto.so": "b" * 64,
                      "jna/jna-5.19.1.aar": "c" * 64}
        self.sources = {"Cargo.lock": "d" * 64, "src/lib.rs": "e" * 64}
        self.receipt = {"schemaVersion": 1, "platform": "android", "rust": "1.90.0",
                        "targets": sdk.TARGETS["android"], "sources": self.sources, "files": self.files}

    def test_matching_exact_receipt(self):
        sdk.validate_receipt(self.receipt, "android", self.files, self.sources)

    def test_invalid_receipt_type(self):
        with self.assertRaises(ValueError):
            sdk.validate_receipt([], "android", self.files, self.sources)

    def test_missing_sdk_and_missing_receipt_fail(self):
        with tempfile.TemporaryDirectory() as directory:
            for path in [Path(directory), Path(directory) / "absent"]:
                with self.assertRaises((ValueError, FileNotFoundError)):
                    sdk.verify(path, "android")

    def test_stale_source_lock_or_binding_fails(self):
        for field in ["files", "sources"]:
            receipt = copy.deepcopy(self.receipt)
            receipt[field][next(iter(receipt[field]))] = "f" * 64
            with self.assertRaises(ValueError):
                sdk.validate_receipt(receipt, "android", self.files, self.sources)

    def test_missing_or_unexpected_abi_fails(self):
        for targets in [[], ["x86_64-linux-android"], sdk.TARGETS["android"] + ["x86_64-linux-android"]]:
            receipt = dict(self.receipt, targets=targets)
            with self.assertRaises(ValueError):
                sdk.validate_receipt(receipt, "android", self.files, self.sources)

    def test_receipt_cannot_authorize_missing_native_library(self):
        actual = dict(self.files)
        del actual["jniLibs/arm64-v8a/libquenderin_remote_crypto.so"]
        with self.assertRaises(ValueError):
            sdk.validate_receipt(dict(self.receipt, files=actual), "android", actual, self.sources)

    def test_extra_or_modified_artifact_fails(self):
        actual = dict(self.files, unexpected="f" * 64)
        with self.assertRaises(ValueError):
            sdk.validate_receipt(self.receipt, "android", actual, self.sources)

    def test_symlink_artifact_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "alias").symlink_to("absent")
            with self.assertRaises(ValueError):
                sdk.files(root)

    def test_build_refuses_existing_output_before_running_tools(self):
        with tempfile.TemporaryDirectory() as directory:
            # This cannot invoke cargo locally, even when output is absent.
            with self.assertRaises(ValueError):
                sdk.build(Path(directory), "android")


class NativeSDKELFTests(unittest.TestCase):
    def fixture(self, *, machine=183, alignment=16384, file_offset=0, address=0):
        data = bytearray(128)
        data[:6] = b"\x7fELF\x02\x01"
        struct.pack_into("<HH", data, 16, 3, machine)
        struct.pack_into("<Q", data, 32, 64)
        struct.pack_into("<HH", data, 54, 56, 1)
        struct.pack_into("<IIQQQQQQ", data, 64, 1, 5, file_offset, address, 0, 64, 64, alignment)
        return bytes(data)

    def test_arm64_16k_load(self):
        sdk.elf(self.fixture())

    def test_wrong_abi_rejected(self):
        with self.assertRaises(ValueError): sdk.elf(self.fixture(machine=62))

    def test_4k_and_non_power_of_two_alignment_rejected(self):
        for alignment in [4096, 24576]:
            with self.assertRaises(ValueError): sdk.elf(self.fixture(alignment=alignment))

    def test_bad_segment_offset_rejected(self):
        with self.assertRaises(ValueError): sdk.elf(self.fixture(file_offset=1))

    def test_declared_larger_alignment_must_also_be_satisfied(self):
        with self.assertRaises(ValueError): sdk.elf(self.fixture(alignment=65536, address=16384))

    def test_truncated_header_rejected(self):
        with self.assertRaises(ValueError): sdk.elf(self.fixture()[:80])


if __name__ == "__main__": unittest.main()

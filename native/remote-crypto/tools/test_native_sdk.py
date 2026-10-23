import copy
import contextlib
import io
from pathlib import Path
import struct
import tempfile
import unittest
from unittest.mock import patch
import zipfile

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


class NativeSDKAndroidToolchainTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.ndk = Path(self.directory.name)
        (self.ndk / "source.properties").write_text("Pkg.Desc = Android NDK\nPkg.Revision = 26.3.11579264\n")
        tools = self.ndk / "toolchains/llvm/prebuilt/linux-x86_64/bin"
        tools.mkdir(parents=True)
        self.compiler = tools / "aarch64-linux-android28-clang"
        self.archiver = tools / "llvm-ar"
        for tool in (self.compiler, self.archiver):
            # Configuration-only fixture: no compiler or native build is executed.
            tool.touch()
            tool.chmod(0o755)

    def test_c_dependencies_use_the_same_pinned_api28_compiler_and_ndk_archiver(self):
        env = sdk.android_toolchain_env(self.ndk)
        self.assertEqual(env["CC_aarch64_linux_android"], str(self.compiler))
        self.assertEqual(env["CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER"], env["CC_aarch64_linux_android"])
        self.assertEqual(env["AR_aarch64_linux_android"], str(self.archiver))
        self.assertIn("max-page-size=16384", env["CARGO_TARGET_AARCH64_LINUX_ANDROID_RUSTFLAGS"])
        self.assertNotIn("CC", env)
        self.assertNotIn("AR", env)

    def test_missing_compiler_or_archiver_fails_instead_of_falling_back_to_path(self):
        for tool in (self.compiler, self.archiver):
            with self.subTest(tool=tool.name):
                tool.unlink()
                with self.assertRaisesRegex(ValueError, "compiler/archiver is unavailable"):
                    sdk.android_toolchain_env(self.ndk)
                tool.touch()
                tool.chmod(0o755)

    def test_nonexecutable_tool_fails(self):
        for tool in (self.compiler, self.archiver):
            with self.subTest(tool=tool.name):
                tool.chmod(0o644)
                with self.assertRaisesRegex(ValueError, "compiler/archiver is unavailable"):
                    sdk.android_toolchain_env(self.ndk)
                tool.chmod(0o755)

    def test_changed_or_similarly_prefixed_ndk_revision_fails(self):
        for revision in ["27.0.12077973", "26.3.115792640"]:
            with self.subTest(revision=revision):
                (self.ndk / "source.properties").write_text(f"Pkg.Revision = {revision}\n")
                with self.assertRaisesRegex(ValueError, "NDK pin differs"):
                    sdk.android_toolchain_env(self.ndk)


class NativeSDKPackageTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.sdk = self.root / "sdk"
        self.noise = NativeSDKELFTests().fixture()
        self.jna = self.noise[:-1] + b"\x01"
        library = self.sdk / "jniLibs/arm64-v8a/libquenderin_remote_crypto.so"
        library.parent.mkdir(parents=True)
        library.write_bytes(self.noise)
        aar = self.sdk / "jna/jna-5.19.1.aar"
        aar.parent.mkdir()
        with zipfile.ZipFile(aar, "w") as archive:
            archive.writestr("jni/arm64-v8a/libjnidispatch.so", self.jna)
        self.entries = {"lib/arm64-v8a/libquenderin_remote_crypto.so": self.noise,
                        "lib/arm64-v8a/libjnidispatch.so": self.jna}

    def package(self, entries=None, compression=zipfile.ZIP_DEFLATED):
        package = self.root / "synthetic.apk"
        with zipfile.ZipFile(package, "w", compression=compression) as archive:
            for name, data in (self.entries if entries is None else entries).items():
                archive.writestr(name, data)
        return package

    def check_package(self, package):
        # These synthetic ELF/ZIP fixtures exercise the package gate only. SDK
        # receipt/JNA provenance validation is a separate, unchanged precondition.
        with patch.object(sdk, "verify") as prerequisite:
            sdk.verify_package(self.sdk, package)
        prerequisite.assert_called_once_with(self.sdk, "android")

    def test_unchanged_sealed_libraries_in_compressed_apk_pass(self):
        self.check_package(self.package())

    def test_changed_noise_and_jna_bytes_remain_rejected_with_distinct_diagnostics(self):
        for library, label in [("libquenderin_remote_crypto.so", "Noise"), ("libjnidispatch.so", "JNA")]:
            with self.subTest(library=library):
                entries = dict(self.entries)
                name = "lib/arm64-v8a/" + library
                entries[name] = entries[name][:-1] + b"\x02"
                with self.assertRaisesRegex(ValueError, f"Packaged {label} bytes differ from verified SDK"):
                    self.check_package(self.package(entries))

    def test_other_dependency_elf_alignment_remains_enforced(self):
        entries = dict(self.entries, **{"lib/arm64-v8a/libsynthetic_dependency.so": NativeSDKELFTests().fixture(alignment=4096)})
        with self.assertRaisesRegex(ValueError, "Another packaged dependency lacks 16 KiB ELF load alignment"):
            self.check_package(self.package(entries))

    def test_noise_and_jna_elf_alignment_failures_are_distinguished(self):
        for library, label in [("libquenderin_remote_crypto.so", "Noise"), ("libjnidispatch.so", "JNA")]:
            with self.subTest(library=library):
                entries = dict(self.entries)
                entries["lib/arm64-v8a/" + library] = NativeSDKELFTests().fixture(alignment=4096)
                with self.assertRaisesRegex(ValueError, f"Packaged {label} ELF lacks 16 KiB load alignment"):
                    self.check_package(self.package(entries))

    def test_unexpected_abi_remains_rejected(self):
        entries = dict(self.entries, **{"lib/x86_64/libsynthetic_dependency.so": NativeSDKELFTests().fixture(machine=62)})
        with self.assertRaisesRegex(ValueError, "Unexpected packaged Android ABI"):
            self.check_package(self.package(entries))

    def test_stored_apk_library_without_zip_alignment_remains_rejected(self):
        with self.assertRaisesRegex(ValueError, "Stored APK native library lacks 16 KiB ZIP alignment"):
            self.check_package(self.package(compression=zipfile.ZIP_STORED))

    def test_missing_remote_library_remains_rejected(self):
        for library, label in [("libquenderin_remote_crypto.so", "Noise"), ("libjnidispatch.so", "JNA")]:
            with self.subTest(library=library):
                entries = dict(self.entries)
                del entries["lib/arm64-v8a/" + library]
                with self.assertRaisesRegex(ValueError, f"missing the real {label} library"):
                    self.check_package(self.package(entries))


class NativeSDKDiagnosticTests(unittest.TestCase):
    def cli_failure(self, error):
        output = io.StringIO()
        with patch("sys.argv", ["native_sdk.py", "verify-package", "--sdk", "/synthetic/sdk", "--package", "/synthetic/app.apk"]), \
                patch.object(sdk, "verify_package", side_effect=error), contextlib.redirect_stderr(output):
            self.assertEqual(sdk.main(), 1)
        return output.getvalue()

    def test_known_package_failure_has_a_fixed_actionable_diagnostic(self):
        self.assertEqual(self.cli_failure(ValueError("Packaged Noise bytes differ from verified SDK")),
                         "Native SDK check failed: PACKAGE_NOISE_BYTES: Packaged Noise bytes differ from verified SDK.\n")
        self.assertIn("PACKAGE_DEPENDENCY_ELF_ALIGNMENT", self.cli_failure(ValueError("Another packaged dependency lacks 16 KiB ELF load alignment")))
        for library, code in [("Noise", "PACKAGE_NOISE_MISSING"), ("JNA", "PACKAGE_JNA_MISSING")]:
            with self.subTest(library=library):
                self.assertIn(code, self.cli_failure(ValueError(f"Android package is missing the real {library} library")))

    def test_unknown_exception_data_is_never_printed(self):
        private = "synthetic-private-value-must-not-appear"
        for error in [ValueError(private), RuntimeError(private), KeyError(private), OSError(private), zipfile.BadZipFile(private)]:
            with self.subTest(kind=type(error).__name__):
                output = self.cli_failure(error)
                self.assertNotIn(private, output)
                self.assertIn("Native SDK check failed: SDK_", output)


if __name__ == "__main__": unittest.main()

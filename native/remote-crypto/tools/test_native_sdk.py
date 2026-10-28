import copy
import contextlib
import io
import json
import os
from pathlib import Path
import plistlib
import struct
import tempfile
import unittest
from unittest.mock import Mock, patch
import zipfile

import native_sdk as sdk


class NativeSDKAppleCloudTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.checkout = self.root / "repository"
        self.checkout.mkdir()
        self.out = self.checkout / "apple/QuenderinKit/build/RemoteCryptoSDK"
        self.env = {"CI": "TRUE", "CI_XCODE_CLOUD": "TRUE", "CI_BUILD_ID": "12345678-ABCD-1234-ABCD-123456789ABC",
                    "CI_WORKSPACE_PATH": str(self.root), "CI_PRIMARY_REPOSITORY_PATH": str(self.checkout), "PATH": "/synthetic/bin"}
        for patcher in (patch.object(sdk, "REPO", self.checkout), patch.object(sdk.host_platform, "system", return_value="Darwin"),
                        patch.dict(os.environ, self.env, clear=True)):
            patcher.start(); self.addCleanup(patcher.stop)
        self.addCleanup(self.reset_limits)

    def reset_limits(self):
        sdk.CLOUD_DEADLINE = sdk.CLOUD_DISK = None

    def test_documented_cloud_context_is_accepted_without_github_spoofing(self):
        sdk.require_apple_cloud(self.out)
        self.assertNotIn("GITHUB_ACTIONS", os.environ)
        self.assertEqual(os.environ["CI"], "TRUE")

    def test_incomplete_wrong_host_and_other_platform_context_fails_before_allocation(self):
        for field, value in [("CI", "true"), ("CI_XCODE_CLOUD", ""), ("CI_BUILD_ID", ""),
                             ("CI_WORKSPACE_PATH", "."), ("CI_PRIMARY_REPOSITORY_PATH", str(self.root))]:
            with self.subTest(field=field), patch.dict(os.environ, {field: value}):
                with self.assertRaisesRegex(ValueError, "Cloud context"):
                    sdk.stage_apple_cloud(self.out)
                self.assertFalse((self.out.parent / "RemoteCryptoCloudTools").exists())
        with patch.object(sdk.host_platform, "system", return_value="Linux"):
            with self.assertRaisesRegex(ValueError, "Cloud context"):
                sdk.require_apple_cloud(self.out)
        with self.assertRaises(ValueError):
            sdk.build(self.out, "android")

    def test_cloud_stage_is_bounded_and_persists_only_after_verified_build(self):
        rustup = self.root / "bin/rustup"
        rustup.parent.mkdir(); rustup.touch()
        for name in ("cargo", "rustc"):
            (rustup.parent / name).touch()
        calls = []

        def command(arguments, env, timeout=600):
            calls.append((arguments, env, timeout))

        def build(out, platform, *, environment):
            self.assertEqual((out, platform), (self.out, "apple"))
            self.assertNotIn("GITHUB_ACTIONS", environment)
            self.assertEqual(environment["CI"], "TRUE")
            self.out.mkdir(parents=True)
            (self.out / sdk.RECEIPT).write_text("synthetic receipt")

        with patch.object(sdk.shutil, "which", return_value=str(rustup)), \
                patch.object(sdk.shutil, "disk_usage", return_value=shutil_usage(10)), \
                patch.object(sdk, "run", side_effect=command), patch.object(sdk, "verify") as verify, \
                patch.object(sdk, "build", side_effect=build), \
                patch.object(sdk, "apple_link_contract", return_value={}):
            sdk.stage_apple_cloud(self.out)
        marker = self.checkout / "apple/QuenderinKit" / sdk.APPLE_RELEASE_MARKER
        self.assertEqual(marker.read_text(), sdk.digest(self.out / sdk.RECEIPT) + "\n")
        verify.assert_called_once_with(self.out, "apple")
        self.assertEqual(len(calls), 1)
        self.assertIn("--no-self-update", calls[0][0])
        self.assertIn(",".join(sdk.TARGETS["apple"]), calls[0][0])
        for _, env, _ in calls:
            self.assertEqual(env["CI"], "TRUE")
            self.assertNotIn("GITHUB_ACTIONS", env)
            self.assertEqual(env["CARGO_NET_RETRY"], "0")
            self.assertEqual(env["RUSTUP_MAX_RETRIES"], "0")
        self.assertIsNotNone(sdk.CLOUD_DEADLINE)

    def test_resource_and_compile_failure_never_persist_release_marker(self):
        marker = self.checkout / "apple/QuenderinKit" / sdk.APPLE_RELEASE_MARKER
        with patch.object(sdk.shutil, "disk_usage", return_value=shutil_usage(1)), patch.object(sdk, "run") as run:
            with self.assertRaisesRegex(ValueError, "resource bound"):
                sdk.stage_apple_cloud(self.out)
            run.assert_not_called()
        self.assertFalse(marker.exists())
        rustup = self.root / "rustup"; rustup.touch()
        for name in ("cargo", "rustc"):
            (rustup.parent / name).touch()
        with patch.object(sdk.shutil, "which", return_value=str(rustup)), \
                patch.object(sdk.shutil, "disk_usage", return_value=shutil_usage(10)), \
                patch.object(sdk, "run", side_effect=RuntimeError("synthetic build failure")):
            with self.assertRaises(RuntimeError):
                sdk.stage_apple_cloud(self.out)
        self.assertFalse(marker.exists())

    def test_cloud_timeout_and_disk_failure_stop_the_whole_compiler_process_group(self):
        process = Mock(pid=1234)
        process.poll.return_value = None
        for failure in ("time", "disk"):
            sdk.CLOUD_DEADLINE = 10
            sdk.CLOUD_DISK = (self.root, 10 * 1024 ** 3)
            with self.subTest(failure=failure), patch.object(sdk.subprocess, "Popen", return_value=process), \
                    patch.object(sdk.time, "monotonic", side_effect=[0, 11 if failure == "time" else 1]), \
                    patch.object(sdk.shutil, "disk_usage", return_value=shutil_usage(1)), \
                    patch.object(sdk.os, "killpg") as kill:
                with self.assertRaises((ValueError, sdk.subprocess.TimeoutExpired)):
                    sdk.run(["synthetic-compiler"], self.env)
                kill.assert_called_once_with(1234, sdk.signal.SIGKILL)
                self.assertTrue(process.wait.called)


def shutil_usage(gib):
    return sdk.shutil._ntuple_diskusage(20 * 1024 ** 3, (20 - gib) * 1024 ** 3, gib * 1024 ** 3)


def apple_proof(sources):
    inputs = {target: "e" * 64 for target in sdk.TARGETS["apple"]}
    identity = sdk.apple_proof_identity(sources, inputs)
    return {"schemaVersion": 1, "inputArchives": inputs, "identity": identity, "symbol": "quenderin_remote_sdk_" + identity}


class NativeSDKAppleLinkTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.sdk = Path(self.directory.name) / "kit/build/RemoteCryptoSDK"
        self.headers = self.sdk / ("QuenderinRemoteCryptoFFI.xcframework/ios-arm64/Headers/" + sdk.HEADER)
        self.headers.parent.mkdir(parents=True)
        self.headers.write_text("\n".join("void " + symbol + "(void);" for symbol in sdk.APPLE_LINK_SYMBOLS))
        sources = {"Cargo.lock": "d" * 64}
        (self.sdk / sdk.RECEIPT).write_text(json.dumps({"sources": sources, "appleLinkProof": apple_proof(sources)}))
        mock = patch.object(sdk, "verify")
        self.verify = mock.start(); self.addCleanup(mock.stop)

    def test_verified_receipt_controls_forced_real_exports_and_archive_proof(self):
        contract = sdk.apple_link_contract(self.sdk)
        receipt = json.loads((self.sdk / sdk.RECEIPT).read_text())
        self.assertEqual(contract["proofSymbol"], "_" + receipt["appleLinkProof"]["symbol"])
        flags = sdk.apple_link_settings(self.sdk)
        for symbol in contract["symbols"]:
            self.assertIn(symbol, flags)
        self.assertEqual(flags.count("-u"), len(sdk.APPLE_LINK_SYMBOLS) + 1)
        self.assertNotIn("-alias", flags)
        self.assertIn(contract["proofSymbol"], flags)
        self.verify.assert_called_with(self.sdk, "apple")

    def test_missing_real_abi_or_stale_release_marker_fails(self):
        valid = self.headers.read_text()
        self.headers.write_text("")
        with self.assertRaisesRegex(ValueError, "entry points"):
            sdk.apple_link_contract(self.sdk)
        self.headers.write_text(valid)
        marker = self.sdk.parent.parent / sdk.APPLE_RELEASE_MARKER
        marker.write_text("0" * 64 + "\n")
        with self.assertRaisesRegex(ValueError, "receipt is stale"):
            sdk.apple_link_contract(self.sdk)
        marker.write_text(sdk.digest(self.sdk / sdk.RECEIPT) + "\n")
        sdk.apple_link_contract(self.sdk)

    def test_unique_proof_is_compiled_into_each_actual_archive_and_references_real_crypto(self):
        work = Path(self.directory.name) / "work"
        for target in sdk.TARGETS["apple"]:
            archive = work / "target" / target / "release/libquenderin_remote_crypto.a"
            archive.parent.mkdir(parents=True)
            archive.write_bytes(("synthetic original " + target).encode())
        with patch.object(sdk, "run") as run:
            proof = sdk.add_apple_archive_proof(work, {})
        self.assertEqual(len(run.call_args_list), 10)
        self.assertEqual(set(proof["inputArchives"]), set(sdk.TARGETS["apple"]))
        self.assertEqual(proof["identity"], sdk.apple_proof_identity(sdk.source_hashes(), proof["inputArchives"]))
        source = (work / "sdk-link-proof.c").read_text()
        self.assertIn(proof["symbol"], source)
        self.assertIn("&" + sdk.APPLE_LINK_SYMBOLS[0], source)
        for index in range(0, 10, 2):
            compile_command = run.call_args_list[index].args[0]
            self.assertEqual(compile_command[:2], ["xcrun", "clang"])
            self.assertIn("-target", compile_command)
            self.assertEqual(run.call_args_list[index + 1].args[0][:4], ["xcrun", "ar", "-r", "-s"])


class NativeSDKAppleReceiptTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.sdk = Path(self.directory.name) / "sdk"
        framework = self.sdk / "QuenderinRemoteCryptoFFI.xcframework"
        framework.mkdir(parents=True)
        self.sources = {"Cargo.lock": "a" * 64, "tools/native_sdk.py": "b" * 64}
        mock = patch.object(sdk, "source_hashes", return_value=self.sources)
        mock.start(); self.addCleanup(mock.stop)
        libs = []
        for identifier, platform, variant, architectures in [
            ("ios-arm64", "ios", None, ["arm64"]),
            ("ios-arm64_x86_64-simulator", "ios", "simulator", ["arm64", "x86_64"]),
            ("macos-arm64_x86_64", "macos", None, ["arm64", "x86_64"])]:
            directory = framework / identifier
            (directory / "Headers").mkdir(parents=True)
            (directory / "Headers" / sdk.HEADER).write_text("synthetic ABI")
            (directory / "Headers/module.modulemap").write_text("synthetic module map")
            (directory / "libquenderin_remote_crypto.a").write_bytes(b"synthetic locked archive")
            lib = {"LibraryIdentifier": identifier, "LibraryPath": "libquenderin_remote_crypto.a", "HeadersPath": "Headers",
                   "SupportedPlatform": platform, "SupportedArchitectures": architectures}
            if variant: lib["SupportedPlatformVariant"] = variant
            libs.append(lib)
        (framework / "Info.plist").write_bytes(plistlib.dumps({"AvailableLibraries": libs}))
        bindings = self.sdk / "Bindings" / sdk.MODULEMAP
        bindings.parent.mkdir(); bindings.write_text("synthetic module map")
        wrapper = self.sdk / "Sources/QuenderinRemoteCrypto" / sdk.SWIFT
        wrapper.parent.mkdir(parents=True); wrapper.write_text("synthetic Swift wrapper")
        self.receipt = {"schemaVersion": 1, "platform": "apple", "rust": "1.90.0", "targets": sdk.TARGETS["apple"],
                        "sources": self.sources, "files": sdk.files(self.sdk), "deploymentTargets": {"iOS": "16.4", "macOS": "13.3"},
                        "appleLinkProof": apple_proof(self.sources)}
        (self.sdk / sdk.RECEIPT).write_text(json.dumps(self.receipt))

    def test_exact_apple_receipt_accepts_all_five_target_slices(self):
        sdk.verify(self.sdk, "apple")

    def test_missing_receipt_and_library_and_tampered_archive_fail(self):
        receipt_path = self.sdk / sdk.RECEIPT
        receipt_path.unlink()
        with self.assertRaises(FileNotFoundError): sdk.verify(self.sdk, "apple")
        receipt_path.write_text(json.dumps(self.receipt))
        library = self.sdk / "QuenderinRemoteCryptoFFI.xcframework/ios-arm64/libquenderin_remote_crypto.a"
        library.write_bytes(b"tampered archive")
        with self.assertRaisesRegex(ValueError, "receipt is stale"): sdk.verify(self.sdk, "apple")
        library.unlink()
        with self.assertRaisesRegex(ValueError, "receipt is stale"): sdk.verify(self.sdk, "apple")

    def test_source_and_target_drift_rejected_even_with_unchanged_bytes(self):
        receipt_path = self.sdk / sdk.RECEIPT
        for field, value in [("sources", {"Cargo.lock": "c" * 64}), ("targets", sdk.TARGETS["apple"][:-1])]:
            with self.subTest(field=field):
                receipt_path.write_text(json.dumps(dict(self.receipt, **{field: value})))
                with self.assertRaisesRegex(ValueError, "receipt is stale"): sdk.verify(self.sdk, "apple")

    def test_missing_and_tampered_static_archive_proof_cannot_authorize_linkage(self):
        for proof in (None, {}, dict(self.receipt["appleLinkProof"], symbol="quenderin_remote_sdk_stale")):
            with self.subTest(proof=proof):
                receipt = dict(self.receipt, appleLinkProof=proof)
                (self.sdk / sdk.RECEIPT).write_text(json.dumps(receipt))
                with self.assertRaisesRegex(ValueError, "archive link proof"):
                    sdk.verify(self.sdk, "apple")


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

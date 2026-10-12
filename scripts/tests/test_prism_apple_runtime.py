"""Small generated Mach-O fixtures verify guards without downloading/building a runtime."""
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import shutil
import struct
import subprocess
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("apple_prism", Path(__file__).resolve().parents[1] / "verify_prism_apple_runtime.py")
prism = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(prism)


def thin(arch, target, code=b"verified-prism-code", signed=False, executable=False):
    cpu = {"arm64": 0x0100000C, "x86_64": 0x01000007}[arch]
    commands_size = 152 + 24 + 24 + (16 if signed else 0)
    offset = 32 + commands_size
    segment = struct.pack("<II16sQQQQiiII", 0x19, 152, b"__TEXT", 0, len(code), offset, len(code), 7, 5, 1, 0)
    section = struct.pack("<16s16sQQIIIIIIII", b"__text", b"__TEXT", 0, len(code), offset, 0, 0, 0, 0x80000400, 0, 0, 0)
    uuid = struct.pack("<II16s", 0x1B, 24, bytes([target]) * 16)
    minimum = (13 << 16 | 3 << 8) if target == 1 else (16 << 16 | 4 << 8)
    build = struct.pack("<IIIIII", 0x32, 24, target, minimum, minimum, 0)
    signature = struct.pack("<IIII", 0x1D, 16, offset + len(code), 9) if signed else b""
    header = struct.pack("<IIIIIIII", 0xFEEDFACF, cpu, 0, 2 if executable else 6, 4 if signed else 3, commands_size, 0, 0)
    return header + segment + section + uuid + build + signature + code + (b"signature" if signed else b"")


def fat(target, **kwargs):
    arm, intel = thin("arm64", target, **kwargs), thin("x86_64", target, **kwargs)
    offset = 8 + 2 * 20
    return struct.pack(">II", 0xCAFEBABE, 2) + struct.pack(">IIIII", 0x0100000C, 0, offset, len(arm), 0) + struct.pack(">IIIII", 0x01000007, 0, offset + len(arm), len(intel), 0) + arm + intel


class ApplePrismTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(prefix="apple-prism-test-")
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name)
        for rel in ("shared", "apple/QuenderinKit/Sources/QuenderinKit"):
            (self.root / rel).mkdir(parents=True)
        for rel in ("shared/prism-runtime.json", "shared/model-catalog.json", "apple/QuenderinKit/Sources/QuenderinKit/ModelCatalog.swift"):
            shutil.copyfile(prism.ROOT / rel, self.root / rel)
        self.framework = self.root / "prism-llama.xcframework"
        self.framework.mkdir()
        self.lock = json.loads((self.root / "shared/prism-runtime.json").read_text())
        (self.framework / "quenderin-prism-runtime.json").write_text(json.dumps({k: self.lock[k] for k in ("repository", "revision")}))
        libs = []
        for identifier, target in (("ios-arm64", 2), ("macos-arm64_x86_64", 1)):
            native = self.framework / identifier / "llama.framework"
            (native / "Headers").mkdir(parents=True)
            (native / "Headers/ggml.h").write_text("GGML_TYPE_PQ2_0 GGML_TYPE_PTQ1_0")
            binary_rel = "llama.framework/Versions/A/llama" if target == 1 else "llama.framework/llama"
            binary = self.framework / identifier / binary_rel
            binary.parent.mkdir(parents=True, exist_ok=True)
            binary.write_bytes(fat(target) if target == 1 else thin("arm64", target))
            libs.append({"LibraryIdentifier": identifier, "LibraryPath": "llama.framework", "BinaryPath": binary_rel,
                         "SupportedArchitectures": ["arm64", "x86_64"] if target == 1 else ["arm64"],
                         "SupportedPlatform": "macos" if target == 1 else "ios"})
        (self.framework / "Info.plist").write_bytes(plistlib.dumps({"AvailableLibraries": libs}))

    def seal(self):
        with patch.object(prism, "native_probe", return_value=prism.PROBE):
            return prism.seal(self.framework, self.root)

    def app(self, target):
        app = self.root / "Quenderin.app"
        contents = app / "Contents" if target == "macos" else app
        contents.mkdir(parents=True)
        info = {"CFBundleIdentifier": "ai.quenderin.Quenderin", "CFBundleVersion": "12", "CFBundleShortVersionString": "0.3.0", "CFBundleExecutable": "Quenderin"}
        (contents / "Info.plist").write_bytes(plistlib.dumps(info))
        identifier = "macos-arm64_x86_64" if target == "macos" else "ios-arm64"
        native = contents / "Frameworks/llama.framework"
        shutil.copytree(self.framework / identifier / "llama.framework", native)
        executable = contents / ("MacOS/Quenderin" if target == "macos" else "Quenderin")
        executable.parent.mkdir(exist_ok=True)
        executable.write_bytes(fat(1, executable=True) if target == "macos" else thin("arm64", 2, executable=True))
        return app, contents, native

    def tool(self, *args):
        if args[:3] == ("xcrun", "otool", "-L"):
            return "@rpath/llama.framework/llama"
        if args[:2] == ("codesign", "-d"):
            return "Authority=Apple Distribution\nTeamIdentifier=9M2B2P4KSA"
        return ""

    def test_seal_requires_positive_native_probe_and_verified_artifact(self):
        with patch.object(prism, "native_probe", side_effect=ValueError("stock native types")):
            with self.assertRaisesRegex(ValueError, "stock native types"):
                prism.seal(self.framework, self.root)
        self.assertFalse((self.framework / prism.STAMP).exists())
        stamp = self.seal()
        self.assertEqual(stamp["nativeProbe"], prism.PROBE)
        self.assertEqual(prism.verify_framework(self.framework, self.root), stamp)
        with self.assertRaisesRegex(ValueError, "Preserve"):
            prism.seal(self.framework, self.root)

    def test_unsigned_payload_survives_signature_but_not_code_tamper(self):
        binary = self.root / "binary"
        binary.write_bytes(fat(1))
        expected = prism.macho_payload(binary)
        binary.write_bytes(fat(1, signed=True))
        self.assertEqual(prism.macho_payload(binary), expected)
        binary.write_bytes(fat(1, signed=True, code=b"tampered-prism-code"))
        self.assertNotEqual(prism.macho_payload(binary), expected)

    def test_slice_rejects_platform_mismatch_and_missing_device(self):
        info = plistlib.loads((self.framework / "Info.plist").read_bytes())
        info["AvailableLibraries"][0]["SupportedPlatformVariant"] = "simulator"
        (self.framework / "Info.plist").write_bytes(plistlib.dumps(info))
        with self.assertRaisesRegex(ValueError, "platform"):
            prism.slices(self.framework)
        info["AvailableLibraries"] = info["AvailableLibraries"][1:]
        (self.framework / "Info.plist").write_bytes(plistlib.dumps(info))
        with self.assertRaisesRegex(ValueError, "iOS device"):
            prism.slices(self.framework)

    def test_framework_rejects_wrong_pin_missing_stamp_and_tamper(self):
        with self.assertRaises(FileNotFoundError):
            prism.verify_framework(self.framework, self.root)
        self.seal()
        provenance = self.framework / "quenderin-prism-runtime.json"
        valid = provenance.read_text()
        provenance.write_text(json.dumps({"repository": self.lock["repository"], "revision": "stock"}))
        with self.assertRaisesRegex(ValueError, "provenance"):
            prism.verify_framework(self.framework, self.root)
        provenance.write_text(valid)
        (self.framework / "ios-arm64/llama.framework/llama").write_bytes(thin("arm64", 2, code=b"stock"))
        with self.assertRaisesRegex(ValueError, "files changed"):
            prism.verify_framework(self.framework, self.root)

    def test_catalog_revision_and_native_identity_cannot_drift(self):
        self.seal()
        source = self.root / "apple/QuenderinKit/Sources/QuenderinKit/ModelCatalog.swift"
        source.write_text(source.read_text().replace(self.lock["sha256"], "wrong"))
        with self.assertRaisesRegex(ValueError, "catalogs differ"):
            prism.verify_framework(self.framework, self.root)

    def test_explicit_release_profile_rejects_stock_and_source_fallback(self):
        marker = self.root / "apple/QuenderinKit" / prism.RELEASE_MARKER
        with patch.dict(os.environ, {"QUENDERIN_RUNTIME": "prism", "QUENDERIN_LLAMA_DIR": ""}):
            with self.assertRaises(FileNotFoundError):
                prism.release_profile(self.root)
            marker.write_text("prism\n")
            prism.release_profile(self.root)
            with patch.dict(os.environ, {"QUENDERIN_RUNTIME": "standard"}):
                with self.assertRaisesRegex(ValueError, "QUENDERIN_RUNTIME"):
                    prism.release_profile(self.root)
            with patch.dict(os.environ, {"QUENDERIN_LLAMA_DIR": "/stock"}):
                with self.assertRaisesRegex(ValueError, "cross-platform"):
                    prism.release_profile(self.root)

    def test_signed_ios_archive_matches_verified_slice_and_embedded_catalog(self):
        stamp = self.seal()
        app, contents, native = self.app("ios")
        with patch.object(prism, "run", side_effect=self.tool):
            prism.verify_app(app, "ios", stamp, self.root)
            (native / "llama").write_bytes(thin("arm64", 2, signed=True))
            result = prism.verify_app(app, "ios", stamp, self.root, signed=True)
            self.assertEqual(result["architectures"], ["arm64"])
            (contents / "quenderin-model-catalog.json").write_text("{}")
            with self.assertRaisesRegex(ValueError, "Archive catalog"):
                prism.verify_app(app, "ios", stamp, self.root, signed=True)

    def test_signed_mac_archive_probes_archived_binary_using_verified_source_headers(self):
        stamp = self.seal()
        app, contents, native = self.app("macos")
        with patch.object(prism, "run", side_effect=self.tool):
            prism.verify_app(app, "macos", stamp, self.root)
            # Xcode strips public headers from an embedded framework. The native
            # probe must link the archived dylib while using the verified headers.
            (native / "Headers/ggml.h").unlink()
            (native / "Headers").rmdir()
            (native / "Versions/A/llama").write_bytes(fat(1, signed=True))
            with patch.object(prism, "native_probe", return_value=prism.PROBE) as probe:
                result = prism.verify_app(app, "macos", stamp, self.root, signed=True, source_framework=self.framework)
                self.assertEqual(result["architectures"], ["arm64", "x86_64"])
                probe.assert_called_once_with(native, self.framework / "macos-arm64_x86_64/llama.framework/Headers")

    def test_archive_rejects_unlinked_runtime_and_wrong_app_identity(self):
        stamp = self.seal()
        app, contents, native = self.app("ios")
        with patch.object(prism, "run", return_value="@rpath/stock.framework/stock"):
            with self.assertRaisesRegex(ValueError, "does not link"):
                prism.verify_app(app, "ios", stamp, self.root)
        info_path = contents / "Info.plist"
        info = plistlib.loads(info_path.read_bytes())
        info["CFBundleIdentifier"] = "wrong.app"
        info_path.write_bytes(plistlib.dumps(info))
        with self.assertRaisesRegex(ValueError, "bundle identifier"):
            prism.verify_app(app, "ios", stamp, self.root)

    def test_archive_rejects_missing_runtime_wrong_version_adhoc_and_tamper(self):
        stamp = self.seal()
        app, contents, native = self.app("ios")
        with patch.object(prism, "run", side_effect=self.tool):
            prism.verify_app(app, "ios", stamp, self.root)
            info_path = contents / "Info.plist"
            info = plistlib.loads(info_path.read_bytes())
            info["CFBundleVersion"] = "11"
            info_path.write_bytes(plistlib.dumps(info))
            with self.assertRaisesRegex(ValueError, "build counter"):
                prism.verify_app(app, "ios", stamp, self.root, signed=True)
            info["CFBundleVersion"] = "12"
            info_path.write_bytes(plistlib.dumps(info))
            with patch.object(prism, "run", side_effect=lambda *a: "Signature=adhoc\nTeamIdentifier=9M2B2P4KSA" if a[:2] == ("codesign", "-d") else self.tool(*a)):
                with self.assertRaisesRegex(ValueError, "signature"):
                    prism.verify_app(app, "ios", stamp, self.root, signed=True)
            (native / "llama").write_bytes(thin("arm64", 2, code=b"stock runtime"))
            with self.assertRaisesRegex(ValueError, "binary payload"):
                prism.verify_app(app, "ios", stamp, self.root, signed=True)
            (native / "llama").unlink()
            with self.assertRaises(FileNotFoundError):
                prism.verify_app(app, "ios", stamp, self.root, signed=True)

    def test_cloud_pre_clone_rejects_missing_explicit_profile_before_mutation(self):
        script = prism.ROOT / "apple/QuenderinApp/ci_scripts/ci_post_clone.sh"
        env = os.environ | {"CI": "TRUE", "QUENDERIN_RUNTIME": "standard", "CI_PRIMARY_REPOSITORY_PATH": str(prism.ROOT)}
        result = subprocess.run(["bash", str(script)], env=env, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("explicit QUENDERIN_RUNTIME=prism", result.stderr)


    def test_all_cloud_hooks_reject_missing_relative_and_wrong_repository_paths(self):
        scripts = prism.ROOT / "apple/QuenderinApp/ci_scripts"
        for name in ("ci_post_clone.sh", "ci_pre_xcodebuild.sh", "ci_post_xcodebuild.sh"):
            for path in ("", ".", str(self.root / "missing"), str(self.root)):
                with self.subTest(hook=name, repository=path):
                    env = os.environ | {"CI": "TRUE", "QUENDERIN_RUNTIME": "prism", "CI_XCODEBUILD_ACTION": "archive",
                                        "CI_PRIMARY_REPOSITORY_PATH": path}
                    result = subprocess.run(["bash", str(scripts / name)], env=env, capture_output=True, text=True)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("CI_PRIMARY_REPOSITORY_PATH", result.stderr)

    def test_isolated_cloud_hooks_use_the_explicit_repository_path(self):
        isolated = self.root / "isolated_ci_scripts"
        isolated.mkdir()
        source = prism.ROOT / "apple/QuenderinApp/ci_scripts"
        for script in source.glob("ci_*.sh"):
            shutil.copyfile(script, isolated / script.name)
        (self.root / "scripts").mkdir()
        (self.root / "apple/QuenderinApp").mkdir()
        (self.root / "apple/QuenderinKit/Package.swift").write_text("// fixture package")
        (self.root / "apple/QuenderinApp/project.yml").write_text("name: Fixture")
        (self.root / "scripts/verify_prism_apple_runtime.py").write_text("import sys; print('REPOSITORY_VERIFIER', ' '.join(sys.argv[1:]))")
        (self.root / "apple/QuenderinKit/.quenderin-prism-release").write_text("prism\n")
        env = os.environ | {"CI": "TRUE", "QUENDERIN_RUNTIME": "prism", "QUENDERIN_LLAMA_DIR": "",
                            "CI_PRIMARY_REPOSITORY_PATH": str(self.root), "CI_XCODEBUILD_ACTION": "archive",
                            "CI_XCODEBUILD_EXIT_CODE": "0", "CI_PRODUCT_PLATFORM": "iOS", "CI_ARCHIVE_PATH": str(self.root / "fixture.xcarchive")}
        clone = subprocess.run(["bash", str(isolated / "ci_post_clone.sh")], cwd=isolated,
                               env=env | {"QUENDERIN_RUNTIME": "standard"}, capture_output=True, text=True)
        self.assertNotEqual(clone.returncode, 0)
        self.assertIn("explicit QUENDERIN_RUNTIME=prism", clone.stderr)
        for name, command in (("ci_pre_xcodebuild.sh", "verify-framework"), ("ci_post_xcodebuild.sh", "verify-archive")):
            with self.subTest(hook=name):
                result = subprocess.run(["bash", str(isolated / name)], cwd=isolated, env=env, capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("REPOSITORY_VERIFIER " + command, result.stdout)


if __name__ == "__main__":
    unittest.main()

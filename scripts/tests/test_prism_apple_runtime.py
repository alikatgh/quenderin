"""Small generated Mach-O fixtures verify guards without downloading/building a runtime."""
import importlib.util
import gzip
import io
import json
import os
from pathlib import Path
import plistlib
import shutil
import stat
import struct
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import xml.etree.ElementTree as ET
import zipfile
import zlib

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


def cpio_fixture(entries):
    data = bytearray()
    for inode, (name, mode, content) in enumerate(entries + [("TRAILER!!!", 0, b"")]):
        name = name.encode() + b"\0"
        fields = ("070707", f"{0:06o}", f"{inode:06o}", f"{mode:06o}", f"{0:06o}",
                  f"{0:06o}", f"{1:06o}", f"{0:06o}", f"{0:011o}", f"{len(name):06o}", f"{len(content):011o}")
        data.extend("".join(fields).encode() + name + content)
    return gzip.compress(bytes(data))


def pkg_fixture(path, entries, second_payload=False):
    payload = cpio_fixture(entries)
    xar = ET.Element("xar")
    toc = ET.SubElement(xar, "toc")
    for name in (["Quenderin.pkg", "Other.pkg"] if second_payload else ["Quenderin.pkg"]):
        component = ET.SubElement(toc, "file")
        ET.SubElement(component, "name").text = name
        ET.SubElement(component, "type").text = "directory"
        file = ET.SubElement(component, "file")
        ET.SubElement(file, "name").text = "Payload"
        ET.SubElement(file, "type").text = "file"
        data = ET.SubElement(file, "data")
        for key, value in (("offset", 0), ("length", len(payload)), ("size", len(payload))):
            ET.SubElement(data, key).text = str(value)
        ET.SubElement(data, "encoding", style="application/octet-stream")
    xml = ET.tostring(xar)
    compressed = zlib.compress(xml)
    path.write_bytes(struct.pack(">4sHHQQI", b"xar!", 28, 1, len(compressed), len(xml), 0) + compressed + payload)
    return path


class ApplePrismTests(unittest.TestCase):
    def setUp(self):
        # Image artifact guards have their own real Mach-O fixture suite. Keep
        # text/source-recovery fixtures independent of that second framework.
        for name in ('embed_image_evidence', 'verify_image_app'):
            mock = patch.object(prism, name, return_value={})
            mock.start(); self.addCleanup(mock.stop)
        self.scratch = tempfile.TemporaryDirectory(prefix="apple-prism-test-")
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name)
        for rel in ("shared", "apple/QuenderinKit/Sources/QuenderinKit", "apple/QuenderinApp"):
            (self.root / rel).mkdir(parents=True)
        (self.root / "apple/QuenderinApp/project.yml").write_text('''targets:
  Quenderin:
    settings:
      base:
        MARKETING_VERSION: "0.4.0"
        CURRENT_PROJECT_VERSION: 16
  QuenderinMac:
    settings:
      base:
        MARKETING_VERSION: "0.4.0"
        CURRENT_PROJECT_VERSION: 16
''')
        for rel in ("shared/prism-runtime.json", "shared/model-catalog.json", "apple/QuenderinKit/Sources/QuenderinKit/ModelCatalog.swift"):
            shutil.copyfile(prism.ROOT / rel, self.root / rel)
        self.framework = self.root / "prism-llama.xcframework"
        self.framework.mkdir()
        self.lock = json.loads((self.root / "shared/prism-runtime.json").read_text())
        for key in ("sourcePatch", "weeklyTextPatch", "beamPatch", "visionPatch", "graniteConverterPatch"):
            if key not in self.lock: continue
            patch_path = self.root / self.lock[key]["path"]
            patch_path.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(prism.ROOT / self.lock[key]["path"], patch_path)
        self.identity = prism.source_runtime.provenance(self.root, self.lock)
        (self.framework / "quenderin-prism-runtime.json").write_text(json.dumps(self.identity))
        libs = []
        for identifier, target in (("ios-arm64", 2), ("macos-arm64_x86_64", 1)):
            native = self.framework / identifier / "llama.framework"
            (native / "Headers").mkdir(parents=True)
            (native / "Headers/ggml.h").write_text("GGML_TYPE_PQ2_0 GGML_TYPE_PTQ1_0")
            (native / "Headers/llama.h").write_text("int quenderin_muse_spark_runtime_abi(void); int quenderin_weekly_text_runtime_abi(void); int quenderin_beam_runtime_abi(void);")
            (native / "Headers/quenderin_vision.h").write_text("unsigned quenderin_vision_runtime_abi(void);")
            binary_rel = "llama.framework/Versions/A/llama" if target == 1 else "llama.framework/llama"
            binary = self.framework / identifier / binary_rel
            binary.parent.mkdir(parents=True, exist_ok=True)
            binary.write_bytes(fat(target) if target == 1 else thin("arm64", target))
            libs.append({"LibraryIdentifier": identifier, "LibraryPath": "llama.framework", "BinaryPath": binary_rel,
                         "SupportedArchitectures": ["arm64", "x86_64"] if target == 1 else ["arm64"],
                         "SupportedPlatform": "macos" if target == 1 else "ios"})
        (self.framework / "Info.plist").write_bytes(plistlib.dumps({"AvailableLibraries": libs}))
        actual_run = prism.run
        native_tools = patch.object(prism, "run", side_effect=lambda *args:
                                    self.tool(*args) if args[:2] == ("xcrun", "nm") else actual_run(*args))
        native_tools.start()
        self.addCleanup(native_tools.stop)

    def seal(self):
        with patch.object(prism, "native_probe", return_value=prism.PROBE):
            return prism.seal(self.framework, self.root)

    def app(self, target):
        app = self.root / "Quenderin.app"
        contents = app / "Contents" if target == "macos" else app
        contents.mkdir(parents=True)
        info = {"CFBundleIdentifier": "ai.quenderin.Quenderin", "CFBundleVersion": "16", "CFBundleShortVersionString": "0.4.0", "CFBundleExecutable": "Quenderin"}
        (contents / "Info.plist").write_bytes(plistlib.dumps(info))
        identifier = "macos-arm64_x86_64" if target == "macos" else "ios-arm64"
        native = contents / "Frameworks/llama.framework"
        shutil.copytree(self.framework / identifier / "llama.framework", native)
        executable = contents / ("MacOS/Quenderin" if target == "macos" else "Quenderin")
        executable.parent.mkdir(exist_ok=True)
        executable.write_bytes(fat(1, executable=True) if target == "macos" else thin("arm64", 2, executable=True))
        return app, contents, native

    def tool(self, *args):
        if args[:2] == ("xcrun", "nm"):
            return "0000000000000100 T _quenderin_muse_spark_runtime_abi\n0000000000000120 T _quenderin_weekly_text_runtime_abi\n0000000000000140 T _quenderin_beam_runtime_abi\n" + "\n".join("0000000000000200 T _quenderin_vision_" + symbol for symbol in ("runtime_abi", "runtime_revision", "patch_sha256", "create", "load", "generate", "cancel", "free"))
        if args[:3] == ("xcrun", "otool", "-L"):
            return "@rpath/llama.framework/llama"
        if args[:2] == ("codesign", "-d"):
            return "Authority=Apple Distribution\nTeamIdentifier=9M2B2P4KSA"
        if args[:2] == ("pkgutil", "--check-signature"):
            return ("Status: signed by a developer certificate issued by Apple (Development)\nCertificate Chain:\n"
                    "    1. 3rd Party Mac Developer Installer: Fixture (9M2B2P4KSA)\n"
                    "    2. Apple Worldwide Developer Relations Certification Authority\n    3. Apple Root CA")
        return ""

    def ipa(self, app, extra=()):
        path = self.root / "Quenderin.ipa"
        with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as package:
            for file in sorted(app.rglob("*")):
                if file.is_file():
                    package.write(file, "Payload/Quenderin.app/" + file.relative_to(app).as_posix())
            for name, data in extra:
                package.writestr(name, data)
        return path

    def packaged_app(self, target):
        stamp = self.seal()
        app, contents, native = self.app(target)
        prism.embed_evidence(app, target, stamp, self.root)
        return stamp, app, contents, native

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

    def test_same_base_revision_without_muse_patch_identity_is_rejected(self):
        provenance = self.framework / "quenderin-prism-runtime.json"
        provenance.write_text(json.dumps({k: self.lock[k] for k in ("repository", "revision")}))
        with self.assertRaisesRegex(ValueError, "source provenance"):
            self.seal()
        self.assertFalse((self.framework / prism.STAMP).exists())
        provenance.write_text(json.dumps(self.identity))
        self.seal()
        changed = dict(self.identity, sourcePatchSha256="0" * 64)
        provenance.write_text(json.dumps(changed))
        with self.assertRaisesRegex(ValueError, "provenance"):
            prism.verify_framework(self.framework, self.root)

    def test_each_native_slice_must_export_muse_capability(self):
        with patch.object(prism, "run", return_value=""):
            with self.assertRaisesRegex(ValueError, "capability symbol"):
                prism.slices(self.framework)

    def test_probe_cannot_accept_old_ternary_only_success(self):
        native = self.framework / "macos-arm64_x86_64/llama.framework"
        calls = []

        def old_runtime(*args):
            calls.append(args)
            if args[:2] == ("xcrun", "--sdk"):
                source = Path(args[args.index("-F") - 1]).read_text()
                self.assertIn("quenderin_muse_spark_runtime_abi() != 1", source)
                return ""
            return "Prism PQ2_0=142/128/34 PTQ1_0=143/128/28 verified"

        with patch.object(prism, "run", side_effect=old_runtime):
            with self.assertRaisesRegex(ValueError, "Prism/Muse/weekly text probe failed"):
                prism.native_probe(native)
        self.assertEqual(len(calls), 2)

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
            prism.verify_image_app.assert_called_with(app, 'ios', self.root, True)
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
            (native / "Headers/llama.h").unlink()
            (native / "Headers/quenderin_vision.h").unlink()
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

    def test_archive_version_matches_source_and_accepts_cloud_build_counter(self):
        stamp = self.seal()
        for target in ("ios", "macos"):
            with self.subTest(platform=target):
                app, contents, _ = self.app(target)
                info_path = contents / "Info.plist"
                info = plistlib.loads(info_path.read_bytes())
                info["CFBundleVersion"] = "17"
                info_path.write_bytes(plistlib.dumps(info))
                with patch.object(prism, "run", side_effect=self.tool):
                    result = prism.verify_app(app, target, stamp, self.root)
                self.assertEqual((result["version"], result["build"]), ("0.4.0", "17"))
                for version, build in (("0.3.0", "17"), ("0.5.0", "18"), ("0.4.0", "15")):
                    info.update(CFBundleShortVersionString=version, CFBundleVersion=build)
                    info_path.write_bytes(plistlib.dumps(info))
                    with self.assertRaisesRegex(ValueError, "expected 0.4.0 with build >= 16"):
                        prism.verify_app(app, target, stamp, self.root, signed=True)

    def test_release_version_follows_source_and_rejects_mismatched_targets(self):
        spec = self.root / "apple/QuenderinApp/project.yml"
        original = spec.read_text()
        spec.write_text(original.replace('"0.4.0"', '"0.5.0"').replace("VERSION: 16", "VERSION: 18"))
        self.assertEqual(prism.release_version(self.root), ("0.5.0", 18))
        for drift in (original.replace('"0.4.0"', '"0.5.0"', 1),
                      original.replace("VERSION: 16", "VERSION: 18", 1),
                      original.replace("CURRENT_PROJECT_VERSION: 16", "CURRENT_PROJECT_VERSION: invalid", 1)):
            with self.subTest(spec=drift):
                spec.write_text(drift)
                with self.assertRaisesRegex(ValueError, "matching release versions"):
                    prism.release_version(self.root)

    def test_archive_rejects_missing_runtime_wrong_version_adhoc_and_tamper(self):
        stamp = self.seal()
        app, contents, native = self.app("ios")
        with patch.object(prism, "run", side_effect=self.tool):
            prism.verify_app(app, "ios", stamp, self.root)
            info_path = contents / "Info.plist"
            info = plistlib.loads(info_path.read_bytes())
            info["CFBundleVersion"] = "15"
            info_path.write_bytes(plistlib.dumps(info))
            with self.assertRaisesRegex(ValueError, "build counter"):
                prism.verify_app(app, "ios", stamp, self.root, signed=True)
            info["CFBundleVersion"] = "16"
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

    def test_signed_ipa_export_uses_strict_app_checks_and_cleans_scratch(self):
        stamp, app, contents, native = self.packaged_app("ios")
        (native / "llama").write_bytes(thin("arm64", 2, signed=True))
        package = self.ipa(app, [("Signatures/", b""), ("Signatures/prism-llama.xcframework-ios.signature", b"framework-signature")])
        export = self.root / "appstoreexport"
        export.mkdir()
        package = package.rename(export / package.name)
        digest = prism.sha(package)
        (export / "ExportOptions.plist").write_bytes(plistlib.dumps({"method": "app-store-connect"}))
        with patch.object(prism, "run", side_effect=self.tool), patch.object(prism, "verify_app", wraps=prism.verify_app) as verify:
            result = prism.verify_distribution(export, "ios", stamp, self.root, self.framework)
            self.assertEqual(result["build"], "16")
            self.assertTrue(verify.call_args.kwargs["signed"])
            extracted = verify.call_args.args[0]
        self.assertFalse(extracted.exists())
        self.assertEqual(prism.sha(package), digest)
        self.assertTrue(app.is_dir())

    def test_signed_mac_pkg_export_preserves_internal_framework_links_and_probes_export(self):
        stamp, app, contents, native = self.packaged_app("macos")
        (native / "Versions/Current").symlink_to("A")
        (native / "llama").symlink_to("Versions/Current/llama")
        entries = [(".", stat.S_IFDIR | 0o755, b""), ("Quenderin.app", stat.S_IFDIR | 0o755, b"")]
        for path in sorted(app.rglob("*")):
            mode = path.lstat().st_mode
            data = os.readlink(path).encode() if path.is_symlink() else (path.read_bytes() if path.is_file() else b"")
            entries.append(("./Quenderin.app/" + path.relative_to(app).as_posix(), mode, data))
        package = pkg_fixture(self.root / "Quenderin.pkg", entries)
        digest = prism.sha(package)
        with patch.object(prism, "run", side_effect=self.tool) as tool, patch.object(prism, "native_probe", return_value=prism.PROBE) as probe:
            result = prism.verify_distribution(package, "macos", stamp, self.root, self.framework)
            self.assertEqual(tool.call_args_list[0].args, ("pkgutil", "--check-signature", str(package)))
            self.assertEqual(result["architectures"], ["arm64", "x86_64"])
            extracted_framework = probe.call_args.args[0]
            self.assertNotEqual(extracted_framework, native)
            self.assertEqual(probe.call_args.args[1], self.framework / "macos-arm64_x86_64/llama.framework/Headers")
        self.assertFalse(extracted_framework.exists())
        self.assertEqual(prism.sha(package), digest)
        self.assertTrue((native / "llama").is_symlink())

    def test_cli_distribution_and_legacy_archive_both_keep_signed_release_checks(self):
        stamp, app, _, _ = self.packaged_app("ios")
        package = self.ipa(app)
        archive = self.root / "Quenderin.xcarchive"
        archived_app = archive / "Products/Applications/Quenderin.app"
        archived_app.parent.mkdir(parents=True)
        shutil.copytree(app, archived_app)
        for command, flag, path in (("verify-distribution", "--distribution", package),
                                    ("verify-archive", "--archive", archive)):
            with self.subTest(command=command), patch.object(prism, "verify_framework", return_value=stamp) as framework, \
                    patch.object(prism, "release_profile") as profile, patch.object(prism, "run", side_effect=self.tool), \
                    patch.object(prism, "verify_app", wraps=prism.verify_app) as verify, patch("sys.stdout", new_callable=io.StringIO) as output, \
                    patch("sys.argv", ["verify_prism_apple_runtime.py", command, flag, str(path), "--platform", "ios", "--framework", str(self.framework)]):
                prism.main()
                self.assertEqual(json.loads(output.getvalue())["runtimeRevision"], self.lock["revision"])
                framework.assert_called_once_with(self.framework)
                profile.assert_called_once_with()
                self.assertTrue(verify.call_args.kwargs["signed"])
                self.assertEqual(verify.call_args.kwargs["source_framework"], self.framework)

    def test_distribution_rejects_missing_ambiguous_wrong_platform_and_symlink_inputs(self):
        stamp, app, _, _ = self.packaged_app("ios")
        with self.assertRaisesRegex(ValueError, "missing"):
            prism.verify_distribution(self.root / "missing", "ios", stamp)
        package = self.ipa(app)
        with self.assertRaisesRegex(ValueError, "exactly one"):
            prism.verify_distribution(self.root, "ios", stamp)
        with self.assertRaisesRegex(ValueError, "package type"):
            prism.verify_distribution(package, "macos", stamp)
        link = self.root / "linked.ipa"
        link.symlink_to(package)
        with self.assertRaisesRegex(ValueError, "symlink"):
            prism.verify_distribution(link, "ios", stamp)

    def test_distribution_accepts_direct_app_but_rejects_external_links(self):
        stamp, app, _, _ = self.packaged_app("ios")
        with patch.object(prism, "run", side_effect=self.tool):
            self.assertEqual(prism.verify_distribution(app, "ios", stamp, self.root)["platform"], "ios")
        (app / "outside").symlink_to(self.root / "shared")
        with self.assertRaisesRegex(ValueError, "symlink escapes"):
            prism.verify_distribution(app, "ios", stamp, self.root)

    def test_ipa_rejects_traversal_duplicate_external_link_and_size_or_space_overrun(self):
        stamp, app, _, _ = self.packaged_app("ios")
        for name in ("../escaped", "/escaped", "Payload\\escaped"):
            with self.subTest(name=name):
                package = self.ipa(app, [(name, b"unsafe")])
                with self.assertRaisesRegex(ValueError, "[Uu]nsafe|escapes"):
                    prism.verify_distribution(package, "ios", stamp)
        package = self.ipa(app, [("./Payload/Quenderin.app/Info.plist", b"duplicate")])
        with self.assertRaisesRegex(ValueError, "Duplicate"):
            prism.verify_distribution(package, "ios", stamp)
        package = self.ipa(app)
        with zipfile.ZipFile(package, "a") as archive:
            link = zipfile.ZipInfo("Payload/Quenderin.app/link")
            link.create_system = 3
            link.external_attr = (stat.S_IFLNK | 0o777) << 16
            archive.writestr(link, "../../../escaped")
        with self.assertRaisesRegex(ValueError, "symlink escapes"):
            prism.verify_distribution(package, "ios", stamp)
        package = self.ipa(app)
        with zipfile.ZipFile(package, "a") as archive:
            link = zipfile.ZipInfo("Signatures/framework.signature")
            link.create_system = 3
            link.external_attr = (stat.S_IFLNK | 0o777) << 16
            archive.writestr(link, "../Payload/Quenderin.app/Info.plist")
        with self.assertRaisesRegex(ValueError, "auxiliary export symlink"):
            prism.verify_distribution(package, "ios", stamp)
        package = self.ipa(app)
        with patch.object(prism, "MAX_EXPORT_BYTES", 32):
            with self.assertRaisesRegex(ValueError, "size limit"):
                prism.verify_distribution(package, "ios", stamp)
        with patch.object(prism.shutil, "disk_usage", return_value=shutil._ntuple_diskusage(100, 100, 0)):
            with self.assertRaisesRegex(ValueError, "scratch space"):
                prism.verify_distribution(package, "ios", stamp)
        self.assertFalse((self.root / "escaped").exists())

    def test_ipa_requires_one_payload_app_and_rejects_adhoc_wrong_team_and_tamper(self):
        stamp, app, _, native = self.packaged_app("ios")
        package = self.ipa(app)
        digest, scratch = prism.sha(package), []
        temporary_directory = tempfile.TemporaryDirectory

        def record_scratch(**kwargs):
            result = temporary_directory(**kwargs)
            scratch.append(Path(result.name))
            return result

        with patch.object(prism.tempfile, "TemporaryDirectory", side_effect=record_scratch), patch.object(prism, "run", side_effect=lambda *a: "Signature=adhoc\nTeamIdentifier=9M2B2P4KSA" if a[:2] == ("codesign", "-d") else self.tool(*a)):
            with self.assertRaisesRegex(ValueError, "signature"):
                prism.verify_distribution(package, "ios", stamp, self.root)
        self.assertTrue(scratch)
        self.assertTrue(all(not path.exists() for path in scratch))
        self.assertEqual(prism.sha(package), digest)
        with patch.object(prism, "run", side_effect=lambda *a: "TeamIdentifier=WRONGTEAM" if a[:2] == ("codesign", "-d") else self.tool(*a)):
            with self.assertRaisesRegex(ValueError, "signature"):
                prism.verify_distribution(package, "ios", stamp, self.root)
        (native / "llama").write_bytes(thin("arm64", 2, code=b"wrong-payload"))
        package = self.ipa(app)
        with self.assertRaisesRegex(ValueError, "binary payload"):
            prism.verify_distribution(package, "ios", stamp, self.root)
        for extra in ([], [("Payload/Other.app/Info.plist", b"other")]):
            with zipfile.ZipFile(package, "w") as archive:
                if extra:
                    archive.writestr("Payload/Quenderin.app/Info.plist", b"app")
                    archive.writestr(*extra[0])
                else:
                    archive.writestr("Info.plist", b"no-payload-app")
            with self.assertRaisesRegex(ValueError, "exactly one"):
                prism.verify_distribution(package, "ios", stamp)

    def test_ipa_rejects_oversized_central_directory_before_loading_it(self):
        stamp, app, _, _ = self.packaged_app("ios")
        package = self.ipa(app)
        data = bytearray(package.read_bytes())
        end = data.rfind(b"PK\x05\x06")
        struct.pack_into("<I", data, end + 12, 17 * 1024 ** 2)
        package.write_bytes(data)
        with patch.object(prism.zipfile, "ZipFile", side_effect=AssertionError("must not load metadata")):
            with self.assertRaisesRegex(ValueError, "oversized IPA ZIP directory"):
                prism.verify_distribution(package, "ios", stamp)

    @patch.object(prism, "run")
    def test_pkg_rejects_multiple_payloads_traversal_external_links_and_special_files(self, tool):
        tool.side_effect = self.tool
        stamp = self.seal()
        package = self.root / "Quenderin.pkg"
        pkg_fixture(package, [], second_payload=True)
        with self.assertRaisesRegex(ValueError, "exactly one PKG"):
            prism.verify_distribution(package, "macos", stamp)
        for name, mode, data, reason in (("../escaped", stat.S_IFREG | 0o644, b"unsafe", "escapes"),
                                         ("Quenderin.app/link", stat.S_IFLNK | 0o777, b"../../escaped", "symlink escapes"),
                                         ("Quenderin.app/device", stat.S_IFCHR | 0o600, b"", "file type")):
            with self.subTest(name=name):
                pkg_fixture(package, [(name, mode, data)])
                with self.assertRaisesRegex(ValueError, reason):
                    prism.verify_distribution(package, "macos", stamp)
        self.assertFalse((self.root / "escaped").exists())
        pkg_fixture(package, [("Quenderin.app", stat.S_IFDIR | 0o755, b""), ("Other.app", stat.S_IFDIR | 0o755, b"")])
        with self.assertRaisesRegex(ValueError, "exactly one exported PKG app"):
            prism.verify_distribution(package, "macos", stamp)

    def test_pkg_rejects_unsigned_untrusted_and_wrong_installer_before_extraction(self):
        package = pkg_fixture(self.root / "Quenderin.pkg", [])
        digest = prism.sha(package)
        trusted = self.tool("pkgutil", "--check-signature", str(package))
        for status in ("Status: no signature", "Status: signed by untrusted certificate"):
            with self.subTest(status=status), patch.object(prism.subprocess, "check_output", side_effect=subprocess.CalledProcessError(
                    1, ["pkgutil", "--check-signature", str(package)], output=status)), \
                    patch.object(prism.tempfile, "TemporaryDirectory", side_effect=AssertionError("must not allocate extraction scratch")), \
                    patch.object(prism, "extract_pkg", side_effect=AssertionError("must not extract untrusted package")):
                with self.assertRaisesRegex(ValueError, "Native command failed.*pkgutil"):
                    prism.verify_distribution(package, "macos", {})
        for signature in (trusted.replace("(9M2B2P4KSA)", "(WRONGTEAM)") + "\n    4. Unrelated (9M2B2P4KSA)",
                          trusted.replace("3rd Party Mac Developer Installer:", "Developer ID Installer:"),
                          trusted + "\n    1. 3rd Party Mac Developer Installer: Other (WRONGTEAM)"):
            with self.subTest(signature=signature), patch.object(prism.subprocess, "check_output", return_value=signature), \
                    patch.object(prism.tempfile, "TemporaryDirectory", side_effect=AssertionError("must not allocate extraction scratch")), \
                    patch.object(prism, "extract_pkg", side_effect=AssertionError("must not extract wrong installer package")):
                with self.assertRaisesRegex(ValueError, "trusted installer signature"):
                    prism.verify_distribution(package, "macos", {})
        self.assertEqual(prism.sha(package), digest)

    def test_pkg_rejects_truncated_out_of_bounds_and_oversized_metadata(self):
        package = pkg_fixture(self.root / "Quenderin.pkg", [])
        original = package.read_bytes()
        package.write_bytes(original[:-4])
        with self.assertRaisesRegex(ValueError, "bounds"):
            prism.pkg_payload(package)
        header = list(struct.unpack(">4sHHQQI", original[:28]))
        header[4] = 9 * 1024 ** 2
        package.write_bytes(struct.pack(">4sHHQQI", *header) + original[28:])
        with self.assertRaisesRegex(ValueError, "size limit"):
            prism.pkg_payload(package)
        package.write_bytes(b"not-a-package")
        with self.assertRaisesRegex(ValueError, "Truncated"):
            prism.pkg_payload(package)

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
        (self.root / "scripts").mkdir(exist_ok=True)
        (self.root / "apple/QuenderinApp").mkdir(exist_ok=True)
        (self.root / "apple/QuenderinKit/Package.swift").write_text("// fixture package")
        (self.root / "apple/QuenderinApp/project.yml").write_text("name: Fixture")
        (self.root / "scripts/verify_prism_apple_runtime.py").write_text("import sys; print('REPOSITORY_VERIFIER', ' '.join(sys.argv[1:]))")
        (self.root / "apple/QuenderinKit/.quenderin-prism-release").write_text("prism\n")
        env = os.environ | {"CI": "TRUE", "QUENDERIN_RUNTIME": "prism", "QUENDERIN_LLAMA_DIR": "",
                            "CI_PRIMARY_REPOSITORY_PATH": str(self.root), "CI_XCODEBUILD_ACTION": "archive",
                            "CI_XCODEBUILD_EXIT_CODE": "0", "CI_PRODUCT_PLATFORM": "iOS", "CI_ARCHIVE_PATH": str(self.root / "adhoc.xcarchive"),
                            "CI_APP_STORE_SIGNED_APP_PATH": str(self.root / "signed export")}
        clone = subprocess.run(["bash", str(isolated / "ci_post_clone.sh")], cwd=isolated,
                               env=env | {"QUENDERIN_RUNTIME": "standard"}, capture_output=True, text=True)
        self.assertNotEqual(clone.returncode, 0)
        self.assertIn("explicit QUENDERIN_RUNTIME=prism", clone.stderr)
        for name, command in (("ci_pre_xcodebuild.sh", "verify-framework"), ("ci_post_xcodebuild.sh", "verify-distribution")):
            with self.subTest(hook=name):
                result = subprocess.run(["bash", str(isolated / name)], cwd=isolated, env=env, capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("REPOSITORY_VERIFIER " + command, result.stdout)
                if command == "verify-distribution":
                    self.assertIn("--distribution " + env["CI_APP_STORE_SIGNED_APP_PATH"], result.stdout)
                    self.assertNotIn(env["CI_ARCHIVE_PATH"], result.stdout)
        missing_export = subprocess.run(["bash", str(isolated / "ci_post_xcodebuild.sh")], cwd=isolated,
                                        env=env | {"CI_APP_STORE_SIGNED_APP_PATH": ""}, capture_output=True, text=True)
        self.assertNotEqual(missing_export.returncode, 0)
        self.assertIn("CI_APP_STORE_SIGNED_APP_PATH", missing_export.stderr)
        self.assertNotIn("REPOSITORY_VERIFIER", missing_export.stdout)


if __name__ == "__main__":
    unittest.main()

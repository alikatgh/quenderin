#!/usr/bin/env python3
"""Build and verify the real locked UniFFI SDK. Builds are hosted-only operations."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import struct
import subprocess
import sys
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[1]
REPO = ROOT.parents[1]
JNA_URL = "https://repo.maven.apache.org/maven2/net/java/dev/jna/jna/5.19.1/jna-5.19.1.aar"
# Official Maven Central digest, retrieved 2026-10-23; not the host JAR.
JNA_SHA1 = "af25a9b1e286a62e2786388671c703b9a1f75a65"
# Independently downloaded from the fixed HTTPS origin and checked against the
# official Maven SHA-1, exact length and arm64 ELF alignment on 2026-10-23.
JNA_SHA256 = "b57125cb7d16253f0d65a80f7d3a4c3664effa711b8bdbb7f87fb572ce1624ed"
JNA_BYTES = 525_093
TARGETS = {
    "apple": ["aarch64-apple-ios", "aarch64-apple-ios-sim", "x86_64-apple-ios", "aarch64-apple-darwin", "x86_64-apple-darwin"],
    "android": ["aarch64-linux-android"],
}
SWIFT = "QuenderinRemoteCrypto.swift"
HEADER = "QuenderinRemoteCryptoFFI.h"
MODULEMAP = "QuenderinRemoteCryptoFFI.modulemap"
KOTLIN = "ai/quenderin/remote/crypto/quenderin_remote_crypto.kt"
RECEIPT = "quenderin-remote-sdk.json"

# Only these fixed validation messages may reach the CLI. Parser, filesystem,
# subprocess and unexpected exception data can contain arbitrary input values.
SAFE_VALIDATION_DIAGNOSTICS = {
    "SDK symlinks are forbidden": "SDK_SYMLINK: SDK symlinks are forbidden.",
    "Expected Android arm64 ELF64": "ELF_ABI: Expected Android arm64 ELF64.",
    "Invalid ELF program header table": "ELF_HEADER: Invalid ELF program header table.",
    "Android ELF does not satisfy 16 KiB load alignment": "ELF_ALIGNMENT: Android ELF does not satisfy 16 KiB load alignment.",
    "ELF has no loadable segments": "ELF_LOAD: ELF has no loadable segments.",
    "Official Android JNA AAR size/digest differs": "JNA_DIGEST: Official Android JNA AAR size/digest differs.",
    "JNA Android archive structure differs": "JNA_LAYOUT: JNA Android archive structure differs.",
    "SDK receipt is stale, incomplete, or from different sources/targets": "SDK_RECEIPT: SDK receipt is stale, incomplete, or from different sources/targets.",
    "SDK is missing generated bindings or native libraries": "SDK_COMPONENT: SDK is missing generated bindings or native libraries.",
    "Native SDK directory is unavailable": "SDK_DIRECTORY: Native SDK directory is unavailable.",
    "Android SDK target contract differs": "SDK_ANDROID_TARGET: Android SDK target contract differs.",
    "Apple deployment targets differ": "SDK_APPLE_TARGET: Apple deployment targets differ.",
    "Invalid XCFramework slice identifier": "SDK_APPLE_SLICE_ID: Invalid XCFramework slice identifier.",
    "XCFramework library/header layout differs": "SDK_APPLE_LAYOUT: XCFramework library/header layout differs.",
    "XCFramework native slice is missing": "SDK_APPLE_COMPONENT: XCFramework native slice is missing.",
    "XCFramework module map differs from the generated map": "SDK_APPLE_MODULE_MAP: XCFramework module map differs from the generated map.",
    "Apple SDK slices differ from supported targets": "SDK_APPLE_SLICES: Apple SDK slices differ from supported targets.",
    "Duplicate Android package entries": "PACKAGE_DUPLICATE: Duplicate Android package entries.",
    "Unexpected packaged Android ABI": "PACKAGE_ABI: Unexpected packaged Android ABI.",
    "Packaged Noise ELF lacks 16 KiB load alignment": "PACKAGE_NOISE_ELF_ALIGNMENT: Packaged Noise ELF lacks 16 KiB load alignment.",
    "Packaged JNA ELF lacks 16 KiB load alignment": "PACKAGE_JNA_ELF_ALIGNMENT: Packaged JNA ELF lacks 16 KiB load alignment.",
    "Another packaged dependency lacks 16 KiB ELF load alignment": "PACKAGE_DEPENDENCY_ELF_ALIGNMENT: Another packaged dependency lacks 16 KiB ELF load alignment.",
    "Stored APK native library lacks 16 KiB ZIP alignment": "PACKAGE_ZIP_ALIGNMENT: Stored APK native library lacks 16 KiB ZIP alignment.",
    "Duplicate packaged remote library": "PACKAGE_REMOTE_DUPLICATE: Duplicate packaged remote library.",
    "Packaged Noise bytes differ from verified SDK": "PACKAGE_NOISE_BYTES: Packaged Noise bytes differ from verified SDK.",
    "Packaged JNA bytes differ from verified SDK": "PACKAGE_JNA_BYTES: Packaged JNA bytes differ from verified SDK.",
    "Android package is missing the real Noise or JNA library": "PACKAGE_REMOTE_MISSING: Android package is missing the real Noise or JNA library.",
    "Android NDK pin differs": "SDK_NDK_PIN: Android NDK pin differs.",
    "Pinned Android arm64 API28 compiler/archiver is unavailable": "SDK_NDK_TOOLS: Pinned Android arm64 API28 compiler/archiver is unavailable.",
    "Native SDK compilation is restricted to the bounded hosted workflow": "SDK_HOSTED_ONLY: Native SDK compilation is restricted to the bounded hosted workflow.",
    "Preserve existing SDK output; choose a new path": "SDK_EXISTING_OUTPUT: Preserve existing SDK output; choose a new path.",
    "Built Apple archive architecture differs": "SDK_APPLE_ARCHITECTURE: Built Apple archive architecture differs.",
    "Unexpected Maven redirect": "SDK_MAVEN_REDIRECT: Unexpected Maven redirect.",
}


def failure_diagnostic(error: Exception) -> str:
    if type(error) is ValueError and len(error.args) == 1 and type(error.args[0]) is str:
        return SAFE_VALIDATION_DIAGNOSTICS.get(error.args[0], "SDK_VALIDATION: Unrecognized validation failure.")
    if isinstance(error, json.JSONDecodeError):
        return "SDK_JSON: SDK metadata is not valid JSON."
    if isinstance(error, zipfile.BadZipFile):
        return "SDK_ARCHIVE: SDK or Android package archive is invalid."
    if isinstance(error, OSError):
        return "SDK_IO: A required SDK or package file could not be read."
    if isinstance(error, KeyError):
        return "SDK_METADATA: Required SDK metadata is missing."
    if isinstance(error, subprocess.TimeoutExpired):
        return "SDK_TIMEOUT: A bounded build command exceeded its deadline."
    if isinstance(error, subprocess.SubprocessError):
        return "SDK_COMMAND: A required build command failed."
    return "SDK_UNEXPECTED: Unexpected SDK verification failure."


def digest(path: Path, algorithm: str = "sha256") -> str:
    with path.open("rb") as stream:
        value = hashlib.new(algorithm)
        for block in iter(lambda: stream.read(1_048_576), b""):
            value.update(block)
    return value.hexdigest()


def source_hashes(root: Path = ROOT) -> dict[str, str]:
    names = ["Cargo.toml", "Cargo.lock", "rust-toolchain.toml", "uniffi.toml", "LICENSES.md", "tools/native_sdk.py", "tools/verify_build_gate.py"]
    names += sorted(str(path.relative_to(root)) for path in (root / "src").rglob("*.rs"))
    return {name: digest(root / name) for name in sorted(names)}


def files(root: Path) -> dict[str, str]:
    result = {}
    for parent, directories, names in os.walk(root, followlinks=False):
        parent = Path(parent)
        if any((parent / name).is_symlink() for name in directories + names):
            raise ValueError("SDK symlinks are forbidden")
        if parent == root and "work" in directories:
            directories.remove("work")
        for name in sorted(names):
            path = parent / name
            relative = path.relative_to(root).as_posix()
            if relative != RECEIPT:
                result[relative] = digest(path)
    return result


def elf(data: bytes, *, machine: int = 183) -> None:
    """Check every ELF64 little-endian PT_LOAD, without trusting a shell tool's text."""
    if (len(data) < 64 or data[:6] != b"\x7fELF\x02\x01"
            or struct.unpack_from("<HH", data, 16) != (3, machine)):
        raise ValueError("Expected Android arm64 ELF64")
    offset = struct.unpack_from("<Q", data, 32)[0]
    size, count = struct.unpack_from("<HH", data, 54)
    if size != 56 or not 1 <= count <= 256 or offset + size * count > len(data):
        raise ValueError("Invalid ELF program header table")
    loads = 0
    for index in range(count):
        kind, _, file_offset, address, _, file_size, memory_size, alignment = struct.unpack_from("<IIQQQQQQ", data, offset + index * size)
        if kind != 1:
            continue
        loads += 1
        if (alignment < 16384 or alignment & (alignment - 1) or file_offset % alignment != address % alignment
                or file_offset + file_size > len(data) or memory_size < file_size):
            raise ValueError("Android ELF does not satisfy 16 KiB load alignment")
    if not loads:
        raise ValueError("ELF has no loadable segments")


def verify_jna(path: Path) -> None:
    if path.stat().st_size != JNA_BYTES or digest(path) != JNA_SHA256 or digest(path, "sha1") != JNA_SHA1:
        raise ValueError("Official Android JNA AAR size/digest differs")
    with zipfile.ZipFile(path) as archive:
        names = archive.namelist()
        if len(names) != len(set(names)) or "classes.jar" not in names or "jni/arm64-v8a/libjnidispatch.so" not in names:
            raise ValueError("JNA Android archive structure differs")
        elf(archive.read("jni/arm64-v8a/libjnidispatch.so"))


def validate_receipt(receipt: dict, platform: str, actual_files: dict[str, str], actual_sources: dict[str, str]) -> None:
    if (not isinstance(receipt, dict) or receipt.get("schemaVersion") != 1 or receipt.get("platform") != platform
            or receipt.get("targets") != TARGETS[platform] or receipt.get("rust") != "1.90.0"
            or receipt.get("sources") != actual_sources or receipt.get("files") != actual_files):
        raise ValueError("SDK receipt is stale, incomplete, or from different sources/targets")
    required = ({"Sources/QuenderinRemoteCrypto/" + SWIFT, "QuenderinRemoteCryptoFFI.xcframework/Info.plist"}
                if platform == "apple" else {"kotlin/" + KOTLIN, "jniLibs/arm64-v8a/libquenderin_remote_crypto.so", "jna/jna-5.19.1.aar"})
    if not required <= actual_files.keys() or not all(len(value) == 64 for value in actual_files.values()):
        raise ValueError("SDK is missing generated bindings or native libraries")


def verify(sdk: Path, platform: str) -> None:
    if sdk.is_symlink() or not sdk.is_dir():
        raise ValueError("Native SDK directory is unavailable")
    receipt = json.loads((sdk / RECEIPT).read_text())
    validate_receipt(receipt, platform, files(sdk), source_hashes())
    if platform == "android":
        if receipt.get("minimumAPI") != 28 or receipt.get("ndk") != "26.3.11579264" or receipt.get("abis") != ["arm64-v8a"]:
            raise ValueError("Android SDK target contract differs")
        elf((sdk / "jniLibs/arm64-v8a/libquenderin_remote_crypto.so").read_bytes())
        verify_jna(sdk / "jna/jna-5.19.1.aar")
    else:
        if receipt.get("deploymentTargets") != {"iOS": "16.4", "macOS": "13.3"}:
            raise ValueError("Apple deployment targets differ")
        framework = sdk / "QuenderinRemoteCryptoFFI.xcframework"
        libraries = plistlib.loads((framework / "Info.plist").read_bytes())["AvailableLibraries"]
        actual = set()
        for library in libraries:
            identifier = library["LibraryIdentifier"]
            if "/" in identifier or identifier in {".", ".."}:
                raise ValueError("Invalid XCFramework slice identifier")
            actual.add((library["SupportedPlatform"], library.get("SupportedPlatformVariant", ""), tuple(sorted(library["SupportedArchitectures"]))))
            directory = framework / identifier
            if library["LibraryPath"] != "libquenderin_remote_crypto.a" or library["HeadersPath"] != "Headers":
                raise ValueError("XCFramework library/header layout differs")
            if not (directory / library["LibraryPath"]).is_file() or not (directory / "Headers" / HEADER).is_file():
                raise ValueError("XCFramework native slice is missing")
            expected_map = (sdk / "Bindings" / MODULEMAP).read_bytes()
            if (directory / "Headers/module.modulemap").read_bytes() != expected_map:
                raise ValueError("XCFramework module map differs from the generated map")
        expected = {("ios", "", ("arm64",)), ("ios", "simulator", ("arm64", "x86_64")), ("macos", "", ("arm64", "x86_64"))}
        if len(libraries) != 3 or actual != expected:
            raise ValueError("Apple SDK slices differ from supported targets")


def verify_package(sdk: Path, package: Path) -> None:
    verify(sdk, "android")
    expected = {
        "libquenderin_remote_crypto.so": (sdk / "jniLibs/arm64-v8a/libquenderin_remote_crypto.so").read_bytes(),
    }
    with zipfile.ZipFile(sdk / "jna/jna-5.19.1.aar") as jna:
        expected["libjnidispatch.so"] = jna.read("jni/arm64-v8a/libjnidispatch.so")
    found = set()
    with zipfile.ZipFile(package) as archive, package.open("rb") as raw:
        if len(archive.namelist()) != len(set(archive.namelist())):
            raise ValueError("Duplicate Android package entries")
        for item in archive.infolist():
            if not item.filename.endswith(".so"):
                continue
            if "/arm64-v8a/" not in item.filename:
                raise ValueError("Unexpected packaged Android ABI")
            data = archive.read(item)
            name = Path(item.filename).name
            try:
                elf(data)
            except ValueError as error:
                if error.args == ("Android ELF does not satisfy 16 KiB load alignment",):
                    if name == "libquenderin_remote_crypto.so":
                        raise ValueError("Packaged Noise ELF lacks 16 KiB load alignment") from None
                    if name == "libjnidispatch.so":
                        raise ValueError("Packaged JNA ELF lacks 16 KiB load alignment") from None
                    raise ValueError("Another packaged dependency lacks 16 KiB ELF load alignment") from None
                raise
            # Compressed libraries are extracted by Android; stored libraries must
            # be directly mmap-able at 16 KiB boundaries in APKs.
            if package.suffix == ".apk" and item.compress_type == zipfile.ZIP_STORED:
                raw.seek(item.header_offset)
                header = raw.read(30)
                name_size, extra_size = struct.unpack_from("<HH", header, 26)
                if (item.header_offset + 30 + name_size + extra_size) % 16384:
                    raise ValueError("Stored APK native library lacks 16 KiB ZIP alignment")
            if name in expected:
                if name in found:
                    raise ValueError("Duplicate packaged remote library")
                if data != expected[name]:
                    if name == "libquenderin_remote_crypto.so":
                        raise ValueError("Packaged Noise bytes differ from verified SDK")
                    raise ValueError("Packaged JNA bytes differ from verified SDK")
                found.add(name)
    if found != expected.keys():
        raise ValueError("Android package is missing the real Noise or JNA library")


def run(arguments: list[str], env: dict[str, str], timeout: int = 600) -> None:
    subprocess.run(arguments, cwd=ROOT, env=env, check=True, timeout=timeout)


def write_copy(source: Path, destination: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    with source.open("rb") as src, destination.open("xb") as dst:
        shutil.copyfileobj(src, dst)


def android_toolchain_env(ndk: Path) -> dict[str, str]:
    properties = {}
    for line in (ndk / "source.properties").read_text().splitlines():
        key, separator, value = line.partition("=")
        if separator:
            properties[key.strip()] = value.strip()
    if properties.get("Pkg.Revision") != "26.3.11579264":
        raise ValueError("Android NDK pin differs")
    tools = ndk / "toolchains/llvm/prebuilt/linux-x86_64/bin"
    compiler = tools / "aarch64-linux-android28-clang"
    archiver = tools / "llvm-ar"
    for tool in (compiler, archiver):
        if not tool.is_file() or not os.access(tool, os.X_OK):
            raise ValueError("Pinned Android arm64 API28 compiler/archiver is unavailable")
    # Cargo's linker setting does not configure cc-rs C dependencies such as ring.
    # Scope both tools to this target, preserving the host bindgen build settings.
    return {
        "CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER": str(compiler),
        "CARGO_TARGET_AARCH64_LINUX_ANDROID_RUSTFLAGS": "-C link-arg=-Wl,-z,max-page-size=16384",
        "CC_aarch64_linux_android": str(compiler),
        "AR_aarch64_linux_android": str(archiver),
    }


def build(out: Path, platform: str) -> None:
    if os.environ.get("GITHUB_ACTIONS") != "true" or os.environ.get("CI") != "true":
        raise ValueError("Native SDK compilation is restricted to the bounded hosted workflow")
    if out.exists() or out.is_symlink():
        raise ValueError("Preserve existing SDK output; choose a new path")
    from verify_build_gate import require_locked
    require_locked()
    out.mkdir(parents=True)
    work = out / "work"
    work.mkdir()
    env = dict(os.environ, CARGO_TARGET_DIR=str(work / "target"), CARGO_NET_RETRY="0", CARGO_HTTP_TIMEOUT="30", CARGO_BUILD_JOBS="2")
    run(["cargo", "+1.90.0", "build", "--locked", "--release", "--lib"], env)
    host_library = work / "target/release" / ("libquenderin_remote_crypto.dylib" if platform == "apple" else "libquenderin_remote_crypto.so")
    generated = work / "generated"
    run(["cargo", "+1.90.0", "run", "--locked", "--release", "--features", "bindgen", "--bin", "quenderin-remote-bindgen", "--", "generate", "--library", str(host_library), "--language", "swift", "--language", "kotlin", "--no-format", "--out-dir", str(generated)], env)
    if platform == "apple":
        env.update(IPHONEOS_DEPLOYMENT_TARGET="16.4", MACOSX_DEPLOYMENT_TARGET="13.3")
        for target in TARGETS[platform]:
            run(["cargo", "+1.90.0", "build", "--locked", "--release", "--lib", "--target", target], env)
        write_copy(generated / SWIFT, out / "Sources/QuenderinRemoteCrypto" / SWIFT)
        write_copy(generated / MODULEMAP, out / "Bindings" / MODULEMAP)
        headers = work / "Headers"
        write_copy(generated / HEADER, headers / HEADER)
        write_copy(generated / MODULEMAP, headers / "module.modulemap")
        groups = [("device", ["aarch64-apple-ios"]), ("simulator", ["aarch64-apple-ios-sim", "x86_64-apple-ios"]), ("macos", ["aarch64-apple-darwin", "x86_64-apple-darwin"])]
        command = ["xcodebuild", "-create-xcframework"]
        for name, targets in groups:
            destination = work / name / "libquenderin_remote_crypto.a"
            destination.parent.mkdir()
            inputs = [str(work / "target" / target / "release/libquenderin_remote_crypto.a") for target in targets]
            if len(inputs) == 1:
                write_copy(Path(inputs[0]), destination)
            else:
                run(["xcrun", "lipo", "-create", *inputs, "-output", str(destination)], env, 60)
            result = subprocess.run(["xcrun", "lipo", "-archs", str(destination)], check=True, capture_output=True, text=True, timeout=30)
            expected = {"arm64"} if name == "device" else {"arm64", "x86_64"}
            if set(result.stdout.split()) != expected:
                raise ValueError("Built Apple archive architecture differs")
            command += ["-library", str(destination), "-headers", str(headers)]
        run(command + ["-output", str(out / "QuenderinRemoteCryptoFFI.xcframework")], env, 180)
    else:
        ndk = Path(os.environ["ANDROID_NDK_HOME"])
        env.update(android_toolchain_env(ndk))
        run(["cargo", "+1.90.0", "build", "--locked", "--release", "--lib", "--target", "aarch64-linux-android"], env)
        write_copy(work / "target/aarch64-linux-android/release/libquenderin_remote_crypto.so", out / "jniLibs/arm64-v8a/libquenderin_remote_crypto.so")
        write_copy(generated / KOTLIN, out / "kotlin" / KOTLIN)
        destination = out / "jna/jna-5.19.1.aar"
        destination.parent.mkdir()
        class NoRedirect(urllib.request.HTTPRedirectHandler):
            def redirect_request(self, *_args, **_kwargs):
                raise ValueError("Unexpected Maven redirect")
        with urllib.request.build_opener(NoRedirect).open(JNA_URL, timeout=30) as response:
            data = response.read(JNA_BYTES + 1)
        if len(data) != JNA_BYTES or hashlib.sha256(data).hexdigest() != JNA_SHA256 or hashlib.sha1(data).hexdigest() != JNA_SHA1:
            raise ValueError("Official Android JNA AAR size/digest differs")
        destination.write_bytes(data)
        verify_jna(destination)
    write_copy(ROOT / "LICENSES.md", out / "LICENSES.md")
    receipt = {"schemaVersion": 1, "platform": platform, "rust": "1.90.0", "targets": TARGETS[platform],
               "sources": source_hashes(), "files": files(out),
               "sourceRevision": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()}
    if platform == "android":
        receipt.update(minimumAPI=28, ndk="26.3.11579264", abis=["arm64-v8a"], jnaSHA1=JNA_SHA1, jnaSHA256=JNA_SHA256)
    else:
        receipt.update(deploymentTargets={"iOS": "16.4", "macOS": "13.3"})
    with (out / RECEIPT).open("x") as stream:
        json.dump(receipt, stream, sort_keys=True, indent=2)
        stream.write("\n")
    verify(out, platform)
    print(f"NATIVE_REMOTE_SDK_VERIFIED {platform}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    for name in ("build", "verify"):
        command = sub.add_parser(name)
        command.add_argument("--platform", choices=TARGETS, required=True)
        command.add_argument("--sdk", type=Path, required=True)
    command = sub.add_parser("verify-package")
    command.add_argument("--sdk", type=Path, required=True)
    command.add_argument("--package", type=Path, required=True)
    args = parser.parse_args()
    try:
        # Do not resolve away an existing symlink before the preserve-path check.
        sdk = Path(os.path.abspath(args.sdk))
        if args.command == "build": build(sdk, args.platform)
        elif args.command == "verify": verify(sdk, args.platform)
        else: verify_package(sdk, Path(os.path.abspath(args.package)))
    except Exception as error:
        print(f"Native SDK check failed: {failure_diagnostic(error)}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
"""Build and verify the real locked UniFFI SDK. Builds are hosted-only operations."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import platform as host_platform
import re
import shutil
import signal
import struct
import subprocess
import sys
import time
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
APPLE_RELEASE_MARKER = "build/.quenderin-remote-crypto-release"
# Real generated UniFFI entry points, not optional Swift adapter symbols. Retain
# their definitions for the distribution gate's dyld export-trie check after
# Xcode removes the ordinary nlist/debug symbol tables.
APPLE_LINK_SYMBOLS = ["uniffi_quenderin_remote_crypto_fn_func_derive_public_key"] + [
    "uniffi_quenderin_remote_crypto_fn_" + kind + "_noiseiksession_" + name
    for kind, name in [("constructor", "create"), ("method", "initiate"),
                       ("method", "read_handshake"), ("method", "encrypt"),
                       ("method", "decrypt"), ("method", "counters"), ("method", "shutdown")]
]
CLOUD_DEADLINE: float | None = None
CLOUD_DISK: tuple[Path, int] | None = None

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
    "Android package is missing the real Noise library": "PACKAGE_NOISE_MISSING: Android package is missing the real Noise library.",
    "Android package is missing the real JNA library": "PACKAGE_JNA_MISSING: Android package is missing the real JNA library.",
    "Android NDK pin differs": "SDK_NDK_PIN: Android NDK pin differs.",
    "Pinned Android arm64 API28 compiler/archiver is unavailable": "SDK_NDK_TOOLS: Pinned Android arm64 API28 compiler/archiver is unavailable.",
    "Native SDK compilation is restricted to the bounded hosted workflow": "SDK_HOSTED_ONLY: Native SDK compilation is restricted to the bounded hosted workflow.",
    "Preserve existing SDK output; choose a new path": "SDK_EXISTING_OUTPUT: Preserve existing SDK output; choose a new path.",
    "Built Apple archive architecture differs": "SDK_APPLE_ARCHITECTURE: Built Apple archive architecture differs.",
    "Unexpected Maven redirect": "SDK_MAVEN_REDIRECT: Unexpected Maven redirect.",
    "Xcode Cloud context differs from the real Apple checkout": "SDK_CLOUD_CONTEXT: Xcode Cloud context differs from the real Apple checkout.",
    "Xcode Cloud SDK build exceeded its resource bound": "SDK_CLOUD_RESOURCE: Xcode Cloud SDK build exceeded its resource bound.",
    "Xcode Cloud Rust bootstrap is unavailable": "SDK_CLOUD_RUST: Xcode Cloud Rust bootstrap is unavailable.",
    "Xcode Cloud Python bootstrap is unavailable": "SDK_CLOUD_PYTHON: Python bootstrap requires Python 3.11 or later with tomllib.",
    "Native SDK source validation failed": "SDK_SOURCE_VALIDATION: Locked source validation failed.",
    "Apple generated crypto entry points differ": "SDK_APPLE_EXPORTS: Apple generated crypto entry points differ.",
    "Apple static archive link proof differs": "SDK_APPLE_LINK_PROOF: Apple static archive link proof differs.",
}


def failure_diagnostic(error: Exception) -> str:
    if type(error) is ValueError and len(error.args) == 1 and type(error.args[0]) is str:
        return SAFE_VALIDATION_DIAGNOSTICS.get(error.args[0], "SDK_VALIDATION: Unrecognized validation failure.")
    if isinstance(error, json.JSONDecodeError):
        return "SDK_JSON: SDK metadata is not valid JSON."
    if isinstance(error, zipfile.BadZipFile):
        return "SDK_ARCHIVE: SDK or Android package archive is invalid."
    if isinstance(error, ModuleNotFoundError) and error.name == "tomllib":
        return "SDK_PYTHON: Source validation requires Python 3.11 or later with tomllib."
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


def apple_proof_identity(sources: dict, archives: dict) -> str:
    return hashlib.sha256(json.dumps({"sources": sources, "inputArchives": archives},
                                    sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def validate_apple_proof(receipt: dict) -> dict:
    proof = receipt.get("appleLinkProof")
    if not isinstance(proof, dict):
        raise ValueError("Apple static archive link proof differs")
    inputs = proof.get("inputArchives")
    if (not isinstance(inputs, dict) or set(inputs) != set(TARGETS["apple"])
            or any(not isinstance(value, str) or not re.fullmatch(r"[0-9a-f]{64}", value) for value in inputs.values())):
        raise ValueError("Apple static archive link proof differs")
    identity = apple_proof_identity(receipt["sources"], inputs)
    if proof != {"schemaVersion": 1, "inputArchives": inputs, "identity": identity,
                 "symbol": "quenderin_remote_sdk_" + identity}:
        raise ValueError("Apple static archive link proof differs")
    return proof


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
        validate_apple_proof(receipt)
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
    if "libquenderin_remote_crypto.so" not in found:
        raise ValueError("Android package is missing the real Noise library")
    if "libjnidispatch.so" not in found:
        raise ValueError("Android package is missing the real JNA library")


def run(arguments: list[str], env: dict[str, str], timeout: int = 600, *, quiet: bool = False) -> None:
    output = {"stdout": subprocess.DEVNULL, "stderr": subprocess.DEVNULL} if quiet else {}
    if CLOUD_DEADLINE is None:
        subprocess.run(arguments, cwd=ROOT, env=env, check=True, timeout=timeout, **output)
        return
    # A single 30-minute deadline includes bootstrap, five serial target builds,
    # binding generation and packaging. Kill the process group, including rustc,
    # when time/free-space/allocation bounds are hit; never retry a failed build.
    deadline = min(CLOUD_DEADLINE, time.monotonic() + timeout)
    process = subprocess.Popen(arguments, cwd=ROOT, env=env, start_new_session=True, **output)
    try:
        while process.poll() is None:
            if time.monotonic() >= deadline:
                raise subprocess.TimeoutExpired(arguments, timeout)
            if CLOUD_DISK is not None:
                path, initial = CLOUD_DISK
                free = shutil.disk_usage(path).free
                if free < 2 * 1024 ** 3 or initial - free > 6 * 1024 ** 3:
                    raise ValueError("Xcode Cloud SDK build exceeded its resource bound")
            time.sleep(0.5)
        if process.returncode:
            raise subprocess.CalledProcessError(process.returncode, arguments)
    finally:
        # Descendants must not continue downloading/compiling after the gate exits.
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait()


def require_apple_cloud(out: Path) -> None:
    """Apple's documented context, never manufactured GitHub/CI variables.

    https://developer.apple.com/documentation/xcode/environment-variable-reference
    These are execution guards, not credential-based host attestation.
    """
    workspace = Path(os.environ.get("CI_WORKSPACE_PATH", ""))
    checkout = Path(os.environ.get("CI_PRIMARY_REPOSITORY_PATH", ""))
    if (host_platform.system() != "Darwin" or os.environ.get("CI") != "TRUE"
            or os.environ.get("CI_XCODE_CLOUD") != "TRUE"
            or not re.fullmatch(r"[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}", os.environ.get("CI_BUILD_ID", ""))
            or not workspace.is_absolute() or not workspace.is_dir()
            or not checkout.is_absolute() or checkout.resolve() != REPO.resolve()
            or not checkout.resolve().is_relative_to(workspace.resolve())
            or not out.resolve().is_relative_to(REPO.resolve())
            or out != REPO / "apple/QuenderinKit/build/RemoteCryptoSDK"):
        raise ValueError("Xcode Cloud context differs from the real Apple checkout")


def apple_link_contract(sdk: Path) -> dict:
    verify(sdk, "apple")
    receipt = json.loads((sdk / RECEIPT).read_text())
    proof = validate_apple_proof(receipt)
    marker = sdk.parent.parent / APPLE_RELEASE_MARKER
    if marker.exists() or marker.is_symlink():
        if marker.is_symlink() or marker.read_text() != digest(sdk / RECEIPT) + "\n":
            raise ValueError("SDK receipt is stale, incomplete, or from different sources/targets")
    header = sdk / "QuenderinRemoteCryptoFFI.xcframework"
    # Verify already checks every slice against the receipt; check the generated
    # ABI explicitly rather than inventing symbols not provided by this SDK.
    headers = list(header.glob("*/Headers/" + HEADER))
    if not headers or any(not all(re.search(r"\b" + re.escape(symbol) + r"\s*\(", path.read_text())
                                 for symbol in APPLE_LINK_SYMBOLS) for path in headers):
        raise ValueError("Apple generated crypto entry points differ")
    symbols = ["_" + symbol for symbol in APPLE_LINK_SYMBOLS]
    return {"receiptSha256": digest(sdk / RECEIPT), "symbols": symbols,
            "proofSymbol": "_" + proof["symbol"]}


def apple_link_settings(sdk: Path) -> list[str]:
    contract = apple_link_contract(sdk)
    # An exported-symbol whitelist hides the public Swift API when Xcode links
    # the package as a dynamic test product. Preserve globals without a filter.
    flags = ["-Xlinker", "-export_dynamic"]
    for symbol in contract["symbols"] + [contract["proofSymbol"]]:
        flags += ["-Xlinker", "-u", "-Xlinker", symbol]
    return flags


def add_apple_archive_proof(work: Path, env: dict[str, str]) -> dict:
    """Make stale SDK cache reuse fail the real link, even when ABI names match.

    The unique symbol is supplied by each actual static archive, not fabricated
    by linker flags. It is bound to the five original archive digests and locked
    sources; its implementation references the real UniFFI public-key function.
    """
    archives = {target: work / "target" / target / "release/libquenderin_remote_crypto.a" for target in TARGETS["apple"]}
    inputs = {target: digest(path) for target, path in archives.items()}
    identity = apple_proof_identity(source_hashes(), inputs)
    symbol = "quenderin_remote_sdk_" + identity
    source = work / "sdk-link-proof.c"
    source.write_text("extern void " + APPLE_LINK_SYMBOLS[0] + "(void);\n"
                      "__attribute__((used, visibility(\"default\"))) void *" + symbol + "(void) {\n"
                      "    return (void *)&" + APPLE_LINK_SYMBOLS[0] + ";\n}\n")
    clang_targets = ["arm64-apple-ios16.4", "arm64-apple-ios16.4-simulator", "x86_64-apple-ios16.4-simulator",
                     "arm64-apple-macos13.3", "x86_64-apple-macos13.3"]
    for target, clang_target in zip(TARGETS["apple"], clang_targets):
        object_file = work / (target + "-sdk-link-proof.o")
        run(["xcrun", "clang", "-target", clang_target, "-O2", "-c", str(source), "-o", str(object_file)], env, 30)
        run(["xcrun", "ar", "-r", "-s", str(archives[target]), str(object_file)], env, 60)
    return {"schemaVersion": 1, "inputArchives": inputs, "identity": identity, "symbol": symbol}


def apple_cloud_python(out: Path, env: dict[str, str]) -> str:
    """Keep the SDK supervisor on Apple's Python; run TOML checks on 3.11+."""
    require_apple_cloud(out)
    if sys.version_info >= (3, 11):
        return sys.executable
    probe = "import sys,tomllib; raise SystemExit(sys.version_info < (3,11))"

    def supported(candidate: str) -> bool:
        try:
            run([candidate, "-I", "-c", probe], env, 15, quiet=True)
        except subprocess.CalledProcessError:
            return False
        return True

    for name in ("python3.13", "python3.12", "python3.11", "python3.14", "python3"):
        candidate = shutil.which(name, path=env["PATH"])
        if candidate is not None and supported(candidate):
            return candidate
    brew = shutil.which("brew", path=env["PATH"])
    if brew is None:
        raise ValueError("Xcode Cloud Python bootstrap is unavailable")
    # Official bottled interpreter, within the same aggregate SDK watchdog.
    run([brew, "install", "--force-bottle", "python@3.13"], env, 300)
    remaining = min(15, CLOUD_DEADLINE - time.monotonic()) if CLOUD_DEADLINE is not None else 15
    if remaining <= 0:
        raise ValueError("Xcode Cloud SDK build exceeded its resource bound")
    prefix = subprocess.check_output([brew, "--prefix", "python@3.13"], env=env, text=True, timeout=remaining).strip()
    candidate = str(Path(prefix) / "bin/python3.13")
    if not Path(candidate).is_file() or not supported(candidate):
        raise ValueError("Xcode Cloud Python bootstrap is unavailable")
    return candidate


def stage_apple_cloud(out: Path) -> None:
    global CLOUD_DEADLINE, CLOUD_DISK
    require_apple_cloud(out)
    tools = out.parent / "RemoteCryptoCloudTools"
    marker = REPO / "apple/QuenderinKit" / APPLE_RELEASE_MARKER
    if any(path.exists() or path.is_symlink() for path in (out, tools, marker)):
        raise ValueError("Preserve existing SDK output; choose a new path")
    free = shutil.disk_usage(REPO).free
    if free < 8 * 1024 ** 3:
        raise ValueError("Xcode Cloud SDK build exceeded its resource bound")
    CLOUD_DEADLINE, CLOUD_DISK = time.monotonic() + 1800, (REPO, free)
    tools.mkdir(parents=True)
    env = dict(os.environ, CARGO_HOME=str(tools / "cargo"), RUSTUP_HOME=str(tools / "rustup"),
               CARGO_NET_RETRY="0", CARGO_HTTP_TIMEOUT="30", CARGO_BUILD_JOBS="2", RUSTUP_MAX_RETRIES="0",
               HOMEBREW_NO_AUTO_UPDATE="1", HOMEBREW_NO_INSTALL_UPGRADE="1", HOMEBREW_NO_INSTALL_CLEANUP="1",
               HOMEBREW_CURL_RETRIES="0")
    print("NATIVE_REMOTE_SDK_STAGE python-bootstrap (requires Python 3.11+)", flush=True)
    lock_python = apple_cloud_python(out, env)
    print("NATIVE_REMOTE_SDK_STAGE rust-bootstrap", flush=True)
    rustup = shutil.which("rustup")
    if rustup is None:
        brew = shutil.which("brew")
        if brew is None:
            raise ValueError("Xcode Cloud Rust bootstrap is unavailable")
        run([brew, "install", "--force-bottle", "rustup"], env, 300)
        # Homebrew's rustup formula is keg-only; don't depend on shell init files.
        prefix = subprocess.check_output([brew, "--prefix", "rustup"], env=env, text=True, timeout=15).strip()
        rustup = str(Path(prefix) / "bin/rustup")
    if not Path(rustup).is_file():
        raise ValueError("Xcode Cloud Rust bootstrap is unavailable")
    # A Homebrew /opt/homebrew/bin/rustup symlink may coexist with standalone
    # Homebrew cargo, which cannot interpret +1.90.0. Select rustup's sibling
    # cargo/rustc proxies rather than depending on the global PATH ordering.
    proxies = Path(rustup).resolve().parent
    if not all((proxies / name).is_file() for name in ("cargo", "rustc")):
        raise ValueError("Xcode Cloud Rust bootstrap is unavailable")
    env["PATH"] = str(proxies) + os.pathsep + env["PATH"]
    run([rustup, "toolchain", "install", "1.90.0", "--profile", "minimal", "--no-self-update",
         "--target", ",".join(TARGETS["apple"])], env, 600)
    # Keep one supervising process: nested process groups could otherwise leave
    # rustc running after an outer bootstrap/build deadline kills its supervisor.
    print("NATIVE_REMOTE_SDK_STAGE source-validation-and-build", flush=True)
    build(out, "apple", environment=env, lock_python=lock_python)
    verify(out, "apple")
    apple_link_contract(out)
    if time.monotonic() >= CLOUD_DEADLINE:
        raise ValueError("Xcode Cloud SDK build exceeded its resource bound")
    with marker.open("x") as stream:
        stream.write(digest(out / RECEIPT) + "\n")


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


def build(out: Path, platform: str, *, environment: dict[str, str] | None = None, lock_python: str | None = None) -> None:
    global CLOUD_DEADLINE, CLOUD_DISK
    cloud_build = os.environ.get("GITHUB_ACTIONS") != "true" or os.environ.get("CI") != "true"
    if cloud_build:
        if platform != "apple":
            raise ValueError("Native SDK compilation is restricted to the bounded hosted workflow")
        require_apple_cloud(out)
        free = shutil.disk_usage(REPO).free
        if free < 4 * 1024 ** 3:
            raise ValueError("Xcode Cloud SDK build exceeded its resource bound")
        CLOUD_DEADLINE = min(CLOUD_DEADLINE or float("inf"), time.monotonic() + 1500)
        CLOUD_DISK = CLOUD_DISK or (REPO, free)
    if out.exists() or out.is_symlink():
        raise ValueError("Preserve existing SDK output; choose a new path")
    if cloud_build:
        lock_python = lock_python or apple_cloud_python(out, dict(os.environ if environment is None else environment))
    if lock_python is None:
        from verify_build_gate import require_locked
        require_locked()
    else:
        try:
            run([lock_python, "-I", "-B", str(ROOT / "tools/verify_build_gate.py")],
                dict(os.environ if environment is None else environment), 15, quiet=True)
        except subprocess.CalledProcessError:
            raise ValueError("Native SDK source validation failed") from None
    out.mkdir(parents=True)
    work = out / "work"
    work.mkdir()
    env = dict(os.environ if environment is None else environment,
               CARGO_TARGET_DIR=str(work / "target"), CARGO_NET_RETRY="0", CARGO_HTTP_TIMEOUT="30", CARGO_BUILD_JOBS="2")
    if platform == "apple":
        # Rust 1.90's Mach-O strip can misalign proc-macro LINKEDIT data, which
        # macOS 27 rejects (rust-lang/rust#157750). Keep only build-time host
        # dependencies unstripped; target archives retain the release profile.
        env["CARGO_PROFILE_RELEASE_BUILD_OVERRIDE_STRIP"] = "none"
    run(["cargo", "+1.90.0", "build", "--locked", "--release", "--lib"], env)
    host_library = work / "target/release" / ("libquenderin_remote_crypto.dylib" if platform == "apple" else "libquenderin_remote_crypto.so")
    generated = work / "generated"
    run(["cargo", "+1.90.0", "run", "--locked", "--release", "--features", "bindgen", "--bin", "quenderin-remote-bindgen", "--", "generate", "--library", str(host_library), "--language", "swift", "--language", "kotlin", "--no-format", "--out-dir", str(generated)], env)
    if platform == "apple":
        env.update(IPHONEOS_DEPLOYMENT_TARGET="16.4", MACOSX_DEPLOYMENT_TARGET="13.3")
        for target in TARGETS[platform]:
            run(["cargo", "+1.90.0", "build", "--locked", "--release", "--lib", "--target", target], env)
        apple_proof = add_apple_archive_proof(work, env)
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
        receipt.update(deploymentTargets={"iOS": "16.4", "macOS": "13.3"}, appleLinkProof=apple_proof)
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
    for name in ("stage-apple-cloud", "apple-link-settings"):
        command = sub.add_parser(name)
        command.add_argument("--sdk", type=Path, required=True)
    args = parser.parse_args()
    try:
        # Do not resolve away an existing symlink before the preserve-path check.
        sdk = Path(os.path.abspath(args.sdk))
        if args.command == "build": build(sdk, args.platform)
        elif args.command == "verify": verify(sdk, args.platform)
        elif args.command == "stage-apple-cloud": stage_apple_cloud(sdk)
        elif args.command == "apple-link-settings": print(json.dumps(apple_link_settings(sdk)))
        else: verify_package(sdk, Path(os.path.abspath(args.package)))
    except Exception as error:
        print(f"Native SDK check failed: {failure_diagnostic(error)}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

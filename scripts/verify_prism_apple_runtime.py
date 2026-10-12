#!/usr/bin/env python3
"""Fail-closed Prism framework and signed Apple archive checks; never downloads a model."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import plistlib
import re
import struct
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent
FRAMEWORK = ROOT / "apple/QuenderinKit/Frameworks/prism-llama.xcframework"
STAMP = "quenderin-apple-runtime.json"
RELEASE_MARKER = ".quenderin-prism-release"
PROBE = {"PQ2_0": {"type": 142, "block": 128, "size": 34},
         "PTQ1_0": {"type": 143, "block": 128, "size": 28}}


def require(condition: bool, reason: str) -> None:
    if not condition:
        raise ValueError(reason)


def sha(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def run(*args: str) -> str:
    try:
        return subprocess.check_output(args, text=True, stderr=subprocess.STDOUT).strip()
    except subprocess.CalledProcessError as error:
        # Preserve compiler/signature diagnostics in the Cloud log so an actual
        # failed check can be diagnosed before anyone considers another run.
        raise ValueError(f"Native command failed ({args[0]}): {error.output[-8000:]}") from error


def catalog(root: Path, lock: dict) -> dict:
    data = json.loads((root / "shared/model-catalog.json").read_text())
    models = [m for m in data["models"] if m["id"] == lock["modelId"]]
    require(len(models) == 1, "Pinned Bonsai catalog entry is missing or duplicated")
    model = models[0]
    require(model.get("sha256") == lock["sha256"] and model.get("downloadBytes") == lock["downloadBytes"]
            and f'/resolve/{lock["modelRevision"]}/' in model["url"]
            and model["quantization"] == "PTQ1_0" and model["ramGb"] >= 7,
            "Bonsai catalog artifact or memory floor differs from the runtime lock")
    swift = (root / "apple/QuenderinKit/Sources/QuenderinKit/ModelCatalog.swift").read_text()
    match = re.search(r'ModelEntry\(\s*id: "bonsai2-27b",(.*?)\n\s*\),', swift, re.S)
    require(match is not None, "Native Bonsai catalog entry is missing")
    entry = match.group(1)
    for value in (model["filename"], model["url"], model["sha256"]):
        require(f'"{value}"' in entry, "Native and shared Bonsai artifact catalogs differ")
    require('quantization: "PTQ1_0"' in entry and 'ramGB: 7.0' in entry
            and 'downloadBytes: 5_946_648_928' in entry, "Native Bonsai quantization/size/memory floor differs")
    return model


def macho_payload(binary: Path) -> dict:
    """Hash loaded sections, invariant under Xcode thinning, stripping and signing.

    A whole-file digest cannot be compared after Apple adds a code signature.
    UUID, platform, deployment minimum and every non-zerofill section must match
    the verified input slice. The complete unsigned file is also hashed at build time.
    """
    data = binary.read_bytes()
    require(len(data) >= 32, f"Missing/truncated Mach-O binary: {binary}")
    magic = struct.unpack_from(">I", data)[0]
    offsets = [(0, len(data))]
    if magic in (0xCAFEBABE, 0xCAFEBABF):
        count = struct.unpack_from(">I", data, 4)[0]
        require(0 < count <= 8, "Invalid fat Mach-O architecture count")
        offsets = []
        width = 32 if magic == 0xCAFEBABF else 20
        for index in range(count):
            start = 8 + index * width
            fmt = ">IIQQII" if width == 32 else ">IIIII"
            record = struct.unpack_from(fmt, data, start)
            offsets.append((record[2], record[3]))
    result = {}
    for base, length in offsets:
        require(base + length <= len(data) and length >= 32, "Mach-O slice exceeds file")
        header = struct.unpack_from("<IIIIIIII", data, base)
        require(header[0] == 0xFEEDFACF and header[3] in (2, 6), "Expected 64-bit Mach-O executable/dylib")
        arch = {0x0100000C: "arm64", 0x01000007: "x86_64"}.get(header[1])
        require(arch is not None and arch not in result, "Unsupported/duplicate Mach-O architecture")
        cursor, end = base + 32, base + 32 + header[5]
        require(end <= base + length, "Invalid Mach-O load commands")
        digest, uuid, target, minimum, sections = hashlib.sha256(), None, None, None, 0
        for _ in range(header[4]):
            require(cursor + 8 <= end, "Truncated Mach-O command")
            command, size = struct.unpack_from("<II", data, cursor)
            require(size >= 8 and cursor + size <= end, "Invalid Mach-O command length")
            if command == 0x1B:
                uuid = data[cursor + 8:cursor + 24].hex()
            if command == 0x32:
                target, minimum = struct.unpack_from("<II", data, cursor + 8)
            elif command in (0x24, 0x25):
                target = 1 if command == 0x24 else 2
                minimum = struct.unpack_from("<I", data, cursor + 8)[0]
            if command == 0x19:
                count = struct.unpack_from("<I", data, cursor + 64)[0]
                require(72 + count * 80 <= size, "Invalid Mach-O section table")
                for index in range(count):
                    section = cursor + 72 + index * 80
                    section_name, segment_name = struct.unpack_from("<16s16s", data, section)
                    section_size, offset = struct.unpack_from("<QI", data, section + 40)
                    flags = struct.unpack_from("<I", data, section + 64)[0]
                    if flags & 0xFF in (1, 0xC, 0x12):  # zero-fill sections have no bytes
                        continue
                    require(offset + section_size <= length, "Mach-O section exceeds slice")
                    digest.update(segment_name + section_name + struct.pack("<QI", section_size, flags))
                    digest.update(data[base + offset:base + offset + section_size])
                    sections += 1
            cursor += size
        require(cursor == end and uuid is not None and target is not None and sections > 0,
                "Mach-O identity/platform/sections are incomplete")
        result[arch] = {"uuid": uuid, "platform": target, "minimumOS": minimum,
                        "sectionsSha256": digest.hexdigest()}
    return result


def tree_hashes(framework: Path) -> dict:
    result = {}
    for path in sorted(framework.rglob("*")):
        rel = path.relative_to(framework).as_posix()
        if rel in (STAMP, "quenderin-prism-runtime.json") or path.name == ".DS_Store":
            continue
        if path.is_symlink():
            require(path.resolve().is_relative_to(framework.resolve()), "Framework symlink escapes artifact")
            result[rel] = {"symlink": os.readlink(path)}
        elif path.is_file():
            result[rel] = sha(path)
    return result


def slices(framework: Path) -> list:
    info = plistlib.loads((framework / "Info.plist").read_bytes())
    result = []
    for lib in info["AvailableLibraries"]:
        identifier = lib["LibraryIdentifier"]
        require(Path(identifier).name == identifier and not identifier.startswith("."), "Invalid slice identifier")
        directory = framework / identifier
        binary = directory / lib["BinaryPath"]
        require(binary.resolve().is_relative_to(directory.resolve()), "Framework binary escapes slice")
        payload = macho_payload(binary)
        require(set(payload) == set(lib["SupportedArchitectures"]), "Declared and actual architectures differ")
        target = {("ios", None): 2, ("ios", "simulator"): 7, ("macos", None): 1}.get(
            (lib["SupportedPlatform"], lib.get("SupportedPlatformVariant")))
        require(target is not None and all(v["platform"] == target for v in payload.values()),
                "Unexpected framework platform or mislabeled Mach-O slice")
        expected_minimum = (13 << 16 | 3 << 8) if target == 1 else (16 << 16 | 4 << 8)
        require(all(v["minimumOS"] == expected_minimum for v in payload.values()),
                "Framework deployment minimum differs from the pinned Apple builder")
        header = directory / lib["LibraryPath"] / "Headers/ggml.h"
        require(all(t in header.read_text() for t in ("GGML_TYPE_PTQ1_0", "GGML_TYPE_PQ2_0")),
                "Prism headers missing from a framework slice")
        result.append({"id": identifier, "platform": lib["SupportedPlatform"],
                       "variant": lib.get("SupportedPlatformVariant"), "libraryPath": lib["LibraryPath"],
                       "binaryPath": lib["BinaryPath"], "payload": payload})
    require(len([s for s in result if s["platform"] == "ios" and s["variant"] is None]) == 1
            and len([s for s in result if s["platform"] == "macos"]) == 1,
            "Exactly one iOS device and one macOS slice are required")
    require(set(next(s for s in result if s["platform"] == "ios" and s["variant"] is None)["payload"]) == {"arm64"}
            and set(next(s for s in result if s["platform"] == "macos")["payload"]) == {"arm64", "x86_64"},
            "Release requires arm64 iOS and universal macOS")
    return result


def native_probe(framework: Path, headers: Path | None = None) -> dict:
    # Only the host Mac slice executes. iOS is verified against its built slice.
    headers = headers or framework / "Headers"
    header = headers / "ggml.h"
    require(header.is_file(), "Missing native framework headers")
    with tempfile.TemporaryDirectory(prefix="quenderin-prism-probe-") as scratch:
        source, executable = Path(scratch) / "probe.c", Path(scratch) / "probe"
        source.write_text('''#include <stdio.h>
#include <string.h>
#include "ggml.h"
int main(void) {
    const int ids[] = {142, 143};
    const char *names[] = {"pq2_0", "ptq1_0"};
    const size_t sizes[] = {34, 28};
    for (int i = 0; i < 2; ++i) {
        enum ggml_type t = (enum ggml_type) ids[i];
        const char *name = ggml_type_name(t);
        if (!name || strcmp(name, names[i]) || ggml_blck_size(t) != 128 || ggml_type_size(t) != sizes[i]) {
            fprintf(stderr, "Prism type %d does not match %s/128/%zu\\n", ids[i], names[i], sizes[i]);
            return 1;
        }
    }
    puts("Prism PQ2_0=142/128/34 PTQ1_0=143/128/28 verified");
    return 0;
}
''')
        run("xcrun", "--sdk", "macosx", "clang", "-arch", platform.machine(), "-I", str(headers),
            str(source), "-F", str(framework.parent), "-framework", "llama", "-Wl,-rpath," + str(framework.parent),
            "-o", str(executable))
        require(run(str(executable)) == "Prism PQ2_0=142/128/34 PTQ1_0=143/128/28 verified", "Native Prism probe failed")
    return PROBE


def verify_framework(framework: Path, root: Path = ROOT) -> dict:
    lock = json.loads((root / "shared/prism-runtime.json").read_text())
    provenance = json.loads((framework / "quenderin-prism-runtime.json").read_text())
    stamp = json.loads((framework / STAMP).read_text())
    require(stamp.get("version") == 1 and all(stamp.get(k) == lock[k] == provenance.get(k)
            for k in ("repository", "revision")), "Framework provenance differs from pinned runtime")
    require(stamp.get("nativeProbe") == PROBE, "Positive native Prism capability proof is missing")
    catalog(root, lock)
    require(stamp.get("catalogSha256") == sha(root / "shared/model-catalog.json")
            and stamp.get("nativeCatalogSha256") == sha(root / "apple/QuenderinKit/Sources/QuenderinKit/ModelCatalog.swift"),
            "Framework was verified against a different model catalog")
    require(stamp.get("files") == tree_hashes(framework), "Framework files changed after native verification")
    require(stamp.get("slices") == slices(framework), "Framework slice payload changed after native verification")
    return stamp


def seal(framework: Path, root: Path = ROOT) -> dict:
    require(not (framework / STAMP).exists(), "Preserve existing verification stamp; use a fresh artifact")
    lock = json.loads((root / "shared/prism-runtime.json").read_text())
    provenance = json.loads((framework / "quenderin-prism-runtime.json").read_text())
    require(all(provenance.get(k) == lock[k] for k in ("repository", "revision")), "Unverified Prism source provenance")
    catalog(root, lock)
    libraries = slices(framework)
    mac = next(s for s in libraries if s["platform"] == "macos")
    stamp = {"version": 1, "repository": lock["repository"], "revision": lock["revision"],
             "catalogSha256": sha(root / "shared/model-catalog.json"),
             "nativeCatalogSha256": sha(root / "apple/QuenderinKit/Sources/QuenderinKit/ModelCatalog.swift"),
             "nativeProbe": native_probe(framework / mac["id"] / mac["libraryPath"]),
             "slices": libraries, "files": tree_hashes(framework)}
    (framework / STAMP).write_text(json.dumps(stamp, indent=2, sort_keys=True) + "\n")
    return verify_framework(framework, root)


def release_profile(root: Path = ROOT) -> None:
    require(os.environ.get("QUENDERIN_RUNTIME") == "prism", "Release requires QUENDERIN_RUNTIME=prism")
    require(not os.environ.get("QUENDERIN_LLAMA_DIR"), "Release must use the verified cross-platform framework")
    require((root / "apple/QuenderinKit" / RELEASE_MARKER).read_text() == "prism\n",
            "Post-clone Prism release profile is missing")


def embed_evidence(app: Path, target: str, stamp: dict, root: Path = ROOT) -> None:
    require(target in ("ios", "macos"), "Only iOS device/macOS archives are supported")
    resources = app / "Contents/Resources" if target == "macos" else app
    resources.mkdir(parents=True, exist_ok=True)
    (resources / "quenderin-prism-release.json").write_text(json.dumps(stamp, indent=2, sort_keys=True) + "\n")
    (resources / "quenderin-model-catalog.json").write_bytes((root / "shared/model-catalog.json").read_bytes())


def verify_app(app: Path, target: str, stamp: dict, root: Path = ROOT, signed: bool = False,
               source_framework: Path = FRAMEWORK) -> dict:
    require(target in ("ios", "macos"), "Only iOS device/macOS archives are supported")
    contents = app / "Contents" if target == "macos" else app
    resources = contents / "Resources" if target == "macos" else contents
    info = plistlib.loads((contents / "Info.plist").read_bytes())
    require(info.get("CFBundleIdentifier") == "ai.quenderin.Quenderin", "Wrong archive bundle identifier")
    require(info.get("CFBundleShortVersionString") == "0.3.0"
            and str(info.get("CFBundleVersion", "")).isdigit() and int(info["CFBundleVersion"]) >= 12,
            "Wrong archive version or stale build counter")
    lib = next(s for s in stamp["slices"] if s["platform"] == target and s["variant"] is None)
    native = contents / "Frameworks/llama.framework"
    binary = native / ("Versions/A/llama" if target == "macos" else "llama")
    payload = macho_payload(binary)
    require(payload and all(value == lib["payload"].get(arch) for arch, value in payload.items()),
            "Archive does not contain the verified Prism binary payload")
    require(set(payload) == ({"arm64", "x86_64"} if target == "macos" else {"arm64"}),
            "Archive is missing required release architectures")
    executable = contents / ("MacOS/" + info["CFBundleExecutable"] if target == "macos" else info["CFBundleExecutable"])
    app_payload = macho_payload(executable)
    require(set(app_payload) == set(payload), "App and embedded framework architectures differ")
    require(all(v["platform"] == (1 if target == "macos" else 2) for v in app_payload.values()),
            "Archive executable has the wrong platform")
    require(all(v["minimumOS"] >= payload[arch]["minimumOS"] for arch, v in app_payload.items()),
            "App deployment minimum is below the embedded framework")
    linked = run("xcrun", "otool", "-L", str(executable))
    require("@rpath/llama.framework/" in linked, "App executable does not link the embedded Prism runtime")
    if signed:
        run("codesign", "--verify", "--deep", "--strict", str(app))
        for path in (app, native):
            details = run("codesign", "-d", "--verbose=4", str(path))
            require("TeamIdentifier=9M2B2P4KSA" in details and "Signature=adhoc" not in details,
                    "Archive app/runtime signature does not belong to the distribution team")
        require(json.loads((resources / "quenderin-prism-release.json").read_text()) == stamp,
                "Archive Prism provenance differs from the verified framework")
        require((resources / "quenderin-model-catalog.json").read_bytes() == (root / "shared/model-catalog.json").read_bytes(),
                "Archive catalog differs from verified source")
        if target == "macos":
            native_probe(native, source_framework / lib["id"] / lib["libraryPath"] / "Headers")
    else:
        embed_evidence(app, target, stamp, root)
    return {"platform": target, "version": info["CFBundleShortVersionString"], "build": str(info["CFBundleVersion"]),
            "architectures": sorted(payload), "runtimeRevision": stamp["revision"]}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("seal", "verify-framework", "activate", "verify-build", "verify-archive"))
    parser.add_argument("--framework", type=Path, default=FRAMEWORK)
    parser.add_argument("--app", type=Path)
    parser.add_argument("--archive", type=Path)
    parser.add_argument("--platform", choices=("iphoneos", "macosx", "ios", "macos"))
    args = parser.parse_args()
    try:
        if args.command == "seal":
            seal(args.framework)
            result = {"verified": str(args.framework), "nativeProbe": PROBE}
        else:
            stamp = verify_framework(args.framework)
            result = {"verified": str(args.framework), "revision": stamp["revision"]}
            if args.command == "activate":
                require(os.environ.get("QUENDERIN_RUNTIME") == "prism", "Cloud requires explicit QUENDERIN_RUNTIME=prism")
                marker = ROOT / "apple/QuenderinKit" / RELEASE_MARKER
                require(not marker.exists() and not marker.is_symlink(), "Preserve existing release profile marker")
                marker.write_text("prism\n")
            elif args.command in ("verify-build", "verify-archive"):
                release_profile()
                target = {"iphoneos": "ios", "macosx": "macos"}.get(args.platform, args.platform)
                if args.command == "verify-archive":
                    require(args.archive is not None, "--archive is required")
                    apps = list((args.archive / "Products/Applications").glob("*.app"))
                    require(len(apps) == 1, "Expected exactly one archived app")
                    app = apps[0]
                else:
                    require(args.app is not None, "--app is required")
                    app = args.app
                if args.command == "verify-build":
                    # Xcode may schedule package-framework copying after this
                    # script. Persist signed resources now; inspect the finished
                    # executable/runtime only in ci_post_xcodebuild.
                    embed_evidence(app, target, stamp)
                    result = {"embeddedReleaseEvidence": str(app), "runtimeRevision": stamp["revision"]}
                else:
                    result = verify_app(app, target, stamp, signed=True, source_framework=args.framework)
        print(json.dumps(result, sort_keys=True))
    except (ValueError, OSError, KeyError, TypeError, StopIteration, struct.error, subprocess.CalledProcessError) as error:
        parser.exit(1, f"Apple Prism runtime rejected: {error}\n")


if __name__ == "__main__":
    main()

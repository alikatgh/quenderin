#!/usr/bin/env python3
"""Fail-closed Prism framework and signed Apple distribution checks; never downloads a model."""
from __future__ import annotations

import argparse
import gzip
import hashlib
import io
import importlib.util
import json
import os
from pathlib import Path, PurePosixPath
import platform
import plistlib
import re
import shutil
import stat
import struct
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
import zipfile
import zlib

ROOT = Path(__file__).resolve().parent.parent
FRAMEWORK = ROOT / "apple/QuenderinKit/Frameworks/prism-llama.xcframework"
STAMP = "quenderin-apple-runtime.json"
RELEASE_MARKER = ".quenderin-prism-release"
PROBE = {"PQ2_0": {"type": 142, "block": 128, "size": 34},
         "PTQ1_0": {"type": 143, "block": 128, "size": 28}, "MuseSparkABI": 1, "WeeklyTextABI": 1,
         "BeamABI": 1, "VisionABI": 1}
SOURCE_SPEC = importlib.util.spec_from_file_location("quenderin_prism_source", Path(__file__).with_name("prepare_prism_runtime.py"))
source_runtime = importlib.util.module_from_spec(SOURCE_SPEC)
SOURCE_SPEC.loader.exec_module(source_runtime)
# No model belongs in an App Store export. Bound package work independently of
# compressed metadata, and reserve space rather than exhausting the Cloud disk.
MAX_EXPORT_BYTES = 2 * 1024 ** 3
MAX_EXPORT_ENTRIES = 100_000
EXPORT_DISK_RESERVE = 64 * 1024 ** 2


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
        llama_header = header.with_name("llama.h")
        require(llama_header.is_file() and "quenderin_muse_spark_runtime_abi" in llama_header.read_text(),
                "Muse capability header missing from a framework slice")
        require("quenderin_weekly_text_runtime_abi" in llama_header.read_text(),
                "Weekly text capability header missing from a framework slice")
        require("quenderin_beam_runtime_abi" in llama_header.read_text(), "Beam capability header missing")
        vision_header = header.with_name("quenderin_vision.h")
        require(vision_header.is_file() and "quenderin_vision_runtime_abi" in vision_header.read_text(), "Vision ABI header missing")
        # Inspect every architecture without executing an iOS/device binary.
        for arch in payload:
            symbols = run("xcrun", "nm", "-arch", arch, "-gU", str(binary))
            require(re.search(r"\b_quenderin_muse_spark_runtime_abi$", symbols, re.M) is not None,
                    f"Muse runtime capability symbol missing from {identifier}/{arch}")
            require(re.search(r"\b_quenderin_weekly_text_runtime_abi$", symbols, re.M) is not None,
                    f"Weekly text runtime capability symbol missing from {identifier}/{arch}")
            require(re.search(r"\b_quenderin_beam_runtime_abi$", symbols, re.M) is not None, f"Beam capability symbol missing from {identifier}/{arch}")
            for symbol in ("runtime_abi", "runtime_revision", "patch_sha256", "create", "load", "generate", "cancel", "free"):
                require(re.search(r"\b_quenderin_vision_" + symbol + r"$", symbols, re.M) is not None,
                        f"Vision {symbol} symbol missing from {identifier}/{arch}")
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
#include "llama.h"
#include "quenderin_vision.h"
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
    if (quenderin_muse_spark_runtime_abi() != 1) {
        fputs("Muse Spark runtime ABI mismatch\\n", stderr);
        return 1;
    }
    if (quenderin_weekly_text_runtime_abi() != 1) {
        fputs("Weekly text runtime ABI mismatch\\n", stderr);
        return 1;
    }
    if (quenderin_beam_runtime_abi() != 1) { return 1; }
    if (quenderin_vision_runtime_abi() != 1
        || strcmp(quenderin_vision_runtime_revision(), "VISION_REVISION")
        || strcmp(quenderin_vision_patch_sha256(), "VISION_PATCH_SHA256")) { return 1; }
    puts("Prism PQ2_0=142/128/34 PTQ1_0=143/128/28 MuseSparkABI=1 WeeklyTextABI=1 verified");
    return 0;
}
'''.replace("VISION_REVISION", source_runtime.LOCK["revision"])
   .replace("VISION_PATCH_SHA256", source_runtime.LOCK["visionPatch"]["sha256"]))
        run("xcrun", "--sdk", "macosx", "clang", "-arch", platform.machine(), "-I", str(headers),
            str(source), "-F", str(framework.parent), "-framework", "llama", "-Wl,-rpath," + str(framework.parent),
            "-o", str(executable))
        require(run(str(executable)) == "Prism PQ2_0=142/128/34 PTQ1_0=143/128/28 MuseSparkABI=1 WeeklyTextABI=1 verified", "Native Prism/Muse/weekly text probe failed")
    return PROBE


def verify_framework(framework: Path, root: Path = ROOT) -> dict:
    lock = json.loads((root / "shared/prism-runtime.json").read_text())
    provenance = json.loads((framework / "quenderin-prism-runtime.json").read_text())
    stamp = json.loads((framework / STAMP).read_text())
    identity = source_runtime.provenance(root, lock)
    require(stamp.get("version") == 1 and all(stamp.get(k) == identity[k] == provenance.get(k)
            for k in source_runtime.IDENTITY_FIELDS), "Framework provenance differs from pinned runtime/source patch")
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
    identity = source_runtime.provenance(root, lock)
    require(all(provenance.get(k) == identity[k] for k in source_runtime.IDENTITY_FIELDS), "Unverified Prism/Muse source provenance")
    catalog(root, lock)
    libraries = slices(framework)
    mac = next(s for s in libraries if s["platform"] == "macos")
    stamp = {**identity,
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
    verify_remote_sdk(root)


def remote_runtime():
    spec = importlib.util.spec_from_file_location("quenderin_remote_sdk", ROOT / "native/remote-crypto/tools/native_sdk.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def verify_remote_sdk(root: Path = ROOT) -> tuple[Path, dict]:
    module = remote_runtime()
    sdk = root / "apple/QuenderinKit/build/RemoteCryptoSDK"
    contract = module.apple_link_contract(sdk)
    marker = root / "apple/QuenderinKit" / module.APPLE_RELEASE_MARKER
    require(not marker.is_symlink() and marker.read_text() == contract["receiptSha256"] + "\n",
            "Post-clone remote crypto release profile is missing or stale")
    return sdk, contract


def remote_exports(binary: Path, contract: dict) -> dict:
    """Inspect dyld exports, which are separate from the stripped symbol table.

    Format and flags: Apple's xnu EXTERNAL_HEADERS/mach-o/loader.h. Required
    symbols must be strong regular definitions in executable sections of this
    image, never imports/reexports/absolute placeholders. The unique proof
    definition must come from the receipt-bound static archive itself.
    """
    architectures = macho_payload(binary)
    data = binary.read_bytes()
    magic = struct.unpack_from(">I", data)[0]
    offsets = [(0, len(data))]
    if magic in (0xCAFEBABE, 0xCAFEBABF):
        width = 32 if magic == 0xCAFEBABF else 20
        fmt = ">IIQQII" if width == 32 else ">IIIII"
        offsets = [(record[2], record[3]) for index in range(struct.unpack_from(">I", data, 4)[0])
                   for record in [struct.unpack_from(fmt, data, 8 + index * width)]]
    result = {}
    required = set(contract["symbols"]) | {contract["proofSymbol"]}
    for base, length in offsets:
        header = struct.unpack_from("<IIIIIIII", data, base)
        arch = {0x0100000C: "arm64", 0x01000007: "x86_64"}[header[1]]
        cursor, end = base + 32, base + 32 + header[5]
        ranges, text_address, executable = set(), None, []
        for _ in range(header[4]):
            command, size = struct.unpack_from("<II", data, cursor)
            if command == 0x19:
                require(size >= 72, "Invalid remote crypto Mach-O segment")
                name, vmaddr, _, fileoff, _, _, protection = struct.unpack_from("<16sQQQQii", data, cursor + 8)
                if name.rstrip(b"\0") == b"__TEXT" and fileoff == 0:
                    text_address = vmaddr
                count = struct.unpack_from("<I", data, cursor + 64)[0]
                for index in range(count):
                    section = cursor + 72 + index * 80
                    address, size_bytes = struct.unpack_from("<QQ", data, section + 32)
                    flags = struct.unpack_from("<I", data, section + 64)[0]
                    if protection & 4 and flags & 0x80000400:
                        executable.append((address, address + size_bytes))
            elif command == 0x80000033:
                require(size == 16, "Invalid remote crypto export command")
                ranges.add(struct.unpack_from("<II", data, cursor + 8))
            elif command in (0x22, 0x80000022):
                require(size == 48, "Invalid remote crypto dyld command")
                offset, amount = struct.unpack_from("<II", data, cursor + 40)
                if amount:
                    ranges.add((offset, amount))
            cursor += size
        require(cursor == end and len(ranges) == 1 and text_address is not None,
                "Remote crypto linked exports are missing")
        offset, amount = next(iter(ranges))
        require(0 < amount <= 16 * 1024 ** 2 and offset + amount <= length,
                "Remote crypto export trie exceeds bounds")
        trie = data[base + offset:base + offset + amount]

        def uleb(position):
            value = 0
            for shift in range(0, 64, 7):
                require(position < len(trie), "Truncated remote crypto export trie")
                byte = trie[position]
                position += 1
                require(shift < 63 or byte <= 1, "Oversized remote crypto export integer")
                value |= (byte & 127) << shift
                if byte < 128:
                    return value, position
            raise ValueError("Oversized remote crypto export integer")

        found, pending, visits = {}, [("", 0, frozenset())], 0
        while pending:
            prefix, node, ancestors = pending.pop()
            visits += 1
            require(visits <= 100_000 and len(prefix) <= 2048 and len(ancestors) <= 256
                    and node not in ancestors, "Cyclic or oversized remote crypto export trie")
            terminal, position = uleb(node)
            children = position + terminal
            require(children < len(trie), "Truncated remote crypto export terminal")
            if terminal and prefix in required:
                flags, address_at = uleb(position)
                address, after = uleb(address_at)
                require(flags == 0 and after == children and prefix not in found
                        and any(start <= text_address + address < finish for start, finish in executable),
                        "Remote crypto export is not a linked executable definition")
                found[prefix] = address
            count, position = trie[children], children + 1
            for _ in range(count):
                terminator = trie.find(b"\0", position)
                require(terminator > position and terminator - position <= 2048,
                        "Invalid remote crypto export edge")
                edge = trie[position:terminator].decode("utf-8")
                child, position = uleb(terminator + 1)
                pending.append((prefix + edge, child, ancestors | {node}))
        require(set(found) == required, "App executable omits the verified remote crypto payload")
        result[arch] = found
    require(set(result) == set(architectures), "Remote crypto exports are missing an architecture")
    return result


def embed_remote_evidence(app: Path, target: str, root: Path = ROOT) -> None:
    sdk, _ = verify_remote_sdk(root)
    resources = app / "Contents/Resources" if target == "macos" else app
    (resources / "quenderin-remote-sdk.json").write_bytes((sdk / "quenderin-remote-sdk.json").read_bytes())


def verify_remote_app(app: Path, target: str, root: Path = ROOT) -> None:
    sdk, contract = verify_remote_sdk(root)
    contents = app / "Contents" if target == "macos" else app
    resources = contents / "Resources" if target == "macos" else contents
    require((resources / "quenderin-remote-sdk.json").read_bytes() == (sdk / "quenderin-remote-sdk.json").read_bytes(),
            "Signed app remote crypto receipt differs from the verified SDK")
    info = plistlib.loads((contents / "Info.plist").read_bytes())
    executable = contents / ("MacOS/" + info["CFBundleExecutable"] if target == "macos" else info["CFBundleExecutable"])
    exports = remote_exports(executable, contract)
    require(set(exports) == ({"arm64", "x86_64"} if target == "macos" else {"arm64"}),
            "Signed app remote crypto payload is missing release architectures")


def embed_evidence(app: Path, target: str, stamp: dict, root: Path = ROOT) -> None:
    require(target in ("ios", "macos"), "Only iOS device/macOS archives are supported")
    resources = app / "Contents/Resources" if target == "macos" else app
    resources.mkdir(parents=True, exist_ok=True)
    (resources / "quenderin-prism-release.json").write_text(json.dumps(stamp, indent=2, sort_keys=True) + "\n")
    (resources / "quenderin-model-catalog.json").write_bytes((root / "shared/model-catalog.json").read_bytes())
    embed_image_evidence(app, target, root)
    embed_remote_evidence(app, target, root)


def image_runtime():
    spec = importlib.util.spec_from_file_location('quenderin_apple_image', Path(__file__).with_name('verify_diffusion_apple_runtime.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def embed_image_evidence(app: Path, target: str, root: Path) -> None:
    image_runtime().embed_evidence(app, target, root)


def verify_image_app(app: Path, target: str, root: Path, signed: bool) -> dict:
    return image_runtime().verify_app(app, target, root, signed)


def release_version(root: Path = ROOT) -> tuple[str, int]:
    spec = (root / "apple/QuenderinApp/project.yml").read_text()
    versions = re.findall(r'(?m)^[ \t]+MARKETING_VERSION:[ \t]*"([0-9]+\.[0-9]+\.[0-9]+)"[ \t]*$', spec)
    builds = re.findall(r'(?m)^[ \t]+CURRENT_PROJECT_VERSION:[ \t]*([0-9]+)[ \t]*$', spec)
    require(len(versions) == len(builds) == 2 and len(set(versions)) == len(set(builds)) == 1,
            "Both Apple targets must declare matching release versions and build counters")
    return versions[0], int(builds[0])


def verify_app(app: Path, target: str, stamp: dict, root: Path = ROOT, signed: bool = False,
               source_framework: Path = FRAMEWORK) -> dict:
    require(target in ("ios", "macos"), "Only iOS device/macOS archives are supported")
    contents = app / "Contents" if target == "macos" else app
    resources = contents / "Resources" if target == "macos" else contents
    info = plistlib.loads((contents / "Info.plist").read_bytes())
    require(info.get("CFBundleIdentifier") == "ai.quenderin.Quenderin", "Wrong archive bundle identifier")
    version, minimum_build = release_version(root)
    require(info.get("CFBundleShortVersionString") == version
            and str(info.get("CFBundleVersion", "")).isdigit() and int(info["CFBundleVersion"]) >= minimum_build,
            f"Wrong archive version or stale build counter; expected {version} with build >= {minimum_build}")
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
    verify_image_app(app, target, root, signed)
    if signed:
        verify_remote_app(app, target, root)
    return {"platform": target, "version": info["CFBundleShortVersionString"], "build": str(info["CFBundleVersion"]),
            "architectures": sorted(payload), "runtimeRevision": stamp["revision"]}


def export_member(name: str) -> PurePosixPath:
    require(name and len(name.encode("utf-8")) <= 4096 and "\\" not in name and "\x00" not in name,
            "Unsafe export member name")
    path = PurePosixPath(name)
    require(not path.is_absolute() and ".." not in path.parts and len(path.parts) <= 32,
            "Export member escapes extraction directory or exceeds the depth limit")
    return path


def validate_export_app(app: Path) -> None:
    require(app.is_dir() and not app.is_symlink(), "Export app must be a real directory")
    total, count = 0, 0
    for path in app.rglob("*"):
        count += 1
        require(count <= MAX_EXPORT_ENTRIES, "Too many export entries")
        mode = path.lstat().st_mode
        if stat.S_ISLNK(mode):
            require(path.resolve().is_relative_to(app.resolve()), "Export symlink escapes app")
        else:
            require(stat.S_ISREG(mode) or stat.S_ISDIR(mode), "Unsafe export file type")
            total += path.stat().st_size if stat.S_ISREG(mode) else 0
            require(total <= MAX_EXPORT_BYTES, "Export exceeds the unpacked size limit")


def extract_entry(destination: Path, path: PurePosixPath, mode: int, size: int,
                  source, links: list) -> None:
    """Write only fresh regular files; create validated symlinks after all files.

    Deferring links prevents an archive member from redirecting any later write.
    Never invoke an installer, restore ownership, or apply setuid permission bits.
    """
    require(0 <= size <= MAX_EXPORT_BYTES, "Export entry exceeds the size limit")
    output = destination.joinpath(*path.parts)
    kind = stat.S_IFMT(mode)
    require(shutil.disk_usage(destination).free >= size + EXPORT_DISK_RESERVE,
            "Insufficient scratch space for signed export verification")
    if kind == stat.S_IFDIR:
        require(size == 0, "Export directory has unexpected data")
        output.mkdir(parents=True, exist_ok=True)
        return
    require(kind in (stat.S_IFREG, stat.S_IFLNK), "Unsafe export file type")
    output.parent.mkdir(parents=True, exist_ok=True)
    if kind == stat.S_IFLNK:
        require(size <= 4096, "Export symlink target is too long")
        target = source.read(size)
        require(len(target) == size, "Truncated export symlink")
        target = target.decode("utf-8")
        require(target and not target.startswith("/") and "\\" not in target and "\x00" not in target
                and (output.parent / target).resolve().is_relative_to(destination.resolve()),
                "Export symlink escapes extraction directory")
        links.append((output, target))
        return
    with output.open("xb") as sink:
        remaining = size
        while remaining:
            chunk = source.read(min(remaining, 1024 * 1024))
            require(chunk, "Truncated export file")
            sink.write(chunk)
            remaining -= len(chunk)
    output.chmod(mode & 0o777)


def finish_export_links(links: list) -> None:
    for path, target in links:
        require(not path.exists() and not path.is_symlink(), "Duplicate export path")
        path.symlink_to(target)


def extract_ipa(package: Path, destination: Path) -> Path:
    # ZipFile reads the central directory eagerly. Bound that read before opening
    # it; this app's <2 GB package never needs a ZIP64 or split-volume container.
    with package.open("rb") as source:
        source.seek(max(0, package.stat().st_size - 65_557))
        tail = source.read()
    end = tail.rfind(b"PK\x05\x06")
    require(end >= 0 and len(tail) - end >= 22, "Missing IPA ZIP directory")
    _, disk, directory_disk, disk_entries, entries, directory_size, directory_offset, comment = struct.unpack_from(
        "<4s4H2IH", tail, end)
    require(disk == directory_disk == 0 and disk_entries == entries < 65_535 and entries <= MAX_EXPORT_ENTRIES
            and directory_size <= 16 * 1024 ** 2 and directory_offset + directory_size <= package.stat().st_size
            and end + 22 + comment == len(tail), "Unsupported or oversized IPA ZIP directory")
    with zipfile.ZipFile(package) as archive:
        entries = archive.infolist()
        require(len(entries) <= MAX_EXPORT_ENTRIES, "Too many export entries")
        require(sum(e.file_size for e in entries) <= MAX_EXPORT_BYTES, "Export exceeds the unpacked size limit")
        seen, links = set(), []
        for entry in entries:
            path = export_member(entry.filename)
            key = str(path).casefold()
            require(key not in seen and not entry.flag_bits & 1, "Duplicate or encrypted export entry")
            seen.add(key)
            mode = entry.external_attr >> 16
            kind = stat.S_IFMT(mode)
            require(kind in (0, stat.S_IFREG, stat.S_IFDIR, stat.S_IFLNK), "Unsafe export file type")
            require(path.parts and path.parts[0] in ("Payload", "SwiftSupport", "Symbols", "BCSymbolMaps", "Signatures")
                    or len(path.parts) == 1, "Unexpected IPA top-level directory")
            if not path.parts or path.parts[0] != "Payload":
                # Auxiliary Swift/symbol/framework-signature files are not part
                # of the signed app. Their names, types and sizes remain bounded.
                require(kind != stat.S_IFLNK, "Unexpected auxiliary export symlink")
                continue
            mode = mode if kind else (stat.S_IFDIR | 0o755 if entry.is_dir() else stat.S_IFREG | 0o644)
            with archive.open(entry) as source:
                extract_entry(destination, path, mode, entry.file_size, source, links)
        finish_export_links(links)
    apps = list((destination / "Payload").glob("*.app"))
    require(len(apps) == 1, "Expected exactly one app in IPA Payload")
    return apps[0]


def pkg_payload(package: Path) -> tuple:
    """Locate the single component Payload without expanding the XAR container.

    Xcode's App Store product package stores a gzip CPIO Payload verbatim in XAR.
    Inspect bounded metadata and read only that range; never execute package scripts.
    """
    with package.open("rb") as source:
        header = source.read(28)
        require(len(header) == 28, "Truncated PKG header")
        magic, header_size, version, compressed, plain, _ = struct.unpack(">4sHHQQI", header)
        require(magic == b"xar!" and version == 1 and 28 <= header_size <= 4096,
                "Unsupported PKG container")
        require(0 < compressed <= 8 * 1024 ** 2 and 0 < plain <= 8 * 1024 ** 2,
                "PKG table of contents exceeds the size limit")
        source.seek(header_size)
        inflater = zlib.decompressobj()
        xml = inflater.decompress(source.read(compressed), plain + 1)
        require(inflater.eof and not inflater.unused_data and len(xml) == plain,
                "Invalid PKG table of contents")
        require(b"<!DOCTYPE" not in xml and b"<!ENTITY" not in xml, "Unsafe PKG XML declaration")
        toc = ET.fromstring(xml)
        heap, payloads, seen = header_size + compressed, [], set()

        def visit(node, parent=PurePosixPath("."), depth=0):
            require(depth < 16 and len(seen) < MAX_EXPORT_ENTRIES, "PKG metadata exceeds the entry limit")
            names = [n.text for n in node.findall("name")]
            require(names and all(n == names[0] for n in names) and names[0]
                    and "/" not in names[0], "Unsafe PKG member name")
            path = parent / export_member(names[0])
            key = str(path).casefold()
            require(key not in seen, "Duplicate PKG member")
            seen.add(key)
            kind = node.findtext("type")
            require(kind in ("file", "directory"), "Unsafe PKG member type")
            if kind == "file":
                data = node.find("data")
                require(data is not None, "Missing PKG member data")
                offset, length, size = (int(data.findtext(k)) for k in ("offset", "length", "size"))
                require(0 <= offset and 0 <= length <= MAX_EXPORT_BYTES and 0 <= size <= MAX_EXPORT_BYTES
                        and heap + offset + length <= package.stat().st_size, "PKG member exceeds container bounds")
                if path.name == "Payload":
                    encoding = data.find("encoding")
                    require(len(path.parts) in (1, 2) and (len(path.parts) == 1 or path.parent.suffix == ".pkg")
                            and encoding is not None and encoding.get("style") == "application/octet-stream"
                            and size == length, "Unsupported PKG Payload layout")
                    payloads.append((heap + offset, length))
            else:
                for child in node.findall("file"):
                    visit(child, path, depth + 1)

        require(toc.tag == "xar" and toc.find("toc") is not None, "Missing PKG table of contents")
        for node in toc.findall("./toc/file"):
            visit(node)
        require(len(payloads) == 1, "Expected exactly one PKG component Payload")
        return payloads[0]


class PackageRange(io.RawIOBase):
    def __init__(self, source, offset: int, length: int):
        self.source, self.remaining = source, length
        source.seek(offset)

    def read(self, size=-1):
        size = self.remaining if size < 0 else min(size, self.remaining)
        data = self.source.read(size)
        self.remaining -= len(data)
        return data


def extract_pkg(package: Path, destination: Path) -> Path:
    offset, length = pkg_payload(package)
    seen, links, total = set(), [], 0
    with package.open("rb") as container:
        source = PackageRange(container, offset, length)
        require(source.read(2) == b"\x1f\x8b", "Unsupported PKG Payload compression; expected Xcode gzip CPIO")
        source = PackageRange(container, offset, length)
        with gzip.GzipFile(fileobj=source) as payload:
            for _ in range(MAX_EXPORT_ENTRIES):
                header = payload.read(76)
                require(len(header) == 76 and header[:6] == b"070707", "Unsupported/truncated PKG CPIO header")
                mode, name_size, size = (int(header[a:b], 8) for a, b in ((18, 24), (59, 65), (65, 76)))
                require(0 < name_size <= 4096, "Invalid PKG CPIO member name length")
                name = payload.read(name_size)
                require(len(name) == name_size and name[-1:] == b"\x00", "Truncated PKG CPIO member name")
                name = name[:-1].decode("utf-8")
                if name == "TRAILER!!!":
                    trailer = payload.read(1025)
                    require(size == 0 and len(trailer) <= 1024 and not trailer.strip(b"\x00"),
                            "Invalid PKG CPIO trailer")
                    break
                path = export_member(name)
                key = str(path).casefold()
                require(key not in seen, "Duplicate export path")
                seen.add(key)
                total += size
                require(total <= MAX_EXPORT_BYTES, "Export exceeds the unpacked size limit")
                extract_entry(destination, path, mode, size, payload, links)
            else:
                raise ValueError("Too many export entries")
    finish_export_links(links)
    # Both supported install-location conventions are explicit; do not search
    # arbitrary package paths for something that happens to resemble an app.
    apps = list(destination.glob("*.app")) + list((destination / "Applications").glob("*.app"))
    require(len(apps) == 1, "Expected exactly one exported PKG app")
    return apps[0]


def verify_distribution(export: Path, target: str, stamp: dict, root: Path = ROOT,
                        source_framework: Path = FRAMEWORK) -> dict:
    require(target in ("ios", "macos"), "Only iOS device/macOS distributions are supported")
    require(export.exists() and not export.is_symlink(), "App Store signed export is missing or is a symlink")
    if export.is_dir() and export.suffix != ".app":
        candidates = [p for p in export.iterdir() if p.suffix.lower() in (".app", ".ipa", ".pkg")]
        require(len(candidates) == 1, "Expected exactly one app/package in App Store signed export directory")
        export = candidates[0]
        require(not export.is_symlink(), "App Store signed export is a symlink")
    if export.is_dir() and export.suffix == ".app":
        validate_export_app(export)
        return verify_app(export, target, stamp, root, signed=True, source_framework=source_framework)
    require(export.is_file() and export.suffix.lower() == (".ipa" if target == "ios" else ".pkg"),
            "Wrong package type for App Store signed export platform")
    require(export.stat().st_size <= MAX_EXPORT_BYTES, "Export package exceeds the size limit")
    if target == "macos":
        # Require pkgutil's successful trust check. Cloud managed signing uses
        # "issued by Apple (Development)" wording even for its App Store export.
        signature = run("pkgutil", "--check-signature", str(export))
        leaves = re.findall(r"(?m)^[ \t]*1\.[ \t]+([^\r\n]+)$", signature)
        require(len(leaves) == 1 and re.fullmatch(r"3rd Party Mac Developer Installer: .+ \(9M2B2P4KSA\)", leaves[0].strip()),
                "App Store PKG must have a trusted installer signature for team 9M2B2P4KSA")
    with tempfile.TemporaryDirectory(prefix="quenderin-app-store-") as scratch:
        app = (extract_ipa if target == "ios" else extract_pkg)(export, Path(scratch))
        validate_export_app(app)
        return verify_app(app, target, stamp, root, signed=True, source_framework=source_framework)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("seal", "verify-framework", "verify-release", "activate", "verify-build", "verify-archive", "verify-distribution"))
    parser.add_argument("--framework", type=Path, default=FRAMEWORK)
    parser.add_argument("--app", type=Path)
    parser.add_argument("--archive", type=Path)
    parser.add_argument("--distribution", type=Path)
    parser.add_argument("--platform", choices=("iphoneos", "macosx", "ios", "macos"))
    args = parser.parse_args()
    try:
        if args.command == "seal":
            seal(args.framework)
            result = {"verified": str(args.framework), "nativeProbe": PROBE}
        else:
            stamp = verify_framework(args.framework)
            result = {"verified": str(args.framework), "revision": stamp["revision"]}
            if args.command == "verify-release":
                release_profile()
            elif args.command == "activate":
                require(os.environ.get("QUENDERIN_RUNTIME") == "prism", "Cloud requires explicit QUENDERIN_RUNTIME=prism")
                marker = ROOT / "apple/QuenderinKit" / RELEASE_MARKER
                require(not marker.exists() and not marker.is_symlink(), "Preserve existing release profile marker")
                verify_remote_sdk()
                marker.write_text("prism\n")
            elif args.command in ("verify-build", "verify-archive", "verify-distribution"):
                release_profile()
                target = {"iphoneos": "ios", "macosx": "macos"}.get(args.platform, args.platform)
                if args.command == "verify-distribution":
                    require(args.distribution is not None, "--distribution is required")
                    result = verify_distribution(args.distribution, target, stamp, source_framework=args.framework)
                elif args.command == "verify-archive":
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
                elif args.command == "verify-archive":
                    result = verify_app(app, target, stamp, signed=True, source_framework=args.framework)
        print(json.dumps(result, sort_keys=True))
    except (ValueError, OSError, KeyError, TypeError, StopIteration, struct.error, subprocess.CalledProcessError,
            ET.ParseError, zipfile.BadZipFile, zlib.error, EOFError, RuntimeError) as error:
        parser.exit(1, f"Apple Prism runtime rejected: {error}\n")


if __name__ == "__main__":
    main()

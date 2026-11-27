#!/usr/bin/env python3
"""Verify/fetch pinned speech-runtime source and GGUF manifests; never fetch model weights."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess

ROOT = Path(__file__).resolve().parent.parent
LOCK_PATH = ROOT / "shared/speech-runtime.json"
CATALOG_PATH = ROOT / "shared/speech-model-catalog.json"
SYNCED_CATALOGS = (
    ROOT / "apple/QuenderinKit/Sources/QuenderinKit/Resources/speech-model-catalog.json",
    ROOT / "android/app/src/main/assets/speech-model-catalog.json",
    ROOT / "website/data/speech-model-catalog.json",
)
EXPORTS = {"quenderin_speech_" + name for name in (
    "abi", "revision", "create", "destroy", "cancel", "validate", "transcribe", "result_free")}


def relative(value: str) -> str:
    if (not isinstance(value, str) or not value or PurePosixPath(value).is_absolute()
            or any(p in ("", ".", "..", ".git") for p in value.split("/"))
            or "\\" in value or any(ord(c) < 32 for c in value)):
        raise ValueError("Unsafe speech manifest-relative path")
    return value


def manifests() -> tuple[dict, dict]:
    lock = json.loads(LOCK_PATH.read_text(encoding="utf-8"))
    catalog = json.loads(CATALOG_PATH.read_text(encoding="utf-8"))
    hex_meta = lock.get("hex", {})
    if (lock.get("version") != 1 or lock.get("abiVersion") != 1
            or lock.get("repository") != "https://github.com/anomalyco/transcribe.cpp.git"
            or not re.fullmatch(r"[0-9a-f]{40}", lock.get("revision", ""))
            or hex_meta.get("repository") != "https://github.com/anomalyco/hex.git"
            or not re.fullmatch(r"[0-9a-f]{40}", hex_meta.get("revision", ""))
            or lock.get("inferenceVerified") is not False):
        raise ValueError("Speech runtime identity is invalid")
    vad = catalog.get("vad", {})
    if (vad.get("id") != "silero_vad_v6_2"
            or not re.fullmatch(r"[0-9a-f]{40}", vad.get("revision", ""))
            or not re.fullmatch(r"[0-9a-f]{64}", vad.get("sha256", ""))
            or type(vad.get("bytes")) is not int or vad["bytes"] <= 0):
        raise ValueError("Speech VAD provenance is invalid")
    models = catalog.get("models", [])
    if catalog.get("version") != 1 or len(models) != 20:
        raise ValueError("Speech catalog must include all 20 pinned Hex speech entries")
    seen_ids = set()
    seen_local = set()
    for model in models:
        mid = relative(model.get("id", ""))
        if mid in seen_ids:
            raise ValueError(f"Duplicate speech model id: {mid}")
        seen_ids.add(mid)
        if model.get("engine") == "apple_speech":
            continue
        if model.get("engine") != "transcribe.cpp":
            raise ValueError(f"Unsupported speech engine for {mid}")
        local_name = relative(model.get("localFilename", ""))
        if "/" in local_name or local_name in seen_local:
            raise ValueError(f"Duplicate or unsafe speech filename: {local_name}")
        seen_local.add(local_name)
        relative(model.get("filename", ""))
        if (not re.fullmatch(r"[\w.-]+/[\w.-]+", model.get("repo", ""))
                or not re.fullmatch(r"[0-9a-f]{40}", model.get("revision", ""))
                or not re.fullmatch(r"[0-9a-f]{64}", model.get("sha256", ""))
                or type(model.get("bytes")) is not int or model["bytes"] <= 0):
            raise ValueError(f"Incomplete provenance for speech model {mid}")
        if not (local_name.endswith(".gguf") or local_name.endswith(".bin")):
            raise ValueError(f"Invalid speech weight format for {mid}")
    canonical = CATALOG_PATH.read_bytes()
    for copy_path in SYNCED_CATALOGS:
        if copy_path.exists() and copy_path.read_bytes() != canonical:
            raise ValueError(f"Speech catalog drifted: {copy_path.relative_to(ROOT)}")
    return lock, catalog


def git(source: Path, *args: str) -> str:
    return subprocess.check_output(["git", "-C", str(source), *args], text=True).strip()


def verify(source: Path) -> dict:
    lock, _ = manifests()
    source = source.resolve(strict=True)
    if (git(source, "rev-parse", "HEAD") != lock["revision"]
            or git(source, "config", "--local", "--get-all", "remote.origin.url").removesuffix(".git")
            != lock["repository"].removesuffix(".git")):
        raise ValueError("Speech engine checkout does not match the pinned origin/revision")
    if git(source, "status", "--porcelain", "--untracked-files=all", "--ignore-submodules=none"):
        raise ValueError("Speech engine checkout has local changes")
    header = (source / "include/transcribe.h").read_text(encoding="utf-8")
    for api in ("transcribe_model_load_file", "transcribe_session_init", "transcribe_run", "transcribe_full_text", "transcribe_session_free"):
        if api not in header:
            raise ValueError("Pinned transcribe.h C API is incomplete")
    return {"version": 1, "abiVersion": lock["abiVersion"], "revision": lock["revision"]}


def fetch(destination: Path) -> dict:
    lock, _ = manifests()
    if destination.exists() or destination.is_symlink():
        raise ValueError("Destination exists; existing checkouts are preserved")
    destination.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(["git", "init", str(destination)], check=True, stdout=subprocess.DEVNULL)
    subprocess.run(["git", "-C", str(destination), "remote", "add", "origin", lock["repository"]], check=True)
    subprocess.run(["git", "-C", str(destination), "fetch", "--depth", "1", "origin", lock["revision"]], check=True)
    subprocess.run(["git", "-C", str(destination), "checkout", "--detach", lock["revision"]], check=True)
    return verify(destination)


def verify_model_file(model_id: str, directory: Path) -> dict:
    _, catalog = manifests()
    model = next((m for m in catalog["models"] if m["id"] == model_id), None)
    if model is None or model.get("engine") == "apple_speech":
        raise ValueError("Unknown or non-file speech model")
    if not directory.is_absolute() or directory.is_symlink() or directory.resolve(strict=True) != directory:
        raise ValueError("Speech model directory must be canonical, absolute, and not a symlink")
    path = directory / model["localFilename"]
    if path.is_symlink() or not path.is_file() or path.stat().st_size != model["bytes"]:
        raise ValueError(f"Speech model file is missing, unsafe or wrong size: {model['localFilename']}")
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while block := stream.read(1024 * 1024):
            digest.update(block)
    if digest.hexdigest() != model["sha256"]:
        raise ValueError(f"Speech model SHA-256 differs: {model['localFilename']}")
    return {"modelId": model_id, "path": str(path), "bytes": model["bytes"], "inferenceVerified": False}


def verify_library(library: Path, platform: str) -> dict:
    manifests()
    if platform == "apple":
        lines = subprocess.check_output(["nm", "-gU", str(library)], text=True).splitlines()
        names = {line.split()[-1] for line in lines if line.strip() and not line.rstrip().endswith(":")}
        names = {n[1:] if n.startswith("_") else n for n in names}
        names.discard("_mh_dylib_header")
    else:
        lines = subprocess.check_output(["nm", "-D", "--defined-only", str(library)], text=True).splitlines()
        names = {line.split()[-1].split("@")[0] for line in lines if line.strip() and not line.rstrip().endswith(":")}
        names.discard("QUENDERIN_SPEECH_1")
    if names != EXPORTS:
        raise ValueError(f"Speech exports must contain only quenderin_speech_* ABI; missing={sorted(EXPORTS - names)}, unexpected={sorted(names - EXPORTS)}")
    return {"library": str(library), "exportedSymbols": sorted(names), "isolated": True}


def desktop_cli_name() -> str:
    return "quenderin-speech-cli.exe" if os.name == "nt" else "quenderin-speech-cli"


def verify_desktop(directory: Path) -> dict:
    lock, _ = manifests()
    cli = directory.resolve(strict=True) / desktop_cli_name()
    if cli.is_symlink() or not cli.is_file():
        raise ValueError("Staged desktop speech CLI is missing or unsafe")
    identity = json.loads(subprocess.check_output([str(cli), "--version"], text=True, timeout=15))
    if identity.get("abiVersion") != lock["abiVersion"] or identity.get("revision") != lock["revision"]:
        raise ValueError("Desktop speech CLI does not match the pinned runtime")
    return {"abiVersion": lock["abiVersion"], "revision": lock["revision"], "inferenceVerified": False}


def build_desktop(work: Path) -> dict:
    target = subprocess.check_output(
        ["node", "-p", "({win32:'win',darwin:'mac',linux:'linux'})[process.platform] + '-' + ({arm:'armv7l'}[process.arch] || process.arch)"],
        text=True,
    ).strip()
    if not re.fullmatch(r"(win|mac|linux)-(x64|arm64|armv7l)", target):
        raise ValueError("Unsupported desktop speech host")
    work = work.resolve()
    source = work / "transcribe"
    if source.exists():
        verify(source)
    else:
        fetch(source)
    build = work / "build"
    platform_flags = []
    if target.startswith("win-"):
        platform_flags.append("-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded")
    elif target.startswith("mac-"):
        arch = "x86_64" if target.endswith("x64") else "arm64"
        platform_flags.extend(["-DCMAKE_OSX_DEPLOYMENT_TARGET=13.3", f"-DCMAKE_OSX_ARCHITECTURES={arch}"])
    subprocess.run([
        "cmake", "-S", str(ROOT / "native/speech"), "-B", str(build),
        f"-DTRANSCRIBE_SOURCE={source}", "-DCMAKE_BUILD_TYPE=Release",
        "-DBUILD_SHARED_LIBS=OFF", "-DCMAKE_BUILD_RPATH_USE_ORIGIN=ON",
        "-DGGML_NATIVE=OFF", "-DGGML_OPENMP=OFF", "-DGGML_BACKEND_DL=OFF", *platform_flags,
    ], check=True)
    subprocess.run([
        "cmake", "--build", str(build), "--config", "Release",
        "--target", "quenderin-speech-cli", "--parallel", "4",
    ], check=True)
    bin_dir = build / "bin"
    candidate = bin_dir / "Release"
    if (candidate / desktop_cli_name()).is_file():
        bin_dir = candidate
    verify_desktop(bin_dir)
    destination = ROOT / "build" / "speech" / target
    shutil.copytree(bin_dir, destination, symlinks=True, dirs_exist_ok=True)
    return verify_desktop(destination)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("check-manifests")
    p = sub.add_parser("fetch"); p.add_argument("--destination", type=Path, required=True)
    p = sub.add_parser("verify"); p.add_argument("--source", type=Path, required=True)
    p = sub.add_parser("verify-model"); p.add_argument("--model", required=True); p.add_argument("--directory", type=Path, required=True)
    p = sub.add_parser("verify-library"); p.add_argument("--library", type=Path, required=True); p.add_argument("--platform", choices=("apple", "elf"), required=True)
    p = sub.add_parser("build-desktop"); p.add_argument("--work", type=Path, required=True)
    p = sub.add_parser("verify-desktop"); p.add_argument("--directory", type=Path, required=True)
    args = parser.parse_args()
    try:
        if args.command == "check-manifests":
            lock, catalog = manifests()
            result = {"abiVersion": lock["abiVersion"], "models": [m["id"] for m in catalog["models"]]}
        elif args.command == "fetch":
            result = fetch(args.destination)
        elif args.command == "verify":
            result = verify(args.source)
        elif args.command == "verify-model":
            result = verify_model_file(args.model, args.directory)
        elif args.command == "verify-library":
            result = verify_library(args.library, args.platform)
        elif args.command == "build-desktop":
            result = build_desktop(args.work)
        else:
            result = verify_desktop(args.directory)
        print(json.dumps(result, sort_keys=True))
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
        parser.exit(1, f"Speech verification failed: {error}\n")


if __name__ == "__main__":
    main()

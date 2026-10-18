#!/usr/bin/env python3
"""Verify/fetch pinned image-runtime source; never fetch model weights or accept licenses."""
from __future__ import annotations
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
LOCK_PATH = ROOT / "shared/diffusion-runtime.json"
CATALOG_PATH = ROOT / "shared/image-model-catalog.json"
EXPORTS = {"quenderin_diffusion_" + name for name in (
    "abi", "revision", "create", "destroy", "validate", "generate", "cancel")}


def relative(value: str) -> str:
    if (not isinstance(value, str) or not value or PurePosixPath(value).is_absolute()
            or any(p in ("", ".", "..", ".git") for p in value.split("/"))
            or "\\" in value or any(ord(c) < 32 for c in value)):
        raise ValueError("Unsafe manifest-relative path")
    return value


def manifests() -> tuple[dict, dict]:
    lock, catalog = json.loads(LOCK_PATH.read_text()), json.loads(CATALOG_PATH.read_text())
    if (lock.get("version") != 1 or lock.get("abiVersion") != 1
            or lock.get("repository") != "https://github.com/leejet/stable-diffusion.cpp.git"
            or not re.fullmatch(r"[0-9a-f]{40}", lock.get("revision", ""))
            or lock.get("inferenceVerified") is not False):
        raise ValueError("Image runtime identity is invalid")
    submodules = lock.get("submodules", [])
    if len(submodules) != 1 or submodules[0].get("path") != "ggml" or submodules[0].get("repository") != "https://github.com/leejet/ggml.git" or not re.fullmatch(r"[0-9a-f]{40}", submodules[0].get("revision", "")):
        raise ValueError("Patched GGML source pin is invalid")
    models = catalog.get("models", [])
    expected = {"flux3-image-klein": 1, "moss-image-base": 2, "moss-image-sft": 3}
    if catalog.get("version") != 1 or len(models) != 3 or {m.get("id") for m in models} != set(expected):
        raise ValueError("Image model set is incomplete")
    for model in models:
        if type(model.get("modelKind")) is not int or model["modelKind"] != expected[model["id"]]:
            raise ValueError("Image model ABI kind is invalid")
        required = {"diffusion", "text_encoder", "vae"} | ({"tokenizer"} if model["modelKind"] != 1 else set())
        components = model.get("components", [])
        if len(components) != len(required) or {c.get("role") for c in components} != required:
            raise ValueError("Required image components are incomplete or duplicated")
        names = set()
        for component in components:
            relative(component["filename"])
            local_name = relative(component["localFilename"])
            if "/" in local_name or local_name in names:
                raise ValueError("Image component local name is duplicated or nested")
            names.add(local_name)
            if not re.fullmatch(r"[\w.-]+/[\w.-]+", component.get("repo", "")) or not re.fullmatch(r"[0-9a-f]{40}", component.get("revision", "")) or not re.fullmatch(r"[0-9a-f]{64}", component.get("sha256", "")) or type(component.get("bytes")) is not int or component["bytes"] <= 0:
                raise ValueError("Image component provenance is incomplete")
            suffix = {"text_encoder": ".gguf", "tokenizer": ".json"}.get(component["role"], ".safetensors")
            if not local_name.endswith(suffix):
                raise ValueError("Image component format is invalid")
        if model["modelKind"] == 1 and (model.get("requiresPublisherAccess") is not True or "not accepted" not in model.get("licenseAcceptance", "")):
            raise ValueError("FLUX publisher access and license review must remain explicit")
    return lock, catalog


def git(source: Path, *args: str) -> str:
    return subprocess.check_output(["git", "-C", str(source), *args], text=True).strip()


def verify(source: Path) -> dict:
    lock, _ = manifests()
    source = source.resolve(strict=True)
    if git(source, "rev-parse", "HEAD") != lock["revision"] or git(source, "config", "--local", "--get-all", "remote.origin.url").removesuffix(".git") != lock["repository"].removesuffix(".git"):
        raise ValueError("Diffusion checkout does not match the pinned source origin/revision")
    if git(source, "status", "--porcelain", "--untracked-files=all", "--ignore-submodules=none"):
        raise ValueError("Diffusion checkout has local changes; preserve them and use a clean source checkout")
    for component in lock["submodules"]:
        path = source / component["path"]
        if path.is_symlink() or path.resolve(strict=True) != path or git(path, "rev-parse", "HEAD") != component["revision"]:
            raise ValueError("Diffusion patched GGML revision is missing or different")
        if git(path, "config", "--local", "--get-all", "remote.origin.url").removesuffix(".git") != component["repository"].removesuffix(".git"):
            raise ValueError("Diffusion patched GGML origin differs")
        if git(path, "status", "--porcelain", "--untracked-files=all"):
            raise ValueError("Diffusion patched GGML source has changes")
    header = (source / "include/stable-diffusion.h").read_text()
    for api in ("new_sd_ctx", "generate_image", "free_sd_images", "sd_cancel_generation", "sd_ctx_params_init"):
        if api not in header:
            raise ValueError("Pinned diffusion C API is incomplete")
    return {"version": 1, "abiVersion": lock["abiVersion"], "repository": lock["repository"], "revision": lock["revision"], "submodules": lock["submodules"]}


def fetch(destination: Path) -> dict:
    lock, _ = manifests()
    if destination.exists() or destination.is_symlink():
        raise ValueError("Destination exists; existing files and checkouts are preserved")
    destination.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(["git", "init", str(destination)], check=True, stdout=subprocess.DEVNULL)
    subprocess.run(["git", "-C", str(destination), "remote", "add", "origin", lock["repository"]], check=True)
    subprocess.run(["git", "-C", str(destination), "fetch", "--depth", "1", "origin", lock["revision"]], check=True)
    subprocess.run(["git", "-C", str(destination), "checkout", "--detach", lock["revision"]], check=True)
    subprocess.run(["git", "-C", str(destination), "submodule", "update", "--init", "--depth", "1", "--", "ggml"], check=True)
    return verify(destination)


def verify_components(model_id: str, directory: Path) -> dict:
    _, catalog = manifests()
    model = next((m for m in catalog["models"] if m["id"] == model_id), None)
    if model is None:
        raise ValueError("Unknown image model")
    if not directory.is_absolute() or directory.is_symlink() or directory.resolve(strict=True) != directory:
        raise ValueError("Image installation directory must be canonical, absolute, and not a symlink")
    paths = {}
    for component in model["components"]:
        path = directory / component["localFilename"]
        if path.is_symlink() or not path.is_file() or path.stat().st_size != component["bytes"]:
            raise ValueError(f"Image component is missing, unsafe or the wrong size: {component['role']}")
        digest = hashlib.sha256()
        with path.open("rb") as stream:
            while block := stream.read(1024 * 1024):
                digest.update(block)
        if digest.hexdigest() != component["sha256"]:
            raise ValueError(f"Image component digest differs: {component['role']}")
        paths[component["role"]] = str(path)
    return {"modelId": model_id, "modelKind": model["modelKind"], "components": paths, "inferenceVerified": False}


def windows_exports(output: str, tool: str) -> set[str]:
    """Parse PE export names only; accept no decoration or forwarder aliasing."""
    if tool == "dumpbin":
        return {match.group(1) for line in output.splitlines()
                if (match := re.match(r"^\s*\d+\s+[0-9A-Fa-f]+\s+[0-9A-Fa-f]+\s+(\S+)(?:\s|$)", line))}
    if tool == "llvm-readobj":
        names = set()
        for block in re.findall(r"(?ms)^\s*Export\s*\{(.*?)^\s*\}", output):
            match = re.search(r"(?m)^\s*Name:\s*(\S+)\s*$", block)
            names.add(match.group(1) if match else "<unnamed-export>")
        return names
    raise ValueError("Unknown Windows export inspection tool")


def verify_library(library: Path, platform: str) -> dict:
    manifests()
    if platform == "windows":
        if inspector := shutil.which("dumpbin"):
            command, tool = [inspector, "/NOLOGO", "/EXPORTS", str(library)], "dumpbin"
        elif inspector := shutil.which("llvm-readobj"):
            command, tool = [inspector, "--coff-exports", str(library)], "llvm-readobj"
        else:
            raise ValueError("Windows export verification blocked: dumpbin or llvm-readobj is required")
        names = windows_exports(subprocess.check_output(command, text=True), tool)
    else:
        command = ["nm", "-gU", str(library)] if platform == "apple" else ["nm", "-D", "--defined-only", str(library)]
        lines = subprocess.check_output(command, text=True).splitlines()
        names = {line.split()[-1].split("@")[0] for line in lines if line.strip() and not line.rstrip().endswith(":")}
    if platform == "apple":
        names = {name[1:] if name.startswith("_") else name for name in names}
        names.discard("_mh_dylib_header")
    elif platform == "elf":
        names.discard("QUENDERIN_DIFFUSION_1")
    if names != EXPORTS:
        raise ValueError(f"Diffusion exports must contain only the shim ABI; missing={sorted(EXPORTS-names)}, unexpected={sorted(names-EXPORTS)}")
    return {"library": str(library), "exportedSymbols": sorted(names), "isolated": True}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("check-manifests")
    p = commands.add_parser("fetch"); p.add_argument("--destination", type=Path, required=True)
    p = commands.add_parser("verify"); p.add_argument("--source", type=Path, required=True)
    p = commands.add_parser("verify-components"); p.add_argument("--model", required=True); p.add_argument("--directory", type=Path, required=True)
    p = commands.add_parser("verify-library"); p.add_argument("--library", type=Path, required=True); p.add_argument("--platform", choices=("apple", "elf", "windows"), required=True)
    args = parser.parse_args()
    try:
        if args.command == "check-manifests":
            lock, catalog = manifests(); result = {"abiVersion": lock["abiVersion"], "models": [m["id"] for m in catalog["models"]]}
        elif args.command == "fetch": result = fetch(args.destination)
        elif args.command == "verify": result = verify(args.source)
        elif args.command == "verify-components": result = verify_components(args.model, args.directory)
        else: result = verify_library(args.library, args.platform)
        print(json.dumps(result, sort_keys=True))
    except (OSError, ValueError, KeyError, TypeError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"Diffusion verification failed: {error}\n")


if __name__ == "__main__":
    main()

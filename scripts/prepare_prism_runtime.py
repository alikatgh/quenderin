#!/usr/bin/env python3
"""Fetch/verify the exact Bonsai runtime without replacing an existing checkout."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
LOCK = json.loads((ROOT / "shared/prism-runtime.json").read_text())
STAMP = "quenderin-prism-runtime.json"
IDENTITY_FIELDS = ("repository", "revision", "sourcePatchId", "sourcePatchSha256", "museSparkABI")


def git(source: Path, *args: str) -> str:
    return subprocess.check_output(["git", "-C", str(source), *args], text=True).rstrip("\n")


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def relative_path(value: str) -> Path:
    path = PurePosixPath(value)
    if not value or path.is_absolute() or any(p in ("", ".", "..", ".git") for p in value.split("/")):
        raise ValueError("Unsafe runtime patch path")
    return Path(*path.parts)


def load_source_patch(root: Path | None = None, lock: dict | None = None) -> dict:
    root, lock = root or ROOT, lock or LOCK
    identity = lock["sourcePatch"]
    path = root / relative_path(identity["path"])
    if path.is_symlink() or not path.resolve().is_relative_to(root.resolve()):
        raise ValueError("Runtime patch manifest escapes the project")
    data = path.read_bytes()
    if digest(data) != identity["sha256"]:
        raise ValueError("Runtime source patch digest does not match the lock")
    manifest = json.loads(data)
    if (manifest.get("version") != 1 or manifest.get("id") != identity["id"]
            or manifest.get("baseRepository") != lock["repository"]
            or manifest.get("baseRevision") != lock["revision"]
            or manifest.get("upstreamRevision") != identity["upstreamRevision"]
            or manifest.get("museSparkABI") != identity["museSparkABI"]
            or type(manifest.get("museSparkABI")) is not int or manifest["museSparkABI"] != 1
            or manifest.get("capabilitySymbol") != "quenderin_muse_spark_runtime_abi"):
        raise ValueError("Runtime source patch identity is invalid")
    files = manifest.get("files", [])
    if not files or len(files) > 64:
        raise ValueError("Runtime source patch file set is invalid")
    seen = set()
    for entry in files:
        path = relative_path(entry["path"])
        if path.parts[0] not in ("include", "src", "tests") or entry["path"] in seen:
            raise ValueError("Runtime source patch path is duplicated or outside the source")
        seen.add(entry["path"])
        for key in ("beforeSha256", "afterSha256"):
            value = entry.get(key)
            if not (key == "beforeSha256" and value is None) and not re.fullmatch(r"[0-9a-f]{64}", value or ""):
                raise ValueError("Runtime source patch file digest is invalid")
        if entry["beforeSha256"] is None:
            if not isinstance(entry.get("content"), str) or "replacements" in entry:
                raise ValueError("New runtime source patch file needs exact content")
        elif not entry.get("replacements") or "content" in entry:
            raise ValueError("Existing runtime source patch file needs exact replacements")
    return manifest


def provenance(root: Path | None = None, lock: dict | None = None) -> dict:
    lock = lock or LOCK
    manifest = load_source_patch(root, lock)
    return {"version": 1, "repository": lock["repository"], "revision": lock["revision"],
            "sourcePatchId": manifest["id"], "sourcePatchSha256": lock["sourcePatch"]["sha256"],
            "museSparkABI": manifest["museSparkABI"]}


def source_path(source: Path, name: str) -> Path:
    path = source / relative_path(name)
    if path.is_symlink() or not path.resolve().is_relative_to(source.resolve()):
        raise ValueError("Runtime source patch path escapes the checkout")
    parent = path.parent
    while parent != source:
        if parent.is_symlink():
            raise ValueError("Runtime source patch parent must not be a symlink")
        parent = parent.parent
    return path


def verify_base(source: Path) -> None:
    if git(source, "rev-parse", "HEAD") != LOCK["revision"]:
        raise ValueError("Prism runtime revision does not match shared/prism-runtime.json")
    # get-url expands insteadOf transport rules (including Xcode Cloud's mirror).
    # Validate the declared origin instead; multiple URLs fail closed.
    if git(source, "config", "--local", "--get-all", "remote.origin.url").removesuffix(".git") != LOCK["repository"].removesuffix(".git"):
        raise ValueError("Prism runtime origin does not match the pinned repository")


def verify(source: Path) -> dict:
    source = source.resolve(strict=True)
    verify_base(source)
    manifest = load_source_patch()
    allowed = {entry["path"]: ("??" if entry["beforeSha256"] is None else " M") for entry in manifest["files"]}
    for line in git(source, "status", "--porcelain", "--untracked-files=all").splitlines():
        if len(line) < 4 or allowed.get(line[3:]) != line[:2]:
            raise ValueError("Prism runtime has changes outside the exact source patch")
    for entry in manifest["files"]:
        path = source_path(source, entry["path"])
        if not path.is_file() or digest(path.read_bytes()) != entry["afterSha256"]:
            raise ValueError(f"Muse runtime source patch is missing or modified: {entry['path']}")
    header = (source / "ggml/include/ggml.h").read_text()
    loader = (source / "src/llama-model.cpp").read_text()
    if not all(t in header for t in LOCK["requiredTypes"]) or '"prism.hadamard.version"' not in loader:
        raise ValueError("Prism ternary types or Hadamard activation transforms are missing")
    return provenance()


def apply_source_patch(source: Path) -> dict:
    """Apply only the authorized patch to its complete, clean, exact preimage."""
    source = source.resolve(strict=True)
    try:
        return verify(source)
    except ValueError:
        pass
    verify_base(source)
    if git(source, "status", "--porcelain", "--untracked-files=all"):
        raise ValueError("Existing source changes are preserved; the patch requires a clean pinned checkout")
    manifest = load_source_patch()
    plan = []
    for entry in manifest["files"]:
        path = source_path(source, entry["path"])
        if entry["beforeSha256"] is None:
            if path.exists() or path.is_symlink():
                raise ValueError("Existing file is preserved; new Muse source path is occupied")
            before, after = None, entry["content"].encode()
        else:
            if not path.is_file():
                raise ValueError("Runtime patch preimage is missing")
            before = path.read_bytes()
            if digest(before) != entry["beforeSha256"]:
                raise ValueError(f"Runtime patch preimage differs: {entry['path']}")
            text = before.decode("utf-8")
            for edit in entry["replacements"]:
                if not edit["before"] or text.count(edit["before"]) != 1:
                    raise ValueError("Runtime patch replacement context is not unique")
                text = text.replace(edit["before"], edit["after"], 1)
            after = text.encode("utf-8")
        if digest(after) != entry["afterSha256"]:
            raise ValueError("Runtime patch output digest differs")
        plan.append((path, before, after))
    # Validate the entire plan before writing any file, then recheck the preimages.
    for path, before, _after in plan:
        changed = (path.exists() or path.is_symlink()) if before is None else path.read_bytes() != before
        if changed:
            raise ValueError("Runtime source changed while preparing the patch")
    for path, before, after in plan:
        if before is None:
            with path.open("xb") as handle:
                handle.write(after)
        else:
            path.write_bytes(after)
    return verify(source)


def fetch(destination: Path) -> dict:
    # Never reset, update, clean or replace a pre-existing checkout or path.
    if destination.exists() or destination.is_symlink():
        raise ValueError("Destination already exists; verify it or choose a new empty path")
    destination.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(["git", "clone", "--depth", "1", "--single-branch", "--branch",
                    LOCK["branch"], LOCK["repository"], str(destination)], check=True)
    subprocess.run(["git", "-C", str(destination), "fetch", "--depth", "1", "origin", LOCK["revision"]], check=True)
    subprocess.run(["git", "-C", str(destination), "checkout", "--detach", LOCK["revision"]], check=True)
    return apply_source_patch(destination)


def stamp(source: Path, artifact: Path) -> dict:
    identity = verify(source)
    if not artifact.is_dir() or (artifact / STAMP).exists():
        raise ValueError("Expected a newly built, unstamped xcframework")
    headers = list(artifact.glob("**/Headers/ggml.h"))
    if not headers or not all(all(t in h.read_text() for t in LOCK["requiredTypes"]) for h in headers):
        raise ValueError("Every framework slice must contain the Prism ternary headers")
    llama_headers = [h.with_name("llama.h") for h in headers]
    if not all(h.is_file() and "quenderin_muse_spark_runtime_abi" in h.read_text() for h in llama_headers):
        raise ValueError("Every framework slice must contain the Muse capability header")
    (artifact / STAMP).write_text(json.dumps(identity, indent=2) + "\n")
    return identity


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    p = commands.add_parser("fetch")
    p.add_argument("--destination", type=Path, required=True)
    p = commands.add_parser("verify")
    p.add_argument("--source", type=Path, required=True)
    p = commands.add_parser("patch")
    p.add_argument("--source", type=Path, required=True)
    p = commands.add_parser("stamp")
    p.add_argument("--source", type=Path, required=True)
    p.add_argument("--artifact", type=Path, required=True)
    args = parser.parse_args()
    try:
        result = fetch(args.destination) if args.command == "fetch" else (
            stamp(args.source, args.artifact) if args.command == "stamp" else (
                apply_source_patch(args.source) if args.command == "patch" else verify(args.source)))
        print(json.dumps(result))
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"Prism runtime rejected: {error}\n")


if __name__ == "__main__":
    main()

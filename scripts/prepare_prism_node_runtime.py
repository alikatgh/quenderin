#!/usr/bin/env python3
"""Prepare a pinned Prism source build for the exact supported Node addon.

This does not invoke npm's destructive `source download` command, compile a
runtime, or replace an existing llama.cpp checkout. Original addon files are
retained before the narrowly versioned C API compatibility patch is applied.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import subprocess

import prepare_prism_runtime as runtime

PATCH_PATH = Path(__file__).resolve().parent / "patches/node-llama-cpp-3.19.1-prism-e8fd209.json"
STAMP_NAME = "quenderin-prism-node-runtime.json"
BACKUP_NAME = "quenderin-prism-node-originals"


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def load_patch() -> dict:
    compatibility = json.loads(PATCH_PATH.read_text())
    if compatibility["runtimeRevision"] != runtime.LOCK["revision"]:
        raise ValueError("Node compatibility patch does not match the pinned Prism revision")
    return compatibility


def patch_plan(package: Path, compatibility: dict) -> list[tuple[Path, bytes, bytes]]:
    """Validate every complete official preimage before preparing any edits."""
    metadata = json.loads((package / "package.json").read_text())
    if (metadata.get("name"), metadata.get("version")) != (
        compatibility["package"], compatibility["packageVersion"]
    ):
        raise ValueError("Expected the exact node-llama-cpp 3.19.1 package")
    plan = []
    for entry in compatibility["files"]:
        path = package / entry["path"]
        if path.is_symlink() or not path.is_file() or not path.resolve().is_relative_to(package.resolve()):
            raise ValueError(f"Expected an ordinary addon source file: {path}")
        before = path.read_bytes()
        if digest(before) != entry["beforeSha256"]:
            raise ValueError(f"Official addon preimage does not match: {entry['path']}")
        source = before.decode("utf-8")
        for edit in entry["replacements"]:
            if source.count(edit["before"]) != 1:
                raise ValueError(f"Addon patch context is not unique: {entry['path']}")
            source = source.replace(edit["before"], edit["after"], 1)
        after = source.encode("utf-8")
        if digest(after) != entry["afterSha256"]:
            raise ValueError(f"Addon patch result does not match: {entry['path']}")
        plan.append((path, before, after))
    return plan


def source_info() -> dict:
    return {"tag": runtime.LOCK["revision"], "llamaCppGithubRepo": "PrismML-Eng/llama.cpp"}


def paths(package: Path) -> tuple[Path, Path, Path, Path]:
    llama = package / "llama"
    return (llama / "llama.cpp", llama / "llama.cpp.info.json",
            llama / BACKUP_NAME, llama / STAMP_NAME)


def verify(package: Path) -> dict:
    compatibility = load_patch()
    metadata = json.loads((package / "package.json").read_text())
    if metadata.get("name") != compatibility["package"] or metadata.get("version") != compatibility["packageVersion"]:
        raise ValueError("Expected the exact node-llama-cpp 3.19.1 package")
    source, info, backup, stamp = paths(package)
    provenance = runtime.verify(source)
    if json.loads(info.read_text()) != source_info():
        raise ValueError("Node source metadata does not match the actual pinned runtime")
    expected = {**provenance, "nodeLlamaCppVersion": compatibility["packageVersion"],
                "compatibilityPatchSha256": digest(PATCH_PATH.read_bytes())}
    if json.loads(stamp.read_text()) != expected:
        raise ValueError("Node compatibility provenance stamp does not match")
    for entry in compatibility["files"]:
        path = package / entry["path"]
        original = backup / Path(entry["path"]).name
        if path.is_symlink() or original.is_symlink() or not path.resolve().is_relative_to(package.resolve()):
            raise ValueError("Addon source and original backup must not be symbolic links")
        if digest(path.read_bytes()) != entry["afterSha256"] or digest(original.read_bytes()) != entry["beforeSha256"]:
            raise ValueError(f"Patched addon or preserved original has changed: {entry['path']}")
    return expected


def prepare(package: Path) -> dict:
    package = package.resolve(strict=True)
    source, info, backup, stamp = paths(package)
    if stamp.exists() or stamp.is_symlink():
        # A repeated invocation only verifies; it never reapplies or overwrites.
        return verify(package)
    for path in (source, info, backup):
        if path.exists() or path.is_symlink():
            raise ValueError(f"Existing path is preserved; use a fresh package installation: {path}")
    compatibility = load_patch()
    plan = patch_plan(package, compatibility)
    # All version/hash/path checks happen before fetching or changing addon files.
    provenance = runtime.fetch(source)
    # Recheck after the network operation in case another process edited the addon.
    if patch_plan(package, compatibility) != plan:
        raise ValueError("Addon source changed while preparing the runtime")
    backup.mkdir()
    for path, before, _after in plan:
        with (backup / path.name).open("xb") as handle:
            handle.write(before)
    for path, _before, after in plan:
        path.write_bytes(after)
    with info.open("x") as handle:
        json.dump(source_info(), handle, indent=2)
        handle.write("\n")
    provenance.update(nodeLlamaCppVersion=compatibility["packageVersion"],
                      compatibilityPatchSha256=digest(PATCH_PATH.read_bytes()))
    with stamp.open("x") as handle:
        json.dump(provenance, handle, indent=2)
        handle.write("\n")
    return verify(package)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("prepare", "verify"))
    parser.add_argument("--package-dir", type=Path, required=True,
                        help="Fresh node_modules/node-llama-cpp installation (version 3.19.1)")
    args = parser.parse_args()
    try:
        result = prepare(args.package_dir) if args.command == "prepare" else verify(args.package_dir)
        print(json.dumps(result))
        if args.command == "prepare":
            print("Prepared only; run the existing installed CLI to compile:")
            print(f'node "{args.package_dir.resolve() / "dist/cli/cli.js"}" source build --gpu false --noUsageExample')
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"Prism Node runtime rejected: {error}\n")


if __name__ == "__main__":
    main()

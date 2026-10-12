#!/usr/bin/env python3
"""Fetch/verify the exact Bonsai runtime without replacing an existing checkout."""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
LOCK = json.loads((ROOT / "shared/prism-runtime.json").read_text())
STAMP = "quenderin-prism-runtime.json"


def git(source: Path, *args: str) -> str:
    return subprocess.check_output(["git", "-C", str(source), *args], text=True).strip()


def verify(source: Path) -> dict:
    if git(source, "rev-parse", "HEAD") != LOCK["revision"]:
        raise ValueError("Prism runtime revision does not match shared/prism-runtime.json")
    if git(source, "status", "--porcelain", "--untracked-files=no"):
        raise ValueError("Prism runtime has modified tracked source files")
    # get-url expands insteadOf transport rules (including Xcode Cloud's mirror).
    # Validate the checkout's declared origin instead; multiple URLs fail closed.
    if git(source, "config", "--local", "--get-all", "remote.origin.url").removesuffix(".git") != LOCK["repository"].removesuffix(".git"):
        raise ValueError("Prism runtime origin does not match the pinned repository")
    header = (source / "ggml/include/ggml.h").read_text()
    loader = (source / "src/llama-model.cpp").read_text()
    if not all(t in header for t in LOCK["requiredTypes"]) or '"prism.hadamard.version"' not in loader:
        raise ValueError("Prism ternary types or Hadamard activation transforms are missing")
    return {"version": 1, "repository": LOCK["repository"], "revision": LOCK["revision"]}


def fetch(destination: Path) -> dict:
    # Never reset, update, clean or replace a pre-existing checkout or path.
    if destination.exists() or destination.is_symlink():
        raise ValueError("Destination already exists; verify it or choose a new empty path")
    destination.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(["git", "clone", "--depth", "1", "--single-branch", "--branch",
                    LOCK["branch"], LOCK["repository"], str(destination)], check=True)
    subprocess.run(["git", "-C", str(destination), "fetch", "--depth", "1", "origin", LOCK["revision"]], check=True)
    subprocess.run(["git", "-C", str(destination), "checkout", "--detach", LOCK["revision"]], check=True)
    return verify(destination)


def stamp(source: Path, artifact: Path) -> dict:
    provenance = verify(source)
    if not artifact.is_dir() or (artifact / STAMP).exists():
        raise ValueError("Expected a newly built, unstamped xcframework")
    headers = list(artifact.glob("**/Headers/ggml.h"))
    if not headers or not all(all(t in h.read_text() for t in LOCK["requiredTypes"]) for h in headers):
        raise ValueError("Every framework slice must contain the Prism ternary headers")
    (artifact / STAMP).write_text(json.dumps(provenance, indent=2) + "\n")
    return provenance


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    p = commands.add_parser("fetch")
    p.add_argument("--destination", type=Path, required=True)
    p = commands.add_parser("verify")
    p.add_argument("--source", type=Path, required=True)
    p = commands.add_parser("stamp")
    p.add_argument("--source", type=Path, required=True)
    p.add_argument("--artifact", type=Path, required=True)
    args = parser.parse_args()
    try:
        result = fetch(args.destination) if args.command == "fetch" else (
            stamp(args.source, args.artifact) if args.command == "stamp" else verify(args.source))
        print(json.dumps(result))
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"Prism runtime rejected: {error}\n")


if __name__ == "__main__":
    main()

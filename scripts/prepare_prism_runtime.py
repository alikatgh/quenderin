#!/usr/bin/env python3
"""Fetch/verify the exact Bonsai runtime without replacing an existing checkout."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent
LOCK = json.loads((ROOT / "shared/prism-runtime.json").read_text())
STAMP = "quenderin-prism-runtime.json"
IDENTITY_FIELDS = ("repository", "revision", "sourcePatchId", "sourcePatchSha256", "museSparkABI",
                   "weeklyTextPatchId", "weeklyTextPatchSha256", "weeklyTextABI",
                   "beamPatchId", "beamPatchSha256", "beamABI")


def git(source: Path, *args: str) -> str:
    return subprocess.check_output(["git", "-C", str(source), *args], text=True).rstrip("\n")


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def relative_path(value: str) -> Path:
    path = PurePosixPath(value)
    if not value or path.is_absolute() or any(p in ("", ".", "..", ".git") for p in value.split("/")):
        raise ValueError("Unsafe runtime patch path")
    return Path(*path.parts)


def read_patch_manifest(root: Path, identity: dict) -> dict:
    path = root / relative_path(identity["path"])
    if path.is_symlink() or not path.resolve().is_relative_to(root.resolve()):
        raise ValueError("Runtime patch manifest escapes the project")
    data = path.read_bytes()
    if digest(data) != identity["sha256"]:
        raise ValueError("Runtime source patch digest does not match the lock")
    return json.loads(data)


def validate_patch_files(manifest: dict, allowed_roots: tuple[str, ...]) -> None:
    files = manifest.get("files", [])
    if not files or len(files) > 64:
        raise ValueError("Runtime source patch file set is invalid")
    seen = set()
    for entry in files:
        path = relative_path(entry["path"])
        if path.parts[0] not in allowed_roots or entry["path"] in seen:
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


def load_source_patch(root: Path | None = None, lock: dict | None = None) -> dict:
    root, lock = root or ROOT, lock or LOCK
    identity = lock["sourcePatch"]
    manifest = read_patch_manifest(root, identity)
    if (manifest.get("version") != 1 or manifest.get("id") != identity["id"]
            or manifest.get("baseRepository") != lock["repository"]
            or manifest.get("baseRevision") != lock["revision"]
            or manifest.get("upstreamRevision") != identity["upstreamRevision"]
            or manifest.get("museSparkABI") != identity["museSparkABI"]
            or type(manifest.get("museSparkABI")) is not int or manifest["museSparkABI"] != 1
            or manifest.get("capabilitySymbol") != "quenderin_muse_spark_runtime_abi"):
        raise ValueError("Runtime source patch identity is invalid")
    validate_patch_files(manifest, ("include", "src", "tests"))
    return manifest


def load_weekly_text_patch(root: Path | None = None, lock: dict | None = None) -> dict | None:
    root, lock = root or ROOT, lock or LOCK
    identity = lock.get("weeklyTextPatch")
    if identity is None:
        return None
    manifest = read_patch_manifest(root, identity)
    if (manifest.get("version") != 1 or manifest.get("id") != identity["id"]
            or manifest.get("baseRepository") != lock["repository"]
            or manifest.get("baseRevision") != lock["revision"]
            or manifest.get("parentSourcePatch") != {"id": lock["sourcePatch"]["id"],
                                                    "sha256": lock["sourcePatch"]["sha256"]}
            or manifest.get("upstreamRevisions") != identity["upstreamRevisions"]
            or manifest.get("weeklyTextABI") != identity["weeklyTextABI"]
            or type(manifest.get("weeklyTextABI")) is not int or manifest["weeklyTextABI"] != 1
            or manifest.get("capabilitySymbol") != "quenderin_weekly_text_runtime_abi"):
        raise ValueError("Weekly text runtime source patch identity is invalid")
    revisions = manifest["upstreamRevisions"]
    if (not isinstance(revisions, dict) or set(revisions) != {"k2Horizon", "nemotron35"}
            or not all(re.fullmatch(r"[0-9a-f]{40}", value or "") for value in revisions.values())):
        raise ValueError("Weekly text upstream revisions are invalid")
    validate_patch_files(manifest, ("include", "src", "tests", "ggml"))
    return manifest


def load_beam_patch(root: Path | None = None, lock: dict | None = None) -> dict | None:
    root, lock = root or ROOT, lock or LOCK
    identity = lock.get("beamPatch")
    if identity is None:
        return None
    manifest = read_patch_manifest(root, identity)
    weekly = lock.get("weeklyTextPatch", {})
    if (manifest.get("version") != 1 or manifest.get("id") != identity["id"]
            or manifest.get("baseRepository") != lock["repository"]
            or manifest.get("baseRevision") != lock["revision"]
            or manifest.get("parentSourcePatch") != {"id": lock["sourcePatch"]["id"],
                                                    "sha256": lock["sourcePatch"]["sha256"]}
            or not weekly
            or manifest.get("parentWeeklyTextPatch") != {"id": weekly.get("id"), "sha256": weekly.get("sha256")}
            or manifest.get("upstreamRevision") != identity["upstreamRevision"]
            or not re.fullmatch(r"[0-9a-f]{40}", manifest.get("upstreamRevision") or "")
            or manifest.get("beamABI") != identity["beamABI"]
            or type(manifest.get("beamABI")) is not int or manifest["beamABI"] != 1
            or manifest.get("capabilitySymbol") != "quenderin_beam_runtime_abi"):
        raise ValueError("Beam runtime source patch identity is invalid")
    validate_patch_files(manifest, ("include", "src", "tests"))
    return manifest


def source_patches(root: Path | None = None, lock: dict | None = None) -> list[dict]:
    manifests = [load_source_patch(root, lock)]
    weekly = load_weekly_text_patch(root, lock)
    if weekly is not None:
        manifests.append(weekly)
    beam = load_beam_patch(root, lock)
    if beam is not None:
        manifests.append(beam)
    return manifests


def final_patch_files(manifests: list[dict]) -> list[dict]:
    """Keep the original git status and final digest for each stacked path."""
    entries = {}
    for manifest in manifests:
        for entry in manifest["files"]:
            original = entries.get(entry["path"])
            if original and entry["beforeSha256"] != original["afterSha256"]:
                raise ValueError("Stacked runtime patch preimages do not match")
            entries[entry["path"]] = {**entry, "beforeSha256": (
                original["beforeSha256"] if original else entry["beforeSha256"])}
    return list(entries.values())


def provenance(root: Path | None = None, lock: dict | None = None) -> dict:
    lock = lock or LOCK
    manifest = load_source_patch(root, lock)
    identity = {"version": 1, "repository": lock["repository"], "revision": lock["revision"],
            "sourcePatchId": manifest["id"], "sourcePatchSha256": lock["sourcePatch"]["sha256"],
            "museSparkABI": manifest["museSparkABI"]}
    weekly = load_weekly_text_patch(root, lock)
    if weekly is not None:
        identity.update(weeklyTextPatchId=weekly["id"],
                        weeklyTextPatchSha256=lock["weeklyTextPatch"]["sha256"],
                        weeklyTextABI=weekly["weeklyTextABI"])
    beam = load_beam_patch(root, lock)
    if beam is not None:
        identity.update(beamPatchId=beam["id"], beamPatchSha256=lock["beamPatch"]["sha256"],
                        beamABI=beam["beamABI"])
    return identity


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
    entries = final_patch_files(source_patches())
    allowed = {entry["path"]: ("??" if entry["beforeSha256"] is None else " M") for entry in entries}
    for line in git(source, "status", "--porcelain", "--untracked-files=all").splitlines():
        if len(line) < 4 or allowed.get(line[3:]) != line[:2]:
            raise ValueError("Prism runtime has changes outside the exact source patch")
    for entry in entries:
        path = source_path(source, entry["path"])
        if not path.is_file() or digest(path.read_bytes()) != entry["afterSha256"]:
            raise ValueError(f"Runtime source patch is missing or modified: {entry['path']}")
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
    manifests = source_patches()
    final_patch_files(manifests)  # Validate stack order before reading or writing source.
    plan = {}
    for entry in [entry for manifest in manifests for entry in manifest["files"]]:
        path = source_path(source, entry["path"])
        previous = plan.get(entry["path"])
        if entry["beforeSha256"] is None:
            if path.exists() or path.is_symlink():
                raise ValueError("Existing file is preserved; new Muse source path is occupied")
            before, after = None, entry["content"].encode()
        else:
            if not path.is_file() and previous is None:
                raise ValueError("Runtime patch preimage is missing")
            before = previous[2] if previous is not None else path.read_bytes()
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
        plan[entry["path"]] = (path, previous[1] if previous is not None else before, after)
    # Validate the entire plan before writing any file, then recheck the preimages.
    for path, before, _after in plan.values():
        changed = (path.exists() or path.is_symlink()) if before is None else path.read_bytes() != before
        if changed:
            raise ValueError("Runtime source changed while preparing the patch")
    # Stage every byte before touching source. Hard-linked preimages permit rollback
    # without another disk allocation, including ENOSPC during commit. Atomic replace
    # keeps existing paths continuously readable; new paths are created exclusively.
    staging = Path(tempfile.mkdtemp(prefix=".quenderin-runtime-patch-", dir=source.parent))
    committed = []
    preserve_staging = False
    try:
        staged = []
        for index, (path, before, after) in enumerate(plan.values()):
            backup, output = staging / f"{index}.before", staging / f"{index}.after"
            if before is not None:
                os.link(path, backup, follow_symlinks=False)
            with output.open("xb") as handle:
                handle.write(after)
                handle.flush()
                os.fsync(handle.fileno())
            if output.read_bytes() != after:
                raise OSError("Runtime patch staging write was incomplete")
            output.chmod(path.stat().st_mode & 0o777 if before is not None else 0o644)
            staged.append((path, before, after, backup, output))
        for path, before, after, backup, output in staged:
            changed = (path.exists() or path.is_symlink()) if before is None else (
                path.is_symlink() or path.read_bytes() != before)
            if changed:
                raise ValueError("Runtime source changed while staging the patch")
        for path, before, after, backup, output in staged:
            if before is None:
                os.link(output, path)  # Fails if a concurrent writer claimed the new path.
            else:
                os.replace(output, path)
            committed.append((path, before, after, backup))
        return verify(source)
    except BaseException:
        conflicts = []
        for path, before, after, backup in reversed(committed):
            try:
                if path.is_symlink() or not path.is_file() or path.read_bytes() != after:
                    conflicts.append(str(path))
                    continue  # Never overwrite a concurrent editor's changes during recovery.
                if before is None:
                    path.unlink()  # Only the exclusively-created file from this transaction.
                else:
                    os.replace(backup, path)
            except OSError:
                conflicts.append(str(path))
        if conflicts:
            preserve_staging = True
            raise ValueError(f"Source changed during recovery; preserved original links in {staging}: {conflicts}")
        raise
    finally:
        if not preserve_staging:
            shutil.rmtree(staging)  # This invocation created and exclusively owns the staging directory.


def fetch(destination: Path) -> dict:
    # Never reset, update, clean or replace a pre-existing checkout or path.
    if destination.exists() or destination.is_symlink():
        raise ValueError("Destination already exists; verify it or choose a new empty path")
    destination.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(["git", "clone", "--config", "core.autocrlf=false", "--depth", "1", "--single-branch", "--branch",
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
    if "weeklyTextABI" in identity and not all(
            "quenderin_weekly_text_runtime_abi" in h.read_text() for h in llama_headers):
        raise ValueError("Every framework slice must contain the weekly text capability header")
    if "beamABI" in identity and not all(
            "quenderin_beam_runtime_abi" in h.read_text() for h in llama_headers):
        raise ValueError("Every framework slice must contain the Beam capability header")
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

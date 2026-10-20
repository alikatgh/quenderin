#!/usr/bin/env python3
"""Export one unsigned, exact-source Android candidate to its existing draft only."""
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
import zipfile

REPOSITORY = "alikatgh/quenderin"
SOURCE_SHA = "eecf089ff328f7303a7d4a64358252e8913e32f5"
RELEASE_ID = 418062490
TAG = "android-beta-0.5.0-candidate-eecf089"
PACKAGE = "ai.quenderin.app"
VERSION = "0.5.0"
VERSION_CODE = 5
NAME = "quenderin-android-0.5.0-5-eecf089-unsigned.aab"
NAMES = (NAME, NAME + ".sha256", NAME + ".receipt.json")
MAX_BYTES = 512 * 1024 * 1024
API = f"repos/{REPOSITORY}"
RELEASE_API = f"{API}/releases/{RELEASE_ID}"


def execute(args: list[str], timeout: int = 120) -> str:
    # Tokens are passed only in the child's environment, never in argv or diagnostics.
    env = os.environ.copy()
    token = env.pop("GITHUB_TOKEN", None)
    if token and args[0] == "gh":
        env["GH_TOKEN"] = token
        # gh versions can classify an absolute uploads.github.com endpoint as a
        # separate host. Its token stays in the child environment in either case.
        if any(arg.startswith("https://uploads.github.com/") for arg in args):
            env["GH_ENTERPRISE_TOKEN"] = token
    env.update(GH_PROMPT_DISABLED="1", GH_HOST="github.com", GIT_TERMINAL_PROMPT="0")
    result = subprocess.run(args, env=env, capture_output=True, text=True, timeout=timeout)
    if result.returncode:
        raise ValueError(f"{Path(args[0]).name} failed (exit {result.returncode}); export stopped")
    return result.stdout


def digest(path: Path) -> str:
    with path.open("rb") as stream:
        return "sha256:" + hashlib.file_digest(stream, "sha256").hexdigest()


class Draft:
    def __init__(self, repository: str, run=execute):
        if repository != REPOSITORY:
            raise ValueError("Candidate repository differs")
        self.run = run

    def verify(self) -> dict:
        repository = json.loads(self.run(["gh", "api", API]))
        if repository.get("full_name") != REPOSITORY or repository.get("private") is not False:
            raise ValueError("The exact public repository is required")
        value = json.loads(self.run(["gh", "api", RELEASE_API]))
        if (value.get("id") != RELEASE_ID or value.get("draft") is not True
                or value.get("prerelease") is not True or value.get("published_at") is not None
                or value.get("tag_name") != TAG or value.get("target_commitish") != SOURCE_SHA
                or value.get("url") != f"https://api.github.com/{RELEASE_API}"
                or not isinstance(value.get("assets"), list)):
            raise ValueError("The exact unpublished candidate draft is required")
        # A draft may not have created its tag. If present, it must resolve to our source.
        refs = self.run(["git", "ls-remote", f"https://github.com/{REPOSITORY}.git",
                         f"refs/tags/{TAG}", f"refs/tags/{TAG}^{{}}"], timeout=60)
        found = dict(line.split()[::-1] for line in refs.splitlines() if line.strip())
        target = found.get(f"refs/tags/{TAG}^{{}}", found.get(f"refs/tags/{TAG}"))
        if found and target != SOURCE_SHA:
            raise ValueError("Existing candidate tag differs from the pinned source")
        if any(asset.get("name") not in NAMES for asset in value["assets"]):
            raise ValueError("Unexpected asset in the dedicated candidate draft")
        return value

    def upload(self, files: list[Path]) -> None:
        local = {path.name: {"name": path.name, "size": path.stat().st_size,
                             "digest": digest(path), "state": "uploaded"} for path in files}
        if tuple(local) != NAMES:
            raise ValueError("Only the three named candidate assets may be exported")

        def missing(value, required=()):
            result = []
            for name, expected in local.items():
                matches = [asset for asset in value["assets"] if asset.get("name") == name]
                if not matches and name not in required:
                    result.append(name)
                elif len(matches) != 1 or any(matches[0].get(key) != item for key, item in expected.items()):
                    raise ValueError("Existing candidate asset differs: " + name)
            return result

        missing(self.verify())  # Check every collision before the first mutation.
        for path in files:
            if path.name not in missing(self.verify()):
                continue
            # Fixed ID endpoint; never create/publish a release, modify a tag, or overwrite.
            self.run(["gh", "api", "--hostname", "github.com", "--method", "POST",
                      f"https://uploads.github.com/{RELEASE_API}/assets?name={path.name}",
                      "--header", "Content-Type: application/octet-stream", "--input", str(path)],
                     timeout=600)
            missing(self.verify(), required=(path.name,))
        missing(self.verify(), required=NAMES)


def source_identity(source: Path, run=execute) -> None:
    if run(["git", "-C", str(source), "rev-parse", "HEAD"]).strip() != SOURCE_SHA:
        raise ValueError("App source is not the fixed candidate commit")
    run(["git", "-C", str(source), "diff", "--quiet", "HEAD", "--"])
    if (source / "android/keystore.properties").exists():
        raise ValueError("Unsigned candidate source must not contain signing configuration")
    gradle = (source / "android/app/build.gradle.kts").read_text()
    for key, expected in (("applicationId", PACKAGE), ("versionName", VERSION), ("versionCode", VERSION_CODE)):
        values = re.findall(r"^\s*" + key + r"\s*=\s*(?:\"([^\"]+)\"|(\d+))\s*$", gradle, re.M)
        if len(values) != 1 or next(part for part in values[0] if part) != str(expected):
            raise ValueError("Pinned Android build metadata differs: " + key)


def verify_bundle(bundle: Path) -> None:
    if bundle.is_symlink() or not bundle.is_file() or not 0 < bundle.stat().st_size <= MAX_BYTES:
        raise ValueError("AAB must be a nonempty regular file at most 512 MiB")
    with zipfile.ZipFile(bundle) as archive:
        entries = archive.infolist()
        names = [entry.filename for entry in entries]
        required = {"BundleConfig.pb", "base/manifest/AndroidManifest.xml", "base/dex/classes.dex",
                    "base/lib/arm64-v8a/libquenderin_llama.so"}
        if (not required.issubset(names) or len(names) != len(set(names)) or len(names) > 100_000
                or sum(entry.file_size for entry in entries) > 2 * 1024 ** 3):
            raise ValueError("Invalid or oversized AAB ZIP structure")
        for name in names:
            if (PurePosixPath(name).is_absolute() or ".." in name.split("/") or "\\" in name
                    or re.match(r"^META-INF/(?:[^/]+\.(?:SF|RSA|DSA|EC)|SIG-[^/]+)$", name, re.I)):
                raise ValueError("Unsafe entry or JAR signature in unsigned AAB")
        if archive.testzip() is not None:
            raise ValueError("AAB ZIP checksum failed")


def export(source: Path, libraries: Path, prism: Path, output: Path, draft: Draft, run=execute) -> list[Path]:
    source = source.resolve()
    source_identity(source, run)
    bundle = source / "android/app/build/outputs/bundle/release/app-release.aab"
    verify_bundle(bundle)
    # Re-run the existing native checks on the exact final AAB before staging/upload.
    image = json.loads(run([sys.executable, str(source / "scripts/verify_diffusion_android_package.py"),
                           "--libraries", str(libraries), "--package", str(bundle)], timeout=300))
    prism_identity = json.loads(run([sys.executable, str(source / "scripts/prepare_prism_runtime.py"),
                                    "verify", "--source", str(prism)], timeout=300))
    draft.verify()
    # A new directory prevents replacement of any existing local review artifact.
    output.mkdir(parents=True, exist_ok=False)
    candidate = output / NAME
    shutil.copyfile(bundle, candidate)
    checksum = digest(candidate)
    (output / NAMES[1]).write_text(checksum.removeprefix("sha256:") + "  " + NAME + "\n")
    receipt = {"schemaVersion": 1, "repository": REPOSITORY, "sourceCommit": SOURCE_SHA,
               "applicationId": PACKAGE, "versionName": VERSION, "versionCode": VERSION_CODE,
               "signed": False, "playUploadReady": False, "asset": NAME,
               "size": candidate.stat().st_size, "digest": checksum,
               "runtimeProvenance": {"prism": prism_identity,
                   "image": {key: image[key] for key in ("revision", "verified", "alignment")}},
               "releaseId": RELEASE_ID, "releaseTag": TAG, "draft": True}
    (output / NAMES[2]).write_text(json.dumps(receipt, indent=2, sort_keys=True) + "\n")
    files = [output / name for name in NAMES]
    draft.upload(files)
    return files


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("preflight", "export"))
    parser.add_argument("--source", type=Path)
    parser.add_argument("--libraries", type=Path)
    parser.add_argument("--prism", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    try:
        draft = Draft(os.environ.get("GITHUB_REPOSITORY", ""))
        if args.command == "preflight":
            draft.verify()
        else:
            if any(getattr(args, key) is None for key in ("source", "libraries", "prism", "output")):
                raise ValueError("Explicit source, libraries, prism, and new output paths are required")
            export(args.source, args.libraries, args.prism, args.output, draft)
        print("Unsigned candidate draft verification passed; no Play upload or publication performed.")
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError, zipfile.BadZipFile):
        parser.exit(1, "Android candidate export rejected; no automatic retry or overwrite.\n")


if __name__ == "__main__":
    main()

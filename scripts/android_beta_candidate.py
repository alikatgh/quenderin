#!/usr/bin/env python3
"""Export one unsigned, exact-source Android candidate to its existing draft only."""
from __future__ import annotations

import argparse
from dataclasses import dataclass
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import sys
import xml.etree.ElementTree as ET
import zipfile

REPOSITORY = "alikatgh/quenderin"
PACKAGE = "ai.quenderin.app"
MAX_BYTES = 512 * 1024 * 1024
API = f"repos/{REPOSITORY}"
# Google's unchanged Apache-2.0 release JAR; keep its embedded license/notices.
# Digest and size: https://api.github.com/repos/google/bundletool/releases/270526371
BUNDLETOOL_VERSION = "1.18.3"
BUNDLETOOL_SIZE = 32_520_401
BUNDLETOOL_SHA256 = "a099cfa1543f55593bc2ed16a70a7c67fe54b1747bb7301f37fdfd6d91028e29"
BUNDLETOOL_URL = ("https://github.com/google/bundletool/releases/download/1.18.3/"
                  "bundletool-all-1.18.3.jar")


@dataclass(frozen=True)
class Candidate:
    source_sha: str
    release_id: int
    version: str
    version_code: int

    @classmethod
    def from_environment(cls, environment: dict[str, str]) -> Candidate:
        # Validate before interpolating anything into a git/API argument or output.
        if environment.get("GITHUB_REPOSITORY") != REPOSITORY:
            raise ValueError("Candidate repository differs")
        source = environment.get("CANDIDATE_SOURCE_COMMIT", "")
        release = environment.get("CANDIDATE_RELEASE_ID", "")
        version = environment.get("CANDIDATE_VERSION_NAME", "")
        code = environment.get("CANDIDATE_VERSION_CODE", "")
        if not re.fullmatch(r"[0-9a-f]{40}", source):
            raise ValueError("An exact lowercase full source commit is required")
        if not re.fullmatch(r"[1-9][0-9]{0,18}", release) or int(release) > 2 ** 63 - 1:
            raise ValueError("An existing positive draft release ID is required")
        if not re.fullmatch(r"(?:0|[1-9][0-9]{0,5})(?:\.(?:0|[1-9][0-9]{0,5})){2}", version):
            raise ValueError("An explicit numeric major.minor.patch version is required")
        if not re.fullmatch(r"[1-9][0-9]{0,9}", code) or int(code) > 2_100_000_000:
            raise ValueError("A valid positive Android version code is required")
        return cls(source, int(release), version, int(code))

    @property
    def tag(self) -> str:
        return f"android-beta-{self.version}-candidate-{self.source_sha[:7]}"

    @property
    def name(self) -> str:
        return f"quenderin-android-{self.version}-{self.version_code}-{self.source_sha[:7]}-unsigned.aab"

    @property
    def names(self) -> tuple[str, str, str]:
        return self.name, self.name + ".sha256", self.name + ".receipt.json"

    @property
    def release_api(self) -> str:
        return f"{API}/releases/{self.release_id}"


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


def verify_bundletool(path: Path) -> None:
    if (path.is_symlink() or not path.is_file() or path.stat().st_size != BUNDLETOOL_SIZE
            or digest(path) != "sha256:" + BUNDLETOOL_SHA256):
        raise ValueError("The pinned official bundletool JAR is required")


def fetch_bundletool(output: Path, run=execute) -> None:
    if output.exists() or output.is_symlink():
        raise ValueError("Bundletool download requires a new disposable path")
    run(["curl", "--fail", "--location", "--retry", "0", "--connect-timeout", "15",
         "--max-time", "120", "--max-filesize", str(BUNDLETOOL_SIZE),
         "--proto", "=https", "--proto-redir", "=https", "--output", str(output),
         BUNDLETOOL_URL], timeout=150)
    verify_bundletool(output)


class Draft:
    def __init__(self, candidate: Candidate, run=execute):
        self.candidate = candidate
        self.run = run

    def verify(self) -> dict:
        repository = json.loads(self.run(["gh", "api", API]))
        if repository.get("full_name") != REPOSITORY or repository.get("private") is not False:
            raise ValueError("The exact public repository is required")
        candidate = self.candidate
        value = json.loads(self.run(["gh", "api", candidate.release_api]))
        if (value.get("id") != candidate.release_id or value.get("draft") is not True
                or value.get("prerelease") is not True or value.get("published_at") is not None
                or value.get("tag_name") != candidate.tag or value.get("target_commitish") != candidate.source_sha
                or value.get("url") != f"https://api.github.com/{candidate.release_api}"
                or not isinstance(value.get("assets"), list)):
            raise ValueError("The exact unpublished candidate draft is required")
        # A draft may not have created its tag. If present, it must resolve to our source.
        refs = self.run(["git", "ls-remote", f"https://github.com/{REPOSITORY}.git",
                         f"refs/tags/{candidate.tag}", f"refs/tags/{candidate.tag}^{{}}"], timeout=60)
        found = dict(line.split()[::-1] for line in refs.splitlines() if line.strip())
        target = found.get(f"refs/tags/{candidate.tag}^{{}}", found.get(f"refs/tags/{candidate.tag}"))
        if found and target != candidate.source_sha:
            raise ValueError("Existing candidate tag differs from the pinned source")
        names = [asset.get("name") if isinstance(asset, dict) else None for asset in value["assets"]]
        if len(names) != len(set(names)) or any(name not in candidate.names for name in names):
            raise ValueError("Unexpected asset in the dedicated candidate draft")
        return value

    def upload(self, files: list[Path]) -> None:
        local = {path.name: {"name": path.name, "size": path.stat().st_size,
                             "digest": digest(path), "state": "uploaded"} for path in files}
        if tuple(local) != self.candidate.names:
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
            # Validated existing ID only; never create/publish a release, modify a tag, or overwrite.
            self.run(["gh", "api", "--hostname", "github.com", "--method", "POST",
                      f"https://uploads.github.com/{self.candidate.release_api}/assets?name={path.name}",
                      "--header", "Content-Type: application/octet-stream", "--input", str(path)],
                     timeout=600)
            missing(self.verify(), required=(path.name,))
        missing(self.verify(), required=self.candidate.names)


def verify_metadata(gradle: str, candidate: Candidate) -> None:
    for key, expected in (("applicationId", PACKAGE), ("versionName", candidate.version),
                          ("versionCode", candidate.version_code)):
        values = re.findall(r"^\s*" + key + r"\s*=\s*(?:\"([^\"]+)\"|(\d+))\s*$", gradle, re.M)
        if len(values) != 1 or next(part for part in values[0] if part) != str(expected):
            raise ValueError("Candidate Android build metadata differs: " + key)


def reviewed_source(tools: Path, candidate: Candidate, run=execute) -> None:
    git = ["git", "-C", str(tools)]
    origin = run([*git, "remote", "get-url", "origin"]).strip()
    if origin not in (f"https://github.com/{REPOSITORY}", f"https://github.com/{REPOSITORY}.git"):
        raise ValueError("The reviewed owner repository is required")
    if run([*git, "cat-file", "-t", candidate.source_sha]).strip() != "commit":
        raise ValueError("Candidate source must be a commit object")
    # checkout fetch-depth: 0 supplies origin/main without executing candidate code.
    run([*git, "merge-base", "--is-ancestor", candidate.source_sha, "refs/remotes/origin/main"])
    gradle = run([*git, "show", f"{candidate.source_sha}:android/app/build.gradle.kts"])
    verify_metadata(gradle, candidate)
    if run([*git, "ls-tree", "--name-only", candidate.source_sha, "--", "android/keystore.properties"]).strip():
        raise ValueError("Unsigned candidate must not contain signing configuration")


def preflight(tools: Path, candidate: Candidate, draft: Draft, run=execute) -> None:
    reviewed_source(tools, candidate, run)
    draft.verify()


def source_identity(source: Path, candidate: Candidate, run=execute) -> None:
    if run(["git", "-C", str(source), "rev-parse", "HEAD"]).strip() != candidate.source_sha:
        raise ValueError("App source is not the requested candidate commit")
    run(["git", "-C", str(source), "diff", "--quiet", "HEAD", "--"])
    if (source / "android/keystore.properties").exists():
        raise ValueError("Unsigned candidate source must not contain signing configuration")
    verify_metadata((source / "android/app/build.gradle.kts").read_text(), candidate)


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


def bundle_metadata(bundle: Path, bundletool: Path, candidate: Candidate, run=execute) -> dict:
    verify_bundletool(bundletool)
    manifest = run(["java", "-Xmx256m", "-jar", str(bundletool), "dump", "manifest",
                    "--bundle=" + str(bundle), "--module=base"], timeout=120)
    if len(manifest.encode("utf-8")) > 1024 * 1024 or "<!DOCTYPE" in manifest or "<!ENTITY" in manifest:
        raise ValueError("Unexpected or oversized packaged manifest")
    root = ET.fromstring(manifest)
    android = "{http://schemas.android.com/apk/res/android}"
    metadata = {"applicationId": root.get("package"), "versionName": root.get(android + "versionName"),
                "versionCode": root.get(android + "versionCode")}
    if (root.tag != "manifest" or root.get(android + "versionCodeMajor", "0") != "0"
            or metadata != {"applicationId": PACKAGE, "versionName": candidate.version,
                            "versionCode": str(candidate.version_code)}):
        raise ValueError("Packaged Android identity differs from the reviewed source/version")
    return {**metadata, "versionCode": candidate.version_code}


def remote_runtime_provenance(source: Path, sdk: Path, bundle: Path, run=execute) -> dict:
    """Recheck both final packages against the exact-source, sealed Noise/JNA SDK."""
    verifier = source / "native/remote-crypto/tools/native_sdk.py"
    run([sys.executable, str(verifier), "verify", "--platform", "android", "--sdk", str(sdk)], timeout=300)
    receipt_path = sdk / "quenderin-remote-sdk.json"
    if receipt_path.stat().st_size > 1024 * 1024:
        raise ValueError("Unexpected or oversized native SDK receipt")
    receipt_digest = digest(receipt_path)
    receipt = json.loads(receipt_path.read_text())
    packages = {}
    apk = source / "android/app/build/outputs/apk/debug/app-debug.apk"
    for label, package in (("aab", bundle), ("debugApk", apk)):
        if package.is_symlink() or not package.is_file() or not 0 < package.stat().st_size <= MAX_BYTES:
            raise ValueError("Both final native packages must be regular files at most 512 MiB")
        checksum = digest(package)
        run([sys.executable, str(verifier), "verify-package", "--sdk", str(sdk),
             "--package", str(package)], timeout=300)
        if digest(package) != checksum:
            raise ValueError("Final Android package changed during verification")
        packages[label] = {"digest": checksum, "size": package.stat().st_size,
                           "verified": ["libquenderin_remote_crypto.so", "libjnidispatch.so"],
                           "elfAlignment": 16384}
    if digest(receipt_path) != receipt_digest:
        raise ValueError("Native SDK receipt changed during verification")
    return {"sdkReceipt": receipt, "sdkReceiptDigest": receipt_digest, "packages": packages}


def export(source: Path, libraries: Path, prism: Path, remote_sdk: Path, output: Path, draft: Draft, bundletool: Path,
           run=execute, tools: Path | None = None) -> list[Path]:
    source = source.resolve()
    candidate = draft.candidate
    preflight(tools or Path(__file__).resolve().parents[1], candidate, draft, run)
    source_identity(source, candidate, run)
    bundle = source / "android/app/build/outputs/bundle/release/app-release.aab"
    verify_bundle(bundle)
    packaged = bundle_metadata(bundle, bundletool, candidate, run)
    # Re-run the existing native checks on the exact final AAB before staging/upload.
    image = json.loads(run([sys.executable, str(source / "scripts/verify_diffusion_android_package.py"),
                           "--libraries", str(libraries), "--package", str(bundle)], timeout=300))
    prism_identity = json.loads(run([sys.executable, str(source / "scripts/prepare_prism_runtime.py"),
                                    "verify", "--source", str(prism)], timeout=300))
    remote = remote_runtime_provenance(source, remote_sdk, bundle, run)
    draft.verify()
    # A new directory prevents replacement of any existing local review artifact.
    output.mkdir(parents=True, exist_ok=False)
    asset = output / candidate.name
    shutil.copyfile(bundle, asset)
    checksum = digest(asset)
    if checksum != remote["packages"]["aab"]["digest"]:
        raise ValueError("Staged Android bundle differs from the verified package")
    (output / candidate.names[1]).write_text(checksum.removeprefix("sha256:") + "  " + candidate.name + "\n")
    receipt = {"schemaVersion": 1, "repository": REPOSITORY, "sourceCommit": candidate.source_sha,
               "applicationId": PACKAGE, "versionName": candidate.version, "versionCode": candidate.version_code,
               "signed": False, "playUploadReady": False, "asset": candidate.name,
               "size": asset.stat().st_size, "digest": checksum,
               "bundleManifest": packaged,
               "verificationTools": {"bundletool": {"version": BUNDLETOOL_VERSION,
                   "digest": "sha256:" + BUNDLETOOL_SHA256}},
               "runtimeProvenance": {"prism": prism_identity,
                   "image": {key: image[key] for key in ("revision", "verified", "alignment")},
                   "remoteCrypto": remote},
               "releaseId": candidate.release_id, "releaseTag": candidate.tag, "draft": True}
    (output / candidate.names[2]).write_text(json.dumps(receipt, indent=2, sort_keys=True) + "\n")
    files = [output / name for name in candidate.names]
    draft.upload(files)
    return files


def main(argv=None, run=execute) -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("preflight", "fetch-bundletool", "export"))
    parser.add_argument("--source", type=Path)
    parser.add_argument("--libraries", type=Path)
    parser.add_argument("--prism", type=Path)
    parser.add_argument("--remote-sdk", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--bundletool", type=Path)
    args = parser.parse_args(argv)
    try:
        candidate = Candidate.from_environment(os.environ)
        draft = Draft(candidate, run)
        tools = Path(__file__).resolve().parents[1]
        if args.command == "preflight":
            preflight(tools, candidate, draft, run)
            if args.source is not None:
                source_identity(args.source, candidate, run)
        elif args.command == "fetch-bundletool":
            if args.output is None:
                raise ValueError("A new disposable tool output path is required")
            fetch_bundletool(args.output, run)
            print("Pinned host manifest inspection tool verified.")
            return
        else:
            if any(getattr(args, key) is None for key in ("source", "libraries", "prism", "remote_sdk", "output", "bundletool")):
                raise ValueError("Explicit source, libraries, prism, remote SDK, bundletool, and new output paths are required")
            export(args.source, args.libraries, args.prism, args.remote_sdk, args.output, draft, args.bundletool, run, tools)
        print("Unsigned candidate draft verification passed; no Play upload or publication performed.")
    except (OSError, ValueError, KeyError, TypeError, ET.ParseError, subprocess.SubprocessError, zipfile.BadZipFile):
        parser.exit(1, "Android candidate export rejected; no automatic retry or overwrite.\n")


if __name__ == "__main__":
    main()

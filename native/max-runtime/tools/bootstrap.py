"""Download exact inert wheels, inspect their terms, and optionally install.

No SDK module or executable is imported or run here. Network work is confined to
this finite bootstrap phase; the actual graph phase runs in another namespace.
"""
from __future__ import annotations

import argparse
import email.parser
import hashlib
import json
import os
import pathlib
import re
import signal
import subprocess
import sys
import time
import urllib.request
import zipfile

from gates import ROOT, load_lock, require_hosted, verify_dependency_versions, verify_license_review


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise ValueError("Unreviewed download redirect rejected")


def download(item: dict, target: pathlib.Path, deadline: float) -> None:
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise ValueError("Aggregate network deadline exceeded")
    digest = hashlib.sha256()
    received = 0
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
    with opener.open(item["url"], timeout=min(20, remaining)) as response, target.open("xb") as output:
        if response.status != 200 or int(response.headers.get("Content-Length", "-1")) != item["size"]:
            raise ValueError("Unexpected official download length/status")
        while True:
            if time.monotonic() >= deadline:
                raise ValueError("Aggregate network deadline exceeded")
            chunk = response.read(min(65536, item["size"] - received + 1))
            if not chunk:
                break
            received += len(chunk)
            if received > item["size"]:
                raise ValueError("Download exceeded exact byte budget")
            output.write(chunk)
            digest.update(chunk)
    if received != item["size"] or digest.hexdigest() != item["sha256"]:
        raise ValueError("Official artifact identity differs")


def metadata_record(package: dict) -> dict:
    """Require the selected wheel's official hash-pinned PEP 658 identity."""
    record = package.get("wheel_metadata", {})
    if (not isinstance(record, dict)
            or record.get("index_url") != f"https://pypi.org/simple/{package['name']}/"
            or record.get("url") != package["url"] + ".metadata"
            or not isinstance(record.get("sha256"), str)
            or not re.fullmatch(r"[a-f0-9]{64}", record.get("sha256", ""))
            or type(record.get("size")) is not int or not 1 <= record["size"] <= 1048576):
        raise ValueError(f"Wheel metadata mismatch for {package['name']}=={package['version']}: PEP 658 provenance")
    return record


def inspect_metadata(package: dict, raw: bytes):
    """Match embedded METADATA to the exact sidecar and declarations, not
    PyPI's project-level JSON rendering of those dependency declarations.
    """
    record = metadata_record(package)
    identity = f"{package['name']}=={package['version']}"
    if len(raw) != record["size"]:
        raise ValueError(f"Wheel metadata mismatch for {identity}: METADATA size")
    if hashlib.sha256(raw).hexdigest() != record["sha256"]:
        raise ValueError(f"Wheel metadata mismatch for {identity}: METADATA SHA256")
    metadata = email.parser.BytesParser().parsebytes(raw)
    normalized = lambda value: re.sub(r"[-_.]+", "-", value).lower()
    if normalized(metadata.get("Name", "")) != package["name"]:
        raise ValueError(f"Wheel metadata mismatch for {identity}: Name")
    if metadata.get("Version") != package["version"]:
        raise ValueError(f"Wheel metadata mismatch for {identity}: Version")
    if sorted(metadata.get_all("Requires-Dist", [])) != sorted(package["requires_dist"]):
        raise ValueError(f"Wheel metadata mismatch for {identity}: Requires-Dist")
    return metadata


def inspect_wheels(lock: dict, wheel_dir: pathlib.Path) -> tuple[list[dict], list[dict]]:
    licenses, inventories = [], []
    aggregate = license_bytes = 0
    for package in lock["packages"]:
        path = wheel_dir / package["filename"]
        if path.stat().st_size != package["size"] or hashlib.sha256(path.read_bytes()).hexdigest() != package["sha256"]:
            raise ValueError("Wheel identity differs during inspection")
        with zipfile.ZipFile(path) as wheel:
            members = wheel.infolist()
            if len(members) > 30000:
                raise ValueError("Wheel member budget exceeded")
            paths = set()
            for member in members:
                pure = pathlib.PurePosixPath(member.filename)
                if (pure.is_absolute() or ".." in pure.parts or "\\" in member.filename
                        or pure.as_posix() in paths
                        or (member.external_attr >> 16) & 0o170000 == 0o120000):
                    raise ValueError("Unsafe wheel member rejected")
                paths.add(pure.as_posix())
                aggregate += member.file_size
            if aggregate > lock["maximum_uncompressed_bytes"]:
                raise ValueError("Aggregate SDK extraction budget exceeded")
            metadata_paths = [m.filename for m in members if re.fullmatch(r"[^/]+\.dist-info/METADATA", m.filename)]
            if len(metadata_paths) != 1:
                raise ValueError("Unique wheel metadata required")
            metadata_info = wheel.getinfo(metadata_paths[0])
            if metadata_info.file_size > 1048576:
                raise ValueError("Wheel metadata budget exceeded")
            metadata = inspect_metadata(package, wheel.read(metadata_info))
            # Product-level terms and bundled third-party notices may live
            # outside dist-info. Conservatively include every safe candidate,
            # including files under a license/legal directory; never silently
            # omit one to fit the review budget.
            def license_candidate(member: zipfile.ZipInfo) -> bool:
                if member.is_dir():
                    return False
                parts = pathlib.PurePosixPath(member.filename).parts
                tokens = r"(?:licen[cs]es?|copying|notices?|copyright|terms|eula)"
                return (bool(re.search(r"(?:^|[^a-z])" + tokens + r"(?:[^a-z]|$)", parts[-1], re.IGNORECASE))
                        or any(re.fullmatch(tokens + r"|legal|third[-_]party[-_]notices", part, re.IGNORECASE)
                               for part in parts[:-1]))
            package_licenses = [m for m in members if license_candidate(m)]
            if not package_licenses:
                raise ValueError("Embedded wheel license files required")
            for member in package_licenses:
                license_bytes += member.file_size
                if member.file_size > 262144 or license_bytes > 2097152 or len(licenses) >= 512:
                    raise ValueError("Embedded license candidates exceed the 256 KiB/file, 2 MiB aggregate or 512-file review budget")
                data = wheel.read(member)
                licenses.append({"package": package["name"], "path": member.filename,
                                 "sha256": hashlib.sha256(data).hexdigest(), "text": data.decode("utf-8")})
            inventories.append({"package": package["name"], "licenseMetadata": (metadata.get("License-Expression") or metadata.get("License") or "")[:256],
                                "nativeLibraries": [m.filename for m in members if pathlib.PurePosixPath(m.filename).name == "libmax.so"],
                                "cHeaders": [m.filename for m in members if "/max/c/" in m.filename and m.filename.endswith(".h")]})
    return licenses, inventories


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=["audit", "install"])
    parser.add_argument("--reviewed-lock", required=True)
    parser.add_argument("--work", type=pathlib.Path, required=True)
    args = parser.parse_args()
    require_hosted()
    lock = load_lock(reviewed=args.reviewed_lock)
    verify_dependency_versions(lock)
    work = args.work.resolve()
    runner_temp = pathlib.Path(os.environ["RUNNER_TEMP"]).resolve()
    if not work.is_relative_to(runner_temp) or work == runner_temp or work.exists():
        raise ValueError("New owned directory under hosted RUNNER_TEMP required")
    work.mkdir(mode=0o700)
    (work / ".quenderin-max-session-owned").write_text("max-fixture-v1\n")
    wheels = work / "wheels"
    wheels.mkdir()
    deadline = time.monotonic() + lock["maximum_network_seconds"]
    header_dir = work / "include/max/c"
    header_dir.mkdir(parents=True)
    def expired(signum, frame):
        raise TimeoutError("Aggregate network deadline exceeded")
    previous_handler = signal.signal(signal.SIGALRM, expired)
    signal.setitimer(signal.ITIMER_REAL, lock["maximum_network_seconds"])
    try:
        for package in lock["packages"]:
            download(package, wheels / package["filename"], deadline)
        for header in lock["headers"]:
            download(header, header_dir / header["filename"], deadline)
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
        signal.signal(signal.SIGALRM, previous_handler)
    licenses, inventories = inspect_wheels(lock, wheels)
    if sum(len(x["text"].encode()) for x in {x["sha256"]: x for x in licenses}.values()) > 524288:
        raise ValueError("Distinct license text exceeds the 512 KiB review log budget")
    facts = {"schema": 1, "lockSHA256": lock["lock_sha256"], "sdkVersion": lock["sdk_version"],
             "packages": inventories, "licenseSHA256": {f"{x['package']}/{x['path']}": x["sha256"] for x in licenses},
             "downloadBytes": sum(p["size"] for p in lock["packages"]), "runtimeExecuted": False}
    (work / "inspection.json").write_text(json.dumps(facts, indent=2) + "\n")
    print("QUENDERIN_MAX_SDK_INSPECTION_BEGIN")
    print(json.dumps(facts, indent=2))
    print("QUENDERIN_MAX_SDK_INSPECTION_END")
    # Emit each distinct embedded license once, so a review can inspect actual
    # binary terms without publishing or retaining a complete SDK artifact.
    seen = set()
    for license in licenses:
        if license["sha256"] not in seen:
            seen.add(license["sha256"])
            print(f"EMBEDDED_LICENSE_BEGIN {license['sha256']} {license['package']}/{license['path']}")
            print(license["text"])
            print("EMBEDDED_LICENSE_END")
    if args.mode == "audit":
        return
    verify_license_review(lock, licenses)
    if sum(bool(p["nativeLibraries"]) for p in inventories) != 1:
        raise ValueError("Exactly one pinned SDK libmax.so is required; no conda/unpinned fallback is permitted")
    # Wheel installation has no build backend or lifecycle scripts. Dependency
    # resolution and network access are disabled; the exact closure is explicit.
    result = subprocess.run([
        sys.executable, "-I", "-m", "pip", "--isolated", "install", "--no-index", "--no-deps",
        "--disable-pip-version-check", "--no-cache-dir", "--no-compile", "--target", str(work / "sdk"),
        *[str(wheels / p["filename"]) for p in lock["packages"]]],
        env={"PATH": "/usr/bin:/bin", "HOME": str(work), "TMPDIR": str(work), "LANG": "C.UTF-8"},
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=90, check=False)
    if result.returncode:
        raise ValueError("Exact offline wheel installation failed")
    (work / "installed.json").write_text(json.dumps({"lockSHA256": lock["lock_sha256"]}) + "\n")
    print(json.dumps({"sdkInstalled": True, "runtimeExecuted": False}))


if __name__ == "__main__":
    main()

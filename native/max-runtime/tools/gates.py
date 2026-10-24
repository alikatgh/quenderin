"""MAX provenance and isolation gates. Imports no vendor runtime."""
from __future__ import annotations

import hashlib
import json
import os
import pathlib
import re
import sys
import urllib.parse

ROOT = pathlib.Path(__file__).resolve().parents[1]
PACKAGES = {
    "max", "max-core", "max-mojo-libs", "max-shmem-libs", "mojo-compiler",
    "mojo-compiler-mojo-libs", "numpy", "click", "exceptiongroup", "msgspec",
    "psutil", "rich", "taskgroup", "typing-extensions", "pygments", "markdown-it-py", "mdurl",
}


def load_lock(path: pathlib.Path = ROOT / "sdk-lock.json", reviewed: str | None = None) -> dict:
    raw = path.read_bytes()
    if len(raw) > 131072:
        raise ValueError("SDK lock exceeds 128 KiB")
    digest = hashlib.sha256(raw).hexdigest()
    if reviewed is not None and (not re.fullmatch(r"[a-f0-9]{64}", reviewed) or reviewed != digest):
        raise ValueError("Independently reviewed full SDK lock SHA256 required")
    lock = json.loads(raw)
    if (lock.get("schema") != 1 or lock.get("platform") != "linux-x86_64-cpython-312"
            or lock.get("sdk_version") != "26.7.0"
            or lock.get("source_revision") != "527d069ee11a41ac5320af1f9402db0a66b2b868"
            or lock.get("maximum_download_bytes") != 350000000
            or lock.get("maximum_uncompressed_bytes") != 1600000000
            or lock.get("maximum_network_seconds") != 240
            or lock.get("maximum_runtime_seconds") != 180):
        raise ValueError("Unreviewed SDK identity or resource bounds")
    packages = lock.get("packages", [])
    if len(packages) != len(PACKAGES) or {p.get("name") for p in packages} != PACKAGES:
        raise ValueError("SDK package closure differs")
    for package in packages:
        url = urllib.parse.urlsplit(package["url"])
        if (url.scheme != "https" or url.netloc != "files.pythonhosted.org"
                or url.query or url.fragment or not url.path.startswith("/packages/")
                or pathlib.PurePosixPath(url.path).name != package["filename"]
                or not re.fullmatch(r"[A-Za-z0-9_.-]+\.whl", package["filename"])
                or not re.fullmatch(r"[0-9]+(?:\.[0-9]+)+", package["version"])
                or not package["filename"].startswith(package["name"].replace("-", "_") + "-" + package["version"] + "-")
                or not re.fullmatch(r"[a-f0-9]{64}", package["sha256"])
                or type(package["size"]) is not int or not 1 <= package["size"] <= 100000000
                or package["metadata_url"] != f"https://pypi.org/pypi/{package['name']}/{package['version']}/json"):
            raise ValueError("Unpinned or unofficial wheel")
        expected = "1.2.0" if package["name"].startswith("mojo-compiler") else "26.7.0"
        if package["name"].startswith(("max", "mojo-compiler")) and package["version"] != expected:
            raise ValueError("Mixed MAX/compiler generation")
    if sum(p["size"] for p in packages) > lock["maximum_download_bytes"]:
        raise ValueError("SDK download exceeds aggregate budget")
    headers = lock.get("headers", [])
    expected = {f"{name}.h" for name in ["common", "context", "device", "model", "tensor", "types", "weights", "symbol_export"]}
    if len(headers) != len(expected) or {h.get("filename") for h in headers} != expected:
        raise ValueError("Pinned C API header closure required")
    for header in headers:
        expected_url = f"https://raw.githubusercontent.com/modular/modular/{lock['source_revision']}/max/include/max/c/{header['filename']}"
        if (header["url"] != expected_url or not re.fullmatch(r"[a-f0-9]{64}", header["sha256"])
                or type(header["size"]) is not int or not 1 <= header["size"] <= 32768):
            raise ValueError("Unpinned C API header")
    lock["lock_sha256"] = digest
    return lock


def verify_dependency_versions(lock: dict) -> None:
    # pip is an existing hosted prerequisite, not a new fixture dependency.
    # Its maintained PEP 508 parser handles platform/Python/extra markers.
    from pip._vendor.packaging.requirements import Requirement
    versions = {p["name"]: p["version"] for p in lock["packages"]}
    for package in lock["packages"]:
        for value in package["requires_dist"]:
            requirement = Requirement(value)
            if requirement.marker is not None and not requirement.marker.evaluate({"extra": ""}):
                continue
            name = re.sub(r"[-_.]+", "-", requirement.name).lower()
            if requirement.url or requirement.extras or name not in versions or versions[name] not in requirement.specifier:
                raise ValueError("Missing or incompatible active SDK dependency")


def require_hosted() -> None:
    if (sys.platform != "linux" or os.environ.get("GITHUB_ACTIONS") != "true"
            or sys.version_info[:2] != (3, 12) or os.uname().machine != "x86_64"):
        raise ValueError("Hosted Linux x86_64 CPython 3.12 required; local SDK installation is disabled")


def assert_status(status: str) -> None:
    fields = dict(line.split(":", 1) for line in status.splitlines() if ":" in line)
    uids = fields.get("Uid", "").split()
    if (len(uids) != 4 or any(not uid.isdigit() or int(uid) == 0 for uid in uids)
            or any(not re.fullmatch(r"0+", fields.get(name, "").strip()) for name in
                   ["CapEff", "CapPrm", "CapBnd", "CapInh", "CapAmb"])
            or fields.get("NoNewPrivs", "").strip() != "1"):
        raise ValueError("Unprivileged capability-free no-new-privs execution required")


def assert_network(parent: str, current: str, interfaces: str, ipv4: str, ipv6: str) -> None:
    if (not re.fullmatch(r"net:\[[0-9]+\]", parent)
            or not re.fullmatch(r"net:\[[0-9]+\]", current) or parent == current):
        raise ValueError("A distinct Linux network namespace is required")
    names = [line.split(":", 1)[0].strip() for line in interfaces.strip().splitlines()[2:]]
    if (any(name != "lo" for name in names)
            or any(line.split()[0] != "lo" for line in ipv4.strip().splitlines()[1:] if line.strip())
            or any(line.split()[-1] != "lo" for line in ipv6.strip().splitlines() if line.strip())):
        raise ValueError("Only isolated loopback interfaces/routes are permitted")


def runtime_environment(scratch: pathlib.Path, sdk: pathlib.Path, libraries: list[pathlib.Path]) -> dict[str, str]:
    paths = [scratch, sdk, *libraries]
    if not all(p.is_absolute() for p in paths):
        raise ValueError("Absolute owned fixture paths required")
    return {
        "PATH": "/usr/bin:/bin", "LANG": "C.UTF-8", "LC_ALL": "C.UTF-8", "TZ": "UTC",
        "HOME": str(scratch), "TMPDIR": str(scratch), "XDG_CACHE_HOME": str(scratch / "cache"),
        "XDG_STATE_HOME": str(scratch / "state"), "MODULAR_HOME": str(scratch / "modular"),
        "MODULAR_CACHE_DIR": str(scratch / "cache"), "MODULAR_TELEMETRY_ENABLED": "0",
        "MODULAR_CRASH_REPORTING_ENABLED": "0", "PYTHONDONTWRITEBYTECODE": "1",
        "PYTHONNOUSERSITE": "1", "PYTHONPATH": str(sdk), "OMP_NUM_THREADS": "2",
        "OPENBLAS_NUM_THREADS": "2", "QUENDERIN_MAX_ISOLATED": "1",
        "LD_LIBRARY_PATH": ":".join(str(p) for p in libraries),
    }


def verify_license_review(lock: dict, licenses: list[dict]) -> None:
    review = lock.get("runtime_license_review")
    actual = {f"{item['package']}/{item['path']}": item["sha256"] for item in licenses}
    if (not actual or not isinstance(review, dict)
            or review.get("scope") != "hosted-cpu-fixture-only-no-redistribution"
            or review.get("license_sha256") != actual):
        raise ValueError("Exact embedded SDK/dependency license inspection and recorded review required before installation or execution")

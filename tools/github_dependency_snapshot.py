"""Submit one trusted Android dependency snapshot without artifact fallbacks."""
from __future__ import annotations

from datetime import datetime
import http.client
import json
import os
from pathlib import Path
import re
import stat
import sys

REPOSITORY = "alikatgh/quenderin"
CORRELATOR = "quenderin-android-main"
REPORT_DIRECTORY = "quenderin-dependency-graph"
MAX_SNAPSHOT_BYTES = 8 * 1024 * 1024
MAX_RESPONSE_BYTES = 64 * 1024
NETWORK_TIMEOUT_SECONDS = 30
DETECTOR = {
    "name": "GitHub Dependency Graph Gradle Plugin",
    "version": "1.5.0",
    "url": "https://github.com/gradle/github-dependency-graph-gradle-plugin",
}


class SnapshotError(Exception):
    """A fixed, credential-free diagnostic safe to print."""


def _unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise SnapshotError("Snapshot JSON contains duplicate keys.")
        result[key] = value
    return result


def read_snapshot(environment):
    """Read only the generator's single, bounded regular file and verify identity."""
    if (environment.get("GITHUB_REPOSITORY") != REPOSITORY
            or environment.get("GITHUB_EVENT_NAME") != "push"
            or environment.get("GITHUB_REF") != "refs/heads/main"):
        raise SnapshotError("Submission requires the trusted main push context.")
    sha = environment.get("GITHUB_SHA", "")
    run_id = environment.get("GITHUB_RUN_ID", "")
    if not re.fullmatch(r"[0-9a-f]{40}(?:[0-9a-f]{24})?", sha) or not re.fullmatch(r"[1-9][0-9]*", run_id):
        raise SnapshotError("Current run identity is invalid.")
    root = Path(environment.get("RUNNER_TEMP", ""))
    expected = root / REPORT_DIRECTORY / f"{CORRELATOR}.json"
    if not root.is_absolute() or environment.get("SNAPSHOT_PATH") != str(expected):
        raise SnapshotError("Snapshot output path does not match the expected report.")
    if expected.parent.is_symlink():
        raise SnapshotError("Snapshot report directory must not be a symlink.")
    with os.scandir(expected.parent) as entries:
        first = next(entries, None)
        if (first is None or first.name != expected.name
                or not first.is_file(follow_symlinks=False)
                or next(entries, None) is not None):
            raise SnapshotError("Expected exactly one regular snapshot report.")
    descriptor = os.open(expected, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(descriptor, "rb") as report:
        info = os.fstat(report.fileno())
        if not stat.S_ISREG(info.st_mode) or not 0 < info.st_size <= MAX_SNAPSHOT_BYTES:
            raise SnapshotError("Snapshot must be a regular file of at most 8 MiB.")
        payload = report.read(MAX_SNAPSHOT_BYTES + 1)
        if len(payload) != info.st_size or len(payload) > MAX_SNAPSHOT_BYTES:
            raise SnapshotError("Snapshot changed while being read.")
    try:
        snapshot = json.loads(payload.decode("utf-8"), object_pairs_hook=_unique_object)
    except (ValueError, UnicodeError, RecursionError):
        raise SnapshotError("Snapshot is not valid UTF-8 JSON.") from None
    if not isinstance(snapshot, dict):
        raise SnapshotError("Snapshot must be a JSON object.")
    if (type(snapshot.get("version")) is not int or snapshot["version"] != 0
            or snapshot.get("sha") != sha or snapshot.get("ref") != "refs/heads/main"
            or snapshot.get("detector") != DETECTOR):
        raise SnapshotError("Snapshot identity or pinned detector does not match.")
    job = snapshot.get("job")
    if not isinstance(job, dict) or job.get("id") != run_id or job.get("correlator") != CORRELATOR:
        raise SnapshotError("Snapshot job identity does not match the current run.")
    scanned = snapshot.get("scanned")
    try:
        timestamp = datetime.fromisoformat(scanned.replace("Z", "+00:00")) if isinstance(scanned, str) else None
    except ValueError:
        timestamp = None
    if timestamp is None or timestamp.tzinfo is None:
        raise SnapshotError("Snapshot scan timestamp is invalid.")
    manifests = snapshot.get("manifests")
    if not isinstance(manifests, dict) or set(manifests) != {CORRELATOR}:
        raise SnapshotError("Snapshot must contain the expected Android manifest.")
    manifest = manifests[CORRELATOR]
    if (not isinstance(manifest, dict) or manifest.get("name") != CORRELATOR
            or manifest.get("file") != {"source_location": "android/settings.gradle.kts"}):
        raise SnapshotError("Snapshot manifest does not describe the Android build.")
    resolved = manifest.get("resolved")
    if (not isinstance(resolved, dict) or not resolved
            or any(not isinstance(value, dict) or not isinstance(value.get("package_url"), str)
                   or not value["package_url"] for value in resolved.values())
            or not any(value["package_url"].startswith("pkg:maven/androidx.") for value in resolved.values())):
        # The pinned plugin always adds the Gradle build tool; that alone is not
        # evidence that Android dependencies were actually resolved.
        raise SnapshotError("Snapshot has no populated Android dependency graph.")
    return payload, len(resolved)


def submit_snapshot(payload, token, connection_factory=http.client.HTTPSConnection):
    """One fixed HTTPS POST; http.client follows no redirects and retries none."""
    connection = connection_factory("api.github.com", timeout=NETWORK_TIMEOUT_SECONDS)
    try:
        connection.request("POST", f"/repos/{REPOSITORY}/dependency-graph/snapshots", body=payload, headers={
            "Authorization": f"Bearer {token}",
            "Accept": "application/vnd.github+json",
            "Content-Type": "application/json",
            "User-Agent": "quenderin-dependency-snapshot",
            "X-GitHub-Api-Version": "2026-03-10",
        })
        response = connection.getresponse()
        if type(response.status) is not int or response.status != 201:
            status = response.status if type(response.status) is int else "invalid"
            raise SnapshotError(f"GitHub snapshot request rejected (HTTP {status}).")
        body = response.read(MAX_RESPONSE_BYTES + 1)
        if len(body) > MAX_RESPONSE_BYTES:
            raise SnapshotError("GitHub snapshot response exceeds the size limit.")
        receipt = json.loads(body)
        if (not isinstance(receipt, dict) or receipt.get("result") != "SUCCESS"
                or type(receipt.get("id")) is not int or receipt["id"] <= 0):
            raise SnapshotError("GitHub snapshot success receipt is invalid.")
        return receipt["id"]
    finally:
        connection.close()


def main(environment=None, connection_factory=http.client.HTTPSConnection):
    environment = os.environ if environment is None else environment
    try:
        payload, count = read_snapshot(environment)
        token = environment.get("GH_TOKEN")
        if not token:
            raise SnapshotError("GitHub snapshot token is unavailable.")
        snapshot_id = submit_snapshot(payload, token, connection_factory)
    except SnapshotError as error:
        print(f"Dependency snapshot failed: {error}", file=sys.stderr)
        return 1
    except Exception:
        # Never log exception messages, HTTP bodies, request headers or paths.
        print("Dependency snapshot failed: report or network operation unavailable.", file=sys.stderr)
        return 1
    print(f"Dependency snapshot submitted: id={snapshot_id}, sha={environment['GITHUB_SHA']}, dependencies={count}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

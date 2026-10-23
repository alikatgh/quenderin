#!/usr/bin/env python3
"""Validate shared carrier fixtures and their actual native execution evidence."""
from __future__ import annotations

import argparse
from collections import Counter
from pathlib import Path
import re
import sys

if __package__:
    from .check_native_connections_contract import checked_json, ContractError, MAX_FIXTURE_BYTES, MAX_LOG_BYTES
else:
    from check_native_connections_contract import checked_json, ContractError, MAX_FIXTURE_BYTES, MAX_LOG_BYTES

ROOT = Path(__file__).resolve().parent.parent
MARKER = re.compile(r"^REMOTE_HARNESS_FIXTURE_PASS ([a-z0-9][a-z0-9-]{0,127})$", re.MULTILINE)


def fixture_ids(document: dict) -> list[str]:
    if set(document) != {"schemaVersion", "requests", "frames"} or type(document["schemaVersion"]) is not int or document["schemaVersion"] != 1:
        raise ContractError("Unsupported carrier fixture schema.")
    ids = []
    for group in ("requests", "frames"):
        rows = document[group]
        if not isinstance(rows, list) or not rows:
            raise ContractError("Empty carrier fixture group.")
        for row in rows:
            if not isinstance(row, dict) or not isinstance(row.get("id"), str) or not re.fullmatch(r"[a-z0-9][a-z0-9-]{0,127}", row["id"]):
                raise ContractError("Invalid carrier fixture identifier.")
            ids.append(row["id"])
            expected = "expectedFrame" if group == "requests" else "expected"
            if (expected in row) == ("error" in row):
                raise ContractError("Carrier fixture needs exactly one outcome.")
            if group == "requests":
                if not isinstance(row.get("method"), str) or not isinstance(row.get("params"), dict) or not isinstance(row.get("frameID"), str) or type(row.get("timestamp")) is not int:
                    raise ContractError("Incomplete carrier request fixture.")
            elif not isinstance(row.get("rawJSON"), str):
                raise ContractError("Incomplete carrier frame fixture.")
    if len(ids) != len(set(ids)):
        raise ContractError("Duplicate carrier fixture identifier.")
    return ids


def validate_report(log: str, expected_ids: list[str]) -> int:
    counts = Counter(MARKER.findall(log))
    if set(counts) != set(expected_ids) or any(n != 1 for n in counts.values()):
        raise ContractError("Incomplete, duplicate or unknown carrier test evidence.")
    return len(counts)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fixtures", type=Path, default=ROOT / "shared/remote-harness-carrier-fixtures.json")
    parser.add_argument("--results", type=Path)
    args = parser.parse_args(argv)
    try:
        with args.fixtures.open("rb") as stream:
            ids = fixture_ids(checked_json(stream.read(MAX_FIXTURE_BYTES + 1)))
        if args.results:
            with args.results.open("rb") as stream:
                raw = stream.read(MAX_LOG_BYTES + 1)
            if len(raw) > MAX_LOG_BYTES:
                raise ContractError("Oversized carrier test report.")
            n = validate_report(raw.decode("utf-8", errors="strict").replace("\r\n", "\n"), ids)
            print(f"Remote Harness fixture executions: {n}/{len(ids)} passed exactly once.")
        else:
            print(f"Remote Harness fixture integrity: {len(ids)} cases.")
        return 0
    except (ContractError, OSError, UnicodeError):
        print("Remote Harness contract check failed: malformed fixtures or incomplete native evidence.", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())

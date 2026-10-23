#!/usr/bin/env python3
"""Require actual native execution of the shared control-wire lifecycle cases."""
from __future__ import annotations

import argparse
from pathlib import Path
import re
import sys

if __package__:
    from .check_remote_harness_carrier import checked_json, ContractError, MAX_FIXTURE_BYTES, MAX_LOG_BYTES, validate_report
else:
    from check_remote_harness_carrier import checked_json, ContractError, MAX_FIXTURE_BYTES, MAX_LOG_BYTES, validate_report

ROOT = Path(__file__).resolve().parent.parent
MARKER = re.compile(r"^REMOTE_HARNESS_CONTROL_WIRE_FIXTURE_PASS ([a-z0-9][a-z0-9-]{0,127})$", re.MULTILINE)


def fixture_ids(document: dict) -> list[str]:
    if (set(document) != {"schemaVersion", "upstreamRevision", "origin", "cases"}
            or type(document["schemaVersion"]) is not int or document["schemaVersion"] != 1
            or not isinstance(document["upstreamRevision"], str)
            or not re.fullmatch(r"[a-f0-9]{40}", document["upstreamRevision"])
            or not isinstance(document["origin"], str)):
        raise ContractError("Unsupported control-wire fixture schema.")
    rows = document["cases"]
    if not isinstance(rows, list) or not rows:
        raise ContractError("Empty control-wire fixture inventory.")
    ids = []
    for row in rows:
        if (not isinstance(row, dict) or set(row) - {"id", "steps", "note"}
                or not isinstance(row.get("id"), str)
                or not re.fullmatch(r"[a-z0-9][a-z0-9-]{0,127}", row["id"])
                or not isinstance(row.get("note", ""), str)
                or len(row.get("note", "").encode("utf-8")) > 1_024
                or not isinstance(row.get("steps"), list) or not row["steps"]
                or any(not isinstance(step, dict) or not isinstance(step.get("action"), str) for step in row["steps"])):
            raise ContractError("Invalid control-wire fixture case.")
        ids.append(row["id"])
    if len(ids) != len(set(ids)):
        raise ContractError("Duplicate control-wire fixture identifier.")
    return ids


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fixtures", type=Path, default=ROOT / "shared/remote-harness-control-wire-fixtures.json")
    parser.add_argument("--results", type=Path)
    args = parser.parse_args(argv)
    try:
        with args.fixtures.open("rb") as stream:
            ids = fixture_ids(checked_json(stream.read(MAX_FIXTURE_BYTES + 1)))
        if args.results:
            with args.results.open("rb") as stream:
                data = stream.read(MAX_LOG_BYTES + 1)
            if len(data) > MAX_LOG_BYTES:
                raise ContractError("Oversized native test report.")
            count = validate_report(data.decode("utf-8", errors="strict").replace("\r\n", "\n"), ids, marker=MARKER)
            print(f"Remote Harness control-wire executions: {count}/{len(ids)} passed exactly once.")
        else:
            print(f"Remote Harness control-wire fixture integrity: {len(ids)} cases.")
        return 0
    except (ContractError, OSError, UnicodeError):
        print("Remote Harness control-wire check failed: malformed fixtures or incomplete native evidence.", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())

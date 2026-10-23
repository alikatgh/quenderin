#!/usr/bin/env python3
"""Require real Swift/Kotlin execution of every canonical DeepSeek case."""
from __future__ import annotations

import argparse
import base64
import binascii
from collections import Counter
import re
from pathlib import Path
import sys

if __package__:
    from .check_native_connections_contract import checked_json, ContractError, MAX_FIXTURE_BYTES, MAX_LOG_BYTES
else:
    from check_native_connections_contract import checked_json, ContractError, MAX_FIXTURE_BYTES, MAX_LOG_BYTES

ROOT = Path(__file__).resolve().parent.parent
MARKER = re.compile(r"^DEEPSEEK_FIXTURE_PASS ([a-z0-9][a-z0-9-]{0,127})$", re.MULTILINE)


def fixture_ids(document: dict) -> list[str]:
    if set(document) != {"schemaVersion", "requests", "streams", "models"} or type(document["schemaVersion"]) is not int or document["schemaVersion"] != 1:
        raise ContractError("Unsupported DeepSeek fixture document.")
    ids = []
    for group in ("requests", "streams", "models"):
        rows = document[group]
        if not isinstance(rows, list) or not rows:
            raise ContractError("Empty DeepSeek fixture group.")
        for row in rows:
            if not isinstance(row, dict) or not isinstance(row.get("id"), str) or not re.fullmatch(r"[a-z0-9][a-z0-9-]{0,127}", row["id"]):
                raise ContractError("Invalid DeepSeek fixture identifier.")
            ids.append(row["id"])
            success = "expectedBody" if group == "requests" else "expectedIDs" if group == "models" else "expected"
            if (success in row) == ("error" in row):
                raise ContractError("Fixture needs exactly one expected outcome.")
            if group == "requests":
                if not all(isinstance(row.get(k), dict) for k in ("profile", "envelope", "limits")) or not isinstance(row.get("tools"), list):
                    raise ContractError("Incomplete request fixture.")
            elif group == "models":
                if not isinstance(row.get("json"), str):
                    raise ContractError("Incomplete model fixture.")
            else:
                chunks = row.get("chunksBase64")
                if not isinstance(chunks, list) or not chunks or type(row.get("maxToolCalls")) is not int:
                    raise ContractError("Incomplete stream fixture.")
                for chunk in chunks:
                    if not isinstance(chunk, str):
                        raise ContractError("Invalid stream byte fixture.")
                    try:
                        base64.b64decode(chunk, validate=True)
                    except (binascii.Error, ValueError) as error:
                        raise ContractError("Invalid stream byte fixture.") from error
    if len(ids) != len(set(ids)):
        raise ContractError("Duplicate DeepSeek fixture identifier.")
    return ids


def validate_report(log: str, expected_ids: list[str]) -> int:
    counts = Counter(MARKER.findall(log))
    if set(counts) != set(expected_ids) or any(n != 1 for n in counts.values()):
        raise ContractError("Incomplete, duplicate or unexpected DeepSeek test evidence.")
    return len(counts)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fixtures", type=Path, default=ROOT / "shared/deepseek-provider-fixtures.json")
    parser.add_argument("--results", type=Path)
    args = parser.parse_args(argv)
    try:
        with args.fixtures.open("rb") as stream:
            ids = fixture_ids(checked_json(stream.read(MAX_FIXTURE_BYTES + 1)))
        if args.results:
            with args.results.open("rb") as stream:
                raw = stream.read(MAX_LOG_BYTES + 1)
            if len(raw) > MAX_LOG_BYTES:
                raise ContractError("Oversized native report.")
            count = validate_report(raw.decode("utf-8", errors="strict").replace("\r\n", "\n"), ids)
            print(f"DeepSeek fixture executions: {count}/{len(ids)} passed exactly once.")
        else:
            print(f"DeepSeek fixture integrity: {len(ids)} cases.")
        return 0
    except (ContractError, OSError, UnicodeError):
        print("DeepSeek contract check failed: malformed fixtures or incomplete native test evidence.", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())

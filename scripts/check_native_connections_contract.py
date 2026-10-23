#!/usr/bin/env python3
"""Check fixture integrity and actual native fixture coverage, without model calls.

Native tests own behavioral correctness. This guard verifies their successful
fixture markers cover the exact same canonical cases once each; static source
markers are not treated as execution evidence. Run --results on a completed
native test log. It never prints fixture inputs, messages or log contents.
"""
from __future__ import annotations

import argparse
from collections import Counter
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parent.parent
GROUPS = ("profilesValid", "profilesInvalid", "envelopesValid", "envelopesInvalid", "legacy")
IDENTIFIER = re.compile(r"[a-z0-9][a-z0-9-]{0,127}\Z")
MARKER = re.compile(r"^NATIVE_CONNECTION_FIXTURE_PASS ([a-z0-9][a-z0-9-]{0,127})$", re.MULTILINE)
MAX_FIXTURE_BYTES = 512 * 1024
MAX_LOG_BYTES = 16 * 1024 * 1024


class ContractError(ValueError):
    """Safe fixed diagnostic; never embed untrusted fixture/log content."""


def checked_json(data: bytes) -> dict:
    if len(data) > MAX_FIXTURE_BYTES:
        raise ContractError("Canonical fixture file exceeds its size bound.")

    def pairs(items: list[tuple[str, object]]) -> dict:
        result: dict = {}
        for key, value in items:
            if key in result:
                raise ContractError("Duplicate JSON object key in canonical fixture file.")
            result[key] = value
        return result

    try:
        value = json.loads(data.decode("utf-8", errors="strict"), object_pairs_hook=pairs,
                           parse_constant=lambda _: (_ for _ in ()).throw(ContractError("Nonfinite JSON number.")))
    except (UnicodeError, json.JSONDecodeError, RecursionError) as error:
        raise ContractError("Canonical fixture file is not valid bounded UTF-8 JSON.") from error
    if not isinstance(value, dict):
        raise ContractError("Canonical fixture file must be an object.")
    return value


def fixture_ids(document: dict) -> list[str]:
    if type(document.get("schemaVersion")) is not int or document["schemaVersion"] != 1:
        raise ContractError("Unsupported fixture schema version.")
    if set(document) != {"schemaVersion", *GROUPS}:
        raise ContractError("Canonical fixture groups do not match the contract.")
    ids: list[str] = []
    for group in GROUPS:
        rows = document[group]
        if not isinstance(rows, list) or not rows:
            raise ContractError("Every canonical fixture group must be nonempty.")
        for row in rows:
            if not isinstance(row, dict):
                raise ContractError("Canonical fixture case must be an object.")
            case_id = row.get("id")
            if not isinstance(case_id, str) or not IDENTIFIER.fullmatch(case_id):
                raise ContractError("Invalid canonical fixture identifier.")
            ids.append(case_id)
            if group == "legacy":
                if set(row) != {"id", "conversationID", "swiftSource", "kotlinSource", "expectedMessages"}:
                    raise ContractError("Legacy fixture fields do not match the contract.")
                if not all(isinstance(row[k], str) for k in ("conversationID", "swiftSource", "kotlinSource")):
                    raise ContractError("Legacy fixture source fields must be strings.")
                expected = row["expectedMessages"]
                if not isinstance(expected, list):
                    raise ContractError("Legacy fixture expected messages must be an array.")
                for index, message in enumerate(expected):
                    if not isinstance(message, dict) or not {"id", "role", "content"} <= set(message):
                        raise ContractError("Legacy expected message is incomplete.")
                    if message["id"] != f"legacy-{index}" or message["role"] not in ("user", "assistant"):
                        raise ContractError("Legacy message identity/role must remain local and ordered.")
                    if not isinstance(message["content"], str):
                        raise ContractError("Legacy message content must remain a string.")
            else:
                if set(row) == {"id", "input"}:
                    if not isinstance(row["input"], dict):
                        raise ContractError("Structured fixture input must be an object.")
                elif set(row) == {"id", "rawJSON"} and group.endswith("Invalid"):
                    if not isinstance(row["rawJSON"], str):
                        raise ContractError("Raw invalid fixture input must be a string.")
                else:
                    raise ContractError("Fixture case fields do not match the contract.")
    if len(ids) != len(set(ids)):
        raise ContractError("Duplicate canonical fixture identifier.")
    destinations = {row["input"].get("kind") for row in document["profilesValid"]}
    if destinations != {"local", "deepseek", "remoteHarness"}:
        raise ContractError("Valid profiles must exercise all three destinations.")
    return ids


def validate_report(log: str, expected_ids: list[str]) -> int:
    counts = Counter(MARKER.findall(log))
    expected = set(expected_ids)
    if set(counts) - expected:
        raise ContractError("Native report contains an unknown fixture identifier.")
    if expected - set(counts):
        raise ContractError("Native report is missing successful fixture executions.")
    if any(count != 1 for count in counts.values()):
        raise ContractError("Native report repeats a fixture execution.")
    return len(counts)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fixtures", type=Path, default=ROOT / "shared/native-connections-fixtures.json")
    parser.add_argument("--results", type=Path, help="Native test log with successful fixture markers")
    args = parser.parse_args(argv)
    try:
        with args.fixtures.open("rb") as stream:
            document = checked_json(stream.read(MAX_FIXTURE_BYTES + 1))
        ids = fixture_ids(document)
        if args.results is not None:
            with args.results.open("rb") as stream:
                raw_log = stream.read(MAX_LOG_BYTES + 1)
            if len(raw_log) > MAX_LOG_BYTES:
                raise ContractError("Native test report exceeds its size bound.")
            log = raw_log.decode("utf-8", errors="strict").replace("\r\n", "\n")
            count = validate_report(log, ids)
            print(f"Native connection fixture executions: {count}/{len(ids)} passed exactly once.")
        else:
            print(f"Native connection fixture integrity: {len(ids)} cases across {len(GROUPS)} groups.")
        return 0
    except (ContractError, OSError, UnicodeError):
        # Do not echo paths, native logs, JSON decoder excerpts or user content.
        print("Native connection contract check failed: malformed fixtures or incomplete/duplicate test evidence.", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())

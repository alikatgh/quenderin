#!/usr/bin/env python3
"""Require actual native execution of every shared attention-policy case."""
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
IDENTIFIER = re.compile(r"[a-z0-9][a-z0-9-]{0,127}")
MARKER = re.compile(r"^REMOTE_ATTENTION_CASE_PASS ([a-z0-9][a-z0-9-]{0,127})$", re.MULTILINE)


def fixture_ids(document: dict) -> list[str]:
    if not isinstance(document, dict) or type(document.get("schemaVersion")) is not int or document["schemaVersion"] != 1:
        raise ContractError("Unsupported attention fixture version.")
    cases = document.get("cases")
    if not isinstance(cases, list) or not 1 <= len(cases) <= 256:
        raise ContractError("Invalid attention fixture count.")
    result = []
    for case in cases:
        if not isinstance(case, dict) or not isinstance(case.get("id"), str) or not IDENTIFIER.fullmatch(case["id"]):
            raise ContractError("Invalid attention fixture ID.")
        if not isinstance(case.get("steps"), list) or not case["steps"]:
            raise ContractError("An attention case needs execution steps.")
        result.append(case["id"])
    if len(set(result)) != len(result):
        raise ContractError("Duplicate attention fixture ID.")
    return result


def validate_report(log: str, expected: list[str]) -> int:
    observed = Counter(MARKER.findall(log))
    if set(observed) != set(expected) or any(count != 1 for count in observed.values()):
        raise ContractError("Missing, duplicate or unexpected attention execution evidence.")
    return len(observed)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fixtures", type=Path, default=ROOT / "shared/remote-harness-attention-fixtures.json")
    parser.add_argument("--results", type=Path)
    args = parser.parse_args(argv)
    try:
        with args.fixtures.open("rb") as stream:
            expected = fixture_ids(checked_json(stream.read(MAX_FIXTURE_BYTES + 1)))
        if args.results:
            with args.results.open("rb") as stream:
                raw = stream.read(MAX_LOG_BYTES + 1)
            if len(raw) > MAX_LOG_BYTES:
                raise ContractError("Oversized native report.")
            count = validate_report(raw.decode("utf-8", errors="strict").replace("\r\n", "\n"), expected)
            print(f"Remote attention native execution: {count}/{len(expected)} cases passed exactly once.")
        else:
            print(f"Remote attention fixture integrity: {len(expected)} cases; native execution not established.")
        return 0
    except (ContractError, OSError, UnicodeError):
        print("Remote attention gate failed: invalid fixtures or incomplete native execution evidence.", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())

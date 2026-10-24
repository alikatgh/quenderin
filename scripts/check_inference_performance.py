#!/usr/bin/env python3
"""Require the same bounded Automatic-selection cases on both native platforms."""
from __future__ import annotations

import argparse
from collections import Counter
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parent.parent
MARKER = re.compile(r"^INFERENCE_PERFORMANCE_FIXTURE_PASS ([a-zA-Z0-9-]{1,128})$", re.MULTILINE)
MAX_REPORT_BYTES = 32 * 1024 * 1024


def fixture_names(path: Path) -> list[str]:
    raw = path.read_bytes()
    if len(raw) > 256 * 1024:
        raise ValueError("Oversized performance fixture document")
    document = json.loads(raw)
    if document.get("schemaVersion") != 1 or not isinstance(document.get("cases"), list):
        raise ValueError("Unsupported performance fixture schema")
    names = [case["name"] for case in document["cases"]]
    if not names or len(names) > 128 or len(names) != len(set(names)) or any(not re.fullmatch(r"[a-zA-Z0-9-]{1,128}", name) for name in names):
        raise ValueError("Invalid performance fixture names")
    gates = {"installed", "verified", "runtimeAvailable", "fitsMemory", "fitsContext", "fitsDisk", "supportsTask", "qualityEligible"}
    for case in document["cases"]:
        if len(case["samples"]) > 64 or len(case["candidates"]) > 64:
            raise ValueError("Unbounded performance fixture")
        for candidate in case["candidates"]:
            if any(type(candidate[gate]) is not bool for gate in gates):
                raise ValueError("Invalid admission gate")
            for key in ("artifactSHA256", "runtimeID", "environmentID"):
                if not re.fullmatch(r"[a-f0-9]{64}", candidate[key]):
                    raise ValueError("Invalid fixture identity")
        if case["expectedModelID"] not in {candidate["modelID"] for candidate in case["candidates"]}:
            raise ValueError("Expected model is absent")
    return names


def validate_results(text: str, expected: list[str]) -> None:
    if Counter(MARKER.findall(text.replace("\r\n", "\n"))) != Counter(expected):
        raise ValueError("Incomplete or duplicated native performance evidence")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fixtures", type=Path, default=ROOT / "shared/inference-performance-fixtures.json")
    parser.add_argument("--results", type=Path)
    args = parser.parse_args(argv)
    try:
        names = fixture_names(args.fixtures)
        if args.results:
            with args.results.open("rb") as stream:
                data = stream.read(MAX_REPORT_BYTES + 1)
            if len(data) > MAX_REPORT_BYTES:
                raise ValueError("Oversized native report")
            validate_results(data.decode("utf-8", errors="strict"), names)
            print(f"Inference performance fixture executions: {len(names)}/{len(names)} passed exactly once.")
        else:
            print(f"Inference performance fixture integrity: {len(names)} cases.")
        return 0
    except (ValueError, KeyError, TypeError, OSError, UnicodeError):
        print("Inference performance check failed: invalid fixtures or incomplete native evidence.", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())

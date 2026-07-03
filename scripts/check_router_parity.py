#!/usr/bin/env python3
"""Verify the cross-platform MODEL-ROUTER parity suite covers the same vectors on every platform.

Same guardrail as check_agent_parity.py, applied to ModelRouter's prompt classification:
  - iOS     : apple/QuenderinKit/Tests/QuenderinKitTests/RouterParityTests.swift
  - Android : android/quenderin-core/src/verify/CoreVerify.kt  (the "parity:router-*" checks)

Namespace contract: every router vector id starts with "router-". check_agent_parity.py IGNORES
router-* markers (they share CoreVerify.kt with the agent suite); this script counts ONLY them.
The two scripts partition the parity:<id> marker space — an id must belong to exactly one canon.

Usage:  python3 scripts/check_router_parity.py     # exit 0 = in sync, 1 = drift
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

CANONICAL = ROOT / "shared" / "router-parity-vectors.json"
SUITES = {
    "iOS": ROOT / "apple" / "QuenderinKit" / "Tests" / "QuenderinKitTests" / "RouterParityTests.swift",
    "Android": ROOT / "android" / "quenderin-core" / "src" / "verify" / "CoreVerify.kt",
}

MARKER = re.compile(r"parity:(router-[a-z0-9][a-z0-9-]*)")


def fail(msg: str) -> None:
    print(f"  ✗ {msg}")


def main() -> int:
    if not CANONICAL.exists():
        print(f"FAIL: canonical vectors missing: {CANONICAL.relative_to(ROOT)}")
        return 1

    doc = json.loads(CANONICAL.read_text(encoding="utf-8"))
    vectors = doc.get("vectors", [])
    canonical = [v["id"] for v in vectors]

    not_namespaced = [i for i in canonical if not i.startswith("router-")]
    if not_namespaced:
        print(f"FAIL: router vector ids must start with 'router-': {not_namespaced}")
        return 1

    dupes = {i for i in canonical if canonical.count(i) > 1}
    if dupes:
        print(f"FAIL: duplicate ids in {CANONICAL.relative_to(ROOT)}: {sorted(dupes)}")
        return 1
    canonical_set = set(canonical)

    print(f"Canonical router parity vectors: {len(canonical_set)}")
    ok = True
    for platform, path in SUITES.items():
        if not path.exists():
            print(f"FAIL: {platform} suite missing: {path.relative_to(ROOT)}")
            ok = False
            continue
        found = MARKER.findall(path.read_text(encoding="utf-8"))
        found_set = set(found)

        repeated = {m for m in found_set if found.count(m) > 1}
        missing = canonical_set - found_set
        orphan = found_set - canonical_set

        if missing or orphan or repeated:
            print(f"\n{platform}  ({path.relative_to(ROOT)}) — DRIFT:")
            for m in sorted(missing):
                fail(f"missing coverage for canonical vector: {m}")
            for m in sorted(orphan):
                fail(f"orphan marker (no such canonical vector — typo?): {m}")
            for m in sorted(repeated):
                fail(f"marker appears more than once (copy-paste?): {m}")
            ok = False
        else:
            print(f"{platform}: all {len(canonical_set)} vectors covered ✓")

    if not ok:
        print("\nRouter parity DRIFT — add the missing case (or fix the id) so both platforms cover every vector.")
        return 1
    print("\nRouter parity suites are in sync across iOS + Android.")
    return 0


if __name__ == "__main__":
    sys.exit(main())

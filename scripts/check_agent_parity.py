#!/usr/bin/env python3
"""Verify the cross-platform agent-logic parity SUITE covers the same vectors on every platform.

The shared agent logic (decision parser, safety blocklist) is hand-ported across:
  - iOS     : apple/QuenderinKit/Tests/QuenderinKitTests/AgentParityTests.swift
  - Android : android/quenderin-core/src/verify/CoreVerify.kt  (the "parity:" checks)

8 of the 11 bugs in docs/audits/2026-06-26-cross-platform-correctness-audit.md were silent
Swift<->Kotlin divergences on identical input (regex \\b, JSON \\uXXXX, date roll-over, ...).
The two parity suites pin those contracts — but they were kept in lockstep BY HAND, so it was
possible to add a case to one platform and forget the other (exactly what happened: Kotlin pinned
the \\t/\\n short-escape decode; Swift did not). This script removes the "by hand": it is the same
guardrail as check_catalog_parity.py, applied to the parity SUITE instead of the model catalog.

The contract: every vector in shared/agent-parity-vectors.json has a stable `id`; each platform's
suite tags the matching assertion with a `parity:<id>` marker comment. This script asserts a
BIJECTION — every canonical id is covered on BOTH platforms, and neither platform has an orphan
marker that isn't in the canonical set. A drift (case added to one platform only, or a typo'd id)
fails CI.

What it does NOT check: that each assertion's EXPECTED value is correct — that's each platform's own
test asserting against the real parser/blocklist. This script guarantees COVERAGE parity; the suites
guarantee CORRECTNESS. Together: both platforms test the same inputs, and each verifies the right output.

Usage:  python3 scripts/check_agent_parity.py     # exit 0 = in sync, 1 = drift
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

CANONICAL = ROOT / "shared" / "agent-parity-vectors.json"
SUITES = {
    "iOS": ROOT / "apple" / "QuenderinKit" / "Tests" / "QuenderinKitTests" / "AgentParityTests.swift",
    "Android": ROOT / "android" / "quenderin-core" / "src" / "verify" / "CoreVerify.kt",
}

MARKER = re.compile(r"parity:([a-z0-9][a-z0-9-]*)")


def fail(msg: str) -> None:
    print(f"  ✗ {msg}")


def main() -> int:
    if not CANONICAL.exists():
        print(f"FAIL: canonical vectors missing: {CANONICAL.relative_to(ROOT)}")
        return 1

    doc = json.loads(CANONICAL.read_text(encoding="utf-8"))
    vectors = doc.get("vectors", [])
    canonical = [v["id"] for v in vectors]

    # Canonical ids must themselves be unique — a duplicate id would silently weaken the check.
    dupes = {i for i in canonical if canonical.count(i) > 1}
    if dupes:
        print(f"FAIL: duplicate ids in {CANONICAL.relative_to(ROOT)}: {sorted(dupes)}")
        return 1
    canonical_set = set(canonical)

    print(f"Canonical parity vectors: {len(canonical_set)}")
    ok = True
    for platform, path in SUITES.items():
        if not path.exists():
            print(f"FAIL: {platform} suite missing: {path.relative_to(ROOT)}")
            ok = False
            continue
        found = MARKER.findall(path.read_text(encoding="utf-8"))
        found_set = set(found)

        # A marker appearing twice in one suite is almost always a copy-paste mistake, not coverage.
        repeated = {m for m in found_set if found.count(m) > 1}
        missing = canonical_set - found_set       # canonical vector not tested on this platform
        orphan = found_set - canonical_set        # marker on this platform with no canonical vector

        if missing or orphan or repeated:
            ok = False
            print(f"\n{platform}  ({path.relative_to(ROOT)}) — DRIFT:")
            for m in sorted(missing):
                fail(f"missing coverage for canonical vector: {m}")
            for m in sorted(orphan):
                fail(f"orphan marker (no such canonical vector — typo?): {m}")
            for m in sorted(repeated):
                fail(f"duplicate marker in suite: {m}")
        else:
            print(f"{platform}: all {len(canonical_set)} vectors covered ✓")

    if ok:
        print("\nAgent parity suites are in sync across iOS + Android.")
        return 0
    print("\nAgent parity DRIFT — add the missing case (or fix the id) so both platforms cover every vector.")
    return 1


if __name__ == "__main__":
    sys.exit(main())

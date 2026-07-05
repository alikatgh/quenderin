#!/usr/bin/env python3
"""Verify the agent SAFETY BLOCKLIST is identical across all platforms.

The keywords an autonomous agent must never act on without explicit human confirmation are
canonical in shared/safety-blocklist.json and hand-ported into three consumers:
  - iOS/macOS : apple/QuenderinKit/Sources/QuenderinKit/SafetyBlocklist.swift
  - Android   : android/quenderin-core/src/main/kotlin/ai/quenderin/core/SafetyBlocklist.kt
  - Desktop   : src/services/agent/actionExecutor.ts  (ActionExecutor.BLOCKLIST)

The 2026-07-04 audit (Q-014) found the three lists had SILENTLY DRIFTED: the desktop list carried
7 keywords the mobile twins lacked (e.g. "place order", "revoke") and was missing 16 of theirs
(e.g. "cvv", "ssn", "seed phrase"). A safety list that differs per platform means an action blocked
on your phone can go through on the desktop — the exact class of silent divergence the parity system
exists to kill. This script is the same guardrail as check_catalog_parity.py, applied to the
blocklist: it asserts the SET of keywords is byte-for-byte equal across the canonical JSON and all
three ports. Match SEMANTICS differ by context on purpose (free-text word boundaries vs UI-element
tokenization) and are covered by each platform's own tests — this script guarantees the VOCABULARY
is one list.

Usage:  python3 scripts/check_safety_parity.py     # exit 0 = in sync, 1 = drift
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

CANONICAL = ROOT / "shared" / "safety-blocklist.json"
SWIFT = ROOT / "apple" / "QuenderinKit" / "Sources" / "QuenderinKit" / "SafetyBlocklist.swift"
KOTLIN = ROOT / "android" / "quenderin-core" / "src" / "main" / "kotlin" / "ai" / "quenderin" / "core" / "SafetyBlocklist.kt"
TS = ROOT / "src" / "services" / "capability" / "safety.ts"

# Pull the double-quoted / single-quoted string literals out of the FIRST array-literal block that
# follows the blocklist declaration in each source file. Anchored to the declaration name so a
# stray string array elsewhere in the file can't be mistaken for the list.
BLOCKS = {
    # `[^=]*` skips the `: [String]` type annotation (whose own `[` would trap a `[^\[]*` scan).
    "Swift": (SWIFT, r"blockedKeywords[^=]*=\s*\[(.*?)\]", r'"([^"]+)"'),
    "Kotlin": (KOTLIN, r"blockedKeywords[^(]*listOf\((.*?)\)", r'"([^"]+)"'),
    "Desktop": (TS, r"AGENT_BLOCKLIST\s*=\s*\[(.*?)\]", r"'([^']+)'"),
}


def canonical_keywords() -> set[str]:
    data = json.loads(CANONICAL.read_text(encoding="utf-8"))
    kws: set[str] = set()
    for group in data["categories"].values():
        kws.update(group)
    return kws


def extract(name: str) -> set[str] | None:
    path, block_re, item_re = BLOCKS[name]
    if not path.exists():
        print(f"  ✗ {name}: source not found at {path.relative_to(ROOT)}")
        return None
    src = path.read_text(encoding="utf-8")
    m = re.search(block_re, src, re.DOTALL)
    if not m:
        print(f"  ✗ {name}: could not locate the blocklist array in {path.name}")
        return None
    return set(re.findall(item_re, m.group(1)))


def main() -> int:
    if not CANONICAL.exists():
        print(f"✗ canonical list missing: {CANONICAL.relative_to(ROOT)}")
        return 1

    canonical = canonical_keywords()
    print(f"Safety-blocklist parity — canonical: shared/safety-blocklist.json ({len(canonical)} keywords)\n")

    ok = True
    for name in BLOCKS:
        found = extract(name)
        if found is None:
            ok = False
            continue
        missing = canonical - found
        extra = found - canonical
        if missing or extra:
            ok = False
            if missing:
                print(f"  ✗ {name}: MISSING {sorted(missing)}")
            if extra:
                print(f"  ✗ {name}: EXTRA (not in canonical) {sorted(extra)}")
        else:
            print(f"  ok   {name}: all {len(found)} keywords match")

    print()
    if ok:
        print("ALL PLATFORMS SHARE ONE SAFETY BLOCKLIST")
        return 0
    print("SAFETY BLOCKLIST HAS DRIFTED — reconcile against shared/safety-blocklist.json")
    return 1


if __name__ == "__main__":
    sys.exit(main())

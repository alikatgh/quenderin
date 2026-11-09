#!/usr/bin/env python3
"""The Turnstone adaptations use the same cases on desktop, Apple, and Android.

Each suite tags assertions with adapt:<id>. This script checks that the three
suites name the same ids, and that the shared sentences live in each
implementation.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SUITES = {
    "Desktop": ROOT / "tests" / "turnstone-adaptations.test.ts",
    "Apple": ROOT / "apple" / "QuenderinKit" / "Tests" / "QuenderinKitTests" / "TurnstoneAdaptationTests.swift",
    "Android": ROOT / "android" / "quenderin-core" / "src" / "main" / "kotlin" / "ai" / "quenderin" / "core" / "TurnstoneAdaptation.kt",
}
IMPLEMENTATIONS = [
    ROOT / "src" / "services" / "modelSelectionHold.ts",
    ROOT / "src" / "services" / "namedGuidance.ts",
    ROOT / "src" / "services" / "conversationWriter.ts",
    ROOT / "apple" / "QuenderinKit" / "Sources" / "QuenderinKit" / "ModelSelectionHold.swift",
    ROOT / "apple" / "QuenderinKit" / "Sources" / "QuenderinKit" / "NamedGuidance.swift",
    ROOT / "apple" / "QuenderinKit" / "Sources" / "QuenderinKit" / "ConversationWriter.swift",
    ROOT / "android" / "quenderin-core" / "src" / "main" / "kotlin" / "ai" / "quenderin" / "core" / "ModelSelectionHold.kt",
    ROOT / "android" / "quenderin-core" / "src" / "main" / "kotlin" / "ai" / "quenderin" / "core" / "NamedGuidance.kt",
    ROOT / "android" / "quenderin-core" / "src" / "main" / "kotlin" / "ai" / "quenderin" / "core" / "ConversationWriter.kt",
]
PHRASES = [
    "This choice stays selected and was not replaced.",
    "Experimental engine support. This selection is source integration, not tested inference, and it is not a store release.",
    "does not change the model or which tools can run",
    "already has a live reply",
]
MARKER = re.compile(r"adapt:([a-z0-9][a-z0-9-]*)")


def main() -> int:
    found = {}
    ok = True
    for name, path in SUITES.items():
        if not path.exists():
            print(f"FAIL: {name} suite missing: {path.relative_to(ROOT)}")
            ok = False
            continue
        ids = MARKER.findall(path.read_text(encoding="utf-8"))
        found[name] = ids
        if len(ids) != len(set(ids)):
            print(f"FAIL: {name} repeats an adapt id")
            ok = False
    if len(found) == 3:
        sets = {name: set(ids) for name, ids in found.items()}
        canonical = next(iter(sets.values()))
        for name, ids in sets.items():
            if ids != canonical:
                print(f"FAIL: {name} adapt ids differ: {sorted(ids ^ canonical)}")
                ok = False
        print(f"Shared adapt ids: {len(canonical)}")
    grouped = {
        "Desktop": IMPLEMENTATIONS[:3],
        "Apple": IMPLEMENTATIONS[3:6],
        "Android": IMPLEMENTATIONS[6:],
    }
    for name, paths in grouped.items():
        text = "\n".join(path.read_text(encoding="utf-8") for path in paths if path.exists())
        for phrase in PHRASES:
            if phrase not in text:
                print(f"FAIL: {name} is missing {phrase!r}")
                ok = False
    if not ok:
        return 1
    print("Turnstone adaptation parity: ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Verify the model catalog is identical across all three platforms.

The same 11 models are hand-maintained in three places:
  - desktop : src/constants.ts                                  (MODEL_CATALOG)
  - iOS     : apple/QuenderinKit/Sources/QuenderinKit/ModelCatalog.swift
  - Android : android/quenderin-core/src/main/kotlin/ai/quenderin/core/ModelCatalog.kt

Edit one and forget the others, and the platforms recommend DIFFERENT models for the
same hardware — silently breaking the cross-platform "download → ready" promise. This
script is the guardrail: it parses each catalog and asserts the set of ids and each
model's (paramsBillions, quantization) match. Run it in CI / before a release.

What it does NOT catch: label/filename/url/ramGB drift (those don't change the
recommendation), and the recommendation thresholds themselves (pinned by each
platform's own recommender tests). Catalog membership + params + quant is the invariant
that, together with those tests, guarantees consistent picks.

Usage:  python3 scripts/check_catalog_parity.py     # exit 0 = in sync, 1 = drift
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# The canonical, language-neutral manifest (generated from desktop by export_catalog.py).
# Every source catalog must match it; a stale manifest is itself a failure.
CANONICAL = ROOT / "shared" / "model-catalog.json"

SOURCES = {
    "desktop": ROOT / "src" / "constants.ts",
    "iOS": ROOT / "apple" / "QuenderinKit" / "Sources" / "QuenderinKit" / "ModelCatalog.swift",
    "Android": ROOT / "android" / "quenderin-core" / "src" / "main" / "kotlin" / "ai" / "quenderin" / "core" / "ModelCatalog.kt",
}

# Slice each file to the model-catalog block so the Quantization/HardwareTiers blocks
# (which also contain `id:` / `quantization:`) can't be mis-parsed as models.
MARKERS = {
    "desktop": "MODEL_CATALOG",
    "iOS": "let models",
    "Android": "val models",
}

# A model entry: id -> (paramsBillions: float, quantization: str)
Catalog = dict[str, tuple[float, str]]


def parse_named(text: str) -> Catalog:
    """desktop TS + iOS Swift: `id: "x" ... paramsBillions: N ... quantization: "Q"`."""
    catalog: Catalog = {}
    # Only look inside the model catalog (skip the HardwareTiers block, which also has
    # `quantization:` but no `id:`/`paramsBillions:` pairing).
    for m in re.finditer(
        r"""id:\s*['"]([\w.-]+)['"].*?paramsBillions:\s*([\d.]+).*?quantization:\s*['"]([\w_]+)['"]""",
        text,
        re.DOTALL,
    ):
        mid, params, quant = m.group(1), float(m.group(2)), m.group(3)
        catalog[mid] = (params, quant)
    return catalog


def parse_kotlin(text: str) -> Catalog:
    """Android Kotlin (positional): ModelEntry("id", "label", "file", ram, "size", params, "quant", "url")."""
    catalog: Catalog = {}
    for m in re.finditer(
        r"""ModelEntry\(\s*"([\w.-]+)"\s*,\s*"[^"]*"\s*,\s*"[^"]*"\s*,\s*[\d.]+\s*,\s*"[^"]*"\s*,\s*([\d.]+)\s*,\s*"([\w_]+)"\s*,""",
        text,
    ):
        mid, params, quant = m.group(1), float(m.group(2)), m.group(3)
        catalog[mid] = (params, quant)
    return catalog


def load(name: str, path: Path) -> Catalog:
    if not path.exists():
        sys.exit(f"FATAL: {name} catalog not found at {path}")
    text = path.read_text(encoding="utf-8")
    marker = MARKERS[name]
    idx = text.find(marker)
    if idx == -1:
        sys.exit(f"FATAL: '{marker}' not found in {name} ({path}) — parser may be stale")
    text = text[idx:]
    catalog = parse_kotlin(text) if name == "Android" else parse_named(text)
    if not catalog:
        sys.exit(f"FATAL: parsed 0 models from {name} ({path}) — parser may be stale")
    return catalog


def load_canonical() -> Catalog:
    if not CANONICAL.exists():
        sys.exit(f"FATAL: {CANONICAL} not found — run: python3 scripts/export_catalog.py")
    data = json.loads(CANONICAL.read_text(encoding="utf-8"))
    catalog = {m["id"]: (float(m["paramsBillions"]), m["quantization"]) for m in data.get("models", [])}
    if not catalog:
        sys.exit(f"FATAL: {CANONICAL} has no models")
    return catalog


def compare(name: str, catalog: Catalog, reference: Catalog) -> bool:
    missing = set(reference) - set(catalog)
    extra = set(catalog) - set(reference)
    mismatched = {
        mid: (reference[mid], catalog[mid])
        for mid in set(reference) & set(catalog)
        if reference[mid] != catalog[mid]
    }
    if not (missing or extra or mismatched):
        print(f"  ok   {name}: {len(catalog)} models match the manifest")
        return True
    print(f"  FAIL {name}:")
    for mid in sorted(missing):
        print(f"        missing '{mid}' (in manifest, not {name})")
    for mid in sorted(extra):
        print(f"        extra '{mid}' (in {name}, not the manifest)")
    for mid, (ref, got) in sorted(mismatched.items()):
        print(f"        '{mid}' params/quant differ: manifest={ref} {name}={got}")
    return False


def main() -> int:
    canonical = load_canonical()
    print(f"Catalog parity — canonical: shared/model-catalog.json ({len(canonical)} models)\n")
    ok = True
    for name, path in SOURCES.items():
        ok = compare(name, load(name, path), canonical) and ok

    print()
    if ok:
        print("ALL PLATFORMS MATCH THE CANONICAL MANIFEST")
        return 0
    print("CATALOG DRIFT — run `python3 scripts/export_catalog.py` if desktop changed, and/or sync the sources.")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())

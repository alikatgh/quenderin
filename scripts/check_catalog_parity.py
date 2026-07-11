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
from typing import Optional

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

# A model entry: id -> (paramsBillions: float, quantization: str, sha256: Optional[str])
Catalog = dict[str, tuple[float, str, Optional[str]]]


def parse_named(text: str) -> Catalog:
    """desktop TS + iOS Swift. Split at each `id:` so an absent (optional) sha256 can never
    borrow the NEXT entry's hash; extract each field per-block (no cross-entry DOTALL span)."""
    catalog: Catalog = {}
    starts = [m.start() for m in re.finditer(r"""id:\s*['"][\w.-]+['"]""", text)]
    starts.append(len(text))
    for i in range(len(starts) - 1):
        block = text[starts[i]:starts[i + 1]]
        idm = re.search(r"""id:\s*['"]([\w.-]+)['"]""", block)
        pm = re.search(r"""paramsBillions:\s*([\d.]+)""", block)
        # Hyphen is legal in quant ids ("UD-IQ3_XXS" — Unsloth dynamic quants).
        qm = re.search(r"""quantization:\s*['"]([\w_-]+)['"]""", block)
        if not (idm and pm and qm):
            continue  # a stray `id:` that isn't a model entry
        # Hex is case-insensitive; accept mixed/upper-case and normalize, so a hand-pasted
        # uppercase hash is never read as missing (which would mask drift / trip the integrity gate).
        sm = re.search(r"""sha256:\s*['"]([0-9a-fA-F]{64})['"]""", block)
        catalog[idm.group(1)] = (float(pm.group(1)), qm.group(1), sm.group(1).lower() if sm else None)
    return catalog


def parse_kotlin(text: str) -> Catalog:
    """Android Kotlin (positional). sha256 is the optional last arg (data-class default null)."""
    catalog: Catalog = {}
    for m in re.finditer(
        r"""ModelEntry\(\s*"([\w.-]+)"\s*,\s*"[^"]*"\s*,\s*"[^"]*"\s*,\s*[\d.]+\s*,\s*"[^"]*"\s*,\s*([\d.]+)\s*,\s*"([\w_-]+)"\s*,\s*"[^"]*"\s*(?:,\s*"([0-9a-fA-F]{64})")?(?:,\s*languagesLabel\s*=\s*"[^"]*")?\s*\)""",
        text,
    ):
        mid, params, quant = m.group(1), float(m.group(2)), m.group(3)
        # Normalize hex case so an uppercase Kotlin literal still matches the (lowercase) manifest.
        catalog[mid] = (params, quant, m.group(4).lower() if m.group(4) else None)
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
    catalog = {m["id"]: (float(m["paramsBillions"]), m["quantization"], (m.get("sha256") or "").lower() or None) for m in data.get("models", [])}
    if not catalog:
        sys.exit(f"FATAL: {CANONICAL} has no models")
    return catalog


def check_sha256_pinned(canonical: Catalog) -> bool:
    """Integrity gate (security audit HIGH). Every SHIPPED model must pin a sha256: when one is
    absent the runtime integrity check (desktop `modelIntegrity.ts`, Android `ModelDownloadEngine`,
    iOS) silently downgrades to a forgeable 4-byte 'GGUF' magic-only sniff — exactly the
    poisoned-mirror / TLS-MITM case the gate exists to stop. Fail the build here so the magic-only
    branch is only ever a corruption sniff, never the sole defense against a substituted file.
    Run `scripts/refresh_model_hashes.py` to pin a missing hash."""
    missing = sorted(mid for mid, (_p, _q, sha) in canonical.items() if not sha)
    if not missing:
        print(f"  ok   integrity: all {len(canonical)} models pin a sha256")
        return True
    print("  FAIL integrity: models missing a pinned sha256 (run scripts/refresh_model_hashes.py):")
    for mid in missing:
        print(f"        '{mid}' → integrity would fall back to a forgeable magic-only check")
    return False


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
    ok = check_sha256_pinned(canonical)
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

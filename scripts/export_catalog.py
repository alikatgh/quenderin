#!/usr/bin/env python3
"""Emit the canonical model manifest from the desktop catalog (the source of truth).

Writes `shared/model-catalog.json` — a versioned, language-neutral list of model modules
that iOS (`ModelManifest`) and Android can decode instead of hand-syncing three catalogs.
The desktop `src/constants.ts` MODEL_CATALOG is authoritative; run this whenever it
changes, and `scripts/check_catalog_parity.py` enforces that the JSON + all three source
catalogs agree.

Usage:  python3 scripts/export_catalog.py
"""
from __future__ import annotations

import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DESKTOP = ROOT / "src" / "constants.ts"
OUT = ROOT / "shared" / "model-catalog.json"

MANIFEST_VERSION = 1


def parse_desktop_models(text: str) -> list[dict]:
    # Slice to the MODEL_CATALOG array via bracket matching.
    start = text.index("MODEL_CATALOG")
    arr_start = text.index("[", start)
    depth = 0
    arr_end = -1
    for i in range(arr_start, len(text)):
        if text[i] == "[":
            depth += 1
        elif text[i] == "]":
            depth -= 1
            if depth == 0:
                arr_end = i
                break
    if arr_end == -1:
        raise SystemExit("FATAL: could not find the end of MODEL_CATALOG[]")
    block = text[arr_start : arr_end + 1]

    models: list[dict] = []
    for obj in re.finditer(r"\{[^{}]*\}", block):  # entries are flat objects
        entry = obj.group(0)

        def s(key: str) -> str:
            m = re.search(rf"{key}:\s*'([^']*)'", entry)
            if not m:
                raise SystemExit(f"FATAL: string field '{key}' missing from a catalog entry")
            return m.group(1)

        def n(key: str) -> float:
            m = re.search(rf"{key}:\s*([\d.]+)", entry)
            if not m:
                raise SystemExit(f"FATAL: numeric field '{key}' missing from a catalog entry")
            return float(m.group(1))

        def s_opt(key: str) -> str | None:
            m = re.search(rf"{key}:\s*'([^']*)'", entry)
            return m.group(1) if m else None

        models.append(
            {
                "id": s("id"),
                "label": s("label"),
                "filename": s("filename"),
                "ramGb": n("ramGb"),
                "sizeLabel": s("sizeLabel"),
                "paramsBillions": n("paramsBillions"),
                "quantization": s("quantization"),
                "url": s("url"),
                # A model may be added to constants.ts before refresh_model_hashes.py runs → emit
                # null rather than crashing mid-export. A null is NOT shippable: check_catalog_parity.py
                # (CI gate) fails the build on any missing sha256, so the runtime magic-only fallback
                # can never be the sole integrity defense for a cataloged model (security audit HIGH).
                "sha256": s_opt("sha256"),
                # Human-language support, honest about Russian (Russian-first user base).
                # Optional in the schema so sideloaded entries decode without it.
                "languages": s_opt("languages"),
            }
        )
    if not models:
        raise SystemExit("FATAL: parsed 0 models from the desktop catalog")
    return models


def main() -> int:
    models = parse_desktop_models(DESKTOP.read_text(encoding="utf-8"))
    manifest = {"version": MANIFEST_VERSION, "models": models}
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(f"Wrote {len(models)} models → {OUT.relative_to(ROOT)} (version {MANIFEST_VERSION})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

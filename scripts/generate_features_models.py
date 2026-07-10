#!/usr/bin/env python3
"""Regenerate the FEATURES.md model table from shared/model-catalog.json (no hand-syncing).

r7 H1: FEATURES.md described a 3-tier Llama-only catalog while MODEL_CATALOG shipped 11+
models — the table was hand-maintained and drifted the moment the catalog changed. This
script makes the doc a RENDERING of the canonical catalog: the table between the
BEGIN/END GENERATED markers is overwritten from shared/model-catalog.json (itself emitted
from src/constants.ts by export_catalog.py and parity-checked in CI).

Usage:  python3 scripts/generate_features_models.py            # rewrite FEATURES.md in place
        python3 scripts/generate_features_models.py --check    # exit 1 if FEATURES.md is stale (CI)
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CATALOG = ROOT / "shared" / "model-catalog.json"
FEATURES = ROOT / "FEATURES.md"

BEGIN = "<!-- BEGIN GENERATED: model-catalog (scripts/generate_features_models.py) -->"
END = "<!-- END GENERATED: model-catalog -->"


def fmt_params(billions: float) -> str:
    return f"{billions:g}B"


def fmt_ram(ram_gb: float) -> str:
    return f"~{ram_gb:g} GB"


def render_table(models: list[dict]) -> str:
    lines = [
        f"_{len(models)} models — generated from `shared/model-catalog.json`; "
        "edit `src/constants.ts` and run `npm run gen:features`, never this table._",
        "",
        "| ID | Label | Params | RAM footprint | Download | Quantization |",
        "|----|-------|--------|---------------|----------|--------------|",
    ]
    for m in models:
        lines.append(
            f"| `{m['id']}` | {m['label']} | {fmt_params(m['paramsBillions'])} "
            f"| {fmt_ram(m['ramGb'])} | {m['sizeLabel']} | `{m['quantization']}` |"
        )
    return "\n".join(lines)


def main() -> int:
    check = "--check" in sys.argv
    models = json.loads(CATALOG.read_text(encoding="utf-8"))["models"]
    text = FEATURES.read_text(encoding="utf-8")

    if BEGIN not in text or END not in text:
        print(f"FAIL: markers missing in {FEATURES.name} — expected '{BEGIN}' … '{END}'")
        return 1

    head, rest = text.split(BEGIN, 1)
    _, tail = rest.split(END, 1)
    new_text = head + BEGIN + "\n" + render_table(models) + "\n" + END + tail

    if new_text == text:
        print(f"{FEATURES.name}: model table up to date ({len(models)} models).")
        return 0
    if check:
        print(f"FAIL: {FEATURES.name} model table is stale — run `npm run gen:features`.")
        return 1
    FEATURES.write_text(new_text, encoding="utf-8")
    print(f"{FEATURES.name}: model table regenerated ({len(models)} models).")
    return 0


if __name__ == "__main__":
    sys.exit(main())

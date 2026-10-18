#!/usr/bin/env python3
"""Verify the model catalog is identical across all three platforms.

The same models are hand-maintained in three places:
  - desktop : src/constants.ts                                  (MODEL_CATALOG)
  - iOS     : apple/QuenderinKit/Sources/QuenderinKit/ModelCatalog.swift
  - Android : android/quenderin-core/src/main/kotlin/ai/quenderin/core/ModelCatalog.kt

Edit one and forget the others, and the platforms recommend DIFFERENT models for the
same hardware — silently breaking the cross-platform "download → ready" promise. This
script is the guardrail: catalog membership, parameters, quantization, SHA-256, RAM
estimate, filename, immutable artifact URL and exact download bytes must match.
Run it in CI / before a release.

Labels and recommendation thresholds are covered by each platform's own tests.

Usage:  python3 scripts/check_catalog_parity.py     # exit 0 = in sync, 1 = drift
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path
from typing import NamedTuple, Optional

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

class CatalogEntry(NamedTuple):
    params: float
    quantization: str
    sha256: Optional[str]
    ram_gb: float
    filename: str
    url: str
    download_bytes: Optional[int]


Catalog = dict[str, CatalogEntry]


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
        rm = re.search(r"""ramG[bB]:\s*([\d.]+)""", block)
        fm = re.search(r"""filename:\s*['"]([^'"]+)['"]""", block)
        um = re.search(r"""(?:url|urlString):\s*['"]([^'"]+)['"]""", block)
        bm = re.search(r"""downloadBytes:\s*([\d_]+)""", block)
        if not (rm and fm and um):
            raise ValueError(f"Incomplete artifact metadata for {idm.group(1)}")
        catalog[idm.group(1)] = CatalogEntry(
            float(pm.group(1)), qm.group(1), sm.group(1).lower() if sm else None,
            float(rm.group(1)), fm.group(1), um.group(1),
            int(bm.group(1).replace("_", "")) if bm else None,
        )
    return catalog


def parse_kotlin(text: str) -> Catalog:
    """Android Kotlin (positional). sha256 is the optional last arg (data-class default null)."""
    catalog: Catalog = {}
    for m in re.finditer(
        r"""ModelEntry\(\s*"([\w.-]+)"\s*,\s*"[^"]*"\s*,\s*"([^"]*)"\s*,\s*([\d.]+)\s*,\s*"[^"]*"\s*,\s*([\d.]+)\s*,\s*"([\w_-]+)"\s*,\s*"([^"]*)"\s*(?:,\s*"([0-9a-fA-F]{64})")?(?:,\s*languagesLabel\s*=\s*"[^"]*")?(?:,\s*downloadBytes\s*=\s*([\d_]+)L?)?(?:,\s*artifacts\s*=\s*MuseModelArtifacts\.parts)?\s*\)""",
        text,
    ):
        # Normalize hex case so an uppercase Kotlin literal still matches the (lowercase) manifest.
        catalog[m.group(1)] = CatalogEntry(
            float(m.group(4)), m.group(5), m.group(7).lower() if m.group(7) else None,
            float(m.group(3)), m.group(2), m.group(6),
            int(m.group(8).replace("_", "")) if m.group(8) else None,
        )
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
    catalog = {
        m["id"]: CatalogEntry(
            float(m["paramsBillions"]), m["quantization"], (m.get("sha256") or "").lower() or None,
            float(m["ramGb"]), m["filename"], m["url"], m.get("downloadBytes"),
        ) for m in data.get("models", [])
    }
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
    missing = sorted(mid for mid, entry in canonical.items() if not entry.sha256)
    if not missing:
        print(f"  ok   integrity: all {len(canonical)} models pin a sha256")
        return True
    print("  FAIL integrity: models missing a pinned sha256 (run scripts/refresh_model_hashes.py):")
    for mid in missing:
        print(f"        '{mid}' → integrity would fall back to a forgeable magic-only check")
    return False


def check_bonsai_artifacts(canonical: Catalog) -> bool:
    """Experimental Bonsai artifacts must keep an immutable revision and exact disk budget."""
    invalid = sorted(mid for mid, entry in canonical.items() if "bonsai" in mid.lower() and (
        not re.search(r"/resolve/[0-9a-f]{40}/" + re.escape(entry.filename) + r"(?:\?|$)", entry.url)
        or not isinstance(entry.download_bytes, int) or entry.download_bytes <= 0
    ))
    if invalid:
        print(f"  FAIL Bonsai artifact revision/byte count: {', '.join(invalid)}")
        return False
    print("  ok   Bonsai artifacts: immutable revisions and exact download bytes")
    return True


EXPERIMENTAL_TEXT_ARTIFACTS = {
    "minicpm-v47-1b": (
        "openbmb/MiniCPM-V-4.7-1B-gguf", "9684c734cfb2e6aaccb0bb52ba58afa9aae92d90",
        "MiniCPM-V-4_7-1B-Q4_K_M.gguf", 672003680, 2.0, "Q4_K_M",
    ),
    "minicpm-v47-35b-a3b": (
        "openbmb/MiniCPM-V-4.7-35B-A3B-gguf", "77ec40de8445999bf3076aeff9ff45d40a2713cc",
        "MiniCPM-V-4_7-35B-A3B-Q4_K_M.gguf", 21166255008, 25.0, "Q4_K_M",
    ),
    "lfm25-24b-a2b": (
        "LiquidAI/LFM2.5-24B-A2B-GGUF", "0912d33141f77e10705345a6732bfd83f0252fdc",
        "LFM2.5-24B-A2B-Q4_K_M.gguf", 14526258464, 18.0, "Q4_K_M",
    ),
    "jais3-0.9b": (
        "IFM/Jais-3-0.9B-GGUF", "ac7c7be976446226ca3da9c9986a678c879b2dce",
        "Jais-3-0.9B-Q4_K_M.gguf", 666192384, 2.0, "Q4_K_M",
    ),
    "jais3-3.7b": (
        "IFM/Jais-3-3.7B-GGUF", "653cc7bb723a5bb13dfa5a407b1fa035f3d0498b",
        "Jais-3-3.7B-Q4_K_M.gguf", 3156606176, 6.0, "Q4_K_M",
    ),
    "jais3-7b": (
        "IFM/Jais-3-7B-GGUF", "ed44d6f2e90f74c341c0291a07e06ae643d82190",
        "Jais-3-7B-Q4_K_M.gguf", 5592226016, 9.0, "Q4_K_M",
    ),
    "jais3-32b": (
        "IFM/Jais-3-32B-GGUF", "7f88bd89cbf83ccce89d07776ad11f7bd62cc83b",
        "Jais-3-32B-Q4_K_M.gguf", 21075786688, 28.0, "Q4_K_M",
    ),
    "jais3-mova-36b-a4b": (
        "IFM/Jais-3-MoVA-36B-A4B-GGUF", "8b2c5ab2feffeeca416c99ec972e543db6a97dbe",
        "Jais-3-MoVA-36B-A4B-Q4_K_M.gguf", 22368019936, 30.0, "Q4_K_M",
    ),
    "nemotron35-bolt-74b-a9b": (
        "nvidia/NVIDIA-Nemotron-3.5-Bolt-74B-A9B-24GB-GGUF", "e0fecb69cb3e5e4c5e8a056fa2aec98c78e91246",
        "NVIDIA-Nemotron-3.5-Bolt-74B-A9B-24GB.gguf", 22018326528, 28.0, "IQ2_XXS-mixed",
    ),
}


def check_experimental_text_artifacts(canonical: Catalog) -> bool:
    """These opt-in models retain the verified full artifact and conservative RAM floor.

    Pin the expected byte count independently of source-catalog parity: changing all
    catalogs together must not turn a projector/partial file into a complete model.
    """
    invalid = []
    for mid, (repository, revision, filename, download_bytes, ram_floor, quantization) in EXPERIMENTAL_TEXT_ARTIFACTS.items():
        entry = canonical.get(mid)
        expected_url = f"https://huggingface.co/{repository}/resolve/{revision}/{filename}"
        if (entry is None or entry.filename != filename or entry.download_bytes != download_bytes
                or entry.url not in (expected_url, expected_url + "?download=true")
                or entry.quantization != quantization or entry.ram_gb < ram_floor):
            invalid.append(mid)
    if invalid:
        print(f"  FAIL experimental text artifact identity/bytes/RAM: {', '.join(invalid)}")
        return False
    print("  ok   experimental text artifacts: pinned full weights, exact bytes and RAM floors")
    return True


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
        print(f"        '{mid}' metadata differs: manifest={ref} {name}={got}")
    return False


def check_muse_artifacts() -> bool:
    """Check every shard and its actual reference, not just the first-file identity."""
    import generate_muse_artifacts
    expected = json.loads((ROOT / "shared/muse-spark-artifacts.json").read_text())
    canonical = json.loads(CANONICAL.read_text())["models"]
    matches = [m for m in canonical if m["id"] == expected["modelId"]]
    try:
        assert len(matches) == 1 and matches[0].get("artifacts") == expected["artifacts"]
        for name, path in SOURCES.items():
            text = path.read_text().split('"muse-spark-open-q2-k"' if name != "desktop" else "'muse-spark-open-q2-k'", 1)[1]
            text = text.split("\n    {", 1)[0] if name == "desktop" else text.split("\n", 1)[0]
            assert ("artifacts: MUSE_SPARK_ARTIFACTS" if name == "desktop" else
                    "artifacts: MuseModelArtifacts.parts" if name == "iOS" else
                    "artifacts = MuseModelArtifacts.parts") in text
        for path, content in generate_muse_artifacts.outputs().items():
            assert path.read_text() == content
    except (AssertionError, IndexError, OSError) as error:
        print(f"  FAIL Muse artifact references/metadata: {error}")
        return False
    print("  ok   Muse artifacts: all 22 parts and native references match")
    return True


def main() -> int:
    canonical = load_canonical()
    print(f"Catalog parity — canonical: shared/model-catalog.json ({len(canonical)} models)\n")
    ok = (check_sha256_pinned(canonical) and check_bonsai_artifacts(canonical)
          and check_experimental_text_artifacts(canonical) and check_muse_artifacts())
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

#!/usr/bin/env python3
"""Inject/refresh per-model GGUF SHA-256 across the three source catalogs, and fix the
Q2_K mirror URL. Idempotent — re-running updates existing sha256 values in place.

Why: the model-download path (desktop `llm.service.ts`, iOS/Android downloaders) streamed
multi-GB GGUFs with no integrity check (audit finding C3). Verifying a catalog-pinned
SHA-256 after download closes the MITM / poisoned-mirror / truncated-file hole. The hashes
live in the catalog; this script keeps all three language copies in sync.

The hashes are the HuggingFace LFS object ids (the canonical SHA-256 of each file), fetched
WITHOUT downloading the multi-GB blobs — every GGUF on HF is git-lfs, so the pointer at
`<repo>/raw/main/<file>` carries `oid sha256:<hex>`:

    curl -fsSL "https://huggingface.co/<repo>/raw/main/<file>.gguf" | grep -oE 'sha256:[0-9a-f]{64}'

To add/rotate a model: drop its id->hash here, run this, then:
    python3 scripts/export_catalog.py        # regenerate shared/model-catalog.json
    python3 scripts/check_catalog_parity.py  # assert all three + the manifest agree

Usage:  python3 scripts/refresh_model_hashes.py
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# id -> GGUF SHA-256 (lowercase hex), from the HF LFS pointers (see module docstring).
HASHES = {
    "qwen3-14b": "500a8806e85ee9c83f3ae08420295592451379b4f8cf2d0f41c15dffeb6b81f0",
    "qwen25-coder-7b": "509287f78cb4d4cf6b3843734733b914b2c158e43e22a7f4bf5e963800894d3c",
    "deepseek-r1-7b": "731ece8d06dc7eda6f6572997feb9ee1258db0784827e642909d9b565641937b",
    "llama3-8b": "ab9e4eec7e80892fd78f74d9a15d0299f1e22121cea44efd68a7a02a3fe9a1da",
    "mistral-7b": "1270d22c0fbb3d092fb725d4d96c457b7b687a5f5a715abe1e818da303e562b6",
    "gemma4-12b": "1278394b693672ac2799eadc9a83fd98259a6a88a40acfb1dcaa6c6fc895a606",
    "gemma3-4b": "04a43a22e8d2003deda5acc262f68ec1005fa76c735a9962a8c77042a74a7d19",
    "qwen3-4b": "7485fe6f11af29433bc51cab58009521f205840f5b4ae3a32fa7f92e8534fdf5",
    "phi4-mini": "88c00229914083cd112853aab84ed51b87bdf6b9ce42f532d8c85c7c63b1730a",
    "llama32-3b": "e4f1a04d927b09ec18eb2f233d85ecd760fc2d35cec97e37f8604d3632210d9a",
    "llama32-1b": "f7ede42862ceca07ad1c88a97b67520019c4ac7e5ced250d2e696fa62ab189af",
    "llama32-1b-q2": "8b7091a92bc10d70392a91ebe06cd43e1f5048ae0162e88f8fbe8445447ceae8",
}

# lmstudio-community ships no Q2_K for Llama-3.2-1B (the pinned URL 404s) — repoint the
# ultra-light tier to unsloth, which actually publishes it.
URL_FIXES = {
    "llama32-1b-q2": (
        "https://huggingface.co/lmstudio-community/Llama-3.2-1B-Instruct-GGUF/resolve/main/Llama-3.2-1B-Instruct-Q2_K.gguf?download=true",
        "https://huggingface.co/unsloth/Llama-3.2-1B-Instruct-GGUF/resolve/main/Llama-3.2-1B-Instruct-Q2_K.gguf?download=true",
    ),
}

HEX64 = r'"[0-9a-f]{64}"'


def _fix_urls(text: str) -> str:
    for old, new in URL_FIXES.values():
        text = text.replace(old, new)
    return text


def _finish(path: Path, text: str, seen: set[str]) -> None:
    missing = set(HASHES) - seen
    if missing:
        sys.exit(f"FATAL: {path.name}: catalog entries not found for {sorted(missing)} — parser may be stale")
    path.write_text(text, encoding="utf-8")
    print(f"  ok  {path.relative_to(ROOT)}: {len(seen)} entries")


def patch_ts(path: Path) -> None:
    """desktop TS: object literals with `id: '...'` ... `url: '...',`."""
    text = _fix_urls(path.read_text(encoding="utf-8"))
    seen: set[str] = set()

    def repl(m: re.Match) -> str:
        block = m.group(0)
        idm = re.search(r"id:\s*'([\w.\-]+)'", block)
        if not idm or idm.group(1) not in HASHES:
            return block
        h = HASHES[idm.group(1)]
        seen.add(idm.group(1))
        if "sha256:" in block:
            return re.sub(r"sha256:\s*'[^']*'", f"sha256: '{h}'", block)
        return re.sub(r"(url:\s*'[^']*',\n)", lambda u: u.group(1) + f"        sha256: '{h}',\n", block, count=1)

    text = re.sub(r"\{[^{}]*\}", repl, text)  # flat object literals only
    _finish(path, text, seen)


def patch_swift(path: Path) -> None:
    """iOS Swift: multi-line `ModelEntry(id: "X" ... urlString: "Y")`. Insert sha256 right
    after the urlString field. Anchored on id..urlString (NOT on parens) because labels
    like "Qwen3 14B (Best Quality)" contain ')'."""
    text = _fix_urls(path.read_text(encoding="utf-8"))
    seen: set[str] = set()

    pattern = re.compile(
        r'(ModelEntry\(\s*id:\s*"([\w.\-]+)".*?urlString:\s*"[^"]*")'  # a catalog entry, up to urlString
        rf'(?:,\s*sha256:\s*{HEX64})?',                                # consume an existing sha256 (idempotent)
        re.DOTALL,
    )

    def repl(m: re.Match) -> str:
        head, mid = m.group(1), m.group(2)
        if mid not in HASHES:
            return m.group(0)
        seen.add(mid)
        return head + f',\n            sha256: "{HASHES[mid]}"'

    text = pattern.sub(repl, text)
    _finish(path, text, seen)


def patch_kotlin(path: Path) -> None:
    """Android Kotlin: one-line positional `ModelEntry("id", ..., "url"),`. Insert the hash
    before the constructor's closing paren, anchored at end-of-line so a ')' inside the
    label can't be mistaken for the constructor close."""
    text = _fix_urls(path.read_text(encoding="utf-8"))
    seen: set[str] = set()

    def patch_line(line: str) -> str:
        idm = re.search(r'ModelEntry\(\s*"([\w.\-]+)"', line)
        if not idm or idm.group(1) not in HASHES:
            return line
        seen.add(idm.group(1))
        line = re.sub(rf',\s*{HEX64}(\s*\))', r"\1", line)  # drop an existing hash arg (idempotent)
        return re.sub(r"\)(\s*,?\s*)$", f', "{HASHES[idm.group(1)]}")' + r"\1", line, count=1)

    text = "".join(patch_line(ln) for ln in text.splitlines(keepends=True))
    _finish(path, text, seen)


def main() -> int:
    print("Injecting GGUF sha256 + Q2_K URL fix into the three source catalogs…")
    patch_ts(ROOT / "src" / "constants.ts")
    patch_swift(ROOT / "apple" / "QuenderinKit" / "Sources" / "QuenderinKit" / "ModelCatalog.swift")
    patch_kotlin(ROOT / "android" / "quenderin-core" / "src" / "main" / "kotlin" / "ai" / "quenderin" / "core" / "ModelCatalog.kt")
    print("Done. Now run:  python3 scripts/export_catalog.py && python3 scripts/check_catalog_parity.py")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

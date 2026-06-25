#!/usr/bin/env python3
"""Catch model-catalog URL rot BEFORE users do — the "maintenance treadmill" gap.

Every model in `shared/model-catalog.json` carries a download `url` (a HuggingFace LFS link).
Those rot: a repo gets renamed, a quant is removed, `main` moves. We already hit one dead URL
(`llama32-1b-q2` 404'd when lmstudio-community dropped its Q2_K). A user only finds out when a
multi-GB download 404s mid-onboarding — the worst possible moment.

This does a cheap liveness check: a 1-byte Range GET per URL confirms the file exists and is served
WITHOUT downloading gigabytes. Run it before any release (and periodically):

    python3 scripts/check_catalog_urls.py        # exit 0 = all live, 1 = one or more dead

It is NOT a blocking CI gate (it needs network + depends on HF uptime, which would make CI flaky) —
it's a maintainer pre-release check. When something is dead, repoint it with
`scripts/refresh_model_hashes.py` (which also refreshes the pinned sha256).
"""
from __future__ import annotations

import json
import sys
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CATALOG = ROOT / "shared" / "model-catalog.json"
TIMEOUT_S = 30


def check_url(url: str) -> tuple[bool, object, str]:
    """A 1-byte Range GET: proves the large file is reachable + served, no multi-GB download.
    Returns (alive, status_or_error, size_info)."""
    req = urllib.request.Request(
        url,
        method="GET",
        headers={"Range": "bytes=0-0", "User-Agent": "quenderin-catalog-check"},
    )
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT_S) as resp:
            code = resp.status
            size = resp.headers.get("Content-Range") or resp.headers.get("Content-Length") or ""
            # 206 = Range honored (ideal); 200 = server ignored Range but the file is still live.
            return (code in (200, 206), code, size)
    except urllib.error.HTTPError as e:
        return (False, e.code, "")
    except Exception as e:  # noqa: BLE001 — any transport failure means "treat as dead, look at it"
        return (False, type(e).__name__ + ": " + str(e), "")


def main() -> int:
    if not CATALOG.exists():
        sys.exit(f"FATAL: {CATALOG} not found — run: python3 scripts/export_catalog.py")
    data = json.loads(CATALOG.read_text(encoding="utf-8"))
    models = data.get("models", data) if isinstance(data, dict) else data
    if not models:
        sys.exit(f"FATAL: {CATALOG} has no models")

    print(f"Catalog URL liveness — {len(models)} models in {CATALOG.relative_to(ROOT)}\n")
    dead: list[tuple[str, object]] = []
    for m in models:
        mid = m.get("id", "?")
        url = m.get("url")
        if not url:
            print(f"  SKIP {mid}: no url")
            continue
        alive, status, size = check_url(url)
        print(f"  {'ok  ' if alive else 'DEAD'} {mid}: {status} {size}".rstrip())
        if not alive:
            dead.append((mid, status))

    print()
    if dead:
        print(f"{len(dead)} catalog URL(s) DEAD — repoint via scripts/refresh_model_hashes.py before release:")
        for mid, status in dead:
            print(f"        {mid}: {status}")
        return 1
    print(f"ALL {len(models)} catalog URLs are live")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

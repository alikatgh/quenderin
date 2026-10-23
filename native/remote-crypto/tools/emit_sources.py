#!/usr/bin/env python3
"""Bounded source-only transfer through existing public CI logs, without artifacts."""
import base64
import gzip
import hashlib
from pathlib import Path
import sys

root = Path(sys.argv[1])
files = sorted(path for path in root.rglob("*") if path.is_file())
if not files or len(files) > 8 or sum(path.stat().st_size for path in files) > 1_048_576:
    raise SystemExit("Generated source count/byte limit exceeded or no bindings produced.")
for path in files:
    if path.suffix not in {".swift", ".kt", ".h", ".modulemap"} or path.is_symlink():
        raise SystemExit("Unexpected generated source file.")
    data = path.read_bytes()
    relative = path.relative_to(root).as_posix()
    print(f"BEGIN_QUENDERIN_GENERATED_SOURCE {relative} bytes={len(data)} sha256={hashlib.sha256(data).hexdigest()}")
    encoded = base64.b64encode(gzip.compress(data, mtime=0)).decode("ascii")
    for offset in range(0, len(encoded), 120):
        print(encoded[offset:offset + 120])
    print(f"END_QUENDERIN_GENERATED_SOURCE {relative}")

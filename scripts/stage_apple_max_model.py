"""Stage the canonical MAX C boundary into the SwiftPM C target.

The Swift package cannot reference files outside its package root. The staged
copies are byte-identical to `native/max-runtime`; this script is the receipt
and CI rejects drift. It never builds, downloads or executes anything.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import pathlib

ROOT = pathlib.Path(__file__).resolve().parents[1]
DEST = ROOT / "apple/QuenderinKit/Sources/CMaxModel"
SOURCES = {
    "quenderin_max.h": ROOT / "native/max-runtime/include/quenderin_max.h",
    "quenderin_max_model.h": ROOT / "native/max-runtime/include/quenderin_max_model.h",
    "quenderin_max_model.c": ROOT / "native/max-runtime/src/quenderin_max_model.c",
}
RECEIPT = ROOT / "apple/QuenderinKit/CMaxModelStaging.json"


def digest(path: pathlib.Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def record() -> dict:
    return {
        "schema": 1,
        "files": {
            name: {
                "source": str(source.relative_to(ROOT)),
                "bytes": source.stat().st_size,
                "sha256": digest(source),
            }
            for name, source in SOURCES.items()
        },
    }


def staged(name: str) -> pathlib.Path:
    return (DEST / "include" / name) if name.endswith(".h") else (DEST / name)


def write() -> None:
    (DEST / "include").mkdir(parents=True, exist_ok=True)
    for name, source in SOURCES.items():
        target = staged(name)
        target.write_bytes(source.read_bytes())
    RECEIPT.write_text(json.dumps(record(), indent=2, sort_keys=True) + "\n")


def check() -> None:
    if not RECEIPT.is_file():
        raise ValueError("Missing staged MAX receipt")
    receipt = json.loads(RECEIPT.read_text())
    expected = record()
    if receipt != expected:
        raise ValueError("Staged MAX receipt differs from the canonical source")
    for name, source in SOURCES.items():
        target = staged(name)
        if not target.is_file() or target.read_bytes() != source.read_bytes():
            raise ValueError(f"Staged MAX file differs from canonical source: {name}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--write", action="store_true")
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    if args.write == args.check:
        raise ValueError("Choose exactly one of --write or --check")
    if args.write:
        write()
    else:
        check()
    print(json.dumps({"staged": len(SOURCES), "check": not args.write, **record()}, sort_keys=True))


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Fail before compiling unless exact source pins and a complete lock are committed."""
from pathlib import Path
import sys
import tomllib

ROOT = Path(__file__).resolve().parents[1]
PINS = {
    "snow": ("https://github.com/mcginty/snow", "4bb43f50370bdb3e8b1b57814ac662864db2704f", "0.10.0"),
    "uniffi": ("https://github.com/mozilla/uniffi-rs", "7bc621ee9d0d15371d792612707ba5ed4111f950", "0.32.2"),
}


def validate_manifest(manifest: dict, toolchain: dict) -> None:
    if toolchain["toolchain"]["channel"] != "1.90.0":
        raise ValueError("Unexpected Rust toolchain.")
    for name, (repo, revision, _) in PINS.items():
        dependency = manifest["dependencies"][name]
        if dependency.get("git") != repo or dependency.get("rev") != revision or dependency.get("default-features") is not False:
            raise ValueError("A required dependency source pin changed.")
    snow_features = set(manifest["dependencies"]["snow"]["features"])
    if snow_features != {"std", "default-resolver", "use-curve25519", "use-chacha20poly1305", "use-sha2", "use-getrandom"}:
        raise ValueError("Unexpected Snow crypto feature surface.")
    if manifest.get("features", {}).get("default") != []:
        raise ValueError("Developer binding tools must not be enabled by default.")


def validate_lock(lock: dict) -> None:
    if lock.get("version") != 4 or not lock.get("package"):
        raise ValueError("A complete Cargo v4 lockfile is required.")
    packages = lock["package"]
    for name, (repo, revision, version) in PINS.items():
        matches = [package for package in packages if package["name"] == name]
        source = f"git+{repo}?rev={revision}#{revision}"
        if len(matches) != 1 or matches[0].get("version") != version or matches[0].get("source") != source:
            raise ValueError("Locked dependency differs from its reviewed source revision.")
    for package in packages:
        source = package.get("source", "")
        if source.startswith("registry+") and (source != "registry+https://github.com/rust-lang/crates.io-index" or len(package.get("checksum", "")) != 64):
            raise ValueError("A registry dependency lacks its immutable checksum.")
        if source.startswith("git+") and not any(source == f"git+{repo}?rev={revision}#{revision}" for repo, revision, _ in PINS.values()):
            raise ValueError("Unreviewed git dependency in lockfile.")


def require_locked(root: Path = ROOT) -> None:
    validate_manifest(tomllib.loads((root / "Cargo.toml").read_text()), tomllib.loads((root / "rust-toolchain.toml").read_text()))
    lock_path = root / "Cargo.lock"
    if not lock_path.is_file():
        raise ValueError("Cargo.lock is absent: metadata bootstrap is allowed; compilation and readiness are blocked.")
    validate_lock(tomllib.loads(lock_path.read_text()))


def main() -> int:
    try:
        if sys.argv[1:] == ["--manifest-only"]:
            validate_manifest(tomllib.loads((ROOT / "Cargo.toml").read_text()), tomllib.loads((ROOT / "rust-toolchain.toml").read_text()))
            print("Source pins verified; this is not a locked build/readiness result.")
        elif not sys.argv[1:]:
            require_locked()
            print("Lock source pins/checksum formats verified; cargo --locked must enforce complete resolution.")
        else:
            return 2
    except (OSError, KeyError, ValueError, tomllib.TOMLDecodeError) as error:
        print(str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

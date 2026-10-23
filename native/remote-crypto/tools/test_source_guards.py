import copy
from pathlib import Path
import tomllib
import unittest
from unittest.mock import patch

import fetch_fixture
import verify_build_gate as gate


class SourceGuards(unittest.TestCase):
    def test_missing_lock_blocks_the_action(self):
        with patch.object(Path, "is_file", return_value=False):
            reached_action = False
            with self.assertRaisesRegex(ValueError, "Cargo.lock is absent"):
                gate.require_locked()
                reached_action = True
            self.assertFalse(reached_action)

    def test_changed_source_pin_and_missing_registry_checksum_are_denied(self):
        manifest = tomllib.loads((gate.ROOT / "Cargo.toml").read_text())
        toolchain = tomllib.loads((gate.ROOT / "rust-toolchain.toml").read_text())
        gate.validate_manifest(manifest, toolchain)
        manifest["dependencies"]["snow"]["rev"] = "0" * 40
        with self.assertRaises(ValueError):
            gate.validate_manifest(manifest, toolchain)
        lock = {"version": 4, "package": [
            {"name": name, "version": version, "source": f"git+{repo}?rev={revision}#{revision}"}
            for name, (repo, revision, version) in gate.PINS.items()
        ]}
        gate.validate_lock(lock)
        corrupt = copy.deepcopy(lock)
        corrupt["package"].append({"name": "example", "version": "1.0.0", "source": "registry+https://github.com/rust-lang/crates.io-index"})
        with self.assertRaises(ValueError):
            gate.validate_lock(corrupt)
        corrupt = copy.deepcopy(lock)
        corrupt["package"][0]["source"] = corrupt["package"][0]["source"].replace(gate.PINS["snow"][1], "0" * 40)
        with self.assertRaises(ValueError):
            gate.validate_lock(corrupt)

    def test_changed_fixture_is_denied_without_printing_contents(self):
        with self.assertRaisesRegex(ValueError, "provenance"):
            fetch_fixture.verify(b"synthetic corruption")
        with self.assertRaisesRegex(ValueError, "provenance"):
            fetch_fixture.verify(b"0" * fetch_fixture.SIZE)


if __name__ == "__main__":
    unittest.main()

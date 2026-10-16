"""Exact addon patch and fail-closed preparation tests; no runtime downloads."""
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[1]
FIXTURES = Path(__file__).resolve().parent / "fixtures/node-llama-cpp-3.19.1"
SPEC = importlib.util.spec_from_file_location("prism_node_runtime", SCRIPTS / "prepare_prism_node_runtime.py")
prism_node = importlib.util.module_from_spec(SPEC)
sys.path.insert(0, str(SCRIPTS))
try:
    SPEC.loader.exec_module(prism_node)
finally:
    sys.path.pop(0)


class PrismNodeRuntimeTests(unittest.TestCase):
    def package(self, root: Path) -> Path:
        package = root / "node-llama-cpp"
        (package / "llama/addon").mkdir(parents=True)
        (package / "package.json").write_text(json.dumps({"name": "node-llama-cpp", "version": "3.19.1"}))
        for entry in prism_node.load_patch()["files"]:
            destination = package / entry["path"]
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes((FIXTURES / destination.name).read_bytes())
        return package

    def provenance(self) -> dict:
        return {"version": 1, "repository": prism_node.runtime.LOCK["repository"],
                "revision": prism_node.runtime.LOCK["revision"]}

    def fetch(self, path: Path) -> dict:
        path.mkdir()
        return self.provenance()

    def test_patch_applies_to_complete_official_addon_sources(self):
        with tempfile.TemporaryDirectory() as directory:
            package = self.package(Path(directory))
            plan = prism_node.patch_plan(package, prism_node.load_patch())
            self.assertEqual(len(plan), 4)
            model = plan[0][2].decode()
            self.assertNotIn("model_params.use_mmap", model)
            self.assertNotIn("model_params.use_direct_io", model)
            self.assertNotIn("model_params.use_mlock", model)
            self.assertIn("LLAMA_LOAD_MODE_MMAP_MLOCK", model)
            sampler = plan[1][2].decode()
            self.assertIn("llama_sampler_init_penalties(\n                llama_vocab_n_tokens(model->vocab),", sampler)
            self.assertIn("llama_sampler_init_dry(\n                model->vocab,\n                strength,", sampler)
            self.assertIn("quenderin-prism-node-runtime.json", plan[2][2].decode())
            self.assertEqual(json.loads(plan[3][2]), prism_node.source_info())
            for path, before, _after in plan:
                self.assertEqual(path.read_bytes(), before)

    def test_wrong_package_version_rejected_before_any_side_effect(self):
        with tempfile.TemporaryDirectory() as directory:
            package = self.package(Path(directory))
            (package / "package.json").write_text('{"name":"node-llama-cpp","version":"3.19.2"}')
            with patch.object(prism_node.runtime, "fetch") as fetch:
                with self.assertRaisesRegex(ValueError, "exact node-llama-cpp"):
                    prism_node.prepare(package)
                fetch.assert_not_called()
            self.assertFalse(prism_node.paths(package)[2].exists())

    def test_later_preimage_mismatch_leaves_every_addon_unchanged(self):
        with tempfile.TemporaryDirectory() as directory:
            package = self.package(Path(directory))
            model = package / "llama/addon/AddonModel.cpp"
            original = model.read_bytes()
            sampler = package / "llama/addon/AddonSampler.cpp"
            sampler.write_bytes(sampler.read_bytes() + b"// user edit\n")
            with patch.object(prism_node.runtime, "fetch") as fetch:
                with self.assertRaisesRegex(ValueError, "preimage"):
                    prism_node.prepare(package)
                fetch.assert_not_called()
            self.assertEqual(model.read_bytes(), original)
            self.assertTrue(sampler.read_bytes().endswith(b"// user edit\n"))
            self.assertFalse(prism_node.paths(package)[2].exists())

    def test_symlinked_source_file_is_rejected_without_overwriting_target(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            package = self.package(root)
            model = package / "llama/addon/AddonModel.cpp"
            original = model.read_bytes()
            # The target is new test-owned data; the helper must never write it.
            target = root / "outside-model.cpp"
            target.write_bytes(original)
            model.unlink()
            model.symlink_to(target)
            with patch.object(prism_node.runtime, "fetch") as fetch:
                with self.assertRaisesRegex(ValueError, "ordinary addon source"):
                    prism_node.prepare(package)
                fetch.assert_not_called()
            self.assertEqual(target.read_bytes(), original)

    def test_existing_runtime_and_backups_are_preserved(self):
        for index in (0, 2):
            with self.subTest(path_index=index), tempfile.TemporaryDirectory() as directory:
                package = self.package(Path(directory))
                existing = prism_node.paths(package)[index]
                existing.mkdir()
                marker = existing / "user-content"
                marker.write_text("preserve me")
                with patch.object(prism_node.runtime, "fetch") as fetch:
                    with self.assertRaisesRegex(ValueError, "Existing path is preserved"):
                        prism_node.prepare(package)
                    fetch.assert_not_called()
                self.assertEqual(marker.read_text(), "preserve me")

    def test_official_fresh_install_metadata_is_accepted_and_preserved(self):
        with tempfile.TemporaryDirectory() as directory:
            package = self.package(Path(directory))
            _source, info, backup, _stamp = prism_node.paths(package)
            official = (FIXTURES / "llama.cpp.info.json").read_bytes()
            self.assertEqual(info.read_bytes(), official)
            with patch.object(prism_node.runtime, "fetch", side_effect=self.fetch), \
                    patch.object(prism_node.runtime, "verify", side_effect=lambda source: self.provenance()):
                prism_node.prepare(package)
            self.assertEqual((backup / info.name).read_bytes(), official)
            self.assertEqual(json.loads(info.read_text()), prism_node.source_info())

    def test_changed_metadata_is_preserved_without_any_partial_edits(self):
        for changed in (b'{"tag":"user-custom","llamaCppGithubRepo":"user/llama.cpp"}\n',
                        b'{"tag":"b10068","llamaCppGithubRepo":"ggml-org/llama.cpp"}\n'):
            with self.subTest(metadata=changed), tempfile.TemporaryDirectory() as directory:
                package = self.package(Path(directory))
                source, info, backup, _stamp = prism_node.paths(package)
                info.write_bytes(changed)
                before = {str(p): p.read_bytes() for p in package.rglob("*") if p.is_file()}
                with patch.object(prism_node.runtime, "fetch") as fetch:
                    with self.assertRaisesRegex(ValueError, "preimage"):
                        prism_node.prepare(package)
                    fetch.assert_not_called()
                self.assertEqual(before, {str(p): p.read_bytes() for p in package.rglob("*") if p.is_file()})
                self.assertFalse(source.exists())
                self.assertFalse(backup.exists())

    def test_prepare_preserves_originals_and_repeat_only_verifies(self):
        with tempfile.TemporaryDirectory() as directory:
            package = self.package(Path(directory))
            with patch.object(prism_node.runtime, "fetch", side_effect=self.fetch) as fetch, \
                    patch.object(prism_node.runtime, "verify", side_effect=lambda source: self.provenance()):
                first = prism_node.prepare(package)
                snapshot = {str(p): p.read_bytes() for p in package.rglob("*") if p.is_file()}
                self.assertEqual(prism_node.prepare(package), first)
                fetch.assert_called_once()
                self.assertEqual(snapshot, {str(p): p.read_bytes() for p in package.rglob("*") if p.is_file()})
                source, info, backup, _stamp = prism_node.paths(package)
                self.assertTrue(source.is_dir())
                self.assertEqual(json.loads(info.read_text()), {
                    "tag": prism_node.runtime.LOCK["revision"], "llamaCppGithubRepo": "PrismML-Eng/llama.cpp"})
                for name in ("AddonModel.cpp", "AddonSampler.cpp", "cloneLlamaCppRepo.js", "llama.cpp.info.json"):
                    self.assertEqual((backup / name).read_bytes(), (FIXTURES / name).read_bytes())
                changed = package / "llama/addon/AddonSampler.cpp"
                changed.write_bytes(changed.read_bytes() + b"// later user edit\n")
                with self.assertRaisesRegex(ValueError, "has changed"):
                    prism_node.prepare(package)
                self.assertTrue(changed.read_bytes().endswith(b"// later user edit\n"))

    def test_damaged_metadata_cannot_relabel_an_existing_build(self):
        with tempfile.TemporaryDirectory() as directory:
            package = self.package(Path(directory))
            with patch.object(prism_node.runtime, "fetch", side_effect=self.fetch), \
                    patch.object(prism_node.runtime, "verify", side_effect=lambda source: self.provenance()):
                prism_node.prepare(package)
                info = prism_node.paths(package)[1]
                info.write_text('{"tag":"stock","llamaCppGithubRepo":"ggml-org/llama.cpp"}')
                with self.assertRaisesRegex(ValueError, "metadata does not match"):
                    prism_node.verify(package)


if __name__ == "__main__":
    unittest.main()

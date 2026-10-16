"""Failure tests for exact source patch provenance; no downloads or runtime builds."""
import copy
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("prism_runtime", Path(__file__).resolve().parents[1] / "prepare_prism_runtime.py")
prism = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(prism)


class PrismRuntimeTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(prefix="prism-source-test-")
        self.addCleanup(self.scratch.cleanup)
        self.project = Path(self.scratch.name) / "project"
        self.root = Path(self.scratch.name) / "source"
        (self.project / "scripts/patches").mkdir(parents=True)
        (self.root / "ggml/include").mkdir(parents=True)
        (self.root / "src/models").mkdir(parents=True)
        self.before = 'get_key("prism.hadamard.version")\nold\n'
        self.after = self.before.replace("old", "new")
        self.new = "synthetic Muse source\n"
        self.lock = copy.deepcopy(prism.LOCK)
        self.manifest = {
            "version": 1, "id": self.lock["sourcePatch"]["id"],
            "baseRepository": self.lock["repository"], "baseRevision": self.lock["revision"],
            "upstreamRevision": self.lock["sourcePatch"]["upstreamRevision"],
            "museSparkABI": 1, "capabilitySymbol": "quenderin_muse_spark_runtime_abi",
            "files": [
                {"path": "src/llama-model.cpp", "beforeSha256": prism.digest(self.before.encode()),
                 "afterSha256": prism.digest(self.after.encode()),
                 "replacements": [{"before": "old\n", "after": "new\n"}]},
                {"path": "src/models/muse-spark.cpp", "beforeSha256": None,
                 "afterSha256": prism.digest(self.new.encode()), "content": self.new},
            ],
        }
        self.save_manifest()
        (self.root / "ggml/include/ggml.h").write_text("GGML_TYPE_PTQ1_0 GGML_TYPE_PQ2_0")
        (self.root / "src/llama-model.cpp").write_text(self.before)
        for name, value in (("ROOT", self.project), ("LOCK", self.lock)):
            p = patch.object(prism, name, value)
            p.start()
            self.addCleanup(p.stop)
        p = patch.object(prism, "git", side_effect=self.git)
        self.real_git = prism.git
        p.start()
        self.addCleanup(p.stop)

    def save_manifest(self):
        path = self.project / self.lock["sourcePatch"]["path"]
        data = (json.dumps(self.manifest) + "\n").encode()
        path.write_bytes(data)
        self.lock["sourcePatch"]["sha256"] = prism.digest(data)

    def git(self, source, *args):
        if args[0] == "rev-parse":
            return self.lock["revision"]
        if args[0] == "config":
            return self.lock["repository"]
        if args[0] == "status":
            return (" M src/llama-model.cpp\n?? src/models/muse-spark.cpp"
                    if (source / "src/models/muse-spark.cpp").exists() else "")
        raise AssertionError(args)

    def ready(self):
        return prism.apply_source_patch(self.root)

    def test_patch_is_exact_and_idempotent_and_old_base_is_not_supported(self):
        with self.assertRaisesRegex(ValueError, "missing or modified"):
            prism.verify(self.root)
        identity = self.ready()
        self.assertEqual(identity["sourcePatchSha256"], self.lock["sourcePatch"]["sha256"])
        self.assertEqual(identity["museSparkABI"], 1)
        self.assertEqual((self.root / "src/llama-model.cpp").read_text(), self.after)
        self.assertEqual(prism.apply_source_patch(self.root), identity)
        self.assertEqual(prism.verify(self.root), identity)

    def test_wrong_revision_origin_and_unknown_source_changes_rejected(self):
        self.ready()
        for field, value in (("rev-parse", "wrong"), ("config", "wrong"),
                             ("status", "?? src/models/injected.cpp"),
                             ("status", "M  src/llama-model.cpp")):
            with self.subTest(field=field, value=value):
                def git(source, *args):
                    return value if args[0] == field else self.git(source, *args)
                with patch.object(prism, "git", side_effect=git), self.assertRaises(ValueError):
                    prism.verify(self.root)

    def test_output_tamper_and_missing_file_fail_with_same_base_revision(self):
        self.ready()
        source = self.root / "src/models/muse-spark.cpp"
        source.write_text("tampered")
        with self.assertRaisesRegex(ValueError, "missing or modified"):
            prism.verify(self.root)
        source.unlink()
        with self.assertRaisesRegex(ValueError, "missing or modified"):
            prism.verify(self.root)

    def test_missing_ternary_or_hadamard_is_not_a_capability(self):
        self.ready()
        (self.root / "ggml/include/ggml.h").write_text("stock types")
        with self.assertRaisesRegex(ValueError, "Hadamard"):
            prism.verify(self.root)

    def test_manifest_digest_and_identity_are_bound(self):
        path = self.project / self.lock["sourcePatch"]["path"]
        path.write_text(path.read_text() + " ")
        with self.assertRaisesRegex(ValueError, "digest"):
            prism.apply_source_patch(self.root)
        self.manifest["museSparkABI"] = 2
        self.save_manifest()
        with self.assertRaisesRegex(ValueError, "identity"):
            prism.apply_source_patch(self.root)
        self.assertEqual((self.root / "src/llama-model.cpp").read_text(), self.before)

    def test_all_outputs_validated_before_any_write(self):
        self.manifest["files"][1]["content"] = "invalid output"
        self.save_manifest()
        with self.assertRaisesRegex(ValueError, "output digest"):
            prism.apply_source_patch(self.root)
        self.assertEqual((self.root / "src/llama-model.cpp").read_text(), self.before)
        self.assertFalse((self.root / "src/models/muse-spark.cpp").exists())

    def test_preimage_mismatch_preserves_existing_user_changes(self):
        source = self.root / "src/llama-model.cpp"
        source.write_text("user source")
        with self.assertRaisesRegex(ValueError, "preimage differs"):
            prism.apply_source_patch(self.root)
        self.assertEqual(source.read_text(), "user source")

    def test_traversal_duplicate_and_symlink_are_rejected_before_writes(self):
        original = copy.deepcopy(self.manifest)
        for name in ("../outside.cpp", "/tmp/outside.cpp", "src/../outside.cpp"):
            self.manifest = copy.deepcopy(original)
            self.manifest["files"][1]["path"] = name
            self.save_manifest()
            with self.assertRaisesRegex(ValueError, "path"):
                prism.apply_source_patch(self.root)
        self.manifest = copy.deepcopy(original)
        self.manifest["files"].append(copy.deepcopy(self.manifest["files"][0]))
        self.save_manifest()
        with self.assertRaisesRegex(ValueError, "duplicated"):
            prism.apply_source_patch(self.root)
        self.manifest = original
        self.save_manifest()
        outside = self.project / "user-source.cpp"
        outside.write_text(self.before)
        source = self.root / "src/llama-model.cpp"
        source.unlink()
        source.symlink_to(outside)
        with self.assertRaisesRegex(ValueError, "escapes"):
            prism.apply_source_patch(self.root)
        self.assertEqual(outside.read_text(), self.before)

    def test_declared_origin_survives_transport_rewrite(self):
        with patch.dict(os.environ, {"GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_COUNT": "0"}):
            subprocess.run(["git", "init", "--quiet", str(self.root)], check=True, capture_output=True)
            self.real_git(self.root, "config", "--local", "remote.origin.url", self.lock["repository"])
            self.real_git(self.root, "config", "--local", "url.http://cloud-mirror.invalid/github/.insteadOf", "https://github.com/")
            self.assertIn("cloud-mirror", self.real_git(self.root, "remote", "get-url", "origin"))

            def transport_git(source, *args):
                return self.real_git(source, *args) if args[0] == "config" else self.git(source, *args)
            with patch.object(prism, "git", side_effect=transport_git):
                self.ready()
                self.real_git(self.root, "config", "--local", "remote.origin.url", "https://untrusted.invalid/runtime.git")
                with self.assertRaisesRegex(ValueError, "origin"):
                    prism.verify(self.root)

    def test_fetch_preserves_existing_path(self):
        original = self.root / "user-file"
        original.write_text("preserve me")
        with patch.object(prism.subprocess, "run") as run, self.assertRaisesRegex(ValueError, "already exists"):
            prism.fetch(self.root)
        run.assert_not_called()
        self.assertEqual(original.read_text(), "preserve me")

    def test_stamp_requires_muse_header_in_every_slice_and_binds_identity(self):
        identity = self.ready()
        artifact = self.project / "new.xcframework"
        headers = artifact / "macos/llama.framework/Headers"
        headers.mkdir(parents=True)
        (headers / "ggml.h").write_text("GGML_TYPE_PTQ1_0 GGML_TYPE_PQ2_0")
        with self.assertRaisesRegex(ValueError, "Muse capability"):
            prism.stamp(self.root, artifact)
        self.assertFalse((artifact / prism.STAMP).exists())
        (headers / "llama.h").write_text("int quenderin_muse_spark_runtime_abi(void);")
        self.assertEqual(prism.stamp(self.root, artifact), identity)
        self.assertEqual(json.loads((artifact / prism.STAMP).read_text()), identity)


if __name__ == "__main__":
    unittest.main()

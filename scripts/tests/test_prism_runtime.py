"""Small failure tests for source provenance; never fetches or builds a runtime."""
import importlib.util
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
    def source(self, root):
        (root / "ggml/include").mkdir(parents=True)
        (root / "src").mkdir()
        (root / "ggml/include/ggml.h").write_text("GGML_TYPE_PTQ1_0 GGML_TYPE_PQ2_0")
        (root / "src/llama-model.cpp").write_text('get_key("prism.hadamard.version")')

    def git(self, source, *args):
        return {"rev-parse": prism.LOCK["revision"], "status": "", "config": prism.LOCK["repository"]}[args[0]]

    def test_exact_pin_and_source_features_required(self):
        with tempfile.TemporaryDirectory() as path:
            root = Path(path)
            self.source(root)
            with patch.object(prism, "git", side_effect=self.git):
                self.assertEqual(prism.verify(root)["revision"], prism.LOCK["revision"])
                (root / "src/llama-model.cpp").write_text("stock loader")
                with self.assertRaisesRegex(ValueError, "Hadamard"):
                    prism.verify(root)

    def test_wrong_revision_and_dirty_source_rejected(self):
        for bad_field in ("rev-parse", "status", "config"):
            def git(source, *args):
                return "wrong" if args[0] == bad_field else self.git(source, *args)
            with patch.object(prism, "git", side_effect=git):
                with self.assertRaises(ValueError):
                    prism.verify(Path("/unused"))

    def rewritten_origin(self, root, declared, replacement, prefix):
        self.source(root)
        subprocess.run(["git", "init", "--quiet", str(root)], check=True, capture_output=True)
        prism.git(root, "config", "--local", "remote.origin.url", declared)
        prism.git(root, "config", "--local", f"url.{replacement}.insteadOf", prefix)
        actual_git = prism.git

        def pinned_head(source, *args):
            # The fixture has no real Prism commit; every origin/config/status
            # query uses Git itself, and the existing test covers commit mismatch.
            if args == ("rev-parse", "HEAD"):
                return prism.LOCK["revision"]
            return actual_git(source, *args)

        return pinned_head

    def test_declared_origin_survives_git_transport_rewrite(self):
        with tempfile.TemporaryDirectory() as path, patch.dict(os.environ, {"GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_COUNT": "0"}):
            root = Path(path)
            pinned_head = self.rewritten_origin(root, prism.LOCK["repository"], "http://cloud-mirror.invalid/github/", "https://github.com/")
            self.assertEqual(prism.git(root, "remote", "get-url", "origin"), "http://cloud-mirror.invalid/github/PrismML-Eng/llama.cpp.git")
            with patch.object(prism, "git", side_effect=pinned_head):
                self.assertEqual(prism.verify(root)["revision"], prism.LOCK["revision"])

    def test_wrong_declared_origin_cannot_be_hidden_by_git_transport_rewrite(self):
        with tempfile.TemporaryDirectory() as path, patch.dict(os.environ, {"GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_COUNT": "0"}):
            root = Path(path)
            wrong = "https://untrusted.invalid/llama.cpp.git"
            pinned_head = self.rewritten_origin(root, wrong, prism.LOCK["repository"], wrong)
            self.assertEqual(prism.git(root, "remote", "get-url", "origin"), prism.LOCK["repository"])
            with patch.object(prism, "git", side_effect=pinned_head):
                with self.assertRaisesRegex(ValueError, "origin"):
                    prism.verify(root)

    def test_fetch_does_not_replace_existing_user_path(self):
        with tempfile.TemporaryDirectory() as path:
            original = Path(path) / "user-file"
            original.write_text("preserve me")
            with patch.object(prism.subprocess, "run") as run:
                with self.assertRaisesRegex(ValueError, "already exists"):
                    prism.fetch(Path(path))
                run.assert_not_called()
            self.assertEqual(original.read_text(), "preserve me")

    def test_stamp_requires_prism_headers_in_every_slice(self):
        with tempfile.TemporaryDirectory() as path:
            root = Path(path)
            artifact = root / "new.xcframework"
            headers = artifact / "macos/llama.framework/Headers"
            headers.mkdir(parents=True)
            (headers / "ggml.h").write_text("stock types")
            with patch.object(prism, "verify", return_value={"revision": prism.LOCK["revision"]}):
                with self.assertRaisesRegex(ValueError, "Every framework slice"):
                    prism.stamp(root, artifact)
            self.assertFalse((artifact / prism.STAMP).exists())


if __name__ == "__main__":
    unittest.main()

import contextlib
import importlib.util
import io
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]


def module(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / "scripts" / f"{name}.py")
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


class PerformanceEvidenceTests(unittest.TestCase):
    def test_real_inventory(self):
        check = module("check_inference_performance")
        names = check.fixture_names(ROOT / "shared/inference-performance-fixtures.json")
        self.assertEqual(len(names), 24)
        check.validate_results("\n".join(f"INFERENCE_PERFORMANCE_FIXTURE_PASS {name}" for name in names), names)

    def test_missing_duplicate_unknown_and_split_markers_fail(self):
        check = module("check_inference_performance")
        for output in ("", "INFERENCE_PERFORMANCE_FIXTURE_PASS a\n" * 2,
                       "INFERENCE_PERFORMANCE_FIXTURE_PASS unknown\n",
                       "INFERENCE_PERFORMANCE_FIXTURE_\nPASS a\n"):
            with self.assertRaises(ValueError):
                check.validate_results(output, ["a"])

    def test_runtime_changes_invalidate_identity_and_reject_stale_generated_files(self):
        generator = module("generate_inference_performance_identity")
        with tempfile.TemporaryDirectory(prefix="quenderin-performance-contract-") as directory:
            root = Path(directory)
            # Only synthetic source data; no SDK, models, credentials or user files.
            for relative in generator.source_paths(root):
                (root / relative).parent.mkdir(parents=True, exist_ok=True)
                (root / relative).write_text("synthetic-source\n")
            identity = generator.fingerprint(root)
            for relative, text in generator.outputs(identity).items():
                (root / relative).write_text(text)
            with patch.object(generator, "ROOT", root), contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(generator.main(["--check"]), 0)
                (root / "shared/prism-runtime.json").write_text("changed-runtime\n")
                self.assertNotEqual(generator.fingerprint(root), identity)
                self.assertEqual(generator.main(["--check"]), 1)
                self.assertEqual(generator.main([]), 0)
                self.assertEqual(generator.main(["--check"]), 0)
                (root / "android/jni/new_backend.h").write_text("changed-native-closure\n")
                self.assertNotEqual(generator.fingerprint(root), identity)
                self.assertEqual(generator.main(["--check"]), 1)


if __name__ == "__main__":
    unittest.main()

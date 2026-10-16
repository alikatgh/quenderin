"""Model-free regression checks for artifact and RAM parity across source catalogs."""
import contextlib
import importlib.util
import io
from pathlib import Path
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "check_catalog_parity.py"
SPEC = importlib.util.spec_from_file_location("catalog_parity", SCRIPT)
parity = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(parity)


class CatalogParityTests(unittest.TestCase):
    def setUp(self):
        self.sha = "a" * 64
        self.url = f"https://huggingface.co/prism-ml/model/resolve/{'b' * 40}/small.gguf?download=true"
        self.entry = parity.CatalogEntry(1.88, "PTQ1_0", self.sha, 1.5, "small.gguf", self.url, 429183456)

    def test_named_and_kotlin_parsers_keep_artifact_identity_and_memory(self):
        named = f'''id: 'bonsai2-2b', filename: 'small.gguf', ramGb: 1.5,
            paramsBillions: 1.88, quantization: 'PTQ1_0', sha256: '{self.sha}',
            url: '{self.url}', downloadBytes: 429_183_456'''
        swift = named.replace("ramGb", "ramGB").replace("url:", "urlString:")
        kotlin = f'''ModelEntry("bonsai2-2b", "Experimental", "small.gguf", 1.5, "0.43 GB",
            1.88, "PTQ1_0", "{self.url}", "{self.sha}", languagesLabel = "See model card",
            downloadBytes = 429_183_456L)'''
        for parsed in (parity.parse_named(named), parity.parse_named(swift), parity.parse_kotlin(kotlin)):
            self.assertEqual(parsed, {"bonsai2-2b": self.entry})

    def test_any_artifact_or_memory_drift_fails_comparison(self):
        canonical = {"bonsai2-2b": self.entry}
        for change in (
            {"ram_gb": 0.1}, {"filename": "other.gguf"}, {"url": self.url.replace("resolve/", "resolve/main/")},
            {"download_bytes": None}, {"download_bytes": 1}, {"sha256": "c" * 64},
        ):
            with self.subTest(change=change), contextlib.redirect_stdout(io.StringIO()):
                self.assertFalse(parity.compare("test", {"bonsai2-2b": self.entry._replace(**change)}, canonical))

    def test_bonsai_requires_immutable_revision_and_exact_bytes(self):
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertTrue(parity.check_bonsai_artifacts({"bonsai2-2b": self.entry}))
            for change in (
                {"url": self.url.replace("b" * 40, "main")}, {"download_bytes": None},
                {"download_bytes": 0}, {"filename": "mismatched.gguf"},
            ):
                self.assertFalse(parity.check_bonsai_artifacts({"bonsai2-2b": self.entry._replace(**change)}))


if __name__ == "__main__":
    unittest.main()

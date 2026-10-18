"""Small platform-independent fixtures for Windows DLL export inspection."""
import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location("prepare_diffusion", ROOT / "scripts/prepare_diffusion_runtime.py")
prepare = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prepare)


class WindowsExports(unittest.TestCase):
    def dumpbin(self, names):
        return "Dump of file image.dll\n  ordinal hint RVA      name\n" + "\n".join(
            f" {i:5d} {i-1:4X} 0000{i:04X} {name}" for i, name in enumerate(sorted(names), 1)) + "\n  Summary\n"

    def test_dumpbin_exact_allowlist(self):
        output = self.dumpbin(prepare.EXPORTS)
        self.assertEqual(prepare.windows_exports(output, "dumpbin"), prepare.EXPORTS)
        with patch.object(prepare.shutil, "which", side_effect=lambda tool: "dumpbin.exe" if tool == "dumpbin" else None), patch.object(prepare.subprocess, "check_output", return_value=output):
            self.assertTrue(prepare.verify_library(Path("image.dll"), "windows")["isolated"])

    def test_extra_ggml_export_is_rejected(self):
        with patch.object(prepare.shutil, "which", return_value="dumpbin.exe"), patch.object(prepare.subprocess, "check_output", return_value=self.dumpbin(prepare.EXPORTS | {"ggml_init"})):
            with self.assertRaisesRegex(ValueError, "unexpected=.*ggml_init"):
                prepare.verify_library(Path("image.dll"), "windows")

    def test_llvm_coff_exports_and_unnamed_entries(self):
        output = 'File: image.dll\nFormat: COFF-x86-64\n' + "\n".join(
            f"Export {{\n  Ordinal: {i}\n  Name: {name}\n  RVA: 0x1234\n}}" for i, name in enumerate(sorted(prepare.EXPORTS), 1))
        self.assertEqual(prepare.windows_exports(output, "llvm-readobj"), prepare.EXPORTS)
        self.assertIn("<unnamed-export>", prepare.windows_exports(output + "\nExport {\n  Ordinal: 99\n  Name: \n  RVA: 0x5678\n}\n", "llvm-readobj"))
        with patch.object(prepare.shutil, "which", side_effect=lambda tool: "llvm-readobj.exe" if tool == "llvm-readobj" else None), patch.object(prepare.subprocess, "check_output", return_value=output):
            self.assertTrue(prepare.verify_library(Path("image.dll"), "windows")["isolated"])

    def test_missing_inspector_is_blocked(self):
        with patch.object(prepare.shutil, "which", return_value=None):
            with self.assertRaisesRegex(ValueError, "verification blocked"):
                prepare.verify_library(Path("image.dll"), "windows")

    def test_def_file_matches_allowlist(self):
        lines = (ROOT / "native/diffusion/exports.def").read_text().splitlines()
        self.assertEqual({line.strip() for line in lines if line.strip().startswith("quenderin_")}, prepare.EXPORTS)


if __name__ == "__main__":
    unittest.main(verbosity=2)

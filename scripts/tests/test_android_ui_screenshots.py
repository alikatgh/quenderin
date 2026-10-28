"""Offline regression fixtures for the bounded job-log screenshot transport."""
import hashlib
import io
from pathlib import Path
import runpy
import struct
import subprocess
import sys
import tempfile
import unittest
import zlib


TOOL = Path(__file__).resolve().parents[1] / "android_ui_screenshots.py"
API = runpy.run_path(str(TOOL))


def chunk(kind, payload):
    return struct.pack(">I", len(payload)) + kind + payload + struct.pack(">I", zlib.crc32(kind + payload) & 0xffffffff)


def png(width=1, height=1):
    header = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", zlib.compress(b"\0\xff\xff\xff\xff")) + chunk(b"IEND", b"")


class ScreenshotProtocolTests(unittest.TestCase):
    def encoded(self, images=None):
        output = io.StringIO()
        API["emit"](images or {"01-welcome-light.png": png()}, output)
        return output.getvalue()

    def decode(self, log):
        return API["decode"](io.StringIO(log))

    def test_round_trip_with_full_job_log_prefixes(self):
        images = {name: png() for name in API["NAMES"]}
        body = self.encoded(images)
        prefixed = "Build output\n" + "".join("job\tstep\t2026-10-28T00:00:00Z " + line for line in body.splitlines(keepends=True))
        self.assertEqual(self.decode(prefixed), images)

    def test_path_traversal_unknown_name_and_duplicate_image_are_rejected(self):
        log = self.encoded()
        for bad in ("../outside.png", "not-allowlisted.png", "/tmp/outside.png"):
            with self.subTest(name=bad), self.assertRaises(ValueError):
                self.decode(log.replace("01-welcome-light.png", bad))
        with self.assertRaisesRegex(ValueError, "duplicate"):
            self.decode(log + log)

    def test_missing_out_of_order_and_truncated_chunks_are_rejected(self):
        log = self.encoded()
        for bad in (
            log.replace("index=0", "index=1"),
            "\n".join(line for line in log.splitlines() if "_DATA " not in line),
            "\n".join(log.splitlines()[:-1]),
            log.replace("chunks=1", "chunks=2"),
        ):
            with self.subTest(log=bad[:60]), self.assertRaises(ValueError):
                self.decode(bad)

    def test_digest_size_and_base64_corruption_are_rejected(self):
        log = self.encoded()
        digest = hashlib.sha256(png()).hexdigest()
        cases = [log.replace(digest, "0" * 64),
                 log.replace(f"bytes={len(png())}", "bytes=1048577"),
                 log.replace(f"bytes={len(png())}", f"bytes={len(png()) - 1}"),
                 log.replace("data=i", "data=!")]
        for bad in cases:
            with self.subTest(log=bad[:60]), self.assertRaises(ValueError):
                self.decode(bad)

    def test_png_crc_dimensions_trailing_bytes_and_oversize_are_rejected(self):
        corrupt = bytearray(png())
        corrupt[20] ^= 1
        for data in (bytes(corrupt), png(4097, 1), png() + b"trailing", b"x" * (API["MAX_IMAGE"] + 1)):
            with self.subTest(size=len(data)), self.assertRaises(ValueError):
                API["validate_png"](data)

    def test_export_validates_entire_batch_before_writing_any_marker(self):
        output = io.StringIO()
        with self.assertRaises(ValueError):
            API["emit"]({"01-welcome-light.png": png(), "02-setup-light.png": b"bad"}, output)
        self.assertEqual(output.getvalue(), "")

    def test_unknown_or_nested_marker_and_oversize_log_line_fail_closed(self):
        log = self.encoded()
        for bad in (API["PREFIX"] + "OTHER\n", log.splitlines()[0] + "\n" + log,
                    "x" * 65537 + "\n"):
            with self.subTest(log=bad[:60]), self.assertRaises(ValueError):
                self.decode(bad)

    def test_cli_writes_only_allowlisted_png_and_never_overwrites(self):
        with tempfile.TemporaryDirectory(prefix="quenderin-ui-protocol-") as temporary:
            root = Path(temporary)
            log = root / "job.log"
            output = root / "review"
            log.write_text(self.encoded(), encoding="utf-8")
            command = [sys.executable, "-B", str(TOOL), "decode", "--input", str(log), "--output", str(output)]
            first = subprocess.run(command, capture_output=True, text=True, timeout=5)
            self.assertEqual(first.returncode, 0, first.stderr)
            self.assertEqual([p.name for p in output.iterdir()], ["01-welcome-light.png"])
            self.assertEqual((output / "01-welcome-light.png").read_bytes(), png())
            second = subprocess.run(command, capture_output=True, text=True, timeout=5)
            self.assertNotEqual(second.returncode, 0)
            self.assertIn("overwrite", second.stderr)
            self.assertEqual((output / "01-welcome-light.png").read_bytes(), png())

    def test_cli_rejects_invalid_final_record_before_creating_output(self):
        with tempfile.TemporaryDirectory(prefix="quenderin-ui-protocol-") as temporary:
            root = Path(temporary)
            log, output = root / "job.log", root / "review"
            log.write_text(self.encoded() + API["PREFIX"] + "OTHER\n", encoding="utf-8")
            result = subprocess.run([sys.executable, "-B", str(TOOL), "decode", "--input", str(log), "--output", str(output)],
                                    capture_output=True, text=True, timeout=5)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(output.exists())


if __name__ == "__main__":
    unittest.main()

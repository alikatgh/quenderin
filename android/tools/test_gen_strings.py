"""Host-only fixtures for preserving resources during translation regeneration."""
import io
from pathlib import Path
import runpy
import unittest
from unittest.mock import patch
import xml.etree.ElementTree as ET


GENERATOR = runpy.run_path(str(Path(__file__).with_name("gen_strings.py")))
FIXTURE = """<?xml version="1.0" encoding="utf-8"?>
<resources>
    <!-- <string name="managed">Keep this comment.</string> -->
    <string name="unmanaged" translatable="false">Keep &amp; raw text.</string>
    <string name="managed">Old copy.</string>
    <plurals name="unmanaged_plural">
        <item quantity="other">Keep %1$d items.</item>
    </plurals>
</resources>
"""


class GeneratorPreservationTests(unittest.TestCase):
    def setUp(self):
        self.path = "fixture/values/strings.xml"
        self.files = {self.path: FIXTURE}

    def open_memory(self, path, mode="r", encoding=None):
        if mode == "r":
            if path not in self.files:
                raise FileNotFoundError(path)
            return io.StringIO(self.files[path])
        self.assertEqual(mode, "w")
        files = self.files
        class Writer(io.StringIO):
            def close(self):
                if not self.closed:
                    files[path] = self.getvalue()
                super().close()
        return Writer()

    def generate(self, pairs):
        with patch("builtins.open", side_effect=self.open_memory), patch("os.makedirs"):
            GENERATOR["write_xml"](self.path, pairs)
        return self.files[self.path]

    def test_preserves_unknown_rows_and_updates_managed_copy(self):
        result = self.generate([("managed", "Selected host & approval.")])
        for block in (
            '    <!-- <string name="managed">Keep this comment.</string> -->',
            '    <string name="unmanaged" translatable="false">Keep &amp; raw text.</string>',
            '    <plurals name="unmanaged_plural">\n        <item quantity="other">Keep %1$d items.</item>\n    </plurals>',
        ):
            self.assertIn(block, result)
        strings = {node.attrib["name"]: node.text for node in ET.fromstring(result).findall("string")}
        self.assertEqual(strings["managed"], "Selected host & approval.")
        self.assertNotIn("Old copy.", result)

    def test_repeated_generation_is_identical_and_adds_missing_row_once(self):
        pairs = [("managed", "Updated."), ("added", "New.")]
        first = self.generate(pairs)
        self.assertEqual(first, self.generate(pairs))
        self.assertEqual(first.count('name="added"'), 1)

    def test_self_closing_string_does_not_consume_following_managed_row(self):
        empty = '    <string name="empty" />\n'
        for manage_empty in (False, True):
            with self.subTest(manage_empty=manage_empty):
                self.files[self.path] = FIXTURE.replace(
                    '    <string name="managed">', empty + '    <string name="managed">')
                pairs = [("managed", "Updated.")]
                if manage_empty:
                    pairs.append(("empty", "Filled."))
                result = self.generate(pairs)
                resources = ET.fromstring(result)
                self.assertEqual([node.attrib["name"] for node in resources],
                                 ["unmanaged", "empty", "managed", "unmanaged_plural"])
                strings = {node.attrib["name"]: node.text for node in resources.findall("string")}
                self.assertEqual(strings["managed"], "Updated.")
                self.assertEqual(strings["empty"], "Filled." if manage_empty else None)
                if not manage_empty:
                    self.assertIn(empty, result)
                self.assertEqual(result, self.generate(pairs))

    def test_duplicate_managed_row_fails_before_overwriting(self):
        original = FIXTURE.replace("</resources>", '<string name="managed">Duplicate.</string>\n</resources>')
        self.files[self.path] = original
        with self.assertRaisesRegex(SystemExit, "duplicate managed resource managed"):
            self.generate([("managed", "Updated.")])
        self.assertEqual(self.files[self.path], original)

    def test_new_file_contains_generated_rows(self):
        self.files.clear()
        result = self.generate([("managed", "New.")])
        self.assertEqual(ET.fromstring(result).find("string").text, "New.")

    def test_unsupported_self_closing_root_fails_before_overwriting(self):
        self.files[self.path] = "<resources />"
        with self.assertRaisesRegex(SystemExit, "resources closing tag"):
            self.generate([("managed", "New.")])
        self.assertEqual(self.files[self.path], "<resources />")


if __name__ == "__main__":
    unittest.main()

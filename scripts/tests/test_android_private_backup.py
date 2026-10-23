"""Keep saved private text out of each declared Android backup/transfer route."""
from pathlib import Path
import unittest
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parents[2]
ANDROID = "{http://schemas.android.com/apk/res/android}"


class PrivateBackupTests(unittest.TestCase):
    def test_manifest_selects_both_rule_sets(self):
        app = ET.parse(ROOT / "android/app/src/main/AndroidManifest.xml").find("application")
        self.assertEqual(app.get(ANDROID + "fullBackupContent"), "@xml/backup_rules")
        self.assertEqual(app.get(ANDROID + "dataExtractionRules"), "@xml/data_extraction_rules")

    def test_private_text_is_excluded_from_every_backup_route(self):
        legacy = ET.parse(ROOT / "android/app/src/main/res/xml/backup_rules.xml").getroot()
        modern = ET.parse(ROOT / "android/app/src/main/res/xml/data_extraction_rules.xml").getroot()
        routes = {"legacy": legacy, "cloud": modern.find("cloud-backup"),
                  "device-transfer": modern.find("device-transfer")}
        for name, route in routes.items():
            with self.subTest(route=name):
                self.assertIsNotNone(route)
                exclusions = [node.get("path").strip("/") for node in route.findall("exclude")
                              if node.get("domain") == "file"]
                def excluded(path):
                    return any(path == prefix or path.startswith(prefix + "/")
                               for prefix in exclusions)
                for path in ("approved-memories/facts.json", "approved-memories/nested/fact.json",
                             "conversations/index.json", "conversations/chat/messages.json",
                             "models/model.gguf", "remote-harness/credentials.bin", "remote-harness/session.json"):
                    self.assertTrue(excluded(path), f"{name} would back up {path}")
                self.assertFalse(excluded("ordinary-app-state.json"))


if __name__ == "__main__":
    unittest.main()

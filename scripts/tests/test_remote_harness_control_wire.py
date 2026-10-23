"""Secure-link parity requires exact successful native execution evidence."""
import copy
import unittest

from scripts import check_remote_harness_control_wire as gate


class ControlWireEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.document = {"schemaVersion": 1, "upstreamRevision": "a" * 40,
                         "origin": "Original synthetic test inventory",
                         "cases": [{"id": "one", "steps": [{"action": "begin"}]},
                                   {"id": "two", "steps": [{"action": "close"}], "note": "Synthetic"}]}
        self.ids = gate.fixture_ids(self.document)
        self.log = "\n".join("REMOTE_HARNESS_CONTROL_WIRE_FIXTURE_PASS " + item for item in self.ids)

    def test_complete_output_passes(self):
        self.assertEqual(gate.validate_report(self.log, self.ids, marker=gate.MARKER), 2)

    def test_missing_duplicate_unknown_commented_and_wrong_marker_rejected(self):
        for log in [self.log.split("\n", 1)[1], self.log + "\n" + self.log.split("\n")[0],
                    self.log + "\nREMOTE_HARNESS_CONTROL_WIRE_FIXTURE_PASS unknown",
                    "\n".join("// " + line for line in self.log.splitlines()),
                    self.log.replace("CONTROL_WIRE", "FRAGMENT")]:
            with self.subTest(log=log), self.assertRaises(gate.ContractError):
                gate.validate_report(log, self.ids, marker=gate.MARKER)

    def test_duplicate_ids_empty_inventory_and_missing_action_rejected(self):
        for rows in [[], [self.document["cases"][0]] * 2,
                     [{"id": "one", "steps": []}], [{"id": "one", "steps": [{}]}]]:
            broken = copy.deepcopy(self.document)
            broken["cases"] = rows
            with self.subTest(rows=rows), self.assertRaises(gate.ContractError):
                gate.fixture_ids(broken)

    def test_malformed_schema_and_note_rejected(self):
        for field, value in [("schemaVersion", True), ("upstreamRevision", "short"), ("origin", None)]:
            broken = copy.deepcopy(self.document)
            broken[field] = value
            with self.subTest(field=field), self.assertRaises(gate.ContractError):
                gate.fixture_ids(broken)
        for value in [None, "a" * 1_025, "\u00e9" * 513]:
            broken = copy.deepcopy(self.document)
            broken["cases"][0]["note"] = value
            with self.subTest(note_type=type(value).__name__), self.assertRaises(gate.ContractError):
                gate.fixture_ids(broken)


if __name__ == "__main__":
    unittest.main()

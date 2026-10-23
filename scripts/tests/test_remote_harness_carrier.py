"""A carrier test gate cannot pass with incomplete or duplicated native evidence."""
import copy
from pathlib import Path
import unittest
from scripts import check_remote_harness_carrier as gate


class CarrierEvidenceTests(unittest.TestCase):
    def setUp(self):
        path = Path(__file__).resolve().parents[2] / "shared/remote-harness-carrier-fixtures.json"
        self.doc = gate.checked_json(path.read_bytes())
        self.ids = gate.fixture_ids(self.doc)
        self.log = "\n".join("REMOTE_HARNESS_FIXTURE_PASS " + item for item in self.ids)

    def test_complete_execution_passes(self):
        self.assertEqual(gate.validate_report(self.log, self.ids), len(self.ids))

    def test_missing_execution_fails(self):
        with self.assertRaises(gate.ContractError):
            gate.validate_report(self.log.split("\n", 1)[1], self.ids)

    def test_duplicate_execution_fails(self):
        with self.assertRaises(gate.ContractError):
            gate.validate_report(self.log + "\nREMOTE_HARNESS_FIXTURE_PASS " + self.ids[0], self.ids)

    def test_unknown_execution_fails(self):
        with self.assertRaises(gate.ContractError):
            gate.validate_report(self.log + "\nREMOTE_HARNESS_FIXTURE_PASS unknown", self.ids)

    def test_source_comment_is_not_evidence(self):
        with self.assertRaises(gate.ContractError):
            gate.validate_report("\n".join("// " + line for line in self.log.splitlines()), self.ids)

    def test_duplicate_fixture_fails(self):
        self.doc["requests"].append(copy.deepcopy(self.doc["requests"][0]))
        with self.assertRaises(gate.ContractError):
            gate.fixture_ids(self.doc)

    def test_ambiguous_outcome_fails(self):
        self.doc["requests"][0]["error"] = "rejected"
        with self.assertRaises(gate.ContractError):
            gate.fixture_ids(self.doc)


if __name__ == "__main__":
    unittest.main()

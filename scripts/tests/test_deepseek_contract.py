"""A missing/duplicated native result must fail the CI evidence gate."""
import copy
from pathlib import Path
import unittest
from scripts import check_deepseek_contract as gate

SCRIPTS = Path(__file__).resolve().parents[1]


class DeepSeekEvidenceGateTests(unittest.TestCase):
    def setUp(self):
        self.doc = gate.checked_json((SCRIPTS.parent / "shared/deepseek-provider-fixtures.json").read_bytes())
        self.ids = gate.fixture_ids(self.doc)
        self.log = "\n".join("DEEPSEEK_FIXTURE_PASS " + case for case in self.ids)

    def test_complete_report_passes(self):
        self.assertEqual(gate.validate_report(self.log, self.ids), len(self.ids))

    def test_missing_case_fails(self):
        with self.assertRaises(gate.ContractError):
            gate.validate_report(self.log.split("\n", 1)[1], self.ids)

    def test_duplicate_case_fails(self):
        with self.assertRaises(gate.ContractError):
            gate.validate_report(self.log + "\nDEEPSEEK_FIXTURE_PASS " + self.ids[0], self.ids)

    def test_unknown_case_fails(self):
        with self.assertRaises(gate.ContractError):
            gate.validate_report(self.log + "\nDEEPSEEK_FIXTURE_PASS unknown", self.ids)

    def test_duplicate_fixture_fails(self):
        self.doc["models"].append(copy.deepcopy(self.doc["models"][0]))
        with self.assertRaises(gate.ContractError):
            gate.fixture_ids(self.doc)

    def test_invalid_base64_fails(self):
        self.doc["streams"][0]["chunksBase64"] = ["!invalid!"]
        with self.assertRaises(gate.ContractError):
            gate.fixture_ids(self.doc)

    def test_ambiguous_outcome_fails(self):
        self.doc["requests"][0]["error"] = "rejected"
        with self.assertRaises(gate.ContractError):
            gate.fixture_ids(self.doc)


if __name__ == "__main__":
    unittest.main()

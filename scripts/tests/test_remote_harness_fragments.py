"""Fragment parity cannot pass from incomplete or unrelated native output."""
import copy
from pathlib import Path
import unittest

from scripts import check_remote_harness_fragments as gate


class FragmentEvidenceTests(unittest.TestCase):
    def setUp(self):
        path = Path(__file__).resolve().parents[2] / "shared/remote-harness-fragments-fixtures.json"
        self.document = gate.checked_json(path.read_bytes())
        self.ids = gate.fixture_ids(self.document)
        self.log = "\n".join("REMOTE_HARNESS_FRAGMENT_FIXTURE_PASS " + item for item in self.ids)

    def check_report(self, log):
        return gate.validate_report(log, self.ids, marker=gate.MARKER)

    def test_complete_actual_output_passes(self):
        self.assertEqual(self.check_report(self.log), len(self.ids))

    def test_missing_duplicate_unknown_and_unrelated_markers_fail(self):
        for log in [self.log.split("\n", 1)[1], self.log + "\n" + self.log.split("\n")[0],
                    self.log + "\nREMOTE_HARNESS_FRAGMENT_FIXTURE_PASS unknown",
                    self.log.replace("REMOTE_HARNESS_FRAGMENT_FIXTURE_PASS", "REMOTE_HARNESS_FIXTURE_PASS")]:
            with self.subTest(log_length=len(log)), self.assertRaises(gate.ContractError):
                self.check_report(log)

    def test_commented_markers_are_not_evidence(self):
        with self.assertRaises(gate.ContractError):
            self.check_report("\n".join("// " + line for line in self.log.splitlines()))

    def test_duplicate_inventory_is_rejected(self):
        self.document["cases"].append(copy.deepcopy(self.document["cases"][0]))
        with self.assertRaises(gate.ContractError):
            gate.fixture_ids(self.document)

    def test_empty_case_or_missing_action_is_rejected(self):
        for steps in [[], [{}]]:
            broken = copy.deepcopy(self.document)
            broken["cases"][0]["steps"] = steps
            with self.subTest(steps=steps), self.assertRaises(gate.ContractError):
                gate.fixture_ids(broken)

    def test_unknown_schema_is_rejected(self):
        self.document["schemaVersion"] = True
        with self.assertRaises(gate.ContractError):
            gate.fixture_ids(self.document)


if __name__ == "__main__":
    unittest.main()

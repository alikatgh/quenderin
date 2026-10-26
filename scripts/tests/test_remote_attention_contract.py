import unittest

from scripts.check_remote_attention_contract import ContractError, fixture_ids, validate_report


class AttentionExecutionGateTests(unittest.TestCase):
    def test_requires_every_case_once(self):
        self.assertEqual(validate_report("REMOTE_ATTENTION_CASE_PASS a\nREMOTE_ATTENTION_CASE_PASS b\n", ["a", "b"]), 2)

    def test_failed_check_blocks_next_action(self):
        for log in ("", "REMOTE_ATTENTION_CASE_PASS a\n", "REMOTE_ATTENTION_CASE_PASS a\nREMOTE_ATTENTION_CASE_PASS a\nREMOTE_ATTENTION_CASE_PASS b\n",
                    "REMOTE_ATTENTION_CASE_PASS a\nREMOTE_ATTENTION_CASE_PASS b\nREMOTE_ATTENTION_CASE_PASS extra\n"):
            with self.subTest(log=log):
                reached = []
                with self.assertRaises(ContractError):
                    validate_report(log, ["a", "b"])
                    reached.append("verification-complete")
                self.assertEqual(reached, [])

    def test_case_names_in_source_or_prose_are_not_execution(self):
        with self.assertRaises(ContractError):
            validate_report('print("REMOTE_ATTENTION_CASE_PASS a")\n', ["a"])

    def test_valid_fixture_identity(self):
        self.assertEqual(fixture_ids({"schemaVersion": 1, "cases": [{"id": "a", "steps": [{}]}]}), ["a"])

    def test_invalid_fixture_identity(self):
        for value in ({"schemaVersion": True, "cases": []}, {"schemaVersion": 1, "cases": []},
                      {"schemaVersion": 1, "cases": [{"id": "a\nb", "steps": [{}]}]},
                      {"schemaVersion": 1, "cases": [{"id": "a", "steps": []}]},
                      {"schemaVersion": 1, "cases": [{"id": "a", "steps": [{}]}] * 2}):
            with self.subTest(value=value), self.assertRaises(ContractError):
                fixture_ids(value)


if __name__ == "__main__":
    unittest.main()

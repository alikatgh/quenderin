"""Failure tests for runtime parity evidence; no networking or native execution."""
from __future__ import annotations

import copy
import json
from pathlib import Path
import unittest

from scripts.check_native_connections_contract import (
    ContractError, MAX_FIXTURE_BYTES, checked_json, fixture_ids, validate_report,
)


class NativeConnectionEvidenceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.document = checked_json((Path(__file__).resolve().parents[2] / "shared/native-connections-fixtures.json").read_bytes())
        cls.ids = fixture_ids(cls.document)

    def report(self, ids=None):
        return "\n".join(f"NATIVE_CONNECTION_FIXTURE_PASS {case_id}" for case_id in (self.ids if ids is None else ids))

    def test_canonical_cases_cover_all_groups_and_destinations(self):
        self.assertGreaterEqual(len(self.ids), 80)
        self.assertEqual(len(set(self.ids)), len(self.ids))

    def test_completed_native_log_is_accepted(self):
        log = "Test suite started.\n" + self.report() + "\nTest suite finished.\n"
        self.assertEqual(validate_report(log, self.ids), len(self.ids))

    def test_coverage_is_order_independent(self):
        self.assertEqual(validate_report(self.report(list(reversed(self.ids))), self.ids), len(self.ids))

    def test_missing_case_fails(self):
        with self.assertRaises(ContractError):
            validate_report(self.report(self.ids[:-1]), self.ids)

    def test_duplicate_case_fails_even_when_all_cases_are_present(self):
        with self.assertRaises(ContractError):
            validate_report(self.report(self.ids + [self.ids[0]]), self.ids)

    def test_unknown_case_fails(self):
        with self.assertRaises(ContractError):
            validate_report(self.report(self.ids + ["not-a-canonical-case"]), self.ids)

    def test_source_comments_are_not_execution_evidence(self):
        log = "\n".join(f"// NATIVE_CONNECTION_FIXTURE_PASS {case_id}" for case_id in self.ids)
        with self.assertRaises(ContractError):
            validate_report(log, self.ids)

    def test_duplicate_fixture_id_fails(self):
        changed = copy.deepcopy(self.document)
        changed["profilesValid"][1]["id"] = changed["profilesValid"][0]["id"]
        with self.assertRaises(ContractError):
            fixture_ids(changed)

    def test_missing_group_fails(self):
        changed = copy.deepcopy(self.document)
        del changed["legacy"]
        with self.assertRaises(ContractError):
            fixture_ids(changed)

    def test_future_and_fractional_fixture_version_fail(self):
        for version in (2, 1.5, True):
            changed = copy.deepcopy(self.document)
            changed["schemaVersion"] = version
            with self.assertRaises(ContractError):
                fixture_ids(changed)

    def test_legacy_identity_loss_fails(self):
        changed = copy.deepcopy(self.document)
        changed["legacy"][1]["expectedMessages"][0]["id"] = "replaced"
        with self.assertRaises(ContractError):
            fixture_ids(changed)

    def test_duplicate_json_keys_fail(self):
        with self.assertRaises(ContractError):
            checked_json(b'{"schemaVersion":1,"schemaVersion":2}')

    def test_malformed_utf8_and_oversized_fixture_fail(self):
        for data in (b'\xff', b" " * (MAX_FIXTURE_BYTES + 1)):
            with self.assertRaises(ContractError):
                checked_json(data)

    def test_errors_do_not_echo_fixture_content(self):
        with self.assertRaises(ContractError) as result:
            checked_json(b'{"private-user-content":')
        self.assertNotIn("private-user-content", str(result.exception))


if __name__ == "__main__":
    unittest.main()

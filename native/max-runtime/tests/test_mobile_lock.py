import copy
import pathlib
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / "tools"))
from check_mobile_lock import catalog_entry, load_lock, validate


class MobileLock(unittest.TestCase):
    def setUp(self):
        self.lock = load_lock()
        self.entry = catalog_entry(self.lock["artifact"]["modelId"])

    def rejected(self, mutate):
        lock = copy.deepcopy(self.lock)
        mutate(lock)
        with self.assertRaises(ValueError):
            validate(lock, self.entry)

    def test_current_receipt(self):
        validate(self.lock, self.entry)
        self.assertEqual(self.lock["status"], "blocked-no-public-mobile-backend")
        self.assertEqual(len(self.lock["prerequisites"]), 7)
        self.assertTrue(all(not item["satisfied"] for item in self.lock["prerequisites"]))

    def test_unknown_status_rejected(self):
        self.rejected(lambda x: x.update(status="mobile-supported"))

    def test_wrong_source_revision_rejected(self):
        self.rejected(lambda x: x["movement"].update(sourceRevision="0" * 40))

    def test_hidden_mobile_path_rejected(self):
        self.rejected(lambda x: x["movement"].update(mobileBackendPaths=1))

    def test_missing_blog_statement_rejected(self):
        self.rejected(lambda x: x["movement"]["blog"].update(statement="Supported."))

    def test_changed_license_rejected(self):
        self.rejected(lambda x: x["movement"]["sourceLicense"].update(bytes=1))

    def test_demo_cannot_claim_source(self):
        self.rejected(lambda x: x["demonstration"].update(publicSourceAvailable=True))

    def test_demo_cannot_claim_reproduction(self):
        self.rejected(lambda x: x["demonstration"].update(independentlyReproduced=True))

    def test_invented_mef_rejected(self):
        self.rejected(lambda x: x["artifact"].update(mef="bonsai.mef"))

    def test_catalog_artifact_mismatch_rejected(self):
        self.rejected(lambda x: x["artifact"].update(sha256="0" * 64))

    def test_satisfied_prerequisite_rejected(self):
        self.rejected(lambda x: x["prerequisites"][0].update(satisfied=True))

    def test_unverified_support_claim_rejected(self):
        self.rejected(lambda x: x["claims"].update(mobileMaxSupported=True))

    def test_phone_claim_rejected(self):
        self.rejected(lambda x: x["claims"].update(phonePerformanceVerified=True))

    def test_store_submission_change_rejected(self):
        self.rejected(lambda x: x["claims"].update(storeSubmission="submitted"))


if __name__ == "__main__":
    unittest.main()

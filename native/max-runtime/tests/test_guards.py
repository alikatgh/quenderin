import copy
import hashlib
import io
import json
import os
import pathlib
import sys
import tempfile
import time
import unittest
from unittest.mock import patch
import zipfile

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / "tools"))
from gates import ROOT, assert_network, assert_status, load_lock, require_hosted, runtime_environment, verify_license_review
from bootstrap import download, inspect_metadata, inspect_wheels, metadata_record
from run_fixture import bounded


SAFE_STATUS = "Uid:\t1001 1001 1001 1001\n" + "".join(
    f"{name}:\t0000000000000000\n" for name in ["CapEff", "CapPrm", "CapBnd", "CapInh", "CapAmb"]
) + "NoNewPrivs:\t1\n"
DEVICES = "Inter-| Receive\n face | bytes\n lo: 0 0 0 0\n"


class Guards(unittest.TestCase):
    def test_exact_lock(self):
        lock = load_lock()
        self.assertEqual(len(lock["packages"]), 17)
        self.assertEqual(sum(p["size"] for p in lock["packages"]), 262318881)
        self.assertIn("runtime_license_review", lock)
        for package in lock["packages"]:
            metadata_record(package)

    def reject_lock(self, mutate):
        lock = json.loads((ROOT / "sdk-lock.json").read_text())
        mutate(lock)
        with tempfile.TemporaryDirectory(prefix="quenderin-max-guard-") as directory:
            path = pathlib.Path(directory) / "lock.json"
            path.write_text(json.dumps(lock))
            with self.assertRaises(ValueError):
                load_lock(path)

    def test_unofficial_origin_rejected(self):
        self.reject_lock(lambda x: x["packages"][0].update(url="https://example.invalid/max.whl"))

    def test_changed_generation_rejected(self):
        self.reject_lock(lambda x: x.update(sdk_version="latest"))

    def test_expanded_budget_rejected(self):
        self.reject_lock(lambda x: x.update(maximum_network_seconds=3600))

    def test_incomplete_dependency_closure_rejected(self):
        self.reject_lock(lambda x: x["packages"].pop())

    def test_unpinned_header_rejected(self):
        self.reject_lock(lambda x: x["headers"][0].update(sha256=""))

    def test_wrong_review_digest_rejected(self):
        with self.assertRaises(ValueError):
            load_lock(reviewed="0" * 64)

    def test_no_local_install(self):
        with patch.dict(os.environ, {}, clear=True), self.assertRaises(ValueError):
            require_hosted()

    def test_privilege_gate(self):
        assert_status(SAFE_STATUS)
        for bad in [SAFE_STATUS.replace("1001", "0", 1), SAFE_STATUS.replace("CapBnd:\t0000000000000000", "CapBnd:\t0000000000000001"),
                    SAFE_STATUS.replace("NoNewPrivs:\t1", "NoNewPrivs:\t0"), SAFE_STATUS.replace("CapEff:", "Missing:")]:
            with self.assertRaises(ValueError):
                assert_status(bad)

    def test_isolation_gate(self):
        assert_network("net:[1]", "net:[2]", DEVICES, "Iface Destination\n", "")
        for arguments in [("net:[1]", "net:[1]", DEVICES, "", ""), ("", "net:[2]", DEVICES, "", ""),
                          ("net:[1]", "net:[2]", DEVICES + "eth0: 0\n", "", ""),
                          ("net:[1]", "net:[2]", DEVICES, "Iface Destination\neth0 00000000\n", ""),
                          ("net:[1]", "net:[2]", DEVICES, "", "000000 eth0\n")]:
            with self.assertRaises(ValueError):
                assert_network(*arguments)

    def test_environment_is_an_allowlist_with_preimport_optouts(self):
        with patch.dict(os.environ, {"UNRELATED_PRIVATE_SENTINEL": "never-inherit", "LD_PRELOAD": "bad"}):
            env = runtime_environment(pathlib.Path("/tmp/owned"), pathlib.Path("/tmp/sdk"), [pathlib.Path("/tmp/sdk/lib")])
        self.assertNotIn("UNRELATED_PRIVATE_SENTINEL", env)
        self.assertNotIn("LD_PRELOAD", env)
        self.assertEqual(env["MODULAR_TELEMETRY_ENABLED"], "0")
        self.assertEqual(env["MODULAR_CRASH_REPORTING_ENABLED"], "0")

    def test_unreviewed_license_fixture_fails_closed(self):
        lock = {"runtime_license_review": None}
        licenses = [{"package": "max-core", "path": "dist-info/LICENSE", "sha256": "1" * 64}]
        with self.assertRaises(ValueError):
            verify_license_review(lock, licenses)

    def test_reviewed_license_fixture_accepts_exact_terms(self):
        licenses = [{"package": "max-core", "path": "dist-info/LICENSE", "sha256": "1" * 64},
                    {"package": "max-core", "path": "max_core/LICENSE", "sha256": "2" * 64}]
        lock = {"runtime_license_review": {"scope": "hosted-cpu-fixture-only-no-redistribution",
                                            "license_sha256": {"max-core/dist-info/LICENSE": "1" * 64,
                                                               "max-core/max_core/LICENSE": "2" * 64}}}
        verify_license_review(lock, licenses)
        changed = copy.deepcopy(licenses)
        changed[0]["sha256"] = "3" * 64
        with self.assertRaises(ValueError):
            verify_license_review(lock, changed)
        del lock["runtime_license_review"]["license_sha256"]["max-core/max_core/LICENSE"]
        with self.assertRaises(ValueError):
            verify_license_review(lock, licenses)

    def test_download_rejects_wrong_length_and_digest(self):
        class Response(io.BytesIO):
            status = 200
            headers = {"Content-Length": "4"}
        class Opener:
            def open(self, url, timeout):
                return Response(b"DATA")
        item = {"url": "https://files.pythonhosted.org/inert", "size": 4, "sha256": hashlib.sha256(b"DATA").hexdigest()}
        with tempfile.TemporaryDirectory(prefix="quenderin-max-guard-") as directory, patch("urllib.request.build_opener", return_value=Opener()):
            root = pathlib.Path(directory)
            download(item, root / "good", time.monotonic() + 1)
            self.assertEqual((root / "good").read_bytes(), b"DATA")
            with self.assertRaises(ValueError):
                download({**item, "size": 3}, root / "wrong-length", time.monotonic() + 1)
            with self.assertRaises(ValueError):
                download({**item, "sha256": "0" * 64}, root / "wrong-hash", time.monotonic() + 1)
            with self.assertRaises(ValueError):
                download(item, root / "expired", time.monotonic() - 1)

    def test_wheel_inspection_is_inert_and_rejects_traversal(self):
        with tempfile.TemporaryDirectory(prefix="quenderin-max-guard-") as directory:
            root = pathlib.Path(directory)
            path = root / "inert.whl"
            metadata = b"Name: max-core\nVersion: 26.7.0\n"
            with zipfile.ZipFile(path, "w") as wheel:
                wheel.writestr("max_core-26.7.0.dist-info/METADATA", metadata)
                wheel.writestr("max_core-26.7.0.dist-info/licenses/LICENSE", "Inert test terms")
                wheel.writestr("max_core/LICENSE", "Package-level terms")
                wheel.writestr("max_core/Third-Party-Notices", "Bundled notices")
                wheel.writestr("max_core/licenses/THIRD-PARTY.txt", "License directory terms")
                wheel.writestr("max_core/__init__.py", "raise RuntimeError('must never import')")
            package = {"filename": path.name, "name": "max-core", "version": "26.7.0", "size": path.stat().st_size,
                       "sha256": hashlib.sha256(path.read_bytes()).hexdigest(), "requires_dist": [],
                       "url": "https://files.pythonhosted.org/packages/inert.whl",
                       "wheel_metadata": {"index_url": "https://pypi.org/simple/max-core/",
                                          "url": "https://files.pythonhosted.org/packages/inert.whl.metadata",
                                          "size": len(metadata), "sha256": hashlib.sha256(metadata).hexdigest()}}
            lock = {"packages": [package], "maximum_uncompressed_bytes": 4096}
            licenses, _ = inspect_wheels(lock, root)
            self.assertEqual({item["path"] for item in licenses}, {
                "max_core-26.7.0.dist-info/licenses/LICENSE", "max_core/LICENSE",
                "max_core/Third-Party-Notices", "max_core/licenses/THIRD-PARTY.txt"})
            with zipfile.ZipFile(path, "a") as wheel:
                wheel.writestr("../outside", "bad")
            package.update(size=path.stat().st_size, sha256=hashlib.sha256(path.read_bytes()).hexdigest())
            with self.assertRaises(ValueError):
                inspect_wheels(lock, root)

    def metadata_fixture(self, raw):
        return {"name": "max", "version": "26.7.0", "requires_dist": ["max[serve,benchmark]; extra == 'all'"],
                "url": "https://files.pythonhosted.org/packages/inert.whl",
                "wheel_metadata": {"index_url": "https://pypi.org/simple/max/",
                                   "url": "https://files.pythonhosted.org/packages/inert.whl.metadata",
                                   "size": len(raw), "sha256": hashlib.sha256(raw).hexdigest()}}

    def test_exact_selected_wheel_metadata_replaces_project_json_rendering(self):
        raw = b"Name: max\nVersion: 26.7.0\nRequires-Dist: max[serve,benchmark]; extra == 'all'\n"
        package = self.metadata_fixture(raw)
        self.assertEqual(inspect_metadata(package, raw).get_all("Requires-Dist"), package["requires_dist"])
        # PyPI project JSON normalizes quotes and extra ordering. The lock must
        # preserve the exact wheel declarations instead of weakening equality.
        package["requires_dist"] = ['max[benchmark,serve]; extra == "all"']
        with self.assertRaisesRegex(ValueError, "max==26.7.0: Requires-Dist"):
            inspect_metadata(package, raw)

    def test_selected_wheel_metadata_identity_and_field_diagnostics(self):
        raw = b"Name: max\nVersion: 26.7.0\nRequires-Dist: max[serve,benchmark]; extra == 'all'\n"
        package = self.metadata_fixture(raw)
        for field, value, message in [("size", len(raw) + 1, "METADATA size"), ("sha256", "0" * 64, "METADATA SHA256"),
                                      ("url", "https://example.invalid/inert.metadata", "PEP 658 provenance")]:
            changed = copy.deepcopy(package)
            changed["wheel_metadata"][field] = value
            with self.assertRaisesRegex(ValueError, f"max==26.7.0: {message}"):
                inspect_metadata(changed, raw)
        for changed_raw, message in [(raw.replace(b"Name: max", b"Name: wrong"), "Name"),
                                     (raw.replace(b"Version: 26.7.0", b"Version: 26.8.0"), "Version")]:
            with self.assertRaisesRegex(ValueError, f"max==26.7.0: {message}"):
                inspect_metadata(self.metadata_fixture(changed_raw), changed_raw)

    def test_supervisor_bounds_time_output_and_exit(self):
        env = {"PATH": "/usr/bin:/bin"}
        with tempfile.TemporaryDirectory(prefix="quenderin-max-guard-") as directory:
            root = pathlib.Path(directory)
            result = bounded([sys.executable, "-c", "print('bounded')"], env=env, cwd=root, deadline=time.monotonic() + 5)
            self.assertEqual(result, (b"bounded\n", b""))
            with self.assertRaises(ValueError):
                bounded([sys.executable, "-c", "print('x'*100000)"], env=env, cwd=root, deadline=time.monotonic() + 5)
            with self.assertRaises(ValueError):
                bounded([sys.executable, "-c", "import time; time.sleep(10)"], env=env, cwd=root, deadline=time.monotonic() + 0.05)
            with self.assertRaises(ValueError):
                bounded([sys.executable, "-c", "raise SystemExit(3)"], env=env, cwd=root, deadline=time.monotonic() + 5)

    def test_supervisor_keeps_json_separate_from_benign_stderr(self):
        env = {"PATH": "/usr/bin:/bin"}
        with tempfile.TemporaryDirectory(prefix="quenderin-max-guard-") as directory:
            root = pathlib.Path(directory)
            stdout, stderr = bounded([sys.executable, "-c",
                "import sys; print('{\"output\":[2,6,12,20]}'); print('benign warning', file=sys.stderr)"],
                env=env, cwd=root, deadline=time.monotonic() + 5)
            self.assertEqual(json.loads(stdout), {"output": [2, 6, 12, 20]})
            self.assertEqual(stderr, b"benign warning\n")
            with self.assertRaisesRegex(ValueError, "64 KiB"):
                bounded([sys.executable, "-c", "import sys; print('x'*40000); print('y'*40000, file=sys.stderr)"],
                        env=env, cwd=root, deadline=time.monotonic() + 5)
            with self.assertRaisesRegex(ValueError, "failure diagnostic"):
                bounded([sys.executable, "-c", "import sys; print('failure diagnostic', file=sys.stderr); raise SystemExit(3)"],
                        env=env, cwd=root, deadline=time.monotonic() + 5)


if __name__ == "__main__":
    unittest.main()

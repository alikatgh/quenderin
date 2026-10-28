"""Offline fixtures for the bounded, artifact-free dependency snapshot POST."""
from contextlib import redirect_stderr, redirect_stdout
import copy
from io import StringIO
import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "tools"))
import github_dependency_snapshot as snapshot

TOKEN = "synthetic-job-token-do-not-use"


class FakeConnection:
    def __init__(self, factory):
        self.factory = factory
        self.closed = False

    def request(self, method, path, body, headers):
        self.factory.requests.append((method, path, body, headers))
        if self.factory.error:
            raise self.factory.error

    def getresponse(self):
        if self.factory.response_error:
            raise self.factory.response_error
        return self.factory

    def close(self):
        self.closed = True


class FakeGitHub:
    def __init__(self, status=201, body=None, error=None, response_error=None, read_error=None):
        self.status = status
        self.body = json.dumps({"id": 123, "result": "SUCCESS"}).encode() if body is None else body
        self.error = error
        self.response_error = response_error
        self.read_error = read_error
        self.connections = []
        self.requests = []
        self.reads = 0

    def __call__(self, host, timeout):
        connection = FakeConnection(self)
        self.connections.append((host, timeout, connection))
        return connection

    def read(self, size):
        self.reads += 1
        if self.read_error:
            raise self.read_error
        return self.body[:size]


class SnapshotTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="github-snapshot-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.reports = self.root / snapshot.REPORT_DIRECTORY
        self.reports.mkdir()
        self.path = self.reports / f"{snapshot.CORRELATOR}.json"
        self.environment = {
            "GITHUB_REPOSITORY": snapshot.REPOSITORY,
            "GITHUB_EVENT_NAME": "push",
            "GITHUB_REF": "refs/heads/main",
            "GITHUB_SHA": "a" * 40,
            "GITHUB_RUN_ID": "123456",
            "RUNNER_TEMP": str(self.root),
            "SNAPSHOT_PATH": str(self.path),
            "GH_TOKEN": TOKEN,
        }
        self.report = {
            "version": 0,
            "job": {"id": "123456", "correlator": snapshot.CORRELATOR},
            "sha": "a" * 40,
            "ref": "refs/heads/main",
            "detector": dict(snapshot.DETECTOR),
            "scanned": "2026-10-28T00:00:00Z",
            "manifests": {snapshot.CORRELATOR: {
                "name": snapshot.CORRELATOR,
                "file": {"source_location": "android/settings.gradle.kts"},
                "resolved": {
                    "androidx.core:core-ktx:1.13.1": {
                        "package_url": "pkg:maven/androidx.core/core-ktx@1.13.1",
                        "relationship": "direct", "scope": "runtime", "dependencies": [],
                    },
                    "org.gradle:gradle-build-tool:8.11.1": {
                        "package_url": "pkg:maven/org.gradle/gradle-build-tool@8.11.1",
                        "relationship": "direct", "scope": "development", "dependencies": [],
                    },
                },
            }},
        }
        self.write_report()

    def write_report(self, report=None):
        self.path.write_text(json.dumps(self.report if report is None else report), encoding="utf-8")

    def invoke(self, transport=None):
        transport = transport or FakeGitHub()
        before = set(self.root.rglob("*"))
        stdout, stderr = StringIO(), StringIO()
        with redirect_stdout(stdout), redirect_stderr(stderr):
            result = snapshot.main(self.environment, transport)
        self.assertEqual(before, set(self.root.rglob("*")), "helper must not create artifacts or other files")
        self.assertNotIn(TOKEN, stdout.getvalue() + stderr.getvalue())
        for _, _, connection in transport.connections:
            self.assertTrue(connection.closed)
        return result, stdout.getvalue(), stderr.getvalue(), transport

    def assert_preflight_rejected(self):
        result, _, error, transport = self.invoke()
        self.assertEqual(1, result)
        self.assertTrue(error)
        self.assertEqual([], transport.connections)

    def test_success_submits_the_unchanged_file_once_to_the_fixed_endpoint(self):
        result, output, error, transport = self.invoke()
        self.assertEqual((0, ""), (result, error))
        self.assertIn("id=123", output)
        self.assertIn("dependencies=2", output)
        self.assertEqual(1, len(transport.connections))
        self.assertEqual(("api.github.com", 30), transport.connections[0][:2])
        self.assertEqual(1, len(transport.requests))
        method, path, body, headers = transport.requests[0]
        self.assertEqual(("POST", "/repos/alikatgh/quenderin/dependency-graph/snapshots"), (method, path))
        self.assertEqual(self.path.read_bytes(), body)
        self.assertEqual("Bearer " + TOKEN, headers["Authorization"])

    def test_missing_file(self):
        self.path.unlink()
        self.assert_preflight_rejected()

    def test_malformed_json_does_not_log_contents(self):
        self.path.write_text('{"unclosed": "' + TOKEN)
        self.assert_preflight_rejected()

    def test_duplicate_json_keys(self):
        self.path.write_text('{"version":0,"version":0}')
        self.assert_preflight_rejected()

    def test_empty_and_non_utf8_reports(self):
        for content in (b"", b"\xff\xfe"):
            with self.subTest(content=content):
                self.path.write_bytes(content)
                self.assert_preflight_rejected()

    def test_oversize_report_is_rejected_before_read_or_request(self):
        with self.path.open("wb") as report:
            report.truncate(snapshot.MAX_SNAPSHOT_BYTES + 1)
        self.assert_preflight_rejected()

    def test_symlink_file_and_directory_are_rejected(self):
        original = self.path.read_bytes()
        target = self.root / "outside.json"
        target.write_bytes(original)
        self.path.unlink()
        self.path.symlink_to(target)
        self.assert_preflight_rejected()
        self.path.unlink()
        self.reports.rmdir()
        self.reports.symlink_to(self.root, target_is_directory=True)
        self.assert_preflight_rejected()

    def test_unexpected_path_or_extra_report_is_rejected(self):
        self.environment["SNAPSHOT_PATH"] = str(self.root / "outside.json")
        self.assert_preflight_rejected()
        self.environment["SNAPSHOT_PATH"] = str(self.path)
        (self.reports / "extra.json").write_text("{}")
        self.assert_preflight_rejected()

    def test_wrong_sha_ref_run_correlator_detector_and_version(self):
        cases = [
            ("sha", "b" * 40), ("ref", "refs/heads/feature"), ("version", False),
            ("job", {"id": "654321", "correlator": snapshot.CORRELATOR}),
            ("job", {"id": "123456", "correlator": "other"}),
            ("detector", {**snapshot.DETECTOR, "version": "other"}),
            ("detector", {**snapshot.DETECTOR, "name": "other"}),
            ("detector", {**snapshot.DETECTOR, "url": "https://example.invalid"}),
            ("scanned", "invalid"), ("scanned", "2026-10-28T00:00:00"),
        ]
        for key, value in cases:
            with self.subTest(key=key, value=value):
                report = copy.deepcopy(self.report)
                report[key] = value
                self.write_report(report)
                self.assert_preflight_rejected()

    def test_manifest_identity_and_source_location(self):
        for manifests in ({}, {"other": {}}, {snapshot.CORRELATOR: None},
                          {snapshot.CORRELATOR: {"name": snapshot.CORRELATOR, "file": {"source_location": "other.gradle"}}}):
            with self.subTest(manifests=manifests):
                report = copy.deepcopy(self.report)
                report["manifests"] = manifests
                self.write_report(report)
                self.assert_preflight_rejected()

    def test_empty_malformed_or_build_tool_only_manifest_is_rejected(self):
        for resolved in ({}, {"bad": None}, {"build-tool": {"package_url": "pkg:maven/org.gradle/gradle-build-tool@8.11.1"}}):
            with self.subTest(resolved=resolved):
                report = copy.deepcopy(self.report)
                report["manifests"][snapshot.CORRELATOR]["resolved"] = resolved
                self.write_report(report)
                self.assert_preflight_rejected()

    def test_untrusted_execution_contexts_and_missing_token_are_rejected(self):
        for key, value in (("GITHUB_REPOSITORY", "fork/quenderin"), ("GITHUB_EVENT_NAME", "pull_request"),
                           ("GITHUB_EVENT_NAME", "pull_request_target"), ("GITHUB_REF", "refs/heads/feature"),
                           ("GH_TOKEN", "")):
            with self.subTest(key=key, value=value):
                original = self.environment[key]
                self.environment[key] = value
                self.assert_preflight_rejected()
                self.environment[key] = original

    def test_http_errors_and_redirects_fail_once_without_reading_or_logging_body(self):
        for status in (301, 302, 307, 308, 403, 429, 500, 502, 503):
            with self.subTest(status=status):
                transport = FakeGitHub(status=status, body=TOKEN.encode())
                result, _, error, transport = self.invoke(transport)
                self.assertEqual(1, result)
                self.assertIn(f"HTTP {status}", error)
                self.assertEqual((1, 1, 0), (len(transport.connections), len(transport.requests), transport.reads))

    def test_timeout_and_transport_exception_do_not_retry_or_log_exception_messages(self):
        for error in (TimeoutError(TOKEN), OSError(TOKEN)):
            with self.subTest(error=type(error).__name__):
                result, _, _, transport = self.invoke(FakeGitHub(error=error))
                self.assertEqual(1, result)
                self.assertEqual((1, 1), (len(transport.connections), len(transport.requests)))

    def test_response_and_body_timeouts_do_not_retry_after_a_post(self):
        for transport in (FakeGitHub(response_error=TimeoutError(TOKEN)), FakeGitHub(read_error=TimeoutError(TOKEN))):
            result, _, _, transport = self.invoke(transport)
            self.assertEqual(1, result)
            self.assertEqual((1, 1), (len(transport.connections), len(transport.requests)))

    def test_invalid_and_oversize_success_receipts_fail_safely(self):
        for body in (TOKEN.encode(), b'{"id":123,"result":"FAILURE"}', b'{"id":true,"result":"SUCCESS"}',
                     b"x" * (snapshot.MAX_RESPONSE_BYTES + 1)):
            with self.subTest(size=len(body)):
                result, _, _, transport = self.invoke(FakeGitHub(body=body))
                self.assertEqual(1, result)
                self.assertEqual((1, 1), (len(transport.connections), len(transport.requests)))


if __name__ == "__main__":
    unittest.main()

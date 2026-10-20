"""No-network fixtures for the one-draft Android candidate export boundary."""
from __future__ import annotations

import copy
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
import warnings
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import android_beta_candidate as candidate


class Fixture:
    def __init__(self, root: Path):
        self.source = root / "source"
        self.source.mkdir()
        self.gradle = self.source / "android/app/build.gradle.kts"
        self.gradle.parent.mkdir(parents=True)
        self.gradle.write_text('applicationId = "ai.quenderin.app"\nversionName = "0.5.0"\nversionCode = 5\n')
        self.bundle = self.source / "android/app/build/outputs/bundle/release/app-release.aab"
        self.bundle.parent.mkdir(parents=True)
        self.write_bundle()
        self.repository = {"full_name": candidate.REPOSITORY, "private": False}
        self.release = {"id": candidate.RELEASE_ID, "draft": True, "prerelease": True,
                        "published_at": None, "tag_name": candidate.TAG,
                        "target_commitish": candidate.SOURCE_SHA,
                        "url": f"https://api.github.com/{candidate.RELEASE_API}", "assets": []}
        self.source_sha = candidate.SOURCE_SHA
        self.tag_sha = None
        self.dirty = False
        self.fail_native = False
        self.fail_upload = False
        self.publish_after_upload = False
        self.calls = []
        self.uploads = []
        self.root = root
        self.draft = candidate.Draft(candidate.REPOSITORY, self.run)

    def write_bundle(self, extra=None, duplicate=False):
        with zipfile.ZipFile(self.bundle, "w") as archive:
            for name in ("BundleConfig.pb", "base/manifest/AndroidManifest.xml", "base/dex/classes.dex",
                         "base/lib/arm64-v8a/libquenderin_llama.so"):
                archive.writestr(name, b"fixture payload")
            if extra:
                archive.writestr(extra, b"signature")
            if duplicate:
                with warnings.catch_warnings():
                    warnings.simplefilter("ignore", UserWarning)
                    archive.writestr("BundleConfig.pb", b"duplicate")

    def run(self, args, timeout=120):
        self.calls.append((args, timeout))
        if args[0] == "git":
            if args[1] == "ls-remote":
                return "" if self.tag_sha is None else self.tag_sha + "\trefs/tags/" + candidate.TAG + "\n"
            if "rev-parse" in args:
                return self.source_sha + "\n"
            if "diff" in args:
                if self.dirty:
                    raise ValueError("Source changed")
                return ""
        elif args[0] == "gh":
            if "--method" in args:
                self.assert_fixed_upload(args)
                path = Path(args[args.index("--input") + 1])
                self.uploads.append(path.name)
                self.release["assets"].append({"name": path.name, "size": path.stat().st_size,
                                               "digest": candidate.digest(path), "state": "uploaded"})
                if self.publish_after_upload:
                    self.release["draft"] = False
                if self.fail_upload:
                    raise ValueError("Upload acknowledgement interrupted")
                return "{}"
            if args == ["gh", "api", candidate.API]:
                return json.dumps(self.repository)
            if args == ["gh", "api", candidate.RELEASE_API]:
                return json.dumps(self.release)
        elif args[0] == sys.executable:
            if self.fail_native:
                raise ValueError("Native verification failed")
            if "verify_diffusion_android_package.py" in args[1]:
                return json.dumps({"revision": "image-source", "verified": ["libquenderin_diffusion.so"],
                                   "alignment": 16384, "artifact": str(self.bundle)})
            if "prepare_prism_runtime.py" in args[1]:
                return json.dumps({"revision": "prism-source", "sourcePatchId": "pinned-patch"})
        raise AssertionError("Unexpected command: " + repr(args))

    @staticmethod
    def assert_fixed_upload(args):
        assert args[args.index("--method") + 1] == "POST"
        assert args[args.index("--method") + 2].startswith(
            f"https://uploads.github.com/{candidate.RELEASE_API}/assets?name=")
        assert not any("clobber" in arg or "DELETE" in arg or "PATCH" in arg for arg in args)

    def export(self, output="export"):
        return candidate.export(self.source, self.root / "jniLibs", self.root / "prism",
                                self.root / output, self.draft, self.run)


class AndroidCandidateTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="quenderin-candidate-fixture-")
        self.addCleanup(self.temporary.cleanup)
        self.fixture = Fixture(Path(self.temporary.name))

    def reject_without_upload(self):
        with self.assertRaises((ValueError, zipfile.BadZipFile)):
            self.fixture.export()
        self.assertEqual(self.fixture.uploads, [])

    def test_happy_path_exports_only_three_named_assets_with_provenance(self):
        files = self.fixture.export()
        self.assertEqual([path.name for path in files], list(candidate.NAMES))
        self.assertEqual(self.fixture.uploads, list(candidate.NAMES))
        self.assertEqual(files[0].read_bytes(), self.fixture.bundle.read_bytes())
        self.assertEqual(files[1].read_text(), candidate.digest(files[0])[7:] + "  " + candidate.NAME + "\n")
        receipt = json.loads(files[2].read_text())
        self.assertEqual(receipt["sourceCommit"], candidate.SOURCE_SHA)
        self.assertEqual((receipt["applicationId"], receipt["versionName"], receipt["versionCode"]),
                         (candidate.PACKAGE, candidate.VERSION, candidate.VERSION_CODE))
        self.assertFalse(receipt["signed"])
        self.assertFalse(receipt["playUploadReady"])
        self.assertEqual(receipt["digest"], candidate.digest(files[0]))
        self.assertEqual(receipt["runtimeProvenance"]["prism"]["revision"], "prism-source")
        self.assertNotIn("artifact", receipt["runtimeProvenance"]["image"])
        self.assertTrue(all(timeout <= 600 for _, timeout in self.fixture.calls))

    def test_repository_must_be_exact_and_public(self):
        with self.assertRaises(ValueError):
            candidate.Draft("other/repository", self.fixture.run)
        for repository in ({"full_name": "other/repository", "private": False},
                           {"full_name": candidate.REPOSITORY, "private": True}):
            with self.subTest(repository=repository):
                self.fixture.repository = repository
                self.reject_without_upload()

    def test_release_identity_guards_prevent_uploads(self):
        original = copy.deepcopy(self.fixture.release)
        for key, value in (("id", 1), ("draft", False), ("prerelease", False),
                           ("published_at", "2026-10-20"), ("tag_name", "wrong-tag"),
                           ("target_commitish", "main"), ("target_commitish", "a" * 40),
                           ("url", "https://api.github.com/repos/other/repository/releases/418062490"),
                           ("assets", None)):
            with self.subTest(key=key, value=value):
                self.fixture.release = {**original, key: value}
                self.reject_without_upload()

    def test_wrong_source_or_modified_tracked_source_prevents_upload(self):
        self.fixture.source_sha = "a" * 40
        self.reject_without_upload()
        self.fixture.source_sha = candidate.SOURCE_SHA
        self.fixture.dirty = True
        self.reject_without_upload()

    def test_wrong_existing_tag_prevents_upload(self):
        self.fixture.tag_sha = "a" * 40
        self.reject_without_upload()

    def test_wrong_package_version_or_code_prevents_upload(self):
        original = self.fixture.gradle.read_text()
        for old, new in (("ai.quenderin.app", "wrong.package"), ("0.5.0", "0.4.0"), ("= 5", "= 4")):
            with self.subTest(field=old):
                self.fixture.gradle.write_text(original.replace(old, new))
                self.reject_without_upload()

    def test_signing_configuration_presence_is_rejected_without_reading_it(self):
        (self.fixture.source / "android/keystore.properties").touch()
        self.reject_without_upload()

    def test_oversized_or_empty_bundle_prevents_upload(self):
        for size in (0, candidate.MAX_BYTES + 1):
            with self.subTest(size=size):
                with self.fixture.bundle.open("wb") as stream:
                    stream.truncate(size)  # Sparse fixture; does not allocate 512 MiB.
                self.reject_without_upload()

    def test_malformed_or_missing_required_zip_entry_prevents_upload(self):
        self.fixture.bundle.write_bytes(b"not a ZIP")
        self.reject_without_upload()
        with zipfile.ZipFile(self.fixture.bundle, "w") as archive:
            archive.writestr("BundleConfig.pb", b"incomplete")
        self.reject_without_upload()

    def test_duplicate_zip_entry_or_symlink_bundle_prevents_upload(self):
        self.fixture.write_bundle(duplicate=True)
        self.reject_without_upload()
        real_bundle = self.fixture.root / "other.aab"
        self.fixture.bundle.rename(real_bundle)
        self.fixture.bundle.symlink_to(real_bundle)
        self.reject_without_upload()

    def test_zip_checksum_and_signature_guards_prevent_upload(self):
        data = self.fixture.bundle.read_bytes().replace(b"fixture payload", b"corrupt payload", 1)
        self.fixture.bundle.write_bytes(data)
        self.reject_without_upload()
        for entry in ("META-INF/CERT.SF", "META-INF/CERT.RSA", "meta-inf/cert.ec", "META-INF/SIG-CERT",
                      "../escape", "/absolute", "base\\unsafe"):
            with self.subTest(entry=entry):
                self.fixture.write_bundle(extra=entry)
                self.reject_without_upload()

    def test_native_package_or_provenance_failure_prevents_upload(self):
        self.fixture.fail_native = True
        self.reject_without_upload()

    def test_preexisting_asset_collision_is_checked_before_any_upload(self):
        self.fixture.release["assets"] = [{"name": candidate.NAMES[2], "state": "uploaded",
                                           "size": 1, "digest": "sha256:" + "a" * 64}]
        self.reject_without_upload()

    def test_unknown_or_duplicate_assets_are_rejected(self):
        self.fixture.release["assets"] = [{"name": "unexpected.log"}]
        self.reject_without_upload()
        self.fixture.release["assets"] = [{"name": candidate.NAME}, {"name": candidate.NAME}]
        self.reject_without_upload()

    def test_partial_upload_replay_reuses_identical_asset_and_never_overwrites(self):
        self.fixture.fail_upload = True
        with self.assertRaises(ValueError):
            self.fixture.export()
        self.assertEqual(self.fixture.uploads, [candidate.NAME])
        self.fixture.fail_upload = False
        files = [self.fixture.root / "export" / name for name in candidate.NAMES]
        self.fixture.draft.upload(files)
        self.assertEqual(self.fixture.uploads, list(candidate.NAMES))
        self.fixture.draft.upload(files)
        self.assertEqual(self.fixture.uploads, list(candidate.NAMES))

    def test_replay_rejects_same_size_different_digest_or_incomplete_asset(self):
        files = self.fixture.export()
        original = copy.deepcopy(self.fixture.release["assets"])
        for key, value in (("digest", "sha256:" + "a" * 64), ("state", "starter"), ("size", 1)):
            with self.subTest(key=key):
                self.fixture.release["assets"] = copy.deepcopy(original)
                self.fixture.release["assets"][0][key] = value
                with self.assertRaises(ValueError):
                    self.fixture.draft.upload(files)
                self.assertEqual(self.fixture.uploads, list(candidate.NAMES))

    def test_failed_remote_verification_prevents_upload(self):
        def unavailable(args, timeout=120):
            if args[0] == "gh":
                raise ValueError("Transport unavailable")
            return self.fixture.run(args, timeout)
        self.fixture.draft = candidate.Draft(candidate.REPOSITORY, unavailable)
        self.reject_without_upload()

    def test_publication_during_upload_stops_remaining_assets(self):
        self.fixture.publish_after_upload = True
        with self.assertRaises(ValueError):
            self.fixture.export()
        self.assertEqual(self.fixture.uploads, [candidate.NAME])

    def test_child_token_is_environment_only_and_process_failure_is_redacted(self):
        with patch.dict(candidate.os.environ, {"GITHUB_TOKEN": "fixture-token"}), \
                patch.object(candidate.subprocess, "run") as run:
            run.return_value.returncode = 1
            run.return_value.stderr = "fixture-token"
            with self.assertRaisesRegex(ValueError, "export stopped") as error:
                candidate.execute(["gh", "api", candidate.API])
            self.assertNotIn("fixture-token", str(error.exception))
            args, kwargs = run.call_args
            self.assertNotIn("fixture-token", repr(args))
            self.assertEqual(kwargs["env"]["GH_TOKEN"], "fixture-token")
            self.assertNotIn("GITHUB_TOKEN", kwargs["env"])
            self.assertEqual(kwargs["timeout"], 120)
            with self.assertRaises(ValueError):
                candidate.execute(["gh", "api", f"https://uploads.github.com/{candidate.RELEASE_API}/assets"])
            self.assertEqual(run.call_args.kwargs["env"]["GH_ENTERPRISE_TOKEN"], "fixture-token")


if __name__ == "__main__":
    unittest.main()

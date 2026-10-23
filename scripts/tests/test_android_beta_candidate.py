"""No-network fixtures for the one-draft Android candidate export boundary."""
from __future__ import annotations

import copy
from contextlib import redirect_stderr, redirect_stdout
from io import StringIO
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
import warnings
import xml.etree.ElementTree as ET
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import android_beta_candidate as candidate

ENVIRONMENT = {"GITHUB_REPOSITORY": candidate.REPOSITORY,
               "CANDIDATE_SOURCE_COMMIT": "b" * 40, "CANDIDATE_RELEASE_ID": "418062491",
               "CANDIDATE_VERSION_NAME": "0.6.0", "CANDIDATE_VERSION_CODE": "6"}
CANDIDATE = candidate.Candidate.from_environment(ENVIRONMENT)
OLD_SOURCE = "eecf089ff328f7303a7d4a64358252e8913e32f5"


class Fixture:
    def __init__(self, root: Path):
        self.source = root / "source"
        self.source.mkdir()
        self.gradle = self.source / "android/app/build.gradle.kts"
        self.gradle.parent.mkdir(parents=True)
        self.gradle.write_text('applicationId = "ai.quenderin.app"\nversionName = "0.6.0"\nversionCode = 6\n')
        self.bundle = self.source / "android/app/build/outputs/bundle/release/app-release.aab"
        self.bundle.parent.mkdir(parents=True)
        self.write_bundle()
        self.repository = {"full_name": candidate.REPOSITORY, "private": False}
        self.release = {"id": CANDIDATE.release_id, "draft": True, "prerelease": True,
                        "published_at": None, "tag_name": CANDIDATE.tag,
                        "target_commitish": CANDIDATE.source_sha,
                        "url": f"https://api.github.com/{CANDIDATE.release_api}", "assets": []}
        self.source_sha = CANDIDATE.source_sha
        self.origin = f"https://github.com/{candidate.REPOSITORY}.git"
        self.object_type = "commit"
        self.on_main = True
        self.committed_gradle = self.gradle.read_text()
        self.committed_signing = False
        self.tag_sha = None
        self.dirty = False
        self.fail_native = False
        self.fail_upload = False
        self.publish_after_upload = False
        self.calls = []
        self.uploads = []
        self.root = root
        self.draft = candidate.Draft(CANDIDATE, self.run)
        self.bundletool = root / "bundletool.jar"
        self.bundletool.write_bytes(b"synthetic JAR for fake Java command")
        self.manifest = ('<manifest xmlns:android="http://schemas.android.com/apk/res/android" '
                         'package="ai.quenderin.app" android:versionName="0.6.0" android:versionCode="6"/>')
        self.java_failure = False

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
                return "" if self.tag_sha is None else self.tag_sha + "\trefs/tags/" + CANDIDATE.tag + "\n"
            if "remote" in args:
                return self.origin + "\n"
            if "cat-file" in args:
                return self.object_type + "\n"
            if "merge-base" in args:
                if not self.on_main:
                    raise ValueError("Source is not reachable from origin/main")
                return ""
            if "show" in args:
                return self.committed_gradle
            if "ls-tree" in args:
                return "android/keystore.properties\n" if self.committed_signing else ""
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
            if args == ["gh", "api", CANDIDATE.release_api]:
                return json.dumps(self.release)
        elif args[0] == "java":
            if self.java_failure:
                raise ValueError("Manifest extraction failed")
            assert args == ["java", "-Xmx256m", "-jar", str(self.bundletool), "dump", "manifest",
                            "--bundle=" + str(self.bundle.resolve()), "--module=base"]
            assert timeout == 120
            return self.manifest
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
            f"https://uploads.github.com/{CANDIDATE.release_api}/assets?name=")
        assert not any("clobber" in arg or "DELETE" in arg or "PATCH" in arg for arg in args)

    def export(self, output="export"):
        return candidate.export(self.source, self.root / "jniLibs", self.root / "prism",
                                self.root / output, self.draft, self.bundletool, self.run)


class AndroidCandidateTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="quenderin-candidate-fixture-")
        self.addCleanup(self.temporary.cleanup)
        self.fixture = Fixture(Path(self.temporary.name))
        self.jar_size = patch.object(candidate, "BUNDLETOOL_SIZE", self.fixture.bundletool.stat().st_size)
        self.jar_digest = patch.object(candidate, "BUNDLETOOL_SHA256", candidate.digest(self.fixture.bundletool)[7:])
        self.jar_size.start()
        self.jar_digest.start()
        self.addCleanup(self.jar_size.stop)
        self.addCleanup(self.jar_digest.stop)

    def reject_without_upload(self):
        with self.assertRaises((ValueError, ET.ParseError, zipfile.BadZipFile)):
            self.fixture.export()
        self.assertEqual(self.fixture.uploads, [])

    def preflight_then_build(self, environment=ENVIRONMENT):
        side_effects = []
        with patch.dict(candidate.os.environ, environment, clear=True), \
                redirect_stderr(StringIO()), redirect_stdout(StringIO()):
            candidate.main(["preflight"], run=self.fixture.run)
        # Candidate checkout/build are admitted only after the production CLI gate succeeds.
        side_effects.extend(("candidate-checkout", "build"))
        return side_effects

    def reject_before_build(self, environment=ENVIRONMENT):
        with self.assertRaises(SystemExit) as error:
            self.preflight_then_build(environment)
        self.assertEqual(error.exception.code, 1)
        self.assertEqual(self.fixture.uploads, [])
        self.assertFalse((self.fixture.root / "export").exists())
        self.assertFalse(any(args[0] in (sys.executable, "java", "curl")
                             or "rev-parse" in args for args, _ in self.fixture.calls))

    def test_cli_accepts_new_reviewed_source_and_matching_draft_before_build(self):
        self.assertEqual(self.preflight_then_build(), ["candidate-checkout", "build"])

    def test_cli_invalid_inputs_stop_before_any_external_command(self):
        invalid = {"GITHUB_REPOSITORY": ("other/repository", "alikatgh/quenderin-fork"),
                   "CANDIDATE_SOURCE_COMMIT": ("", "main", "refs/heads/main", "refs/pull/1/head",
                       "b" * 39, "B" * 40, "b" * 41, "b" * 40 + "\n", "$(touch marker)", "--help"),
                   "CANDIDATE_RELEASE_ID": ("", "0", "-1", "01", "1/path", "1\n", "9" * 20),
                   "CANDIDATE_VERSION_NAME": ("", "0.6", "v0.6.0", "00.6.0", "0.6.0;touch marker"),
                   "CANDIDATE_VERSION_CODE": ("", "0", "-1", "06", "6.0", "2100000001", "6\n")}
        for key, values in invalid.items():
            for value in values:
                with self.subTest(key=key, value=value):
                    self.fixture.calls.clear()
                    self.reject_before_build({**ENVIRONMENT, key: value})
                    self.assertEqual(self.fixture.calls, [])

    def test_unreviewed_repository_commit_and_version_stop_before_checkout_build(self):
        for field, value in (("origin", "https://github.com/other/quenderin.git"),
                             ("object_type", "tag"), ("on_main", False),
                             ("committed_gradle", self.fixture.committed_gradle.replace("0.6.0", "0.5.0")),
                             ("committed_gradle", self.fixture.committed_gradle.replace("= 6", "= 5")),
                             ("committed_signing", True)):
            with self.subTest(field=field):
                original = getattr(self.fixture, field)
                setattr(self.fixture, field, value)
                self.reject_before_build()
                setattr(self.fixture, field, original)

    def test_old_draft_cannot_be_relabelled_as_new_source_before_build_or_export(self):
        self.fixture.release.update(id=418062490, target_commitish=OLD_SOURCE,
            tag_name="android-beta-0.5.0-candidate-eecf089",
            url=f"https://api.github.com/{candidate.API}/releases/418062490",
            assets=[{"name": "quenderin-android-0.5.0-5-eecf089-unsigned.aab"}])
        old_draft = copy.deepcopy(self.fixture.release)
        self.reject_before_build()
        self.reject_without_upload()
        self.assertEqual(self.fixture.release, old_draft)

    def test_matching_draft_with_branch_target_or_old_full_sha_stops_before_build(self):
        for target in ("main", OLD_SOURCE, "refs/pull/170/head"):
            with self.subTest(target=target):
                self.fixture.release["target_commitish"] = target
                self.reject_before_build()

    def test_ancestry_and_draft_are_rechecked_before_export(self):
        self.assertEqual(self.preflight_then_build(), ["candidate-checkout", "build"])
        self.fixture.on_main = False
        self.reject_without_upload()
        self.fixture.on_main = True
        self.fixture.release["target_commitish"] = OLD_SOURCE
        self.reject_without_upload()
        self.assertFalse((self.fixture.root / "export").exists())

    def test_checked_out_source_gate_prevents_build_on_wrong_head_or_dirty_source(self):
        for field, value in (("source_sha", OLD_SOURCE), ("dirty", True)):
            with self.subTest(field=field):
                original = getattr(self.fixture, field)
                setattr(self.fixture, field, value)
                with patch.dict(candidate.os.environ, ENVIRONMENT, clear=True), \
                        redirect_stderr(StringIO()), self.assertRaises(SystemExit) as error:
                    candidate.main(["preflight", "--source", str(self.fixture.source)], run=self.fixture.run)
                self.assertEqual(error.exception.code, 1)
                self.assertEqual(self.fixture.uploads, [])
                setattr(self.fixture, field, original)

    def test_happy_path_exports_only_three_named_assets_with_provenance(self):
        files = self.fixture.export()
        self.assertEqual([path.name for path in files], list(CANDIDATE.names))
        self.assertEqual(self.fixture.uploads, list(CANDIDATE.names))
        self.assertEqual(files[0].read_bytes(), self.fixture.bundle.read_bytes())
        self.assertEqual(files[1].read_text(), candidate.digest(files[0])[7:] + "  " + CANDIDATE.name + "\n")
        receipt = json.loads(files[2].read_text())
        self.assertEqual(receipt["sourceCommit"], CANDIDATE.source_sha)
        self.assertEqual((receipt["applicationId"], receipt["versionName"], receipt["versionCode"]),
                         (candidate.PACKAGE, CANDIDATE.version, CANDIDATE.version_code))
        self.assertEqual(receipt["bundleManifest"], {"applicationId": candidate.PACKAGE,
                         "versionName": CANDIDATE.version, "versionCode": CANDIDATE.version_code})
        self.assertEqual((receipt["releaseId"], receipt["releaseTag"]),
                         (CANDIDATE.release_id, CANDIDATE.tag))
        self.assertFalse(receipt["signed"])
        self.assertFalse(receipt["playUploadReady"])
        self.assertEqual(receipt["digest"], candidate.digest(files[0]))
        self.assertEqual(receipt["runtimeProvenance"]["prism"]["revision"], "prism-source")
        self.assertNotIn("artifact", receipt["runtimeProvenance"]["image"])
        self.assertTrue(all(timeout <= 600 for _, timeout in self.fixture.calls))

    def test_repository_must_be_exact_and_public(self):
        with self.assertRaises(ValueError):
            candidate.Candidate.from_environment({**ENVIRONMENT, "GITHUB_REPOSITORY": "other/repository"})
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
        self.fixture.source_sha = CANDIDATE.source_sha
        self.fixture.dirty = True
        self.reject_without_upload()

    def test_wrong_existing_tag_prevents_upload(self):
        self.fixture.tag_sha = "a" * 40
        self.reject_without_upload()

    def test_wrong_package_version_or_code_prevents_upload(self):
        original = self.fixture.gradle.read_text()
        for old, new in (("ai.quenderin.app", "wrong.package"), ("0.6.0", "0.5.0"), ("= 6", "= 5")):
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

    def test_packaged_manifest_mismatch_failure_or_unsafe_xml_prevents_staging_and_upload(self):
        original = self.fixture.manifest
        for manifest in (original.replace("ai.quenderin.app", "wrong.package"),
                         original.replace("0.6.0", "0.5.0"), original.replace('versionCode="6"', 'versionCode="5"'),
                         original.replace('versionCode="6"', 'versionCode="6" android:versionCodeMajor="1"'),
                         original.replace('android:versionName="0.6.0"', ""), "not XML",
                         "<!DOCTYPE manifest>" + original, " " * (1024 * 1024 + 1)):
            with self.subTest(manifest=manifest[:100]):
                self.fixture.manifest = manifest
                self.reject_without_upload()
                self.assertFalse((self.fixture.root / "export").exists())
        self.fixture.manifest = original
        self.fixture.java_failure = True
        self.reject_without_upload()

    def test_untrusted_manifest_tool_is_never_executed(self):
        original = self.fixture.bundletool.read_bytes()
        self.fixture.bundletool.write_bytes(b"x" * len(original))
        self.reject_without_upload()
        self.assertFalse(any(args[0] == "java" for args, _ in self.fixture.calls))

    def test_tool_download_is_fixed_bounded_digest_checked_and_never_replaced(self):
        output = self.fixture.root / "downloaded.jar"
        calls = []
        def download(args, timeout=120):
            calls.append((args, timeout))
            self.assertEqual(args[0], "curl")
            self.assertEqual(args[-1], candidate.BUNDLETOOL_URL)
            self.assertEqual(args[args.index("--retry") + 1], "0")
            self.assertEqual(args[args.index("--max-time") + 1], "120")
            self.assertEqual(args[args.index("--max-filesize") + 1], str(candidate.BUNDLETOOL_SIZE))
            self.assertEqual(args[args.index("--proto-redir") + 1], "=https")
            self.assertEqual(timeout, 150)
            Path(args[args.index("--output") + 1]).write_bytes(self.fixture.bundletool.read_bytes())
            return ""
        candidate.fetch_bundletool(output, download)
        self.assertEqual(output.read_bytes(), self.fixture.bundletool.read_bytes())
        with self.assertRaises(ValueError):
            candidate.fetch_bundletool(output, download)
        self.assertEqual(len(calls), 1)
        output.unlink()
        with patch.object(candidate, "BUNDLETOOL_SHA256", "a" * 64), self.assertRaises(ValueError):
            candidate.fetch_bundletool(output, download)

    def test_preexisting_asset_collision_is_checked_before_any_upload(self):
        self.fixture.release["assets"] = [{"name": CANDIDATE.names[2], "state": "uploaded",
                                           "size": 1, "digest": "sha256:" + "a" * 64}]
        self.reject_without_upload()

    def test_unknown_or_duplicate_assets_are_rejected(self):
        self.fixture.release["assets"] = [{"name": "unexpected.log"}]
        self.reject_without_upload()
        self.fixture.release["assets"] = [{"name": CANDIDATE.name}, {"name": CANDIDATE.name}]
        self.reject_without_upload()

    def test_partial_upload_replay_reuses_identical_asset_and_never_overwrites(self):
        self.fixture.fail_upload = True
        with self.assertRaises(ValueError):
            self.fixture.export()
        self.assertEqual(self.fixture.uploads, [CANDIDATE.name])
        self.fixture.fail_upload = False
        files = [self.fixture.root / "export" / name for name in CANDIDATE.names]
        self.fixture.draft.upload(files)
        self.assertEqual(self.fixture.uploads, list(CANDIDATE.names))
        self.fixture.draft.upload(files)
        self.assertEqual(self.fixture.uploads, list(CANDIDATE.names))

    def test_replay_rejects_same_size_different_digest_or_incomplete_asset(self):
        files = self.fixture.export()
        original = copy.deepcopy(self.fixture.release["assets"])
        for key, value in (("digest", "sha256:" + "a" * 64), ("state", "starter"), ("size", 1)):
            with self.subTest(key=key):
                self.fixture.release["assets"] = copy.deepcopy(original)
                self.fixture.release["assets"][0][key] = value
                with self.assertRaises(ValueError):
                    self.fixture.draft.upload(files)
                self.assertEqual(self.fixture.uploads, list(CANDIDATE.names))

    def test_failed_remote_verification_prevents_upload(self):
        def unavailable(args, timeout=120):
            if args[0] == "gh":
                raise ValueError("Transport unavailable")
            return self.fixture.run(args, timeout)
        self.fixture.draft = candidate.Draft(CANDIDATE, unavailable)
        self.reject_without_upload()

    def test_publication_during_upload_stops_remaining_assets(self):
        self.fixture.publish_after_upload = True
        with self.assertRaises(ValueError):
            self.fixture.export()
        self.assertEqual(self.fixture.uploads, [CANDIDATE.name])

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
                candidate.execute(["gh", "api", f"https://uploads.github.com/{CANDIDATE.release_api}/assets"])
            self.assertEqual(run.call_args.kwargs["env"]["GH_ENTERPRISE_TOKEN"], "fixture-token")


if __name__ == "__main__":
    unittest.main()

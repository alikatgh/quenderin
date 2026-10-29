"""Pure synthetic signing-boundary tests; no key, Java signing or download runs."""
import base64
import copy
from contextlib import redirect_stderr
import hashlib
import importlib.util
from io import StringIO
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import zipfile

spec = importlib.util.spec_from_file_location("sign_aab", Path(__file__).with_name("sign_aab.py"))
signer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(signer)
from scripts.tests.test_android_beta_candidate import Fixture, CANDIDATE, native_sdk


class SigningTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="quenderin-sign-fixture-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.fixture = Fixture(self.root)
        for module, name, value in (
            (signer.candidate, "BUNDLETOOL_SIZE", self.fixture.bundletool.stat().st_size),
            (signer.candidate, "BUNDLETOOL_SHA256", signer.candidate.digest(self.fixture.bundletool)[7:]),
            (native_sdk, "JNA_BYTES", self.fixture.aar.stat().st_size),
            (native_sdk, "JNA_SHA1", native_sdk.digest(self.fixture.aar, "sha1")),
            (native_sdk, "JNA_SHA256", native_sdk.digest(self.fixture.aar)),
        ):
            mocked = patch.object(module, name, value)
            mocked.start()
            self.addCleanup(mocked.stop)
        self.files = self.fixture.export()
        self.keystore = self.root / "opaque-existing-placeholder"
        self.keystore.write_bytes(b"synthetic placeholder, never passed to real keytool")
        self.environment = dict(zip(signer.KEYS, (str(self.keystore), "synthetic-alias", "dummy-store", "dummy-key")))
        mocked = patch.dict(os.environ, self.environment)
        mocked.start()
        self.addCleanup(mocked.stop)
        self.certificate = b"synthetic public certificate DER"
        mocked = patch.object(signer, "CERT_SHA256", hashlib.sha256(self.certificate).hexdigest())
        mocked.start()
        self.addCleanup(mocked.stop)
        self.calls = []
        self.tamper_payload = False
        self.wrong_signed_certificate = False
        self.verified = True

    def fake_run(self, args, *, env=None, timeout=120):
        self.calls.append((args, timeout))
        for password in ("dummy-store", "dummy-key"):
            self.assertNotIn(password, repr(args))
        self.assertFalse(any(arg in ("-tsa", "-revCheck") for arg in args))
        if args[:2] == ["keytool", "-exportcert"]:
            self.assertIn("-storepass:env", args)
            return self.certificate
        if args[:2] == ["keytool", "-printcert"]:
            cert = b"wrong" if self.wrong_signed_certificate else self.certificate
            return b"-----BEGIN CERTIFICATE-----\n" + base64.b64encode(cert) + b"\n-----END CERTIFICATE-----\n"
        if args[0] == "jarsigner" and "-verify" in args:
            return b"jar verified.\n" if self.verified else b"jar is unsigned.\n"
        if args[0] == "jarsigner":
            self.assertIn("-keypass:env", args)
            signed = Path(args[args.index("-signedjar") + 1])
            self.assertFalse(signed.exists())
            with zipfile.ZipFile(self.files[0]) as before, zipfile.ZipFile(signed, "w") as after:
                for name in before.namelist():
                    payload = before.read(name)
                    if self.tamper_payload and name.endswith(".so"):
                        payload += b"tampered"
                    after.writestr(name, payload)
                for name in ("META-INF/MANIFEST.MF", "META-INF/QUPLOAD.SF", "META-INF/QUPLOAD.RSA"):
                    after.writestr(name, b"synthetic signature metadata")
            return b"jar signed.\n"
        raise AssertionError("Unexpected synthetic command")

    def sign(self, output="signed"):
        return signer.sign(self.files[0], self.files[2], self.root / output,
                           CANDIDATE.source_sha, CANDIDATE.version, CANDIDATE.version_code,
                           signer.candidate.digest(self.files[2])[7:], self.fake_run)

    def test_exact_candidate_and_certificate_create_three_new_verified_assets(self):
        original = self.files[0].read_bytes()
        signed = self.sign()
        self.assertEqual(len(list(signed.parent.iterdir())), 3)
        receipt = json.loads(signed.with_name(signed.name + ".receipt.json").read_text())
        self.assertTrue(receipt["signed"] and receipt["payloadPreserved"] and receipt["signatureVerified"])
        self.assertFalse(receipt["uploaded"])
        self.assertEqual(receipt["unsignedDigest"], signer.candidate.digest(self.files[0]))
        self.assertEqual(receipt["digest"], signer.candidate.digest(signed))
        self.assertEqual(self.files[0].read_bytes(), original)

    def test_wrong_source_version_or_code_stops_before_key_access(self):
        for source, version, code in (("a" * 40, "0.6.0", 6), (CANDIDATE.source_sha, "0.5.0", 6),
                                      (CANDIDATE.source_sha, "0.6.0", 5)):
            with self.subTest(source=source, version=version, code=code), self.assertRaises(ValueError):
                signer.sign(self.files[0], self.files[2], self.root / "signed", source, version, code,
                            signer.candidate.digest(self.files[2])[7:], self.fake_run)
        self.assertEqual(self.calls, [])

    def test_missing_or_stale_noise_provenance_stops_before_key_access(self):
        original = json.loads(self.files[2].read_text())
        for mutation in ("missing", "stale", "wrong-bundle"):
            receipt = copy.deepcopy(original)
            remote = receipt["runtimeProvenance"]["remoteCrypto"]
            if mutation == "missing":
                del receipt["runtimeProvenance"]["remoteCrypto"]
            elif mutation == "stale":
                remote["sdkReceipt"]["sources"]["Cargo.lock"] = "f" * 64
            else:
                remote["packages"]["aab"]["digest"] = "sha256:" + "f" * 64
            self.files[2].write_text(json.dumps(receipt))
            with self.subTest(mutation=mutation), self.assertRaises((ValueError, KeyError)):
                self.sign()
        self.assertEqual(self.calls, [])

    def test_wrong_registered_certificate_stops_before_output_or_signing(self):
        with patch.object(signer, "CERT_SHA256", "f" * 64), self.assertRaises(ValueError):
            self.sign()
        self.assertFalse((self.root / "signed").exists())
        self.assertEqual(len(self.calls), 1)

    def test_wrong_github_receipt_digest_stops_before_key_access(self):
        with self.assertRaises(ValueError):
            signer.sign(self.files[0], self.files[2], self.root / "signed", CANDIDATE.source_sha,
                        CANDIDATE.version, CANDIDATE.version_code, "f" * 64, self.fake_run)
        self.assertEqual(self.calls, [])

    def test_invalid_cli_arguments_never_echo_arbitrary_values(self):
        output = StringIO()
        with redirect_stderr(output):
            self.assertEqual(signer.main(["sign", "--unrecognized", "dummy-sensitive-value"]), 1)
        self.assertNotIn("dummy-sensitive-value", output.getvalue())
        self.assertEqual(json.loads(output.getvalue())["status"], "rejected")

    def test_existing_output_is_never_overwritten(self):
        output = self.root / "signed"
        output.mkdir()
        original = output / "user-file"
        original.write_text("preserved")
        with self.assertRaises(FileExistsError):
            self.sign()
        self.assertEqual(original.read_text(), "preserved")
        self.assertFalse(any(args[0] == "jarsigner" for args, _ in self.calls))

    def test_payload_tamper_signature_failure_or_wrong_packaged_cert_never_get_receipt(self):
        for field in ("tamper_payload", "wrong_signed_certificate", "verified"):
            setattr(self, field, field != "verified")
            with self.subTest(failure=field), self.assertRaises(ValueError):
                self.sign(output=field)
            self.assertEqual(list((self.root / field).glob("*.receipt.json")), [])
            setattr(self, field, field == "verified")

    @unittest.skipUnless(signer.VARLOCK.is_file(), "Optional installed Mac Varlock 1.23.0 check")
    def test_real_pinned_varlock_validates_only_synthetic_exported_inputs(self):
        status = signer.check_tools()
        self.assertEqual(status, {"varlock1230": True, "jdkSigningTools": True, "credentialsValidated": True})
        # An arbitrary explicit schema filename must still enforce every required
        # field, rather than merely accepting inherited synthetic environment vars.
        for key in signer.KEYS:
            env = signer.varlock_environment()
            del env[key]
            with self.subTest(missing=key), self.assertRaises(ValueError):
                signer.command([str(signer.VARLOCK), "load", "--agent", "--skip-cache",
                                "--path", str(signer.SCHEMA)], env=env, timeout=30)
        # Exercise the exact run/path/injection options used by the wrapper, with
        # a presence-only child instead of accessing even a synthetic key file.
        program = "import os; assert all(k in os.environ for k in " + repr(signer.KEYS) + "); print('validated')"
        output = signer.command([str(signer.VARLOCK), "run", "--skip-cache", "--inject", "vars",
                                 "--filter", "QUENDERIN_UPLOAD_*", "--path", str(signer.SCHEMA),
                                 "--", signer.sys.executable, "-c", program],
                                env=signer.varlock_environment(), timeout=30)
        self.assertIn(b"validated", output)


if __name__ == "__main__":
    unittest.main()

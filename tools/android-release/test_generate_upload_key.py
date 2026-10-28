"""Synthetic generator boundaries; every keytool generation/export is mocked."""
import base64
from contextlib import contextmanager, redirect_stderr
import hashlib
import importlib.util
from io import StringIO
import json
import os
from pathlib import Path
import signal
import stat
import subprocess
import sys
import tempfile
import time
from types import SimpleNamespace
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("generate_upload_key", Path(__file__).with_name("generate_upload_key.py"))
generator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(generator)


class GenerationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="quenderin-generator-fixture-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.output = self.root / "new-private-output"
        self.keystore = self.output / generator.KEYSTORE_NAME
        self.password = "synthetic-confirmed-password"
        self.environment = dict(zip(generator.signing.KEYS, (
            str(self.keystore), generator.ALIAS, self.password, self.password)))
        mocked = patch.dict(os.environ, self.environment)
        mocked.start()
        self.addCleanup(mocked.stop)
        if generator.sys.platform != "darwin":
            # Synthetic generation exercises the other boundaries on hosted
            # Linux; real macOS ACL metadata has its own platform-only tests.
            acl = patch.object(generator, "require_no_acl")
            acl.start()
            self.addCleanup(acl.stop)
        self.certificate = b"synthetic public certificate DER, never real key material"
        self.calls = []
        self.fail_generation = False
        self.bad_pem = False
        self.bad_der = False

    def fake_run(self, args, *, env=None, timeout=120):
        self.calls.append((args, env, timeout))
        self.assertNotIn(self.password, repr(args))
        self.assertNotIn("-storepass", args)
        self.assertNotIn("-keypass", args)
        self.assertLessEqual(timeout, 120)
        if args == [str(generator.signing.VARLOCK), "--version"]:
            self.assertTrue(all(name not in env for name in generator.signing.KEYS))
            return b"1.23.0\n"
        if args == ["java", "--version"]:
            return b"openjdk 21.0.10 2026-01-20 LTS\n"
        if args == ["keytool", "-help"]:
            return b"keytool help\n"
        if args[:2] == ["keytool", "-genkeypair"]:
            self.assertFalse(self.keystore.exists())
            for flag, value in (("-storetype", "PKCS12"), ("-keyalg", "RSA"), ("-keysize", "3072"),
                                ("-sigalg", "SHA256withRSA"), ("-validity", "10000"),
                                ("-dname", generator.SUBJECT), ("-alias", generator.ALIAS),
                                ("-storepass:env", generator.signing.KEYS[2]),
                                ("-keypass:env", generator.signing.KEYS[3])):
                self.assertEqual(args[args.index(flag) + 1], value)
            if self.fail_generation:
                raise ValueError("A mock tool error must not expose " + self.password)
            # Deliberately opaque fake bytes. No JDK generation is invoked.
            self.keystore.write_bytes(b"synthetic non-key placeholder")
            return b""
        if args[:2] == ["keytool", "-exportcert"]:
            self.assertIn("-storepass:env", args)
            if "-file" in args:
                destination = Path(args[args.index("-file") + 1])
                self.assertFalse(destination.exists())
                with destination.open("xb") as stream:
                    stream.write(b"invalid" if self.bad_pem else b"-----BEGIN CERTIFICATE-----\n" +
                                 base64.b64encode(self.certificate) + b"\n-----END CERTIFICATE-----\n")
                return b""
            return b"different public certificate" if self.bad_der else self.certificate
        raise AssertionError("Unexpected synthetic command")

    def generate(self):
        return generator.generate(self.fake_run)

    def test_new_private_outputs_have_public_receipt_and_old_signer_pin_stays(self):
        original_pin = generator.signing.CERT_SHA256
        receipt = self.generate()
        self.assertEqual(set(path.name for path in self.output.iterdir()), {
            generator.KEYSTORE_NAME, generator.CERTIFICATE_NAME, generator.RECEIPT_NAME})
        self.assertEqual(stat.S_IMODE(self.output.stat().st_mode), 0o700)
        for path in self.output.iterdir():
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
        self.assertEqual(receipt, json.loads((self.output / generator.RECEIPT_NAME).read_text()))
        self.assertEqual(receipt["certificateSha256"], hashlib.sha256(self.certificate).hexdigest())
        self.assertTrue(receipt["generated"])
        self.assertFalse(receipt["resetRequested"] or receipt["registeredForPlay"])
        self.assertNotIn(self.password, json.dumps(receipt))
        self.assertNotIn(str(self.root), json.dumps(receipt))
        self.assertEqual(generator.signing.CERT_SHA256, original_pin)
        self.assertEqual(original_pin, "8b38f4e585883ab737f2918f4990ba401767a03937eb2a687288bde3e949cf3d")

    def test_generator_never_reads_even_synthetic_keystore_bytes(self):
        original = Path.read_bytes
        def public_only(path):
            self.assertNotEqual(path.name, generator.KEYSTORE_NAME)
            return original(path)
        with patch.object(Path, "read_bytes", public_only):
            self.generate()

    def test_existing_directory_and_contents_are_preserved_before_tool_calls(self):
        self.output.mkdir()
        original = self.output / "user-file"
        original.write_text("preserve")
        with self.assertRaises(ValueError):
            self.generate()
        self.assertEqual(original.read_text(), "preserve")
        self.assertEqual(self.calls, [])

    def test_output_symlink_and_symlink_ancestor_are_rejected(self):
        target = self.root / "actual"
        target.mkdir()
        self.output.symlink_to(target, target_is_directory=True)
        with self.assertRaises(ValueError):
            self.generate()
        nested = self.output / "nested" / generator.KEYSTORE_NAME
        with patch.dict(os.environ, {generator.signing.KEYS[0]: str(nested)}), self.assertRaises(ValueError):
            self.generate()
        self.assertEqual(list(target.iterdir()), [])
        self.assertEqual(self.calls, [])

    def test_git_repository_worktree_and_git_directory_destinations_are_rejected(self):
        for name, worktree in (("repository", False), ("worktree", True)):
            root = self.root / name
            root.mkdir()
            marker = root / ".git"
            if worktree:
                marker.write_text("gitdir: synthetic metadata only")
            else:
                marker.mkdir()
            for output in (root / "new", marker / "new"):
                with self.subTest(output=output), patch.dict(os.environ, {
                    generator.signing.KEYS[0]: str(output / generator.KEYSTORE_NAME)
                }), self.assertRaises(ValueError):
                    self.generate()
        self.assertEqual(self.calls, [])

    def test_relative_parent_traversal_wrong_name_and_missing_parent_are_rejected(self):
        for path in (Path("relative") / generator.KEYSTORE_NAME,
                     self.root / ".." / "new" / generator.KEYSTORE_NAME,
                     self.output / "different-name.p12",
                     self.root / "missing" / "new" / generator.KEYSTORE_NAME):
            with self.subTest(path=path), patch.dict(os.environ, {
                generator.signing.KEYS[0]: str(path)
            }), self.assertRaises(ValueError):
                self.generate()
        self.assertEqual(self.calls, [])

    def test_missing_short_or_different_password_and_alias_fail_without_writes(self):
        for key in generator.signing.KEYS:
            with patch.dict(os.environ, self.environment):
                del os.environ[key]
                with self.subTest(missing=key), self.assertRaises(ValueError):
                    self.generate()
        for changes in ({generator.signing.KEYS[2]: "short", generator.signing.KEYS[3]: "short"},
                        {generator.signing.KEYS[3]: "different"}, {generator.signing.KEYS[1]: "other-alias"}):
            with patch.dict(os.environ, changes), self.assertRaises(ValueError):
                self.generate()
        self.assertFalse(self.output.exists())
        self.assertEqual(self.calls, [])

    def test_wrong_tool_version_never_creates_directory(self):
        def wrong_version(args, **kwargs):
            if args == ["java", "--version"]:
                return b"openjdk 17.0.2\n"
            return self.fake_run(args, **kwargs)
        with self.assertRaises(ValueError):
            generator.generate(wrong_version)
        self.assertFalse(self.output.exists())

    def test_cancelled_tool_check_cannot_continue_with_another_subprocess(self):
        calls = []
        def cancelled(args, **_kwargs):
            calls.append(args)
            raise generator.CommandCancelled()
        with self.assertRaises(generator.CommandCancelled):
            generator.check_tools(cancelled)
        self.assertEqual(len(calls), 1)

    def test_keytool_failure_preserves_incomplete_directory_without_receipt(self):
        self.fail_generation = True
        with self.assertRaises(ValueError):
            self.generate()
        self.assertTrue(self.output.is_dir())
        self.assertEqual(list(self.output.iterdir()), [])

    def test_symlink_hardlink_or_public_permissions_never_reach_certificate_export(self):
        original = self.root / "synthetic-original"
        original.write_bytes(b"preserve synthetic placeholder")
        for mode in ("symlink", "hardlink", "public"):
            self.output = self.root / mode
            self.keystore = self.output / generator.KEYSTORE_NAME
            def altered(args, **kwargs):
                if args[:2] == ["keytool", "-genkeypair"]:
                    if mode == "symlink":
                        self.keystore.symlink_to(original)
                    elif mode == "hardlink":
                        os.link(original, self.keystore)
                    else:
                        self.keystore.write_bytes(b"synthetic placeholder")
                        self.keystore.chmod(0o644)
                    return b""
                return self.fake_run(args, **kwargs)
            with patch.dict(os.environ, {generator.signing.KEYS[0]: str(self.keystore)}), \
                 self.subTest(mode=mode), self.assertRaises(ValueError):
                generator.generate(altered)
            self.assertFalse((self.output / generator.CERTIFICATE_NAME).exists())
            self.assertFalse((self.output / generator.RECEIPT_NAME).exists())
        self.assertEqual(original.read_bytes(), b"preserve synthetic placeholder")

    def test_invalid_or_different_public_certificate_has_no_success_receipt(self):
        for field in ("bad_pem", "bad_der"):
            self.output = self.root / field
            self.keystore = self.output / generator.KEYSTORE_NAME
            with patch.dict(os.environ, {generator.signing.KEYS[0]: str(self.keystore)}):
                setattr(self, field, True)
                with self.subTest(field=field), self.assertRaises(ValueError):
                    self.generate()
                self.assertFalse((self.output / generator.RECEIPT_NAME).exists())
                self.assertTrue(self.keystore.is_file())
                setattr(self, field, False)

    def test_umask_is_restored_on_success(self):
        previous = os.umask(0o022)
        try:
            self.generate()
            self.assertEqual(os.umask(0o022), 0o022)
        finally:
            os.umask(previous)

    def test_umask_is_restored_on_failure(self):
        self.fail_generation = True
        previous = os.umask(0o022)
        try:
            with self.assertRaises(ValueError):
                self.generate()
            self.assertEqual(os.umask(0o022), 0o022)
        finally:
            os.umask(previous)

    def test_noninteractive_and_bad_cli_arguments_are_status_only(self):
        for argv in (["generate"], ["generate", "--unrecognized", self.password]):
            output = StringIO()
            with patch.object(generator.sys.stdin, "isatty", return_value=False), redirect_stderr(output):
                self.assertEqual(generator.main(argv), 1)
            self.assertNotIn(self.password, output.getvalue())
            self.assertEqual(json.loads(output.getvalue())["status"], "rejected")
            self.assertFalse(json.loads(output.getvalue())["privateOutputMayExist"])
        self.assertEqual(self.calls, [])

    def test_internal_tool_failure_never_prints_tool_error_or_password(self):
        output = StringIO()
        with patch.object(generator, "generate", side_effect=ValueError(self.password)), redirect_stderr(output):
            self.assertEqual(generator.main(["_generate"]), 1)
        self.assertNotIn(self.password, output.getvalue())

    def test_outer_terminal_flow_uses_exact_varlock_schema_and_injection(self):
        calls = []
        def wrapper(args, **kwargs):
            calls.append((args, kwargs))
            if args[-1] == "--version":
                return b"1.23.0\n"
            self.assertIn("--skip-cache", args)
            self.assertEqual(args[args.index("--inject") + 1], "vars")
            self.assertEqual(args[args.index("--filter") + 1], "QUENDERIN_UPLOAD_*")
            self.assertEqual(args[args.index("--path") + 1], str(generator.signing.SCHEMA))
            self.assertEqual(args[-1], "_generate")
            self.assertNotIn(self.password, repr(args))
            return b"arbitrary child output is never forwarded"
        from contextlib import redirect_stdout
        output = StringIO()
        with patch.object(generator.sys.stdin, "isatty", return_value=True), \
             patch.object(generator.sys.stdout, "isatty", return_value=True), \
             patch.object(generator, "command", side_effect=wrapper), redirect_stdout(output):
            # redirect_stdout changes the object queried for isatty.
            with patch.object(output, "isatty", return_value=True):
                self.assertEqual(generator.main(["generate"]), 0)
        self.assertEqual(len(calls), 2)
        self.assertNotIn("arbitrary", output.getvalue())
        self.assertTrue(json.loads(output.getvalue())["generated"])

    @unittest.skipUnless(sys.platform == "darwin", "macOS extended ACL regression")
    def test_inherited_acl_grants_fail_before_private_key_generation(self):
        parent = self.root / "acl-parent"
        parent.mkdir(mode=0o700)
        subprocess.run(["/bin/chmod", "+a", "everyone allow read,write,execute,file_inherit,directory_inherit", str(parent)],
                       check=True, capture_output=True)
        self.output = parent / "new-output"
        self.keystore = self.output / generator.KEYSTORE_NAME
        with patch.dict(os.environ, {generator.signing.KEYS[0]: str(self.keystore)}), self.assertRaises(ValueError):
            self.generate()
        self.assertEqual(stat.S_IMODE(self.output.stat().st_mode), 0o700)
        self.assertFalse(self.keystore.exists())
        self.assertFalse(any(args[:2] == ["keytool", "-genkeypair"] for args, _, _ in self.calls))

    @unittest.skipUnless(sys.platform == "darwin", "macOS extended ACL regression")
    def test_acl_grants_on_mode_0600_file_are_rejected_and_key_is_preserved(self):
        def added_acl(args, **kwargs):
            result = self.fake_run(args, **kwargs)
            if args[:2] == ["keytool", "-genkeypair"]:
                subprocess.run(["/bin/chmod", "+a", "everyone allow read,write", str(self.keystore)],
                               check=True, capture_output=True)
            return result
        with self.assertRaises(ValueError):
            generator.generate(added_acl)
        self.assertEqual(stat.S_IMODE(self.keystore.stat().st_mode), 0o600)
        self.assertTrue(self.keystore.is_file())
        self.assertFalse((self.output / generator.RECEIPT_NAME).exists())

    def test_ancestor_symlink_swap_after_initial_validation_cannot_create_in_git(self):
        parent = self.root / "safe-parent"
        parent.mkdir()
        repository = self.root / "repository"
        repository.mkdir()
        (repository / ".git").mkdir()
        self.output = parent / "new-output"
        self.keystore = self.output / generator.KEYSTORE_NAME
        def swap(args, **kwargs):
            result = self.fake_run(args, **kwargs)
            if args == ["keytool", "-help"]:
                parent.rename(self.root / "original-parent")
                parent.symlink_to(repository, target_is_directory=True)
            return result
        with patch.dict(os.environ, {generator.signing.KEYS[0]: str(self.keystore)}), self.assertRaises((OSError, ValueError)):
            generator.generate(swap)
        self.assertFalse((repository / "new-output").exists())
        self.assertFalse(any(args[:2] == ["keytool", "-genkeypair"] for args, _, _ in self.calls))

    def test_mid_generation_ancestor_swap_cannot_redirect_relative_keytool_write(self):
        parent = self.root / "safe-parent"
        parent.mkdir()
        original_parent = self.root / "original-parent"
        repository = self.root / "repository"
        repository.mkdir()
        (repository / ".git").mkdir()
        self.output = parent / "new-output"
        self.keystore = self.output / generator.KEYSTORE_NAME
        def swap(args, **kwargs):
            if args[:2] == ["keytool", "-genkeypair"]:
                parent.rename(original_parent)
                parent.symlink_to(repository, target_is_directory=True)
                key = Path(args[args.index("-keystore") + 1])
                self.assertEqual(key, Path(generator.KEYSTORE_NAME))
                key.write_bytes(b"preserved synthetic generated key placeholder")
                return b""
            return self.fake_run(args, **kwargs)
        with patch.dict(os.environ, {generator.signing.KEYS[0]: str(self.keystore)}), self.assertRaises(ValueError):
            generator.generate(swap)
        self.assertFalse((repository / "new-output").exists())
        preserved = original_parent / "new-output" / generator.KEYSTORE_NAME
        self.assertEqual(preserved.read_bytes(), b"preserved synthetic generated key placeholder")

    def test_public_export_and_receipt_failures_preserve_generated_key(self):
        for phase in ("pem", "der", "receipt"):
            self.output = self.root / phase
            self.keystore = self.output / generator.KEYSTORE_NAME
            def fail_export(args, **kwargs):
                if args[:2] == ["keytool", "-exportcert"]:
                    if (phase == "pem" and "-file" in args) or (phase == "der" and "-file" not in args):
                        raise ValueError("Synthetic export failure")
                return self.fake_run(args, **kwargs)
            with patch.dict(os.environ, {generator.signing.KEYS[0]: str(self.keystore)}):
                if phase == "receipt":
                    with patch.object(generator.json, "dumps", side_effect=ValueError("Synthetic receipt failure")), \
                         self.assertRaises(ValueError):
                        generator.generate(fail_export)
                else:
                    with self.assertRaises(ValueError):
                        generator.generate(fail_export)
            self.assertEqual(self.keystore.read_bytes(), b"synthetic non-key placeholder")
            self.assertFalse((self.output / generator.RECEIPT_NAME).exists())
            with patch.dict(os.environ, {generator.signing.KEYS[0]: str(self.keystore)}), self.assertRaises(ValueError):
                generator.generate(fail_export)  # Existing partial output cannot be replaced.

    def test_receipt_io_failure_preserves_key_and_partial_public_file(self):
        with patch.object(generator.os, "fsync", side_effect=OSError("Synthetic disk failure")), self.assertRaises(OSError):
            self.generate()
        self.assertEqual(self.keystore.read_bytes(), b"synthetic non-key placeholder")
        self.assertTrue((self.output / generator.RECEIPT_NAME).is_file())
        before = self.keystore.stat()
        with self.assertRaises(ValueError):
            self.generate()
        self.assertEqual(self.keystore.stat().st_ino, before.st_ino)

    def test_inner_failures_report_preserved_output_recovery_without_private_values(self):
        original_generate = generator.generate
        for phase in ("pem", "der", "receipt", "receipt-io"):
            self.output = self.root / phase
            self.keystore = self.output / generator.KEYSTORE_NAME
            def fail_export(args, **kwargs):
                if args[:2] == ["keytool", "-exportcert"]:
                    if (phase == "pem" and "-file" in args) or (phase == "der" and "-file" not in args):
                        raise ValueError("Synthetic failure contains " + self.password)
                return self.fake_run(args, **kwargs)
            def mocked_generate(**kwargs):
                return original_generate(run=fail_export, **kwargs)
            output = StringIO()
            with patch.dict(os.environ, {generator.signing.KEYS[0]: str(self.keystore)}), \
                 patch.object(generator, "generate", side_effect=mocked_generate), redirect_stderr(output):
                if phase == "receipt":
                    with patch.object(generator.json, "dumps", side_effect=ValueError(self.password)):
                        result = generator.main(["_generate"])
                elif phase == "receipt-io":
                    with patch.object(generator.os, "fsync", side_effect=OSError(self.password)):
                        result = generator.main(["_generate"])
                else:
                    result = generator.main(["_generate"])
            self.assertEqual(result, 1)
            status = json.loads(output.getvalue())
            self.assertEqual(status["status"], "preserved_output_requires_recovery")
            self.assertTrue(status["privateOutputMayExist"])
            self.assertNotIn(self.password, output.getvalue())
            self.assertNotIn(str(self.root), output.getvalue())
            self.assertEqual(self.keystore.read_bytes(), b"synthetic non-key placeholder")

    def test_outer_dispatch_failure_reports_possible_output_when_child_cannot_report(self):
        def stopped(args, **_kwargs):
            if args[-1] == "--version":
                return b"1.23.0\n"
            raise generator.CommandCancelled()
        output = StringIO()
        with patch.object(generator.sys.stdin, "isatty", return_value=True), \
             patch.object(generator.sys.stdout, "isatty", return_value=True), \
             patch.object(generator, "command", side_effect=stopped), redirect_stderr(output):
            self.assertEqual(generator.main(["generate"]), 1)
        self.assertEqual(json.loads(output.getvalue())["status"], "preserved_output_requires_recovery")
        self.assertTrue(json.loads(output.getvalue())["privateOutputMayExist"])
        self.assertFalse(self.output.exists())  # Conservative, not a claim that creation completed.


class ACLBoundaryTests(unittest.TestCase):
    def test_real_acl_guard_fails_closed_on_non_macos(self):
        with patch.object(generator, "sys", SimpleNamespace(platform="linux")), \
             patch.object(generator.ctypes, "CDLL") as native_acl:
            with self.assertRaisesRegex(ValueError, "macOS ACL validation is required"):
                generator.require_no_acl(-1)
        native_acl.assert_not_called()

    def test_non_macos_synthetic_generation_reaches_receipt_without_native_acl(self):
        original_acl = generator.require_no_acl
        with patch.object(generator, "sys", SimpleNamespace(platform="linux")), \
             patch.object(generator.ctypes, "CDLL") as native_acl:
            result = unittest.TestResult()
            GenerationTests("test_new_private_outputs_have_public_receipt_and_old_signer_pin_stays").run(result)
        self.assertEqual(result.testsRun, 1)
        self.assertEqual(result.errors, [])
        self.assertEqual(result.failures, [])
        native_acl.assert_not_called()
        self.assertIs(generator.require_no_acl, original_acl)


class ProcessSupervisionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="quenderin-process-fixture-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()

    @contextmanager
    def cancellation_after_readiness(self, ready):
        """Hold Popen's return until the bounded fixture startup handshake.

        command() starts its cancellation deadline after this handoff, so a slow
        interpreter/import cannot consume the time meant to exercise cleanup.
        Cleanup here runs after the late-marker assertion, preserving the causal
        regression against supervision that leaves descendants working.
        """
        processes = []
        real_popen = subprocess.Popen
        def observed(*args, **kwargs):
            process = real_popen(*args, **kwargs)
            processes.append(process)
            startup_deadline = time.monotonic() + 10
            while not ready.exists():
                if process.poll() is not None:
                    self.fail("Synthetic supervisor exited before its readiness handshake")
                if time.monotonic() >= startup_deadline:
                    self.fail("Synthetic descendant readiness exceeded the 10-second startup bound")
                time.sleep(0.01)
            return process
        try:
            with patch.object(generator.subprocess, "Popen", side_effect=observed):
                yield processes
        finally:
            for process in processes:
                try:
                    os.killpg(process.pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
                try:
                    process.communicate(timeout=3)
                except subprocess.TimeoutExpired:
                    pass
                finally:
                    try:
                        os.killpg(process.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    process.communicate(timeout=3)

    def test_timeout_stops_term_ignoring_descendant_and_reaps_direct_child(self):
        sentinel = self.root / "late-write"
        ready = self.root / "ready"
        leaf = ("import signal,time; from pathlib import Path; signal.signal(signal.SIGTERM,signal.SIG_IGN); "
                "Path(" + repr(str(ready)) + ").write_text('ready'); time.sleep(1.4); "
                "Path(" + repr(str(sentinel)) + ").write_text('must not happen')")
        parent = "import subprocess,sys,time; subprocess.Popen([sys.executable,'-B','-c'," + repr(leaf) + "]); time.sleep(10)"
        with self.cancellation_after_readiness(ready) as processes:
            with self.assertRaises(subprocess.TimeoutExpired):
                generator.command([sys.executable, "-B", "-c", parent], timeout=0.3, terminate_grace=0.1)
            self.assertIsNotNone(processes[0].poll())
            self.assertTrue(ready.exists(), "The descendant must have started for this regression to prove termination")
            time.sleep(1.5)
            self.assertFalse(sentinel.exists())

    def test_outer_timeout_lets_inner_supervisor_stop_its_separate_leaf_group(self):
        sentinel = self.root / "late-nested-write"
        ready = self.root / "ready"
        leaf = ("import signal,time; from pathlib import Path; signal.signal(signal.SIGTERM,signal.SIG_IGN); "
                "Path(" + repr(str(ready)) + ").write_text('ready'); time.sleep(2); "
                "Path(" + repr(str(sentinel)) + ").write_text('must not happen')")
        inner = ("import runpy,sys; g=runpy.run_path(" + repr(str(Path(generator.__file__).resolve())) + "); "
                 "g['command']([sys.executable,'-B','-c'," + repr(leaf) + "], timeout=10)")
        # Deliberately exceed the cancellation interval during startup: the ready
        # handshake, rather than interpreter scheduling, must start that clock.
        outer = "import subprocess,sys,time; time.sleep(0.7); subprocess.Popen([sys.executable,'-B','-c'," + repr(inner) + "]); time.sleep(10)"
        with self.cancellation_after_readiness(ready):
            with self.assertRaises(subprocess.TimeoutExpired):
                generator.command([sys.executable, "-B", "-c", outer], timeout=0.4, terminate_grace=3)
            self.assertTrue(ready.exists(), "The separate leaf group must start before cancellation is exercised")
            time.sleep(2.1)
            self.assertFalse(sentinel.exists())

    def test_cancellation_during_spawn_handoff_stops_child_before_rejection_returns(self):
        sentinel = self.root / "late-handoff-write"
        ready = self.root / "handoff-started"
        leaf = ("import signal,time; from pathlib import Path; signal.signal(signal.SIGTERM,signal.SIG_IGN); "
                "time.sleep(3.5); Path(" + repr(str(sentinel)) + ").write_text('must not happen')")
        inner = ("import runpy,sys,time; from pathlib import Path\n"
                 "g=runpy.run_path(" + repr(str(Path(generator.__file__).resolve())) + ")\n"
                 "real_popen=g['subprocess'].Popen\n"
                 "def delayed_popen(*args,**kwargs):\n"
                 " p=real_popen(*args,**kwargs)\n"
                 " Path(" + repr(str(ready)) + ").write_text('child created before PID handoff')\n"
                 " time.sleep(2)\n"
                 " return p\n"
                 "g['subprocess'].Popen=delayed_popen\n"
                 "g['command']([sys.executable,'-B','-c'," + repr(leaf) + "],timeout=10,terminate_grace=0.1)\n")
        outer = "import subprocess,sys,time; subprocess.Popen([sys.executable,'-B','-c'," + repr(inner) + "]); time.sleep(10)"
        with self.cancellation_after_readiness(ready):
            with self.assertRaises(subprocess.TimeoutExpired):
                generator.command([sys.executable, "-B", "-c", outer], timeout=0.5, terminate_grace=4)
            self.assertTrue(ready.exists(), "Cancellation must hit after the real child was created")
            time.sleep(3.6)
            self.assertFalse(sentinel.exists())


if __name__ == "__main__":
    unittest.main()

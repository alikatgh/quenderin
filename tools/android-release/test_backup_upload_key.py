#!/usr/bin/env python3
"""Synthetic-only portable backup checks; never reads production signing inputs."""
import base64
import hashlib
import io
import json
import os
from pathlib import Path
import pty
import re
import select
import signal
import stat
import subprocess
import sys
import tarfile
import tempfile
import time
import traceback
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent))
import backup_upload_key as backup

TEST_ROOT = Path(os.environ.get("QUENDERIN_BACKUP_TEST_ROOT", "/private/tmp")).resolve()
SYNTHETIC_PASSWORD = "synthetic-recovery-fixture-2026"


def fixtures():
    der = b"synthetic public certificate bytes"
    digest = hashlib.sha256(der).hexdigest()
    files = {backup.KEYSTORE: b"synthetic already-encrypted PKCS12 bytes",
             backup.CERTIFICATE: b"-----BEGIN CERTIFICATE-----\n" + base64.b64encode(der) + b"\n-----END CERTIFICATE-----\n",
             backup.RECEIPT: backup.json_bytes({"schemaVersion": 1, "applicationId": "ai.quenderin.app",
                "purpose": "upload-key-reset", "generated": True, "certificateSha256": digest,
                "keystoreFile": backup.KEYSTORE, "publicCertificateFile": backup.CERTIFICATE})}
    credentials = {"schemaVersion": 1, "alias": backup.existing.ALIAS,
                   "storePassword": SYNTHETIC_PASSWORD, "keyPassword": SYNTHETIC_PASSWORD}
    return files, credentials, digest


def mutated_archive(data, mutate):
    entries = []
    with tarfile.open(fileobj=io.BytesIO(data), mode="r:") as archive:
        for entry in archive:
            entries.append((entry, archive.extractfile(entry).read()))
    entries = mutate(entries)
    result = io.BytesIO()
    with tarfile.open(fileobj=result, mode="w", format=tarfile.USTAR_FORMAT) as archive:
        for entry, content in entries:
            entry.size = len(content)
            archive.addfile(entry, io.BytesIO(content))
    return result.getvalue()


def private_write(path, value):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "wb") as stream:
        stream.write(value)


def run_private_pty(action, *, passphrase=SYNTHETIC_PASSWORD, timeout=90):
    """Drive only synthetic age prompts. Captured TTY text is never emitted."""
    pid, terminal = pty.fork()
    if pid == 0:
        try:
            action()
            os.write(1, b"SYNTHETIC_CHECK_OK\n")
            os._exit(0)
        except BaseException as error:
            frames = traceback.extract_tb(error.__traceback__)
            location = frames[-1].name + ":" + str(frames[-1].lineno) if frames else "unknown"
            os.write(1, ("SYNTHETIC_REASON:" + type(error).__name__ + ":" + location + "\n").encode())
            os.write(1, b"SYNTHETIC_CHECK_FAILED\n")
            os._exit(1)
    collected = b""
    pending = b""
    deadline = time.monotonic() + timeout
    status = None
    try:
        while time.monotonic() < deadline:
            ready, _, _ = select.select([terminal], [], [], 0.1)
            if ready:
                try:
                    chunk = os.read(terminal, 8192)
                except OSError:
                    chunk = b""
                if chunk:
                    collected += chunk
                    pending += chunk
                    if len(collected) > 64 * 1024:
                        raise AssertionError("Synthetic terminal output exceeded bound")
                    while match := re.search(rb"(?:Enter|Confirm) (?:backup )?passphrase[^:\r\n]*:", pending):
                        pending = pending[match.end():]
                        os.write(terminal, passphrase.encode() + b"\n")
                else:
                    break
            completed, child_status = os.waitpid(pid, os.WNOHANG)
            if completed:
                status = child_status
                # Drain the final status marker without ever echoing terminal text.
                while select.select([terminal], [], [], 0)[0]:
                    try:
                        chunk = os.read(terminal, 8192)
                    except OSError:
                        break
                    if not chunk:
                        break
                    collected += chunk
                break
        if status is None:
            # PTY EOF can arrive just before the child's exit becomes waitable.
            # Honor the actual deadline instead of treating that short race as
            # a timeout and terminating a successful authentication rejection.
            while time.monotonic() < deadline:
                completed, child_status = os.waitpid(pid, os.WNOHANG)
                if completed:
                    status = child_status
                    break
                time.sleep(0.01)
            if status is None:
                os.kill(pid, 15)
                stop_deadline = time.monotonic() + 3
                while time.monotonic() < stop_deadline:
                    completed, _child_status = os.waitpid(pid, os.WNOHANG)
                    if completed:
                        break
                    time.sleep(0.01)
                else:
                    os.kill(pid, 9)
                    os.waitpid(pid, 0)
                raise AssertionError("Synthetic private operation timed out")
        if status != 0 or b"SYNTHETIC_CHECK_OK" not in collected:
            reason = re.search(rb"SYNTHETIC_REASON:([A-Za-z0-9_:]+)", collected)
            raise AssertionError("Synthetic private operation failed" + (": " + reason[1].decode() if reason else ""))
    finally:
        os.close(terminal)


class ArchiveTests(unittest.TestCase):
    def setUp(self):
        self.files, self.credentials, self.digest = fixtures()
        self.archive = backup.make_archive(self.files, self.credentials, self.digest)

    def test_round_trip_has_actual_portable_credentials(self):
        files, credentials = backup.parse_archive(self.archive, self.digest)
        self.assertEqual(credentials, self.credentials)
        self.assertEqual({name: files[name] for name in self.files}, self.files)

    def test_wrong_certificate_and_receipt_purpose_rejected(self):
        with self.assertRaises(ValueError):
            backup.parse_archive(self.archive, "f" * 64)
        self.files[backup.RECEIPT] = self.files[backup.RECEIPT].replace(b"upload-key-reset", b"other-purpose")
        with self.assertRaises(ValueError):
            backup.make_archive(self.files, self.credentials, self.digest)

    def test_missing_duplicate_and_traversal_members_rejected(self):
        for mutate in (lambda entries: entries[:-1], lambda entries: entries + entries[:1]):
            with self.assertRaises(ValueError):
                backup.parse_archive(mutated_archive(self.archive, mutate), self.digest)
        def traversal(entries):
            entries[0][0].name = "../outside"
            return entries
        with self.assertRaises(ValueError):
            backup.parse_archive(mutated_archive(self.archive, traversal), self.digest)

    def test_symlink_and_extension_headers_rejected(self):
        def symlink(entries):
            entries[0][0].type = tarfile.SYMTYPE
            entries[0][0].linkname = "outside"
            return entries
        with self.assertRaises(ValueError):
            backup.parse_archive(mutated_archive(self.archive, symlink), self.digest)
        extension = tarfile.TarInfo("././@LongLink")
        extension.type = tarfile.GNUTYPE_LONGNAME
        extension.mode = 0o600
        extension.size = 1
        hidden_header = extension.tobuf(format=tarfile.USTAR_FORMAT) + b"x" + b"\0" * 511
        with self.assertRaises(ValueError):
            backup.parse_archive(hidden_header + self.archive, self.digest)

    def test_tampered_truncated_oversized_and_trailing_data_rejected(self):
        for data in (self.archive[:100], self.archive[:-512] + b"x" * 512,
                     self.archive + b"x" * 512, b"x" * (backup.MAX_ARCHIVE + 1)):
            with self.assertRaises((ValueError, tarfile.TarError)):
                backup.parse_archive(data, self.digest)
        changed = bytearray(self.archive)
        changed[512] ^= 1
        with self.assertRaises(ValueError):
            backup.parse_archive(bytes(changed), self.digest)

    def test_duplicate_json_fields_rejected(self):
        with self.assertRaises(ValueError):
            backup.strict_json(b'{"x":1,"x":2}')

    def test_credentials_require_exact_canonical_path_and_alias(self):
        env = dict(zip(backup.KEYS, (str(backup.SOURCE / backup.KEYSTORE), backup.existing.ALIAS,
                                    SYNTHETIC_PASSWORD, SYNTHETIC_PASSWORD)))
        self.assertEqual(backup.portable_credentials(env), self.credentials)
        for key, value in ((backup.KEYS[0], "/somewhere/else.p12"), (backup.KEYS[1], "wrong-alias")):
            with self.assertRaises(ValueError):
                backup.portable_credentials({**env, key: value})

    def test_age_environment_never_contains_signing_credentials(self):
        with patch.dict(os.environ, {name: SYNTHETIC_PASSWORD for name in backup.KEYS}):
            self.assertTrue(set(backup.KEYS).isdisjoint(backup.environment()))

    def test_non_tty_rejected_before_secret_or_tool_access(self):
        with patch.object(sys.stdin, "isatty", return_value=False), patch.object(backup.existing, "command") as run:
            with self.assertRaises(ValueError):
                backup.bootstrap()
            run.assert_not_called()
        wrapper = Path(backup.__file__).with_name("backup-with-prompts.zsh")
        result = subprocess.run(["zsh", str(wrapper)], stdin=subprocess.DEVNULL, capture_output=True)
        self.assertEqual(result.returncode, 2)
        self.assertEqual(json.loads(result.stderr)["status"], "interactive_terminal_required")

    def test_status_drops_arbitrary_strings_and_unverified_claims(self):
        self.assertEqual(backup.safe_report({"backupPath": SYNTHETIC_PASSWORD, "restoreVerified": True})["status"], "rejected")
        valid_path = str(backup.DESTINATION / ("quenderin-upload-key-20261102T000000Z-" + "a" * 16 + ".tar.age"))
        report = backup.safe_report({"backupPath": valid_path, "restoreVerified": True, "sha256": "a" * 64, "size": 50})
        self.assertFalse(report["restoreVerified"])
        self.assertNotIn(SYNTHETIC_PASSWORD, json.dumps(report))


@unittest.skipUnless(sys.platform == "darwin", "macOS ACL enforcement is required")
class FilesystemTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="portable-unit-", dir=TEST_ROOT)
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.source = self.root / "source"
        self.source.mkdir(mode=0o700)
        self.destination = self.root / "backups"
        self.files, self.credentials, self.digest = fixtures()
        for name, value in self.files.items():
            private_write(self.source / name, value)
        self.env = dict(zip(backup.KEYS, (str(self.source / backup.KEYSTORE), backup.existing.ALIAS,
                                       SYNTHETIC_PASSWORD, SYNTHETIC_PASSWORD)))

    def test_symlink_hardlink_and_loose_permissions_rejected(self):
        with backup.anchored_directory(self.source) as (fd, _verify):
            path = self.source / backup.KEYSTORE
            path.chmod(0o644)
            with self.assertRaises(ValueError):
                backup.read_private(fd, backup.KEYSTORE, backup.MAX_FILE)
            path.chmod(0o600)
            os.link(path, self.source / "extra-link")
            with self.assertRaises(ValueError):
                backup.read_private(fd, backup.KEYSTORE, backup.MAX_FILE)
        link = self.root / "directory-link"
        link.symlink_to(self.source)
        with self.assertRaises(OSError):
            with backup.anchored_directory(link):
                self.fail("Symlink unexpectedly accepted")

    def test_backup_exclusive_private_and_originals_unchanged(self):
        original = {name: hashlib.sha256(value).hexdigest() for name, value in self.files.items()}
        state = {}
        def fake_age(args, *, data=None, output=None, input_fd=None, **_kwargs):
            if output is not None:
                state["archive"] = data
                os.write(output, b"synthetic age encrypted ciphertext")
            else:
                return state["archive"]
        with patch.dict(os.environ, self.env), patch.object(sys.stdin, "isatty", return_value=True), \
             patch.object(backup, "check_tools"), patch.object(backup, "age_command", side_effect=fake_age), \
             patch.object(backup, "verify_restored") as verify, patch.object(backup.secrets, "token_hex", return_value="a" * 16):
            result = backup.backup(source=self.source, destination=self.destination, expected=self.digest)
            self.assertTrue(result["restoreVerified"])
            verify.assert_called_once()
            output = Path(result["backupPath"])
            self.assertEqual(stat.S_IMODE(output.stat().st_mode), 0o600)
            self.assertEqual(stat.S_IMODE(self.destination.stat().st_mode), 0o700)
            self.assertEqual(hashlib.sha256(output.read_bytes()).hexdigest(), result["sha256"])
            with self.assertRaises(FileExistsError):
                backup.backup(source=self.source, destination=self.destination, expected=self.digest)
            self.assertEqual(output.read_bytes(), b"synthetic age encrypted ciphertext")
        self.assertEqual({name: hashlib.sha256((self.source / name).read_bytes()).hexdigest() for name in self.files}, original)
        self.assertEqual(set(self.source.iterdir()), {self.source / name for name in self.files})

    def test_failed_restore_preserves_only_private_encrypted_output(self):
        progress = {}
        def failing_age(args, *, output=None, **_kwargs):
            if output is not None:
                os.write(output, b"synthetic encrypted data")
            else:
                raise ValueError("Synthetic authentication rejection")
        with patch.dict(os.environ, self.env), patch.object(sys.stdin, "isatty", return_value=True), \
             patch.object(backup, "check_tools"), patch.object(backup, "age_command", side_effect=failing_age):
            with self.assertRaises(ValueError):
                backup.backup(source=self.source, destination=self.destination, expected=self.digest, progress=progress)
        self.assertEqual(len(list(self.destination.iterdir())), 1)
        self.assertEqual(Path(progress["backupPath"]).suffix, ".age")
        self.assertNotIn("restoreVerified", progress)
        self.assertEqual(set(self.root.iterdir()), {self.source, self.destination})


class BootstrapSupervisionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="portable-supervisor-", dir=TEST_ROOT)
        self.schema = Path(self.temporary.name) / "synthetic.schema"
        private_write(self.schema, b"nonsecret synthetic metadata fixture\n")

    def tearDown(self):
        self.temporary.cleanup()

    def invoke(self, *, signum=None, during_spawn=False, retained_pipes=False, parent_exited=False):
        class Process:
            def __init__(self, _args, **kwargs):
                self.returncode = None
                self.stdout, self.stderr = io.BytesIO(), io.BytesIO()
                self.calls, self.timeouts, self.terminated, self.killed = 0, [], False, False
                self.wait_timeout = None
                self.owner = kwargs["env"][backup.SUPERVISOR_PID]
                if during_spawn:
                    signal.raise_signal(signum)

            def poll(self):
                return self.returncode

            def communicate(self, timeout):
                self.calls += 1
                self.timeouts.append(timeout)
                if self.calls == 1 and signum is not None and not during_spawn:
                    signal.raise_signal(signum)
                if retained_pipes or (self.calls == 1 and signum is not None and not during_spawn):
                    raise subprocess.TimeoutExpired("synthetic supervisor", timeout)
                return b"", b""

            def terminate(self):
                self.terminated = True
                self.returncode = -15

            def kill(self):
                self.killed = True
                self.returncode = -9

            def wait(self, timeout):
                self.wait_timeout = timeout
                return self.returncode

        created = []
        def spawn(*args, **kwargs):
            value = Process(*args, **kwargs)
            created.append(value)
            return value
        parent = os.getppid()
        parent_values = [parent, parent, parent + 1] if parent_exited else None
        with patch.object(backup, "SCHEMA", self.schema), \
             patch.object(sys.stdin, "isatty", return_value=True), \
             patch.object(sys.stdout, "isatty", return_value=True), \
             patch.object(backup.existing, "command", return_value=b"1.23.0"), \
             patch.object(backup.subprocess, "Popen", side_effect=spawn), \
             patch.object(backup.os, "getppid", side_effect=parent_values, return_value=parent):
            result = backup.bootstrap()
        self.assertEqual(len(created), 1)
        self.assertEqual(created[0].owner, str(os.getpid()))
        self.assertTrue(created[0].terminated)
        self.assertFalse(result["restoreVerified"])
        return created[0]

    def test_signals_reap_supervisor_and_restore_handlers(self):
        for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            with self.subTest(signal=signum):
                before = signal.getsignal(signum)
                self.invoke(signum=signum)
                self.assertIs(signal.getsignal(signum), before)

    def test_signal_during_spawn_is_deferred_until_child_is_owned(self):
        self.invoke(signum=signal.SIGTERM, during_spawn=True)

    def test_parent_exit_stops_supervisor(self):
        self.invoke(parent_exited=True)

    def test_descendant_held_pipes_have_bounded_final_drain(self):
        child = self.invoke(signum=signal.SIGHUP, retained_pipes=True)
        self.assertEqual(child.timeouts, [0.2, 5, 5])
        self.assertEqual(child.wait_timeout, 2)
        self.assertTrue(child.stdout.closed and child.stderr.closed)

    def test_orphaned_start_or_missing_owner_rejected_before_watchdog(self):
        for parent, owner in ((1, str(os.getpid())), (99, ""), (99, "not-a-pid")):
            with patch.object(backup.os, "getppid", return_value=parent), \
                 patch.dict(os.environ, {backup.SUPERVISOR_PID: owner}):
                with self.assertRaises(ValueError):
                    with backup.supervised_parent():
                        self.fail("An orphaned helper started")
        with patch.dict(os.environ, {backup.SUPERVISOR_PID: str(os.getpid())}), \
             patch.object(backup, "process_exists", return_value=False):
            with self.assertRaises(ValueError):
                with backup.supervised_parent():
                    self.fail("A dead owner's helper started")

    def test_inner_watchdog_stops_when_explicit_owner_dies(self):
        before = signal.getsignal(signal.SIGTERM)
        with patch.dict(os.environ, {backup.SUPERVISOR_PID: str(os.getpid())}), \
             patch.object(backup, "process_exists", side_effect=[True, False]):
            with self.assertRaises(backup.existing.CommandCancelled):
                with backup.supervised_parent():
                    time.sleep(2)
        self.assertIs(signal.getsignal(signal.SIGTERM), before)


@unittest.skipUnless(sys.platform == "darwin" and backup.AGE.is_file(), "installed age/macOS required")
class InstalledToolTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="portable-real-", dir=TEST_ROOT)
        cls.root = Path(cls.temporary.name)
        cls.source = cls.root / "source"
        cls.source.mkdir(mode=0o700)
        env = backup.environment()
        env.update({backup.KEYS[2]: SYNTHETIC_PASSWORD, backup.KEYS[3]: SYNTHETIC_PASSWORD})
        cls.keystore = cls.source / backup.KEYSTORE
        # ONLY an isolated disposable SYNTHETIC fixture, never a production key.
        backup.existing.command(["keytool", "-genkeypair", "-keystore", str(cls.keystore), "-storetype", "PKCS12",
            "-alias", backup.existing.ALIAS, "-keyalg", "RSA", "-keysize", "2048", "-validity", "1",
            "-dname", "CN=DISPOSABLE SYNTHETIC RECOVERY TEST", "-storepass:env", backup.KEYS[2],
            "-keypass:env", backup.KEYS[3]], env=env, timeout=30)
        cls.keystore.chmod(0o600)
        der = backup.existing.command(["keytool", "-exportcert", "-keystore", str(cls.keystore),
            "-alias", backup.existing.ALIAS, "-storepass:env", backup.KEYS[2]], env=env, timeout=30)
        cls.digest = hashlib.sha256(der).hexdigest()
        files, cls.credentials, _digest = fixtures()
        files[backup.KEYSTORE] = cls.keystore.read_bytes()
        files[backup.CERTIFICATE] = b"-----BEGIN CERTIFICATE-----\n" + base64.b64encode(der) + b"\n-----END CERTIFICATE-----\n"
        receipt = backup.strict_json(files[backup.RECEIPT])
        receipt["certificateSha256"] = cls.digest
        files[backup.RECEIPT] = backup.json_bytes(receipt)
        cls.files = files
        cls.archive = backup.make_archive(files, cls.credentials, cls.digest)

    @classmethod
    def tearDownClass(cls):
        cls.temporary.cleanup()

    def test_real_jdk_restoration_and_mismatched_credentials(self):
        backup.verify_restored(self.files, self.credentials, scratch_parent=self.root, expected=self.digest)
        for field in ("storePassword", "keyPassword"):
            with self.assertRaises(ValueError):
                backup.verify_restored(self.files, {**self.credentials, field: "synthetic-wrong-password"},
                                       scratch_parent=self.root, expected=self.digest)
        self.assertFalse(any(path.name.startswith("quenderin-restore-") for path in self.root.iterdir()))

    def test_actual_passphrase_age_authentication_tamper_truncation_and_restore(self):
        encrypted = self.root / "synthetic.age"
        private_write(encrypted, b"")
        def encrypt():
            with encrypted.open("r+b") as output:
                backup.age_command(["--passphrase"], data=self.archive, output=output)
        run_private_pty(encrypt)
        ciphertext = encrypted.read_bytes()
        self.assertGreater(len(ciphertext), len(self.archive))
        self.assertNotIn(SYNTHETIC_PASSWORD.encode(), ciphertext)

        def decrypt_and_verify():
            with encrypted.open("rb") as source:
                restored = backup.age_command(["--decrypt"], input_fd=source)
            files, credentials = backup.parse_archive(restored, self.digest)
            backup.verify_restored(files, credentials, scratch_parent=self.root, expected=self.digest)
        run_private_pty(decrypt_and_verify)

        for index, content in enumerate((ciphertext[:-20], ciphertext[:-1] + bytes([ciphertext[-1] ^ 1]))):
            corrupted = self.root / ("corrupted-" + str(index) + ".age")
            private_write(corrupted, content)
            def reject(path=corrupted):
                try:
                    with path.open("rb") as source:
                        backup.age_command(["--decrypt"], input_fd=source)
                except ValueError:
                    return
                raise AssertionError("Unauthenticated plaintext was accepted")
            run_private_pty(reject)
        # All outputs here are owned synthetic test data, removed by tearDownClass.

    def test_actual_varlock_tree_exits_when_bootstrap_is_terminated_or_killed(self):
        helper_directory = str(Path(backup.__file__).resolve().parent)
        def running(pid):
            result = subprocess.run(["/bin/ps", "-o", "stat=", "-p", str(pid)],
                                    stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=3)
            state = result.stdout.strip()
            return bool(state and not state.startswith(b"Z"))

        for signum in (signal.SIGTERM, signal.SIGKILL):
            with self.subTest(signal=signum), tempfile.TemporaryDirectory(prefix="tree-", dir=self.root) as temporary:
                root = Path(temporary)
                schema, actor, state_file = root / "synthetic.schema", root / "actor.py", root / "state.json"
                private_write(schema, b"\n".join(
                    ("# @required @sensitive\n" + name + "=synthetic-only-unused-input").encode()
                    for name in backup.KEYS) + b"\n")
                actor_source = '''import json,os,sys
from pathlib import Path
sys.path.insert(0, HELPER_DIRECTORY)
import backup_upload_key as b
os.umask(0o077)
spawn = b.subprocess.Popen
def record(*args, **kwargs):
    process = spawn(*args, **kwargs)
    with open(STATE_FILE, "x") as stream:
        json.dump({"owner": int(os.environ[b.SUPERVISOR_PID]), "varlock": os.getppid(),
                   "helper": os.getpid(), "age": process.pid}, stream)
    return process
b.subprocess.Popen = record
try:
    with b.supervised_parent():
        with open(ENCRYPTED_FILE, "xb") as encrypted:
            b.age_command(["--passphrase"], data=b"synthetic cancellation payload", output=encrypted)
except BaseException:
    pass
'''.replace("HELPER_DIRECTORY", repr(helper_directory)).replace("STATE_FILE", repr(str(state_file))).replace("ENCRYPTED_FILE", repr(str(root / "synthetic.age")))
                private_write(actor, actor_source.encode())
                owner_script = root / "owner.py"
                owner_source = '''import sys
from pathlib import Path
sys.path.insert(0, HELPER_DIRECTORY)
import backup_upload_key as b
b.SCHEMA = Path(SCHEMA_FILE)
b.__file__ = ACTOR_FILE
try:
    b.bootstrap()
except BaseException:
    pass
'''.replace("HELPER_DIRECTORY", repr(helper_directory)).replace("SCHEMA_FILE", repr(str(schema))).replace("ACTOR_FILE", repr(str(actor)))
                private_write(owner_script, owner_source.encode())
                # A fresh interpreter avoids executing Python/loaded native
                # libraries after fork in this multi-test macOS process. BSD
                # script owns and reaps the terminal child as a normal parent.
                owner_terminal = subprocess.Popen(["/usr/bin/script", "-q", "/dev/null",
                    sys.executable, "-B", str(owner_script)], env=backup.environment(),
                    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                    start_new_session=True)
                child_pids = []
                try:
                    deadline = time.monotonic() + 20
                    state = None
                    while time.monotonic() < deadline:
                        if state_file.exists():
                            try:
                                state = json.loads(state_file.read_text())
                                break
                            except json.JSONDecodeError:
                                pass
                        if owner_terminal.poll() is not None:
                            break
                        time.sleep(0.05)
                    self.assertIsNotNone(state, "Synthetic process tree did not reach age")
                    self.assertGreater(state["owner"], 1)
                    child_pids = [state[name] for name in ("varlock", "helper", "age")]
                    self.assertTrue(all(running(value) for value in child_pids))
                    os.kill(state["owner"], signum)
                    deadline = time.monotonic() + 12
                    while time.monotonic() < deadline and any(running(value) for value in child_pids):
                        time.sleep(0.05)
                    self.assertFalse(any(running(value) for value in child_pids), "Synthetic descendant survived its owner")
                finally:
                    for value in [*child_pids, *([state["owner"]] if state else [])]:
                        if running(value):
                            try:
                                os.kill(value, signal.SIGKILL)
                            except ProcessLookupError:
                                pass
                    if owner_terminal.poll() is None:
                        owner_terminal.terminate()
                    try:
                        owner_terminal.communicate(timeout=5)
                    except subprocess.TimeoutExpired:
                        owner_terminal.kill()
                        try:
                            owner_terminal.communicate(timeout=5)
                        except subprocess.TimeoutExpired:
                            pass
                    for stream in (owner_terminal.stdin, owner_terminal.stdout, owner_terminal.stderr):
                        if stream is not None:
                            stream.close()


if __name__ == "__main__":
    unittest.main()

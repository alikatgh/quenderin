#!/usr/bin/env python3
"""Human-only portable age backup; credentials and decrypted archives stay in RAM."""
from __future__ import annotations

from contextlib import contextmanager
from datetime import datetime, timezone
import base64
import hashlib
import io
import json
import os
from pathlib import Path
import re
import secrets
import selectors
import signal
import stat
import subprocess
import sys
import tarfile
import tempfile
import threading
import time
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
import generate_upload_key as existing

HOME = Path("/Users/s_avelova")
SOURCE = HOME / "QuenderinSigning"
DESTINATION = HOME / "QuenderinSigningBackups"
SCHEMA = HOME / "QuenderinSigningCredentials/signing.schema"
VARLOCK = HOME / ".local/varlock/1.23.0/varlock"
AGE = Path("/opt/homebrew/bin/age")
CERT_SHA256 = "880aca180c193bcbd670f1afddc2b0e15e95f755771805e470aa5e75384f8b6f"
KEYS = existing.signing.KEYS
KEYSTORE = existing.KEYSTORE_NAME
CERTIFICATE = existing.CERTIFICATE_NAME
RECEIPT = existing.RECEIPT_NAME
CREDENTIALS = "portable-credentials.json"
MANIFEST = "manifest.json"
README = "RESTORE.txt"
MEMBERS = {KEYSTORE, CERTIFICATE, RECEIPT, CREDENTIALS, MANIFEST, README}
MAX_FILE = 2 * 1024 * 1024
MAX_ARCHIVE = 3 * 1024 * 1024
MAX_ENCRYPTED = MAX_ARCHIVE + 64 * 1024
MAX_SMALL = 16 * 1024
SUPERVISOR_PID = "_QUENDERIN_BACKUP_SUPERVISOR_PID"
README_BYTES = b"""Quenderin Android upload key portable recovery, format 1.
This age passphrase-encrypted archive contains the existing encrypted PKCS12,
public certificate, original public reset receipt, manifest, and actual alias,
store password and key password. The original device's Varlock ciphertext is
not needed. Protect both this archive and its independent age passphrase.

On a trusted independent Mac install age and JDK 21. First prepare an encrypted
APFS disk image with Disk Utility, using a separate strong password, and mount
it. Give it a private recovery folder, outside repositories and cloud sync.
Run age --decrypt -o /Volumes/RECOVERY/recovery.tar /path/to/backup.tar.age in
your own Terminal; age asks privately for the independent archive passphrase.
Only proceed after age exits successfully. Inspect the member list with tar -tf
/Volumes/RECOVERY/recovery.tar, then extract inside that encrypted recovery
folder. Expect exactly upload-keystore.p12, upload_certificate.pem,
upload-key-reset.receipt.json, portable-credentials.json, manifest.json and
RESTORE.txt. Reject links, paths, duplicates and unexpected members. Never use
a public/shared machine or extract to an unencrypted disk.

portable-credentials.json contains the actual alias, storePassword and
keyPassword. Open it privately inside the encrypted image. Do not print it,
paste into chat, or put passwords in command arguments/history. Use keytool
-list -v -storetype PKCS12 -keystore /Volumes/RECOVERY/upload-keystore.p12
-alias quenderin-upload, entering storePassword at its private prompt. Compare
its certificate SHA256 to the manifest and public reset receipt. To check the
private key, put a harmless text file in a small JAR using the JDK jar command,
then run jarsigner -storetype PKCS12 -keystore
/Volumes/RECOVERY/upload-keystore.p12 /Volumes/RECOVERY/test.jar
quenderin-upload, answering its password prompts privately. If prompted for a
distinct key password, use keyPassword. Run jarsigner -verify on test.jar and
keytool -printcert -jarfile on test.jar; require verification and the same
certificate SHA256. Lock/eject the encrypted image after recovery.

The repository helper additionally performs strict parsing, manifest hashes,
and all checks without saving plaintext credentials; it is useful when present
but is not needed to recover with the mature tools above. Keep a public copy of
the expected certificate SHA256 separately from this archive.

The original receipt describes generation/reset preparation, not current Play
registration. A local restore check does not establish an off-device copy.
"""


def environment(*, credentials=False):
    """Only JDK children receive actual credentials; age never does."""
    names = ("PATH", "HOME", "JAVA_HOME", "TMPDIR", "LANG", "LC_ALL")
    result = {name: os.environ[name] for name in names if name in os.environ}
    if credentials:
        result.update({name: os.environ[name] for name in KEYS if name in os.environ})
    result["PYTHONDONTWRITEBYTECODE"] = "1"
    return result


def private_metadata(metadata, *, directory=False):
    expected = 0o700 if directory else 0o600
    valid_type = stat.S_ISDIR(metadata.st_mode) if directory else stat.S_ISREG(metadata.st_mode)
    if (not valid_type or metadata.st_uid != os.getuid()
            or stat.S_IMODE(metadata.st_mode) != expected
            or (not directory and metadata.st_nlink != 1)):
        raise ValueError("Private filesystem metadata differs")


@contextmanager
def anchored_directory(path, *, create=False):
    """Hold every ancestor; never follow symlinks or redirect path-based writes."""
    if not path.is_absolute() or ".." in path.parts:
        raise ValueError("Absolute canonical directory is required")
    held = []
    try:
        descriptor = os.open("/", existing.DIRECTORY_FLAGS)
        held.append(("/", descriptor))
        for index, part in enumerate(path.parts[1:]):
            if create and index == len(path.parts) - 2:
                try:
                    os.mkdir(part, mode=0o700, dir_fd=descriptor)
                except FileExistsError:
                    pass
            descriptor = os.open(part, existing.DIRECTORY_FLAGS, dir_fd=descriptor)
            held.append((part, descriptor))

        def verify():
            for index, (part, current) in enumerate(held):
                existing.require_no_git(current)
                if index:
                    info = os.stat(part, dir_fd=held[index - 1][1], follow_symlinks=False)
                    if not stat.S_ISDIR(info.st_mode) or (info.st_dev, info.st_ino) != existing.identity(current):
                        raise ValueError("Directory ancestry changed")
            private_metadata(os.fstat(descriptor), directory=True)
            existing.require_no_acl(descriptor)

        verify()
        yield descriptor, verify
        verify()
    finally:
        for _part, descriptor in reversed(held):
            os.close(descriptor)


def read_private(directory_fd, name, limit):
    descriptor = os.open(name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=directory_fd)
    try:
        info = os.fstat(descriptor)
        private_metadata(info)
        existing.require_no_acl(descriptor)
        if not 0 < info.st_size <= limit:
            raise ValueError("Private input is empty or oversized")
        with os.fdopen(os.dup(descriptor), "rb") as stream:
            data = stream.read(limit + 1)
        after = os.fstat(descriptor)
        linked = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
        stamp = lambda value: (value.st_dev, value.st_ino, value.st_size, value.st_mtime_ns, value.st_ctime_ns)
        if len(data) != info.st_size or stamp(info) != stamp(after) or stamp(info) != stamp(linked):
            raise ValueError("Private input changed while reading")
        return data
    finally:
        os.close(descriptor)


def json_bytes(value):
    return (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()


def strict_json(data):
    def pairs(items):
        result = {}
        for key, value in items:
            if key in result:
                raise ValueError("Repeated JSON field")
            result[key] = value
        return result
    return json.loads(data, object_pairs_hook=pairs)


def certificate_digest(pem):
    match = re.fullmatch(rb"-----BEGIN CERTIFICATE-----\s+([A-Za-z0-9+/=\r\n]+)\s+-----END CERTIFICATE-----\s*", pem)
    if match is None:
        raise ValueError("Public certificate format differs")
    der = base64.b64decode(re.sub(rb"\s", b"", match[1]), validate=True)
    if not der:
        raise ValueError("Public certificate is empty")
    return hashlib.sha256(der).hexdigest()


def validate_public(files, expected=CERT_SHA256):
    if certificate_digest(files[CERTIFICATE]) != expected:
        raise ValueError("Public certificate differs")
    receipt = strict_json(files[RECEIPT])
    required = {"schemaVersion": 1, "applicationId": "ai.quenderin.app", "purpose": "upload-key-reset",
                "generated": True, "certificateSha256": expected, "keystoreFile": KEYSTORE,
                "publicCertificateFile": CERTIFICATE}
    if not isinstance(receipt, dict) or any(receipt.get(key) != value for key, value in required.items()):
        raise ValueError("Public reset receipt differs")


def portable_credentials(env, source=SOURCE):
    if (not all(name in env for name in KEYS) or env[KEYS[0]] != str(source / KEYSTORE)
            or env[KEYS[1]] != existing.ALIAS
            or any(not isinstance(env[name], str) or not 1 <= len(env[name]) <= 4096
                   or "\x00" in env[name] or "\n" in env[name] or "\r" in env[name] for name in KEYS[1:])):
        raise ValueError("Canonical signing inputs differ")
    return {"schemaVersion": 1, "alias": env[KEYS[1]], "storePassword": env[KEYS[2]],
            "keyPassword": env[KEYS[3]]}


def make_archive(files, credentials, expected=CERT_SHA256):
    validate_public(files, expected)
    payload = {**files, CREDENTIALS: json_bytes(credentials), README: README_BYTES}
    payload[MANIFEST] = json_bytes({"schemaVersion": 1, "applicationId": "ai.quenderin.app",
        "purpose": "portable-upload-key-backup", "certificateSha256": expected,
        "files": {name: {"size": len(data), "sha256": hashlib.sha256(data).hexdigest()}
                  for name, data in payload.items()}})
    stream = io.BytesIO()
    with tarfile.open(fileobj=stream, mode="w", format=tarfile.USTAR_FORMAT) as archive:
        for name, data in sorted(payload.items()):
            limit = MAX_FILE if name == KEYSTORE else MAX_SMALL
            if not 0 < len(data) <= limit:
                raise ValueError("Archive member size differs")
            member = tarfile.TarInfo(name)
            member.size = len(data)
            member.mode = 0o600
            archive.addfile(member, io.BytesIO(data))
    result = stream.getvalue()
    if len(result) > MAX_ARCHIVE:
        raise ValueError("Archive is oversized")
    return result


def parse_archive(data, expected=CERT_SHA256):
    """Only call after age has authenticated the entire stream successfully."""
    if not data or len(data) > MAX_ARCHIVE or len(data) % 512:
        raise ValueError("Archive size differs")
    files = {}
    # Parse each raw USTAR header, including extensions tarfile normally hides.
    # Exact generated headers exclude links, extensions, alternate names and paths.
    offset = 0
    while offset + 512 <= len(data) and any(data[offset:offset + 512]):
        header = data[offset:offset + 512]
        member = tarfile.TarInfo.frombuf(header, "utf-8", "strict")
        if (member.name not in MEMBERS or member.name in files or member.type != tarfile.REGTYPE
                or member.pax_headers or member.linkname or member.mode != 0o600
                or member.uid != 0 or member.gid != 0 or member.uname or member.gname
                or member.mtime != 0 or member.tobuf(format=tarfile.USTAR_FORMAT) != header
                or not 0 < member.size <= (MAX_FILE if member.name == KEYSTORE else MAX_SMALL)):
            raise ValueError("Archive member differs")
        start = offset + 512
        end = start + member.size
        offset = start + ((member.size + 511) // 512) * 512
        if offset > len(data) or any(data[end:offset]):
            raise ValueError("Archive member is truncated or padded differently")
        files[member.name] = data[start:end]
    if len(data) - offset < 1024 or any(data[offset:]):
        raise ValueError("Archive termination differs")
    if set(files) != MEMBERS:
        raise ValueError("Required archive members are missing")
    validate_public(files, expected)
    manifest = strict_json(files[MANIFEST])
    required = {"schemaVersion": 1, "applicationId": "ai.quenderin.app",
                "purpose": "portable-upload-key-backup", "certificateSha256": expected,
                "files": {name: {"size": len(value), "sha256": hashlib.sha256(value).hexdigest()}
                          for name, value in files.items() if name != MANIFEST}}
    if manifest != required or files[README] != README_BYTES:
        raise ValueError("Archive manifest differs")
    credentials = strict_json(files[CREDENTIALS])
    if (not isinstance(credentials, dict) or set(credentials) != {"schemaVersion", "alias", "storePassword", "keyPassword"}
            or credentials["schemaVersion"] != 1 or credentials["alias"] != existing.ALIAS
            or any(not isinstance(credentials[name], str) or not 1 <= len(credentials[name]) <= 4096
                   or any(char in credentials[name] for char in "\x00\r\n")
                   for name in ("storePassword", "keyPassword"))):
        raise ValueError("Portable credentials differ")
    return files, credentials


def age_command(args, *, data=None, output=None, input_fd=None, timeout=600):
    """Keep the controlling TTY for age's private passphrase prompt, capture errors."""
    # age has no compressor; bounded ciphertext bounds decrypted memory. The
    # authenticated plaintext is consumed only after a zero exit status.
    process = None
    previous = {}
    cancelled = False
    def interrupted(_number, _frame):
        nonlocal cancelled
        cancelled = True
    for number in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        previous[number] = signal.signal(number, interrupted)
    try:
        process = subprocess.Popen([str(AGE), *args], env=environment(),
            stdin=input_fd if input_fd is not None else subprocess.PIPE,
            stdout=output if output is not None else subprocess.PIPE, stderr=subprocess.PIPE)
        # age writes its prompt to stderr while reading the answer from /dev/tty.
        # Forward only recognized fixed prompts; never forward error/tool text.
        result = bytearray()
        errors = b""
        cursor = 0
        deadline = time.monotonic() + timeout
        with open("/dev/tty", "wb", buffering=0) as terminal, selectors.DefaultSelector() as selector:
            for stream, kind in ((process.stdin, "input"), (process.stdout, "output"), (process.stderr, "error")):
                if stream is not None:
                    os.set_blocking(stream.fileno(), False)
                    selector.register(stream, selectors.EVENT_WRITE if kind == "input" else selectors.EVENT_READ, kind)
            while selector.get_map() or process.poll() is None:
                if cancelled:
                    raise existing.CommandCancelled("Private operation interrupted")
                if time.monotonic() >= deadline:
                    raise ValueError("Private age operation timed out")
                for key, _events in selector.select(timeout=0.1):
                    if key.data == "input":
                        if cursor < len(data or b""):
                            try:
                                cursor += os.write(key.fd, memoryview(data)[cursor:cursor + 65536])
                            except BlockingIOError:
                                continue
                        if cursor == len(data or b""):
                            selector.unregister(key.fileobj)
                            key.fileobj.close()
                    else:
                        try:
                            chunk = os.read(key.fd, 65536)
                        except BlockingIOError:
                            continue
                        if not chunk:
                            selector.unregister(key.fileobj)
                            key.fileobj.close()
                        elif key.data == "output":
                            result.extend(chunk)
                            if len(result) > MAX_ARCHIVE:
                                raise ValueError("Decrypted archive is oversized")
                        else:
                            errors += chunk
                            if len(errors) > MAX_SMALL:
                                raise ValueError("Private age diagnostics exceeded bound")
                            while match := re.search(rb"(?:Enter|Confirm) passphrase[^:\r\n]*:", errors):
                                prompt = b"\nConfirm backup passphrase: " if match[0].startswith(b"Confirm") else b"\nEnter backup passphrase (private): "
                                terminal.write(prompt)
                                errors = errors[match.end():]
            terminal.write(b"\n")
        process.wait(timeout=2)
        if cancelled or process.returncode:
            raise ValueError("age authentication or encryption failed")
        return bytes(result) if output is None else None
    except BaseException:
        if process is not None:
            for number in previous:
                signal.signal(number, signal.SIG_IGN)
            if process.poll() is None:
                process.terminate()
            try:
                process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
        raise
    finally:
        if process is not None:
            for stream in (process.stdin, process.stdout, process.stderr):
                if stream is not None:
                    stream.close()
        for number, handler in previous.items():
            signal.signal(number, handler)


@contextmanager
def supervised_parent():
    """A killed Varlock/launcher cannot orphan a credential-holding helper."""
    parent = os.getppid()
    owner_text = os.environ.get(SUPERVISOR_PID, "")
    if parent <= 1 or not owner_text.isdecimal() or not 1 < int(owner_text) <= 2 ** 31 - 1:
        raise ValueError("Live backup supervisor is required")
    owner = int(owner_text)
    if not process_exists(owner):
        raise ValueError("Backup supervisor has already exited")
    stopped = threading.Event()
    previous = {}
    def interrupted(_number, _frame):
        raise existing.CommandCancelled("Private operation interrupted")
    def watch():
        while not stopped.wait(0.2):
            if os.getppid() != parent or not process_exists(owner):
                os.kill(os.getpid(), signal.SIGTERM)
                return
    for number in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        previous[number] = signal.signal(number, interrupted)
    watcher = threading.Thread(target=watch, daemon=True)
    watcher.start()
    try:
        yield
    finally:
        stopped.set()
        watcher.join(timeout=1)
        for number, handler in previous.items():
            signal.signal(number, handler)


def process_exists(pid):
    try:
        os.kill(pid, 0)
        return True
    except (ProcessLookupError, PermissionError):
        return False


def verify_restored(files, credentials, *, scratch_parent=None, expected=CERT_SHA256, run=existing.command):
    """Disk holds only the already encrypted PKCS12 and a tiny JAR fixture."""
    with tempfile.TemporaryDirectory(prefix="quenderin-restore-", dir=scratch_parent or "/private/tmp") as temporary:
        directory = Path(temporary)
        private_metadata(directory.stat(), directory=True)
        with anchored_directory(directory) as (descriptor, verify):
            target = directory / KEYSTORE
            fd = os.open(KEYSTORE, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                         0o600, dir_fd=descriptor)
            with os.fdopen(fd, "wb") as stream:
                stream.write(files[KEYSTORE])
            env = environment()
            env.update({KEYS[0]: str(target), KEYS[1]: credentials["alias"],
                        KEYS[2]: credentials["storePassword"], KEYS[3]: credentials["keyPassword"]})
            der = run(["keytool", "-exportcert", "-storetype", "PKCS12", "-keystore", str(target),
                       "-alias", credentials["alias"], "-storepass:env", KEYS[2]], env=env, timeout=30)
            if hashlib.sha256(der).hexdigest() != expected:
                raise ValueError("Restored keystore certificate differs")
            fixture, signed = directory / "fixture.jar", directory / "signed.jar"
            with zipfile.ZipFile(fixture, "x", compression=zipfile.ZIP_STORED) as archive:
                archive.writestr("recovery-check.txt", b"Quenderin offline key recovery check.\n")
            run(["jarsigner", "-storetype", "PKCS12", "-keystore", str(target),
                 "-storepass:env", KEYS[2], "-keypass:env", KEYS[3], "-digestalg", "SHA-256",
                 "-sigfile", "QRESTORE", "-signedjar", str(signed), str(fixture), credentials["alias"]],
                env=env, timeout=60)
            verification = run(["jarsigner", "-J-Duser.language=en", "-J-Duser.country=US",
                                "-verify", str(signed)], env=environment(), timeout=30)
            if b"jar verified." not in verification:
                raise ValueError("Restored signing verification failed")
            public = run(["keytool", "-printcert", "-rfc", "-jarfile", str(signed)],
                         env=environment(), timeout=30)
            certificates = re.findall(rb"-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----", public, re.S)
            if len(certificates) != 1 or certificate_digest(certificates[0]) != expected:
                raise ValueError("Restored actual signature certificate differs")
            with zipfile.ZipFile(signed) as archive:
                if (archive.testzip() is not None or archive.read("recovery-check.txt")
                        != b"Quenderin offline key recovery check.\n"):
                    raise ValueError("Recovery fixture payload changed")
            verify()


def check_tools():
    for args, valid in (([str(AGE), "--version"], lambda v: v.strip() == b"v1.3.2"),
                        (["java", "--version"], lambda v: bool(re.match(rb"(?:openjdk|java) 21(?:[.\s])", v))),
                        (["keytool", "-help"], lambda v: True),
                        (["jarsigner", "-help"], lambda v: True)):
        if not valid(existing.command(args, env=environment(), timeout=20)):
            raise ValueError("Pinned installed tools differ")


def backup(*, source=SOURCE, destination=DESTINATION, expected=CERT_SHA256, progress=None):
    progress = {} if progress is None else progress
    if not sys.stdin.isatty():
        raise ValueError("Private human Terminal is required")
    credentials = portable_credentials(os.environ, source)
    check_tools()
    previous_umask = os.umask(0o077)
    try:
        with anchored_directory(source) as (source_fd, verify_source):
            files = {name: read_private(source_fd, name, MAX_FILE if name == KEYSTORE else MAX_SMALL)
                     for name in (KEYSTORE, CERTIFICATE, RECEIPT)}
            archive = make_archive(files, credentials, expected)
            with anchored_directory(destination, create=True) as (output_fd, verify_output):
                name = "quenderin-upload-key-" + datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ") + "-" + secrets.token_hex(8) + ".tar.age"
                descriptor = os.open(name, os.O_RDWR | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                                     0o600, dir_fd=output_fd)
                progress["backupPath"] = str(destination / name)
                try:
                    private_metadata(os.fstat(descriptor))
                    existing.require_no_acl(descriptor)
                    age_command(["--passphrase"], data=archive, output=descriptor)
                    os.fsync(descriptor)
                    verify_output()
                    info = os.fstat(descriptor)
                    linked = os.stat(name, dir_fd=output_fd, follow_symlinks=False)
                    if ((info.st_dev, info.st_ino) != (linked.st_dev, linked.st_ino)
                            or not 0 < info.st_size <= MAX_ENCRYPTED):
                        raise ValueError("Encrypted backup identity or size differs")
                    private_metadata(info)
                    os.lseek(descriptor, 0, os.SEEK_SET)
                    encrypted = os.read(descriptor, MAX_ENCRYPTED + 1)
                    progress.update(size=len(encrypted), sha256=hashlib.sha256(encrypted).hexdigest())
                    os.lseek(descriptor, 0, os.SEEK_SET)
                    plaintext = age_command(["--decrypt"], input_fd=descriptor)
                    restored_files, restored_credentials = parse_archive(plaintext, expected)
                    verify_restored(restored_files, restored_credentials, expected=expected)
                    # Verify the actual restored bytes against the original input,
                    # then re-read anchored originals to detect concurrent edits.
                    if any(restored_files[name] != value for name, value in files.items()):
                        raise ValueError("Restored originals differ")
                    verify_source()
                    if any(read_private(source_fd, name, MAX_FILE if name == KEYSTORE else MAX_SMALL) != value
                           for name, value in files.items()):
                        raise ValueError("Original signing assets changed")
                    verify_output()
                    os.lseek(descriptor, 0, os.SEEK_SET)
                    if hashlib.sha256(os.read(descriptor, MAX_ENCRYPTED + 1)).hexdigest() != progress["sha256"]:
                        raise ValueError("Encrypted backup changed during restore verification")
                    os.fsync(output_fd)
                finally:
                    os.close(descriptor)
        return {**progress, "certificateSha256": expected, "restoreVerified": True,
                "offDeviceCopyVerified": False, "status": "verified_local_backup"}
    finally:
        os.umask(previous_umask)


def safe_report(value):
    """Never relay arbitrary subprocess strings, exception details or tool output."""
    result = {"restoreVerified": False, "offDeviceCopyVerified": False, "status": "rejected"}
    path = value.get("backupPath") if isinstance(value, dict) else None
    if (isinstance(path, str) and re.fullmatch(re.escape(str(DESTINATION))
            + r"/quenderin-upload-key-[0-9]{8}T[0-9]{6}Z-[0-9a-f]{16}\.tar\.age", path)):
        result.update(backupPath=path, status="preserved_output_unverified")
        if (type(value.get("size")) is int and 0 < value["size"] <= MAX_ENCRYPTED
                and isinstance(value.get("sha256"), str) and re.fullmatch(r"[0-9a-f]{64}", value["sha256"])):
            result.update(size=value["size"], sha256=value["sha256"])
            if value.get("restoreVerified") is True and value.get("certificateSha256") == CERT_SHA256:
                result.update(restoreVerified=True, certificateSha256=CERT_SHA256, status="verified_local_backup")
    return result


def bootstrap():
    if not sys.stdin.isatty() or not sys.stdout.isatty():
        raise ValueError("Private human Terminal is required")
    parent = os.getppid()
    if parent <= 1:
        raise ValueError("Live human launcher is required")
    # Validate the encrypted loader's metadata only; never open its bytes here.
    with anchored_directory(SCHEMA.parent) as (descriptor, verify):
        metadata_fd = os.open(SCHEMA.name, getattr(os, "O_EVTONLY", os.O_RDONLY) | os.O_NOFOLLOW, dir_fd=descriptor)
        try:
            private_metadata(os.fstat(metadata_fd))
            existing.require_no_acl(metadata_fd)
        finally:
            os.close(metadata_fd)
        verify()
    env = {key: value for key, value in os.environ.items()
           if not key.startswith(("QUENDERIN_UPLOAD_", "VARLOCK_", "_VARLOCK_", "__VARLOCK_", "AGE_"))
           and key not in {"PYTHONPATH", "PYTHONSTARTUP", "PYTHONINSPECT"}}
    env.update(VARLOCK_TELEMETRY_DISABLED="true", _VARLOCK_FORCE_FILE_ENCRYPTION_FALLBACK="1",
               PYTHONDONTWRITEBYTECODE="1")
    env[SUPERVISOR_PID] = str(os.getpid())
    if existing.command([str(VARLOCK), "--version"], env=env, timeout=20).strip() != b"1.23.0":
        raise ValueError("Pinned Varlock differs")
    # Preserve the foreground controlling TTY for age, while suppressing all
    # Varlock/tool stdout and stderr. Only strictly validated status JSON escapes.
    process = None
    output = b""
    previous = {}
    cancelled = False
    failed = False
    def interrupted(_number, _frame):
        nonlocal cancelled
        # Defer until Popen's result is owned, including the spawn boundary.
        cancelled = True
    for number in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        previous[number] = signal.signal(number, interrupted)
    try:
        if os.getppid() != parent:
            raise existing.CommandCancelled("Human launcher exited")
        process = subprocess.Popen([str(VARLOCK), "run", "--skip-cache", "--inject", "vars", "--filter",
            "QUENDERIN_UPLOAD_*", "--path", str(SCHEMA), "--", sys.executable, "-B", str(Path(__file__).resolve()), "_backup"],
            env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        deadline = time.monotonic() + 1300
        while True:
            if cancelled or os.getppid() != parent or time.monotonic() >= deadline:
                raise existing.CommandCancelled("Private operation interrupted")
            try:
                output, _error = process.communicate(timeout=0.2)
                break
            except subprocess.TimeoutExpired:
                continue
        if cancelled or os.getppid() != parent:
            raise existing.CommandCancelled("Private operation interrupted")
    except BaseException:
        failed = True
        if process is not None:
            if process.poll() is None:
                process.terminate()
            try:
                output, _error = process.communicate(timeout=5)
            except subprocess.TimeoutExpired:
                if process.poll() is None:
                    process.kill()
                try:
                    output, _error = process.communicate(timeout=5)
                except subprocess.TimeoutExpired:
                    # A descendant may still hold the pipes while its watchdog
                    # performs bounded cleanup. Never wait indefinitely for EOF.
                    for stream in (process.stdout, process.stderr):
                        if stream is not None:
                            stream.close()
                    process.wait(timeout=2)
    finally:
        for number, handler in previous.items():
            signal.signal(number, handler)
    report = safe_report({})
    if len(output) <= 64 * 1024:
        for line in output.splitlines():
            try:
                proposed = safe_report(strict_json(line))
                if "backupPath" in proposed:
                    report = proposed
            except (ValueError, TypeError, UnicodeError):
                pass
    if failed or process is None or process.returncode:
        report["restoreVerified"] = False
        report["status"] = "preserved_output_unverified" if "backupPath" in report else "rejected"
    return report


def main(argv=None):
    args = sys.argv[1:] if argv is None else argv
    progress = {}
    try:
        if args == ["backup"]:
            report = bootstrap()
        elif args == ["_backup"]:
            with supervised_parent():
                report = backup(progress=progress)
        else:
            raise ValueError("Backup arguments differ")
    except BaseException:
        report = safe_report(progress)
    print(json.dumps(report, sort_keys=True))
    return 0 if report["restoreVerified"] else 1


if __name__ == "__main__":
    raise SystemExit(main())

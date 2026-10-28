#!/usr/bin/env python3
"""Human-only, offline preparation of a replacement Google Play upload key."""
from __future__ import annotations

import base64
from contextlib import contextmanager
import ctypes
import ctypes.util
import errno
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import stat
import subprocess
import sys
import threading
import time

sys.path.insert(0, str(Path(__file__).resolve().parent))
import sign_aab as signing

KEYSTORE_NAME = "upload-keystore.p12"
CERTIFICATE_NAME = "upload_certificate.pem"
RECEIPT_NAME = "upload-key-reset.receipt.json"
ALIAS = "quenderin-upload"
SUBJECT = "CN=Quenderin upload key"
DIRECTORY_FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW


class CommandCancelled(Exception):
    """Distinct from InterruptedError, which selectors can swallow as EINTR."""


def command(args: list[str], *, env=None, timeout=120, terminate_grace=1) -> bytes:
    """Own a subprocess group, including cleanup on timeout or parent interruption."""
    if threading.current_thread() is not threading.main_thread():
        raise ValueError("Private process supervision requires the main thread")
    process = None
    pending_cancellation = False
    previous = {}
    def interrupted(_number, _frame):
        nonlocal pending_cancellation
        pending_cancellation = True
        # Popen may already have created a child before returning its PID. Do not
        # raise through that ownership handoff: remember the signal, receive the
        # process object, then stop/reap its group before reporting cancellation.
        # Polling also prevents repeated signals from interrupting group cleanup.
    try:
        for number in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
            previous[number] = signal.signal(number, interrupted)
        try:
            if pending_cancellation:
                raise CommandCancelled("Private operation interrupted")
            process = subprocess.Popen(args, env=env, stdin=subprocess.DEVNULL,
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
            deadline = time.monotonic() + timeout
            while True:
                if pending_cancellation:
                    raise CommandCancelled("Private operation interrupted")
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise subprocess.TimeoutExpired(args, timeout)
                try:
                    output, _error = process.communicate(timeout=min(0.1, remaining))
                    break
                except subprocess.TimeoutExpired:
                    continue
            if pending_cancellation:
                raise CommandCancelled("Private operation interrupted")
            if process.returncode:
                raise ValueError("Private command failed")
            return output
        except BaseException:
            if process is None:
                raise  # No process object was returned; there is no owned group.
            # Ignore repeated termination while stopping/reaping our direct child.
            # The inner generator has a shorter grace than the outer Varlock
            # supervisor, so it can stop its separately owned keytool group too.
            for number in previous:
                signal.signal(number, signal.SIG_IGN)
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                process.communicate(timeout=terminate_grace)
            except subprocess.TimeoutExpired:
                pass
            finally:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                process.communicate()  # Reap the direct child; drain/close pipes.
            raise
    finally:
        for number, handler in previous.items():
            signal.signal(number, handler)


def require_no_acl(descriptor: int) -> None:
    """Fail closed on any macOS extended ACL, including inherited mode-hidden grants."""
    if sys.platform != "darwin":
        raise ValueError("macOS ACL validation is required")
    library = ctypes.CDLL(ctypes.util.find_library("c"), use_errno=True)
    library.acl_get_fd_np.argtypes = [ctypes.c_int, ctypes.c_int]
    library.acl_get_fd_np.restype = ctypes.c_void_p
    library.acl_free.argtypes = [ctypes.c_void_p]
    library.acl_free.restype = ctypes.c_int
    ctypes.set_errno(0)
    acl = library.acl_get_fd_np(descriptor, 0x100)  # Apple's ACL_TYPE_EXTENDED.
    if acl:
        library.acl_free(acl)
        raise ValueError("Extended ACLs are not accepted for private output")
    # For an already-open, fstat-verified descriptor ENOENT means no extended ACL.
    if ctypes.get_errno() != errno.ENOENT:
        raise ValueError("Effective ACL validation failed")


def require_no_git(descriptor: int) -> None:
    try:
        os.stat(".git", dir_fd=descriptor, follow_symlinks=False)
    except FileNotFoundError:
        return
    raise ValueError("Private output must stay outside Git")


def identity(descriptor: int) -> tuple:
    metadata = os.fstat(descriptor)
    return metadata.st_dev, metadata.st_ino


@contextmanager
def private_directory(output: Path):
    """Anchor each ancestor and the new directory; writes use its stable cwd/FD."""
    chain = []
    output_fd = original_cwd = None
    try:
        descriptor = os.open("/", DIRECTORY_FLAGS)
        chain.append(("/", descriptor))
        for component in output.parent.parts[1:]:
            descriptor = os.open(component, DIRECTORY_FLAGS, dir_fd=descriptor)
            chain.append((component, descriptor))
        def verify_ancestors():
            for index, (component, held) in enumerate(chain):
                require_no_git(held)
                if index:
                    metadata = os.stat(component, dir_fd=chain[index - 1][1], follow_symlinks=False)
                    if not stat.S_ISDIR(metadata.st_mode) or (metadata.st_dev, metadata.st_ino) != identity(held):
                        raise ValueError("Output ancestry changed")
        verify_ancestors()
        os.mkdir(output.name, mode=0o700, dir_fd=descriptor)
        output_fd = os.open(output.name, DIRECTORY_FLAGS, dir_fd=descriptor)
        original_cwd = os.open(".", DIRECTORY_FLAGS)
        os.fchdir(output_fd)
        def verify_location():
            verify_ancestors()
            metadata = os.stat(output.name, dir_fd=descriptor, follow_symlinks=False)
            if not stat.S_ISDIR(metadata.st_mode) or (metadata.st_dev, metadata.st_ino) != identity(output_fd):
                raise ValueError("Private output directory changed")
            metadata = os.fstat(output_fd)
            if metadata.st_uid != os.getuid() or stat.S_IMODE(metadata.st_mode) != 0o700:
                raise ValueError("Output directory is not private")
            require_no_git(output_fd)
            require_no_acl(output_fd)
            if any(name not in {KEYSTORE_NAME, CERTIFICATE_NAME, RECEIPT_NAME} for name in os.listdir(output_fd)):
                raise ValueError("Unexpected private output")
        verify_location()
        if os.listdir(output_fd):
            raise ValueError("New private output is not empty")
        yield output_fd, verify_location
        verify_location()
    finally:
        if original_cwd is not None:
            os.fchdir(original_cwd)
            os.close(original_cwd)
        if output_fd is not None:
            os.close(output_fd)
        for _component, descriptor in reversed(chain):
            os.close(descriptor)


def check_tools(run=command) -> dict:
    """Check installed tools without loading or accessing any credentials."""
    status = {"varlock1230": False, "jdk21": False, "keytoolAvailable": False}
    env = signing.varlock_environment()
    for name in signing.KEYS:
        env.pop(name, None)
    for key, args, valid in (
        ("varlock1230", [str(signing.VARLOCK), "--version"], lambda value: value.strip() == b"1.23.0"),
        ("jdk21", ["java", "--version"], lambda value: bool(re.match(rb"(?:openjdk|java) 21(?:[.\s])", value))),
        ("keytoolAvailable", ["keytool", "-help"], lambda _value: True),
    ):
        try:
            status[key] = valid(run(args, env=env, timeout=20))
        except CommandCancelled:
            raise  # Cancellation must not start another tool after its group stops.
        except Exception:
            pass
    return status


def destination() -> Path:
    if not all(name in os.environ for name in signing.KEYS):
        raise ValueError("Private inputs are missing")
    keystore = Path(os.environ[signing.KEYS[0]])
    password = os.environ[signing.KEYS[2]]
    if (not keystore.is_absolute() or ".." in keystore.parts or keystore.name != KEYSTORE_NAME
            or os.environ[signing.KEYS[1]] != ALIAS or len(password) < 12
            or os.environ[signing.KEYS[3]] != password):
        raise ValueError("Private inputs are invalid")
    output = keystore.parent
    if output.exists() or output.is_symlink() or not output.parent.is_dir():
        raise ValueError("A new output directory with an existing parent is required")
    for path in (output, *output.parents):
        if path.is_symlink() or path.name == ".git" or (path / ".git").exists() or (path / ".git").is_symlink():
            raise ValueError("Output must be outside Git and have no symlink ancestors")
    return output


def require_private_metadata(metadata) -> None:
    if (not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1 or metadata.st_size == 0
            or metadata.st_uid != os.getuid() or stat.S_IMODE(metadata.st_mode) & 0o077):
        raise ValueError("Generated output is not a private regular file")


def regular_private_file(path: Path, directory_fd=None) -> None:
    # O_EVTONLY obtains metadata without opening private keystore bytes for read.
    require_private_metadata(os.stat(path, dir_fd=directory_fd, follow_symlinks=False))
    descriptor = os.open(str(path), getattr(os, "O_EVTONLY", os.O_RDONLY) | os.O_NOFOLLOW,
                         dir_fd=directory_fd)
    try:
        require_private_metadata(os.fstat(descriptor))
        require_no_acl(descriptor)
    finally:
        os.close(descriptor)


def read_public_certificate(directory_fd: int) -> bytes:
    descriptor = os.open(CERTIFICATE_NAME, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=directory_fd)
    try:
        require_private_metadata(os.fstat(descriptor))
        require_no_acl(descriptor)
        data = os.read(descriptor, 1024 * 1024 + 1)
        if len(data) > 1024 * 1024:
            raise ValueError("Public certificate is oversized")
        return data
    finally:
        os.close(descriptor)


def generate(run=command, progress=None) -> dict:
    if progress is None:
        progress = {"privateOutputMayExist": False}
    output = destination()
    if not all(check_tools(run).values()):
        raise ValueError("Pinned installed tools are unavailable")
    env = {name: os.environ[name] for name in ("PATH", "HOME", "JAVA_HOME", *signing.KEYS) if name in os.environ}
    # Relative, fixed names are resolved in the descriptor-bound directory. A
    # rename/symlink swap of an absolute ancestor cannot redirect keytool output.
    keystore = Path(KEYSTORE_NAME)
    certificate = Path(CERTIFICATE_NAME)
    previous_umask = os.umask(0o077)
    try:
        # Exclusive creation, no parent creation and no recovery deletion. An
        # incomplete directory is preserved on failure for private human review.
        with private_directory(output) as (directory_fd, verify_location):
            verify_location()
            progress["privateOutputMayExist"] = True
            run(["keytool", "-genkeypair", "-keystore", str(keystore), "-storetype", "PKCS12",
                 "-alias", ALIAS, "-keyalg", "RSA", "-keysize", "3072", "-sigalg", "SHA256withRSA",
                 "-validity", "10000", "-dname", SUBJECT,
                 "-storepass:env", signing.KEYS[2], "-keypass:env", signing.KEYS[3]], env=env, timeout=120)
            verify_location()
            return finish_public_exports(directory_fd, verify_location, keystore, certificate, env, run)
    finally:
        os.umask(previous_umask)


def finish_public_exports(directory_fd, verify_location, keystore, certificate, env, run):
    regular_private_file(keystore, directory_fd)  # Never read private keystore bytes.
    if set(os.listdir(directory_fd)) != {KEYSTORE_NAME}:
        raise ValueError("Unexpected output after key generation")
    run(["keytool", "-exportcert", "-rfc", "-keystore", str(keystore), "-alias", ALIAS,
         "-storepass:env", signing.KEYS[2], "-file", str(certificate)], env=env, timeout=30)
    verify_location()
    regular_private_file(certificate, directory_fd)
    # Read the exported PUBLIC certificate only; verify it against the JDK's
    # DER export before recording the public fingerprint.
    pem = read_public_certificate(directory_fd)
    match = re.fullmatch(rb"-----BEGIN CERTIFICATE-----\s+([A-Za-z0-9+/=\r\n]+)\s+-----END CERTIFICATE-----\s*", pem)
    if match is None:
        raise ValueError("Public certificate format differs")
    der = base64.b64decode(re.sub(rb"\s", b"", match[1]), validate=True)
    exported = run(["keytool", "-exportcert", "-keystore", str(keystore), "-alias", ALIAS,
                    "-storepass:env", signing.KEYS[2]], env=env, timeout=30)
    verify_location()
    fingerprint = hashlib.sha256(der).hexdigest()
    if not der or der != exported or fingerprint == signing.CERT_SHA256:
        raise ValueError("Replacement public certificate verification failed")
    if set(os.listdir(directory_fd)) != {KEYSTORE_NAME, CERTIFICATE_NAME}:
        raise ValueError("Unexpected output after certificate export")
    receipt = {"schemaVersion": 1, "applicationId": "ai.quenderin.app", "purpose": "upload-key-reset",
               "generated": True, "resetRequested": False, "registeredForPlay": False,
               "certificateSha256": fingerprint, "keyAlgorithm": "RSA", "keySize": 3072,
               "signatureAlgorithm": "SHA256withRSA", "validityDays": 10000,
               "certificateSubject": SUBJECT, "keystoreFile": KEYSTORE_NAME,
               "publicCertificateFile": CERTIFICATE_NAME}
    serialized = json.dumps(receipt, sort_keys=True, indent=2) + "\n"
    verify_location()
    descriptor = os.open(RECEIPT_NAME, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                         mode=0o600, dir_fd=directory_fd)
    with os.fdopen(descriptor, "w") as stream:
        stream.write(serialized)
        stream.flush()
        os.fsync(stream.fileno())
    regular_private_file(Path(RECEIPT_NAME), directory_fd)
    return receipt


def main(argv=None) -> int:
    parser = signing.StatusParser(description=__doc__)
    parser.add_argument("command", choices=("check", "generate", "_generate"))
    progress = {"privateOutputMayExist": False}
    try:
        args = parser.parse_args(argv)
        if args.command == "check":
            print(json.dumps(check_tools(), sort_keys=True))
            return 0
        if args.command == "generate":
            if not sys.stdin.isatty() or not sys.stdout.isatty():
                raise ValueError("Use private interactive Terminal entry")
            destination()  # Reject invalid destinations before invoking Varlock.
            env = signing.varlock_environment()
            if command([str(signing.VARLOCK), "--version"], env=env, timeout=20).strip() != b"1.23.0":
                raise ValueError("Pinned Varlock is unavailable")
            # The child can be cancelled before it delivers a phase/status. Once
            # dispatched, failure must conservatively require private inspection.
            progress["privateOutputMayExist"] = True
            command([str(signing.VARLOCK), "run", "--skip-cache", "--inject", "vars",
                             "--filter", "QUENDERIN_UPLOAD_*", "--path", str(signing.SCHEMA), "--",
                             sys.executable, "-B", str(Path(__file__).resolve()), "_generate"],
                    env=env, timeout=240, terminate_grace=5)
        else:
            generate(progress=progress)
        print('{"generated":true,"resetRequested":false,"registeredForPlay":false}')
        return 0
    except Exception:
        # Tool output, private paths, passwords and arbitrary CLI values are never
        # printed, including when keytool or Varlock rejects the operation.
        # Keep this independent of JSON serialization: receipt serialization may
        # itself be the failure. Only these two fixed nonsecret statuses can print.
        if progress["privateOutputMayExist"]:
            print('{"generated":false,"resetRequested":false,"registeredForPlay":false,'
                  '"privateOutputMayExist":true,"status":"preserved_output_requires_recovery"}', file=sys.stderr)
        else:
            print('{"generated":false,"resetRequested":false,"registeredForPlay":false,'
                  '"privateOutputMayExist":false,"status":"rejected"}', file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())

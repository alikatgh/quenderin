#!/usr/bin/env python3
"""Offline signing of a verified hosted AAB; all command output is status-only."""
from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import zipfile

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
import android_beta_candidate as candidate

SCHEMA = Path(__file__).with_name("signing.schema")
VARLOCK = Path.home() / ".local/varlock/1.23.0/varlock"
KEYS = ("QUENDERIN_UPLOAD_KEYSTORE", "QUENDERIN_UPLOAD_ALIAS",
        "QUENDERIN_UPLOAD_STORE_PASSWORD", "QUENDERIN_UPLOAD_KEY_PASSWORD")
CERT_SHA256 = "8b38f4e585883ab737f2918f4990ba401767a03937eb2a687288bde3e949cf3d"
SIGNATURE_ENTRIES = {"META-INF/MANIFEST.MF", "META-INF/QUPLOAD.SF",
                     "META-INF/QUPLOAD.RSA", "META-INF/QUPLOAD.DSA", "META-INF/QUPLOAD.EC"}


class StatusParser(argparse.ArgumentParser):
    def error(self, message):
        raise ValueError("Signing arguments are invalid")


def command(args: list[str], *, env=None, timeout=120) -> bytes:
    result = subprocess.run(args, env=env, stdin=subprocess.DEVNULL,
                            capture_output=True, timeout=timeout)
    if result.returncode:
        raise ValueError("Signing command failed")
    return result.stdout


def varlock_environment() -> dict[str, str]:
    # The explicit schema file and removed overrides prevent unrelated dotenv,
    # frozen-environment or plugin configuration from entering this operation.
    env = {key: value for key, value in os.environ.items()
           if not key.startswith(("VARLOCK_", "_VARLOCK_", "__VARLOCK_"))}
    env.update(VARLOCK_TELEMETRY_DISABLED="true", _VARLOCK_FORCE_FILE_ENCRYPTION_FALLBACK="1")
    return env


def check_tools(run=command) -> dict:
    status = {"varlock1230": False, "jdkSigningTools": False, "credentialsValidated": False}
    env = varlock_environment()
    try:
        status["varlock1230"] = run([str(VARLOCK), "--version"], env=env, timeout=20).strip() == b"1.23.0"
        if status["varlock1230"]:
            # Capture even agent-mode output locally; expose only validation success.
            run([str(VARLOCK), "load", "--agent", "--skip-cache", "--path", str(SCHEMA)],
                env=env, timeout=30)
            status["credentialsValidated"] = True
    except (OSError, ValueError, subprocess.SubprocessError):
        pass
    try:
        run(["jarsigner", "-help"], timeout=20)
        run(["keytool", "-help"], timeout=20)
        status["jdkSigningTools"] = True
    except (OSError, ValueError, subprocess.SubprocessError):
        pass
    return status


def unsigned_provenance(bundle: Path, receipt_path: Path, source: str, version: str, code: int,
                        receipt_sha256: str) -> dict:
    expected = candidate.Candidate.from_environment({"GITHUB_REPOSITORY": candidate.REPOSITORY,
        "CANDIDATE_SOURCE_COMMIT": source, "CANDIDATE_RELEASE_ID": "1",
        "CANDIDATE_VERSION_NAME": version, "CANDIDATE_VERSION_CODE": str(code)})
    candidate.verify_bundle(bundle)
    if receipt_path.is_symlink() or not receipt_path.is_file() or receipt_path.stat().st_size > 1024 * 1024:
        raise ValueError("Candidate receipt is unavailable")
    if (not re.fullmatch(r"[0-9a-f]{64}", receipt_sha256)
            or candidate.digest(receipt_path) != "sha256:" + receipt_sha256):
        raise ValueError("Candidate receipt differs from its reviewed GitHub asset digest")
    receipt = json.loads(receipt_path.read_text())
    required = {"schemaVersion": 1, "repository": candidate.REPOSITORY, "sourceCommit": source,
                "applicationId": candidate.PACKAGE, "versionName": version, "versionCode": code,
                "signed": False, "playUploadReady": False, "asset": expected.name,
                "size": bundle.stat().st_size, "digest": candidate.digest(bundle), "draft": True}
    if bundle.name != expected.name or any(receipt.get(key) != value for key, value in required.items()):
        raise ValueError("Candidate identity or digest differs")
    runtimes = receipt["runtimeProvenance"]
    if (not runtimes["prism"].get("revision") or not runtimes["prism"].get("sourcePatchId")
            or runtimes["image"].get("alignment") != 16384
            or not {"libquenderin_diffusion.so", "libquenderin_diffusion_jni.so"}
                <= set(runtimes["image"].get("verified", []))):
        raise ValueError("Candidate runtime provenance is incomplete")
    remote = runtimes["remoteCrypto"]
    sdk = remote["sdkReceipt"]
    stamp = "sha256:" + hashlib.sha256((json.dumps(sdk, sort_keys=True, indent=2) + "\n").encode()).hexdigest()
    if (remote["sdkReceiptDigest"] != stamp or sdk.get("platform") != "android"
            or sdk.get("rust") != "1.90.0" or sdk.get("minimumAPI") != 28
            or sdk.get("ndk") != "26.3.11579264" or sdk.get("abis") != ["arm64-v8a"]
            or sdk.get("targets") != ["aarch64-linux-android"]
            or not {"Cargo.lock", "tools/native_sdk.py"} <= sdk.get("sources", {}).keys()
            or not {"kotlin/ai/quenderin/remote/crypto/quenderin_remote_crypto.kt",
                    "jniLibs/arm64-v8a/libquenderin_remote_crypto.so", "jna/jna-5.19.1.aar"}
                <= sdk.get("files", {}).keys()
            or not all(re.fullmatch(r"[0-9a-f]{64}", value)
                       for group in ("sources", "files") for value in sdk[group].values())):
        raise ValueError("Candidate Noise/JNA provenance differs")
    for label in ("aab", "debugApk"):
        package = remote["packages"][label]
        if (package["verified"] != ["libquenderin_remote_crypto.so", "libjnidispatch.so"]
                or package["elfAlignment"] != 16384):
            raise ValueError("Candidate native package verification is incomplete")
    if remote["packages"]["aab"]["digest"] != receipt["digest"]:
        raise ValueError("Candidate verified bundle digest differs")
    return receipt


def verify_signed_payload(unsigned: Path, signed: Path) -> None:
    if signed.is_symlink() or not signed.is_file() or not 0 < signed.stat().st_size <= candidate.MAX_BYTES:
        raise ValueError("Signed bundle is unavailable or oversized")
    with zipfile.ZipFile(unsigned) as before, zipfile.ZipFile(signed) as after:
        names = after.namelist()
        if len(names) != len(set(names)) or after.testzip() is not None:
            raise ValueError("Signed bundle ZIP differs")
        if not set(before.namelist()) <= set(names) or not set(names) - set(before.namelist()) <= SIGNATURE_ENTRIES:
            raise ValueError("Signed bundle entries differ")
        for name in before.namelist():
            if name != "META-INF/MANIFEST.MF" and before.read(name) != after.read(name):
                raise ValueError("Signed bundle changed a verified payload")
        if "META-INF/QUPLOAD.SF" not in names or not set(names) & {
                "META-INF/QUPLOAD.RSA", "META-INF/QUPLOAD.DSA", "META-INF/QUPLOAD.EC"}:
            raise ValueError("Signed bundle signature is absent")


def sign(bundle: Path, receipt_path: Path, output: Path, source: str, version: str, code: int,
         receipt_sha256: str, run=command) -> Path:
    receipt = unsigned_provenance(bundle, receipt_path, source, version, code, receipt_sha256)
    if not all(name in os.environ for name in KEYS):
        raise ValueError("Signing inputs are missing")
    keystore = Path(os.environ[KEYS[0]])
    alias = os.environ[KEYS[1]]
    if keystore.is_symlink() or not keystore.is_file() or not keystore.is_absolute() or not alias:
        raise ValueError("An existing absolute upload key path and alias are required")
    # Only the JDK tools access the keystore. Passwords stay in the child env.
    env = {name: os.environ[name] for name in ("PATH", "HOME", "JAVA_HOME", *KEYS) if name in os.environ}
    cert = run(["keytool", "-exportcert", "-keystore", str(keystore), "-alias", alias,
                "-storepass:env", KEYS[2]], env=env, timeout=30)
    if hashlib.sha256(cert).hexdigest() != CERT_SHA256:
        raise ValueError("Existing upload certificate differs")
    output.mkdir(mode=0o700, parents=False, exist_ok=False)
    signed = output / bundle.name.replace("-unsigned.aab", "-signed.aab")
    run(["jarsigner", "-keystore", str(keystore), "-storepass:env", KEYS[2],
         "-keypass:env", KEYS[3], "-digestalg", "SHA-256", "-sigfile", "QUPLOAD",
         "-signedjar", str(signed), str(bundle), alias], env=env, timeout=120)
    verify_signed_payload(bundle, signed)
    verification = run(["jarsigner", "-J-Duser.language=en", "-J-Duser.country=US", "-verify", str(signed)],
                       env=env, timeout=120)
    if b"jar verified." not in verification:
        raise ValueError("Signed bundle signature verification failed")
    public = run(["keytool", "-printcert", "-rfc", "-jarfile", str(signed)], env=env, timeout=30)
    certificates = re.findall(rb"-----BEGIN CERTIFICATE-----\s*(.*?)\s*-----END CERTIFICATE-----", public, re.S)
    if len(certificates) != 1 or hashlib.sha256(base64.b64decode(certificates[0])).hexdigest() != CERT_SHA256:
        raise ValueError("Actual signed bundle certificate differs")
    if (candidate.digest(bundle) != receipt["digest"]
            or candidate.digest(receipt_path) != "sha256:" + receipt_sha256):
        raise ValueError("Unsigned candidate changed during signing")
    checksum = candidate.digest(signed)
    (output / (signed.name + ".sha256")).write_text(checksum[7:] + "  " + signed.name + "\n")
    (output / (signed.name + ".receipt.json")).write_text(json.dumps({
        "schemaVersion": 1, "repository": candidate.REPOSITORY, "sourceCommit": source,
        "applicationId": candidate.PACKAGE, "versionName": version, "versionCode": code,
        "signed": True, "uploaded": False, "asset": signed.name, "digest": checksum,
        "unsignedDigest": receipt["digest"], "unsignedReceiptDigest": candidate.digest(receipt_path),
        "uploadCertificateSha256": CERT_SHA256, "payloadPreserved": True, "signatureVerified": True,
    }, sort_keys=True, indent=2) + "\n")
    return signed


def main(argv=None) -> int:
    parser = StatusParser(description=__doc__)
    parser.add_argument("command", choices=("check", "sign", "_sign"))
    parser.add_argument("--bundle", type=Path)
    parser.add_argument("--receipt", type=Path)
    parser.add_argument("--receipt-sha256")
    parser.add_argument("--output-dir", type=Path)
    parser.add_argument("--source-commit")
    parser.add_argument("--version-name")
    parser.add_argument("--version-code", type=int)
    try:
        args = parser.parse_args(argv)
        if args.command == "check":
            print(json.dumps(check_tools(), sort_keys=True))
            return 0
        if any(getattr(args, key) is None for key in (
                "bundle", "receipt", "receipt_sha256", "output_dir", "source_commit", "version_name", "version_code")):
            raise ValueError("Explicit candidate and new output paths are required")
        if args.command == "sign":
            env = varlock_environment()
            if command([str(VARLOCK), "--version"], env=env, timeout=20).strip() != b"1.23.0":
                raise ValueError("Pinned Varlock is unavailable")
            forwarded = list(sys.argv[2:] if argv is None else argv[1:])
            command([str(VARLOCK), "run", "--skip-cache", "--inject", "vars", "--filter", "QUENDERIN_UPLOAD_*",
                     "--path", str(SCHEMA), "--", sys.executable, str(Path(__file__).resolve()), "_sign", *forwarded],
                    env=env, timeout=360)
        else:
            sign(args.bundle, args.receipt, args.output_dir, args.source_commit, args.version_name, args.version_code,
                 args.receipt_sha256)
        print('{"signed":true,"uploaded":false}')
        return 0
    except Exception:
        # Never print arbitrary tool, path, alias, parser, or credential details.
        print('{"signed":false,"uploaded":false,"status":"rejected"}', file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())

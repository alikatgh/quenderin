#!/usr/bin/env python3
"""One candidate, one exact login Keychain item; private output is never printed."""
import argparse
import ctypes
import hashlib
import importlib
import json
import os
from pathlib import Path
import sys

sys.dont_write_bytecode = True
TOOLS = Path('/Users/s_avelova/Documents/projects/quenderin/.worktrees/native-final-integration-20261029/tools/android-release')
ARTIFACTS = Path(__file__).resolve().parent
KEY_DIRECTORY = Path.home() / 'Library/Application Support/Quenderin-Upload-Key-20261029'
FINGERPRINT = '8f45bb0c428be051ee77b6c876e133af8b282347ea8e422ab17d2d206c863d1b'
SOURCE = 'a1d9c9eff3c1a244f55f23f697af63e7ef98308d'
RECEIPT_SHA256 = '72c0707122c206460a80990dbc91dd14cff600879dccea38a267d540c5c08077'
BUNDLE_SHA256 = 'c9718cd9a64c6c45f9be4de731f95ba8e1dc9ba861e3b472435b5cfaf0a2ffe5'
BUNDLE_NAME = 'quenderin-android-0.6.0-6-a1d9c9e-unsigned.aab'
SERVICE = b'ai.quenderin.play-upload.20261029'
ACCOUNT = b'quenderin-upload'


def login_password():
    """Read only the named login-keychain item, with interactive prompts disabled."""
    security = ctypes.CDLL('/System/Library/Frameworks/Security.framework/Security')
    core = ctypes.CDLL('/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation')
    security.SecKeychainOpen.argtypes = [ctypes.c_char_p, ctypes.POINTER(ctypes.c_void_p)]
    security.SecKeychainOpen.restype = ctypes.c_int32
    security.SecKeychainGetUserInteractionAllowed.argtypes = [ctypes.POINTER(ctypes.c_bool)]
    security.SecKeychainGetUserInteractionAllowed.restype = ctypes.c_int32
    security.SecKeychainSetUserInteractionAllowed.argtypes = [ctypes.c_bool]
    security.SecKeychainSetUserInteractionAllowed.restype = ctypes.c_int32
    security.SecKeychainFindGenericPassword.argtypes = [ctypes.c_void_p, ctypes.c_uint32, ctypes.c_char_p,
        ctypes.c_uint32, ctypes.c_char_p, ctypes.POINTER(ctypes.c_uint32), ctypes.POINTER(ctypes.c_void_p), ctypes.c_void_p]
    security.SecKeychainFindGenericPassword.restype = ctypes.c_int32
    security.SecKeychainItemFreeContent.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
    security.SecKeychainItemFreeContent.restype = ctypes.c_int32
    core.CFRelease.argtypes = [ctypes.c_void_p]
    core.CFRelease.restype = None
    previous, keychain = ctypes.c_bool(), ctypes.c_void_p()
    length, pointer = ctypes.c_uint32(), ctypes.c_void_p()
    changed = False
    try:
        if security.SecKeychainGetUserInteractionAllowed(ctypes.byref(previous)) != 0:
            raise ValueError('Keychain policy unavailable')
        if security.SecKeychainSetUserInteractionAllowed(False) != 0:
            raise ValueError('Keychain policy unavailable')
        changed = True
        path = Path.home() / 'Library/Keychains/login.keychain-db'
        if security.SecKeychainOpen(os.fsencode(path), ctypes.byref(keychain)) != 0:
            raise ValueError('Login Keychain unavailable')
        status = security.SecKeychainFindGenericPassword(keychain, len(SERVICE), SERVICE,
            len(ACCOUNT), ACCOUNT, ctypes.byref(length), ctypes.byref(pointer), None)
        if status != 0 or not pointer.value or not 12 <= length.value <= 1024:
            raise ValueError('Exact Keychain item unavailable')
        password = ctypes.string_at(pointer, length.value).decode('ascii')
        if not password or any(ord(char) < 33 or ord(char) > 126 for char in password):
            raise ValueError('Keychain item invalid')
        return password
    finally:
        if pointer.value:
            ctypes.memset(pointer, 0, length.value)
            security.SecKeychainItemFreeContent(None, pointer)
        if keychain.value:
            core.CFRelease(keychain)
        if changed:
            security.SecKeychainSetUserInteractionAllowed(previous.value)


def plain_path(path):
    if not path.is_absolute() or '..' in path.parts or any(p.is_symlink() for p in (path, *path.parents)):
        raise ValueError('Path rejected')


def preflight(signing, output):
    # This pin is updated separately ONLY after Google confirms the effective key.
    if signing.CERT_SHA256 != FINGERPRINT:
        raise ValueError('Registered signer differs')
    for path in (output, ARTIFACTS, KEY_DIRECTORY):
        plain_path(path)
    if output.exists() or not output.parent.is_dir():
        raise ValueError('New output required')
    bundle = ARTIFACTS / BUNDLE_NAME
    receipt = ARTIFACTS / (BUNDLE_NAME + '.receipt.json')
    key_receipt = KEY_DIRECTORY / 'upload-key-reset.receipt.json'
    for path in (bundle, receipt, key_receipt, KEY_DIRECTORY / 'upload-keystore.p12'):
        plain_path(path)
        if not path.is_file():
            raise ValueError('Input unavailable')
    if key_receipt.stat().st_size > 65536:
        raise ValueError('Key receipt oversized')
    public = json.loads(key_receipt.read_text())
    expected = {'schemaVersion': 1, 'applicationId': 'ai.quenderin.app', 'generated': True,
        'purpose': 'upload-key-reset', 'certificateSha256': FINGERPRINT,
        'keystoreFile': 'upload-keystore.p12', 'keyAlgorithm': 'RSA', 'keySize': 3072}
    if any(public.get(key) != value for key, value in expected.items()):
        raise ValueError('Key receipt differs')
    verified = signing.unsigned_provenance(bundle, receipt, SOURCE, '0.6.0', 6, RECEIPT_SHA256)
    if verified.get('digest') != 'sha256:' + BUNDLE_SHA256:
        raise ValueError('Bundle digest differs')
    return bundle, receipt


def execute(output, *, signing=None, generator=None, keychain=login_password):
    if signing is None or generator is None:
        sys.path.insert(0, str(TOOLS))
        signing = importlib.import_module('sign_aab')
        generator = importlib.import_module('generate_upload_key')
    bundle, receipt = preflight(signing, output)
    # Tool checks have no credentials and happen before any Keychain lookup.
    if not all(generator.check_tools().values()):
        raise ValueError('Tools unavailable')
    env = signing.varlock_environment()
    for name in signing.KEYS:
        env.pop(name, None)
    password = None
    try:
        password = keychain()
        if not isinstance(password, str) or not 12 <= len(password) <= 1024:
            raise ValueError('Keychain item invalid')
        values = (str(KEY_DIRECTORY / 'upload-keystore.p12'), ACCOUNT.decode(), password, password)
        env.update(zip(signing.KEYS, values))
        generator.command([str(signing.VARLOCK), 'run', '--skip-cache', '--inject', 'vars',
            '--filter', 'QUENDERIN_UPLOAD_*', '--path', str(signing.SCHEMA), '--',
            sys.executable, '-B', str(TOOLS / 'sign_aab.py'), '_sign',
            '--bundle', str(bundle), '--receipt', str(receipt), '--receipt-sha256', RECEIPT_SHA256,
            '--output-dir', str(output), '--source-commit', SOURCE, '--version-name', '0.6.0',
            '--version-code', '6'], env=env, timeout=360, terminate_grace=5)
    finally:
        for name in signing.KEYS:
            env.pop(name, None)
        password = None
        values = None


class StatusParser(argparse.ArgumentParser):
    def error(self, message):
        raise ValueError('Invalid arguments')


def main(argv=None):
    try:
        parser = StatusParser(description=__doc__)
        parser.add_argument('--output-dir', required=True, type=Path)
        args = parser.parse_args(argv)
        execute(args.output_dir)
        print('{"signed":true,"uploaded":false}')
        return 0
    except BaseException:
        print('{"signed":false,"uploaded":false,"status":"rejected"}')
        return 1


if __name__ == '__main__':
    raise SystemExit(main())

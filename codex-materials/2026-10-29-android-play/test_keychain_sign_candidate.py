"""Offline mocked checks. Never access Keychain or run a signing subprocess."""
import contextlib
import ctypes
import importlib.util
import io
import json
import os
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

spec = importlib.util.spec_from_file_location('wrapper', Path(__file__).with_name('keychain_sign_candidate.py'))
wrapper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(wrapper)
KEYS = ('QUENDERIN_UPLOAD_KEYSTORE', 'QUENDERIN_UPLOAD_ALIAS',
        'QUENDERIN_UPLOAD_STORE_PASSWORD', 'QUENDERIN_UPLOAD_KEY_PASSWORD')


class WrapperTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='quenderin-wrapper-mock-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.artifacts = self.root / 'artifacts'
        self.keydir = self.root / 'keys'
        self.artifacts.mkdir()
        self.keydir.mkdir()
        for name in (wrapper.BUNDLE_NAME, wrapper.BUNDLE_NAME + '.receipt.json'):
            (self.artifacts / name).write_text('synthetic')
        (self.keydir / 'upload-keystore.p12').write_text('synthetic placeholder, no key')
        (self.keydir / 'upload-key-reset.receipt.json').write_text(json.dumps({
            'schemaVersion': 1, 'applicationId': 'ai.quenderin.app', 'generated': True,
            'purpose': 'upload-key-reset', 'certificateSha256': wrapper.FINGERPRINT,
            'keystoreFile': 'upload-keystore.p12', 'keyAlgorithm': 'RSA', 'keySize': 3072}))
        for name, value in (('ARTIFACTS', self.artifacts), ('KEY_DIRECTORY', self.keydir)):
            manager = patch.object(wrapper, name, value)
            manager.start()
            self.addCleanup(manager.stop)
        self.output = self.root / 'signed'
        self.signing = SimpleNamespace(CERT_SHA256=wrapper.FINGERPRINT, KEYS=KEYS,
            VARLOCK=Path('/mock/varlock'), SCHEMA=Path('/mock/signing.schema'),
            unsigned_provenance=Mock(return_value={'digest': 'sha256:' + wrapper.BUNDLE_SHA256}),
            varlock_environment=Mock(return_value={'PATH': '/mock', KEYS[2]: 'stale-mock-value'}))
        self.generator = SimpleNamespace(check_tools=Mock(return_value={'tools': True}), command=Mock())
        self.keychain = Mock(return_value='synthetic-password-only')

    def execute(self):
        wrapper.execute(self.output, signing=self.signing, generator=self.generator, keychain=self.keychain)

    def rejected_before_credentials(self):
        with self.assertRaises(ValueError):
            self.execute()
        self.keychain.assert_not_called()
        self.generator.command.assert_not_called()

    def test_old_pin_rejects_first(self):
        self.signing.CERT_SHA256 = 'old'
        self.rejected_before_credentials()
        self.signing.unsigned_provenance.assert_not_called()
        self.generator.check_tools.assert_not_called()

    def test_candidate_receipt_mismatch_rejects(self):
        self.signing.unsigned_provenance.side_effect = ValueError('receipt mismatch')
        self.rejected_before_credentials()

    def test_bundle_digest_mismatch_rejects(self):
        self.signing.unsigned_provenance.return_value = {'digest': 'wrong'}
        self.rejected_before_credentials()

    def test_key_receipt_mismatch_rejects(self):
        (self.keydir / 'upload-key-reset.receipt.json').write_text('{}')
        self.rejected_before_credentials()

    def test_existing_output_is_preserved(self):
        self.output.mkdir()
        marker = self.output / 'existing.txt'
        marker.write_text('preserved')
        self.rejected_before_credentials()
        self.assertEqual(marker.read_text(), 'preserved')

    def test_dangling_output_symlink_rejects(self):
        self.output.symlink_to(self.root / 'missing')
        self.rejected_before_credentials()
        self.assertTrue(self.output.is_symlink())

    def test_failed_tool_check_rejects(self):
        self.generator.check_tools.return_value = {'tools': False}
        self.rejected_before_credentials()

    def test_private_values_only_in_child_environment_and_cleared(self):
        original = dict(os.environ)
        captured = {}
        def command(args, *, env, timeout, terminate_grace):
            captured['env'] = env
            self.assertNotIn(self.keychain.return_value, str(args))
            self.assertEqual(env[KEYS[2]], self.keychain.return_value)
            self.assertEqual(env[KEYS[3]], self.keychain.return_value)
            self.assertIn('--skip-cache', args)
            self.assertIn('_sign', args)
            self.assertIn(str(self.signing.SCHEMA), args)
            self.assertEqual((timeout, terminate_grace), (360, 5))
            return b'private child output must never be printed'
        self.generator.command.side_effect = command
        stdout, stderr = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            self.execute()
        self.assertEqual(stdout.getvalue() + stderr.getvalue(), '')
        self.assertEqual(dict(os.environ), original)
        self.assertTrue(all(name not in captured['env'] for name in KEYS))
        self.keychain.assert_called_once_with()
        self.generator.command.assert_called_once()

    def test_failure_preserves_partial_output_and_clears_env(self):
        captured = {}
        def command(args, *, env, **kwargs):
            captured['env'] = env
            self.output.mkdir()
            (self.output / 'partial.aab').write_text('synthetic')
            raise KeyboardInterrupt('private error')
        self.generator.command.side_effect = command
        with self.assertRaises(KeyboardInterrupt):
            self.execute()
        self.assertTrue((self.output / 'partial.aab').is_file())
        self.assertTrue(all(name not in captured['env'] for name in KEYS))
        self.generator.command.assert_called_once()

    def test_main_suppresses_failure_details(self):
        output = io.StringIO()
        with patch.object(wrapper, 'execute', side_effect=ValueError('private mock detail')):
            with contextlib.redirect_stdout(output):
                result = wrapper.main(['--output-dir', str(self.output)])
        self.assertEqual(result, 1)
        self.assertEqual(json.loads(output.getvalue()), {'signed': False, 'uploaded': False, 'status': 'rejected'})


class KeychainAPITests(unittest.TestCase):
    def setUp(self):
        self.secret = ctypes.create_string_buffer(b'synthetic-password-only')
        self.security = SimpleNamespace(**{name: Mock(return_value=0) for name in (
            'SecKeychainOpen', 'SecKeychainGetUserInteractionAllowed',
            'SecKeychainSetUserInteractionAllowed', 'SecKeychainFindGenericPassword',
            'SecKeychainItemFreeContent')})
        self.core = SimpleNamespace(CFRelease=Mock())
        def get_policy(pointer):
            ctypes.cast(pointer, ctypes.POINTER(ctypes.c_bool))[0] = True
            return 0
        def open_keychain(path, pointer):
            self.assertEqual(path, os.fsencode(Path.home() / 'Library/Keychains/login.keychain-db'))
            ctypes.cast(pointer, ctypes.POINTER(ctypes.c_void_p))[0] = 123
            return 0
        def find(keychain, service_len, service, account_len, account, length, pointer, item):
            self.assertEqual(keychain.value, 123)
            self.assertEqual((service_len, service), (len(wrapper.SERVICE), wrapper.SERVICE))
            self.assertEqual((account_len, account), (len(wrapper.ACCOUNT), wrapper.ACCOUNT))
            self.assertIsNone(item)
            ctypes.cast(length, ctypes.POINTER(ctypes.c_uint32))[0] = len(self.secret.value)
            ctypes.cast(pointer, ctypes.POINTER(ctypes.c_void_p))[0] = ctypes.addressof(self.secret)
            return 0
        self.security.SecKeychainGetUserInteractionAllowed.side_effect = get_policy
        self.security.SecKeychainOpen.side_effect = open_keychain
        self.security.SecKeychainFindGenericPassword.side_effect = find
        self.libraries = patch.object(wrapper.ctypes, 'CDLL', side_effect=[self.security, self.core])
        self.libraries.start()
        self.addCleanup(self.libraries.stop)

    def test_exact_login_item_and_buffer_cleanup(self):
        self.assertEqual(wrapper.login_password(), 'synthetic-password-only')
        self.assertEqual(self.secret.value, b'')
        self.security.SecKeychainFindGenericPassword.assert_called_once()
        self.security.SecKeychainItemFreeContent.assert_called_once()
        self.core.CFRelease.assert_called_once()
        self.assertEqual(self.security.SecKeychainSetUserInteractionAllowed.call_args_list,
            [unittest.mock.call(False), unittest.mock.call(True)])

    def test_inaccessible_item_does_not_retry_or_fallback(self):
        self.security.SecKeychainFindGenericPassword.side_effect = None
        self.security.SecKeychainFindGenericPassword.return_value = -25300
        with self.assertRaises(ValueError):
            wrapper.login_password()
        self.security.SecKeychainFindGenericPassword.assert_called_once()
        self.security.SecKeychainItemFreeContent.assert_not_called()
        self.core.CFRelease.assert_called_once()
        self.security.SecKeychainSetUserInteractionAllowed.assert_called_with(True)


if __name__ == '__main__':
    unittest.main()

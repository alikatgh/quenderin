import hashlib
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import threading
import http.client
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import unittest

SPEC = importlib.util.spec_from_file_location('step5_backend', Path(__file__).parents[1] / 'run_step5_backend.py')
backend = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(backend)


class Step5BackendTests(unittest.TestCase):
    def test_gateway_concurrency_and_disconnect_cancel_real_upstream_connection(self):
        entered = threading.Event(); disconnected = threading.Event()
        class Inner(BaseHTTPRequestHandler):
            def log_message(self, *_): pass
            def do_POST(self):
                self.rfile.read(int(self.headers['Content-Length']))
                entered.set(); self.connection.settimeout(3)
                try:
                    if self.rfile.read(1) == b'': disconnected.set()
                except OSError: pass
        inner = ThreadingHTTPServer(('127.0.0.1', 0), Inner)
        inner.daemon_threads = True
        gateway = backend.BoundedHTTPServer(('127.0.0.1', 0), backend.make_handler(inner.server_port, lambda: True))
        threads = [threading.Thread(target=server.serve_forever, kwargs={'poll_interval': 0.05}, daemon=True) for server in [inner, gateway]]
        for thread in threads: thread.start()
        first = http.client.HTTPConnection('127.0.0.1', gateway.server_port, timeout=3)
        second = http.client.HTTPConnection('127.0.0.1', gateway.server_port, timeout=3)
        try:
            body = json.dumps({'messages': [{'role': 'user', 'content': 'synthetic host fixture'}]})
            first.request('POST', '/quenderin/step5/answer', body, {'Content-Type': 'application/json'})
            self.assertTrue(entered.wait(2))
            second.request('POST', '/quenderin/step5/answer', body, {'Content-Type': 'application/json'})
            response = second.getresponse(); self.assertEqual(response.status, 409); response.read()
            first.close()
            self.assertTrue(disconnected.wait(2), 'Client cancellation must close the actual upstream request')
        finally:
            first.close(); second.close()
            gateway.shutdown(); gateway.server_close(); inner.shutdown(); inner.server_close()
            for thread in threads: thread.join(timeout=1)

    def test_complete_set_and_hashes_are_required(self):
        with tempfile.TemporaryDirectory(dir=os.environ.get('QUENDERIN_TEST_TMP')) as temporary:
            root = Path(temporary).resolve()
            content = b'fixture, never model weights'
            (root / 'model.safetensors').write_bytes(content)
            manifest = {'files': [{'filename': 'model.safetensors', 'bytes': len(content), 'sha256': hashlib.sha256(content).hexdigest()}]}
            self.assertEqual(backend.verify_model(root, manifest), root)
            (root / 'model.safetensors').write_bytes(content[:-1] + b'x')
            with self.assertRaisesRegex(ValueError, 'hash mismatch'): backend.verify_model(root, manifest)
            manifest['files'].append({'filename': 'missing.safetensors', 'bytes': 1, 'sha256': '0' * 64})
            (root / 'model.safetensors').write_bytes(content)
            with self.assertRaises(FileNotFoundError): backend.verify_model(root, manifest)

    def test_normal_metadata_uses_git_blob_identity(self):
        with tempfile.TemporaryDirectory(dir=os.environ.get('QUENDERIN_TEST_TMP')) as temporary:
            root = Path(temporary); content = b'{}'
            (root / 'config.json').write_bytes(content)
            manifest = {'files': [{'filename': 'config.json', 'bytes': 2, 'gitBlobSha1': hashlib.sha1(b'blob 2\0' + content).hexdigest()}]}
            backend.verify_model(root, manifest)

    def test_no_hidden_fields_or_duplicate_json(self):
        with self.assertRaises(ValueError): backend.parse_json(b'{"messages":[],"messages":[]}')
        for value in [[], [{'role': 'system', 'content': 'x'}], [{'role': 'user', 'content': 'a', 'tools': []}], [{'role': 'user', 'content': 'x' * 8193}]]:
            with self.assertRaises(ValueError): backend.validate_messages(value)

    def test_only_final_content_leaves_gateway(self):
        wire = {'choices': [{'message': {'content': 'Answer', 'reasoning_content': 'private'}, 'finish_reason': 'stop'}]}
        self.assertEqual(backend.final_answer(wire), {'text': 'Answer', 'truncated': False})
        for content in ['<think>private</think>Answer', '<|channel|>analysis', '']:
            wire['choices'][0]['message']['content'] = content
            with self.assertRaises(ValueError): backend.final_answer(wire)
        wire['choices'][0]['message'] = {'content': 'answer', 'tool_calls': [{'id': 'call'}]}
        with self.assertRaises(ValueError): backend.final_answer(wire)

    def test_fixed_offline_bounded_launch(self):
        command = backend.backend_command(Path('/source'), Path('/model'), '/python', 18001, 4)
        for flag, value in [('--host', '127.0.0.1'), ('--max-num-seqs', '1'), ('--max-model-len', '32768'), ('--reasoning-parser', 'step5')]:
            self.assertEqual(command[command.index(flag) + 1], value)
        self.assertNotIn('--trust-remote-code', command)
        self.assertNotIn('--spec-method', command)

    def test_pinned_manifest_covers_every_indexed_weight(self):
        manifest = backend.MANIFEST
        weights = [file for file in manifest['files'] if file['filename'].endswith('.safetensors')]
        self.assertEqual(len(weights), 26)
        self.assertEqual(sum(file['bytes'] for file in weights), 644100979280)
        self.assertEqual(manifest['sourceBackend']['revision'], 'e177c621f2b8ae1be06190bc34eef84646e54f11')
        self.assertEqual(len({file['filename'] for file in manifest['files']}), len(manifest['files']))


if __name__ == '__main__': unittest.main()

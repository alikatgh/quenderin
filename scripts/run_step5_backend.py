#!/usr/bin/env python3
"""Serve a complete, already installed Step 5 FP8 checkpoint through its pinned official vLLM.

No install, download, provisioning or credential handling. The gateway binds loopback;
use an SSH tunnel from Quenderin, or an independently secured HTTPS reverse proxy.
"""
from __future__ import annotations
import argparse
import hashlib
import http.client
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import signal
import select
import socket
import subprocess
import sys
import threading

ROOT = Path(__file__).resolve().parent.parent
MANIFEST = json.loads((ROOT / 'shared/step5-backend.json').read_text())
MAX_REQUEST = 64 * 1024
MAX_RESPONSE = 2 * 1024 * 1024


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError('Duplicate JSON field')
        result[key] = value
    return result


def parse_json(data: bytes):
    return json.loads(data.decode('utf-8'), object_pairs_hook=unique_object)


def verify_model(directory: Path, manifest=MANIFEST):
    directory = directory.resolve(strict=True)
    for entry in manifest['files']:
        name = entry['filename']
        if Path(name).name != name or name.startswith('.'):
            raise ValueError('Unsafe model manifest path')
        file = directory / name
        with file.open('rb') as stream:
            size = os.fstat(stream.fileno()).st_size
            if size != entry['bytes']:
                raise ValueError(f'Missing or wrong-size Step 5 artifact: {name}')
            digest = hashlib.sha256() if 'sha256' in entry else hashlib.sha1(b'blob ' + str(size).encode() + b'\0')
            for chunk in iter(lambda: stream.read(4 * 1024 * 1024), b''):
                digest.update(chunk)
            if digest.hexdigest() != entry.get('sha256', entry.get('gitBlobSha1')):
                raise ValueError(f'Step 5 artifact hash mismatch: {name}')
    return directory


def verify_source(source: Path):
    source = source.resolve(strict=True)
    def git(*args):
        return subprocess.check_output(['git', '-C', str(source), *args], text=True).strip()
    if git('rev-parse', 'HEAD') != MANIFEST['sourceBackend']['revision']:
        raise ValueError('Use the exact official Step 5 vLLM source revision from shared/step5-backend.json')
    if git('status', '--porcelain', '--untracked-files=all'):
        raise ValueError('The pinned vLLM checkout must be clean before starting it')
    if not (source / 'vllm/models/step5/nvidia/model.py').is_file():
        raise ValueError('The official Step 5 model implementation is missing')
    return source


def validate_messages(raw):
    if not isinstance(raw, list) or not 1 <= len(raw) <= 16 or len(raw) % 2 != 1:
        raise ValueError('Use 1–16 alternating messages ending in a user message')
    total = 0
    for index, message in enumerate(raw):
        if not isinstance(message, dict) or set(message) != {'role', 'content'} or message['role'] != ('user' if index % 2 == 0 else 'assistant'):
            raise ValueError('Invalid message role or fields')
        text = message['content']
        if not isinstance(text, str) or not text.strip() or '\0' in text or len(text.encode()) > 8192:
            raise ValueError('Each message must contain 1–8192 UTF-8 bytes')
        total += len(text.encode())
    if total > 32768:
        raise ValueError('Conversation exceeds 32 KiB')
    return raw


def final_answer(raw):
    import re
    choices = raw.get('choices') if isinstance(raw, dict) else None
    if not isinstance(choices, list) or len(choices) != 1 or not isinstance(choices[0], dict):
        raise ValueError('The backend returned no final answer')
    choice = choices[0]
    message = choice.get('message')
    if not isinstance(message, dict) or message.get('tool_calls') or choice.get('finish_reason') not in ('stop', 'length'):
        raise ValueError('Tool calls and incomplete responses are unavailable in Step 5 chat')
    text = message.get('content')
    if not isinstance(text, str) or not text.strip() or len(text.encode()) > 256 * 1024 or re.search(r'<\/?(?:think|tool_call)|<\|(?:im_start|im_end|channel)|<｜', text, re.I):
        raise ValueError('The backend did not return a valid final channel; use its Step 5 reasoning parser')
    # reasoning_content/reasoning fields are intentionally never forwarded or persisted.
    return {'text': text, 'truncated': choice['finish_reason'] == 'length'}


def backend_command(source: Path, model: Path, python: str, port: int, parallel: int):
    # Import from the checked source, not a similarly named installed package.
    bootstrap = ('import pathlib,runpy,vllm; '
                 f'assert pathlib.Path(vllm.__file__).resolve().is_relative_to(pathlib.Path({str(source)!r})); '
                 'runpy.run_module("vllm.entrypoints.openai.api_server",run_name="__main__")')
    return [python, '-c', bootstrap, '--model', str(model), '--tokenizer', str(model),
            '--served-model-name', MANIFEST['servedModelName'], '--host', '127.0.0.1', '--port', str(port),
            '--tensor-parallel-size', str(parallel), '--data-parallel-backend', 'mp',
            '--distributed-executor-backend', 'mp', '--disable-custom-all-reduce',
            '--max-model-len', '32768', '--max-num-batched-tokens', '8192', '--max-num-seqs', '1',
            '--gpu-memory-utilization', '0.85', '--reasoning-parser', 'step5', '--disable-log-requests']


class BoundedHTTPServer(ThreadingHTTPServer):
    """Bound idle headers and foreground requests as well as CUDA generation."""
    def __init__(self, *args, **kwargs):
        self.slots = threading.BoundedSemaphore(8)
        super().__init__(*args, **kwargs)
        self.daemon_threads = True
    def process_request(self, request, client_address):
        if not self.slots.acquire(blocking=False):
            self.shutdown_request(request)
            return
        try: super().process_request(request, client_address)
        except BaseException:
            self.slots.release()
            raise
    def process_request_thread(self, request, client_address):
        try: super().process_request_thread(request, client_address)
        finally: self.slots.release()


def make_handler(inner_port: int, alive):
    gate = threading.Lock()
    def request(method, route, body=None, timeout=180, peer=None):
        connection = http.client.HTTPConnection('127.0.0.1', inner_port, timeout=timeout)
        completed = threading.Event()
        try:
            connection.connect()
            upstream = connection.sock
            def watch_disconnect():
                while not completed.wait(0.1):
                    try:
                        if select.select([peer], [], [], 0)[0] and not peer.recv(1, socket.MSG_PEEK):
                            upstream.shutdown(socket.SHUT_RDWR)
                            return
                    except (OSError, ValueError):
                        try: upstream.shutdown(socket.SHUT_RDWR)
                        except OSError: pass
                        return
            if peer is not None:
                threading.Thread(target=watch_disconnect, daemon=True).start()
            connection.request(method, route, body=body, headers={'Content-Type': 'application/json'})
            response = connection.getresponse()
            data = response.read(MAX_RESPONSE + 1)
            if len(data) > MAX_RESPONSE or response.status != 200:
                raise ValueError('Official Step 5 backend is unavailable or exceeded its response limit')
            return data
        finally:
            completed.set()
            connection.close()

    class Handler(BaseHTTPRequestHandler):
        server_version = 'QuenderinStep5/1'
        timeout = 10
        def log_message(self, *_): pass
        def send_json(self, status, value):
            payload = json.dumps(value, ensure_ascii=False).encode()
            self.send_response(status)
            self.send_header('Content-Type', 'application/json; charset=utf-8')
            self.send_header('Content-Length', str(len(payload)))
            self.send_header('Cache-Control', 'no-store')
            self.send_header('X-Content-Type-Options', 'nosniff')
            self.end_headers()
            try: self.wfile.write(payload)
            except (BrokenPipeError, ConnectionResetError): pass
        def trusted(self):
            # No browser-origin access; Quenderin's authenticated local API is the caller.
            return not self.headers.get('Origin') and self.headers.get('Host') in {
                f'127.0.0.1:{self.server.server_port}', f'localhost:{self.server.server_port}'}
        def do_GET(self):
            if not self.trusted() or self.path != '/quenderin/step5':
                return self.send_json(404, {'error': 'Unknown route'})
            ready = False
            if alive():
                try: request('GET', '/health', timeout=2); ready = True
                except (OSError, ValueError, http.client.HTTPException): pass
            self.send_json(200, {'protocol': 1, 'modelRevision': MANIFEST['revision'],
                'backendRevision': MANIFEST['sourceBackend']['revision'], 'artifactsVerified': True,
                'ready': ready, 'maxOutputTokens': 1024, 'maxConcurrentRequests': 1})
        def do_POST(self):
            if not self.trusted() or self.path != '/quenderin/step5/answer':
                return self.send_json(404, {'error': 'Unknown route'})
            if not gate.acquire(blocking=False):
                return self.send_json(409, {'error': 'A Step 5 request is already running'})
            try:
                if self.headers.get('Transfer-Encoding') or not self.headers.get('Content-Length', '').isdigit():
                    raise ValueError('A bounded Content-Length is required')
                length = int(self.headers['Content-Length'])
                if not 1 <= length <= MAX_REQUEST: raise ValueError('Request exceeds 64 KiB')
                payload = self.rfile.read(length)
                if len(payload) != length: raise ValueError('Incomplete request')
                body = parse_json(payload)
                if not isinstance(body, dict) or set(body) != {'messages'}: raise ValueError('Only messages are accepted')
                messages = validate_messages(body['messages'])
                wire = json.dumps({'model': MANIFEST['servedModelName'], 'messages': messages,
                    'max_tokens': 1024, 'temperature': 0.6, 'stream': False, 'n': 1}).encode()
                self.send_json(200, final_answer(parse_json(request('POST', '/v1/chat/completions', wire, peer=self.connection))))
            except (ValueError, OSError, http.client.HTTPException, KeyError, TypeError):
                self.send_json(400, {'error': 'Step 5 request failed. Check backend readiness and bounded chat inputs.'})
            finally: gate.release()
    return Handler


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True, help='Clean checkout of the pinned official vLLM source')
    parser.add_argument('--model', type=Path, required=True, help='Complete already installed pinned FP8 checkpoint')
    parser.add_argument('--python', default=sys.executable, help='Existing Python environment with official backend dependencies')
    parser.add_argument('--port', type=int, default=18000)
    parser.add_argument('--backend-port', type=int, default=18001)
    parser.add_argument('--tensor-parallel-size', type=int, choices=[4, 8], default=4)
    parser.add_argument('--verify-only', action='store_true')
    args = parser.parse_args()
    if not 1024 <= args.port <= 65535 or not 1024 <= args.backend_port <= 65535 or args.port == args.backend_port:
        parser.error('Use two distinct unprivileged ports')
    source = verify_source(args.source)
    model = verify_model(args.model)
    if args.verify_only:
        print('Verified pinned Step 5 source and complete checkpoint. Inference was not run.')
        return
    if sys.platform != 'linux': parser.error('The official CUDA backend requires a suitable Linux GPU host')
    environment = {**os.environ, 'PYTHONPATH': str(source), 'HF_HUB_OFFLINE': '1', 'TRANSFORMERS_OFFLINE': '1',
                   'VLLM_NO_USAGE_STATS': '1', 'DO_NOT_TRACK': '1', 'HF_HUB_DISABLE_TELEMETRY': '1'}
    process = subprocess.Popen(backend_command(source, model, args.python, args.backend_port, args.tensor_parallel_size),
                               cwd=source, env=environment, start_new_session=True)
    server = None
    def stop(*_): raise KeyboardInterrupt()
    signal.signal(signal.SIGTERM, stop)
    try:
        server = BoundedHTTPServer(('127.0.0.1', args.port), make_handler(args.backend_port, lambda: process.poll() is None))
        print(f'Quenderin Step 5 gateway: http://127.0.0.1:{args.port}. No models are downloaded.')
        server.serve_forever(poll_interval=0.5)
    except KeyboardInterrupt: pass
    finally:
        if server: server.server_close()
        if process.poll() is None:
            os.killpg(process.pid, signal.SIGTERM)
            try: process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL); process.wait()


if __name__ == '__main__':
    try: main()
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(f'Step 5 could not start: {error}', file=sys.stderr)
        sys.exit(1)

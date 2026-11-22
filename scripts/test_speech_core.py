#!/usr/bin/env python3
"""No-weight host tests for native/speech C ABI, CLI, isolation, and WAV bounds."""
from __future__ import annotations

import ctypes as C
import importlib.util
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parent.parent
NATIVE = ROOT / "native/speech"
spec = importlib.util.spec_from_file_location("prepare_speech", ROOT / "scripts/prepare_speech_runtime.py")
prepare = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prepare)


class SpeechRequest(C.Structure):
    _fields_ = [
        ("abi_version", C.c_uint32),
        ("struct_size", C.c_size_t),
        ("model_path", C.c_char_p),
        ("vad_path", C.c_char_p),
        ("wav_path", C.c_char_p),
        ("pcm_f32", C.POINTER(C.c_float)),
        ("pcm_samples", C.c_size_t),
        ("sample_rate", C.c_uint32),
        ("language", C.c_char_p),
        ("prompt", C.c_char_p),
        ("vocabulary", C.POINTER(C.c_char_p)),
        ("vocabulary_count", C.c_uint32),
        ("threads", C.c_uint32),
        ("translate", C.c_bool),
        ("timestamps", C.c_bool),
    ]


class SpeechResult(C.Structure):
    _fields_ = [
        ("text", C.c_char_p),
        ("language", C.c_char_p),
        ("backend", C.c_char_p),
        ("segments_json", C.c_char_p),
        ("duration_ms", C.c_int64),
        ("truncated", C.c_bool),
        ("aborted", C.c_bool),
    ]


def write_wav(path: Path, samples: int = 1600, rate: int = 16000) -> Path:
    data = b"\x00\x00" * samples
    header = struct.pack("<4sI4s4sIHHIIHH4sI", b"RIFF", 36 + len(data), b"WAVE", b"fmt ", 16, 1, 1, rate, rate * 2, 2, 16, b"data", len(data))
    path.write_bytes(header + data)
    return path


class SpeechCoreTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        scratch = os.environ.get("QUENDERIN_DIFFUSION_TEST_SCRATCH") or tempfile.gettempdir()
        cls.temp = tempfile.TemporaryDirectory(prefix="speech-fixture-", dir=scratch)
        cls.base = Path(cls.temp.name).resolve()
        compiler = shutil.which("clang++") or shutil.which("g++")
        if not compiler:
            raise RuntimeError("C++ compiler unavailable")
        cls.library = cls.base / ("speech.dylib" if sys.platform == "darwin" else "speech.so")
        lock, _ = prepare.manifests()
        cmd = [
            compiler, "-std=c++17", "-O0", "-fPIC",
            "-dynamiclib" if sys.platform == "darwin" else "-shared", "-pthread",
            f'-DQUENDERIN_SPEECH_REVISION="{lock["revision"]}"',
            "-I", str(NATIVE / "tests"), "-I", str(NATIVE),
            str(NATIVE / "quenderin_speech.cpp"), str(NATIVE / "tests/transcribe_stub.cpp"),
            "-o", str(cls.library),
        ]
        if sys.platform == "darwin":
            cmd += ["-Wl,-exported_symbols_list," + str(NATIVE / "exports.apple")]
        else:
            cmd += ["-Wl,--version-script=" + str(NATIVE / "exports.map")]
        subprocess.run(cmd, check=True, capture_output=True, text=True)
        cls.cli = cls.base / "quenderin-speech-cli"
        subprocess.run([
            compiler, "-std=c++17", "-pthread", "-I", str(NATIVE),
            str(NATIVE / "speech_cli.cpp"), str(cls.library), "-Wl,-rpath," + str(cls.base), "-o", str(cls.cli),
        ], check=True, capture_output=True, text=True)
        cls.lib = C.CDLL(str(cls.library))
        cls.lib.quenderin_speech_create.restype = C.c_void_p
        cls.lib.quenderin_speech_destroy.argtypes = [C.c_void_p]
        cls.lib.quenderin_speech_cancel.argtypes = [C.c_void_p]
        cls.lib.quenderin_speech_validate.argtypes = [C.POINTER(SpeechRequest), C.c_char_p, C.c_size_t]
        cls.lib.quenderin_speech_transcribe.argtypes = [C.c_void_p, C.POINTER(SpeechRequest), C.POINTER(SpeechResult), C.c_char_p, C.c_size_t]
        cls.lib.quenderin_speech_result_free.argtypes = [C.POINTER(SpeechResult)]
        cls.lib.quenderin_speech_revision.restype = C.c_char_p

        for name in ("parakeet.gguf", "load-fail.gguf", "slow-cancel.gguf", "silero-vad.gguf"):
            (cls.base / name).write_bytes(b"GGUFfixture-speech")
        cls.wav = write_wav(cls.base / "clip.wav")
        cls.bad_rate_wav = write_wav(cls.base / "bad-rate.wav", rate=44100)

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def setUp(self):
        self.engine = self.lib.quenderin_speech_create()
        self.assertTrue(self.engine)

    def tearDown(self):
        self.assertEqual(self.lib.quenderin_speech_destroy(self.engine), 0)

    def request(self, **overrides):
        req = SpeechRequest(
            abi_version=1,
            struct_size=C.sizeof(SpeechRequest),
            model_path=str(self.base / "parakeet.gguf").encode(),
            vad_path=str(self.base / "silero-vad.gguf").encode(),
            wav_path=str(self.wav).encode(),
            sample_rate=16000,
            language=b"en",
            threads=2,
            translate=False,
            timestamps=True,
        )
        for k, v in overrides.items():
            setattr(req, k, v)
        return req

    def test_manifest_and_symbol_isolation(self):
        lock, catalog = prepare.manifests()
        self.assertEqual(self.lib.quenderin_speech_revision().decode(), lock["revision"])
        self.assertEqual(len(catalog["models"]), 20)
        self.assertIs(lock["inferenceVerified"], False)
        iso = prepare.verify_library(self.library, "apple" if sys.platform == "darwin" else "elf")
        self.assertTrue(iso["isolated"])

    def test_wav_and_vocabulary_transcription_via_c_abi_and_cli(self):
        terms = (C.c_char_p * 1)(b"Quenderin")
        res = SpeechResult()
        err = C.create_string_buffer(512)
        status = self.lib.quenderin_speech_transcribe(
            self.engine,
            C.byref(self.request(vocabulary=terms, vocabulary_count=1)),
            C.byref(res),
            err,
            len(err),
        )
        self.assertEqual(status, 0, err.value.decode())
        self.assertIn(b"Quenderin", res.text)
        self.assertEqual(res.backend, b"cpu-fixture")
        self.assertEqual(len(json.loads(res.segments_json.decode())), 1)
        self.lib.quenderin_speech_result_free(C.byref(res))

        version = json.loads(subprocess.check_output([str(self.cli), "--version"], text=True))
        self.assertEqual(version["abiVersion"], 1)
        cli_out = json.loads(subprocess.check_output([
            str(self.cli), "--model", str(self.base / "parakeet.gguf"),
            "--wav", str(self.wav), "--vocab", "Quenderin,Kromoss", "--timestamps",
        ], text=True))
        self.assertTrue(cli_out["ok"])
        self.assertIn("Quenderin", cli_out["text"])

    def test_rejects_bad_abi_symlinks_and_non_16k_wav(self):
        err = C.create_string_buffer(512)
        for bad in (
            {"abi_version": 99},
            {"threads": 9},
            {"sample_rate": 48000},
            {"wav_path": str(self.bad_rate_wav).encode()},
            {"model_path": str(self.base / "missing.gguf").encode()},
        ):
            status = self.lib.quenderin_speech_validate(C.byref(self.request(**bad)), err, len(err))
            self.assertEqual(status, 1)
        status = self.lib.quenderin_speech_transcribe(
            self.engine, C.byref(self.request(wav_path=str(self.bad_rate_wav).encode())), C.byref(SpeechResult()), err, len(err)
        )
        self.assertEqual(status, 1)

    def test_cancellation_and_busy_guards(self):
        res = SpeechResult()
        err = C.create_string_buffer(512)
        status_holder = []
        worker = threading.Thread(target=lambda: status_holder.append(
            self.lib.quenderin_speech_transcribe(
                self.engine, C.byref(self.request(model_path=str(self.base / "slow-cancel.gguf").encode())), C.byref(res), err, len(err)
            )
        ))
        worker.start()
        other = self.lib.quenderin_speech_create()
        import time
        time.sleep(0.02)
        self.assertEqual(self.lib.quenderin_speech_cancel(self.engine), 0)
        worker.join(2)
        self.assertFalse(worker.is_alive())
        self.assertEqual(status_holder[0], 3)
        self.assertEqual(self.lib.quenderin_speech_destroy(other), 0)


if __name__ == "__main__":
    unittest.main(verbosity=2)

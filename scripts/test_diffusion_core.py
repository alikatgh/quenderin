#!/usr/bin/env python3
"""No-weight host tests: compile only the small shim against a synthetic C API."""
from __future__ import annotations
import ctypes as C
import importlib.util
import hashlib
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
import zlib

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parent.parent
NATIVE = ROOT / "native/diffusion"
spec = importlib.util.spec_from_file_location("prepare_diffusion", ROOT / "scripts/prepare_diffusion_runtime.py")
prepare = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prepare)


class Image(C.Structure):
    _fields_ = [("width", C.c_uint32), ("height", C.c_uint32), ("channels", C.c_uint32), ("pixels", C.POINTER(C.c_uint8)), ("byte_count", C.c_size_t)]


class Request(C.Structure):
    _fields_ = [("abi_version", C.c_uint32), ("struct_size", C.c_size_t), ("model", C.c_int),
                *[(name, C.c_char_p) for name in ("diffusion_path", "text_encoder_path", "vae_path", "tokenizer_path", "prompt", "negative_prompt", "output_path")],
                *[(name, C.c_uint32) for name in ("width", "height", "steps", "threads")],
                ("seed", C.c_int64), ("reference_images", C.POINTER(Image)), ("reference_count", C.c_size_t)]


Progress = C.CFUNCTYPE(None, C.c_uint32, C.c_uint32, C.c_void_p)


class CoreTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        scratch = os.environ.get("QUENDERIN_DIFFUSION_TEST_SCRATCH")
        if not scratch:
            raise RuntimeError("Set QUENDERIN_DIFFUSION_TEST_SCRATCH to registered session scratch or hosted RUNNER_TEMP")
        cls.temp = tempfile.TemporaryDirectory(prefix="diffusion-fixture-", dir=scratch)
        cls.base = Path(cls.temp.name).resolve()
        compiler = shutil.which("clang++") or shutil.which("g++")
        if not compiler:
            raise RuntimeError("C++ compiler unavailable; native fixture verification is blocked")
        cls.library = cls.base / ("fixture.dylib" if sys.platform == "darwin" else "fixture.so")
        lock, _ = prepare.manifests()
        command = [compiler, "-std=c++17", "-O0", "-fPIC", "-dynamiclib" if sys.platform == "darwin" else "-shared", "-pthread",
                   f'-DQUENDERIN_DIFFUSION_REVISION="{lock["revision"]}"',
                   "-I", str(NATIVE / "tests"), "-I", str(NATIVE), str(NATIVE / "quenderin_diffusion.cpp"), str(NATIVE / "tests/stable-diffusion.cpp"), "-o", str(cls.library)]
        if sys.platform == "darwin":
            command += ["-Wl,-exported_symbols_list," + str(NATIVE / "exports.apple")]
        else:
            command += ["-Wl,--version-script=" + str(NATIVE / "exports.map")]
        subprocess.run(command, check=True, capture_output=True, text=True)
        cls.cli = cls.base / "quenderin-diffusion-cli"
        subprocess.run([compiler, "-std=c++17", "-pthread", "-I", str(NATIVE), str(NATIVE / "diffusion_cli.cpp"), str(cls.library), "-Wl,-rpath," + str(cls.base), "-o", str(cls.cli)], check=True, capture_output=True, text=True)
        cls.lib = C.CDLL(str(cls.library))
        cls.lib.quenderin_diffusion_create.restype = C.c_void_p
        cls.lib.quenderin_diffusion_destroy.argtypes = [C.c_void_p]
        cls.lib.quenderin_diffusion_cancel.argtypes = [C.c_void_p]
        cls.lib.quenderin_diffusion_validate.argtypes = [C.POINTER(Request), C.c_char_p, C.c_size_t]
        cls.lib.quenderin_diffusion_generate.argtypes = [C.c_void_p, C.POINTER(Request), Progress, C.c_void_p, C.c_char_p, C.c_size_t]
        cls.lib.quenderin_diffusion_revision.restype = C.c_char_p
        for name in ("model.safetensors", "vae.safetensors", "moss-tokenizer.json", "load-fail.safetensors"):
            (cls.base / name).write_bytes(b'{"fixture":true}')
        (cls.base / "encoder.gguf").write_bytes(b"GGUFfixture-data")

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def setUp(self):
        self.engine = self.lib.quenderin_diffusion_create()
        self.assertTrue(self.engine)
        self.output = self.base / (self.id().split(".")[-1] + ".png")

    def tearDown(self):
        self.assertEqual(self.lib.quenderin_diffusion_destroy(self.engine), 0)

    def request(self, **changes):
        r = Request(abi_version=1, struct_size=C.sizeof(Request), model=1, width=64, height=64, steps=16, threads=2, seed=42)
        for name, path in (("diffusion_path", "model.safetensors"), ("text_encoder_path", "encoder.gguf"), ("vae_path", "vae.safetensors")):
            setattr(r, name, str(self.base / path).encode())
        r.prompt = b"fixture:success"
        r.output_path = str(self.output).encode()
        for key, value in changes.items():
            setattr(r, key, value)
        return r

    def validate(self, request):
        error = C.create_string_buffer(512)
        return self.lib.quenderin_diffusion_validate(C.byref(request), error, len(error))

    def generate(self, request, callback=None):
        error = C.create_string_buffer(512)
        status = self.lib.quenderin_diffusion_generate(self.engine, C.byref(request), callback or Progress(), None, error, len(error))
        return status, error.value.decode()

    def test_manifest_provenance_and_complete_roles(self):
        lock, catalog = prepare.manifests()
        self.assertEqual(self.lib.quenderin_diffusion_revision().decode(), lock["revision"])
        self.assertEqual(len(catalog["models"]), 3)
        self.assertIs(lock["inferenceVerified"], False)

    def test_exports_isolate_all_ggml_sd_and_cpp_symbols(self):
        result = prepare.verify_library(self.library, "apple" if sys.platform == "darwin" else "elf")
        self.assertTrue(result["isolated"])

    def test_png_output_has_valid_chunks_and_pixels(self):
        self.assertEqual(self.generate(self.request())[0], 0)
        data = self.output.read_bytes(); self.assertEqual(data[:8], b"\x89PNG\r\n\x1a\n")
        offset, compressed = 8, b""
        while offset < len(data):
            size = struct.unpack(">I", data[offset:offset+4])[0]
            kind, payload = data[offset+4:offset+8], data[offset+8:offset+8+size]
            self.assertEqual(struct.unpack(">I", data[offset+8+size:offset+12+size])[0], zlib.crc32(kind+payload))
            if kind == b"IDAT": compressed += payload
            if kind == b"IHDR": self.assertEqual(struct.unpack(">II", payload[:8]), (64, 64))
            offset += 12+size
        pixels = zlib.decompress(compressed); self.assertEqual(len(pixels), (64*3+1)*64)
        self.assertEqual(pixels[:4], b"\x00{{{")

    def test_moss_required_tokenizer_and_fixed_policy(self):
        self.assertEqual(self.validate(self.request(model=3)), 1)
        request = self.request(model=3, tokenizer_path=str(self.base / "moss-tokenizer.json").encode(), steps=50)
        self.assertEqual(self.generate(request)[0], 0)

    def test_bounds_abi_and_required_component_rejection(self):
        for changes in ({"abi_version": 2}, {"width": 2048}, {"height": 65}, {"steps": 51}, {"threads": 9}, {"seed": -1}, {"model": 99}, {"diffusion_path": b"https://example/model.safetensors"}, {"text_encoder_path": str(self.base / "missing.gguf").encode()}):
            with self.subTest(changes=changes): self.assertEqual(self.validate(self.request(**changes)), 1)

    def test_existing_output_is_preserved(self):
        self.output.write_bytes(b"user-original")
        self.assertEqual(self.generate(self.request())[0], 1)
        self.assertEqual(self.output.read_bytes(), b"user-original")

    def test_racing_output_creation_is_preserved(self):
        @Progress
        def callback(step, total, _):
            if step == total: self.output.write_bytes(b"racing-original")
        self.assertEqual(self.generate(self.request(), callback)[0], 6)
        self.assertEqual(self.output.read_bytes(), b"racing-original")

    def test_symlink_model_and_output_are_rejected(self):
        link = self.base / "linked.safetensors"; link.symlink_to(self.base / "model.safetensors")
        self.assertEqual(self.validate(self.request(diffusion_path=str(link).encode())), 1)
        self.output.symlink_to(self.base / "user-absent.png")
        self.assertEqual(self.validate(self.request()), 1)
        self.assertTrue(self.output.is_symlink())

    def test_generation_and_load_failures_leave_no_output(self):
        self.assertEqual(self.generate(self.request(prompt=b"fixture:fail"))[0], 5)
        self.assertFalse(self.output.exists())
        self.assertEqual(self.generate(self.request(diffusion_path=str(self.base / "load-fail.safetensors").encode()))[0], 4)
        self.assertFalse(self.output.exists())

    def test_concurrent_jobs_destroy_and_cancel(self):
        started = threading.Event(); result = []
        @Progress
        def callback(step, total, _): started.set()
        request = self.request()
        worker = threading.Thread(target=lambda: result.append(self.generate(request, callback)))
        worker.start(); self.assertTrue(started.wait(2))
        other = self.lib.quenderin_diffusion_create()
        error = C.create_string_buffer(512)
        self.assertEqual(self.lib.quenderin_diffusion_generate(other, C.byref(request), Progress(), None, error, len(error)), 2)
        self.assertEqual(self.lib.quenderin_diffusion_destroy(self.engine), 2)
        self.assertEqual(self.lib.quenderin_diffusion_cancel(self.engine), 0)
        worker.join(2); self.assertFalse(worker.is_alive())
        self.assertEqual(result[0][0], 3); self.assertFalse(self.output.exists())
        self.assertEqual(self.lib.quenderin_diffusion_destroy(other), 0)

    def test_reference_set_is_strict_and_moss_rejects_references(self):
        self.assertEqual(self.validate(self.request(reference_count=11)), 1)
        pixels = (C.c_uint8 * (64*64*3))()
        images = (Image * 1)(Image(64, 64, 3, pixels, len(pixels)))
        request = self.request(reference_images=images, reference_count=1)
        self.assertEqual(self.generate(request)[0], 0)
        self.assertEqual(self.validate(self.request(model=2, tokenizer_path=str(self.base / "moss-tokenizer.json").encode(), reference_images=images, reference_count=1)), 1)

    def test_cli_protocol_and_generation(self):
        version = json.loads(subprocess.check_output([str(self.cli), "--version"], text=True))
        self.assertEqual(version["abiVersion"], 1)
        result = subprocess.run([str(self.cli), "--model", "flux3-image-klein", "--diffusion", str(self.base / "model.safetensors"), "--text-encoder", str(self.base / "encoder.gguf"), "--vae", str(self.base / "vae.safetensors"), "--prompt", "fixture:success", "--output", str(self.output), "--width", "64", "--height", "64"], capture_output=True, text=True, check=True)
        self.assertTrue(json.loads(result.stdout)["ok"])
        self.assertEqual(json.loads(result.stderr.splitlines()[0])["step"], 1)
        rejected = subprocess.run([str(self.cli), "--unknown", "value"], capture_output=True, text=True)
        self.assertEqual(rejected.returncode, 1)
        self.assertFalse(json.loads(rejected.stdout)["ok"])

    def test_source_fetch_preserves_existing_destination(self):
        with self.assertRaisesRegex(ValueError, "Destination exists"):
            prepare.fetch(self.base)

    def test_component_hash_verification_is_offline_and_detects_tampering(self):
        fixture = self.base / "component-integrity"; fixture.mkdir()
        file = fixture / "component.gguf"; file.write_bytes(b"GGUFfixture")
        component = {"role": "text_encoder", "localFilename": file.name, "bytes": file.stat().st_size, "sha256": hashlib.sha256(file.read_bytes()).hexdigest()}
        catalog = {"models": [{"id": "fixture", "modelKind": 1, "components": [component]}]}
        with patch.object(prepare, "manifests", return_value=({}, catalog)):
            self.assertEqual(prepare.verify_components("fixture", fixture)["components"]["text_encoder"], str(file))
            file.write_bytes(b"GGUFtamper!")
            with self.assertRaisesRegex(ValueError, "digest differs"):
                prepare.verify_components("fixture", fixture)


if __name__ == "__main__":
    unittest.main(verbosity=2)

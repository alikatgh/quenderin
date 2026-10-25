"""Pure-data source-generation fixtures; the compiler callback never executes."""
import copy
import hashlib
import pathlib
import sys
import tempfile
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / "tools"))
from cpu_profile import build_projection, canonical_sha, prepare_installation, verify_tree
from source_shmem import ARGUMENTS, MODULE_PATH, generate_module, generation_files, validate_recipe
from test_cpu_profile import fixture, inert_install


def setup(root):
    lock, native, wheels, payloads = fixture(root)
    profile = lock["cpu_fixture_profile"]
    recipe = profile["generated_source_module"]
    projection = build_projection(lock, wheels, native)
    sdk = inert_install(root, projection, payloads)
    compiler = sdk / recipe["compiler"]["installed_path"]
    compiler.parent.mkdir(parents=True, exist_ok=True)
    compiler.write_bytes(b"inert compiler fixture: never execute")
    recipe["compiler"].update(sha256=hashlib.sha256(compiler.read_bytes()).hexdigest(), size=compiler.stat().st_size)
    projection["expected"][recipe["compiler"]["installed_path"]] = {
        "package": "mojo-compiler", "kind": "archive", "sha256": recipe["compiler"]["sha256"], "size": compiler.stat().st_size}
    for name in recipe["module_inputs"]:
        relative = "modular/lib/mojo/" + name
        path = sdk / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(("inert upstream dependency " + name).encode())
        projection["expected"][relative] = {"package": "max-mojo-libs", "kind": "archive",
            "sha256": hashlib.sha256(path.read_bytes()).hexdigest(), "size": path.stat().st_size}
    sources = root / "cpu-sources/shmem"
    sources.mkdir(parents=True)
    header = b"# Licensed under the Apache License v2.0 with LLVM Exceptions\n"
    for item in recipe["sources"]:
        data = header + b" " * (item["size"] - len(header))
        (sources / item["filename"]).write_bytes(data)
        item["sha256"] = hashlib.sha256(data).hexdigest()
    projection["profileSHA256"] = canonical_sha(profile)
    manifest = prepare_installation(sdk, projection, profile)
    scratch = root / "runtime"
    scratch.mkdir()
    return profile, sdk, manifest, scratch


class SourceShmem(unittest.TestCase):
    def test_attested_generation_uses_only_upstream_precompile_flags(self):
        with tempfile.TemporaryDirectory(prefix="quenderin-source-shmem-") as directory:
            root = pathlib.Path(directory)
            profile, sdk, manifest, scratch = setup(root)
            calls = []
            def inert_compiler(command, **kwargs):
                calls.append(command)
                self.assertEqual(command[0], str(sdk / "modular/bin/mojo"))
                self.assertEqual(command[1], "precompile")
                self.assertFalse(any("bitcode" in arg or "target-accelerator" in arg for arg in command))
                include = pathlib.Path(command[command.index("-I") + 1])
                self.assertEqual({path.name for path in include.iterdir()}, set(profile["generated_source_module"]["module_inputs"]))
                pathlib.Path(command[command.index("-o") + 1]).write_bytes(b"inert newly generated upstream module")
            updated, receipt = generate_module(root, sdk, scratch, manifest, profile, {}, 123, inert_compiler)
            self.assertEqual(len(calls), 1)
            self.assertEqual(receipt["arguments"], ARGUMENTS)
            self.assertEqual(receipt["compilerExitCode"], 0)
            self.assertFalse(receipt["sdkPythonImported"])
            self.assertEqual(len(receipt["sourceInputs"]), 9)
            self.assertEqual(len(receipt["moduleInputs"]), 10)
            self.assertEqual(verify_tree(sdk, manifest["sourceProjection"], profile, [receipt]), updated["files"])
            (sdk / MODULE_PATH).write_bytes(b"mutated generated module")
            with self.assertRaisesRegex(ValueError, "generated module identity"):
                verify_tree(sdk, manifest["sourceProjection"], profile, [receipt])

    def test_source_or_compiler_failure_never_admits_a_module(self):
        for failure in ["source-mutant", "compiler-failure", "original-packaged-module", "elf-output", "input-changed-during-compile"]:
            with self.subTest(failure=failure), tempfile.TemporaryDirectory(prefix="quenderin-source-shmem-") as directory:
                root = pathlib.Path(directory)
                profile, sdk, manifest, scratch = setup(root)
                if failure == "source-mutant":
                    (root / "cpu-sources/shmem/__init__.mojo").write_bytes(b"mutant")
                def fail(command, **kwargs):
                    if failure == "compiler-failure":
                        raise ValueError("bounded compiler failed")
                    if failure == "input-changed-during-compile":
                        include = pathlib.Path(command[command.index("-I") + 1])
                        (include / "std.mojoc").write_bytes(b"mutant input")
                    output = pathlib.Path(command[command.index("-o") + 1])
                    data = b"\x7fELF-inert" if failure == "elf-output" else b"inert excluded compiled-wrapper fixture"
                    output.write_bytes(data)
                with self.assertRaises(ValueError):
                    generate_module(root, sdk, scratch, manifest, profile, {}, 123, fail)
                self.assertFalse((sdk / MODULE_PATH).exists())

    def test_bitcode_arguments_and_mutated_attestation_are_rejected(self):
        with tempfile.TemporaryDirectory(prefix="quenderin-source-shmem-") as directory:
            root = pathlib.Path(directory)
            profile, sdk, manifest, scratch = setup(root)
            bad = copy.deepcopy(profile)
            bad["generated_source_module"]["arguments"].append("--bitcode-libs=forbidden.bc")
            with self.assertRaises(ValueError):
                validate_recipe(bad)
            def inert(command, **kwargs):
                pathlib.Path(command[command.index("-o") + 1]).write_bytes(b"fresh fixture module")
            _, receipt = generate_module(root, sdk, scratch, manifest, profile, {}, 123, inert)
            receipt["moduleInputs"][0]["sha256"] = "0" * 64
            with self.assertRaisesRegex(ValueError, "attestation"):
                generation_files(profile, manifest["sourceProjection"], [receipt])


if __name__ == "__main__":
    unittest.main()

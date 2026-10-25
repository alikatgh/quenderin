"""Source-only projection fixtures. No SDK, ELF, compiler or loader is run."""
import copy
import hashlib
import json
import pathlib
import sys
import tempfile
import unittest
import zipfile

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / "tools"))
from gates import ROOT, load_lock
from cpu_profile import (NVSHMEM_NAMES, OMITTED_MOJO, PROFILE_ID, build_projection, canonical_sha,
                         check_loader_snapshot, configured_loader_directories, installed_path,
                         loader_directories, prepare_installation, validate_profile, verify_installation)


def fixture(root):
    wheels = root / "wheels"
    wheels.mkdir()
    wrapper = b"inert excluded compiled-wrapper fixture"
    payloads = {"max": {"max/driver.py": b"raise RuntimeError('never import')",
                        "max-26.7.0.dist-info/LICENSE": b"keep exact license",
                        "max-26.7.0.dist-info/Third-Party-Notices": b"keep NVSHMEM attribution"},
                "max-core": {"max_core-26.7.0.data/platlib/modular/lib/libmax.so": b"\x7fELF-inert-cpu-fixture"},
                "max-mojo-libs": {OMITTED_MOJO: wrapper, "modular/lib/mojo/algorithm.mojoc": b"keep CPU fixture"},
                "max-shmem-libs": {"max_shmem_libs-26.7.0.data/platlib/modular/lib/" + name:
                                     b"\x7fELF-inert-" + name.encode() for name in sorted(NVSHMEM_NAMES)}}
    packages, elfs = [], []
    for name, files in payloads.items():
        dist = name.replace("-", "_") + "-26.7.0.dist-info"
        files.update({dist + "/METADATA": f"Name: {name}\nVersion: 26.7.0\n".encode(), dist + "/RECORD": b"source record"})
        if name == "max":
            files[dist + "/entry_points.txt"] = b"[console_scripts]\nfixture-cli = max.driver:main\n"
        path = wheels / (name + ".whl")
        with zipfile.ZipFile(path, "w") as wheel:
            for member, data in files.items():
                wheel.writestr(member, data)
                if data.startswith(b"\x7fELF"):
                    elfs.append({"package": name, "path": member, "size": len(data), "sha256": hashlib.sha256(data).hexdigest(),
                                 "needed": ["libc.so.6"], "rpath": ["$ORIGIN"], "runpath": []})
        packages.append({"name": name, "version": "26.7.0", "filename": path.name,
                         "sha256": hashlib.sha256(path.read_bytes()).hexdigest(), "size": path.stat().st_size})
    native = {"sdkCodeExecuted": False, "cpuOmissionAdmitted": False, "elfs": elfs,
              "artifacts": [{key: package[key] for key in ["name", "version", "sha256"]} for package in packages],
              "sharedMemoryArtifacts": [{"package": "max-mojo-libs", "path": OMITTED_MOJO, "size": len(wrapper),
                                          "sha256": hashlib.sha256(wrapper).hexdigest()}],
              "maxShmemPackagePayloads": [item["path"] for item in elfs if item["package"] == "max-shmem-libs"],
              "pythonImports": [{"package": "max", "path": name, "sharedMemoryReferences": []} for name in
                                ["max/driver/__init__.py", "max/driver/driver.py", "max/engine/__init__.py", "max/engine/api.py", "max/graph/__init__.py"]]}
    native["evidenceSHA256"] = canonical_sha(native)
    profile = {"schema": 1, "id": PROFILE_ID, "scope": "hosted-cpu-fixture-only-no-redistribution",
               "native_evidence_sha256": native["evidenceSHA256"], "omitted_packages": ["max-shmem-libs"],
               "omitted_package_payloads": [{key: item[key] for key in ["package", "path", "size", "sha256"]}
                                            for item in elfs if item["package"] == "max-shmem-libs"],
               "omitted_files": [{**native["sharedMemoryArtifacts"][0], "installed_path": installed_path(OMITTED_MOJO)}],
               "generated_console_scripts": "omit", "runtime_license_approval_inferred": False,
               "generated_source_module": copy.deepcopy(load_lock()["cpu_fixture_profile"]["generated_source_module"]),
               "declared_dependency_exception": {"package": "max-core", "requirement": "max-shmem-libs==26.7.0", "reason": "inert unit fixture"}}
    lock = {"packages": packages, "maximum_uncompressed_bytes": 100000, "cpu_fixture_profile": profile}
    return lock, native, wheels, payloads


def inert_install(root, projection, payloads):
    sdk = root / "sdk"
    sdk.mkdir()
    for name, files in payloads.items():
        if name == "max-shmem-libs":
            continue
        for member, data in files.items():
            target = sdk / installed_path(member)
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
    for dist, source in projection["distributions"].items():
        (sdk / dist / "INSTALLER").write_bytes(b"pip\n")
        (sdk / dist / "REQUESTED").write_bytes(b"")
        (sdk / dist / "direct_url.json").write_text(json.dumps({"url": source["url"], "archive_info": {"hashes": {"sha256": source["sha256"]}}}))
        (sdk / dist / "RECORD").write_bytes(b"installer-updated record")
    (sdk / "bin").mkdir()
    (sdk / "bin/fixture-cli").write_bytes(b"inert generated wrapper; never execute")
    return sdk


class CpuProfile(unittest.TestCase):
    def test_actual_profile_matches_retained_nonexecuting_audit(self):
        native = json.loads((ROOT / "tests/fixtures/native-audit-40101507948.json").read_text())
        decision = validate_profile(load_lock(), native)
        self.assertEqual(decision["omittedPackages"], ["max-shmem-libs"])
        self.assertEqual(len(decision["retainedPackages"]), 16)
        self.assertFalse(decision["runtimeAdmissionInferred"])
        self.assertTrue(loader_directories(pathlib.Path("/owned/cpu/sdk"), native))

    def test_exact_projection_removes_gpu_components_and_preserves_notices(self):
        with tempfile.TemporaryDirectory(prefix="quenderin-cpu-profile-") as directory:
            root = pathlib.Path(directory)
            lock, native, wheels, payloads = fixture(root)
            projection = build_projection(lock, wheels, native)
            self.assertNotIn("max-shmem-libs", projection["retainedPackages"])
            sdk = inert_install(root, projection, payloads)
            manifest = prepare_installation(sdk, projection, lock["cpu_fixture_profile"])
            self.assertFalse((sdk / "modular/lib/mojo/shmem.mojoc").exists())
            self.assertFalse((sdk / "bin").exists())
            self.assertEqual((sdk / "max-26.7.0.dist-info/Third-Party-Notices").read_bytes(), b"keep NVSHMEM attribution")
            verify_installation(sdk, manifest, lock, native)

    def test_profile_rejects_mutated_receipts_and_required_gpu_dependency(self):
        with tempfile.TemporaryDirectory(prefix="quenderin-cpu-profile-") as directory:
            lock, native, _, _ = fixture(pathlib.Path(directory))
            changed = copy.deepcopy(lock)
            changed["cpu_fixture_profile"]["omitted_files"][0]["sha256"] = "0" * 64
            with self.assertRaisesRegex(ValueError, "shmem.mojoc"):
                validate_profile(changed, native)
            changed_native = copy.deepcopy(native)
            changed_native["elfs"][0]["needed"].append("libnvshmem_host.so.3")
            changed_native["evidenceSHA256"] = canonical_sha({key: value for key, value in changed_native.items() if key != "evidenceSHA256"})
            changed = copy.deepcopy(lock)
            changed["cpu_fixture_profile"]["native_evidence_sha256"] = changed_native["evidenceSHA256"]
            with self.assertRaisesRegex(ValueError, "Retained ELF requires"):
                validate_profile(changed, changed_native)

    def test_installed_mutant_extra_missing_and_renamed_payloads_fail(self):
        for mutation in ["changed", "extra", "missing", "renamed-gpu", "bad-installer"]:
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory(prefix="quenderin-cpu-profile-") as directory:
                root = pathlib.Path(directory)
                lock, native, wheels, payloads = fixture(root)
                projection = build_projection(lock, wheels, native)
                sdk = inert_install(root, projection, payloads)
                manifest = prepare_installation(sdk, projection, lock["cpu_fixture_profile"])
                if mutation == "changed":
                    (sdk / "max/driver.py").write_bytes(b"mutant")
                elif mutation == "extra":
                    (sdk / "unexpected.py").write_bytes(b"extra")
                elif mutation == "missing":
                    (sdk / "max/driver.py").unlink()
                elif mutation == "renamed-gpu":
                    (sdk / "renamed.so").write_bytes(next(data for name, data in payloads["max-shmem-libs"].items() if name.endswith("libnvshmem_host.so.3")))
                else:
                    (sdk / "max-26.7.0.dist-info/INSTALLER").write_bytes(b"unknown\n")
                with self.assertRaises(ValueError):
                    verify_installation(sdk, manifest, lock, native)

    def test_wrong_omitted_file_and_unknown_generated_script_fail_before_import(self):
        for mutation in ["wrong-wrapper", "unknown-script"]:
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory(prefix="quenderin-cpu-profile-") as directory:
                root = pathlib.Path(directory)
                lock, native, wheels, payloads = fixture(root)
                projection = build_projection(lock, wheels, native)
                sdk = inert_install(root, projection, payloads)
                if mutation == "wrong-wrapper":
                    (sdk / "modular/lib/mojo/shmem.mojoc").write_bytes(b"wrong component")
                else:
                    (sdk / "bin/unknown").write_bytes(b"unregistered")
                with self.assertRaises(ValueError):
                    prepare_installation(sdk, projection, lock["cpu_fixture_profile"])

    def test_loader_cache_maps_preload_and_directory_presence_fail_closed(self):
        check_loader_snapshot("libc.so => /lib/libc.so", "/lib/libc.so", "# empty", {"/lib": ["libc.so"]})
        for values in [("libnvshmem_host.so.3 => /lib/libnvshmem_host.so.3", "", "", {}),
                       ("", "/lib/libnvshmem_host.so.3", "", {}), ("", "", "/tmp/unapproved.so", {}),
                       ("", "", "", {"/lib": ["nvshmem_transport_ibgda.so.6"]})]:
            with self.assertRaises(ValueError):
                check_loader_snapshot(*values)
        with tempfile.TemporaryDirectory(prefix="quenderin-cpu-profile-") as directory:
            config = pathlib.Path(directory) / "ld.so.conf"
            config.write_text("/usr/local/lib\n# comment\n")
            self.assertEqual(configured_loader_directories(config), {pathlib.Path("/usr/local/lib").resolve()})
            config.write_text("include /unreviewed/*.conf\n")
            with self.assertRaises(ValueError):
                configured_loader_directories(config)


if __name__ == "__main__":
    unittest.main()

"""Bounded, offline hosted CPU graph execution. No MAX import in supervisor."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import pathlib
import resource
import selectors
import signal
import subprocess
import time

from gates import ROOT, assert_network, assert_status, load_lock, require_hosted, runtime_environment, verify_license_review
from cpu_profile import validate_profile, verify_installation, verify_loader_absence


def bounded(command: list[str], *, env: dict[str, str], cwd: pathlib.Path, deadline: float,
            max_output_bytes: int = 65536) -> tuple[bytes, bytes]:
    if type(max_output_bytes) is not int or not 1 <= max_output_bytes <= 1048576:
        raise ValueError("Invalid bounded process output budget")
    if time.monotonic() >= deadline:
        raise ValueError("Aggregate CPU fixture deadline exceeded")
    process = subprocess.Popen(command, cwd=cwd, env=env, stdin=subprocess.DEVNULL,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
    output = {"stdout": bytearray(), "stderr": bytearray()}
    output_bytes = 0
    selector = selectors.DefaultSelector()
    try:
        for name, pipe in [("stdout", process.stdout), ("stderr", process.stderr)]:
            os.set_blocking(pipe.fileno(), False)
            selector.register(pipe, selectors.EVENT_READ, data=name)
        while selector.get_map():
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise ValueError("Aggregate CPU fixture deadline exceeded")
            for key, _ in selector.select(min(remaining, 0.1)):
                data = os.read(key.fd, 65536)
                if not data:
                    selector.unregister(key.fileobj)
                    continue
                remaining_bytes = max(0, max_output_bytes - output_bytes)
                output[key.data].extend(data[:remaining_bytes])
                output_bytes += len(data)
                if output_bytes > max_output_bytes:
                    raise ValueError(f"CPU fixture output exceeded {max_output_bytes // 1024} KiB")
        process.wait(timeout=max(0.001, deadline - time.monotonic()))
        if process.returncode:
            # The canned public fixture has no credentials, prompts or model
            # content; the diagnostic is nevertheless capped to 8 KiB.
            diagnostics = "\n".join(f"{name}: {bytes(output[name][-4096:]).decode('utf-8', errors='replace')}"
                                    for name in ["stdout", "stderr"])
            raise ValueError(f"CPU fixture process failed ({process.returncode}): {diagnostics}")
        return bytes(output["stdout"]), bytes(output["stderr"])
    finally:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait(timeout=5)
        selector.close()
        process.stdout.close()
        process.stderr.close()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--work", type=pathlib.Path, required=True)
    parser.add_argument("--reviewed-lock", required=True)
    args = parser.parse_args()
    require_hosted()
    assert_status(pathlib.Path("/proc/self/status").read_text())
    assert_network(os.environ.get("QUENDERIN_PARENT_NETNS", ""), os.readlink("/proc/self/ns/net"),
                   pathlib.Path("/proc/net/dev").read_text(), pathlib.Path("/proc/net/route").read_text(),
                   pathlib.Path("/proc/net/ipv6_route").read_text())
    lock = load_lock(reviewed=args.reviewed_lock)
    work = args.work.resolve(strict=True)
    inspection = json.loads((work / "inspection.json").read_text())
    native = inspection.get("nativeEvidence", {})
    profile = validate_profile(lock, native)
    review = lock.get("runtime_license_review")
    license_hashes = inspection.get("licenseSHA256")
    if not isinstance(license_hashes, dict) or any(not isinstance(key, str) or "/" not in key for key in license_hashes):
        raise ValueError("Exact inspected license provenance required")
    verify_license_review(lock, [{"package": key.split("/", 1)[0], "path": key.split("/", 1)[1], "sha256": value}
                                 for key, value in license_hashes.items()])
    if (work.is_symlink() or work.stat().st_uid != os.getuid()
            or json.loads((work / "installed.json").read_text()).get("lockSHA256") != lock["lock_sha256"]
            or inspection.get("lockSHA256") != lock["lock_sha256"] or not isinstance(review, dict)
            or review.get("scope") != "hosted-cpu-fixture-only-no-redistribution"
            or not inspection.get("licenseSHA256") or review.get("license_sha256") != inspection["licenseSHA256"]):
        raise ValueError("Owned reviewed offline SDK installation required")
    sdk = work / "sdk"
    manifest_path = work / "cpu-install-manifest.json"
    if manifest_path.is_symlink() or not manifest_path.is_file() or manifest_path.stat().st_size > 4194304:
        raise ValueError("Bounded exact CPU installation manifest required")
    manifest_raw = manifest_path.read_bytes()
    receipt = json.loads((work / "installed.json").read_text())
    if (receipt.get("cpuProfileSHA256") != profile["profileSHA256"]
            or receipt.get("manifestSHA256") != hashlib.sha256(manifest_raw).hexdigest()
            or receipt.get("stagingWheelsRemoved") is not True or (work / "wheels").exists()):
        raise ValueError("CPU installation profile receipt differs")
    manifest = json.loads(manifest_raw)
    verify_installation(sdk, manifest, lock, native)
    libraries = sorted({path.parent for path in sdk.rglob("*.so*") if path.is_file()})
    max_libraries = [path for path in sdk.rglob("libmax.so") if path.is_file() and not path.is_symlink()]
    if len(max_libraries) != 1 or len(libraries) > 64:
        raise ValueError("One real pinned MAX C API library required")
    scratch = work / "runtime"
    scratch.mkdir(mode=0o700)
    env = runtime_environment(scratch, sdk, libraries)
    # Bounds apply to compiler/exporter/executor descendants too. A separate
    # network namespace and no capabilities prevent enabling external transport.
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    resource.setrlimit(resource.RLIMIT_CPU, (120, 120))
    resource.setrlimit(resource.RLIMIT_AS, (4 * 1024**3, 4 * 1024**3))
    resource.setrlimit(resource.RLIMIT_FSIZE, (64 * 1024**2, 64 * 1024**2))
    resource.setrlimit(resource.RLIMIT_NOFILE, (256, 256))
    resource.setrlimit(resource.RLIMIT_NPROC, (256, 256))
    allowed = sorted(os.sched_getaffinity(0))[:2]
    if not allowed:
        raise ValueError("Included CPU runner required")
    os.sched_setaffinity(0, allowed)
    deadline = time.monotonic() + lock["maximum_runtime_seconds"]
    absence = verify_loader_absence(sdk, native, deadline)
    executable = scratch / "max-cpu-fixture"
    compile_command = ["/usr/bin/cc", "-std=c11", "-O1", "-Wall", "-Wextra", "-Werror",
                       "-I", str(ROOT / "include"), "-I", str(work / "include"),
                       str(ROOT / "src/quenderin_max.c"), str(ROOT / "fixture/smoke.c"),
                       "-L", str(max_libraries[0].parent), "-lmax", "-o", str(executable)]
    bounded(compile_command, env=env, cwd=scratch, deadline=deadline)
    graph = scratch / "weighted-multiply.mef"
    verify_installation(sdk, manifest, lock, native)
    absence = verify_loader_absence(sdk, native, deadline)
    bounded(["/usr/bin/python3", "-S", "-B", str(ROOT / "fixture/export_graph.py"), str(graph)],
            env=env, cwd=scratch, deadline=deadline)
    verify_installation(sdk, manifest, lock, native)
    absence = verify_loader_absence(sdk, native, deadline)
    facts, _diagnostics = bounded([str(executable), str(graph)], env=env, cwd=scratch, deadline=deadline)
    parsed = json.loads(facts)
    if (parsed.get("schema") != 1 or parsed.get("output") != [2, 6, 12, 20]
            or parsed.get("executions") != 3 or parsed.get("llmInference") is not False):
        raise ValueError("Actual C API CPU graph result differs")
    print("QUENDERIN_MAX_CPU_FACTS_BEGIN")
    print(json.dumps({**parsed, "lockSHA256": lock["lock_sha256"],
                      "mefSHA256": hashlib.sha256(graph.read_bytes()).hexdigest(),
                      "networkIsolated": True, "telemetryOptOut": True, "crashReportingOptOut": True,
                      "cpuProfileSHA256": profile["profileSHA256"], "installedManifestSHA256": hashlib.sha256(manifest_raw).hexdigest(),
                      "loaderAbsence": absence}))
    print("QUENDERIN_MAX_CPU_FACTS_END")


if __name__ == "__main__":
    main()

"""Hosted-only sanitizer test with an inert C ABI double, never the MAX SDK."""
import argparse
import os
import pathlib
import subprocess

from gates import ROOT, require_hosted


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--work", type=pathlib.Path, required=True)
    args = parser.parse_args()
    require_hosted()
    work = args.work.resolve()
    runner_temp = pathlib.Path(os.environ["RUNNER_TEMP"]).resolve()
    if not work.is_relative_to(runner_temp) or work == runner_temp or work.exists():
        raise ValueError("New owned hosted scratch required")
    work.mkdir(mode=0o700)
    (work / ".quenderin-max-session-owned").write_text("max-fixture-v1\n")
    include = work / "include/max/c"
    include.mkdir(parents=True)
    for name in ["common", "context", "device", "model", "tensor", "weights"]:
        (include / f"{name}.h").write_text('#include "fake_max.h"\n')
    env = {"PATH": "/usr/bin:/bin", "HOME": str(work), "TMPDIR": str(work), "LANG": "C.UTF-8",
           "MODULAR_TELEMETRY_ENABLED": "0", "MODULAR_CRASH_REPORTING_ENABLED": "0",
           "ASAN_OPTIONS": "detect_leaks=1:halt_on_error=1", "UBSAN_OPTIONS": "halt_on_error=1"}
    executable = work / "fake-c-lifecycle"
    subprocess.run(["/usr/bin/cc", "-std=c11", "-Wall", "-Wextra", "-Werror", "-O1", "-g",
                    "-fsanitize=address,undefined", "-fno-omit-frame-pointer",
                    "-I", str(ROOT / "include"), "-I", str(work / "include"), "-I", str(ROOT / "tests"),
                    str(ROOT / "src/quenderin_max.c"), str(ROOT / "tests/fake_max.c"), "-o", str(executable)],
                   env=env, timeout=30, check=True)
    graph = work / "inert-abi-test.mef"
    graph.write_bytes(b"TEST-not-a-real-MEF")
    subprocess.run([str(executable), str(graph)], env=env, timeout=15, check=True)


if __name__ == "__main__":
    main()

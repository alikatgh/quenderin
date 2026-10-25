"""Hosted fixture compile/run for the portable MAX model boundary.

Compiles the adapter with an inert runner double and sanitizers. No MAX SDK,
headers, weights, network or device are used. Local runs are allowed because
the fixture is fully synthetic; unlike the SDK scripts, nothing is installed.
"""
import argparse
import os
import pathlib
import subprocess
import sys

from gates import ROOT


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--work", type=pathlib.Path, required=True)
    parser.add_argument("--cc", default="cc")
    args = parser.parse_args()
    work = args.work.resolve()
    if work.exists():
        raise ValueError("A new scratch directory is required")
    work.mkdir(mode=0o700, parents=True)
    (work / ".quenderin-max-session-owned").write_text("max-model-fixture-v1\n")
    env = {
        "PATH": "/usr/bin:/bin:/usr/local/bin",
        "HOME": str(work),
        "TMPDIR": str(work),
        "LANG": "C.UTF-8",
        "MODULAR_TELEMETRY_ENABLED": "0",
        "MODULAR_CRASH_REPORTING_ENABLED": "0",
        # Leak detection is Linux-only; Apple's ASan rejects the option.
        "ASAN_OPTIONS": "detect_leaks=1:halt_on_error=1" if sys.platform.startswith("linux") else "halt_on_error=1",
        "UBSAN_OPTIONS": "halt_on_error=1",
    }
    executable = work / "max-model-double"
    command = [
        args.cc, "-std=c11", "-Wall", "-Wextra", "-Werror", "-O1", "-g",
        "-fsanitize=address,undefined", "-fno-omit-frame-pointer", "-pthread",
        "-I", str(ROOT / "include"), "-I", str(ROOT / "tests"),
        str(ROOT / "src/quenderin_max_model.c"),
        str(ROOT / "tests/fake_model_runner.c"),
        str(ROOT / "fixture/model_smoke.c"),
        "-lm", "-o", str(executable),
    ]
    subprocess.run(command, env=env, timeout=60, check=True)
    artifacts = work / "artifacts"
    artifacts.mkdir()
    result = subprocess.run([str(executable), str(artifacts)], env=env, timeout=30,
                            check=True, capture_output=True, text=True)
    if "no MAX runtime or model used" not in result.stdout:
        raise ValueError("Fixture did not report its inert boundary")
    print(result.stdout, end="")


if __name__ == "__main__":
    main()

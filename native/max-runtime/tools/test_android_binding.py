"""Hosted JNI/JVM interoperability for the MAX model binding.

Builds the canonical C boundary, the JNI bridge and the synthetic runner for
the host JVM, then runs the Kotlin facade against it. No vendor SDK, weights,
device or network is used. The production Android build links no runner.
"""
from __future__ import annotations

import argparse
import os
import pathlib
import shutil
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[3]
NATIVE = ROOT / "native/max-runtime"


def tool(name: str, explicit: str | None) -> str:
    path = explicit or shutil.which(name)
    if not path:
        raise ValueError(f"Required host tool is missing: {name}")
    return path


def run(command: list[str], env: dict[str, str]) -> None:
    subprocess.run(command, env=env, check=True, timeout=120)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--work", type=pathlib.Path, required=True)
    parser.add_argument("--cc")
    parser.add_argument("--cxx")
    parser.add_argument("--kotlinc")
    parser.add_argument("--java")
    args = parser.parse_args()
    work = args.work.resolve()
    if work.exists():
        raise ValueError("A new scratch directory is required")
    work.mkdir(mode=0o700, parents=True)
    java_home = os.environ.get("JAVA_HOME")
    if not java_home:
        raise ValueError("JAVA_HOME is required for JNI headers")
    env = {
        "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
        "HOME": str(work),
        "TMPDIR": str(work),
        "LANG": "C.UTF-8",
        "JAVA_HOME": java_home,
        "MODULAR_TELEMETRY_ENABLED": "0",
        "MODULAR_CRASH_REPORTING_ENABLED": "0",
    }
    cc = tool("gcc", args.cc)
    cxx = tool("g++", args.cxx)
    kotlinc = tool("kotlinc", args.kotlinc)
    java = tool("java", args.java)
    jni_includes = [f"-I{java_home}/include"]
    for platform_include in ("linux", "darwin", "win32"):
        candidate = pathlib.Path(java_home) / "include" / platform_include
        if candidate.is_dir():
            jni_includes.append(f"-I{candidate}")
    model = work / "model.o"
    fake = work / "fake.o"
    bridge = work / "max_jni.o"
    suffix = ".dylib" if sys.platform == "darwin" else ".so"
    library = work / f"libquenderin_max_jni{suffix}"
    jar = work / "max-binding.jar"
    run([cc, "-std=c11", "-O1", "-g", "-fPIC", "-Wall", "-Wextra", "-Werror",
         f"-I{NATIVE / 'include'}", "-c", str(NATIVE / "src/quenderin_max_model.c"), "-o", str(model)], env)
    run([cc, "-std=c11", "-O1", "-g", "-fPIC", "-pthread", "-Wall", "-Wextra", "-Werror",
         f"-I{NATIVE / 'include'}", f"-I{NATIVE / 'tests'}",
         "-c", str(NATIVE / "tests/fake_model_runner.c"), "-o", str(fake)], env)
    run([cxx, "-std=c++17", "-O1", "-g", "-fPIC", "-pthread", "-Wall", "-Wextra", "-Werror",
         "-DQUENDERIN_MAX_TEST_RUNNER=1", *jni_includes,
         f"-I{NATIVE / 'include'}", f"-I{NATIVE / 'tests'}", f"-I{ROOT / 'android/jni'}",
         "-c", str(ROOT / "android/jni/max_jni.cpp"), "-o", str(bridge)], env)
    run([cxx, "-shared", "-pthread", str(model), str(fake), str(bridge), "-o", str(library)], env)
    core = ROOT / "android/quenderin-core/src/main/kotlin/ai/quenderin/core"
    verify = ROOT / "android/quenderin-core/src/verify/MaxModelVerify.kt"
    run([kotlinc, *sorted(str(path) for path in core.glob("*.kt")), str(verify),
         "-include-runtime", "-d", str(jar)], env)
    run([java, f"-Djava.library.path={work}", "-cp", str(jar), "MaxModelVerifyKt", str(work / "artifacts")], env)
    print("MAX JNI/JVM binding fixture passed; no vendor runtime used")


if __name__ == "__main__":
    main()

"""Configure the actual JNI project; inspect link commands without compiling."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


class AndroidJniAlignmentTests(unittest.TestCase):
    def test_shared_libraries_and_cpu_modules_receive_16k_link_options(self):
        compiler = shutil.which("clang") or shutil.which("cc")
        cxx = shutil.which("clang++") or shutil.which("c++")
        if not (shutil.which("cmake") and shutil.which("make") and compiler and cxx):
            self.skipTest("CMake, Make and host compiler paths required")
        with tempfile.TemporaryDirectory(prefix="android-jni-alignment-", dir=os.environ.get("RUNNER_TEMP") or os.environ.get("TMPDIR")) as temporary:
            root = Path(temporary)
            jni = root / "android/jni"
            jni.mkdir(parents=True)
            shutil.copyfile(ROOT / "android/jni/CMakeLists.txt", jni / "CMakeLists.txt")
            for name in ("llama_jni.cpp", "max_jni.cpp"):
                (jni / name).write_text("// Configure fixture; never compiled.\n")
            max_source = root / "native/max-runtime/src"
            max_source.mkdir(parents=True)
            (max_source / "quenderin_max_model.c").write_text("/* Never compiled. */\n")
            upstream = root / "prism"
            (upstream / "include").mkdir(parents=True)
            (upstream / "include/llama.h").write_text("// Configure fixture.\n")
            (upstream / "stub.cpp").write_text("// Never compiled.\n")
            (upstream / "CMakeLists.txt").write_text(
                "add_library(llama SHARED stub.cpp)\n"
                "add_library(ggml SHARED stub.cpp)\n"
                "add_subdirectory(cpu)\n"
            )
            (upstream / "cpu").mkdir()
            # Pinned Prism's ggml_add_backend_library uses MODULE with BACKEND_DL.
            (upstream / "cpu/CMakeLists.txt").write_text(
                "add_library(ggml-cpu-android_armv8.0_1 MODULE ../stub.cpp)\n"
            )
            build = root / "build"
            result = subprocess.run([
                "cmake", "-S", str(jni), "-B", str(build), "-G", "Unix Makefiles",
                "-DLLAMA_DIR=" + str(upstream), "-DCMAKE_SYSTEM_NAME=Linux",
                "-DCMAKE_C_COMPILER=" + compiler, "-DCMAKE_CXX_COMPILER=" + cxx,
                # Only generate link commands; do not even compile ABI probes.
                "-DCMAKE_C_COMPILER_FORCED=TRUE", "-DCMAKE_CXX_COMPILER_FORCED=TRUE",
                "-DCMAKE_C_COMPILER_ID=Clang", "-DCMAKE_CXX_COMPILER_ID=Clang",
                "-DCMAKE_C_COMPILER_ID_RUN=TRUE", "-DCMAKE_CXX_COMPILER_ID_RUN=TRUE",
                "-DCMAKE_SHARED_LINKER_FLAGS=-Wl,--build-id=sha1",
                "-DCMAKE_MODULE_LINKER_FLAGS=-Wl,--build-id=md5",
            ], capture_output=True, text=True, timeout=40)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            for directory, target, existing in (
                ("", "quenderin_llama", "sha1"),
                ("", "quenderin_max_jni", "sha1"),
                ("llama.cpp", "llama", "sha1"),
                ("llama.cpp", "ggml", "sha1"),
                ("llama.cpp/cpu", "ggml-cpu-android_armv8.0_1", "md5"),
            ):
                with self.subTest(target=target):
                    command = (build / directory / "CMakeFiles" / (target + ".dir") / "link.txt").read_text()
                    self.assertIn("max-page-size=16384", command)
                    self.assertIn("common-page-size=16384", command)
                    self.assertIn("--build-id=" + existing, command)


if __name__ == "__main__":
    unittest.main()

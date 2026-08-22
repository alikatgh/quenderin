# Builds libquenderin_llama.so (the JNI bridge) and links it against llama.cpp.
# Driven by the app module's externalNativeBuild. See android/INTEGRATION.md.
cmake_minimum_required(VERSION 3.22.1)
project(quenderin_llama LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)

# Point this at a checkout of llama.cpp pinned to a known commit. Options:
#   - git submodule add https://github.com/ggml-org/llama.cpp android/jni/llama.cpp
#   - or set -DLLAMA_DIR=/abs/path when configuring.
if(NOT DEFINED LLAMA_DIR)
    set(LLAMA_DIR "${CMAKE_CURRENT_SOURCE_DIR}/llama.cpp")
endif()

# Mobile-friendly llama.cpp options (no host tools/tests).
set(LLAMA_BUILD_TESTS    OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_SERVER   OFF CACHE BOOL "" FORCE)
set(GGML_OPENMP          OFF CACHE BOOL "" FORCE)

# Per-CPU-feature backends (OSS audit: the #1 prefill lever). A single generic arm64-v8a build never
# uses the DOTPROD/I8MM matmul kernels — why prefill ran no faster than decode (measured: both
# 3.5 tok/s on a cool S23). GGML_CPU_ALL_VARIANTS builds ggml's Android variant set
# (android_armv8.0 … armv9.2 — DOTPROD, MATMUL_INT8, …) as dlopen-able backends; the JNI calls
# ggml_backend_load_all_from_path(nativeLibraryDir) at init and ggml scores the live CPU.
# 0.2.1: ON. ggml_threadpool_new/free are GGML_BACKEND_API and live in those plugins — the JNI
# must resolve them via ggml_backend_reg_get_proc_address (never link ggml-cpu). Packaging:
# useLegacyPackaging=true so the variant .so files are extracted where the scan can see them.
set(BUILD_SHARED_LIBS     ON CACHE BOOL "" FORCE)
set(GGML_BACKEND_DL       ON CACHE BOOL "" FORCE)
set(GGML_CPU_ALL_VARIANTS ON CACHE BOOL "" FORCE)

# GPU offload (Vulkan) — opt-in. The vendored llama.cpp Vulkan backend requires SPIRV-Headers at
# configure time (`find_package(SPIRV-Headers CONFIG REQUIRED)`), which the NDK does not ship.
# CPU-variant backends (above) are the 0.2.1 default win; Vulkan stays -DQUENDERIN_VULKAN=ON /
# Gradle -Pquenderin.vulkan=true. GpuOffloadPlanner still gates per-SoC (Adreno only) when compiled in.
option(QUENDERIN_VULKAN "Build llama.cpp with the Vulkan GPU backend" OFF)
if(QUENDERIN_VULKAN)
    set(GGML_VULKAN ON CACHE BOOL "" FORCE)
    message(STATUS "quenderin: Vulkan GPU backend ENABLED (GpuOffloadPlanner gates offload per SoC)")
else()
    message(STATUS "quenderin: Vulkan GPU backend DISABLED (CPU-only build)")
endif()

# Force an optimized (RelWithDebInfo) build even when the app's Gradle variant is Debug: native
# inference is the perf-critical path, and an unoptimized (-O0) ggml is 5-20x slower AND compiles with
# live assert()s (NDEBUG unset), which can abort() on-device where an optimized build compiles them
# out (audit L3). RelWithDebInfo keeps debug symbols (-g), so the .so stays debuggable, just fast.
if(NOT CMAKE_BUILD_TYPE OR CMAKE_BUILD_TYPE STREQUAL "Debug")
    set(CMAKE_BUILD_TYPE "RelWithDebInfo" CACHE STRING "" FORCE)
endif()
# …and at -O3, not CMake's RelWithDebInfo default of -O2 (OSS llama.cpp apps ship -O3): measurable
# extra vectorization in the ggml kernels, still with -g symbols for debuggability.
set(CMAKE_C_FLAGS_RELWITHDEBINFO   "-O3 -g -DNDEBUG" CACHE STRING "" FORCE)
set(CMAKE_CXX_FLAGS_RELWITHDEBINFO "-O3 -g -DNDEBUG" CACHE STRING "" FORCE)

# 16 KB page-size compatibility (Android 15+): some devices run with 16 KB memory pages, and a native
# .so whose LOAD segments aren't 16 KB-aligned is rejected by the loader / flagged by Play (the on-device
# "ELF alignment check failed" warning). Set the linker flag BEFORE llama.cpp's targets are defined so it
# applies to EVERY shared lib we ship — our JNI bridge AND the vendored libggml*/libllama.
set(CMAKE_SHARED_LINKER_FLAGS "${CMAKE_SHARED_LINKER_FLAGS} -Wl,-z,max-page-size=16384,-z,common-page-size=16384")

add_subdirectory(${LLAMA_DIR} ${CMAKE_BINARY_DIR}/llama.cpp)

add_library(quenderin_llama SHARED llama_jni.cpp)
# ggml/include for ggml-backend.h (runtime CPU-variant pick) + ggml-cpu.h (pinned threadpool).
target_include_directories(quenderin_llama PRIVATE ${LLAMA_DIR}/include ${LLAMA_DIR}/ggml/include)
# llama.cpp replaced use_mmap/use_mlock with load_mode — detect so llama_jni.cpp can compile against
# either the vendored pin (old bools) or a HEAD checkout (CI syntax-check / future pin bumps).
if(EXISTS "${LLAMA_DIR}/include/llama.h")
    file(READ "${LLAMA_DIR}/include/llama.h" _QUENDERIN_LLAMA_H)
    # Match the enum / MMAP constant — not llama_load_model_from_file (substring false positive).
    if(_QUENDERIN_LLAMA_H MATCHES "enum[ \t]+llama_load_mode" OR _QUENDERIN_LLAMA_H MATCHES "LLAMA_LOAD_MODE_MMAP")
        target_compile_definitions(quenderin_llama PRIVATE QUENDERIN_LLAMA_LOAD_MODE=1)
        message(STATUS "quenderin: llama.cpp load_mode API detected")
    else()
        message(STATUS "quenderin: llama.cpp legacy use_mmap/use_mlock API")
    endif()
endif()
# Do NOT link ggml-cpu: with BACKEND_DL the CPU kernels are separate libggml-cpu-android_armv*.so
# plugins, and ggml_threadpool_* is resolved at runtime from the CPU backend registry.
target_link_libraries(quenderin_llama llama ggml android log)

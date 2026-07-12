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
# 3.5 tok/s on a cool S23). When ENABLED (planned for 0.2.1), GGML_CPU_ALL_VARIANTS builds ggml's
# Android variant set (android_armv8.0 … armv9.2 — DOTPROD, MATMUL_INT8, …) as dlopen-able backends,
# the best one picked at RUNTIME; the JNI calls ggml_backend_load_all_from_path(nativeLibraryDir) at
# init to load them. For v0.2.0 BOTH flags are OFF (SHIP NOTE below) → one baseline armv8.0 backend.
set(BUILD_SHARED_LIBS     ON CACHE BOOL "" FORCE)
# v0.2.0 SHIP NOTE (2026-07-11): variant backends temporarily OFF. With BACKEND_DL the
# ggml_threadpool_new/free the JNI bridge links (big-core affinity) live only inside the
# dlopened CPU plugins (ggml-cpu.h marks them GGML_BACKEND_API) → ld.lld undefined-symbol.
# Single baseline armv8.0 CPU backend for the first release — safe on every minSdk-28 device;
# restore variants (+Vulkan) in 0.2.1 by resolving the threadpool via the backend registry.
set(GGML_BACKEND_DL       OFF CACHE BOOL "" FORCE)
set(GGML_CPU_ALL_VARIANTS OFF CACHE BOOL "" FORCE)

# GPU offload (Vulkan) — OFF by default for v0.2.0 (CPU-only baseline; matches the release notes and
# the emulator-verified build). The GPU path returns in 0.2.1. When built IN, the Kotlin
# GpuOffloadPlanner still decides PER-SoC whether to offload (Adreno → all layers; others → CPU until
# forceGpu), so a Vulkan build stays safe on every device. Opt IN with -DQUENDERIN_VULKAN=ON (or
# Gradle -Pquenderin.vulkan=true). NDK ships libvulkan.so (API 24+), so find_package(Vulkan) resolves.
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
# ggml-cpu carries ggml_threadpool_new (big-core affinity). llama/ggml already pull most of it;
# link explicitly so the affinity symbols always resolve.
target_link_libraries(quenderin_llama llama ggml android log)
if(TARGET ggml-cpu)
    target_link_libraries(quenderin_llama ggml-cpu)
endif()

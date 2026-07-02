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

# GPU offload (Vulkan) — opt-in: configure with -DQUENDERIN_VULKAN=ON. Default OFF keeps a stable
# CPU build. When ON, the .so carries the Vulkan backend; the Kotlin GpuOffloadPlanner still decides
# PER-SoC whether to actually offload (Adreno → yes; Mali/Xclipse → only with the forceGpu benchmark
# override), so a Vulkan build is safe on every device. The Android NDK ships libvulkan.so (API 24+),
# so llama.cpp's own find_package(Vulkan) resolves without extra linkage here.
option(QUENDERIN_VULKAN "Build llama.cpp with the Vulkan GPU backend" OFF)
if(QUENDERIN_VULKAN)
    set(GGML_VULKAN ON CACHE BOOL "" FORCE)
    message(STATUS "quenderin: Vulkan GPU backend ENABLED (GpuOffloadPlanner gates offload per SoC)")
endif()

# Force an optimized (RelWithDebInfo) build even when the app's Gradle variant is Debug: native
# inference is the perf-critical path, and an unoptimized (-O0) ggml is 5-20x slower AND compiles with
# live assert()s (NDEBUG unset), which can abort() on-device where an optimized build compiles them
# out (audit L3). RelWithDebInfo keeps debug symbols (-g), so the .so stays debuggable, just fast.
if(NOT CMAKE_BUILD_TYPE OR CMAKE_BUILD_TYPE STREQUAL "Debug")
    set(CMAKE_BUILD_TYPE "RelWithDebInfo" CACHE STRING "" FORCE)
endif()

# 16 KB page-size compatibility (Android 15+): some devices run with 16 KB memory pages, and a native
# .so whose LOAD segments aren't 16 KB-aligned is rejected by the loader / flagged by Play (the on-device
# "ELF alignment check failed" warning). Set the linker flag BEFORE llama.cpp's targets are defined so it
# applies to EVERY shared lib we ship — our JNI bridge AND the vendored libggml*/libllama.
set(CMAKE_SHARED_LINKER_FLAGS "${CMAKE_SHARED_LINKER_FLAGS} -Wl,-z,max-page-size=16384,-z,common-page-size=16384")

add_subdirectory(${LLAMA_DIR} ${CMAKE_BINARY_DIR}/llama.cpp)

add_library(quenderin_llama SHARED llama_jni.cpp)
target_include_directories(quenderin_llama PRIVATE ${LLAMA_DIR}/include)
target_link_libraries(quenderin_llama llama android log)

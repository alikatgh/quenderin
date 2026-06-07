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

# Mobile-friendly llama.cpp options (no host tools/tests; CPU build).
set(LLAMA_BUILD_TESTS    OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_SERVER   OFF CACHE BOOL "" FORCE)
set(GGML_OPENMP          OFF CACHE BOOL "" FORCE)

add_subdirectory(${LLAMA_DIR} ${CMAKE_BINARY_DIR}/llama.cpp)

add_library(quenderin_llama SHARED llama_jni.cpp)
target_include_directories(quenderin_llama PRIVATE ${LLAMA_DIR}/include)
target_link_libraries(quenderin_llama llama android log)

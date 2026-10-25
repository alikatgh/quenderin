# Compile probe only: proves the portable model-adapter boundary builds for
# Android arm64 with the pinned NDK. It ships nothing and links no vendor
# runtime; a future runner supplies load/generate behavior.
cmake_minimum_required(VERSION 3.22.1)
project(quenderin_max_model_boundary LANGUAGES C)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_C_EXTENSIONS OFF)

add_library(quenderin_max_model STATIC ../src/quenderin_max_model.c)
target_include_directories(quenderin_max_model PUBLIC ../include)
target_compile_options(quenderin_max_model PRIVATE -Wall -Wextra -Werror)

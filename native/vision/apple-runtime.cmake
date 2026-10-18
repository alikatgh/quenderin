# Loaded by the pinned upstream Apple builder before project(). CMake forbids
# add_subdirectory during deferred execution, so construct only the bridge target
# after the upstream root has defined its existing llama/ggml/mtmd targets.
include_guard(GLOBAL)
if(NOT QUENDERIN_VISION_SOURCE_DIR OR NOT PRISM_SOURCE_DIR)
  message(FATAL_ERROR "Apple vision integration requires explicit verified source paths")
endif()
set(QUENDERIN_VISION_BUILD_CLI OFF CACHE BOOL "" FORCE)

function(quenderin_add_apple_vision_target)
  foreach(dependency llama ggml mtmd vendor::hash)
    if(NOT TARGET "${dependency}")
      message(FATAL_ERROR "Apple vision requires the existing verified ${dependency} target")
    endif()
  endforeach()
  if(TARGET quenderin_vision)
    message(FATAL_ERROR "Apple vision bridge target already exists")
  endif()
  find_package(Python3 REQUIRED COMPONENTS Interpreter)
  execute_process(COMMAND "${Python3_EXECUTABLE}" "${CMAKE_CURRENT_FUNCTION_LIST_DIR}/../../scripts/prepare_prism_runtime.py"
    verify --source "${PRISM_SOURCE_DIR}" RESULT_VARIABLE VERIFIED OUTPUT_VARIABLE PROVENANCE ERROR_VARIABLE VERIFY_ERROR)
  if(NOT VERIFIED EQUAL 0)
    message(FATAL_ERROR "Vision Prism source provenance rejected: ${VERIFY_ERROR}")
  endif()
  string(JSON VISION_ABI GET "${PROVENANCE}" visionABI)
  string(JSON VISION_REVISION GET "${PROVENANCE}" revision)
  string(JSON VISION_PATCH_SHA256 GET "${PROVENANCE}" visionPatchSha256)
  if(NOT VISION_ABI EQUAL 1)
    message(FATAL_ERROR "Vision source ABI 1 is required")
  endif()
  add_library(quenderin_vision STATIC
    "${QUENDERIN_VISION_SOURCE_DIR}/quenderin_vision.cpp"
    "${QUENDERIN_VISION_SOURCE_DIR}/vision_safety.cpp"
    "${QUENDERIN_VISION_SOURCE_DIR}/quenderin_vision.h")
  target_include_directories(quenderin_vision PUBLIC "${QUENDERIN_VISION_SOURCE_DIR}" PRIVATE "${PRISM_SOURCE_DIR}/vendor")
  target_compile_definitions(quenderin_vision PRIVATE QUENDERIN_VISION_BUILD_DLL
    QUENDERIN_VISION_REVISION="${VISION_REVISION}" QUENDERIN_VISION_PATCH_SHA256="${VISION_PATCH_SHA256}")
  target_link_libraries(quenderin_vision PUBLIC llama mtmd PRIVATE vendor::hash)
  # Xcode's default archive path includes the effective platform (-iphoneos,
  # -iphonesimulator, etc.). An explicit plain directory would silently drop it.
  # Keep the unchanged pinned framework merger's exact configuration layout.
  set(VISION_ARCHIVE_DIRECTORY "${CMAKE_BINARY_DIR}/quenderin-vision")
  if(CMAKE_GENERATOR STREQUAL "Xcode")
    set(VISION_ARCHIVE_DIRECTORY "${VISION_ARCHIVE_DIRECTORY}/$<CONFIG>$(EFFECTIVE_PLATFORM_NAME)")
  endif()
  set_target_properties(quenderin_vision PROPERTIES
    ARCHIVE_OUTPUT_DIRECTORY "${VISION_ARCHIVE_DIRECTORY}"
    CXX_STANDARD 17 CXX_STANDARD_REQUIRED YES POSITION_INDEPENDENT_CODE ON
    CXX_VISIBILITY_PRESET hidden VISIBILITY_INLINES_HIDDEN YES)
endfunction()

cmake_language(DEFER CALL quenderin_add_apple_vision_target)

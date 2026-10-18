# Loaded by the pinned upstream Apple builder before project(); defer until its
# existing llama/ggml/mtmd targets exist. Never configure a second engine.
if(NOT QUENDERIN_VISION_SOURCE_DIR OR NOT PRISM_SOURCE_DIR)
  message(FATAL_ERROR "Apple vision integration requires explicit verified source paths")
endif()
set(QUENDERIN_VISION_BUILD_CLI OFF CACHE BOOL "" FORCE)
cmake_language(DEFER CALL add_subdirectory "${QUENDERIN_VISION_SOURCE_DIR}" "${CMAKE_BINARY_DIR}/quenderin-vision")

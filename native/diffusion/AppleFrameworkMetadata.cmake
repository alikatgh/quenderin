# CMake's default framework plist omits the deployment target and platform.
# Use the same target that the compiler records in every Mach-O slice.
if(NOT CMAKE_OSX_DEPLOYMENT_TARGET MATCHES "^[0-9]+\\.[0-9]+(\\.[0-9]+)?$")
  message(FATAL_ERROR "Diffusion framework needs a numeric Apple deployment target")
endif()
if(CMAKE_SYSTEM_NAME STREQUAL "iOS" AND NOT CMAKE_OSX_SYSROOT MATCHES "[Ss]imulator")
  set(QUENDERIN_DIFFUSION_MINIMUM_OS_KEY MinimumOSVersion)
  set(QUENDERIN_DIFFUSION_SUPPORTED_PLATFORM iPhoneOS)
elseif(CMAKE_SYSTEM_NAME STREQUAL "Darwin")
  set(QUENDERIN_DIFFUSION_MINIMUM_OS_KEY LSMinimumSystemVersion)
  set(QUENDERIN_DIFFUSION_SUPPORTED_PLATFORM MacOSX)
else()
  message(FATAL_ERROR "Diffusion framework supports only iOS device and macOS targets")
endif()

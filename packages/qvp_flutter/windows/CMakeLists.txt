cmake_minimum_required(VERSION 3.14)
project(qvp_flutter LANGUAGES CXX)

set(PLUGIN_NAME "qvp_flutter_plugin")

set(QVP_DLL_PATH "${CMAKE_CURRENT_SOURCE_DIR}/qvp_ffi.dll")

# If not present in plugin directory, check the Cargo build: target/dist (the shipped
# profile) or target/release (a host build for tests), whichever is newer
if(NOT EXISTS "${QVP_DLL_PATH}")
  set(CARGO_DIST_DLL "${CMAKE_CURRENT_SOURCE_DIR}/../../../../target/dist/qvp_ffi.dll")
  set(CARGO_RELEASE_DLL "${CMAKE_CURRENT_SOURCE_DIR}/../../../../target/release/qvp_ffi.dll")
  if(EXISTS "${CARGO_DIST_DLL}" AND EXISTS "${CARGO_RELEASE_DLL}")
    if("${CARGO_RELEASE_DLL}" IS_NEWER_THAN "${CARGO_DIST_DLL}")
      set(QVP_DLL_PATH "${CARGO_RELEASE_DLL}")
    else()
      set(QVP_DLL_PATH "${CARGO_DIST_DLL}")
    endif()
  elseif(EXISTS "${CARGO_DIST_DLL}")
    set(QVP_DLL_PATH "${CARGO_DIST_DLL}")
  elseif(EXISTS "${CARGO_RELEASE_DLL}")
    set(QVP_DLL_PATH "${CARGO_RELEASE_DLL}")
  endif()
endif()

if(NOT EXISTS "${QVP_DLL_PATH}")
  message(FATAL_ERROR "qvp_ffi.dll not found in ${CMAKE_CURRENT_SOURCE_DIR}, target/dist or target/release. Build the Cargo crate first.")
endif()
message(STATUS "qvp_flutter: bundling ${QVP_DLL_PATH}")

# Expose prebuilt qvp_ffi.dll to be bundled with the final application binary
set(qvp_flutter_bundled_libraries
  "${QVP_DLL_PATH}"
  PARENT_SCOPE
)

# Dummy target for IDE integration and clean project definition
add_custom_target(${PLUGIN_NAME})

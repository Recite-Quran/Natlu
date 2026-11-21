# The tajweed library (include/zf_tajweed.h), inference only: the model folder (tokens, the calibration's
# bytes as data), streams over the exact engine, the decoded layer (top-K, top-2) and the reference data
# reader, in portable C11 with no dependencies. It builds inside the SDK (added from the top
# CMakeLists.txt, with the streams) or on its own (cmake -S tajweed: no streams, for heads that came
# from elsewhere). There is no scorer here.
cmake_minimum_required(VERSION 3.24)
if(CMAKE_SOURCE_DIR STREQUAL CMAKE_CURRENT_SOURCE_DIR)
  project(zf_tajweed C)
  set(CMAKE_C_STANDARD 11)
  if(NOT MSVC)
    add_compile_options($<$<COMPILE_LANGUAGE:C>:-ffp-contract=off>)
  endif()
  # on its own, the library's tests are this project's tests
  set(ZF_TESTS ON)
  enable_testing()
endif()

set(ZF_TAJWEED_SOURCES src/model.c src/decoded.c src/reference.c)

if(MSVC)
  set(ZF_TAJWEED_WARN /W4)
else()
  set(ZF_TAJWEED_WARN -O2 -Wall -Wextra -Werror)
  if(WIN32)
    # MinGW ignores the header's visibility attribute with a warning
    list(APPEND ZF_TAJWEED_WARN -Wno-attributes)
  endif()
endif()

# What the SDKs link: zf_tajweed_inference. With the engine built (the target zf_stream exists) it has
# the real streams (src/engine.c over zf_stream); without, src/engine_stub.c stands in and
# zf_tajweed_stream_create fails with a message.
if(TARGET zf_stream)
  add_library(zf_tajweed_inference STATIC ${ZF_TAJWEED_SOURCES} src/engine.c)
  target_link_libraries(zf_tajweed_inference PUBLIC zf_stream)

  # Shared library for Dart FFI
  add_library(zf_tajweed SHARED ${ZF_TAJWEED_SOURCES} src/engine.c)
  target_link_libraries(zf_tajweed PUBLIC zf_stream)
  target_include_directories(zf_tajweed PUBLIC include PRIVATE src)
  target_compile_options(zf_tajweed PRIVATE $<$<COMPILE_LANGUAGE:C>:${ZF_TAJWEED_WARN}>)
  if(WIN32)
    target_compile_definitions(zf_tajweed PRIVATE _CRT_SECURE_NO_WARNINGS ZF_TAJWEED_BUILD_DLL)
  endif()
  if(APPLE)
    set_target_properties(zf_tajweed PROPERTIES
      FRAMEWORK TRUE
      MACOSX_FRAMEWORK_IDENTIFIER com.recitequran.zf-tajweed
      XCODE_ATTRIBUTE_PRODUCT_BUNDLE_IDENTIFIER com.recitequran.zf-tajweed
      PUBLIC_HEADER include/zf_tajweed.h
      XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED "NO"
      XCODE_ATTRIBUTE_CODE_SIGNING_REQUIRED "NO"
      XCODE_ATTRIBUTE_CODE_SIGN_IDENTITY ""
    )
  endif()
else()
  add_library(zf_tajweed_inference STATIC ${ZF_TAJWEED_SOURCES} src/engine_stub.c)
endif()
target_include_directories(zf_tajweed_inference PUBLIC include PRIVATE src)
target_compile_options(zf_tajweed_inference PRIVATE $<$<COMPILE_LANGUAGE:C>:${ZF_TAJWEED_WARN}>)
if(WIN32)
  # fopen on bounded buffers: the Windows CRT's deprecation notes are not errors here
  target_compile_definitions(zf_tajweed_inference PRIVATE _CRT_SECURE_NO_WARNINGS)
endif()

# The tests (ctest). They need no weights and no network: the model folder they open is
# tests/data/model (the real tokens.txt, a synthetic calibration.json and a synthetic reference table
# of random tokens), and the folders with one thing wrong are built under the build directory.
#   zf_tajweed_decoded    top-K, top-2 and the head table on rows with known answers
#   zf_tajweed_model      the tokens file, the open options, a folder without calibration.json and
#                         without expected_tj3.zfx, the calibration's bytes, a context's chunk length
#   zf_tajweed_reference  the reference data reader against the 2.x calls' output, and damaged files
#   zf_tajweed_api        zf_tajweed.h declares no scorer name, and the functions it does declare
# Built when this is the project being built (ZF_TESTS, set by the top CMakeLists.txt), or on its own.
if(ZF_TESTS)
  if(NOT TARGET zf_tests)
    add_custom_target(zf_tests)
  endif()
  foreach(t decoded model reference api)
    add_executable(zf_tajweed_test_${t} tests/test_${t}.c)
    target_compile_options(zf_tajweed_test_${t} PRIVATE ${ZF_TAJWEED_WARN})
    target_link_libraries(zf_tajweed_test_${t} PRIVATE zf_tajweed_inference)
    if(WIN32)
      target_compile_definitions(zf_tajweed_test_${t} PRIVATE _CRT_SECURE_NO_WARNINGS)
    endif()
    if(TARGET zf_stream)
      target_compile_definitions(zf_tajweed_test_${t} PRIVATE TJ_TEST_ENGINE=1)
    endif()
    add_dependencies(zf_tests zf_tajweed_test_${t})
  endforeach()
  add_test(NAME zf_tajweed_decoded COMMAND zf_tajweed_test_decoded)
  add_test(NAME zf_tajweed_model COMMAND zf_tajweed_test_model ${CMAKE_CURRENT_SOURCE_DIR}/tests/data/model
           ${CMAKE_CURRENT_BINARY_DIR}/test_model_scratch)
  add_test(NAME zf_tajweed_reference COMMAND zf_tajweed_test_reference ${CMAKE_CURRENT_SOURCE_DIR}/tests/data/model
           ${CMAKE_CURRENT_BINARY_DIR}/test_reference_scratch)
  add_test(NAME zf_tajweed_api COMMAND zf_tajweed_test_api ${CMAKE_CURRENT_SOURCE_DIR}/include/zf_tajweed.h)
endif()

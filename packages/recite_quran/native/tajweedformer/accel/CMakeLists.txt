# The ONNX Runtime C API headers: this checkout's third_party, or the including project's when the
# engine is built as a subproject (the wrappers keep a copy in their own third_party).
set(ONNXRUNTIME_HEADERS "${tajweedformer_sdk_SOURCE_DIR}/third_party/onnxruntime/include")
if(NOT EXISTS "${ONNXRUNTIME_HEADERS}/onnxruntime_c_api.h")
  set(ONNXRUNTIME_HEADERS "${CMAKE_SOURCE_DIR}/third_party/onnxruntime/include")
endif()
if(NOT EXISTS "${ONNXRUNTIME_HEADERS}/onnxruntime_c_api.h")
  message(FATAL_ERROR "missing ONNX Runtime C API header in ${ONNXRUNTIME_HEADERS}")
endif()
# Windows: the header read with char paths, as zf_rt implements it (see win32/onnxruntime_c_api.h)
if(WIN32)
  set(ZF_ORT_C_API_HEADER "${ONNXRUNTIME_HEADERS}/onnxruntime_c_api.h")
  set(ONNXRUNTIME_HEADERS "${CMAKE_CURRENT_SOURCE_DIR}/win32" "${ONNXRUNTIME_HEADERS}")
endif()

if(MSVC)
  set(ZF_ACCEL_WARN /O2 /W3)
else()
  set(ZF_ACCEL_WARN -O2 -Wall -Wextra -Werror)
endif()

add_library(zf_ort_ops STATIC src/ort_ops.c)
target_include_directories(zf_ort_ops PUBLIC include "${ONNXRUNTIME_HEADERS}")
target_compile_options(zf_ort_ops PRIVATE ${ZF_ACCEL_WARN})
target_link_libraries(zf_ort_ops PUBLIC zf_engine)

# The engine graph without ONNX Runtime: the slice of its C API that the operators above and the
# bench harnesses call, and a runner for the exported graph (tools/zfg_export.py).
add_library(zf_rt STATIC src/zf_rt.c)
target_include_directories(zf_rt PUBLIC include "${ONNXRUNTIME_HEADERS}")
target_compile_options(zf_rt PRIVATE ${ZF_ACCEL_WARN})
if(CMAKE_C_COMPILER_ID STREQUAL "GNU")
  # GCC's -Wformat-truncation: zf_rt's error messages are cut at 256 bytes on purpose
  target_compile_options(zf_rt PRIVATE -Wno-format-truncation)
endif()
if(WIN32 AND NOT MINGW AND CMAKE_C_COMPILER_ID MATCHES "Clang")
  # COFF has no undefined weak references: zf_rt's weak zf_ops_defer_begin is a plain reference
  # there (ort_ops.c defines it; every target that links zf_rt links it too), and clang says the
  # test of its address is always true
  target_compile_options(zf_rt PRIVATE -Wno-pointer-bool-conversion)
endif()
target_link_libraries(zf_rt PUBLIC zf_engine)

if(WIN32)
  foreach(t zf_ort_ops zf_rt)
    target_compile_definitions(${t} PUBLIC "ZF_ORT_C_API_HEADER=\"${ZF_ORT_C_API_HEADER}\"")
  endforeach()
endif()

# The library entry point: a stream of feature frames in, phonemes out (zf/stream.h).
add_library(zf_stream STATIC src/stream.c)
target_include_directories(zf_stream PUBLIC include "${ONNXRUNTIME_HEADERS}")
target_compile_options(zf_stream PRIVATE ${ZF_ACCEL_WARN})
target_link_libraries(zf_stream PUBLIC zf_ort_ops zf_rt)
# zf_stream's sessions are zf_rt's, so ZfStreamOptions.batch runs its chunks through zf_rt_run_batch
target_compile_definitions(zf_stream PRIVATE ZF_RT_BATCH=1)

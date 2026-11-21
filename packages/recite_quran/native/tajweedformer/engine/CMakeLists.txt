set(ZF_ENGINE_SOURCES src/pool.c src/kernels.c src/dot.c src/conv.c src/layout.c src/block.c src/zfw.c src/frontend.c src/layer.c src/decode.c src/zf_libm.c src/fbank.c src/resample.c src/vfs.c src/sha256.c src/zfs.c src/neon_emu_trace.c
    ${tajweedformer_sdk_SOURCE_DIR}/third_party/kissfft/kiss_fft.c ${tajweedformer_sdk_SOURCE_DIR}/third_party/kissfft/kiss_fftr.c)
if(ANDROID_ABI STREQUAL "armeabi-v7a")
  # Hand-scheduled microkernels for the A53's in-order NEON pipeline.
  list(APPEND ZF_ENGINE_SOURCES src/kernels_armv7.S)
endif()

add_library(zf_engine STATIC ${ZF_ENGINE_SOURCES})
target_include_directories(zf_engine PUBLIC include)
target_include_directories(zf_engine PRIVATE ${tajweedformer_sdk_SOURCE_DIR}/third_party/kissfft)
if(MSVC)
  target_compile_options(zf_engine PRIVATE /O2 /W3)
  set(ZF_NO_VECTORIZE "")
else()
  target_compile_options(zf_engine PRIVATE $<$<COMPILE_LANGUAGE:C>:-O3 -Wall -Wextra -Werror>)
  if(CMAKE_C_COMPILER_ID MATCHES "Clang")
    set(ZF_NO_VECTORIZE "-fno-vectorize;-fno-slp-vectorize")
  else()
    set(ZF_NO_VECTORIZE "-fno-tree-vectorize;-fno-tree-slp-vectorize")
  endif()
endif()
# vendored third-party code (optimized-routines): its own style, so no -Werror on it
if(NOT MSVC)
  set_source_files_properties(src/zf_libm.c PROPERTIES COMPILE_OPTIONS "-w")
endif()
# The fbank and its FFT: plain IEEE scalar arithmetic on every ABI. Auto-vectorised on ARMv7 they
# would run on NEON, which flushes denormals where scalar arithmetic does not (see zf/fbank.h).
# (GCC spells the two switches -fno-tree-vectorize and -fno-tree-slp-vectorize.)
if(NOT MSVC)
  set_source_files_properties(src/fbank.c ${tajweedformer_sdk_SOURCE_DIR}/third_party/kissfft/kiss_fft.c
                              ${tajweedformer_sdk_SOURCE_DIR}/third_party/kissfft/kiss_fftr.c
                              PROPERTIES COMPILE_OPTIONS "-w;${ZF_NO_VECTORIZE}")
  set_source_files_properties(src/resample.c PROPERTIES COMPILE_OPTIONS "${ZF_NO_VECTORIZE}")
endif()
# The dot-product matmul is compiled for the instruction set that has SDOT, and asks the core at
# run time whether it can issue it; see dot.h.
# (An Apple build names its target in CMAKE_OSX_ARCHITECTURES when it is not the host's: an x86_64
# build on an ARM Mac must not get the flag.)
if(ANDROID_ABI STREQUAL "arm64-v8a" OR (APPLE AND CMAKE_OSX_ARCHITECTURES MATCHES "arm64") OR
   (APPLE AND NOT CMAKE_OSX_ARCHITECTURES AND CMAKE_SYSTEM_PROCESSOR MATCHES "arm64|aarch64"))
  set_source_files_properties(src/dot.c PROPERTIES COMPILE_OPTIONS "-march=armv8.2-a+dotprod")
endif()

# ZF_PLD_DIST tunes how far the microkernel prefetches its weight panel; see kernels_armv7.S.
if(ZF_PLD_DIST)
  target_compile_definitions(zf_engine PRIVATE ZF_PLD_DIST=${ZF_PLD_DIST})
endif()
if(NOT ANDROID)
  find_package(Threads REQUIRED)
  target_link_libraries(zf_engine PUBLIC Threads::Threads)
endif()
if(ANDROID OR (UNIX AND NOT APPLE))
  target_link_libraries(zf_engine PUBLIC m)
endif()
if(WIN32 AND NOT MINGW)
  # Windows against the Microsoft C runtime (clang targeting x86_64-pc-windows-msvc): the POSIX
  # threads, sched_yield and clock_gettime the engine uses, over Win32 (win32/msvc). MinGW-w64
  # has them already (winpthreads).
  target_include_directories(zf_engine BEFORE PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}/win32/msvc")
  target_compile_definitions(zf_engine PUBLIC _CRT_SECURE_NO_WARNINGS _CRT_NONSTDC_NO_DEPRECATE
                                               strtok_r=strtok_s)
endif()

# The engine's tests (engine/tests, run by ctest): built when this repository is the project being
# built, not when another project adds the engine as a subdirectory.
if(ZF_TESTS)
  add_subdirectory(tests)
endif()

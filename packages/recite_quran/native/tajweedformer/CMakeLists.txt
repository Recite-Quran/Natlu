cmake_minimum_required(VERSION 3.24)
project(tajweedformer_sdk DESCRIPTION "TajweedFormer engine: the exact inference runtime" LANGUAGES C CXX ASM)

set(CMAKE_C_STANDARD 11)
set(CMAKE_CXX_STANDARD 17)

# Build only the engine library (no stream API, no harnesses), for example for another ABI.
option(ZF_ENGINE_ONLY "Build only the engine" OFF)

# What an app links: the exact configuration fixed at compile time, and the environment ignored
# (engine/include/zf/env.h). Development builds leave it off to keep the ZF_* switches.
option(ZF_RELEASE "Exact configuration only; ignore ZF_* environment switches" OFF)
if(ZF_RELEASE)
  add_compile_definitions(ZF_RELEASE=1 ZF_QUANT_DIVIDE=1)
endif()

# The engine's exact arithmetic is ARMv7 NEON's. On a host without NEON (x86) the same source runs
# through zf/neon_emu.h, NEON's arithmetic in portable C; that is the default there.
if(CMAKE_SYSTEM_PROCESSOR MATCHES "^(AMD64|amd64|x86_64|x86|i[3-6]86)$" AND NOT ANDROID)
  set(ZF_NEON_EMU_DEFAULT ON)
else()
  set(ZF_NEON_EMU_DEFAULT OFF)
endif()
option(ZF_NEON_EMU "Emulate ARMv7 NEON in portable C" ${ZF_NEON_EMU_DEFAULT})
if(ZF_NEON_EMU)
  add_compile_definitions(ZF_NEON_EMU=1)
endif()

# No contraction anywhere: every multiply-add rounds twice, as ARMv7's VMLA does.
add_compile_options($<$<COMPILE_LANGUAGE:C>:-ffp-contract=off>)
# The tests (engine/tests, tajweed/tests): `ctest --test-dir <build dir>`. They need no model file and no
# network. On when this is the project being built; a project that adds the engine with
# add_subdirectory(... EXCLUDE_FROM_ALL) does not build them, so it does not get them in its own ctest either.
if(CMAKE_SOURCE_DIR STREQUAL CMAKE_CURRENT_SOURCE_DIR)
  set(ZF_TESTS_DEFAULT ON)
else()
  set(ZF_TESTS_DEFAULT OFF)
endif()
option(ZF_TESTS "Build the engine's tests and register them with ctest" OFF)
if(ZF_TESTS)
  enable_testing()
endif()

add_subdirectory(engine)
if(NOT ZF_ENGINE_ONLY)
  add_subdirectory(accel)
endif()
# The tajweed library, inference only (model folders, the decoded layer, the reference data reader):
# portable C with no dependencies. zf_tajweed_inference is what an app links; with the engine built it
# has the streams.
option(ZF_TAJWEED "Build the tajweed library" ON)
if(ZF_TAJWEED)
  add_subdirectory(tajweed)
endif()

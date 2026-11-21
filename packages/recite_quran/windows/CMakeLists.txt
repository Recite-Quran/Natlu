cmake_minimum_required(VERSION 3.14)
project(quran_tajweedformer LANGUAGES CXX)

set(PLUGIN_NAME "quran_tajweedformer_plugin")

set(ZF_DLL_PATH "${CMAKE_CURRENT_SOURCE_DIR}/zf_tajweed.dll")

if(EXISTS "${ZF_DLL_PATH}")
  message(STATUS "quran_tajweedformer: bundling ${ZF_DLL_PATH}")
  set(quran_tajweedformer_bundled_libraries
    "${ZF_DLL_PATH}"
    PARENT_SCOPE
  )
endif()

add_custom_target(${PLUGIN_NAME})

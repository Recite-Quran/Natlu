/* The ONNX Runtime C API header as the engine reads it on Windows.
 *
 * On _WIN32 the real header declares paths as wchar_t (ORTCHAR_T) and the calls __stdcall. The
 * engine never links the real runtime on Windows: its sessions are zf_rt's, which implement the
 * API slice with char paths, as on every other platform. So the header is read here with _WIN32
 * hidden, which gives char paths and the default calling convention (the only one on x86-64).
 * accel/CMakeLists.txt puts this directory before the real headers on WIN32 and names the real
 * file in ZF_ORT_C_API_HEADER. */
#ifndef ZF_WIN32_ORT_C_API_SHIM_H
#define ZF_WIN32_ORT_C_API_SHIM_H
/* what the real header includes, read first with _WIN32 visible so the CRT headers are the
 * Windows ones */
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#pragma push_macro("_WIN32")
#undef _WIN32
#if defined(_MSC_VER) && !defined(__clang__)
/* the non-Windows branch spells ORT_MUST_USE_RESULT with __attribute__ */
#pragma push_macro("__attribute__")
#define __attribute__(x)
#endif
#include ZF_ORT_C_API_HEADER
#if defined(_MSC_VER) && !defined(__clang__)
#pragma pop_macro("__attribute__")
#endif
#pragma pop_macro("_WIN32")
#endif

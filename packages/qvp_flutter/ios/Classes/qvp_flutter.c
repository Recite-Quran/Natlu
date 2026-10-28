#include <stdint.h>

// Forward declaration of an engine symbol from libqvp_ffi.a
uint32_t qvp_format_version(void);

// A dummy symbol to satisfy CocoaPods source_files and prevent Xcode's linker
// from dead-stripping static C symbols from QvpEngine.xcframework when
// dart:ffi calls DynamicLibrary.process().
__attribute__((visibility("default"))) __attribute__((used))
intptr_t qvp_flutter_dummy_symbol_to_enforce_linking(void) {
    return (intptr_t)qvp_format_version;
}

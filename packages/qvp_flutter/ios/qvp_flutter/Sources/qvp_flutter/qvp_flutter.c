#include <stdint.h>

#include "include/qvp_flutter.h"

// An engine symbol from libqvp_ffi.a in QvpEngine.xcframework.
uint32_t qvp_format_version(void);

// Dart reaches the engine through DynamicLibrary.process(), and no native code calls it.
// This symbol refers to the engine, so the linker keeps the engine's object file in the
// plugin's library. `used` keeps the symbol itself. CocoaPods and Swift Package Manager
// both build this file.
__attribute__((visibility("default"))) __attribute__((used))
intptr_t qvp_flutter_dummy_symbol_to_enforce_linking(void) {
    return (intptr_t)qvp_format_version;
}

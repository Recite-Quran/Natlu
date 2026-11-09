#ifndef QVP_FLUTTER_H
#define QVP_FLUTTER_H

#include <stdint.h>

// The plugin's only native symbol. It keeps the engine linked; see qvp_flutter.c. The
// engine API is crates/qvp-ffi/include/qvp.h, which QvpEngine.xcframework carries.
intptr_t qvp_flutter_dummy_symbol_to_enforce_linking(void);

#endif

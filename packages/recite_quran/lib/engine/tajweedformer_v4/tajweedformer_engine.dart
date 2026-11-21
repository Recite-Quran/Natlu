// lib/engine/tajweedformer_v4/tajweedformer_engine.dart
// Conditional export router for TajweedFormerEngine.

export 'tajweedformer_engine_io.dart'
    if (dart.library.js_interop) 'tajweedformer_engine_web.dart';


/// Flutter wrapper for the QVP vector mushaf engine.
///
/// `QvpEngine` initializes the engine (native via `dart:ffi`, web via WebAssembly).
/// `QvpPage` represents a decoded page with geometry copied once; layout, styles,
/// highlights, masks and hit-testing live in the engine.
/// `QvpAtlas` provides cross-page index and lookups.
/// `QvpPassage` lays out contiguous ayah ranges across pages.
/// `QvpOrnaments` dresses pages with medallions, headers and page frames.
/// `QvpPageView` is the host Flutter renderer.
library;

export 'src/atlas.dart';
export 'src/backend/qvp_backend.dart';
export 'src/engine.dart';
export 'src/ornaments.dart';
export 'src/page.dart';
export 'src/page_view.dart';
export 'src/passage.dart';
export 'src/types.dart';

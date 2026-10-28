import 'dart:typed_data';

import 'atlas.dart';
import 'backend/qvp_backend.dart';
import 'ornaments.dart';
import 'page.dart';
import 'types.dart';

export 'atlas.dart';
export 'backend/qvp_backend.dart';
export 'ornaments.dart';
export 'page.dart';
export 'passage.dart';
export 'types.dart';

/// The QVP engine instance.
///
/// Holds the platform backend (native via `dart:ffi` or web via WebAssembly/JS).
/// Creates and manages pages, atlases, ornaments, and provides text tools.
class QvpEngine {
  /// Opens with an existing backend or default native library.
  QvpEngine([dynamic library]) : backend = createDefaultBackend(library: library) {
    _initNames();
  }

  /// Opens the engine library: [path] if given, else the platform default.
  factory QvpEngine.open({String? path}) =>
      QvpEngine.fromBackend(createDefaultBackend(path: path));

  /// Initializes the QVP engine on Flutter Web.
  ///
  /// Can optionally be provided [wasmBytes], [wasmAssetPath] or fetched from [wasmUrl].
  static Future<QvpEngine> initWeb({
    List<int>? wasmBytes,
    String? wasmAssetPath,
    String? wasmUrl,
  }) async {
    final b = await initWebBackend(
      wasmBytes: wasmBytes,
      wasmAssetPath: wasmAssetPath,
      wasmUrl: wasmUrl,
    );
    return QvpEngine.fromBackend(b);
  }

  /// Wraps a specific [backend] implementation.
  QvpEngine.fromBackend(this.backend) {
    _initNames();
  }

  final QvpBackend backend;
  bool _disposed = false;

  void _initNames() {
    for (final t in [
      QvpNames.mark,
      QvpNames.kind,
      QvpNames.family,
      QvpNames.category,
      QvpNames.decoration,
      QvpNames.division,
      QvpNames.place,
    ]) {
      QvpNames.setTable(t, names(t));
    }
  }

  /// Engine version, e.g. `0.7.0`.
  String get version => backend.version;

  /// Page format version the engine reads.
  int get formatVersion => backend.formatVersion;

  /// Name of the engine (`qvp`).
  String get engineName => backend.engineName;

  // ── Name tables ──
  int nameCount(int table) => backend.nameCount(table);
  String name(int table, int id) => backend.name(table, id);
  int nameId(int table, String s) => backend.nameId(table, s);
  List<String> names(int table) => List.generate(nameCount(table), (i) => name(table, i), growable: false);

  String markName(int m) => backend.markName(m);
  String familyName(int f) => backend.familyName(f);
  String kindName(int k) => backend.kindName(k);
  String categoryName(int c) => backend.categoryName(c);
  int markCategory(Object m) => backend.markCategory(QvpMark.id(m));
  int markFromName(String s) => backend.markFromName(s);
  String decorationName(int k) => name(QvpNames.decoration, k);
  String divisionName(int d) => name(QvpNames.division, d);
  String placeName(int p) => name(QvpNames.place, p);

  // ── Arabic text tools ──
  String strip(String s) => backend.arabic(0, s);
  String fold(String s) => backend.arabic(1, s);
  String normalize(String s) => backend.arabic(2, s);
  String looseKey(String s) => backend.arabic(3, s);

  // ── Loading resources ──

  /// Decodes a page from QVP bytes.
  QvpPage loadPage(Uint8List bytes) {
    final (handle, data) = backend.pageLoad(bytes);
    return QvpPage.fromHandle(this, backend, handle, data);
  }

  /// Decodes an atlas (`atlas.qva`).
  QvpAtlas loadAtlas(Uint8List bytes) {
    final (handle, pages) = backend.atlasLoad(bytes);
    return QvpAtlas.fromHandle(this, backend, handle, pages);
  }

  /// Decodes an ornament set (`ornaments.qvo`).
  QvpOrnaments loadOrnaments(Uint8List bytes) {
    final (handle, list) = backend.ornamentsLoad(bytes);
    return QvpOrnaments.fromHandle(this, backend, handle, list);
  }

  /// Scales [view] by [factor] about a focal point in viewport px.
  QvpView viewZoomAbout(QvpView view, double focalX, double focalY, double factor, {double min = 0, double max = 0}) =>
      backend.viewZoomAbout(view, focalX, focalY, factor, min: min, max: max);

  /// Releases backend resources. Free pages and atlases first.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    backend.dispose();
  }
}

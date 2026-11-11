// QvpEngine — the entry point: holds the backend, opens pages, atlases and ornament sets.
import 'dart:typed_data';

import 'atlas.dart';
import 'backend/qvp_backend.dart';
import 'ornaments.dart';
import 'page.dart';
import 'types.dart';

export 'atlas.dart';
export 'backend/qvp_backend.dart';
export 'ornaments.dart';
export 'page.dart' hide pageClock;
export 'passage.dart';
export 'types.dart';

/// The QVP engine instance.
///
/// Holds the platform backend (native via `dart:ffi` or web via WebAssembly/JS).
/// Creates and manages pages, atlases, ornaments, and provides text tools.
class QvpEngine {
  /// Opens with an existing backend or default native library.
  QvpEngine([dynamic library])
    : backend = createDefaultBackend(library: library) {
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

  /// The platform backend every call goes through: dart:ffi on native, WebAssembly on the web.
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

  /// How many ids [table] has. [table] is one of [QvpNames].
  int nameCount(int table) => backend.nameCount(table);

  /// The name of [id] in [table]; empty outside the table.
  String name(int table, int id) => backend.name(table, id);

  /// The id of the name [s] in [table]; 255 when the table has no such name.
  int nameId(int table, String s) => backend.nameId(table, s);

  /// Every name of [table], at the index of its id.
  List<String> names(int table) =>
      List.generate(nameCount(table), (i) => name(table, i), growable: false);

  /// The name of mark id [m], such as `fathah`. The ids are the `QVP_NAMES_MARK` table.
  String markName(int m) => backend.markName(m);

  /// The name of mark family [f] (see [QvpFamily]).
  String familyName(int f) => backend.familyName(f);

  /// The name of path kind [k] (see [QvpKind]).
  String kindName(int k) => backend.kindName(k);

  /// The name of mark category [c] (see [QvpCategory]).
  String categoryName(int c) => backend.categoryName(c);

  /// The [QvpCategory] a mark belongs to. [m] is a mark id or a mark name.
  int markCategory(Object m) => backend.markCategory(QvpMark.id(m));

  /// The mark id of the name [s]; 255 when no mark has that name.
  int markFromName(String s) => backend.markFromName(s);

  /// The name of decoration kind [k] (see [QvpDecorationKind]).
  String decorationName(int k) => name(QvpNames.decoration, k);

  /// The name of division [d] (see [QvpDiv]), such as `juz`.
  String divisionName(int d) => name(QvpNames.division, d);

  /// The name of place [p]: 0 is `makkah`, 1 is `madinah`.
  String placeName(int p) => name(QvpNames.place, p);

  // ── Arabic text tools ──

  /// [s] with every Arabic mark removed, so only the letters are left.
  String strip(String s) => backend.arabic(0, s);

  /// [s] with letter variants folded: أ إ آ ٱ to ا, ى ئ to ي, ؤ to و, ة to ه, and Arabic-Indic
  /// digits to ASCII. ء stays.
  String fold(String s) => backend.arabic(1, s);

  /// [s] stripped and folded, with runs of white space made one space. Search applies this to
  /// the query and to each word before it compares them.
  String normalize(String s) => backend.arabic(2, s);

  /// The loose key of [s]: [normalize], and bare alif and hamzah dropped too. Search falls back
  /// to it only when the strict pass finds nothing, so a typed `الرحمان` finds the printed
  /// `الرحمن`. It merges words such as كاتب and كتاب, so a match through it has
  /// [QvpMatch.isLooseMatch] set.
  String looseKey(String s) => backend.arabic(3, s);

  // ── Loading resources ──

  /// Decodes a page from QVP bytes.
  QvpPage loadPage(Uint8List bytes) {
    final (handle, data) = backend.pageLoad(bytes);
    return QvpPage.fromHandle(this, backend, handle, data);
  }

  /// Decodes a page off the UI thread on native platforms (and inline on Web).
  Future<QvpPage> loadPageAsync(Uint8List bytes) async {
    final (handle, data) = await backend.pageLoadAsync(bytes);
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

  /// [view] zoomed by [factor] about a point of the viewport, with the scale held between [min]
  /// and [max]: the point under the fingers stays under them. A limit of 0 is the engine's own,
  /// and a ceiling under the floor is the floor. A host hands this the view and the focal point
  /// the pinch began on and the factor of the whole gesture.
  QvpView viewZoomAbout(
    QvpView view,
    double focalX,
    double focalY,
    double factor, {
    double min = 0,
    double max = 0,
  }) => backend.viewZoomAbout(view, focalX, focalY, factor, min: min, max: max);

  /// [view] moved by a drag, in viewport px.
  QvpView viewPan(QvpView view, double dx, double dy) =>
      backend.viewPan(view, dx, dy);

  /// [view] held against the viewport: an axis the content does not fill is centred, and on an
  /// axis it overflows the content keeps the viewport covered. [QvpPage.dressClamp] is the same
  /// over the content plus a dress's border.
  QvpView viewClamp(
    QvpView view,
    double contentW,
    double contentH,
    double viewportW,
    double viewportH,
  ) => backend.viewClamp(view, contentW, contentH, viewportW, viewportH);

  /// The way a released drag went, when it is a page swipe: +1 right, -1 left, 0 when it is
  /// not a swipe. [dx] and [dy] are the drag in viewport px, [vx] and [vy] its release velocity
  /// in px per second.
  int viewSwipe(double dx, double dy, [double vx = 0, double vy = 0]) =>
      backend.viewSwipe(dx, dy, vx, vy);

  /// How many pages a released drag turns, in reading order: a mushaf runs right to left, so a
  /// flick to the right is the next page. Add it to the page you are on.
  int swipePages(double dx, double dy, [double vx = 0, double vy = 0]) =>
      backend.swipePages(dx, dy, vx, vy);

  /// Releases backend resources. Free pages and atlases first.
  ///
  /// The engine is closed after this. On a native build, any later call on the engine or on
  /// a page, atlas, passage or ornament set it made throws `StateError('QvpEngine was
  /// disposed')`, and freeing an object still works. A second `dispose` does nothing.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    backend.dispose();
  }
}

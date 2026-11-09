// QvpAtlas — the cross-page index: surahs, divisions and the lookups over them.
import 'engine.dart';

/// Cross-page lookup (`atlas.qva`).
class QvpAtlas {
  /// Wraps an atlas the backend has loaded. Apps call [QvpEngine.loadAtlas] instead.
  QvpAtlas.fromHandle(this.engine, this._backend, this._handle, this.pages);

  /// The engine that loaded the atlas.
  final QvpEngine engine;
  final QvpBackend _backend;
  AtlasHandle? _handle;

  /// Total number of pages indexed.
  final int pages;

  /// Throws a [StateError] once the atlas is disposed, in every build mode.
  AtlasHandle get handle =>
      _handle ?? (throw StateError('QvpAtlas is disposed'));

  /// True after [free] or [dispose].
  bool get isDisposed => _handle == null;

  /// Frees backend atlas memory. A second call does nothing.
  void free() {
    final h = _handle;
    if (h != null) {
      _handle = null;
      _backend.atlasFree(h);
    }
  }

  /// The same as [free].
  void dispose() => free();

  /// Page number containing an ayah, or null.
  int? pageOf(int surah, int ayah) => _backend.atlasPageOf(handle, surah, ayah);

  /// First and last ayah `(surah, ayah)` of a page, or null.
  ({(int, int) first, (int, int) last})? pageRange(int page) =>
      _backend.atlasPageRange(handle, page);

  /// Surah metadata for surah [n], or null.
  QvpAtlasSurah? surah(int n) => _backend.atlasSurah(handle, n);

  /// All surahs in the atlas.
  List<QvpAtlasSurah> surahs() => _backend.atlasSurahs(handle);

  /// First page of surah [n], or null.
  int? pageOfSurah(int n) => surah(n)?.page;

  /// Start of division [n] of [division] ('juz' | 'hizb' | 'nisf' | 'rubuAlHizb' or [QvpDiv]).
  QvpAtlasRubuAlHizb? division(Object division, int n) =>
      _backend.atlasDivision(handle, QvpDiv.of(division), n);

  /// Where juz [n] (1 to 30) starts, or null.
  QvpAtlasRubuAlHizb? juz(int n) => division('juz', n);

  /// Where hizb [n] (1 to 60) starts, or null.
  QvpAtlasRubuAlHizb? hizb(int n) => division('hizb', n);

  /// Where `rubu_al_hizb` [n] (1 to 240) starts, or null.
  QvpAtlasRubuAlHizb? rubuAlHizb(int n) => division('rubuAlHizb', n);

  /// Division number containing an ayah, or null.
  int? divisionOf(Object division, int surah, int ayah) =>
      _backend.atlasDivisionOf(handle, QvpDiv.of(division), surah, ayah);

  /// The juz that holds an ayah, or null.
  int? juzOf(int surah, int ayah) => divisionOf('juz', surah, ayah);

  /// `[first, last]` page of a juz, or null.
  List<int>? pagesOfJuz(int n) => _backend.atlasPagesOfJuz(handle, n);

  /// Surahs matching a (partial, any-script) name.
  List<QvpAtlasSurah> searchSurahs(String text) {
    final ids = _backend.atlasSearchSurahs(handle, text);
    return [for (final k in ids) surah(k)]
        .whereType<QvpAtlasSurah>()
        .toList(growable: false);
  }

  /// Full atlas in JSON format.
  String json() => _backend.atlasJson(handle);
}

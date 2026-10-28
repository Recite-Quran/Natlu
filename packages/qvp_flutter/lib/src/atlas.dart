import 'engine.dart';

/// Cross-page lookup (`atlas.qva`).
class QvpAtlas {
  QvpAtlas.fromHandle(this.engine, this._backend, this._handle, this.pages);

  final QvpEngine engine;
  final QvpBackend _backend;
  AtlasHandle? _handle;

  /// Total number of pages indexed.
  final int pages;

  AtlasHandle get handle {
    assert(_handle != null, 'QvpAtlas used after dispose()');
    return _handle!;
  }

  bool get isDisposed => _handle == null;

  void free() {
    if (_handle != null) {
      _backend.atlasFree(_handle!);
      _handle = null;
    }
  }

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

  QvpAtlasRubuAlHizb? juz(int n) => division('juz', n);
  QvpAtlasRubuAlHizb? hizb(int n) => division('hizb', n);
  QvpAtlasRubuAlHizb? rubuAlHizb(int n) => division('rubuAlHizb', n);

  /// Division number containing an ayah, or null.
  int? divisionOf(Object division, int surah, int ayah) =>
      _backend.atlasDivisionOf(handle, QvpDiv.of(division), surah, ayah);

  int? juzOf(int surah, int ayah) => divisionOf('juz', surah, ayah);

  /// `[first, last]` page of a juz, or null.
  List<int>? pagesOfJuz(int n) => _backend.atlasPagesOfJuz(handle, n);

  /// Surahs matching a (partial, any-script) name.
  List<QvpAtlasSurah> searchSurahs(String text) {
    final ids = _backend.atlasSearchSurahs(handle, text);
    return [for (final k in ids) surah(k)].whereType<QvpAtlasSurah>().toList(growable: false);
  }

  /// Full atlas in JSON format.
  String json() => _backend.atlasJson(handle);
}

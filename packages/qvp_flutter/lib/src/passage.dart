import 'engine.dart';

/// A contiguous range of complete ayahs, or a surah's basmalah, ready to lay out at any width.
class QvpPassage {
  QvpPassage._(this.engine, this._backend, this._handle, this.ayahs, this.lineSpacing);

  /// Loads ayahs [from] to [to] of [surah] from the pages that print them.
  factory QvpPassage.load(List<QvpPage> pages, int surah, int from, {int? to}) {
    final last = to ?? from;
    _checkU16(surah, 'surah');
    _checkU16(from, 'from');
    _checkU16(last, 'to');
    final engine = _engineOf(pages);
    final handles = [for (final p in pages) p.handle];
    final (handle, ayahs, lineSpacing) = engine.backend.passageLoad(handles, surah, from, last);
    return QvpPassage._(engine, engine.backend, handle, ayahs, lineSpacing);
  }

  /// Loads the basmalah printed above [surah].
  factory QvpPassage.basmalah(List<QvpPage> pages, int surah) {
    _checkU16(surah, 'surah');
    final engine = _engineOf(pages);
    final handles = [for (final p in pages) p.handle];
    final (handle, ayahs, lineSpacing) = engine.backend.passageLoadBasmalah(handles, surah);
    return QvpPassage._(engine, engine.backend, handle, ayahs, lineSpacing);
  }

  static void _checkU16(int v, String name) {
    if (v < 1 || v > 0xffff) throw RangeError.range(v, 1, 0xffff, name);
  }

  static QvpEngine _engineOf(List<QvpPage> pages) {
    if (pages.isEmpty) throw ArgumentError.value(pages, 'pages', 'a passage needs at least one page');
    for (final p in pages) {
      if (p.isDisposed) throw StateError('QvpPassage: a page was disposed');
    }
    return pages.first.engine;
  }

  final QvpEngine engine;
  final QvpBackend _backend;
  PassageHandle? _handle;

  /// The ayahs in reading order. Empty for a basmalah.
  final List<QvpPassageText> ayahs;

  /// The printed line spacing of the passage's first word, in page units.
  final double lineSpacing;

  /// The last layout, if any.
  QvpPassageLayout? currentLayout;

  PassageHandle get handle {
    assert(_handle != null, 'QvpPassage used after close()');
    return _handle!;
  }

  bool get isDisposed => _handle == null;

  /// Frees backend passage memory.
  void close() {
    if (_handle != null) {
      _backend.passageFree(_handle!);
      _handle = null;
    }
  }

  void dispose() => close();

  /// Lays the passage out. Null when spec is out of range.
  QvpPassageLayout? layout(QvpPassageSpec spec) {
    final l = _backend.passageLayout(handle, spec);
    if (l != null) currentLayout = l;
    return l;
  }
}

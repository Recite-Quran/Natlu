// dart:ffi implementation of QvpBackend.
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show Path, PathFillType, Rect;

import 'package:ffi/ffi.dart' as pffi;
import 'package:flutter/foundation.dart';

import '../bindings.dart';
import '../types.dart';
import 'qvp_backend.dart';

/// Creates the default native backend over dart:ffi.
QvpBackend createDefaultBackend({String? path, dynamic library}) =>
    QvpNativeBackend(library: library is ffi.DynamicLibrary ? library : null, path: path);

/// Throws UnsupportedError on native platforms.
Future<QvpBackend> initWebBackend({List<int>? wasmBytes, String? wasmAssetPath, String? wasmUrl}) async =>
    throw UnsupportedError('initWebBackend is only supported on Web platforms.');

/// Native page handle wrapping a C pointer.
final class NativePageHandle implements PageHandle {
  NativePageHandle(this.pointer);
  ffi.Pointer<QvpPageC> pointer;
}

/// Native atlas handle wrapping a C pointer.
final class NativeAtlasHandle implements AtlasHandle {
  NativeAtlasHandle(this.pointer);
  ffi.Pointer<QvpAtlasC> pointer;
}

/// Native passage handle wrapping a C pointer.
final class NativePassageHandle implements PassageHandle {
  NativePassageHandle(this.pointer);
  ffi.Pointer<QvpPassageC> pointer;
}

/// Native ornaments handle wrapping a C pointer.
final class NativeOrnamentsHandle implements OrnamentsHandle {
  NativeOrnamentsHandle(this.pointer);
  ffi.Pointer<QvpOrnamentsC> pointer;
}

/// Native backend implementation of [QvpBackend] over `dart:ffi`.
class QvpNativeBackend implements QvpBackend {
  QvpNativeBackend({ffi.DynamicLibrary? library, String? path})
      : b = QvpBindings(library ?? resolveLibrary(path: path)) {
    _scratch = pffi.calloc<ffi.Uint8>(_scratchBytes);
    _scratchIn = pffi.calloc<ffi.Uint8>(_scratchBytes);
    _str = pffi.calloc<QvpStrC>();
    _target = pffi.calloc<QvpTargetC>();
    _sel = pffi.calloc<QvpSelectorC>();
    _hl = pffi.calloc<QvpHighlightStyleC>();
    _theme = pffi.calloc<QvpThemeC>();
    _spec = pffi.calloc<QvpLayoutSpecC>();
    _layout = pffi.calloc<QvpLayoutC>();
    _hitOpt = pffi.calloc<QvpHitOptionsC>();
    _hit = pffi.calloc<QvpHitC>();
    _crop = pffi.calloc<QvpCropBoundsC>();
    _pageInfo = pffi.calloc<QvpPageInfoC>();
    _geom = pffi.calloc<QvpGeometryC>();
    _wordInfo = pffi.calloc<QvpWordInfoC>();
    _ayahInfo = pffi.calloc<QvpAyahInfoC>();
    _lineInfo = pffi.calloc<QvpLineInfoC>();
    _decoInfo = pffi.calloc<QvpDecorationInfoC>();
    _zoom = pffi.calloc<QvpZoomC>();
    _zoomOut = pffi.calloc<QvpZoomC>();
    _view = pffi.calloc<QvpViewC>();
    _viewOut = pffi.calloc<QvpViewC>();
    _zoomChange = pffi.calloc<QvpZoomChangeC>();
    _dressSpec = pffi.calloc<QvpDressSpecC>();
    _passageSpec = pffi.calloc<QvpPassageSpecC>();
    _passageLayout = pffi.calloc<QvpPassageLayoutC>();
    _ornament = pffi.calloc<QvpOrnamentC>();
    _dressColors = pffi.calloc<ffi.Uint32>(16 * 3);
  }

  static ffi.DynamicLibrary resolveLibrary({String? path}) {
    if (kIsWeb) throw UnsupportedError('QvpNativeBackend runs on native platforms.');
    if (path != null) return ffi.DynamicLibrary.open(path);
    if (Platform.isAndroid) return ffi.DynamicLibrary.open('libqvp_ffi.so');
    if (Platform.isIOS || Platform.isMacOS) {
      final lib = ffi.DynamicLibrary.process();
      try {
        lib.lookup<ffi.NativeFunction<ffi.IntPtr Function()>>('qvp_flutter_dummy_symbol_to_enforce_linking');
      } catch (_) {}
      return lib;
    }
    final env = Platform.environment['QVP_LIB'];
    if (env != null && env.isNotEmpty) return ffi.DynamicLibrary.open(env);
    if (Platform.isWindows) {
      for (final p in ['qvp_ffi.dll', '${File(Platform.resolvedExecutable).parent.path}\\qvp_ffi.dll']) {
        if (File(p).existsSync()) return ffi.DynamicLibrary.open(File(p).absolute.path);
      }
      return ffi.DynamicLibrary.open('qvp_ffi.dll');
    }
    if (Platform.isLinux) {
      for (final p in ['libqvp_ffi.so', '${File(Platform.resolvedExecutable).parent.path}/lib/libqvp_ffi.so']) {
        if (File(p).existsSync()) return ffi.DynamicLibrary.open(File(p).absolute.path);
      }
      return ffi.DynamicLibrary.open('libqvp_ffi.so');
    }
    return ffi.DynamicLibrary.open('libqvp_ffi.so');
  }

  static const int _scratchBytes = 1 << 18; // 256 KB

  final QvpBindings b;
  late final ffi.Pointer<ffi.Uint8> _scratch, _scratchIn;
  late final ffi.Pointer<QvpStrC> _str;
  late final ffi.Pointer<QvpTargetC> _target;
  late final ffi.Pointer<QvpSelectorC> _sel;
  late final ffi.Pointer<QvpHighlightStyleC> _hl;
  late final ffi.Pointer<QvpThemeC> _theme;
  late final ffi.Pointer<QvpLayoutSpecC> _spec;
  late final ffi.Pointer<QvpLayoutC> _layout;
  late final ffi.Pointer<QvpHitOptionsC> _hitOpt;
  late final ffi.Pointer<QvpHitC> _hit;
  late final ffi.Pointer<QvpCropBoundsC> _crop;
  late final ffi.Pointer<QvpPageInfoC> _pageInfo;
  late final ffi.Pointer<QvpGeometryC> _geom;
  late final ffi.Pointer<QvpWordInfoC> _wordInfo;
  late final ffi.Pointer<QvpAyahInfoC> _ayahInfo;
  late final ffi.Pointer<QvpLineInfoC> _lineInfo;
  late final ffi.Pointer<QvpDecorationInfoC> _decoInfo;
  late final ffi.Pointer<QvpZoomC> _zoom, _zoomOut;
  late final ffi.Pointer<QvpViewC> _view, _viewOut;
  late final ffi.Pointer<QvpZoomChangeC> _zoomChange;
  late final ffi.Pointer<QvpDressSpecC> _dressSpec;
  late final ffi.Pointer<QvpPassageSpecC> _passageSpec;
  late final ffi.Pointer<QvpPassageLayoutC> _passageLayout;
  late final ffi.Pointer<QvpOrnamentC> _ornament;
  late final ffi.Pointer<ffi.Uint32> _dressColors;
  bool _disposed = false;

  ffi.Pointer<QvpPageC> _page(PageHandle h) => (h as NativePageHandle).pointer;
  ffi.Pointer<QvpAtlasC> _atlas(AtlasHandle h) => (h as NativeAtlasHandle).pointer;
  ffi.Pointer<QvpPassageC> _passage(PassageHandle h) => (h as NativePassageHandle).pointer;
  ffi.Pointer<QvpOrnamentsC> _ornaments(OrnamentsHandle h) => (h as NativeOrnamentsHandle).pointer;

  static String str(QvpStrC s) => s.len == 0 || s.ptr == ffi.nullptr ? '' : utf8.decode(s.ptr.asTypedList(s.len));
  String _s() => str(_str.ref);

  R _withBytes<R>(List<int> bytes, R Function(ffi.Pointer<ffi.Uint8> p, int len) f) {
    final n = bytes.length;
    if (n <= _scratchBytes) {
      _scratchIn.asTypedList(n).setAll(0, bytes);
      return f(_scratchIn, n);
    }
    final p = pffi.malloc<ffi.Uint8>(n);
    try {
      p.asTypedList(n).setAll(0, bytes);
      return f(p, n);
    } finally {
      pffi.malloc.free(p);
    }
  }

  R _withString<R>(String s, R Function(ffi.Pointer<ffi.Uint8> p, int len) f) => _withBytes(utf8.encode(s), f);

  R _withU32<R>(List<int> v, R Function(ffi.Pointer<ffi.Uint32> p, int n) f) {
    if (v.length * 4 <= _scratchBytes) {
      final p = _scratchIn.cast<ffi.Uint32>();
      p.asTypedList(v.length).setAll(0, v);
      return f(p, v.length);
    }
    final p = pffi.malloc<ffi.Uint32>(v.length);
    try {
      p.asTypedList(v.length).setAll(0, v);
      return f(p, v.length);
    } finally {
      pffi.malloc.free(p);
    }
  }

  List<R> _readArray<C extends ffi.Struct, R>(
    int elemSize,
    int Function(ffi.Pointer<C> out, int cap) fn,
    R Function(ffi.Pointer<C> ptr, int index) decode,
  ) {
    final p = _scratch.cast<C>();
    final cap = _scratchBytes ~/ elemSize;
    final n = fn(p, cap).clamp(0, cap);
    return List<R>.generate(n, (i) => decode(p, i), growable: false);
  }

  List<int> _readU32(int Function(ffi.Pointer<ffi.Uint32> p, int cap) fn) {
    final p = _scratch.cast<ffi.Uint32>();
    final cap = _scratchBytes ~/ 4;
    final n = fn(p, cap).clamp(0, cap);
    return Uint32List.fromList(p.asTypedList(n));
  }

  List<QvpBox> _readBoxes(int Function(ffi.Pointer<QvpBoxC> out, int cap) fn) =>
      _readArray<QvpBoxC, QvpBox>(ffi.sizeOf<QvpBoxC>(), fn, (ptr, i) {
        final b = ptr[i];
        return QvpBox(id: b.id, line: b.line, x0: b.x0, y0: b.y0, x1: b.x1, y1: b.y1, color: b.color, radius: b.radius);
      });

  R _withTarget<R>(PageHandle handle, QvpTarget target, R Function(ffi.Pointer<QvpTargetC> t) f) {
    _writeTarget(_target, target, handle);
    try {
      return f(_target);
    } finally {
      _freeTarget(_target);
    }
  }

  R _withTheme<R>(QvpTheme t, R Function(ffi.Pointer<QvpThemeC> th) f) {
    _writeTheme(_theme, t);
    try {
      return f(_theme);
    } finally {
      _freeTheme(_theme);
    }
  }

  String _name(void Function(int, ffi.Pointer<QvpStrC>) fn, int v) {
    fn(v, _str);
    return _s();
  }

  @override
  String get version {
    b.version(_str);
    return _s();
  }

  @override
  int get formatVersion => b.formatVersion();

  @override
  String get engineName => b.engineName().cast<pffi.Utf8>().toDartString();

  @override
  int nameCount(int table) => b.nameCount(table);

  @override
  String name(int table, int id) => _name((v, out) => b.name(table, v, out), id);

  @override
  int nameId(int table, String s) => _withString(s, (p, n) => b.nameId(table, p, n));

  @override
  String markName(int m) => _name(b.markName, m);

  @override
  String familyName(int f) => _name(b.familyName, f);

  @override
  String kindName(int k) => _name(b.kindName, k);

  @override
  String categoryName(int c) => _name(b.categoryName, c);

  @override
  int markCategory(int m) => b.markCategory(m);

  @override
  int markFromName(String s) => _withString(s, (p, n) => b.markFromName(p, n));

  @override
  String arabic(int op, String s) => _withString(s, (p, n) {
        b.arabic(op, p, n, _str);
        return _s();
      });

  @override
  QvpView viewZoomAbout(QvpView view, double focalX, double focalY, double factor, {double min = 0, double max = 0}) {
    _writeView(_view, view);
    b.viewZoomAbout(_view, focalX, focalY, factor, min, max, _viewOut);
    return _readView(_viewOut.ref);
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _freeTarget(_target);
    _freeTheme(_theme);
    for (final p in <ffi.Pointer>[
      _scratch, _scratchIn, _str, _target, _sel, _hl, _theme, _spec, _layout,
      _hitOpt, _hit, _crop, _pageInfo, _geom, _wordInfo, _ayahInfo, _lineInfo,
      _decoInfo, _zoom, _zoomOut, _view, _viewOut, _zoomChange, _dressSpec,
      _passageSpec, _passageLayout, _ornament, _dressColors,
    ]) {
      pffi.calloc.free(p);
    }
  }

  // ── Page lifecycle ──

  @override
  (PageHandle, QvpPageData) pageLoad(Uint8List bytes) {
    final h = _withBytes(bytes, (p, n) => b.pageLoad(p, n));
    if (h == ffi.nullptr) throw const FormatException('qvp_page_load failed');
    b.pageInfo(h, _pageInfo);
    final i = _pageInfo.ref;
    b.geometry(h, _geom);
    final g = _geom.ref;
    return (
      NativePageHandle(h),
      QvpPageData(
        width: i.width,
        height: i.height,
        lineSpacing: b.pageLineSpacing(h),
        page: i.page,
        nLines: i.nLines,
        nAyahs: i.nAyahs,
        nWords: i.nWords,
        nPaths: i.nPaths,
        nDecorations: i.nDecorations,
        ops: Uint8List.fromList(g.ops.asTypedList(g.opsLen)),
        pts: Float32List.fromList(g.pts.asTypedList(g.ptsLen)),
        table: Uint32List.fromList(g.table.asTypedList(g.nPaths * 8)),
        words: List.generate(i.nWords, (w) => _readWord(h, w), growable: false),
        ayahs: List.generate(i.nAyahs, (a) => _readAyah(h, a), growable: false),
        lines: List.generate(i.nLines, (l) => _readLine(h, l), growable: false),
        decorations: List.generate(i.nDecorations, (d) => _readDeco(h, d), growable: false),
      ),
    );
  }

  @override
  void pageFree(PageHandle handle) {
    final p = _page(handle);
    if (p != ffi.nullptr) {
      b.pageFree(p);
      (handle as NativePageHandle).pointer = ffi.nullptr;
    }
  }

  QvpWordInfo _readWord(ffi.Pointer<QvpPageC> h, int i) {
    if (b.wordInfo(h, i, _wordInfo) == 0) throw StateError('qvp_word_info($i) failed');
    final w = _wordInfo.ref;
    return QvpWordInfo(index: i, surah: w.surah, ayah: w.ayah, word: w.word, line: w.lineNumber, ayahIndex: w.ayahIndex, lineIndex: w.lineIndex, x0: w.x0, y0: w.y0, x1: w.x1, y1: w.y1, text: str(w.text), firstPath: w.firstPath, nPaths: w.nPaths);
  }

  QvpAyahInfo _readAyah(ffi.Pointer<QvpPageC> h, int i) {
    if (b.ayahInfo(h, i, _ayahInfo) == 0) throw StateError('qvp_ayah_info($i) failed');
    final a = _ayahInfo.ref;
    return QvpAyahInfo(index: i, surah: a.surah, ayah: a.ayah, fragment: a.fragment, fragments: a.fragments, flags: a.flags, rubuAlHizb: a.rubuAlHizb, firstWord: a.firstWord, nWords: a.nWords, ayahMarkDecoration: a.ayahMarkDecoration, x0: a.x0, y0: a.y0, x1: a.x1, y1: a.y1);
  }

  QvpLineInfo _readLine(ffi.Pointer<QvpPageC> h, int i) {
    if (b.lineInfo(h, i, _lineInfo) == 0) throw StateError('qvp_line_info($i) failed');
    final l = _lineInfo.ref;
    return QvpLineInfo(index: i, lineNumber: l.lineNumber, isHeader: l.isHeader != 0, firstWord: l.firstWord, nWords: l.nWords, x0: l.x0, y0: l.y0, x1: l.x1, y1: l.y1, bandY0: l.bandY0, bandY1: l.bandY1, centre: l.centre);
  }

  QvpDecorationInfo _readDeco(ffi.Pointer<QvpPageC> h, int i) {
    if (b.decorationInfo(h, i, _decoInfo) == 0) throw StateError('qvp_decoration_info($i) failed');
    final d = _decoInfo.ref;
    return QvpDecorationInfo(index: i, decoration: d.decoration, surah: d.surah, ayah: d.ayah, line: d.line, x0: d.x0, y0: d.y0, x1: d.x1, y1: d.y1, text: str(d.text), firstPath: d.firstPath, nPaths: d.nPaths);
  }

  // ── Page text & query ──

  @override
  String wordForm(PageHandle handle, int wordIndex, int form) {
    b.wordForm(_page(handle), wordIndex, form, _str);
    return _s();
  }

  @override
  int findWord(PageHandle handle, int surah, int ayah, int word) =>
      b.findWord(_page(handle), surah, ayah, word);

  @override
  List<int> targetWords(PageHandle handle, QvpTarget target) =>
      _withTarget(handle, target, (t) => _readU32((p, cap) => b.targetWords(_page(handle), t, p, cap)));

  @override
  List<QvpSurah> surahs(PageHandle handle) {
    final h = _page(handle);
    final n = b.surahCount(h);
    final p = _scratch.cast<QvpSurahC>();
    final places = QvpNames.of(QvpNames.place);
    return List<QvpSurah>.generate(n, (i) {
      b.surahAt(h, i, p);
      final s = p.ref;
      return QvpSurah(
        number: s.number,
        ayahCount: s.ayahCount,
        hasBanner: s.hasBanner != 0,
        hasBasmalah: s.hasBasmalah != 0,
        place: s.place < places.length ? places[s.place] : '',
        bannerDecoration: s.bannerDecoration,
        arabic: str(s.arabic),
        latin: str(s.latin),
        english: str(s.english),
      );
    }, growable: false);
  }

  @override
  List<QvpDivision> divisions(PageHandle handle) => _readArray<QvpDivisionC, QvpDivision>(
        ffi.sizeOf<QvpDivisionC>(),
        (out, cap) => b.divisions(_page(handle), out, cap),
        (ptr, i) {
          final d = ptr[i];
          final divNames = QvpDiv.names;
          return QvpDivision(
            division: d.division < divNames.length ? divNames[d.division] : '',
            line: d.line,
            number: d.number,
            surah: d.surah,
            ayah: d.ayah,
            ayahIndex: d.ayahIndex,
          );
        },
      );

  @override
  List<QvpSurahHeader> surahHeaders(PageHandle handle, {required bool view}) =>
      _readArray<QvpSurahHeaderC, QvpSurahHeader>(
        ffi.sizeOf<QvpSurahHeaderC>(),
        (out, cap) => view ? b.surahHeadersView(_page(handle), out, cap) : b.surahHeaders(_page(handle), out, cap),
        (ptr, i) {
          final h = ptr[i];
          return QvpSurahHeader(decoration: h.decoration, surah: h.surah, line: h.line, x0: h.x0, y0: h.y0, x1: h.x1, y1: h.y1, titleX0: h.titleX0, titleY0: h.titleY0, titleX1: h.titleX1, titleY1: h.titleY1);
        },
      );

  @override
  List<QvpAyahMark> ayahMarks(PageHandle handle) => _readArray<QvpAyahMarkC, QvpAyahMark>(
        ffi.sizeOf<QvpAyahMarkC>(),
        (out, cap) => b.ayahMarks(_page(handle), out, cap),
        (ptr, i) {
          final m = ptr[i];
          return QvpAyahMark(decoration: m.decoration, surah: m.surah, ayah: m.ayah, line: m.line, cx: m.cx, cy: m.cy, r: m.r, ornamentPath: m.ornamentPath, numeralPath: m.numeralPath);
        },
      );

  @override
  List<QvpRosette> rosettes(PageHandle handle) => _readArray<QvpRosetteC, QvpRosette>(
        ffi.sizeOf<QvpRosetteC>(),
        (out, cap) => b.rosettes(_page(handle), out, cap),
        (ptr, i) {
          final r = ptr[i];
          return QvpRosette(decoration: r.decoration, surah: r.surah, ayah: r.ayah, juz: r.juz, hizb: r.hizb, nisf: r.nisf, rubuAlHizb: r.rubuAlHizb, rubuAlHizbInHizb: r.rubuAlHizbInHizb);
        },
      );

  @override
  List<QvpSajdah> sajdahs(PageHandle handle) => _readArray<QvpSajdahC, QvpSajdah>(
        ffi.sizeOf<QvpSajdahC>(),
        (out, cap) => b.sajdahs(_page(handle), out, cap),
        (ptr, i) => QvpSajdah(decoration: ptr[i].decoration, surah: ptr[i].surah, ayah: ptr[i].ayah, signPath: ptr[i].signPath),
      );

  @override
  List<(int, int)> ayahKeys(PageHandle handle) {
    final p = _scratch.cast<ffi.Uint32>();
    final cap = _scratchBytes ~/ 4;
    final n = b.ayahKeys(_page(handle), p, cap).clamp(0, cap);
    return List<(int, int)>.generate(n, (i) => (p[i] >> 16, p[i] & 0xffff), growable: false);
  }

  @override
  ({int count, bool isComplete}) ayahWordCount(PageHandle handle, int surah, int ayah) {
    final completePtr = _scratch.cast<ffi.Uint8>();
    final count = b.ayahWordCount(_page(handle), surah, ayah, completePtr);
    return (count: count, isComplete: completePtr.value != 0);
  }

  @override
  List<int>? reciteMap(PageHandle handle, int surah, int ayah, int nSegments) {
    final p = _scratch.cast<ffi.Uint32>();
    final cap = _scratchBytes ~/ 4;
    final res = b.reciteMap(_page(handle), surah, ayah, nSegments, p, cap);
    if (res < 0) return null;
    return Uint32List.fromList(p.asTypedList(nSegments));
  }

  @override
  String wordLabel(PageHandle handle, int wordIndex) {
    b.wordLabel(_page(handle), wordIndex, _str);
    return _s();
  }

  @override
  String ayahLabel(PageHandle handle, int ayahIndex) {
    b.ayahLabel(_page(handle), ayahIndex, _str);
    return _s();
  }

  @override
  String text(PageHandle handle, QvpTarget target, int form, String wordSep, String lineSep) =>
      _withTarget(handle, target, (t) => _withString(wordSep, (wPtr, wLen) => _withString(lineSep, (lPtr, lLen) {
        b.text(_page(handle), t, form, wPtr, wLen, lPtr, lLen, _str);
        return _s();
      })));

  @override
  List<QvpMatch> search(PageHandle handle, String query, {int form = 4, String mode = 'includes', bool normalize = true, bool looseMatch = true, int limit = 0}) {
    final modeCode = switch (mode) { 'exact' => 1, 'prefix' => 2, _ => 0 };
    return _withString(query, (qPtr, qLen) {
      final p = _scratch.cast<QvpMatchC>();
      final cap = _scratchBytes ~/ ffi.sizeOf<QvpMatchC>();
      final n = b.search(_page(handle), qPtr, qLen, form, modeCode, normalize ? 1 : 0, looseMatch ? 1 : 0, limit, p, cap).clamp(0, cap);
      return List<QvpMatch>.generate(n, (i) => QvpMatch(word: p[i].word, index: p[i].index, isLooseMatch: p[i].isLooseMatch != 0), growable: false);
    });
  }

  @override
  String citation(PageHandle handle, List<int> words) => _withU32(words, (p, n) {
        b.citation(_page(handle), p, n, _str);
        return _s();
      });

  @override
  int attachWords(PageHandle handle, List<int> bytes) =>
      _withBytes(bytes, (p, n) => b.attachWords(_page(handle), p, n));

  @override
  bool hasForm(PageHandle handle, int form) => b.hasForm(_page(handle), form) != 0;

  // ── Hit testing ──

  @override
  QvpHit? hitTestExact(PageHandle handle, double x, double y) =>
      b.hitTestExact(_page(handle), x, y, _hit) == 0 ? null : _readHit(_hit.ref);

  @override
  QvpHit? hitTestExactView(PageHandle handle, double viewX, double viewY) =>
      b.hitTestExactView(_page(handle), viewX, viewY, _hit) == 0 ? null : _readHit(_hit.ref);

  @override
  QvpHit? hitTest(PageHandle handle, double x, double y, QvpHitOptions options) {
    _writeHitOptions(_hitOpt, options);
    return b.hitTest(_page(handle), x, y, _hitOpt, _hit) == 0 ? null : _readHit(_hit.ref);
  }

  @override
  QvpHit? hitTestView(PageHandle handle, double viewX, double viewY, QvpHitOptions options) {
    _writeHitOptions(_hitOpt, options);
    return b.hitTestView(_page(handle), viewX, viewY, _hitOpt, _hit) == 0 ? null : _readHit(_hit.ref);
  }

  @override
  List<QvpLineBand> lineBands(PageHandle handle) => _readArray<QvpLineBandC, QvpLineBand>(
        ffi.sizeOf<QvpLineBandC>(),
        (out, cap) => b.lineBands(_page(handle), out, cap),
        (ptr, i) {
          final lb = ptr[i];
          return QvpLineBand(line: lb.line, lineNumber: lb.lineNumber, y0: lb.y0, y1: lb.y1, mid: lb.mid, inkY0: lb.inkY0, inkY1: lb.inkY1);
        },
      );

  @override
  List<QvpHitArea> hitAreas(PageHandle handle, double gapBias) => _readArray<QvpHitAreaC, QvpHitArea>(
        ffi.sizeOf<QvpHitAreaC>(),
        (out, cap) => b.hitAreas(_page(handle), gapBias, out, cap),
        (ptr, i) {
          final ha = ptr[i];
          return QvpHitArea(word: ha.word, line: ha.line, x0: ha.x0, y0: ha.y0, x1: ha.x1, y1: ha.y1, inkX0: ha.inkX0, inkY0: ha.inkY0, inkX1: ha.inkX1, inkY1: ha.inkY1);
        },
      );

  // ── Layout & zoom ──

  @override
  QvpLayout layout(PageHandle handle, QvpLayoutSpec spec) {
    _writeSpec(_spec, spec);
    b.layout(_page(handle), _spec, _layout);
    return _readLayout(_layout.ref);
  }

  QvpZoomChange _readZoomChange(QvpZoomChangeC c) =>
      QvpZoomChange(zoom: _readZoom(c.zoom), view: _readView(c.view), relaid: c.relaid != 0);

  @override
  QvpZoomChange zoomPinch(PageHandle handle, QvpLayoutSpec spec, QvpZoom zoom, QvpView view, double factor, double focalX, double focalY) {
    _writeSpec(_spec, spec);
    _writeZoom(_zoom, zoom);
    _writeView(_view, view);
    b.zoomPinch(_page(handle), _spec, _zoom, _view, factor, focalX, focalY, _zoomChange);
    return _readZoomChange(_zoomChange.ref);
  }

  @override
  QvpZoomChange zoomToStep(PageHandle handle, QvpLayoutSpec spec, QvpZoom zoom, int step, QvpView view) {
    _writeSpec(_spec, spec);
    _writeZoom(_zoom, zoom);
    _writeView(_view, view);
    b.zoomToStep(_page(handle), _spec, _zoom, step, _view, _zoomChange);
    return _readZoomChange(_zoomChange.ref);
  }

  @override
  QvpZoom zoomMode(PageHandle handle, QvpLayoutSpec spec, QvpZoom zoom, QvpZoomMode mode) {
    _writeSpec(_spec, spec);
    _writeZoom(_zoom, zoom);
    b.zoomMode(_page(handle), _spec, _zoom, mode.index, _zoomOut);
    return _readZoom(_zoomOut.ref);
  }

  @override
  QvpLayoutSpec zoomSpec(PageHandle handle, QvpLayoutSpec spec, QvpZoom zoom) {
    _writeSpec(_spec, spec);
    _writeZoom(_zoom, zoom);
    final p = _scratch.cast<QvpLayoutSpecC>();
    b.zoomSpec(_page(handle), _spec, _zoom, p);
    return _readSpec(p.ref);
  }

  @override
  QvpZoom zoomCarried(PageHandle handle, QvpLayoutSpec spec, QvpZoom zoom) {
    _writeSpec(_spec, spec);
    _writeZoom(_zoom, zoom);
    b.zoomCarried(_page(handle), _spec, _zoom, _zoomOut);
    return _readZoom(_zoomOut.ref);
  }

  @override
  double zoomAtStep(PageHandle handle, QvpLayoutSpec spec, int step) {
    _writeSpec(_spec, spec);
    return b.zoomAtStep(_page(handle), _spec, step);
  }

  @override
  Float32List zoomSteps(PageHandle handle, QvpLayoutSpec spec) {
    _writeSpec(_spec, spec);
    final p = _scratch.cast<ffi.Float>();
    final cap = _scratchBytes ~/ 4;
    final n = b.zoomSteps(_page(handle), _spec, p, cap).clamp(0, cap);
    return Float32List.fromList(p.asTypedList(n));
  }

  @override
  double reflowMaxZoom(PageHandle handle, QvpLayoutSpec spec) {
    _writeSpec(_spec, spec);
    return b.reflowMaxZoom(_page(handle), _spec);
  }

  @override
  bool isZoomed(QvpZoom zoom, QvpView view, double fitScale) {
    _writeZoom(_zoom, zoom);
    _writeView(_view, view);
    return b.zoomIsZoomed(_zoom, _view, fitScale) != 0;
  }

  @override
  QvpSideways sidewaysDrag(PageHandle handle, QvpZoom zoom, QvpView view, double fitScale) {
    _writeZoom(_zoom, zoom);
    _writeView(_view, view);
    return b.sidewaysDrag(_page(handle), _zoom, _view, fitScale) == 1 ? QvpSideways.turnPage : QvpSideways.pan;
  }

  @override
  List<QvpDraw> layoutDrawList(PageHandle handle, {double bandTop = 0, double bandBottom = 0}) {
    final p = _scratch.cast<ffi.Uint32>();
    final cap = _scratchBytes ~/ 4;
    final n = b.layoutDrawList(_page(handle), bandTop, bandBottom, p, cap).clamp(0, cap ~/ 2);
    return List<QvpDraw>.generate(n, (i) => QvpDraw(p[i * 2], p[i * 2 + 1]), growable: false);
  }

  @override
  List<QvpPlacement> layoutPlacements(PageHandle handle) {
    final p = _scratch.cast<ffi.Float>();
    final cap = _scratchBytes ~/ 4;
    final n = b.layoutPlacements(_page(handle), p, cap).clamp(0, cap ~/ 4);
    return List<QvpPlacement>.generate(n, (i) => QvpPlacement(p[i * 4], p[i * 4 + 1], p[i * 4 + 2], p[i * 4 + 3]), growable: false);
  }

  @override
  QvpLayout? readLayout(PageHandle handle) =>
      b.layoutCurrent(_page(handle), _layout) == 0 ? null : _readLayout(_layout.ref);

  @override
  int? layoutWordRow(PageHandle handle, int word) {
    final r = b.layoutWordRow(_page(handle), word);
    return r == qvpNone ? null : r;
  }

  @override
  Uint32List layoutRowWords(PageHandle handle, int row) {
    final p = _scratch.cast<ffi.Uint32>();
    final cap = _scratchBytes ~/ 4;
    final n = b.layoutRowWords(_page(handle), row, p, cap).clamp(0, cap);
    return Uint32List.fromList(p.asTypedList(n));
  }

  @override
  ({int lines, double lineSpacing}) pageGrid(PageHandle handle) {
    final p = _scratch.cast<QvpGridC>();
    b.pageGrid(_page(handle), p);
    return (lines: p.ref.lines, lineSpacing: p.ref.lineSpacing);
  }

  @override
  double layoutWastedFraction(PageHandle handle, QvpLayoutSpec spec) {
    _writeSpec(_spec, spec);
    return b.layoutWastedFraction(_page(handle), _spec);
  }

  @override
  double layoutPrintedHeight(PageHandle handle, QvpLayoutSpec spec) {
    _writeSpec(_spec, spec);
    return b.layoutPrintedHeight(_page(handle), _spec);
  }

  @override
  double layoutLineSpacingToFill(PageHandle handle, QvpLayoutSpec spec, double max) {
    _writeSpec(_spec, spec);
    return b.layoutLineSpacingToFill(_page(handle), _spec, max);
  }

  @override
  ({double x0, double y0, double x1, double y1}) wordBoundsView(PageHandle handle, int wordIndex) {
    final p = _scratch.cast<ffi.Float>();
    b.wordBoundsView(_page(handle), wordIndex, p);
    return (x0: p[0], y0: p[1], x1: p[2], y1: p[3]);
  }

  // ── Styling & themes ──

  @override
  int style(PageHandle handle, QvpSelector sel, int color, {int ms = 0, int layer = 0}) {
    _writeSelector(_sel, sel);
    return b.styleAdd(_page(handle), layer, _sel, color, ms);
  }

  @override
  int styleTarget(PageHandle handle, QvpTarget target, int color, {int ms = 0, int layer = 0}) =>
      _withTarget(handle, target, (t) => b.styleAddTarget(_page(handle), layer, t, color, ms));

  @override
  int removeStyle(PageHandle handle, int styleHandle) => b.styleRemove(_page(handle), styleHandle);

  @override
  int recolorStyle(PageHandle handle, int styleHandle, int color, int ms) =>
      b.styleRecolor(_page(handle), styleHandle, color, ms);

  @override
  int hide(PageHandle handle, QvpSelector sel) {
    _writeSelector(_sel, sel);
    return b.hide(_page(handle), _sel);
  }

  @override
  void clearStyles(PageHandle handle) => b.styleClear(_page(handle));

  @override
  void clearLayer(PageHandle handle, int layer) => b.styleClearLayer(_page(handle), layer);

  @override
  void setDefaultColor(PageHandle handle, int color) => b.styleDefaultColor(_page(handle), color);

  @override
  int theme(PageHandle handle, QvpTheme t) => _withTheme(t, (th) => b.theme(_page(handle), th));

  @override
  List<int> styleHandles(PageHandle handle) => _readU32((p, cap) => b.styleHandles(_page(handle), p, cap));

  // ── Animation & display ──

  @override
  bool tick(PageHandle handle, double nowMs) => b.tick(_page(handle), nowMs) != 0;

  @override
  Uint32List colors(PageHandle handle, int nPaths) =>
      Uint32List.fromList(b.colors(_page(handle)).asTypedList(nPaths));

  @override
  List<QvpStyledPath> styledPaths(PageHandle handle) {
    final p = _scratch.cast<ffi.Uint32>();
    final cap = _scratchBytes ~/ 8;
    final n = b.styledPaths(_page(handle), p, cap).clamp(0, cap);
    return List<QvpStyledPath>.generate(n, (i) => (path: p[i * 2], color: p[i * 2 + 1]), growable: false);
  }

  @override
  int colorOf(PageHandle handle, int path) => b.colorOf(_page(handle), path);

  // ── Highlights ──

  @override
  int highlight(PageHandle handle, QvpTarget target, QvpHighlightStyle style) =>
      _withTarget(handle, target, (t) {
        _writeHighlight(_hl, style);
        return b.highlight(_page(handle), t, _hl);
      });

  @override
  bool moveHighlight(PageHandle handle, int highlightHandle, QvpTarget target) =>
      _withTarget(handle, target, (t) => b.moveHighlight(_page(handle), highlightHandle, t) != 0);

  @override
  bool restyleHighlight(PageHandle handle, int highlightHandle, QvpHighlightStyle style) {
    _writeHighlight(_hl, style);
    return b.restyleHighlight(_page(handle), highlightHandle, _hl) != 0;
  }

  @override
  bool removeHighlight(PageHandle handle, int highlightHandle) =>
      b.removeHighlight(_page(handle), highlightHandle) != 0;

  @override
  void clearHighlights(PageHandle handle) => b.clearHighlights(_page(handle));

  @override
  List<int> highlightHandles(PageHandle handle) => _readU32((p, cap) => b.highlightHandles(_page(handle), p, cap));

  @override
  List<int> highlightWords(PageHandle handle, int highlightHandle) =>
      _readU32((p, cap) => b.highlightWords(_page(handle), highlightHandle, p, cap));

  @override
  List<QvpBox> highlightBoxesView(PageHandle handle) => _readBoxes((out, cap) => b.highlightBoxesView(_page(handle), out, cap));

  @override
  List<QvpBox> wordBands(PageHandle handle, List<int> ws, {required bool inkHeight, required double padX, required double padY}) =>
      _withU32(ws, (wPtr, n) => _readBoxes((out, cap) => b.wordBands(_page(handle), wPtr, n, inkHeight ? 1 : 0, padX, padY, out, cap)));

  // ── Selection ──

  @override
  void select(PageHandle handle, int anchor, int focus) => b.select(_page(handle), anchor, focus);

  @override
  List<int> selection(PageHandle handle) => _readU32((p, cap) => b.selection(_page(handle), p, cap));

  @override
  String selectionText(PageHandle handle, int form, bool includeCitation) {
    b.selectionText(_page(handle), form, includeCitation ? 1 : 0, _str);
    return _s();
  }

  // ── Masks & memorisation ──

  @override
  void mask(PageHandle handle, QvpTarget target, int mode) =>
      _withTarget(handle, target, (t) => b.mask(_page(handle), t, mode));

  @override
  void maskFrom(PageHandle handle, int wordIndex, int mode) => b.maskFrom(_page(handle), wordIndex, mode);

  @override
  void maskOptions(PageHandle handle, int blockColor, double padX, double padY, double radius, bool reverse) =>
      b.maskOptions(_page(handle), blockColor, padX, padY, radius, reverse ? 1 : 0);

  @override
  int unmaskNext(PageHandle handle, int n) => b.unmaskNext(_page(handle), n);

  @override
  int maskBack(PageHandle handle, int n) => b.maskBack(_page(handle), n);

  @override
  bool unmaskWord(PageHandle handle, int wordIndex) => b.unmaskWord(_page(handle), wordIndex) != 0;

  @override
  bool maskWord(PageHandle handle, int wordIndex) => b.maskWord(_page(handle), wordIndex) != 0;

  @override
  void unmaskAll(PageHandle handle) => b.unmaskAll(_page(handle));

  @override
  void maskAll(PageHandle handle) => b.maskAll(_page(handle));

  @override
  void unmask(PageHandle handle) => b.unmask(_page(handle));

  @override
  List<int> maskHidden(PageHandle handle) => _readU32((p, cap) => b.maskHidden(_page(handle), p, cap));

  @override
  List<int> maskWords(PageHandle handle) => _readU32((p, cap) => b.maskWords(_page(handle), p, cap));

  @override
  List<QvpBox> maskBoxesView(PageHandle handle) => _readBoxes((out, cap) => b.maskBoxesView(_page(handle), out, cap));

  // ── Reveal ──

  @override
  int revealStart(PageHandle handle, {required int lit, required bool byAyah, required int grey, required int ink, required bool ayahMarks, required int ms}) =>
      b.revealStart(_page(handle), lit, byAyah ? 1 : 0, grey, ink, ayahMarks ? 1 : 0, ms);

  @override
  bool revealGoto(PageHandle handle, int at) => b.revealGoto(_page(handle), at) != 0;

  @override
  int? revealPosition(PageHandle handle) {
    final r = b.revealPosition(_page(handle));
    return r == -2 ? null : r;
  }

  @override
  int revealStepCount(PageHandle handle) => b.revealStepCount(_page(handle));

  @override
  int revealStepOf(PageHandle handle, int wordIndex) => b.revealStepOf(_page(handle), wordIndex);

  @override
  void revealStop(PageHandle handle) => b.revealStop(_page(handle));

  // ── Dress ──

  @override
  bool dress(PageHandle page, OrnamentsHandle set, QvpDressSpec spec) {
    _writeDressSpec(_dressSpec, spec, set);
    return b.dress(_page(page), _ornaments(set), _dressSpec) != 0;
  }

  @override
  void undress(PageHandle page) => b.undress(_page(page));

  @override
  QvpView dressClamp(PageHandle page, QvpView view, double viewportW, double viewportH) {
    _writeView(_view, view);
    b.dressClamp(_page(page), _view, viewportW, viewportH, _viewOut);
    return _readView(_viewOut.ref);
  }

  @override
  QvpDressView dressView(PageHandle page, double scale, double viewportW) {
    final dims = _scratch.cast<ffi.Float>();
    b.dressView(_page(page), scale, viewportW, _viewOut, dims);
    return QvpDressView(view: _readView(_viewOut.ref), width: dims[0], height: dims[1]);
  }

  @override
  QvpDressInfo? dressInfo(PageHandle page) {
    final p = _scratch.cast<QvpDressInfoC>();
    if (b.dressInfo(_page(page), p) == 0) return null;
    final di = p.ref;
    return QvpDressInfo(
      ayahMark: di.ayahMark == qvpNone ? null : di.ayahMark,
      surahHeader: di.surahHeader == qvpNone ? null : di.surahHeader,
      pageFrame: di.pageFrame == qvpNone ? null : di.pageFrame,
      ayahMarks: di.nAyahMarks,
      surahHeaders: di.nSurahHeaders,
      frameRepeats: di.nFrameRepeats,
      frameStretched: di.frameStretched != 0,
      draws: di.nDraws,
      revision: di.revision,
      viewBox: List<double>.generate(4, (i) => di.viewBox[i], growable: false),
      overflow: List<double>.generate(4, (i) => di.overflow[i], growable: false),
    );
  }

  @override
  List<QvpDressDraw> dressGeometry(PageHandle page) {
    final dgPtr = _scratch.cast<QvpDressGeometryC>();
    b.dressGeometry(_page(page), dgPtr);
    final dg = dgPtr.ref;
    final n = dg.nDraws;
    if (n == 0) return const [];
    final ops = dg.ops.asTypedList(dg.opsLen);
    final pts = dg.pts.asTypedList(dg.ptsLen);
    final table = dg.table.asTypedList(n * 9);
    final tf = table.buffer.asFloat32List(table.offsetInBytes, n * 9);

    return List<QvpDressDraw>.generate(n, (i) {
      final off = i * 9;
      final opStart = table[off];
      final opCount = table[off + 1];
      final ptStart = table[off + 2];
      final color = table[off + 4];
      final flags = table[off + 5];
      final strokeWidth = tf[off + 6];
      final part = table[off + 7];
      final placement = table[off + 8];
      final evenOdd = flags & 0x100 != 0;
      final path = Path()..fillType = evenOdd ? PathFillType.evenOdd : PathFillType.nonZero;
      decodeQvpPath(path, ops, opStart, opCount, pts, ptStart);
      return QvpDressDraw(
        path: path,
        color: color,
        kind: QvpOrnamentKind.values[(flags & 0xff).clamp(0, 2)],
        evenOdd: evenOdd,
        stroke: flags & 0x200 != 0,
        strokeWidth: strokeWidth,
        part: part,
        placement: placement == qvpNone ? null : placement,
      );
    }, growable: false);
  }

  // ── Crop ──

  @override
  QvpCropBounds? cropBounds(PageHandle handle, QvpTarget target, {required double pad, required bool keepAyahMarks}) =>
      _withTarget(handle, target, (t) {
        if (b.cropBounds(_page(handle), t, pad, keepAyahMarks ? 1 : 0, _crop) == 0) return null;
        final c = _crop.ref;
        return QvpCropBounds(x0: c.x0, y0: c.y0, x1: c.x1, y1: c.y1, nWords: c.nWords, ayahMarkDecoration: c.ayahMarkDecoration);
      });

  @override
  String? cropSvg(PageHandle handle, QvpTarget target, {required double pad, required bool keepAyahMarks, int? background}) =>
      _withTarget(handle, target, (t) {
        if (b.cropSvg(_page(handle), t, pad, keepAyahMarks ? 1 : 0, background ?? 0, _str) == 0) return null;
        return _s();
      });

  // ── Atlas ──

  @override
  (AtlasHandle, int) atlasLoad(Uint8List bytes) {
    final h = _withBytes(bytes, (p, n) => b.atlasLoad(p, n));
    if (h == ffi.nullptr) throw const FormatException('qvp_atlas_load failed');
    return (NativeAtlasHandle(h), b.atlasPageCount(h));
  }

  @override
  void atlasFree(AtlasHandle handle) {
    final a = _atlas(handle);
    if (a != ffi.nullptr) {
      b.atlasFree(a);
      (handle as NativeAtlasHandle).pointer = ffi.nullptr;
    }
  }

  @override
  int? atlasPageOf(AtlasHandle handle, int surah, int ayah) {
    final p = b.atlasPageOf(_atlas(handle), surah, ayah);
    return p == qvpNone ? null : p;
  }

  @override
  ({(int, int) first, (int, int) last})? atlasPageRange(AtlasHandle handle, int page) {
    final p = _scratch.cast<ffi.Uint16>();
    if (b.atlasPageRange(_atlas(handle), page, p) == 0) return null;
    return (first: (p[0], p[1]), last: (p[2], p[3]));
  }

  @override
  QvpAtlasSurah? atlasSurah(AtlasHandle handle, int n) {
    final p = _scratch.cast<QvpAtlasSurahC>();
    if (b.atlasSurah(_atlas(handle), n, p) == 0) return null;
    final s = p.ref;
    final places = QvpNames.of(QvpNames.place);
    return QvpAtlasSurah(number: s.number, page: s.firstPage, ayahCount: s.ayahCount, place: s.place < places.length ? places[s.place] : '', arabic: str(s.arabic), latin: str(s.latin), english: str(s.english));
  }

  @override
  List<QvpAtlasSurah> atlasSurahs(AtlasHandle handle) {
    final a = _atlas(handle);
    final n = b.atlasSurahs(a);
    final p = _scratch.cast<QvpAtlasSurahC>();
    final places = QvpNames.of(QvpNames.place);
    return List<QvpAtlasSurah>.generate(n, (i) {
      b.atlasSurah(a, i + 1, p);
      final s = p.ref;
      return QvpAtlasSurah(number: s.number, page: s.firstPage, ayahCount: s.ayahCount, place: s.place < places.length ? places[s.place] : '', arabic: str(s.arabic), latin: str(s.latin), english: str(s.english));
    }, growable: false);
  }

  @override
  QvpAtlasRubuAlHizb? atlasDivision(AtlasHandle handle, int division, int n) {
    final p = _scratch.cast<QvpAtlasRubuAlHizbC>();
    if (b.atlasDivision(_atlas(handle), division, n, p) == 0) return null;
    final d = p.ref;
    return QvpAtlasRubuAlHizb(rubuAlHizb: d.rubuAlHizb, page: d.page, surah: d.surah, ayah: d.ayah);
  }

  @override
  int? atlasDivisionOf(AtlasHandle handle, int division, int surah, int ayah) {
    final d = b.atlasDivisionOf(_atlas(handle), division, surah, ayah);
    return d == qvpNone ? null : d;
  }

  @override
  List<int>? atlasPagesOfJuz(AtlasHandle handle, int n) {
    final p = _scratch.cast<ffi.Uint16>();
    return b.atlasPagesOfJuz(_atlas(handle), n, p) == 0 ? null : [p[0], p[1]];
  }

  @override
  List<int> atlasSearchSurahs(AtlasHandle handle, String text) => _withString(text, (tPtr, len) {
        final p = _scratch.cast<ffi.Uint16>();
        final cap = _scratchBytes ~/ 2;
        final n = b.atlasSearchSurahs(_atlas(handle), tPtr, len, p, cap).clamp(0, cap);
        return Uint16List.fromList(p.asTypedList(n));
      });

  @override
  String atlasJson(AtlasHandle handle) {
    b.atlasJson(_atlas(handle), _str);
    return _s();
  }

  // ── Passage ──

  @override
  (PassageHandle, List<QvpPassageText>, double) passageLoad(List<PageHandle> pages, int surah, int from, int to) {
    final pList = pffi.malloc<ffi.Pointer<QvpPageC>>(pages.length);
    for (var i = 0; i < pages.length; i++) {
      pList[i] = _page(pages[i]);
    }
    final p = b.passageLoad(pList, pages.length, surah, from, to);
    pffi.malloc.free(pList);
    if (p == ffi.nullptr) throw const FormatException('qvp_passage_load failed');

    final n = b.passageAyahCount(p);
    final ayahs = List<QvpPassageText>.generate(n, (i) {
      b.passageAyahText(p, i, _str);
      return QvpPassageText(surah: surah, ayah: from + i, text: _s());
    }, growable: false);

    return (NativePassageHandle(p), ayahs, b.passageLineSpacing(p));
  }

  @override
  (PassageHandle, List<QvpPassageText>, double) passageLoadBasmalah(List<PageHandle> pages, int surah) {
    final pList = pffi.malloc<ffi.Pointer<QvpPageC>>(pages.length);
    for (var i = 0; i < pages.length; i++) {
      pList[i] = _page(pages[i]);
    }
    final p = b.passageLoadBasmalah(pList, pages.length, surah);
    pffi.malloc.free(pList);
    if (p == ffi.nullptr) throw const FormatException('qvp_passage_load_basmalah failed');
    return (NativePassageHandle(p), const [], b.passageLineSpacing(p));
  }

  @override
  void passageFree(PassageHandle handle) {
    final p = _passage(handle);
    if (p != ffi.nullptr) {
      b.passageFree(p);
      (handle as NativePassageHandle).pointer = ffi.nullptr;
    }
  }

  @override
  QvpPassageLayout? passageLayout(PassageHandle handle, QvpPassageSpec spec) {
    _writePassageSpec(_passageSpec, spec);
    if (b.passageLayout(_passage(handle), _passageSpec, _passageLayout) == 0) return null;
    final l = _passageLayout.ref;
    final p = _passage(handle);

    final rows = _readArray<QvpPassageRowC, QvpPassageRow>(
      ffi.sizeOf<QvpPassageRowC>(),
      (out, cap) => b.passageRows(p, out, cap),
      (ptr, i) => QvpPassageRow(x0: ptr[i].x0, y0: ptr[i].y0, x1: ptr[i].x1, y1: ptr[i].y1, baseline: ptr[i].baseline),
    );

    final words = _readArray<QvpPassageWordC, QvpPassageWord>(
      ffi.sizeOf<QvpPassageWordC>(),
      (out, cap) => b.passageWords(p, out, cap),
      (ptr, i) {
        final w = ptr[i];
        return QvpPassageWord(surah: w.surah, ayah: w.ayah, word: w.word, page: w.page, row: w.row, x0: w.x0, y0: w.y0, x1: w.x1, y1: w.y1, wordX0: w.wordX0, wordY0: w.wordY0, wordX1: w.wordX1, wordY1: w.wordY1);
      },
    );

    final ayahs = _readArray<QvpPassageAyahC, QvpPassageAyah>(
      ffi.sizeOf<QvpPassageAyahC>(),
      (out, cap) => b.passageAyahs(p, out, cap),
      (ptr, i) => QvpPassageAyah(surah: ptr[i].surah, ayah: ptr[i].ayah, x0: ptr[i].x0, y0: ptr[i].y0, x1: ptr[i].x1, y1: ptr[i].y1),
    );

    final pDraws = _scratch.cast<ffi.Uint32>();
    final capDraws = _scratchBytes ~/ 4;
    final nDraws = b.passageDrawList(p, pDraws, capDraws);
    final draws = List<QvpPassageDraw>.generate(nDraws.clamp(0, capDraws ~/ 3), (i) => QvpPassageDraw(pDraws[i * 3], pDraws[i * 3 + 1], pDraws[i * 3 + 2]), growable: false);

    final pPlaces = _scratch.cast<ffi.Float>();
    final capPlaces = _scratchBytes ~/ 4;
    final nPlaces = b.passagePlacements(p, pPlaces, capPlaces);
    final places = List<QvpPlacement>.generate(nPlaces.clamp(0, capPlaces ~/ 4), (i) => QvpPlacement(pPlaces[i * 4], pPlaces[i * 4 + 1], pPlaces[i * 4 + 2], pPlaces[i * 4 + 3]), growable: false);

    return QvpPassageLayout(
      width: l.width,
      height: l.height,
      scale: l.scale,
      lineSpacing: l.lineSpacing,
      isTruncated: l.isTruncated != 0,
      ellipsis: l.isTruncated != 0 ? Rect.fromLTRB(l.ellipsisX0, l.ellipsisY0, l.ellipsisX1, l.ellipsisY1) : null,
      rows: rows,
      words: words,
      ayahs: ayahs,
      draws: draws,
      placements: places,
    );
  }

  // ── Ornaments ──

  @override
  (OrnamentsHandle, List<QvpOrnament>) ornamentsLoad(Uint8List bytes) {
    final h = _withBytes(bytes, (p, n) => b.ornamentsLoad(p, n));
    if (h == ffi.nullptr) throw const FormatException('qvp_ornaments_load failed');

    final n = b.ornamentCount(h);
    final pPart = _scratch.cast<QvpOrnamentPartC>();
    final list = List<QvpOrnament>.generate(n, (i) {
      b.ornamentInfo(h, i, _ornament);
      final o = _ornament.ref;
      final parts = List<QvpOrnamentPart>.generate(o.nParts, (pi) {
        b.ornamentPart(h, i, pi, pPart);
        final pt = pPart.ref;
        return QvpOrnamentPart(index: pi, name: str(pt.name), color: pt.color, stroke: pt.stroke != 0);
      }, growable: false);

      return QvpOrnament(
        index: i,
        kind: QvpOrnamentKind.values[o.kind.clamp(0, 2)],
        lineage: QvpLineage.values[o.lineage.clamp(0, 1)],
        style: str(o.style),
        riwayah: str(o.riwayah),
        hasSlices: o.hasSlices != 0,
        licence: QvpOrnamentLicence(id: str(o.licenseId), status: str(o.licenseStatus), redistributable: o.redistributable != 0, attribution: str(o.attribution)),
        parts: parts,
      );
    }, growable: false);

    return (NativeOrnamentsHandle(h), list);
  }

  @override
  void ornamentsFree(OrnamentsHandle handle) {
    final o = _ornaments(handle);
    if (o != ffi.nullptr) {
      b.ornamentsFree(o);
      (handle as NativeOrnamentsHandle).pointer = ffi.nullptr;
    }
  }

  @override
  int ornamentFind(OrnamentsHandle handle, int kind, String style) =>
      _withString(style, (p, n) => b.ornamentFind(_ornaments(handle), kind, p, n));

  // ── Struct encoders & decoders ──

  void _writeTarget(ffi.Pointer<QvpTargetC> p, QvpTarget t, [PageHandle? handle]) {
    final r = p.ref;
    r.target = t.code;
    if (t.wordKey != null && handle != null) {
      final wk = t.wordKey!;
      final w = b.findWord(_page(handle), wk[0], wk[1], wk[2]);
      r.a = w < 0 ? 0 : w;
    } else {
      r.a = t.argA;
    }
    r.b = t.argB;
    r.c = t.argC;
    if (t.words != null && t.words!.isNotEmpty) {
      final ws = t.words!;
      final ptr = pffi.malloc<ffi.Uint32>(ws.length);
      ptr.asTypedList(ws.length).setAll(0, ws);
      r.words = ptr;
      r.nWords = ws.length;
    } else {
      r.words = ffi.nullptr;
      r.nWords = 0;
    }
  }

  void _freeTarget(ffi.Pointer<QvpTargetC> p) {
    if (p.ref.words != ffi.nullptr) {
      pffi.malloc.free(p.ref.words);
      p.ref.words = ffi.nullptr;
      p.ref.nWords = 0;
    }
  }

  void _writeSelector(ffi.Pointer<QvpSelectorC> p, QvpSelector s) {
    final r = p.ref;
    r.selector = s.code;
    r.a = s.argA;
    r.b = s.argB;
    r.c = s.argC;
  }

  void _writeHighlight(ffi.Pointer<QvpHighlightStyleC> p, QvpHighlightStyle s) {
    final r = p.ref;
    r.mode = s.modeCode;
    r.height = s.heightCode;
    r.ink = s.inkRgba;
    r.band = s.bandRgba;
    r.padX = s.padX;
    r.padY = s.padY;
    r.radius = s.radius;
    r.seam = s.seam;
    r.transitionMs = s.ms;
    r.layer = s.layer;
  }

  void _writeTheme(ffi.Pointer<QvpThemeC> p, QvpTheme t) {
    final r = p.ref;
    r.ink = t.ink != null ? rgba(t.ink!) : 0;
    r.diacritics = t.diacritics != null ? rgba(t.diacritics!) : 0;
    r.dots = t.dots != null ? rgba(t.dots!) : 0;
    r.waqf = t.waqf != null ? rgba(t.waqf!) : 0;
    r.sifr = t.sifr != null ? rgba(t.sifr!) : 0;
    r.ayahMark = t.ayahMark != null ? rgba(t.ayahMark!) : 0;
    r.numeral = t.numeral != null ? rgba(t.numeral!) : 0;
    r.headers = t.headers != null ? rgba(t.headers!) : 0;
    r.transitionMs = t.ms;
    final marks = t.marks;
    if (marks.isNotEmpty) {
      final entries = marks.entries.toList();
      final pMarks = pffi.malloc<ffi.Uint32>(entries.length * 2);
      for (var i = 0; i < entries.length; i++) {
        pMarks[i * 2] = QvpMark.id(entries[i].key);
        pMarks[i * 2 + 1] = rgba(entries[i].value);
      }
      r.marks = pMarks;
      r.nMarks = entries.length;
    } else {
      r.marks = ffi.nullptr;
      r.nMarks = 0;
    }
  }

  void _freeTheme(ffi.Pointer<QvpThemeC> p) {
    if (p.ref.marks != ffi.nullptr) {
      pffi.malloc.free(p.ref.marks);
      p.ref.marks = ffi.nullptr;
      p.ref.nMarks = 0;
    }
  }

  void _writeSpec(ffi.Pointer<QvpLayoutSpecC> p, QvpLayoutSpec s) {
    final r = p.ref;
    r.viewportW = s.viewportW;
    r.viewportH = s.viewportH;
    r.padTop = s.padTop;
    r.padBottom = s.padBottom;
    r.padLeft = s.padLeft;
    r.padRight = s.padRight;
    r.lineSpacing = s.lineSpacing;
    r.fillHeight = s.fillHeight ? 1 : 0;
    r.gridLines = s.gridLines;
    r.cropLeft = s.cropLeft;
    r.cropRight = s.cropRight;
    r.maxAspectSlack = s.maxAspectSlack;
    r.bannerZoom = s.bannerZoom;
    r.surahFrames = s.surahFrames ? 1 : 0;
    r.reflowZoom = s.reflowZoomValue;
    r.reflowFill = s.reflowFillCode;
    r.reflowBreaks = s.reflowBreaksCode;
    r.reflowGaps = s.reflowGapsCode;
    r.reflowWordGap = s.reflowWordGapValue;
    r.reflowMaxStretch = s.reflowMaxStretchValue;
    r.reflowRelax = s.reflowRelaxValue;
  }

  void _writeHitOptions(ffi.Pointer<QvpHitOptionsC> p, QvpHitOptions opt) {
    p.ref.maxDistance = opt.maxDistance;
    p.ref.gapBias = opt.gapBias;
    p.ref.preferExact = opt.preferExact ? 1 : 0;
  }

  void _writeView(ffi.Pointer<QvpViewC> p, QvpView v) {
    p.ref.scale = v.scale;
    p.ref.offsetX = v.offsetX;
    p.ref.offsetY = v.offsetY;
  }

  void _writeZoom(ffi.Pointer<QvpZoomC> p, QvpZoom z) {
    p.ref.step = z.step;
    p.ref.zoom = z.zoom;
    p.ref.mode = z.mode.index;
  }

  void _writeDressSpec(ffi.Pointer<QvpDressSpecC> p, QvpDressSpec s, OrnamentsHandle set) {
    final r = p.ref;
    int resolve(Object? ref, int kind) {
      if (ref == null) return qvpNone;
      if (ref is int) return ref;
      if (ref is QvpOrnament) return ref.index;
      if (ref is String) return ornamentFind(set, kind, ref);
      return qvpNone;
    }
    r.ayahMark = resolve(s.ayahMark ?? s.style, 0);
    r.surahHeader = resolve(s.surahHeader ?? s.style, 1);
    r.pageFrame = resolve(s.pageFrame ?? s.style, 2);
    r.gap = s.gap;
    r.bandGap = s.bandGap;
    r.ayahMarkScale = s.ayahMarkScale;
    r.pageFrameScale = s.pageFrameScale;
    r.lineArt = s.lineArtBits;
    r.nColors = s.colors.length.clamp(0, 16);
    if (r.nColors > 0) {
      for (var i = 0; i < r.nColors; i++) {
        final (o, part, col) = s.colors[i];
        final oi = o is QvpOrnament ? o.index : (o as int);
        _dressColors[i * 3] = oi;
        _dressColors[i * 3 + 1] = part;
        _dressColors[i * 3 + 2] = rgba(col);
      }
      r.colors = _dressColors;
    } else {
      r.colors = ffi.nullptr;
    }
  }

  void _writePassageSpec(ffi.Pointer<QvpPassageSpecC> p, QvpPassageSpec s) {
    final r = p.ref;
    r.width = s.width;
    r.scale = s.scale;
    r.lineSpacing = s.lineSpacing;
    r.padding = s.padding;
    r.align = s.alignCode;
    r.maxRows = s.maxRows;
    r.keepAyahMark = s.keepAyahMark ? 1 : 0;
    r.ellipsisWidth = s.ellipsisWidth;
    r.maxStretch = s.maxStretch;
  }

  QvpHit _readHit(QvpHitC h) => QvpHit(
        word: h.word == qvpNone ? -1 : h.word,
        path: h.path == qvpNone ? -1 : h.path,
        decoration: h.decoration == qvpNone ? -1 : h.decoration,
        line: h.line == qvpNone ? -1 : h.line,
        distance: h.distance,
        isExact: h.isExact != 0,
      );

  QvpView _readView(QvpViewC v) => QvpView(scale: v.scale, offsetX: v.offsetX, offsetY: v.offsetY);

  QvpZoom _readZoom(QvpZoomC z) => QvpZoom(step: z.step, zoom: z.zoom, mode: QvpZoomMode.values[z.mode.clamp(0, 2)]);

  QvpLayout _readLayout(QvpLayoutC l) {
    final n = l.nLines;
    final dy = Float32List(n);
    final slots = <(double, double)>[];
    if (l.lines != ffi.nullptr && n > 0) {
      final p = l.lines.asTypedList(n * 3);
      for (var i = 0; i < n; i++) {
        dy[i] = p[i * 3];
        slots.add((p[i * 3 + 1].toDouble(), p[i * 3 + 2].toDouble()));
      }
    }
    return QvpLayout(
      scale: l.scale,
      offsetX: l.offsetX,
      offsetY: l.offsetY,
      contentW: l.contentW,
      contentH: l.contentH,
      lineSpacing: l.lineSpacing,
      lineDy: dy,
      slots: slots,
      fitScale: l.fitScale,
      fitX: l.fitX,
      fitY: l.fitY,
      reflowed: l.reflowed != 0,
      rows: l.nRows,
    );
  }

  QvpLayoutSpec _readSpec(QvpLayoutSpecC s) => QvpLayoutSpec(
        viewportW: s.viewportW,
        viewportH: s.viewportH,
        padTop: s.padTop,
        padBottom: s.padBottom,
        padLeft: s.padLeft,
        padRight: s.padRight,
        lineSpacing: s.lineSpacing,
        fillHeight: s.fillHeight != 0,
        gridLines: s.gridLines,
        cropLeft: s.cropLeft,
        cropRight: s.cropRight,
        maxAspectSlack: s.maxAspectSlack,
        bannerZoom: s.bannerZoom,
        surahFrames: s.surahFrames != 0,
        reflow: s.reflowZoom > 0 || s.reflowFill != 255 || s.reflowBreaks != 255
            ? QvpReflowSpec(
                zoom: s.reflowZoom,
                fill: switch (s.reflowFill) { 0 => 'ragged', 1 => 'justified', _ => 'centred' },
                breaks: switch (s.reflowBreaks) { 0 => 'greedy', 1 => 'even', 3 => 'printed', _ => 'fitted' },
                gaps: s.reflowGaps == 0 ? 'printed' : 'uniform',
                wordGap: s.reflowWordGap,
                maxStretch: s.reflowMaxStretch,
                relax: s.reflowRelax,
              )
            : null,
      );
}

// dart:js_interop implementation of QvpBackend for Flutter Web.
import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';
import 'dart:ui' show Path, PathFillType, Rect;

import 'package:flutter/services.dart' show rootBundle;

import '../types.dart';
import 'qvp_backend.dart';

QvpWebBackend? _defaultWebBackend;
Future<QvpWebBackend>? _initWebFuture;

const _formNames = ['rasm_uthmani', 'rasm_imlai', 'qpc', 'rasm', 'search'];
const _maskModeNames = ['hide', 'block', 'blur'];
const _divKindNames = {0: 'juz', 1: 'hizb', 2: 'nisf', 3: 'rubu_al_hizb'};

/// Creates or returns the Web backend over dart:js_interop and WebAssembly.
QvpBackend createDefaultBackend({String? path, dynamic library}) {
  if (_defaultWebBackend != null) return _defaultWebBackend!;
  throw StateError('On Flutter Web, call `await QvpEngine.initWeb()` before accessing QvpEngine, or ensure assets are bundled.');
}

/// Initializes the Web backend on Flutter Web.
Future<QvpBackend> initWebBackend({List<int>? wasmBytes, String? wasmAssetPath, String? wasmUrl}) {
  if (_defaultWebBackend != null) return Future.value(_defaultWebBackend!);
  return _initWebFuture ??= QvpWebBackend.init(
    wasmBytes: wasmBytes,
    wasmAssetPath: wasmAssetPath,
    wasmUrl: wasmUrl,
  ).then((b) => _defaultWebBackend = b);
}

final class WebPageHandle implements PageHandle {
  WebPageHandle(this.js);
  JSObject js;
}

final class WebAtlasHandle implements AtlasHandle {
  WebAtlasHandle(this.js);
  JSObject js;
}

final class WebPassageHandle implements PassageHandle {
  WebPassageHandle(this.js);
  JSObject js;
}

final class WebOrnamentsHandle implements OrnamentsHandle {
  WebOrnamentsHandle(this.js);
  JSObject js;
}

// ── Extension types for direct zero-copy JS object access ──

extension type JSQvpWord(JSObject _) implements JSObject {
  external int get index; external int get surah; external int get ayah; external int get word;
  external int get line; external int get ayahIndex; external int get lineIndex;
  external double get x0; external double get y0; external double get x1; external double get y1;
  external String get text; external int get firstPath; external int get nPaths;
}

extension type JSQvpAyah(JSObject _) implements JSObject {
  external int get index; external int get surah; external int get ayah; external int get fragment;
  external int get fragments; external int get flags; external int get rubuAlHizb; external int get firstWord;
  external int get nWords; external int get ayahMarkDecoration;
  external double get x0; external double get y0; external double get x1; external double get y1;
}

extension type JSQvpLine(JSObject _) implements JSObject {
  external int get index; external int get lineNumber; external bool get isHeader;
  external int get firstWord; external int get nWords;
  external double get x0; external double get y0; external double get x1; external double get y1;
  external double get bandY0; external double get bandY1; external double get centre;
}

extension type JSQvpDecoration(JSObject _) implements JSObject {
  external int get index; external int get decoration; external int get surah; external int get ayah;
  external int get line; external double get x0; external double get y0; external double get x1; external double get y1;
  external String get text; external int get firstPath; external int get nPaths;
}

extension type JSQvpBox(JSObject _) implements JSObject {
  external int get id; external int get line;
  external double get x0; external double get y0; external double get x1; external double get y1;
  external int get color; external double get radius;
}

/// Web backend implementation of [QvpBackend] using `dart:js_interop`.
class QvpWebBackend implements QvpBackend {
  QvpWebBackend(this.js);

  final JSObject js;

  static JSObject get _qvp {
    final qvp = globalContext['QVP'] as JSObject?;
    if (qvp == null) throw StateError('QVP JavaScript library is not loaded. Ensure qvp.js is included in web/index.html or available as an asset.');
    return qvp;
  }

  static Future<QvpWebBackend> init({List<int>? wasmBytes, String? wasmAssetPath, String? wasmUrl}) async {
    await _ensureLoaded();
    final Uint8List bytes;
    if (wasmBytes != null) {
      bytes = Uint8List.fromList(wasmBytes);
    } else if (wasmAssetPath != null) {
      final data = await rootBundle.load(wasmAssetPath);
      bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    } else {
      bytes = await _loadDefaultWasm(wasmUrl);
    }

    final jsEngineClass = _qvp['QvpEngine'] as JSObject;
    final promise = jsEngineClass.callMethod<JSPromise>('init'.toJS, bytes.toJS);
    final jsInstance = (await promise.toDart) as JSObject;
    final backend = QvpWebBackend(jsInstance);
    _defaultWebBackend ??= backend;
    return backend;
  }

  static Future<void> _ensureLoaded() async {
    if (globalContext.has('QVP')) return;
    for (final path in const [
      'packages/qvp_flutter/assets/js/qvp.js',
      'assets/packages/qvp_flutter/assets/js/qvp.js',
      'assets/js/qvp.js',
    ]) {
      try {
        final jsText = await rootBundle.loadString(path);
        _injectScript(jsText);
        if (globalContext.has('QVP')) return;
      } catch (_) {}
    }
    for (final url in const [
      'assets/packages/qvp_flutter/assets/js/qvp.js',
      'packages/qvp_flutter/assets/js/qvp.js',
      'qvp.js',
      'assets/qvp.js',
    ]) {
      try {
        final jsText = await _fetchString(url);
        _injectScript(jsText);
        if (globalContext.has('QVP')) return;
      } catch (_) {}
    }
  }

  static void _injectScript(String code) {
    final doc = globalContext['document'] as JSObject?;
    if (doc != null) {
      final script = doc.callMethod<JSObject>('createElement'.toJS, 'script'.toJS);
      script['text'] = code.toJS;
      final head = (doc['head'] ?? doc['body']) as JSObject?;
      head?.callMethod('appendChild'.toJS, script);
    }
  }

  static Future<Uint8List> _loadDefaultWasm(String? wasmUrl) async {
    if (wasmUrl != null) return _fetchBytes(wasmUrl);
    for (final path in const [
      'packages/qvp_flutter/assets/wasm/qvp_ffi.wasm',
      'assets/packages/qvp_flutter/assets/wasm/qvp_ffi.wasm',
      'assets/wasm/qvp_ffi.wasm',
    ]) {
      try {
        final data = await rootBundle.load(path);
        return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
      } catch (_) {}
    }
    for (final url in const [
      'assets/packages/qvp_flutter/assets/wasm/qvp_ffi.wasm',
      'packages/qvp_flutter/assets/wasm/qvp_ffi.wasm',
      'qvp_ffi.wasm',
      'assets/qvp_ffi.wasm',
    ]) {
      try {
        return await _fetchBytes(url);
      } catch (_) {}
    }
    throw StateError('Could not load qvp_ffi.wasm from assets or network.');
  }

  static Future<Uint8List> _fetchBytes(String url) async {
    final responsePromise = globalContext.callMethod<JSPromise>('fetch'.toJS, url.toJS);
    final response = (await responsePromise.toDart) as JSObject;
    final bufferPromise = response.callMethod<JSPromise>('arrayBuffer'.toJS);
    final arrayBuffer = (await bufferPromise.toDart) as JSArrayBuffer;
    return JSUint8Array(arrayBuffer).toDart;
  }

  static Future<String> _fetchString(String url) async {
    final responsePromise = globalContext.callMethod<JSPromise>('fetch'.toJS, url.toJS);
    final response = (await responsePromise.toDart) as JSObject;
    final textPromise = response.callMethod<JSPromise>('text'.toJS);
    return ((await textPromise.toDart) as JSString).toDart;
  }

  static List<QvpBox> _readBoxes(JSArray arr) => List<QvpBox>.generate(arr.length, (i) {
        final b = arr[i] as JSQvpBox;
        return QvpBox(id: b.id, line: b.line, x0: b.x0, y0: b.y0, x1: b.x1, y1: b.y1, color: b.color, radius: b.radius);
      }, growable: false);

  static List<int> _readIntList(JSArray arr) =>
      List<int>.generate(arr.length, (i) => (arr[i] as JSNumber).toDartInt, growable: false);

  JSObject _page(PageHandle h) => (h as WebPageHandle).js;
  JSObject _atlas(AtlasHandle h) => (h as WebAtlasHandle).js;
  JSObject _passage(PassageHandle h) => (h as WebPassageHandle).js;
  JSObject _ornaments(OrnamentsHandle h) => (h as WebOrnamentsHandle).js;

  JSObject _targetToJs(QvpTarget t) {
    final res = JSObject()
      ..['target'] = t.code.toJS
      ..['a'] = t.argA.toJS
      ..['b'] = t.argB.toJS
      ..['c'] = t.argC.toJS;
    if (t.words != null && t.words!.isNotEmpty) {
      res['words'] = Uint32List.fromList(t.words!).toJS;
    }
    return res;
  }

  JSObject _selToJs(QvpSelector s) => JSObject()
    ..['selector'] = s.code.toJS
    ..['a'] = s.argA.toJS
    ..['b'] = s.argB.toJS
    ..['c'] = s.argC.toJS;

  JSObject _hlToJs(QvpHighlightStyle st) => JSObject()
    ..['mode'] = st.mode.toJS
    ..['height'] = st.height.toJS
    ..['ink'] = st.inkRgba.toJS
    ..['band'] = st.bandRgba.toJS
    ..['padX'] = st.padX.toJS
    ..['padY'] = st.padY.toJS
    ..['radius'] = st.radius.toJS
    ..['seam'] = st.seam.toJS
    ..['ms'] = st.ms.toJS
    ..['layer'] = st.layer.toJS;

  JSObject _specToJs(QvpLayoutSpec spec) {
    final s = JSObject()
      ..['viewportW'] = spec.viewportW.toJS
      ..['viewportH'] = spec.viewportH.toJS
      ..['padTop'] = spec.padTop.toJS
      ..['padBottom'] = spec.padBottom.toJS
      ..['padLeft'] = spec.padLeft.toJS
      ..['padRight'] = spec.padRight.toJS
      ..['lineSpacing'] = spec.lineSpacing.toJS
      ..['fillHeight'] = spec.fillHeight.toJS
      ..['gridLines'] = spec.gridLines.toJS
      ..['cropLeft'] = spec.cropLeft.toJS
      ..['cropRight'] = spec.cropRight.toJS
      ..['maxAspectSlack'] = spec.maxAspectSlack.toJS
      ..['bannerZoom'] = spec.bannerZoom.toJS
      ..['surahFrames'] = spec.surahFrames.toJS;
    final r = spec.reflow;
    if (r != null) {
      s['reflow'] = JSObject()
        ..['zoom'] = r.zoom.toJS
        ..['fill'] = r.fill.toJS
        ..['breaks'] = r.breaks.toJS
        ..['gaps'] = r.gaps.toJS
        ..['wordGap'] = r.wordGap.toJS
        ..['maxStretch'] = r.maxStretch.toJS
        ..['relax'] = r.relax.toJS;
    }
    return s;
  }

  JSObject _passageSpecToJs(QvpPassageSpec s) => JSObject()
    ..['width'] = s.width.toJS
    ..['scale'] = s.scale.toJS
    ..['lineSpacing'] = s.lineSpacing.toJS
    ..['padding'] = s.padding.toJS
    ..['align'] = s.align.name.toJS
    ..['maxRows'] = s.maxRows.toJS
    ..['keepAyahMark'] = s.keepAyahMark.toJS
    ..['ellipsisWidth'] = s.ellipsisWidth.toJS
    ..['maxStretch'] = s.maxStretch.toJS;

  QvpHit? _readHit(JSObject? res) {
    if (res == null) return null;
    final w = (res['word'] as JSNumber).toDartInt;
    return QvpHit(
      word: w == qvpNone ? -1 : w,
      path: (res['path'] as JSNumber).toDartInt,
      decoration: (res['decoration'] as JSNumber).toDartInt,
      line: (res['line'] as JSNumber).toDartInt,
      distance: (res['distance'] as JSNumber).toDartDouble,
      isExact: (res['isExact'] as JSBoolean).toDart,
    );
  }

  JSObject _zoomToJs(QvpZoom z) => JSObject()..['mode'] = z.mode.name.toJS..['step'] = z.step.toJS..['zoom'] = z.zoom.toJS;
  QvpZoom _jsToZoom(JSObject z) => QvpZoom(mode: QvpZoomMode.values.byName((z['mode'] as JSString).toDart), step: (z['step'] as JSNumber).toDartInt, zoom: (z['zoom'] as JSNumber).toDartDouble);
  JSObject _viewToJs(QvpView v) => JSObject()..['scale'] = v.scale.toJS..['offsetX'] = v.offsetX.toJS..['offsetY'] = v.offsetY.toJS;
  QvpView _jsToView(JSObject v) => QvpView(scale: (v['scale'] as JSNumber).toDartDouble, offsetX: (v['offsetX'] as JSNumber).toDartDouble, offsetY: (v['offsetY'] as JSNumber).toDartDouble);
  QvpZoomChange _jsToZoomChange(JSObject c) => QvpZoomChange(zoom: _jsToZoom(c['zoom'] as JSObject), view: _jsToView(c['view'] as JSObject), relaid: (c['relaid'] as JSBoolean).toDart);

  QvpLayout _readLayoutObject(JSObject res) {
    final lineDyJs = res['lineDy'] as JSFloat32Array?;
    final lineDy = lineDyJs != null ? lineDyJs.toDart : Float32List(0);
    final rowsNum = res['rows'] as JSNumber?;
    final rows = rowsNum != null ? rowsNum.toDartInt : 0;
    final slotsJs = res['slots'] as JSArray?;
    final slots = <(double, double)>[];
    if (slotsJs != null) {
      for (var i = 0; i < slotsJs.length; i++) {
        final s = slotsJs[i] as JSArray;
        slots.add(((s[0] as JSNumber).toDartDouble, (s[1] as JSNumber).toDartDouble));
      }
    }
    return QvpLayout(
      scale: (res['scale'] as JSNumber).toDartDouble,
      offsetX: (res['offsetX'] as JSNumber).toDartDouble,
      offsetY: (res['offsetY'] as JSNumber).toDartDouble,
      contentW: (res['contentW'] as JSNumber).toDartDouble,
      contentH: (res['contentH'] as JSNumber).toDartDouble,
      lineSpacing: (res['lineSpacing'] as JSNumber).toDartDouble,
      lineDy: lineDy,
      slots: slots,
      fitScale: (res['fitScale'] as JSNumber).toDartDouble,
      fitX: (res['fitX'] as JSNumber).toDartDouble,
      fitY: (res['fitY'] as JSNumber).toDartDouble,
      reflowed: (res['reflowed'] as JSBoolean).toDart,
      rows: rows,
    );
  }

  static JSAny? _ornamentSpecToJs(Object? v) {
    if (v == null) return null;
    if (v is int) return v.toJS;
    if (v is String) return v.toJS;
    if (v is QvpOrnament) return v.index.toJS;
    throw ArgumentError.value(v, 'ornament', 'Must be an ornament, its index or a style name');
  }

  static QvpOrnamentKind _kindFromName(String name) => switch (name) {
    'ayah_mark' => QvpOrnamentKind.ayahMark,
    'surah_header' => QvpOrnamentKind.surahHeader,
    'page_frame' => QvpOrnamentKind.pageFrame,
    _ => throw ArgumentError.value(name, 'name', 'Unknown ornament kind'),
  };

  static QvpLineage _lineageFromName(String name) => switch (name) {
    'scan' => QvpLineage.scan,
    'font' => QvpLineage.font,
    _ => throw ArgumentError.value(name, 'name', 'Unknown lineage'),
  };

  // ── Engine Info ──

  @override
  String get version => (js.callMethod<JSString>('version'.toJS)).toDart;

  @override
  int get formatVersion => (js.callMethod<JSNumber>('formatVersion'.toJS)).toDartInt;

  @override
  String get engineName => 'qvp';

  @override
  int nameCount(int table) => (js.callMethod<JSNumber>('nameCount'.toJS, table.toJS)).toDartInt;

  @override
  String name(int table, int id) => (js.callMethod<JSString>('name'.toJS, table.toJS, id.toJS)).toDart;

  @override
  int nameId(int table, String s) => (js.callMethod<JSNumber>('nameId'.toJS, table.toJS, s.toJS)).toDartInt;

  @override
  String markName(int m) => (js.callMethod<JSString>('markName'.toJS, m.toJS)).toDart;

  @override
  String familyName(int f) => (js.callMethod<JSString>('familyName'.toJS, f.toJS)).toDart;

  @override
  String kindName(int k) => (js.callMethod<JSString>('kindName'.toJS, k.toJS)).toDart;

  @override
  String categoryName(int c) => (js.callMethod<JSString>('categoryName'.toJS, c.toJS)).toDart;

  @override
  int markCategory(int m) => (js.callMethod<JSNumber>('markCategory'.toJS, m.toJS)).toDartInt;

  @override
  int markFromName(String s) => (js.callMethod<JSNumber>('markFromName'.toJS, s.toJS)).toDartInt;

  @override
  String arabic(int op, String s) => (js.callMethod<JSString>('_arabic'.toJS, op.toJS, s.toJS)).toDart;

  @override
  QvpView viewZoomAbout(QvpView view, double focalX, double focalY, double factor, {double min = 0, double max = 0}) {
    final opt = JSObject()..['min'] = min.toJS..['max'] = max.toJS;
    return _jsToView(js.callMethodVarArgs<JSObject>('viewZoomAbout'.toJS, [_viewToJs(view), focalX.toJS, focalY.toJS, factor.toJS, opt]));
  }

  @override
  void dispose() {}

  // ── Page Lifecycle ──

  @override
  (PageHandle, QvpPageData) pageLoad(Uint8List bytes) {
    final jsPage = js.callMethod<JSObject>('loadPage'.toJS, bytes.toJS);
    return (
      WebPageHandle(jsPage),
      QvpPageData(
        width: (jsPage['width'] as JSNumber).toDartDouble,
        height: (jsPage['height'] as JSNumber).toDartDouble,
        lineSpacing: (jsPage['lineSpacing'] as JSNumber).toDartDouble,
        page: (jsPage['page'] as JSNumber).toDartInt,
        nLines: (jsPage['nLines'] as JSNumber).toDartInt,
        nAyahs: (jsPage['nAyahs'] as JSNumber).toDartInt,
        nWords: (jsPage['nWords'] as JSNumber).toDartInt,
        nPaths: (jsPage['nPaths'] as JSNumber).toDartInt,
        nDecorations: (jsPage['nDecorations'] as JSNumber).toDartInt,
        ops: (jsPage['ops'] as JSUint8Array).toDart,
        pts: (jsPage['pts'] as JSFloat32Array).toDart,
        table: (jsPage['table'] as JSUint32Array).toDart,
        words: _readWords(jsPage),
        ayahs: _readAyahs(jsPage),
        lines: _readLines(jsPage),
        decorations: _readDecorations(jsPage),
      ),
    );
  }

  @override
  void pageFree(PageHandle handle) => _page(handle).callMethod('free'.toJS);

  List<QvpWordInfo> _readWords(JSObject p) {
    final arr = p['words'] as JSArray;
    return List<QvpWordInfo>.generate(arr.length, (i) {
      final w = arr[i] as JSQvpWord;
      return QvpWordInfo(index: w.index, surah: w.surah, ayah: w.ayah, word: w.word, line: w.line, ayahIndex: w.ayahIndex, lineIndex: w.lineIndex, x0: w.x0, y0: w.y0, x1: w.x1, y1: w.y1, text: w.text, firstPath: w.firstPath, nPaths: w.nPaths);
    }, growable: false);
  }

  List<QvpAyahInfo> _readAyahs(JSObject p) {
    final arr = p['ayahs'] as JSArray;
    return List<QvpAyahInfo>.generate(arr.length, (i) {
      final a = arr[i] as JSQvpAyah;
      return QvpAyahInfo(index: a.index, surah: a.surah, ayah: a.ayah, fragment: a.fragment, fragments: a.fragments, flags: a.flags, rubuAlHizb: a.rubuAlHizb, firstWord: a.firstWord, nWords: a.nWords, ayahMarkDecoration: a.ayahMarkDecoration, x0: a.x0, y0: a.y0, x1: a.x1, y1: a.y1);
    }, growable: false);
  }

  List<QvpLineInfo> _readLines(JSObject p) {
    final arr = p['lines'] as JSArray;
    return List<QvpLineInfo>.generate(arr.length, (i) {
      final l = arr[i] as JSQvpLine;
      return QvpLineInfo(index: l.index, lineNumber: l.lineNumber, isHeader: l.isHeader, firstWord: l.firstWord, nWords: l.nWords, x0: l.x0, y0: l.y0, x1: l.x1, y1: l.y1, bandY0: l.bandY0, bandY1: l.bandY1, centre: l.centre);
    }, growable: false);
  }

  List<QvpDecorationInfo> _readDecorations(JSObject p) {
    final arr = p['decorations'] as JSArray;
    return List<QvpDecorationInfo>.generate(arr.length, (i) {
      final d = arr[i] as JSQvpDecoration;
      return QvpDecorationInfo(index: d.index, decoration: d.decoration, surah: d.surah, ayah: d.ayah, line: d.line, x0: d.x0, y0: d.y0, x1: d.x1, y1: d.y1, text: d.text, firstPath: d.firstPath, nPaths: d.nPaths);
    }, growable: false);
  }

  // ── Page text & query ──

  @override
  String wordForm(PageHandle handle, int wordIndex, int form) =>
      (_page(handle).callMethod<JSString>('wordForm'.toJS, wordIndex.toJS, _formNames[form.clamp(0, _formNames.length - 1)].toJS)).toDart;

  @override
  int findWord(PageHandle handle, int surah, int ayah, int word) =>
      (_page(handle).callMethod<JSNumber>('findWord'.toJS, surah.toJS, ayah.toJS, word.toJS)).toDartInt;

  @override
  List<int> targetWords(PageHandle handle, QvpTarget target) =>
      _readIntList(_page(handle).callMethod<JSArray>('targetWords'.toJS, _targetToJs(target)));

  @override
  List<QvpSurah> surahs(PageHandle handle) {
    final arr = _page(handle).callMethod<JSArray>('surahs'.toJS);
    return List<QvpSurah>.generate(arr.length, (i) {
      final s = arr[i] as JSObject;
      return QvpSurah(
        number: (s['number'] as JSNumber).toDartInt,
        ayahCount: (s['ayahCount'] as JSNumber).toDartInt,
        hasBanner: (s['hasBanner'] as JSBoolean).toDart,
        hasBasmalah: (s['hasBasmalah'] as JSBoolean).toDart,
        place: (s['place'] as JSString).toDart,
        bannerDecoration: (s['bannerDecoration'] as JSNumber).toDartInt,
        arabic: (s['arabic'] as JSString).toDart,
        latin: (s['latin'] as JSString).toDart,
        english: (s['english'] as JSString).toDart,
      );
    }, growable: false);
  }

  @override
  List<QvpDivision> divisions(PageHandle handle) {
    final arr = _page(handle).callMethod<JSArray>('divisions'.toJS);
    return List<QvpDivision>.generate(arr.length, (i) {
      final d = arr[i] as JSObject;
      return QvpDivision(division: (d['division'] as JSString).toDart, line: (d['line'] as JSNumber).toDartInt, number: (d['number'] as JSNumber).toDartInt, surah: (d['surah'] as JSNumber).toDartInt, ayah: (d['ayah'] as JSNumber).toDartInt, ayahIndex: (d['ayahIndex'] as JSNumber).toDartInt);
    }, growable: false);
  }

  @override
  List<QvpSurahHeader> surahHeaders(PageHandle handle, {required bool view}) {
    final arr = _page(handle).callMethod<JSArray>(view ? 'surahHeadersView'.toJS : 'surahHeaders'.toJS);
    return List<QvpSurahHeader>.generate(arr.length, (i) {
      final h = arr[i] as JSObject;
      return QvpSurahHeader(decoration: (h['decoration'] as JSNumber).toDartInt, surah: (h['surah'] as JSNumber).toDartInt, line: (h['line'] as JSNumber).toDartInt, x0: (h['x0'] as JSNumber).toDartDouble, y0: (h['y0'] as JSNumber).toDartDouble, x1: (h['x1'] as JSNumber).toDartDouble, y1: (h['y1'] as JSNumber).toDartDouble, titleX0: (h['titleX0'] as JSNumber).toDartDouble, titleY0: (h['titleY0'] as JSNumber).toDartDouble, titleX1: (h['titleX1'] as JSNumber).toDartDouble, titleY1: (h['titleY1'] as JSNumber).toDartDouble);
    }, growable: false);
  }

  @override
  List<QvpAyahMark> ayahMarks(PageHandle handle) {
    final arr = _page(handle).callMethod<JSArray>('ayahMarks'.toJS);
    return List<QvpAyahMark>.generate(arr.length, (i) {
      final m = arr[i] as JSObject;
      return QvpAyahMark(decoration: (m['decoration'] as JSNumber).toDartInt, surah: (m['surah'] as JSNumber).toDartInt, ayah: (m['ayah'] as JSNumber).toDartInt, line: (m['line'] as JSNumber).toDartInt, cx: (m['cx'] as JSNumber).toDartDouble, cy: (m['cy'] as JSNumber).toDartDouble, r: (m['r'] as JSNumber).toDartDouble, ornamentPath: (m['ornamentPath'] as JSNumber).toDartInt, numeralPath: (m['numeralPath'] as JSNumber).toDartInt);
    }, growable: false);
  }

  @override
  List<QvpRosette> rosettes(PageHandle handle) {
    final arr = _page(handle).callMethod<JSArray>('rosettes'.toJS);
    return List<QvpRosette>.generate(arr.length, (i) {
      final r = arr[i] as JSObject;
      return QvpRosette(decoration: (r['decoration'] as JSNumber).toDartInt, surah: (r['surah'] as JSNumber).toDartInt, ayah: (r['ayah'] as JSNumber).toDartInt, juz: (r['juz'] as JSNumber).toDartInt, hizb: (r['hizb'] as JSNumber).toDartInt, nisf: (r['nisf'] as JSNumber).toDartInt, rubuAlHizb: (r['rubuAlHizb'] as JSNumber).toDartInt, rubuAlHizbInHizb: (r['rubuAlHizbInHizb'] as JSNumber).toDartInt);
    }, growable: false);
  }

  @override
  List<QvpSajdah> sajdahs(PageHandle handle) {
    final arr = _page(handle).callMethod<JSArray>('sajdahs'.toJS);
    return List<QvpSajdah>.generate(arr.length, (i) {
      final s = arr[i] as JSObject;
      return QvpSajdah(decoration: (s['decoration'] as JSNumber).toDartInt, surah: (s['surah'] as JSNumber).toDartInt, ayah: (s['ayah'] as JSNumber).toDartInt, signPath: (s['signPath'] as JSNumber).toDartInt);
    }, growable: false);
  }

  @override
  List<(int, int)> ayahKeys(PageHandle handle) {
    final arr = _page(handle).callMethod<JSArray>('ayahKeys'.toJS);
    return List<(int, int)>.generate(arr.length, (i) {
      final pair = arr[i] as JSArray;
      return ((pair[0] as JSNumber).toDartInt, (pair[1] as JSNumber).toDartInt);
    }, growable: false);
  }

  @override
  ({int count, bool isComplete}) ayahWordCount(PageHandle handle, int surah, int ayah) {
    final res = _page(handle).callMethod<JSObject>('ayahWordCount'.toJS, surah.toJS, ayah.toJS);
    return (count: (res['count'] as JSNumber).toDartInt, isComplete: (res['isComplete'] as JSBoolean).toDart);
  }

  @override
  List<int>? reciteMap(PageHandle handle, int surah, int ayah, int nSegments) {
    final arr = _page(handle).callMethod<JSArray?>('reciteMap'.toJS, surah.toJS, ayah.toJS, nSegments.toJS);
    return arr == null ? null : _readIntList(arr);
  }

  @override
  String wordLabel(PageHandle handle, int wordIndex) => (_page(handle).callMethod<JSString>('wordLabel'.toJS, wordIndex.toJS)).toDart;

  @override
  String ayahLabel(PageHandle handle, int ayahIndex) => (_page(handle).callMethod<JSString>('ayahLabel'.toJS, ayahIndex.toJS)).toDart;

  @override
  String text(PageHandle handle, QvpTarget target, int form, String wordSep, String lineSep) {
    final opt = JSObject()..['form'] = _formNames[form.clamp(0, _formNames.length - 1)].toJS..['wordSep'] = wordSep.toJS..['lineSep'] = lineSep.toJS;
    return (_page(handle).callMethod<JSString>('text'.toJS, _targetToJs(target), opt)).toDart;
  }

  @override
  List<QvpMatch> search(PageHandle handle, String query, {int form = 4, String mode = 'includes', bool normalize = true, bool looseMatch = true, int limit = 0}) {
    final opt = JSObject()..['form'] = _formNames[form.clamp(0, _formNames.length - 1)].toJS..['mode'] = mode.toJS..['normalize'] = normalize.toJS..['looseMatch'] = looseMatch.toJS..['limit'] = limit.toJS;
    final arr = _page(handle).callMethod<JSArray>('search'.toJS, query.toJS, opt);
    return List<QvpMatch>.generate(arr.length, (i) {
      final m = arr[i] as JSObject;
      return QvpMatch(word: (m['word'] as JSNumber).toDartInt, index: (m['index'] as JSNumber).toDartInt, isLooseMatch: (m['isLooseMatch'] as JSBoolean).toDart, wordKey: (m['wordKey'] as JSString).toDart, text: (m['text'] as JSString).toDart);
    }, growable: false);
  }

  @override
  String citation(PageHandle handle, List<int> words) =>
      (_page(handle).callMethod<JSString>('citation'.toJS, Uint32List.fromList(words).toJS)).toDart;

  @override
  int attachWords(PageHandle handle, List<int> bytes) =>
      (_page(handle).callMethod<JSNumber>('attachWords'.toJS, Uint8List.fromList(bytes).toJS)).toDartInt;

  @override
  bool hasForm(PageHandle handle, int form) =>
      (_page(handle).callMethod<JSBoolean>('hasForm'.toJS, _formNames[form.clamp(0, _formNames.length - 1)].toJS)).toDart;

  // ── Hit Testing ──

  @override
  QvpHit? hitTestExact(PageHandle handle, double x, double y) =>
      _readHit(_page(handle).callMethod<JSObject?>('hitTestExact'.toJS, x.toJS, y.toJS));

  @override
  QvpHit? hitTestExactView(PageHandle handle, double viewX, double viewY) =>
      _readHit(_page(handle).callMethod<JSObject?>('hitTestExactView'.toJS, viewX.toJS, viewY.toJS));

  @override
  QvpHit? hitTest(PageHandle handle, double x, double y, QvpHitOptions options) {
    final opt = JSObject()..['maxDistance'] = options.maxDistance.toJS..['gapBias'] = options.gapBias.toJS..['preferExact'] = options.preferExact.toJS;
    return _readHit(_page(handle).callMethod<JSObject?>('hitTest'.toJS, x.toJS, y.toJS, opt));
  }

  @override
  QvpHit? hitTestView(PageHandle handle, double viewX, double viewY, QvpHitOptions options) {
    final opt = JSObject()..['maxDistance'] = options.maxDistance.toJS..['gapBias'] = options.gapBias.toJS..['preferExact'] = options.preferExact.toJS;
    return _readHit(_page(handle).callMethod<JSObject?>('hitTestView'.toJS, viewX.toJS, viewY.toJS, opt));
  }

  @override
  List<QvpLineBand> lineBands(PageHandle handle) {
    final arr = _page(handle).callMethod<JSArray>('lineBands'.toJS);
    return List<QvpLineBand>.generate(arr.length, (i) {
      final b = arr[i] as JSObject;
      return QvpLineBand(line: (b['line'] as JSNumber).toDartInt, lineNumber: (b['lineNumber'] as JSNumber).toDartInt, y0: (b['y0'] as JSNumber).toDartDouble, y1: (b['y1'] as JSNumber).toDartDouble, mid: (b['mid'] as JSNumber).toDartDouble, inkY0: (b['inkY0'] as JSNumber).toDartDouble, inkY1: (b['inkY1'] as JSNumber).toDartDouble);
    }, growable: false);
  }

  @override
  List<QvpHitArea> hitAreas(PageHandle handle, double gapBias) {
    final arr = _page(handle).callMethod<JSArray>('hitAreas'.toJS, gapBias.toJS);
    return List<QvpHitArea>.generate(arr.length, (i) {
      final a = arr[i] as JSObject;
      return QvpHitArea(word: (a['word'] as JSNumber).toDartInt, line: (a['line'] as JSNumber).toDartInt, x0: (a['x0'] as JSNumber).toDartDouble, y0: (a['y0'] as JSNumber).toDartDouble, x1: (a['x1'] as JSNumber).toDartDouble, y1: (a['y1'] as JSNumber).toDartDouble, inkX0: (a['inkX0'] as JSNumber).toDartDouble, inkY0: (a['inkY0'] as JSNumber).toDartDouble, inkX1: (a['inkX1'] as JSNumber).toDartDouble, inkY1: (a['inkY1'] as JSNumber).toDartDouble);
    }, growable: false);
  }

  // ── Layout & Zoom ──

  @override
  QvpLayout layout(PageHandle handle, QvpLayoutSpec spec) =>
      _readLayoutObject(_page(handle).callMethod<JSObject>('layout'.toJS, _specToJs(spec)));

  @override
  QvpZoomChange zoomPinch(PageHandle handle, QvpLayoutSpec spec, QvpZoom zoom, QvpView view, double factor, double focalX, double focalY) =>
      _jsToZoomChange(_page(handle).callMethodVarArgs<JSObject>('zoomPinch'.toJS, [_specToJs(spec), _zoomToJs(zoom), _viewToJs(view), factor.toJS, focalX.toJS, focalY.toJS]));

  @override
  QvpZoomChange zoomToStep(PageHandle handle, QvpLayoutSpec spec, QvpZoom zoom, int step, QvpView view) =>
      _jsToZoomChange(_page(handle).callMethodVarArgs<JSObject>('zoomToStep'.toJS, [_specToJs(spec), _zoomToJs(zoom), step.toJS, _viewToJs(view)]));

  @override
  QvpZoom zoomMode(PageHandle handle, QvpLayoutSpec spec, QvpZoom zoom, QvpZoomMode mode) =>
      _jsToZoom(_page(handle).callMethod<JSObject>('zoomMode'.toJS, _specToJs(spec), _zoomToJs(zoom), mode.name.toJS));

  @override
  QvpLayoutSpec zoomSpec(PageHandle handle, QvpLayoutSpec spec, QvpZoom zoom) {
    final s = _page(handle).callMethod<JSObject>('zoomSpec'.toJS, _specToJs(spec), _zoomToJs(zoom));
    final r = s['reflow'] as JSObject?;
    final knobs = spec.reflow ?? const QvpReflowSpec();
    final zNum = r != null ? (r['zoom'] as JSNumber?)?.toDartDouble ?? 0.0 : 0.0;
    final zoomed = zNum > 1.0001;
    return spec.copyWith(reflow: zoomed || spec.reflow != null ? knobs.copyWith(zoom: zoomed ? zNum : 0) : null);
  }

  @override
  QvpZoom zoomCarried(PageHandle handle, QvpLayoutSpec spec, QvpZoom zoom) =>
      _jsToZoom(_page(handle).callMethod<JSObject>('zoomCarried'.toJS, _specToJs(spec), _zoomToJs(zoom)));

  @override
  double zoomAtStep(PageHandle handle, QvpLayoutSpec spec, int step) =>
      (_page(handle).callMethod<JSNumber>('zoomAtStep'.toJS, _specToJs(spec), step.toJS)).toDartDouble;

  @override
  Float32List zoomSteps(PageHandle handle, QvpLayoutSpec spec) {
    final arr = _page(handle).callMethod<JSArray>('zoomSteps'.toJS, _specToJs(spec));
    final list = Float32List(arr.length);
    for (var i = 0; i < arr.length; i++) {
      list[i] = (arr[i] as JSNumber).toDartDouble;
    }
    return list;
  }

  @override
  double reflowMaxZoom(PageHandle handle, QvpLayoutSpec spec) =>
      (_page(handle).callMethod<JSNumber>('reflowMaxZoom'.toJS, _specToJs(spec))).toDartDouble;

  @override
  bool isZoomed(QvpZoom zoom, QvpView view, double fitScale) =>
      (js.callMethod<JSBoolean>('zoomIsZoomed'.toJS, _zoomToJs(zoom), _viewToJs(view), fitScale.toJS)).toDart;

  @override
  QvpSideways sidewaysDrag(PageHandle handle, QvpZoom zoom, QvpView view, double fitScale) {
    final res = (_page(handle).callMethod<JSString>('sidewaysDrag'.toJS, _zoomToJs(zoom), _viewToJs(view), fitScale.toJS)).toDart;
    return res == 'turnPage' ? QvpSideways.turnPage : QvpSideways.pan;
  }

  @override
  List<QvpDraw> layoutDrawList(PageHandle handle, {double bandTop = 0, double bandBottom = 0}) {
    final list = (_page(handle).callMethod<JSUint32Array>('layoutDrawList'.toJS, bandTop.toJS, bandBottom.toJS)).toDart;
    final n = list.length ~/ 2;
    return List<QvpDraw>.generate(n, (i) => QvpDraw(list[i * 2], list[i * 2 + 1]), growable: false);
  }

  @override
  List<QvpPlacement> layoutPlacements(PageHandle handle) {
    final list = (_page(handle).callMethod<JSFloat32Array>('layoutPlacements'.toJS)).toDart;
    final n = list.length ~/ 4;
    return List<QvpPlacement>.generate(n, (i) => QvpPlacement(list[i * 4], list[i * 4 + 1], list[i * 4 + 2], list[i * 4 + 3]), growable: false);
  }

  @override
  QvpLayout? readLayout(PageHandle handle) {
    final cur = _page(handle)['currentLayout'] as JSObject?;
    return cur != null ? _readLayoutObject(cur) : null;
  }

  @override
  int? layoutWordRow(PageHandle handle, int word) =>
      (_page(handle).callMethod<JSNumber?>('layoutWordRow'.toJS, word.toJS))?.toDartInt;

  @override
  Uint32List layoutRowWords(PageHandle handle, int row) =>
      (_page(handle).callMethod<JSUint32Array>('layoutRowWords'.toJS, row.toJS)).toDart;

  @override
  ({int lines, double lineSpacing}) pageGrid(PageHandle handle) {
    final g = _page(handle)['grid'] as JSObject;
    return (lines: (g['lines'] as JSNumber).toDartInt, lineSpacing: (g['lineSpacing'] as JSNumber).toDartDouble);
  }

  @override
  double layoutWastedFraction(PageHandle handle, QvpLayoutSpec spec) =>
      (_page(handle).callMethod<JSNumber>('layoutWastedFraction'.toJS, _specToJs(spec))).toDartDouble;

  @override
  double layoutPrintedHeight(PageHandle handle, QvpLayoutSpec spec) =>
      (_page(handle).callMethod<JSNumber>('layoutPrintedHeight'.toJS, _specToJs(spec))).toDartDouble;

  @override
  double layoutLineSpacingToFill(PageHandle handle, QvpLayoutSpec spec, double max) =>
      (_page(handle).callMethod<JSNumber>('layoutLineSpacingToFill'.toJS, _specToJs(spec), max.toJS)).toDartDouble;

  @override
  ({double x0, double y0, double x1, double y1}) wordBoundsView(PageHandle handle, int wordIndex) {
    final res = _page(handle).callMethod<JSObject>('wordBoundsView'.toJS, wordIndex.toJS);
    return (x0: (res['x0'] as JSNumber).toDartDouble, y0: (res['y0'] as JSNumber).toDartDouble, x1: (res['x1'] as JSNumber).toDartDouble, y1: (res['y1'] as JSNumber).toDartDouble);
  }

  // ── Page Styling & Themes ──

  @override
  int style(PageHandle handle, QvpSelector sel, int color, {int ms = 0, int layer = 0}) {
    final opt = JSObject()..['ms'] = ms.toJS..['layer'] = layer.toJS;
    return (_page(handle).callMethod<JSNumber>('style'.toJS, _selToJs(sel), color.toJS, opt)).toDartInt;
  }

  @override
  int styleTarget(PageHandle handle, QvpTarget target, int color, {int ms = 0, int layer = 0}) {
    final opt = JSObject()..['ms'] = ms.toJS..['layer'] = layer.toJS;
    return (_page(handle).callMethod<JSNumber>('styleTarget'.toJS, _targetToJs(target), color.toJS, opt)).toDartInt;
  }

  @override
  int removeStyle(PageHandle handle, int styleHandle) =>
      (_page(handle).callMethod<JSNumber>('removeStyle'.toJS, styleHandle.toJS)).toDartInt;

  @override
  int recolorStyle(PageHandle handle, int styleHandle, int color, int ms) =>
      (_page(handle).callMethod<JSNumber>('recolorStyle'.toJS, styleHandle.toJS, color.toJS, ms.toJS)).toDartInt;

  @override
  int hide(PageHandle handle, QvpSelector sel) =>
      (_page(handle).callMethod<JSNumber>('hide'.toJS, _selToJs(sel))).toDartInt;

  @override
  void clearStyles(PageHandle handle) => _page(handle).callMethod('clearStyles'.toJS);

  @override
  void clearLayer(PageHandle handle, int layer) => _page(handle).callMethod('clearLayer'.toJS, layer.toJS);

  @override
  void setDefaultColor(PageHandle handle, int color) =>
      _page(handle).callMethod('setDefaultColor'.toJS, color.toJS);

  @override
  int theme(PageHandle handle, QvpTheme t) {
    final marksObj = JSObject();
    for (final e in t.marks.entries) {
      marksObj[e.key.toString()] = rgba(e.value).toJS;
    }
    final obj = JSObject()
      ..['ink'] = (t.ink == null ? 0 : rgba(t.ink!)).toJS
      ..['diacritics'] = (t.diacritics == null ? 0 : rgba(t.diacritics!)).toJS
      ..['dots'] = (t.dots == null ? 0 : rgba(t.dots!)).toJS
      ..['waqf'] = (t.waqf == null ? 0 : rgba(t.waqf!)).toJS
      ..['sifr'] = (t.sifr == null ? 0 : rgba(t.sifr!)).toJS
      ..['ayahMark'] = (t.ayahMark == null ? 0 : rgba(t.ayahMark!)).toJS
      ..['numeral'] = (t.numeral == null ? 0 : rgba(t.numeral!)).toJS
      ..['headers'] = (t.headers == null ? 0 : rgba(t.headers!)).toJS
      ..['ms'] = t.ms.toJS
      ..['marks'] = marksObj;
    return (_page(handle).callMethod<JSNumber>('theme'.toJS, obj)).toDartInt;
  }

  @override
  List<int> styleHandles(PageHandle handle) =>
      _readIntList(_page(handle).callMethod<JSArray>('styleHandles'.toJS));

  // ── Clock & Display List ──

  @override
  bool tick(PageHandle handle, double nowMs) =>
      (_page(handle).callMethod<JSBoolean>('tick'.toJS, nowMs.toJS)).toDart;

  @override
  Uint32List colors(PageHandle handle, int nPaths) =>
      (_page(handle).callMethod<JSUint32Array>('colors'.toJS)).toDart;

  @override
  List<QvpStyledPath> styledPaths(PageHandle handle) {
    final arr = _page(handle).callMethod<JSArray>('styledPaths'.toJS);
    return List<QvpStyledPath>.generate(arr.length, (i) {
      final pair = arr[i] as JSArray;
      return (path: (pair[0] as JSNumber).toDartInt, color: (pair[1] as JSNumber).toDartInt);
    }, growable: false);
  }

  @override
  int colorOf(PageHandle handle, int path) =>
      (_page(handle).callMethod<JSNumber>('colorOf'.toJS, path.toJS)).toDartInt;

  // ── Highlights ──

  @override
  int highlight(PageHandle handle, QvpTarget target, QvpHighlightStyle style) =>
      (_page(handle).callMethod<JSNumber>('highlight'.toJS, _targetToJs(target), _hlToJs(style))).toDartInt;

  @override
  bool moveHighlight(PageHandle handle, int highlightHandle, QvpTarget target) =>
      (_page(handle).callMethod<JSBoolean>('moveHighlight'.toJS, highlightHandle.toJS, _targetToJs(target))).toDart;

  @override
  bool restyleHighlight(PageHandle handle, int highlightHandle, QvpHighlightStyle style) =>
      (_page(handle).callMethod<JSBoolean>('restyleHighlight'.toJS, highlightHandle.toJS, _hlToJs(style))).toDart;

  @override
  bool removeHighlight(PageHandle handle, int highlightHandle) =>
      (_page(handle).callMethod<JSBoolean>('removeHighlight'.toJS, highlightHandle.toJS)).toDart;

  @override
  void clearHighlights(PageHandle handle) => _page(handle).callMethod('clearHighlights'.toJS);

  @override
  List<int> highlightHandles(PageHandle handle) =>
      _readIntList(_page(handle).callMethod<JSArray>('highlightHandles'.toJS));

  @override
  List<int> highlightWords(PageHandle handle, int highlightHandle) =>
      _readIntList(_page(handle).callMethod<JSArray>('highlightWords'.toJS, highlightHandle.toJS));

  @override
  List<QvpBox> highlightBoxesView(PageHandle handle) =>
      _readBoxes(_page(handle).callMethod<JSArray>('highlightBoxesView'.toJS));

  @override
  List<QvpBox> wordBands(PageHandle handle, List<int> ws, {required bool inkHeight, required double padX, required double padY}) {
    final opt = JSObject()..['height'] = (inkHeight ? 'ink' : 'lineSpacing').toJS..['padX'] = padX.toJS..['padY'] = padY.toJS;
    return _readBoxes(_page(handle).callMethod<JSArray>('wordBands'.toJS, Uint32List.fromList(ws).toJS, opt));
  }

  // ── Selection ──

  @override
  void select(PageHandle handle, int anchor, int focus) =>
      _page(handle).callMethod('select'.toJS, anchor.toJS, focus.toJS);

  @override
  List<int> selection(PageHandle handle) =>
      _readIntList(_page(handle).callMethod<JSArray>('selection'.toJS));

  @override
  String selectionText(PageHandle handle, int form, bool includeCitation) =>
      (_page(handle).callMethod<JSString>('selectionText'.toJS, _formNames[form.clamp(0, _formNames.length - 1)].toJS, includeCitation.toJS)).toDart;

  // ── Masks & Memorisation ──

  @override
  void mask(PageHandle handle, QvpTarget target, int mode) =>
      _page(handle).callMethod('mask'.toJS, _targetToJs(target), _maskModeNames[mode.clamp(0, 2)].toJS);

  @override
  void maskFrom(PageHandle handle, int wordIndex, int mode) =>
      _page(handle).callMethod('maskFrom'.toJS, wordIndex.toJS, _maskModeNames[mode.clamp(0, 2)].toJS);

  @override
  void maskOptions(PageHandle handle, int blockColor, double padX, double padY, double radius, bool reverse) {
    final opt = JSObject()..['blockColor'] = blockColor.toJS..['padX'] = padX.toJS..['padY'] = padY.toJS..['radius'] = radius.toJS..['reverse'] = reverse.toJS;
    _page(handle).callMethod('maskOptions'.toJS, opt);
  }

  @override
  int unmaskNext(PageHandle handle, int n) =>
      (_page(handle).callMethod<JSNumber>('unmaskNext'.toJS, n.toJS)).toDartInt;

  @override
  int maskBack(PageHandle handle, int n) =>
      (_page(handle).callMethod<JSNumber>('maskBack'.toJS, n.toJS)).toDartInt;

  @override
  bool unmaskWord(PageHandle handle, int wordIndex) =>
      (_page(handle).callMethod<JSBoolean>('unmaskWord'.toJS, wordIndex.toJS)).toDart;

  @override
  bool maskWord(PageHandle handle, int wordIndex) =>
      (_page(handle).callMethod<JSBoolean>('maskWord'.toJS, wordIndex.toJS)).toDart;

  @override
  void unmaskAll(PageHandle handle) => _page(handle).callMethod('unmaskAll'.toJS);

  @override
  void maskAll(PageHandle handle) => _page(handle).callMethod('maskAll'.toJS);

  @override
  void unmask(PageHandle handle) => _page(handle).callMethod('unmask'.toJS);

  @override
  List<int> maskHidden(PageHandle handle) =>
      _readIntList(_page(handle).callMethod<JSArray>('maskHidden'.toJS));

  @override
  List<int> maskWords(PageHandle handle) =>
      _readIntList(_page(handle).callMethod<JSArray>('maskWords'.toJS));

  @override
  List<QvpBox> maskBoxesView(PageHandle handle) =>
      _readBoxes(_page(handle).callMethod<JSArray>('maskBoxesView'.toJS));

  // ── Reveal ──

  @override
  int revealStart(PageHandle handle, {required int lit, required bool byAyah, required int grey, required int ink, required bool ayahMarks, required int ms}) {
    final opt = JSObject()..['lit'] = lit.toJS..['byAyah'] = byAyah.toJS..['grey'] = grey.toJS..['ink'] = ink.toJS..['ayahMarks'] = ayahMarks.toJS..['ms'] = ms.toJS;
    return (_page(handle).callMethod<JSNumber>('revealStart'.toJS, opt)).toDartInt;
  }

  @override
  bool revealGoto(PageHandle handle, int at) =>
      (_page(handle).callMethod<JSBoolean>('revealGoto'.toJS, at.toJS)).toDart;

  @override
  int? revealPosition(PageHandle handle) =>
      (_page(handle).callMethod<JSNumber?>('revealPosition'.toJS))?.toDartInt;

  @override
  int revealStepCount(PageHandle handle) =>
      (_page(handle).callMethod<JSNumber>('revealStepCount'.toJS)).toDartInt;

  @override
  int revealStepOf(PageHandle handle, int wordIndex) =>
      (_page(handle).callMethod<JSNumber>('revealStepOf'.toJS, wordIndex.toJS)).toDartInt;

  @override
  void revealStop(PageHandle handle) => _page(handle).callMethod('revealStop'.toJS);

  // ── Dress ──

  @override
  bool dress(PageHandle page, OrnamentsHandle set, QvpDressSpec spec) {
    final lineArtJs = [for (final k in spec.lineArt) (switch (k) { QvpOrnamentKind.ayahMark => 'ayah_mark', QvpOrnamentKind.surahHeader => 'surah_header', QvpOrnamentKind.pageFrame => 'page_frame' }).toJS].toJS;
    final opt = JSObject()..['gap'] = spec.gap.toJS..['bandGap'] = spec.bandGap.toJS..['ayahMarkScale'] = spec.ayahMarkScale.toJS..['pageFrameScale'] = spec.pageFrameScale.toJS..['lineArt'] = lineArtJs;
    if (spec.style != null) opt['style'] = spec.style!.toJS;
    final ayahVal = _ornamentSpecToJs(spec.ayahMark);
    if (ayahVal != null) opt['ayahMark'] = ayahVal;
    final headerVal = _ornamentSpecToJs(spec.surahHeader);
    if (headerVal != null) opt['surahHeader'] = headerVal;
    final frameVal = _ornamentSpecToJs(spec.pageFrame);
    if (frameVal != null) opt['pageFrame'] = frameVal;
    if (spec.colors.isNotEmpty) {
      opt['colors'] = [for (final (o, part, col) in spec.colors) [_ornamentSpecToJs(o) ?? 0.toJS, part.toJS, rgba(col).toJS].toJS].toJS;
    }
    return _page(page).callMethod<JSObject?>('dress'.toJS, _ornaments(set), opt) != null;
  }

  @override
  void undress(PageHandle page) => _page(page).callMethod('undress'.toJS);

  @override
  QvpView dressClamp(PageHandle page, QvpView view, double viewportW, double viewportH) =>
      _jsToView(_page(page).callMethod<JSObject>('dressClamp'.toJS, _viewToJs(view), viewportW.toJS, viewportH.toJS));

  @override
  QvpDressView dressView(PageHandle page, double scale, double viewportW) {
    final res = _page(page).callMethod<JSObject>('dressView'.toJS, scale.toJS, viewportW.toJS);
    return QvpDressView(view: _jsToView(res['view'] as JSObject), width: (res['width'] as JSNumber).toDartDouble, height: (res['height'] as JSNumber).toDartDouble);
  }

  @override
  QvpDressInfo? dressInfo(PageHandle page) {
    final info = _page(page).callMethod<JSObject?>('dressInfo'.toJS);
    if (info == null) return null;
    final vb = info['viewBox'] as JSArray;
    final of = info['overflow'] as JSArray;
    return QvpDressInfo(
      ayahMark: (info['ayahMark'] as JSNumber?)?.toDartInt,
      surahHeader: (info['surahHeader'] as JSNumber?)?.toDartInt,
      pageFrame: (info['pageFrame'] as JSNumber?)?.toDartInt,
      ayahMarks: (info['ayahMarks'] as JSNumber).toDartInt,
      surahHeaders: (info['surahHeaders'] as JSNumber).toDartInt,
      frameRepeats: (info['frameRepeats'] as JSNumber).toDartInt,
      frameStretched: (info['frameStretched'] as JSBoolean).toDart,
      draws: (info['draws'] as JSNumber).toDartInt,
      revision: (info['revision'] as JSNumber).toDartInt,
      viewBox: [(vb[0] as JSNumber).toDartDouble, (vb[1] as JSNumber).toDartDouble, (vb[2] as JSNumber).toDartDouble, (vb[3] as JSNumber).toDartDouble],
      overflow: [(of[0] as JSNumber).toDartDouble, (of[1] as JSNumber).toDartDouble, (of[2] as JSNumber).toDartDouble, (of[3] as JSNumber).toDartDouble],
    );
  }

  @override
  List<QvpDressDraw> dressGeometry(PageHandle page) {
    final p = _page(page);
    final engine = p['e'] as JSObject;
    final ex = engine['ex'] as JSObject;
    final scratch = (engine['scratch'] as JSNumber).toDartInt;
    final h = (p['h'] as JSNumber).toDartInt;
    ex.callMethod('qvp_dress_geometry'.toJS, h.toJS, scratch.toJS);

    final dv = engine.callMethod<JSObject>('dv'.toJS);
    final n = (dv.callMethod<JSNumber>('getUint32'.toJS, (scratch + 20).toJS, true.toJS)).toDartInt;
    if (n == 0) return const [];

    final opsPtr = (dv.callMethod<JSNumber>('getUint32'.toJS, scratch.toJS, true.toJS)).toDartInt;
    final opsLen = (dv.callMethod<JSNumber>('getUint32'.toJS, (scratch + 4).toJS, true.toJS)).toDartInt;
    final ptsPtr = (dv.callMethod<JSNumber>('getUint32'.toJS, (scratch + 8).toJS, true.toJS)).toDartInt;
    final ptsLen = (dv.callMethod<JSNumber>('getUint32'.toJS, (scratch + 12).toJS, true.toJS)).toDartInt;
    final tabPtr = (dv.callMethod<JSNumber>('getUint32'.toJS, (scratch + 16).toJS, true.toJS)).toDartInt;

    final mem = engine['mem'] as JSObject;
    final buffer = mem['buffer'] as JSArrayBuffer;
    final u8Class = globalContext['Uint8Array'] as JSFunction;
    final f32Class = globalContext['Float32Array'] as JSFunction;
    final u32Class = globalContext['Uint32Array'] as JSFunction;

    final opsArr = (u8Class.callAsConstructor<JSUint8Array>(buffer, opsPtr.toJS, opsLen.toJS)).toDart;
    final ptsArr = (f32Class.callAsConstructor<JSFloat32Array>(buffer, ptsPtr.toJS, ptsLen.toJS)).toDart;
    final tabArr = (u32Class.callAsConstructor<JSUint32Array>(buffer, tabPtr.toJS, (n * 9).toJS)).toDart;
    final tf = tabArr.buffer.asFloat32List(tabArr.offsetInBytes, n * 9);

    return List<QvpDressDraw>.generate(n, (i) {
      final off = i * 9;
      final flags = tabArr[off + 5];
      final placement = tabArr[off + 8];
      final evenOdd = flags & 0x100 != 0;
      final path = Path()..fillType = evenOdd ? PathFillType.evenOdd : PathFillType.nonZero;
      decodeQvpPath(path, opsArr, tabArr[off], tabArr[off + 1], ptsArr, tabArr[off + 2]);
      return QvpDressDraw(
        path: path,
        color: tabArr[off + 4],
        kind: QvpOrnamentKind.values[(flags & 0xff).clamp(0, 2)],
        evenOdd: evenOdd,
        stroke: flags & 0x200 != 0,
        strokeWidth: tf[off + 6],
        part: tabArr[off + 7],
        placement: placement == qvpNone ? null : placement,
      );
    }, growable: false);
  }

  // ── Crop ──

  @override
  QvpCropBounds? cropBounds(PageHandle handle, QvpTarget target, {required double pad, required bool keepAyahMarks}) {
    final opt = JSObject()..['pad'] = pad.toJS..['keepAyahMarks'] = keepAyahMarks.toJS;
    final res = _page(handle).callMethod<JSObject?>('cropBounds'.toJS, _targetToJs(target), opt);
    return res == null ? null : QvpCropBounds(x0: (res['x0'] as JSNumber).toDartDouble, y0: (res['y0'] as JSNumber).toDartDouble, x1: (res['x1'] as JSNumber).toDartDouble, y1: (res['y1'] as JSNumber).toDartDouble, nWords: (res['nWords'] as JSNumber).toDartInt, ayahMarkDecoration: (res['ayahMarkDecoration'] as JSNumber).toDartInt);
  }

  @override
  String? cropSvg(PageHandle handle, QvpTarget target, {required double pad, required bool keepAyahMarks, int? background}) {
    final opt = JSObject()..['pad'] = pad.toJS..['keepAyahMarks'] = keepAyahMarks.toJS;
    if (background != null) opt['background'] = background.toJS;
    return (_page(handle).callMethod<JSString?>('cropSvg'.toJS, _targetToJs(target), opt))?.toDart;
  }

  // ── Atlas ──

  @override
  (AtlasHandle, int pageCount) atlasLoad(Uint8List bytes) {
    final jsAtlas = js.callMethod<JSObject>('loadAtlas'.toJS, bytes.toJS);
    return (WebAtlasHandle(jsAtlas), (jsAtlas.callMethod<JSNumber>('pageCount'.toJS)).toDartInt);
  }

  @override
  void atlasFree(AtlasHandle handle) => _atlas(handle).callMethod('free'.toJS);

  @override
  int? atlasPageOf(AtlasHandle handle, int surah, int ayah) {
    final res = _atlas(handle).callMethod<JSNumber?>('pageOf'.toJS, surah.toJS, ayah.toJS);
    if (res == null) return null;
    final p = res.toDartInt;
    return p <= 0 ? null : p;
  }

  @override
  ({(int, int) first, (int, int) last})? atlasPageRange(AtlasHandle handle, int page) {
    final res = _atlas(handle).callMethod<JSObject?>('pageRange'.toJS, page.toJS);
    if (res == null) return null;
    final first = res['first'] as JSArray;
    final last = res['last'] as JSArray;
    return (first: ((first[0] as JSNumber).toDartInt, (first[1] as JSNumber).toDartInt), last: ((last[0] as JSNumber).toDartInt, (last[1] as JSNumber).toDartInt));
  }

  QvpAtlasSurah _readAtlasSurah(JSObject s) => QvpAtlasSurah(
    number: (s['number'] as JSNumber).toDartInt,
    page: (s['page'] as JSNumber).toDartInt,
    ayahCount: (s['ayahCount'] as JSNumber).toDartInt,
    place: (s['place'] as JSString).toDart,
    arabic: (s['arabic'] as JSString).toDart,
    latin: (s['latin'] as JSString).toDart,
    english: (s['english'] as JSString).toDart,
  );

  @override
  QvpAtlasSurah? atlasSurah(AtlasHandle handle, int n) {
    final res = _atlas(handle).callMethod<JSObject?>('surah'.toJS, n.toJS);
    return res != null ? _readAtlasSurah(res) : null;
  }

  @override
  List<QvpAtlasSurah> atlasSurahs(AtlasHandle handle) {
    final arr = _atlas(handle).callMethod<JSArray>('surahs'.toJS);
    return List<QvpAtlasSurah>.generate(arr.length, (i) => _readAtlasSurah(arr[i] as JSObject), growable: false);
  }

  @override
  QvpAtlasRubuAlHizb? atlasDivision(AtlasHandle handle, int division, int n) {
    final res = _atlas(handle).callMethod<JSObject?>('division'.toJS, (_divKindNames[division] ?? 'rubu_al_hizb').toJS, n.toJS);
    return res == null ? null : QvpAtlasRubuAlHizb(rubuAlHizb: (res['rubuAlHizb'] as JSNumber).toDartInt, surah: (res['surah'] as JSNumber).toDartInt, ayah: (res['ayah'] as JSNumber).toDartInt, page: (res['page'] as JSNumber).toDartInt);
  }

  @override
  int? atlasDivisionOf(AtlasHandle handle, int division, int surah, int ayah) =>
      (_atlas(handle).callMethod<JSNumber?>('divisionOf'.toJS, (_divKindNames[division] ?? 'rubu_al_hizb').toJS, surah.toJS, ayah.toJS))?.toDartInt;

  @override
  List<int>? atlasPagesOfJuz(AtlasHandle handle, int n) {
    final arr = _atlas(handle).callMethod<JSArray?>('pagesOfJuz'.toJS, n.toJS);
    return arr == null ? null : [(arr[0] as JSNumber).toDartInt, (arr[1] as JSNumber).toDartInt];
  }

  @override
  List<int> atlasSearchSurahs(AtlasHandle handle, String text) {
    final arr = _atlas(handle).callMethod<JSArray>('searchSurahs'.toJS, text.toJS);
    return List<int>.generate(arr.length, (i) => ((arr[i] as JSObject)['number'] as JSNumber).toDartInt, growable: false);
  }

  @override
  String atlasJson(AtlasHandle handle) => (_atlas(handle).callMethod<JSString>('json'.toJS)).toDart;

  // ── Passage ──

  (PassageHandle, List<QvpPassageText> ayahs, double lineSpacing) _readPassage(JSObject jsPassage) {
    final arr = jsPassage['ayahs'] as JSArray;
    final ayahs = List<QvpPassageText>.generate(arr.length, (i) {
      final a = arr[i] as JSObject;
      return QvpPassageText(surah: (a['surah'] as JSNumber).toDartInt, ayah: (a['ayah'] as JSNumber).toDartInt, text: (a['text'] as JSString).toDart);
    }, growable: false);
    return (WebPassageHandle(jsPassage), ayahs, (jsPassage['lineSpacing'] as JSNumber).toDartDouble);
  }

  @override
  (PassageHandle, List<QvpPassageText> ayahs, double lineSpacing) passageLoad(List<PageHandle> pages, int surah, int from, int to) =>
      _readPassage(js.callMethod<JSObject>('loadPassage'.toJS, [for (final p in pages) _page(p)].toJS, surah.toJS, from.toJS, to.toJS));

  @override
  (PassageHandle, List<QvpPassageText> ayahs, double lineSpacing) passageLoadBasmalah(List<PageHandle> pages, int surah) =>
      _readPassage(js.callMethod<JSObject>('loadBasmalah'.toJS, [for (final p in pages) _page(p)].toJS, surah.toJS));

  @override
  void passageFree(PassageHandle handle) => _passage(handle).callMethod('free'.toJS);

  @override
  QvpPassageLayout? passageLayout(PassageHandle handle, QvpPassageSpec spec) {
    final res = _passage(handle).callMethod<JSObject?>('layout'.toJS, _passageSpecToJs(spec));
    if (res == null) return null;
    final rowsJs = res['rows'] as JSArray;
    final rows = List<QvpPassageRow>.generate(rowsJs.length, (i) {
      final r = rowsJs[i] as JSObject;
      return QvpPassageRow(x0: (r['x0'] as JSNumber).toDartDouble, y0: (r['y0'] as JSNumber).toDartDouble, x1: (r['x1'] as JSNumber).toDartDouble, y1: (r['y1'] as JSNumber).toDartDouble, baseline: (r['baseline'] as JSNumber).toDartDouble);
    }, growable: false);

    final wordsJs = res['words'] as JSArray;
    final words = List<QvpPassageWord>.generate(wordsJs.length, (i) {
      final w = wordsJs[i] as JSObject;
      return QvpPassageWord(surah: (w['surah'] as JSNumber).toDartInt, ayah: (w['ayah'] as JSNumber).toDartInt, word: (w['word'] as JSNumber).toDartInt, page: (w['page'] as JSNumber).toDartInt, row: (w['row'] as JSNumber).toDartInt, x0: (w['x0'] as JSNumber).toDartDouble, y0: (w['y0'] as JSNumber).toDartDouble, x1: (w['x1'] as JSNumber).toDartDouble, y1: (w['y1'] as JSNumber).toDartDouble, wordX0: (w['wordX0'] as JSNumber).toDartDouble, wordY0: (w['wordY0'] as JSNumber).toDartDouble, wordX1: (w['wordX1'] as JSNumber).toDartDouble, wordY1: (w['wordY1'] as JSNumber).toDartDouble);
    }, growable: false);

    final ayahsJs = res['ayahs'] as JSArray;
    final ayahs = List<QvpPassageAyah>.generate(ayahsJs.length, (i) {
      final a = ayahsJs[i] as JSObject;
      return QvpPassageAyah(surah: (a['surah'] as JSNumber).toDartInt, ayah: (a['ayah'] as JSNumber).toDartInt, x0: (a['x0'] as JSNumber).toDartDouble, y0: (a['y0'] as JSNumber).toDartDouble, x1: (a['x1'] as JSNumber).toDartDouble, y1: (a['y1'] as JSNumber).toDartDouble);
    }, growable: false);

    final drawsJs = res['draws'] as JSArray;
    final draws = List<QvpPassageDraw>.generate(drawsJs.length, (i) {
      final d = drawsJs[i] as JSObject;
      return QvpPassageDraw((d['page'] as JSNumber).toDartInt, (d['path'] as JSNumber).toDartInt, (d['placement'] as JSNumber).toDartInt);
    }, growable: false);

    final placementsJs = res['placements'] as JSArray;
    final placements = List<QvpPlacement>.generate(placementsJs.length, (i) {
      final p = placementsJs[i] as JSObject;
      return QvpPlacement((p['dx'] as JSNumber).toDartDouble, (p['dy'] as JSNumber).toDartDouble, (p['kx'] as JSNumber).toDartDouble, (p['ky'] as JSNumber).toDartDouble);
    }, growable: false);

    final isTruncated = (res['isTruncated'] as JSBoolean).toDart;
    final ellObj = res['ellipsis'] as JSObject?;
    final ellipsis = ellObj != null ? Rect.fromLTRB((ellObj['x0'] as JSNumber).toDartDouble, (ellObj['y0'] as JSNumber).toDartDouble, (ellObj['x1'] as JSNumber).toDartDouble, (ellObj['y1'] as JSNumber).toDartDouble) : null;

    return QvpPassageLayout(width: (res['width'] as JSNumber).toDartDouble, height: (res['height'] as JSNumber).toDartDouble, scale: (res['scale'] as JSNumber).toDartDouble, lineSpacing: (res['lineSpacing'] as JSNumber).toDartDouble, rows: rows, words: words, ayahs: ayahs, draws: draws, placements: placements, isTruncated: isTruncated, ellipsis: ellipsis);
  }

  // ── Ornaments ──

  @override
  (OrnamentsHandle, List<QvpOrnament>) ornamentsLoad(Uint8List bytes) {
    final jsOrn = js.callMethod<JSObject>('loadOrnaments'.toJS, bytes.toJS);
    final count = (jsOrn['count'] as JSNumber).toDartInt;
    final listJs = jsOrn['list'] as JSArray;
    final list = List<QvpOrnament>.generate(count, (i) {
      final o = listJs[i] as JSObject;
      final partsJs = o['parts'] as JSArray;
      final parts = List<QvpOrnamentPart>.generate(partsJs.length, (k) {
        final p = partsJs[k] as JSObject;
        return QvpOrnamentPart(index: (p['index'] as JSNumber).toDartInt, color: (p['color'] as JSNumber).toDartInt, stroke: (p['stroke'] as JSBoolean).toDart, name: (p['name'] as JSString).toDart);
      }, growable: false);
      final lic = o['licence'] as JSObject;
      final licence = QvpOrnamentLicence(id: (lic['id'] as JSString).toDart, status: (lic['status'] as JSString).toDart, redistributable: (lic['redistributable'] as JSBoolean).toDart, attribution: (lic['attribution'] as JSString).toDart);
      return QvpOrnament(index: (o['index'] as JSNumber).toDartInt, kind: _kindFromName((o['kind'] as JSString).toDart), lineage: _lineageFromName((o['lineage'] as JSString).toDart), style: (o['style'] as JSString).toDart, riwayah: (o['riwayah'] as JSString).toDart, hasSlices: (o['hasSlices'] as JSBoolean).toDart, licence: licence, parts: parts);
    }, growable: false);
    return (WebOrnamentsHandle(jsOrn), list);
  }

  @override
  void ornamentsFree(OrnamentsHandle handle) => _ornaments(handle).callMethod('free'.toJS);

  @override
  int ornamentFind(OrnamentsHandle handle, int kind, String style) {
    final res = _ornaments(handle).callMethod<JSObject?>('find'.toJS, const ['ayah_mark', 'surah_header', 'page_frame'][kind.clamp(0, 2)].toJS, style.toJS);
    return res == null ? qvpNone : (res['index'] as JSNumber).toDartInt;
  }
}

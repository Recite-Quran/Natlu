import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import 'engine.dart';

/// A decoded page. Geometry ([ops], [pts], [table]) and the info lists are
/// copied out once; style state, layout, highlights, masks and selection
/// live in the engine backend. Listeners are notified after every mutating call.
class QvpPage extends ChangeNotifier {
  QvpPage.fromHandle(this.engine, this._backend, this._handle, QvpPageData data)
      : width = data.width,
        height = data.height,
        lineSpacing = data.lineSpacing,
        page = data.page,
        nLines = data.nLines,
        nAyahs = data.nAyahs,
        nWords = data.nWords,
        nPaths = data.nPaths,
        nDecorations = data.nDecorations,
        ops = data.ops,
        pts = data.pts,
        table = data.table,
        words = data.words,
        ayahs = data.ayahs,
        lines = data.lines,
        decorations = data.decorations;

  final QvpEngine engine;
  final QvpBackend _backend;
  PageHandle? _handle;

  /// Internal handle for passage / ornament dressing calls.
  PageHandle get handle {
    assert(_handle != null, 'QvpPage used after dispose()');
    return _handle!;
  }

  final double width;
  final double height;
  final double lineSpacing;
  final int page;
  final int nLines;
  final int nAyahs;
  final int nWords;
  final int nPaths;
  final int nDecorations;

  /// Opcode stream (see [QvpOp]).
  final Uint8List ops;

  /// x,y pairs consumed in order by the opcodes.
  final Float32List pts;

  /// `nPaths × 8`: op_start, op_count, pt_start, pt_count, flags, word, line, extra.
  final Uint32List table;

  final List<QvpWordInfo> words;
  final List<QvpAyahInfo> ayahs;
  final List<QvpLineInfo> lines;
  final List<QvpDecorationInfo> decorations;

  /// Layout from the last [layout] call, if any.
  QvpLayout? currentLayout;

  int _defaultInk = QvpDefaults.ink;

  /// Default ink colour (0xRRGGBBAA).
  int get defaultInk => _defaultInk;

  /// Incremented on every mutating call.
  int revision = 0;

  bool get isDisposed => _handle == null;

  int _batchDepth = 0;
  bool _needsNotify = false;

  /// Runs [fn] with notifications suppressed until complete, firing a single notification at the end.
  void batch(void Function() fn) {
    _batchDepth++;
    try {
      fn();
    } finally {
      _batchDepth--;
      if (_batchDepth == 0 && _needsNotify) {
        _needsNotify = false;
        _touch();
      }
    }
  }

  void _touch() {
    _cachedAyahMarks = null;
    if (_batchDepth > 0) {
      _needsNotify = true;
      return;
    }
    revision++;
    notifyListeners();
  }

  List<ui.Path?>? _lazyPaths;

  /// Lazy path access: builds only the path at [i] when requested, matching native Android/iOS.
  ui.Path path(int i) {
    final all = _lazyPaths ??= List<ui.Path?>.filled(nPaths, null);
    final kept = all[i];
    if (kept != null) return kept;

    final p = ui.Path();
    p.fillType = pathEvenOdd(i) ? ui.PathFillType.evenOdd : ui.PathFillType.nonZero;
    final t = table;
    decodeQvpPath(p, ops, t[i * 8], t[i * 8 + 1], pts, t[i * 8 + 2]);
    return all[i] = p;
  }

  /// One [ui.Path] per engine path, in page units, with the fill rule the page records. Built
  /// from the copied geometry, so it works on a disposed page too.
  List<ui.Path> buildPaths() => List<ui.Path>.generate(nPaths, path, growable: false);

  /// Frees backend page memory. Geometry and info lists stay usable.
  void free() {
    _cachedAyahMarks = null;
    _lazyPaths = null;
    if (_handle != null) {
      _backend.pageFree(_handle!);
      _handle = null;
    }
  }

  @override
  void dispose() {
    _lazyPaths = null;
    free();
    super.dispose();
  }

  // ── Geometry table accessors ──
  int pathOpStart(int i) => table[i * 8];
  int pathOpCount(int i) => table[i * 8 + 1];
  int pathPtStart(int i) => table[i * 8 + 2];
  int pathPtCount(int i) => table[i * 8 + 3];
  int pathFlags(int i) => table[i * 8 + 4];
  int pathKind(int i) => pathFlags(i) & 0xff;
  int pathMark(int i) => (pathFlags(i) >> 8) & 0xff;
  int pathFamily(int i) => (pathFlags(i) >> 16) & 0xff;
  bool pathEvenOdd(int i) => ((pathFlags(i) >> 24) & 1) == 1;
  bool pathGlyphInstance(int i) => ((pathFlags(i) >> 24) & 2) == 2;
  int pathWord(int i) {
    final w = table[i * 8 + 5];
    return w == qvpNone ? -1 : w;
  }
  int pathLine(int i) => table[i * 8 + 6];
  int pathCategory(int i) => table[i * 8 + 7] & 0xff;
  int pathNthInWord(int i) => (table[i * 8 + 7] >> 8) & 0xff;
  int pathNthMark(int i) {
    final n = (table[i * 8 + 7] >> 16) & 0xff;
    return n == 0xff ? -1 : n;
  }

  // ── Queries & Words ──

  /// Text of word [i] in a text form ('rasmUthmani' | 'rasmImlai' | 'qpc' | 'rasm' | 'search' or [QvpForm]).
  String wordForm(int i, [Object form = 'rasmUthmani']) =>
      _backend.wordForm(handle, i, QvpForm.of(form));

  /// Word index for (surah, ayah, word) or -1.
  int findWord(int surah, int ayah, int word) =>
      _backend.findWord(handle, surah, ayah, word);

  /// `surah:ayah:word` of word [i].
  String wordKey(int i) => words[i].wordKey;

  /// Word indices of a target.
  List<int> targetWords(Object target) =>
      _backend.targetWords(handle, QvpTarget.of(target));

  /// Surahs starting or continuing on this page.
  List<QvpSurah> surahs() => _backend.surahs(handle);

  /// Divisions (juz / hizb / nisf / rubuAlHizb) that start on this page.
  List<QvpDivision> divisions() => _backend.divisions(handle);

  /// The surah headings, in page units.
  List<QvpSurahHeader> surahHeaders() => _backend.surahHeaders(handle, view: false);

  /// The surah headings in viewport px through current layout.
  List<QvpSurahHeader> surahHeadersView() => _backend.surahHeaders(handle, view: true);

  List<QvpAyahMark>? _cachedAyahMarks;

  /// Ayah medallions on the page.
  List<QvpAyahMark> ayahMarks() {
    if (_cachedAyahMarks != null) return _cachedAyahMarks!;
    return _cachedAyahMarks = _backend.ayahMarks(handle);
  }

  /// Drawn hizb rosettes.
  List<QvpRosette> rosettes() => _backend.rosettes(handle);

  /// Sajdah signs.
  List<QvpSajdah> sajdahs() => _backend.sajdahs(handle);

  /// `(surah, ayah)` keys in reading order.
  List<(int, int)> ayahKeys() => _backend.ayahKeys(handle);

  /// Words of an ayah on this page and whether the ayah is complete here.
  ({int count, bool isComplete}) ayahWordCount(int surah, int ayah) =>
      _backend.ayahWordCount(handle, surah, ayah);

  /// Words for [nSegments] recitation segments, or null when counts disagree.
  List<int>? reciteMap(int surah, int ayah, int nSegments) =>
      _backend.reciteMap(handle, surah, ayah, nSegments);

  /// Accessibility label of word [i].
  String wordLabel(int i) => _backend.wordLabel(handle, i);

  /// Accessibility label of ayah record [ayahIndex].
  String ayahLabel(int ayahIndex) => _backend.ayahLabel(handle, ayahIndex);

  // ── Text & Search ──

  /// Text of a target (default: the page).
  String text([Object target = 'page', Object form = 'rasmUthmani', String wordSep = ' ', String lineSep = '\n']) =>
      _backend.text(handle, QvpTarget.of(target), QvpForm.of(form), wordSep, lineSep);

  /// Search this page. [mode]: 'includes' | 'exact' | 'prefix'.
  List<QvpMatch> search(String query, {Object form = 'search', String mode = 'includes', bool normalize = true, bool looseMatch = true, int limit = 0}) {
    final matches = _backend.search(handle, query, form: QvpForm.of(form), mode: mode, normalize: normalize, looseMatch: looseMatch, limit: limit);
    return [
      for (final m in matches)
        QvpMatch(
          word: m.word,
          index: m.index,
          isLooseMatch: m.isLooseMatch,
          wordKey: wordKey(m.word),
          text: words[m.word].text,
        )
    ];
  }

  /// Citation string (e.g. "2:255-257, 3:1") for a word list.
  String citation(List<int> ws) => _backend.citation(handle, ws);

  /// Attaches a words sidecar (`NNN.words.json` as String, bytes or decoded map).
  int attachWords(Object sidecar) {
    final List<int> bytes = switch (sidecar) {
      String s => utf8.encode(s),
      Uint8List b => b,
      List<int> b => b,
      _ => utf8.encode(jsonEncode(sidecar)),
    };
    final n = _backend.attachWords(handle, bytes);
    if (n > 0) _touch();
    return n;
  }

  /// Checks if a text form is attached to this page.
  bool hasForm(Object form) => _backend.hasForm(handle, QvpForm.of(form));

  // ── Hit Testing ──

  /// Exact outline hit, page units.
  QvpHit? hitTestExact(double x, double y) => _enrichHit(_backend.hitTestExact(handle, x, y));

  /// Exact outline hit, viewport px through current layout.
  QvpHit? hitTestExactView(double viewX, double viewY) => _enrichHit(_backend.hitTestExactView(handle, viewX, viewY));

  /// Gap-aware hit test, page units.
  QvpHit? hitTest(double x, double y, [QvpHitOptions opt = const QvpHitOptions()]) =>
      _enrichHit(_backend.hitTest(handle, x, y, opt));

  /// Gap-aware hit test, viewport px through current layout.
  QvpHit? hitTestView(double viewX, double viewY, [QvpHitOptions opt = const QvpHitOptions()]) =>
      _enrichHit(_backend.hitTestView(handle, viewX, viewY, opt));

  QvpHit? _enrichHit(QvpHit? h) {
    if (h == null) return null;
    final w = h.word;
    return QvpHit(
      word: w,
      path: h.path,
      decoration: h.decoration,
      line: h.line,
      distance: h.distance,
      isExact: h.isExact,
      wordKey: w >= 0 && w < words.length ? words[w].wordKey : null,
      ayahKey: w >= 0 && w < words.length ? words[w].ayahKey : null,
    );
  }

  List<QvpLineBand> lineBands() => _backend.lineBands(handle);
  List<QvpHitArea> hitAreas([double gapBias = QvpDefaults.gapBias]) => _backend.hitAreas(handle, gapBias);

  // ── Layout ──

  /// Computes and stores an engine layout.
  QvpLayout layout(QvpLayoutSpec spec) {
    final l = _backend.layout(handle, spec);
    currentLayout = l;
    _touch();
    return l;
  }

  // ── The reader's zoom control ──

  QvpZoomChange zoomPinch(QvpLayoutSpec spec, QvpZoom zoom, QvpView view, double factor, double focalX, double focalY) =>
      _backend.zoomPinch(handle, spec, zoom, view, factor, focalX, focalY);

  QvpZoomChange zoomToStep(QvpLayoutSpec spec, QvpZoom zoom, int step, QvpView view) =>
      _backend.zoomToStep(handle, spec, zoom, step, view);

  QvpZoom zoomMode(QvpLayoutSpec spec, QvpZoom zoom, QvpZoomMode mode) =>
      _backend.zoomMode(handle, spec, zoom, mode);

  QvpLayoutSpec zoomSpec(QvpLayoutSpec spec, QvpZoom zoom) =>
      _backend.zoomSpec(handle, spec, zoom);

  QvpZoom zoomCarried(QvpLayoutSpec spec, QvpZoom zoom) =>
      _backend.zoomCarried(handle, spec, zoom);

  double zoomAtStep(QvpLayoutSpec spec, int step) =>
      _backend.zoomAtStep(handle, spec, step);

  Float32List zoomSteps(QvpLayoutSpec spec) =>
      _backend.zoomSteps(handle, spec);

  double reflowMaxZoom(QvpLayoutSpec spec) =>
      _backend.reflowMaxZoom(handle, spec);

  bool isZoomed(QvpZoom zoom, QvpView view, [double fitScale = 0]) =>
      _backend.isZoomed(zoom, view, fitScale);

  QvpSideways sidewaysDrag(QvpZoom zoom, QvpView view, [double fitScale = 0]) =>
      _backend.sidewaysDrag(handle, zoom, view, fitScale);

  List<QvpDraw> layoutDrawList({double bandTop = 0, double bandBottom = 0}) =>
      _backend.layoutDrawList(handle, bandTop: bandTop, bandBottom: bandBottom);

  List<QvpPlacement> layoutPlacements() =>
      _backend.layoutPlacements(handle);

  QvpLayout? readLayout() {
    final l = _backend.readLayout(handle);
    if (l != null) currentLayout = l;
    return l;
  }

  int? layoutWordRow(int word) => _backend.layoutWordRow(handle, word);
  Uint32List layoutRowWords(int row) => _backend.layoutRowWords(handle, row);

  ({int lines, double lineSpacing}) get grid => _backend.pageGrid(handle);
  double layoutWastedFraction(QvpLayoutSpec spec) => _backend.layoutWastedFraction(handle, spec);
  double layoutPrintedHeight(QvpLayoutSpec spec) => _backend.layoutPrintedHeight(handle, spec);
  double layoutLineSpacingToFill(QvpLayoutSpec spec, [double max = 0]) => _backend.layoutLineSpacingToFill(handle, spec, max);
  ({double x0, double y0, double x1, double y1}) wordBoundsView(int i) => _backend.wordBoundsView(handle, i);

  // ── Styles ──

  int style(QvpSelector sel, Object color, {int ms = 0, int layer = QvpLayer.base}) {
    final h = _backend.style(handle, sel, rgba(color), ms: ms, layer: layer);
    _touch();
    return h;
  }

  int styleTarget(Object target, Object color, {int ms = 0, int layer = QvpLayer.base}) {
    final h = _backend.styleTarget(handle, QvpTarget.of(target), rgba(color), ms: ms, layer: layer);
    _touch();
    return h;
  }

  int removeStyle(int styleHandle) {
    final n = _backend.removeStyle(handle, styleHandle);
    _touch();
    return n;
  }

  int recolorStyle(int styleHandle, Object color, [int ms = 0]) {
    final n = _backend.recolorStyle(handle, styleHandle, rgba(color), ms);
    _touch();
    return n;
  }

  int hide(QvpSelector sel) {
    final h = _backend.hide(handle, sel);
    _touch();
    return h;
  }

  void clearStyles() {
    _backend.clearStyles(handle);
    _touch();
  }

  void clearLayer(int layer) {
    _backend.clearLayer(handle, layer);
    _touch();
  }

  void setDefaultColor(Object color) {
    _defaultInk = rgba(color);
    _backend.setDefaultColor(handle, _defaultInk);
    _touch();
  }

  int theme(QvpTheme t) {
    final h = _backend.theme(handle, t);
    _touch();
    return h;
  }

  List<int> styleHandles() => _backend.styleHandles(handle);

  // ── Clock & Display list ──

  bool tick(double nowMs) => _backend.tick(handle, nowMs);
  Uint32List colors() => _backend.colors(handle, nPaths);
  List<QvpStyledPath> styledPaths() => _backend.styledPaths(handle);
  int colorOf(int path) => _backend.colorOf(handle, path);

  // ── Highlights ──

  int highlight(Object target, [QvpHighlightStyle style = const QvpHighlightStyle()]) {
    final h = _backend.highlight(handle, QvpTarget.of(target), style);
    _touch();
    return h;
  }

  bool moveHighlight(int highlightHandle, Object target) {
    final ok = _backend.moveHighlight(handle, highlightHandle, QvpTarget.of(target));
    _touch();
    return ok;
  }

  bool restyleHighlight(int highlightHandle, QvpHighlightStyle style) {
    final ok = _backend.restyleHighlight(handle, highlightHandle, style);
    _touch();
    return ok;
  }

  bool removeHighlight(int highlightHandle) {
    final ok = _backend.removeHighlight(handle, highlightHandle);
    _touch();
    return ok;
  }

  void clearHighlights() {
    _backend.clearHighlights(handle);
    _touch();
  }

  List<int> highlightHandles() => _backend.highlightHandles(handle);
  List<int> highlightWords(int highlightHandle) => _backend.highlightWords(handle, highlightHandle);
  List<QvpBox> highlightBoxesView() => _backend.highlightBoxesView(handle);
  List<QvpBox> wordBands(List<int> ws, {String height = 'lineSpacing', double padX = QvpDefaults.highlightPadX, double padY = QvpDefaults.highlightPadY}) =>
      _backend.wordBands(handle, ws, inkHeight: height == 'ink', padX: padX, padY: padY);

  // ── Selection ──

  void select(int anchor, [int? focus]) {
    _backend.select(handle, anchor, focus ?? anchor);
    _touch();
  }

  void clearSelection() => select(-1, -1);
  List<int> selection() => _backend.selection(handle);
  String selectionText([Object form = 'rasmUthmani', bool includeCitation = false]) =>
      _backend.selectionText(handle, QvpForm.of(form), includeCitation);

  // ── Masks & memorisation ──

  static int _maskMode(String m) => const {'hide': 0, 'block': 1, 'blur': 2}[m] ?? 0;

  void mask(Object target, [String mode = 'hide']) {
    _backend.mask(handle, QvpTarget.of(target), _maskMode(mode));
    _touch();
  }

  void maskFrom(int wordIndex, [String mode = 'hide']) {
    _backend.maskFrom(handle, wordIndex, _maskMode(mode));
    _touch();
  }

  void maskOptions({Object blockColor = QvpDefaults.maskBlock, double padX = QvpDefaults.maskPad, double padY = QvpDefaults.maskPad, double radius = QvpDefaults.maskRadius, bool reverse = false}) {
    _backend.maskOptions(handle, rgba(blockColor), padX, padY, radius, reverse);
    _touch();
  }

  int unmaskNext([int n = 1]) {
    final r = _backend.unmaskNext(handle, n);
    _touch();
    return r;
  }

  int maskBack([int n = 1]) {
    final r = _backend.maskBack(handle, n);
    _touch();
    return r;
  }

  bool unmaskWord(int wordIndex) {
    final r = _backend.unmaskWord(handle, wordIndex);
    _touch();
    return r;
  }

  bool maskWord(int wordIndex) {
    final r = _backend.maskWord(handle, wordIndex);
    _touch();
    return r;
  }

  void unmaskAll() {
    _backend.unmaskAll(handle);
    _touch();
  }

  void maskAll() {
    _backend.maskAll(handle);
    _touch();
  }

  void unmask() {
    _backend.unmask(handle);
    _touch();
  }

  List<int> maskHidden() => _backend.maskHidden(handle);
  List<int> maskWords() => _backend.maskWords(handle);
  List<QvpBox> maskBoxesView() => _backend.maskBoxesView(handle);

  // ── Reveal ──

  int revealStart({int lit = QvpDefaults.revealLit, bool byAyah = false, Object grey = QvpDefaults.revealGrey, Object ink = QvpDefaults.ink, bool ayahMarks = true, int ms = 0}) {
    final n = _backend.revealStart(handle, lit: lit, byAyah: byAyah, grey: rgba(grey), ink: rgba(ink), ayahMarks: ayahMarks, ms: ms);
    _touch();
    return n;
  }

  bool revealGoto(int at) {
    final ok = _backend.revealGoto(handle, at);
    _touch();
    return ok;
  }

  int? revealPosition() => _backend.revealPosition(handle);
  int revealStepCount() => _backend.revealStepCount(handle);
  int revealStepOf(int wordIndex) => _backend.revealStepOf(handle, wordIndex);

  void revealStop() {
    _backend.revealStop(handle);
    _touch();
  }

  // ── Dress: ornaments ──

  QvpDressSpec? _dressSpec;

  /// The spec the page is dressed with, or null.
  QvpDressSpec? get dressSpec => _dressSpec;

  List<QvpDressDraw>? _dressDraws;
  int _dressDrawsRevision = -1;

  QvpDressInfo? dress(QvpOrnaments set, [QvpDressSpec spec = const QvpDressSpec()]) {
    _dressDraws = null;
    final ok = _backend.dress(handle, set.handle, spec);
    _dressSpec = ok ? spec : null;
    _touch();
    return ok ? dressInfo() : null;
  }

  void undress() {
    _backend.undress(handle);
    _dressSpec = null;
    _dressDraws = null;
    _touch();
  }

  QvpView dressClamp(QvpView view, double viewportW, double viewportH) =>
      _backend.dressClamp(handle, view, viewportW, viewportH);

  QvpDressView dressView(double scale, double viewportW) =>
      _backend.dressView(handle, scale, viewportW);

  QvpDressInfo? dressInfo() => _backend.dressInfo(handle);
  int dressRevision() => dressInfo()?.revision ?? 0;

  List<QvpDressDraw> dressGeometry() {
    final rev = dressRevision();
    final kept = _dressDraws;
    if (kept != null && _dressDrawsRevision == rev) return kept;
    final draws = _backend.dressGeometry(handle);
    _dressDrawsRevision = rev;
    return _dressDraws = draws;
  }

  // ── Crop ──

  QvpCropBounds? cropBounds(Object target, {double pad = QvpDefaults.cropPad, bool keepAyahMarks = true}) =>
      _backend.cropBounds(handle, QvpTarget.of(target), pad: pad, keepAyahMarks: keepAyahMarks);

  String? cropSvg(Object target, {double pad = QvpDefaults.cropPad, bool keepAyahMarks = true, Object? background}) =>
      _backend.cropSvg(handle, QvpTarget.of(target), pad: pad, keepAyahMarks: keepAyahMarks, background: background == null ? null : rgba(background));
}

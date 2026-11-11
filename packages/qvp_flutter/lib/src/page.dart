// QvpPage — one decoded page: geometry copied out once, everything else asked of the engine.
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import 'engine.dart';

/// A decoded page. Geometry ([ops], [pts], [table]) and the info lists are
/// copied out once; style state, layout, highlights, masks and selection
/// live in the engine backend. Listeners are notified after every mutating call.
class QvpPage extends ChangeNotifier {
  /// Wraps a page the backend has loaded. Apps call [QvpEngine.loadPage] instead.
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

  /// The engine that loaded the page.
  final QvpEngine engine;
  final QvpBackend _backend;
  PageHandle? _handle;

  /// Internal handle for passage / ornament dressing calls. Throws a [StateError] once the
  /// page is disposed, in every build mode, so no call hands the engine a null handle.
  PageHandle get handle => _handle ?? (throw StateError('QvpPage is disposed'));

  /// The page's width in page units, the coordinate space of every page-unit call.
  final double width;

  /// The page's height in page units. y runs down.
  final double height;

  /// The printed line spacing, in page units.
  final double lineSpacing;

  /// The page number in the mushaf, from 1.
  final int page;

  /// How many printed lines the page has: the length of [lines].
  final int nLines;

  /// How many ayah fragments the page has: the length of [ayahs]. An ayah that runs over
  /// several lines has one fragment per line.
  final int nAyahs;

  /// How many words the page has: the length of [words].
  final int nWords;

  /// How many paths the page has: the rows of [table], and the length of [colors].
  final int nPaths;

  /// How many decorations the page has: the length of [decorations].
  final int nDecorations;

  /// Opcode stream (see [QvpOp]).
  final Uint8List ops;

  /// x,y pairs consumed in order by the opcodes.
  final Float32List pts;

  /// `nPaths × 8`: op_start, op_count, pt_start, pt_count, flags, word, line, extra.
  final Uint32List table;

  /// Every word on the page in reading order. A word index is a position in this list.
  final List<QvpWordInfo> words;

  /// Every ayah fragment on the page in reading order, one per printed line an ayah touches.
  final List<QvpAyahInfo> ayahs;

  /// Every printed line, from the top, headers included.
  final List<QvpLineInfo> lines;

  /// Every decoration: ayah marks, surah names, the basmalah, division marks, sajdah signs and
  /// page furniture.
  final List<QvpDecorationInfo> decorations;

  /// Layout from the last [layout] call, if any.
  QvpLayout? currentLayout;

  /// Layout spec passed to the last [layout] call, if known.
  QvpLayoutSpec? currentLayoutSpec;

  int _defaultInk = QvpDefaults.ink;

  /// Default ink colour (0xRRGGBBAA).
  int get defaultInk => _defaultInk;

  /// Incremented on every mutating call.
  int revision = 0;

  /// True after [free] or [dispose]. The geometry and the info lists stay readable.
  bool get isDisposed => _handle == null;

  int _batchDepth = 0;
  bool _needsNotify = false;

  /// Runs [fn] and notifies listeners once at the end, however many mutations it makes.
  /// Nested calls notify when the outermost one returns.
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

  void _invalidateViewGeometry() {
    _cachedAyahMarks = null;
    _cachedAyahMarksView = null;
    _cachedSurahHeadersView = null;
    _cachedWordBoxesView = null;
  }

  void _touch() {
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
    p.fillType =
        pathEvenOdd(i) ? ui.PathFillType.evenOdd : ui.PathFillType.nonZero;
    final t = table;
    decodeQvpPath(p, ops, t[i * 8], t[i * 8 + 1], pts, t[i * 8 + 2]);
    return all[i] = p;
  }

  /// One [ui.Path] per engine path, in page units, with the fill rule the page records. Built
  /// from the copied geometry, so it works on a disposed page too.
  List<ui.Path> buildPaths() =>
      List<ui.Path>.generate(nPaths, path, growable: false);

  /// Frees backend page memory. Geometry and info lists stay usable. A second call does
  /// nothing.
  void free() {
    _invalidateViewGeometry();
    _lazyPaths = null;
    final h = _handle;
    if (h != null) {
      _handle = null;
      _backend.pageFree(h);
    }
  }

  bool _disposed = false;

  /// Frees the page and drops its listeners. A second call does nothing.
  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    free();
    super.dispose();
  }

  // ── Geometry table accessors ──

  /// Where the opcodes of path [i] start in [ops].
  int pathOpStart(int i) => table[i * 8];

  /// How many opcodes path [i] has.
  int pathOpCount(int i) => table[i * 8 + 1];

  /// Where the coordinates of path [i] start in [pts]. It counts floats, not points.
  int pathPtStart(int i) => table[i * 8 + 2];

  /// How many floats of [pts] path [i] reads: two per point.
  int pathPtCount(int i) => table[i * 8 + 3];

  /// The packed flags of path [i]: kind, mark and family in the low three bytes, and the
  /// even-odd and glyph-instance bits above them. The accessors below unpack them.
  int pathFlags(int i) => table[i * 8 + 4];

  /// The [QvpKind] of path [i].
  int pathKind(int i) => pathFlags(i) & 0xff;

  /// The mark id of path [i] (see [QvpMark]); 0 for a path that is not a mark.
  int pathMark(int i) => (pathFlags(i) >> 8) & 0xff;

  /// The [QvpFamily] of path [i].
  int pathFamily(int i) => (pathFlags(i) >> 16) & 0xff;

  /// True when path [i] fills with the even-odd rule, false for nonzero.
  bool pathEvenOdd(int i) => ((pathFlags(i) >> 24) & 1) == 1;

  /// True when path [i] draws a glyph outline that the page stores once and places again.
  bool pathGlyphInstance(int i) => ((pathFlags(i) >> 24) & 2) == 2;

  /// The word that owns path [i], or -1 for a decoration's path.
  int pathWord(int i) {
    final w = table[i * 8 + 5];
    return w == qvpNone ? -1 : w;
  }

  /// The line index path [i] is laid out with. Every path has one.
  int pathLine(int i) => table[i * 8 + 6];

  /// The [QvpCategory] of path [i].
  int pathCategory(int i) => table[i * 8 + 7] & 0xff;

  /// The position of path [i] among the paths of its word, from 0.
  int pathNthInWord(int i) => (table[i * 8 + 7] >> 8) & 0xff;

  /// The position of path [i] among the marks of its word, from 0; -1 when it is not a mark.
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

  /// The surahs on this page: those with words here, and those whose name banner or basmalah
  /// is here. A surah that continues from an earlier page has no names and an `ayahCount` of
  /// 0 (see [QvpSurah.ayahCount]).
  List<QvpSurah> surahs() => _backend.surahs(handle);

  /// Divisions (juz / hizb / nisf / rubuAlHizb) that start on this page.
  List<QvpDivision> divisions() => _backend.divisions(handle);

  /// The surah headings, in page units.
  List<QvpSurahHeader> surahHeaders() =>
      _backend.surahHeaders(handle, view: false);

  List<QvpSurahHeader>? _cachedSurahHeadersView;

  /// The surah headings in viewport px through current layout.
  List<QvpSurahHeader> surahHeadersView() =>
      _cachedSurahHeadersView ??= _backend.surahHeaders(handle, view: true);

  List<QvpAyahMark>? _cachedAyahMarks;
  List<QvpAyahMark>? _cachedAyahMarksView;

  /// Ayah medallions on the page. Held until the next mutation, because a dressed page asks
  /// for them on every frame.
  List<QvpAyahMark> ayahMarks() =>
      _cachedAyahMarks ??= _backend.ayahMarks(handle, view: false);

  /// The same marks in viewport px through the current layout: where a reflowed page put
  /// them.
  List<QvpAyahMark> ayahMarksView() =>
      _cachedAyahMarksView ??= _backend.ayahMarks(handle, view: true);

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
  String text([
    Object target = 'page',
    Object form = 'rasmUthmani',
    String wordSep = ' ',
    String lineSep = '\n',
  ]) =>
      _backend.text(
        handle,
        QvpTarget.of(target),
        QvpForm.of(form),
        wordSep,
        lineSep,
      );

  /// Search this page. [mode]: 'includes' | 'exact' | 'prefix'.
  List<QvpMatch> search(
    String query, {
    Object form = 'search',
    String mode = 'includes',
    bool normalize = true,
    bool looseMatch = true,
    int limit = 0,
  }) {
    final matches = _backend.search(
      handle,
      query,
      form: QvpForm.of(form),
      mode: mode,
      normalize: normalize,
      looseMatch: looseMatch,
      limit: limit,
    );
    return [
      for (final m in matches)
        QvpMatch(
          word: m.word,
          index: m.index,
          isLooseMatch: m.isLooseMatch,
          wordKey: wordKey(m.word),
          text: words[m.word].text,
        ),
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

  /// Exact hit, page units: the outline under the point, else the box of a word
  /// or a decoration.
  QvpHit? hitTestExact(double x, double y) =>
      _enrichHit(_backend.hitTestExact(handle, x, y));

  /// Exact hit, viewport px through current layout.
  QvpHit? hitTestExactView(double viewX, double viewY) =>
      _enrichHit(_backend.hitTestExactView(handle, viewX, viewY));

  /// Gap-aware hit test, page units.
  QvpHit? hitTest(
    double x,
    double y, [
    QvpHitOptions opt = const QvpHitOptions(),
  ]) =>
      _enrichHit(_backend.hitTest(handle, x, y, opt));

  /// Gap-aware hit test, viewport px through current layout.
  QvpHit? hitTestView(
    double viewX,
    double viewY, [
    QvpHitOptions opt = const QvpHitOptions(),
  ]) =>
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

  /// The vertical band of every printed line, in page units: the line-spacing band and the
  /// ink extent. The gap-aware hit test resolves a point to a line by these.
  List<QvpLineBand> lineBands() => _backend.lineBands(handle);

  /// The gap-aware box of every word, in page units. The boxes split each line with no gap
  /// between them, so every point on a line belongs to one word. [gapBias] is the share of a
  /// gap that goes to the word before it; a negative value is the engine default.
  List<QvpHitArea> hitAreas([double gapBias = QvpDefaults.gapBias]) =>
      _backend.hitAreas(handle, gapBias, view: false);

  /// The same partition in viewport px through the current layout. Not [hitAreas]
  /// transformed: a reflowed row's words have other neighbours than a printed line's, so the
  /// engine computes it again.
  List<QvpHitArea> hitAreasView([double gapBias = QvpDefaults.gapBias]) =>
      _backend.hitAreas(handle, gapBias, view: true);

  // ── Layout ──

  /// Computes and stores an engine layout.
  QvpLayout layout(QvpLayoutSpec spec) {
    final l = _backend.layout(handle, spec);
    currentLayout = l;
    currentLayoutSpec = spec;
    _invalidateViewGeometry();
    _touch();
    return l;
  }

  // ── The reader's zoom control ──

  /// One frame of a pinch. [factor] is the distance between the fingers against the distance
  /// when they went down — the whole gesture, not the step since the last frame — and [focal] is
  /// the point between them, in viewport px. Pass the [QvpZoom] the gesture began on every
  /// frame: measured against that, a slow pinch walks the steps one at a time.
  QvpZoomChange zoomPinch(
    QvpLayoutSpec spec,
    QvpZoom zoom,
    QvpView view,
    double factor,
    double focalX,
    double focalY,
  ) =>
      _backend.zoomPinch(handle, spec, zoom, view, factor, focalX, focalY);

  /// The control moved to a step directly: a size button, a double tap, a reset. Step 0 is the
  /// printed page.
  QvpZoomChange zoomToStep(
    QvpLayoutSpec spec,
    QvpZoom zoom,
    int step,
    QvpView view,
  ) =>
      _backend.zoomToStep(handle, spec, zoom, step, view);

  /// The same control under another policy, keeping the size the reader is already at.
  QvpZoom zoomMode(QvpLayoutSpec spec, QvpZoom zoom, QvpZoomMode mode) =>
      _backend.zoomMode(handle, spec, zoom, mode);

  /// The spec this control asks for: what to lay out, draw and hit-test with. The host's other
  /// reflow knobs come back as it set them, on the printed page too, where the zoom is 0 and
  /// they wait for the next pinch.
  QvpLayoutSpec zoomSpec(QvpLayoutSpec spec, QvpZoom zoom) =>
      _backend.zoomSpec(handle, spec, zoom);

  /// The same control on this page: what a page turn keeps. A step carries as a step, because
  /// every page's steps are its own; a free zoom carries as a size, held inside what this page
  /// can reach.
  QvpZoom zoomCarried(QvpLayoutSpec spec, QvpZoom zoom) =>
      _backend.zoomCarried(handle, spec, zoom);

  /// The reflow zoom one step of this page's control means. Step 0 is the printed page.
  double zoomAtStep(QvpLayoutSpec spec, int step) =>
      _backend.zoomAtStep(handle, spec, step);

  /// The zoom steps this page ships with, above the printed page.
  Float32List zoomSteps(QvpLayoutSpec spec) => _backend.zoomSteps(handle, spec);

  /// The largest reflow zoom whose rows still hold every word of this page.
  double reflowMaxZoom(QvpLayoutSpec spec) =>
      _backend.reflowMaxZoom(handle, spec);

  /// Has the reader zoomed in, by either road: a magnified view or a reflowed page.
  /// [fitScale] is [QvpLayout.fitScale]; 0 means the page is at its fitted size.
  bool isZoomed(QvpZoom zoom, QvpView view, [double fitScale = 0]) =>
      _backend.isZoomed(zoom, view, fitScale);

  /// What a sideways drag means on the page in hand: pan it, or turn it.
  QvpSideways sidewaysDrag(QvpZoom zoom, QvpView view, [double fitScale = 0]) =>
      _backend.sidewaysDrag(handle, zoom, view, fitScale);

  /// Everything the current layout draws, in drawing order. Each [QvpDraw] names a path and the
  /// index of the placement to draw it under, from [layoutPlacements]. Omitted paths never
  /// appear and a repeated one appears twice, so one loop draws any page, reflowed or not.
  ///
  /// [bandTop] and [bandBottom] cut it to a band of the page, in viewport px; leave them out for
  /// the whole page.
  List<QvpDraw> layoutDrawList({double bandTop = 0, double bandBottom = 0}) =>
      _backend.layoutDrawList(handle, bandTop: bandTop, bandBottom: bandBottom);

  /// What a draw list's `placement` indexes: the groups, then the repeats.
  List<QvpPlacement> layoutPlacements() => _backend.layoutPlacements(handle);

  /// The layout the page already has, without computing one, or null when it has none. A zoom
  /// call lays the page out again, so this is how a host reads what it must now draw.
  QvpLayout? readLayout() {
    final l = _backend.readLayout(handle);
    if (l != null && l != currentLayout) {
      currentLayout = l;
      currentLayoutSpec = null;
      _invalidateViewGeometry();
      _touch();
    }
    return l;
  }

  /// The row a word landed on when the page reflowed, or null when it did not.
  int? layoutWordRow(int word) => _backend.layoutWordRow(handle, word);

  /// The words of one reflowed row, in drawing order.
  Uint32List layoutRowWords(int row) => _backend.layoutRowWords(handle, row);

  /// The grid the page is designed on: the mushaf's line count (15, or more when this page has
  /// more) and the printed line spacing in page units.
  ({int lines, double lineSpacing}) get grid => _backend.pageGrid(handle);

  /// The share of the padded viewport of [spec] left empty when the page is fitted to width.
  double layoutWastedFraction(QvpLayoutSpec spec) =>
      _backend.layoutWastedFraction(handle, spec);

  /// The page's height laid out for [spec] at the printed pitch, in viewport px: `contentH`
  /// before fill-height adds any leading, padding included. What a host asks before it sizes
  /// the canvas.
  double layoutPrintedHeight(QvpLayoutSpec spec) =>
      _backend.layoutPrintedHeight(handle, spec);

  /// The [QvpLayoutSpec.lineSpacing] multiplier that makes the page fill the padded viewport of
  /// [spec] when it is fitted to width; 1 when it fills it already. [max] caps the multiplier,
  /// and any [max] of 1 or less leaves it uncapped.
  double layoutLineSpacingToFill(QvpLayoutSpec spec, [double max = 0]) =>
      _backend.layoutLineSpacingToFill(handle, spec, max);

  /// The box of word [i] in viewport px through the current layout. [i] must be a valid word
  /// index.
  ({double x0, double y0, double x1, double y1}) wordBoundsView(int i) =>
      _backend.wordBoundsView(handle, i);

  /// The view that holds a point inside [word] ([nx], [ny] from 0 to 1 across its box) at
  /// ([toX], [toY]) on the screen, then clamps it to the viewport: how a pinch keeps its place
  /// when the layout reflows under it.
  QvpView viewAnchor(
    QvpView view,
    int word,
    double nx,
    double ny,
    double toX,
    double toY,
    double viewportW,
    double viewportH,
  ) =>
      _backend.viewAnchor(
        handle,
        view,
        word,
        nx,
        ny,
        toX,
        toY,
        viewportW,
        viewportH,
      );

  /// Which band of the current layout to keep drawn for [view] and a viewport: the whole page
  /// when it fits, otherwise two screens around the reader. The top moves in steps, so a pan
  /// inside one step redraws nothing; pass `top` and `top + height` to [layoutDrawList].
  /// [maxHeight] is the tallest band the host can draw and [maxPixels] the pixels it keeps for
  /// one, both in viewport px; 0 takes [QvpDefaults.maxInkHeight] and no pixel limit. The
  /// pixel limit never takes the band below one screen.
  QvpInkBand layoutInkBand(
    QvpView view,
    double viewportW,
    double viewportH, {
    double maxHeight = 0,
    double maxPixels = 0,
  }) =>
      _backend.layoutInkBand(
        handle,
        view,
        viewportW,
        viewportH,
        maxHeight,
        maxPixels,
      );

  /// Where a point of the viewport lands in the laid-out page: how a host turns a touch into a
  /// [hitTestView]. The inverse of `offset + scale·p`.
  ({double x, double y}) viewToLayout(
    QvpView view,
    double viewX,
    double viewY,
  ) =>
      _backend.viewToLayout(handle, view, viewX, viewY);

  // ── Styles ──

  /// Adds a style rule → handle (0 = bad selector).
  int style(
    QvpSelector sel,
    Object color, {
    int ms = 0,
    int layer = QvpLayer.base,
  }) {
    final h = _backend.style(handle, sel, rgba(color), ms: ms, layer: layer);
    _touch();
    return h;
  }

  /// Adds a colour rule for every word of [target] on [layer] and returns its handle. [color]
  /// is anything [rgba] takes, and [ms] is the fade in milliseconds.
  int styleTarget(
    Object target,
    Object color, {
    int ms = 0,
    int layer = QvpLayer.base,
  }) {
    final h = _backend.styleTarget(
      handle,
      QvpTarget.of(target),
      rgba(color),
      ms: ms,
      layer: layer,
    );
    _touch();
    return h;
  }

  /// Removes a rule / theme / hide by handle → rules removed.
  int removeStyle(int styleHandle) {
    final n = _backend.removeStyle(handle, styleHandle);
    _touch();
    return n;
  }

  /// Changes the colour of rule [styleHandle] in place, fading over [ms] milliseconds. Returns
  /// how many rules changed: 0 for an unknown handle.
  int recolorStyle(int styleHandle, Object color, [int ms = 0]) {
    final n = _backend.recolorStyle(handle, styleHandle, rgba(color), ms);
    _touch();
    return n;
  }

  /// Alpha-0 rule on the top layer → handle.
  int hide(QvpSelector sel) {
    final h = _backend.hide(handle, sel);
    _touch();
    return h;
  }

  /// Removes every style rule, themes and hides included.
  void clearStyles() {
    _backend.clearStyles(handle);
    _touch();
  }

  /// Removes every style rule on [layer] (see [QvpLayer]).
  void clearLayer(int layer) {
    _backend.clearLayer(handle, layer);
    _touch();
  }

  /// Sets the ink a path has when no rule applies to it. [color] is anything [rgba] takes.
  void setDefaultColor(Object color) {
    _defaultInk = rgba(color);
    _backend.setDefaultColor(handle, _defaultInk);
    _touch();
  }

  /// Applies a whole theme under one handle.
  int theme(QvpTheme t) {
    final h = _backend.theme(handle, t);
    _touch();
    return h;
  }

  /// The handles of every live style rule.
  List<int> styleHandles() => _backend.styleHandles(handle);

  // ── Clock & Display list ──

  /// Advances animations; true while something is still moving (keep drawing frames).
  bool tick(double nowMs) {
    final moving = _backend.tick(handle, nowMs);
    // the tick that ends an animation puts the colours and bands at their end, so it counts too
    if (moving || _clockMoving) _clock++;
    _clockMoving = moving;
    return moving;
  }

  /// Counts the ticks that moved a colour or a band, and the tick after them that settles the
  /// last of it. Read through [pageClock].
  int _clock = 0;
  bool _clockMoving = false;

  /// Full display list: one 0xRRGGBBAA per path (copy).
  Uint32List colors() => _backend.colors(handle, nPaths);

  /// Paths whose colour differs from the default ink (mid-transition values included).
  List<QvpStyledPath> styledPaths() => _backend.styledPaths(handle);

  /// The current colour of one path, as 0xRRGGBBAA, mid-transition included.
  int colorOf(int path) => _backend.colorOf(handle, path);

  // ── Highlights ──

  /// Highlights a target → handle.
  int highlight(
    Object target, [
    QvpHighlightStyle style = const QvpHighlightStyle(),
  ]) {
    final h = _backend.highlight(handle, QvpTarget.of(target), style);
    _touch();
    return h;
  }

  /// Moves a highlight: the band slides, the ink fades.
  bool moveHighlight(int highlightHandle, Object target) {
    final ok = _backend.moveHighlight(
      handle,
      highlightHandle,
      QvpTarget.of(target),
    );
    _touch();
    return ok;
  }

  /// Changes the style of highlight [highlightHandle] in place. False for an unknown handle.
  bool restyleHighlight(int highlightHandle, QvpHighlightStyle style) {
    final ok = _backend.restyleHighlight(handle, highlightHandle, style);
    _touch();
    return ok;
  }

  /// Fades out over the highlight's transition.
  bool removeHighlight(int highlightHandle) {
    final ok = _backend.removeHighlight(handle, highlightHandle);
    _touch();
    return ok;
  }

  /// Removes every highlight at once, without a fade.
  void clearHighlights() {
    _backend.clearHighlights(handle);
    _touch();
  }

  /// The handles of every live highlight.
  List<int> highlightHandles() => _backend.highlightHandles(handle);

  /// The word indices that highlight [highlightHandle] covers; empty for an unknown handle.
  List<int> highlightWords(int highlightHandle) =>
      _backend.highlightWords(handle, highlightHandle);

  /// Animated band boxes in layout viewport px; draw each id as one nonzero path behind the ink.
  List<QvpBox> highlightBoxesView() => _backend.highlightBoxesView(handle);

  /// Static band boxes for a word list (no highlight state involved).
  List<QvpBox> wordBands(
    List<int> ws, {
    String height = 'lineSpacing',
    double padX = QvpDefaults.highlightPadX,
    double padY = QvpDefaults.highlightPadY,
  }) =>
      _backend.wordBands(
        handle,
        ws,
        view: false,
        inkHeight: height == 'ink',
        padX: padX,
        padY: padY,
      );

  /// The same bands in viewport px through the current layout: one box per row the words
  /// occupy, where a reflowed page has moved them. A host that draws its own underlines or
  /// ayah marks reads these, never the printed page's boxes.
  List<QvpBox> wordBandsView(
    List<int> ws, {
    String height = 'lineSpacing',
    double padX = QvpDefaults.highlightPadX,
    double padY = QvpDefaults.highlightPadY,
  }) =>
      _backend.wordBands(
        handle,
        ws,
        view: true,
        inkHeight: height == 'ink',
        padX: padX,
        padY: padY,
      );

  Map<int, QvpBox>? _cachedWordBoxesView;

  /// Resolves a single word's band box in layout viewport px with tight ink padding.
  /// On non-reflowed layouts this uses direct arithmetic on [words] and [QvpLayout] with zero FFI calls.
  QvpBox wordBoxView(int i, {double padY = 2.0, QvpLayout? layout}) {
    final w = words[i];
    final l = layout ?? currentLayout;
    if (l != null && !l.reflowed) {
      final dy = (w.lineIndex >= 0 && w.lineIndex < l.lineDy.length)
          ? l.lineDy[w.lineIndex]
          : 0.0;
      final scale = l.scale;
      return QvpBox(
        id: i,
        line: w.line,
        x0: l.offsetX + w.x0 * scale,
        y0: l.offsetY + (w.y0 + dy) * scale - padY,
        x1: l.offsetX + w.x1 * scale,
        y1: l.offsetY + (w.y1 + dy) * scale + padY,
        color: 0,
        radius: 0.0,
      );
    }
    final b = wordBoundsView(i);
    return QvpBox(
      id: i,
      line: w.line,
      x0: b.x0,
      y0: b.y0 - padY,
      x1: b.x1,
      y1: b.y1 + padY,
      color: 0,
      radius: 0.0,
    );
  }

  /// Cached band boxes in layout viewport px for each word on the page with tight ink padding.
  /// Computed once per layout and cached until the next mutation or layout change.
  Map<int, QvpBox> wordBoxesView({String height = 'ink', double padY = 2.0}) {
    if (isDisposed) return const {};
    if (_cachedWordBoxesView != null) return _cachedWordBoxesView!;
    final l = currentLayout;
    final map = <int, QvpBox>{};
    final n = words.length;
    for (var i = 0; i < n; i++) {
      map[i] = wordBoxView(i, padY: padY, layout: l);
    }
    return _cachedWordBoxesView = map;
  }

  // ── Selection ──

  /// Selects the whole words from [anchor] to [focus], in either order. Leave out [focus] to
  /// select one word. -1 for both clears the selection.
  void select(int anchor, [int? focus]) {
    _backend.select(handle, anchor, focus ?? anchor);
    _touch();
  }

  /// Clears the selection.
  void clearSelection() => select(-1, -1);

  /// The selected word indices in reading order; empty when nothing is selected.
  List<int> selection() => _backend.selection(handle);

  /// The text of the selection in [form], with its citation, such as `2:255`, when
  /// [includeCitation] is true. Empty when nothing is selected.
  String selectionText([
    Object form = 'rasmUthmani',
    bool includeCitation = false,
  ]) =>
      _backend.selectionText(handle, QvpForm.of(form), includeCitation);

  // ── Masks & memorisation ──

  static int _maskMode(String m) =>
      const {'hide': 0, 'block': 1, 'blur': 2}[m] ?? 0;

  /// Masks a target. [mode]: 'hide' | 'block' | 'blur'.
  void mask(Object target, [String mode = 'hide']) {
    _backend.mask(handle, QvpTarget.of(target), _maskMode(mode));
    _touch();
  }

  /// Masks every word from [wordIndex] to the end of the page. [mode]: 'hide' | 'block' | 'blur'.
  void maskFrom(int wordIndex, [String mode = 'hide']) {
    _backend.maskFrom(handle, wordIndex, _maskMode(mode));
    _touch();
  }

  /// Sets how the mask looks and runs: the colour of a block, its padding and corner radius in
  /// page units. With [reverse] true, [unmaskNext] and [maskBack] work from the last word back.
  void maskOptions({
    Object blockColor = QvpDefaults.maskBlock,
    double padX = QvpDefaults.maskPad,
    double padY = QvpDefaults.maskPad,
    double radius = QvpDefaults.maskRadius,
    bool reverse = false,
  }) {
    _backend.maskOptions(handle, rgba(blockColor), padX, padY, radius, reverse);
    _touch();
  }

  /// Unhides the next [n] hidden words in mask order and returns how many it unhid.
  int unmaskNext([int n = 1]) {
    final r = _backend.unmaskNext(handle, n);
    _touch();
    return r;
  }

  /// Hides [n] shown words again and returns how many it hid. It walks the mask from its last
  /// word back (from its first word with `reverse` in [maskOptions]) and hides the first [n]
  /// shown words it meets. Their place in the mask decides, not the order they were unhidden in.
  int maskBack([int n = 1]) {
    final r = _backend.maskBack(handle, n);
    _touch();
    return r;
  }

  /// Unhides one word. False when it was not hidden.
  bool unmaskWord(int wordIndex) {
    final r = _backend.unmaskWord(handle, wordIndex);
    _touch();
    return r;
  }

  /// Hides one word, and adds it to the mask when it is outside it. False when it was hidden
  /// already.
  bool maskWord(int wordIndex) {
    final r = _backend.maskWord(handle, wordIndex);
    _touch();
    return r;
  }

  /// Unhides every word of the mask. The mask stays, so [maskAll] hides them again.
  void unmaskAll() {
    _backend.unmaskAll(handle);
    _touch();
  }

  /// Hides every word of the mask again.
  void maskAll() {
    _backend.maskAll(handle);
    _touch();
  }

  /// Removes the mask, so every word shows, and resets [maskOptions].
  void unmask() {
    _backend.unmask(handle);
    _touch();
  }

  /// The word indices that are hidden now.
  List<int> maskHidden() => _backend.maskHidden(handle);

  /// The word indices the mask covers, hidden or not, in reading order.
  List<int> maskWords() => _backend.maskWords(handle);

  /// Block / blur boxes in layout viewport px (drawn last).
  List<QvpBox> maskBoxesView() => _backend.maskBoxesView(handle);

  // ── Reveal ──

  /// Greyed page with a lit window → steps.
  int revealStart({
    int lit = QvpDefaults.revealLit,
    bool byAyah = false,
    Object grey = QvpDefaults.revealGrey,
    Object ink = QvpDefaults.ink,
    bool ayahMarks = true,
    int ms = 0,
  }) {
    final n = _backend.revealStart(
      handle,
      lit: lit,
      byAyah: byAyah,
      grey: rgba(grey),
      ink: rgba(ink),
      ayahMarks: ayahMarks,
      ms: ms,
    );
    _touch();
    return n;
  }

  /// Lights the window at step [at] (-1 = nothing lit yet).
  bool revealGoto(int at) {
    final ok = _backend.revealGoto(handle, at);
    _touch();
    return ok;
  }

  /// Current step, or null when no reveal is running.
  int? revealPosition() => _backend.revealPosition(handle);

  /// How many steps the running reveal has; 0 when none runs.
  int revealStepCount() => _backend.revealStepCount(handle);

  /// The step that lights word [wordIndex], or -1 when no reveal runs.
  int revealStepOf(int wordIndex) => _backend.revealStepOf(handle, wordIndex);

  /// Ends the reveal and gives the page back its colours.
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

  /// Puts other ornaments on the page, up to one per kind, and returns the readout. Returns
  /// null when the engine refuses the spec: an index out of range, an ornament of another
  /// kind, or nothing to dress. Replaces any previous dress. The printed rings and bands under
  /// the new ornaments are hidden.
  QvpDressInfo? dress(
    QvpOrnaments set, [
    QvpDressSpec spec = const QvpDressSpec(),
  ]) {
    _dressDraws = null;
    final ok = _backend.dress(handle, set.handle, spec);
    _dressSpec = ok ? spec : null;
    _invalidateViewGeometry();
    _touch();
    return ok ? dressInfo() : null;
  }

  /// Takes the ornaments off. The printed rings and bands come back.
  void undress() {
    _backend.undress(handle);
    _dressSpec = null;
    _dressDraws = null;
    _invalidateViewGeometry();
    _touch();
  }

  /// Holds [view] so a drag reaches the border of a dressed page and never goes past it. An
  /// undressed page gets the plain clamp. The viewport is in the same px as the layout's.
  QvpView dressClamp(QvpView view, double viewportW, double viewportH) =>
      _backend.dressClamp(handle, view, viewportW, viewportH);

  /// For a host that scrolls the page itself: the view that shows the dressed box at [scale],
  /// centred across [viewportW] (at x = 0 when wider) with its top at 0, and the box's size at
  /// that scale, which is the size to give the canvas. An undressed page gets its content
  /// centred at the top and the content's size.
  QvpDressView dressView(double scale, double viewportW) =>
      _backend.dressView(handle, scale, viewportW);

  /// The readout, or null when the page is not dressed.
  QvpDressInfo? dressInfo() => _backend.dressInfo(handle);

  /// Counts up whenever the ornament layer is rebuilt: a new dress, or a layout. 0 when the
  /// page is not dressed.
  int dressRevision() => dressInfo()?.revision ?? 0;

  /// The ornament display list in page units. Paint it behind the page ink, each draw under
  /// its [QvpDressDraw.placement] the way a page draw is placed. Kept until the revision
  /// changes.
  List<QvpDressDraw> dressGeometry() {
    final rev = dressRevision();
    final kept = _dressDraws;
    if (kept != null && _dressDrawsRevision == rev) return kept;
    final draws = _backend.dressGeometry(handle);
    _dressDrawsRevision = rev;
    return _dressDraws = draws;
  }

  // ── Crop ──

  /// The box around [target] in page units, [pad] all round, or null when the target has no
  /// words on the page. With [keepAyahMarks], a medallion is inside the box only when the whole
  /// ayah it closes is.
  QvpCropBounds? cropBounds(
    Object target, {
    double pad = QvpDefaults.cropPad,
    bool keepAyahMarks = true,
  }) =>
      _backend.cropBounds(
        handle,
        QvpTarget.of(target),
        pad: pad,
        keepAyahMarks: keepAyahMarks,
      );

  /// Standalone SVG of a target (current colours), or null.
  String? cropSvg(
    Object target, {
    double pad = QvpDefaults.cropPad,
    bool keepAyahMarks = true,
    Object? background,
  }) =>
      _backend.cropSvg(
        handle,
        QvpTarget.of(target),
        pad: pad,
        keepAyahMarks: keepAyahMarks,
        background: background == null ? null : rgba(background),
      );
}

/// How many ticks of [page] moved a colour or a band, the tick that settles them included.
/// The page view keys what it read from the engine on it, so a tick from any caller reaches
/// every view. The package does not export it.
int pageClock(QvpPage page) => page._clock;

import 'dart:ui' show Color, Path, Rect;
import 'package:flutter/foundation.dart';

/// `QVP_NONE`: absent index.
const int qvpNone = 0xffffffff;

// ───────────── enums (ints, so they interoperate with the geometry table) ─────────────

/// `QVP_KIND_*`
abstract final class QvpKind {
  static const int body = 0, mark = 1, ayahNumber = 2, ayahMarkOrnament = 3, headerInk = 4, other = 255;
}

/// `QVP_FAMILY_*`
abstract final class QvpFamily {
  static const int none = 0, diacritic = 1, tanwin = 2, dots = 3, waqf = 4, sifr = 5, sajdah = 6, readingSign = 7;
}

/// `QVP_CATEGORY_*`
abstract final class QvpCategory {
  static const int none = 0, harakah = 1, tanwin = 2, letterDot = 3, orthographic = 4, dabt = 5, waqf = 6, readingSign = 7, standalone = 8;
}

/// `QVP_DECORATION_*`
abstract final class QvpDecorationKind {
  static const int ayahMark = 0, surahName = 1, basmalah = 2, divisionMark = 3, sajdahMark = 4;
}

/// `QVP_FORM_*` — text forms. Strings 'rasmUthmani' | 'rasmImlai' | 'qpc' | 'rasm' | 'search' are accepted everywhere a form is.
abstract final class QvpForm {
  static const int rasmUthmani = 0, rasmImlai = 1, qpc = 2, rasm = 3, search = 4;
  /// Both the Dart spelling and the engine's own `rasm_uthmani` / `rasm_imlai` resolve.
  static const Map<String, int> byName = {
    'rasmUthmani': 0, 'rasm_uthmani': 0,
    'rasmImlai': 1, 'rasm_imlai': 1,
    'qpc': 2, 'rasm': 3, 'search': 4,
  };
  static int of(Object f) => f is int ? f : (byName[f as String] ?? 0);
}

/// `QVP_LAYER_*` — style layers (higher wins).
abstract final class QvpLayer {
  static const int base = 0, theme = 10, highlight = 50, selection = 60, top = 100;
}

/// The defaults every wrapper shares (`QVP_DEFAULT_*` in qvp.h; the parity check compares them).
/// Colours are 0xRRGGBBAA, lengths page units.
abstract final class QvpDefaults {
  static const int ink = 0x231f20ff, highlightInk = 0x1a73e8ff, highlightBand = 0xd6a3264d, selectionBand = 0x2d6fd640, maskBlock = 0xd9d4c8ff, revealGrey = 0xc9c4b8ff;
  static const double highlightPadX = 1.2, highlightPadY = 0, highlightSeam = 0.25, gapBias = 0.6, tapDistance = 6, aspectSlack = 1.15, maskPad = 0.6, maskRadius = 0.8, cropPad = 2, ayahMarkScaleScan = 1.5;
  static const int gridLines = 15, revealLit = 1;
  /// The reader's pinch and swipe: the engine's own limits, which every platform holds to.
  static const double minZoom = 0.5, maxZoom = 12, zoomedThreshold = 1.02;
  static const double swipeAxisRatio = 1.5, swipeDistance = 40, swipeVelocity = 500;
  static const double zoomSnapHysteresis = 0.03, zoomQuantum = 0.01;
  /// How far a justified row's gaps may open, as a multiple of the usual air between two
  /// words: what a reflowed page and a passage stretch to unless the host says otherwise.
  static const double reflowMaxStretch = 2;
}

/// The engine's name tables (`QVP_NAMES_*`), loaded from the engine when a [QvpEngine] opens.
/// No table lives in this package.
abstract final class QvpNames {
  static const int mark = 0, kind = 1, family = 2, category = 3, decoration = 4, division = 5, place = 6;
  static final Map<int, List<String>> _tables = {};

  /// Every name of a table, index = id. Empty until a [QvpEngine] has opened.
  static void setTable(int table, List<String> names) => _tables[table] = names;

  static List<String> of(int table) => _tables[table] ?? const [];

  /// A name's id in a table; 255 when the table has no such name.
  static int idOf(int table, Object v) {
    if (v is int) return v;
    final i = of(table).indexOf(v as String);
    return i < 0 ? 255 : i;
  }
}

/// `QVP_DIVISION_*`
abstract final class QvpDiv {
  static const int juz = 0, hizb = 1, nisf = 2, rubuAlHizb = 3;
  static List<String> get names => QvpNames.of(QvpNames.division);
  static int of(Object k) => k is int ? k : QvpNames.idOf(QvpNames.division, k == 'rubuAlHizb' ? 'rubu_al_hizb' : k);
}

/// Mark ids ↔ names, from the engine. Index = id; 255 = unknown.
abstract final class QvpMark {
  static List<String> get names => QvpNames.of(QvpNames.mark);

  /// Mark id from a name or an id; unknown names → 255.
  static int id(Object m) {
    if (m is int) return m;
    final i = QvpNames.idOf(QvpNames.mark, m);
    return i == 0 ? 255 : i;
  }
}

/// Path opcodes in [QvpPage.ops].
abstract final class QvpOp {
  static const int moveTo = 0, lineTo = 1, quadTo = 2, cubicTo = 3, close = 4;
}

// ───────────── colours ─────────────

/// 0xRRGGBBAA from an int (passed through), a `#rgb` / `#rrggbb` / `#rrggbbaa` string, or a Flutter [Color].
/// [alpha] (0..1) replaces the alpha of 6-digit strings and Colors.
int rgba(Object c, [double? alpha]) {
  if (c is int) return c & 0xffffffff;
  if (c is Color) return QvpColor.fromColor(c, alpha);
  var h = (c as String).trim();
  if (h.startsWith('#')) h = h.substring(1);
  if (h.length == 3 || h.length == 4) h = h.split('').map((x) => x + x).join();
  if (h.length == 6) h += alpha != null ? (alpha * 255).round().clamp(0, 255).toRadixString(16).padLeft(2, '0') : 'ff';
  return int.parse(h, radix: 16) & 0xffffffff;
}

/// 0xRRGGBBAA ↔ Flutter [Color].
abstract final class QvpColor {
  static Color toColor(int rgba) => Color.fromARGB(rgba & 0xff, (rgba >> 24) & 0xff, (rgba >> 16) & 0xff, (rgba >> 8) & 0xff);
  static int fromColor(Color c, [double? alpha]) {
    final a = alpha != null ? (alpha * 255).round().clamp(0, 255) : (c.a * 255).round();
    return (((c.r * 255).round() << 24) | ((c.g * 255).round() << 16) | ((c.b * 255).round() << 8) | a) & 0xffffffff;
  }

  /// CSS-style string `#rrggbbaa`.
  static String hex(int rgba) => '#${rgba.toRadixString(16).padLeft(8, '0')}';
  static int withAlpha(int rgba, double alpha) => (rgba & 0xffffff00) | (alpha * 255).round().clamp(0, 255);
}

// ───────────── selectors & targets ─────────────

/// What a style rule applies to (`QvpSelector`, `QVP_SELECTOR_*`). Build with [Sel].
@immutable
final class QvpSelector {
  const QvpSelector(this.selector, [this.a = 0, this.b = 0, this.c = 0]);
  final int selector, a, b, c;

  int get code => selector;
  int get argA => a;
  int get argB => b;
  int get argC => c;

  @override
  String toString() => 'Sel($selector,$a,$b,$c)';
}

/// Selector constructors (same names as web/qvp.js `Sel`).
abstract final class Sel {
  static QvpSelector page() => const QvpSelector(0);
  static QvpSelector path(int i) => QvpSelector(1, i);
  static QvpSelector wordPath(int w, int n) => QvpSelector(2, w, n);

  /// nth mark of the word (0-based)
  static QvpSelector wordMark(int w, int n) => QvpSelector(3, w, n);
  static QvpSelector wordMarkNamed(int w, Object mark, [int n = 0]) => QvpSelector(4, w, QvpMark.id(mark), n);
  static QvpSelector wordBody(int w) => QvpSelector(5, w);
  static QvpSelector wordMarks(int w) => QvpSelector(6, w);
  static QvpSelector word(int w) => QvpSelector(7, w);
  static QvpSelector ayah(int s, int a) => QvpSelector(8, s, a);
  static QvpSelector line(int n) => QvpSelector(9, n);
  static QvpSelector mark(Object m) => QvpSelector(10, QvpMark.id(m));
  static QvpSelector category(int c) => QvpSelector(11, c);
  static QvpSelector family(int f) => QvpSelector(12, f);
  static QvpSelector kind(int k) => QvpSelector(13, k);
  static QvpSelector decoration(int k) => QvpSelector(14, k);
  static QvpSelector decorationIndex(int i) => QvpSelector(15, i);
}

/// What resolves to a word list (`QvpTarget`, `QVP_TARGET_*`). Build with [T]
/// or pass a string anywhere a target is accepted: 'page', '2:255', '2:255:3',
/// '2:255-257', 'line:7', 'surah:2'. A `List<int>` of word indices is a target too.
@immutable
final class QvpTarget {
  const QvpTarget(this.target, {this.a = 0, this.b = 0, this.c = 0, this.words, this.wordKey});
  final int target, a, b, c;
  final List<int>? words;

  /// Numeric code for the target kind.
  int get code => target;
  int get argA => a;
  int get argB => b;
  int get argC => c;

  /// `[surah, ayah, word]` for the '2:255:3' string form; resolved per page via `findWord`.
  final List<int>? wordKey;

  static QvpTarget parse(String s) {
    if (s == 'page') return T.page();
    RegExpMatch? m;
    if ((m = RegExp(r'^line:(\d+)$').firstMatch(s)) != null) return T.line(int.parse(m!.group(1)!));
    if ((m = RegExp(r'^surah:(\d+)$').firstMatch(s)) != null) return T.surah(int.parse(m!.group(1)!));
    if ((m = RegExp(r'^(\d+):(\d+)-(\d+)$').firstMatch(s)) != null) {
      return T.ayahRange(int.parse(m!.group(1)!), int.parse(m.group(2)!), int.parse(m.group(3)!));
    }
    if ((m = RegExp(r'^(\d+):(\d+):(\d+)$').firstMatch(s)) != null) {
      return QvpTarget(1, wordKey: [int.parse(m!.group(1)!), int.parse(m.group(2)!), int.parse(m.group(3)!)]);
    }
    if ((m = RegExp(r'^(\d+):(\d+)$').firstMatch(s)) != null) return T.ayah(int.parse(m!.group(1)!), int.parse(m.group(2)!));
    throw ArgumentError('bad target $s');
  }

  /// Coerces a String / QvpTarget / `List<int>` to a target.
  static QvpTarget of(Object t) {
    if (t is QvpTarget) return t;
    if (t is String) return parse(t);
    if (t is List<int>) return T.words(t);
    throw ArgumentError('bad target $t');
  }
}

/// Target constructors (same names as web/qvp.js `T`).
abstract final class T {
  static QvpTarget page() => const QvpTarget(0);
  static QvpTarget word(int i) => QvpTarget(1, a: i);
  static QvpTarget words(List<int> ws) => QvpTarget(2, words: ws);
  static QvpTarget ayah(int s, int a) => QvpTarget(3, a: s, b: a);
  static QvpTarget ayahRange(int s, int a, int b) => QvpTarget(4, a: s, b: a, c: b);
  static QvpTarget line(int n) => QvpTarget(5, a: n);
  static QvpTarget surah(int s) => QvpTarget(6, a: s);
  static QvpTarget range(int a, int b) => QvpTarget(7, a: a, b: b);
}

// ───────────── records ─────────────

@immutable
final class QvpWordInfo {
  const QvpWordInfo({
    required this.index,
    required this.surah,
    required this.ayah,
    required this.word,
    required this.line,
    required this.ayahIndex,
    required this.lineIndex,
    required this.x0,
    required this.y0,
    required this.x1,
    required this.y1,
    required this.text,
    required this.firstPath,
    required this.nPaths,
  });
  final int index, surah, ayah, word, line, ayahIndex, lineIndex, firstPath, nPaths;
  final double x0, y0, x1, y1;

  /// `rasm_uthmani`, the text of record (inline in the QVP file).
  final String text;

  /// `surah:ayah:word`
  String get wordKey => '$surah:$ayah:$word';

  /// `surah:ayah`
  String get ayahKey => '$surah:$ayah';
}

@immutable
final class QvpAyahInfo {
  const QvpAyahInfo({
    required this.index,
    required this.surah,
    required this.ayah,
    required this.fragment,
    required this.fragments,
    required this.flags,
    required this.rubuAlHizb,
    required this.firstWord,
    required this.nWords,
    required this.ayahMarkDecoration,
    required this.x0,
    required this.y0,
    required this.x1,
    required this.y1,
  });
  final int index, surah, ayah, fragment, fragments, flags, rubuAlHizb, firstWord, nWords;

  /// Deco index of the ayah mark or [qvpNone].
  final int ayahMarkDecoration;
  final double x0, y0, x1, y1;
}

@immutable
final class QvpLineInfo {
  const QvpLineInfo({
    required this.index,
    required this.lineNumber,
    required this.isHeader,
    required this.firstWord,
    required this.nWords,
    required this.x0,
    required this.y0,
    required this.x1,
    required this.y1,
    required this.bandY0,
    required this.bandY1,
    required this.centre,
  });
  final int index, lineNumber, firstWord, nWords;
  final bool isHeader;
  final double x0, y0, x1, y1, bandY0, bandY1, centre;
}

@immutable
final class QvpDecorationInfo {
  const QvpDecorationInfo({
    required this.index,
    required this.decoration,
    required this.surah,
    required this.ayah,
    required this.line,
    required this.x0,
    required this.y0,
    required this.x1,
    required this.y1,
    required this.text,
    required this.firstPath,
    required this.nPaths,
  });
  final int index, decoration, surah, ayah, line, firstPath, nPaths;
  final double x0, y0, x1, y1;
  final String text;
}

/// The one hit shape for every hit test (`QvpHit`); the exact variants report distance 0 and
/// `isExact`. Indices are -1 when absent.
@immutable
final class QvpHit {
  const QvpHit({required this.word, required this.path, required this.decoration, required this.line, required this.distance, required this.isExact, this.wordKey, this.ayahKey});
  final int word, path, decoration, line;
  final double distance;
  final bool isExact;
  final String? wordKey, ayahKey;
  @override
  String toString() => 'QvpHit(word: $word, path: $path, decoration: $decoration, line: $line, distance: $distance, isExact: $isExact)';
}

/// Options of the gap-aware hit test.
@immutable
final class QvpHitOptions {
  const QvpHitOptions({this.maxDistance = 0, this.gapBias = QvpDefaults.gapBias, this.preferExact = true});

  /// Page units; <= 0 unlimited.
  final double maxDistance;
  final double gapBias;
  final bool preferExact;
}

/// A band / mask box in layout viewport px (`QvpBox`).
@immutable
final class QvpBox {
  const QvpBox({required this.id, required this.line, required this.x0, required this.y0, required this.x1, required this.y1, required this.color, required this.radius});
  final int id, line, color;
  final double x0, y0, x1, y1, radius;
}

@immutable
final class QvpHitArea {
  const QvpHitArea({required this.word, required this.line, required this.x0, required this.y0, required this.x1, required this.y1, required this.inkX0, required this.inkY0, required this.inkX1, required this.inkY1});
  final int word, line;
  final double x0, y0, x1, y1, inkX0, inkY0, inkX1, inkY1;
}

@immutable
final class QvpLineBand {
  const QvpLineBand({required this.line, required this.lineNumber, required this.y0, required this.y1, required this.mid, required this.inkY0, required this.inkY1});
  final int line, lineNumber;
  final double y0, y1, mid, inkY0, inkY1;
}

/// Input of [QvpPage.layout]; lengths in viewport px. Spacing only opens up:
/// `lineSpacing` < 1 is clamped by the engine. `gridLines` 0 = the page's own grid.
@immutable
/// How a page reflows when the reader zooms in: the ink grows, fewer words fit a row, the rest
/// move down and the page scrolls. Every field but [zoom] is a typographic knob with a default
/// the engine chose; a reader's control only ever moves [zoom].
@immutable
final class QvpReflowSpec {
  const QvpReflowSpec({
    this.zoom = 1,
    this.fill = 'centred',
    this.breaks = 'fitted',
    this.gaps = 'uniform',
    this.wordGap = 1,
    this.maxStretch = QvpDefaults.reflowMaxStretch,
    this.relax = 0.5,
  });

  /// 1 or less is the printed page; [QvpPage.zoomSpec] hands back 0 there, as the C header
  /// does. The largest this page can reach is [QvpPage.reflowMaxZoom].
  final double zoom;
  /// `ragged` | `justified` | `centred`; `greedy` | `even` | `fitted` | `printed`; `printed` | `uniform`.
  final String fill, breaks, gaps;
  final double wordGap, maxStretch, relax;

  int get fillCode => switch (fill) {
        'ragged' => 0,
        'justified' => 1,
        'centred' || 'centered' => 2,
        _ => 255,
      };

  int get breaksCode => switch (breaks) {
        'greedy' => 0,
        'even' => 1,
        'fitted' => 2,
        'printed' => 3,
        _ => 255,
      };

  int get gapsCode => gaps == 'printed' ? 0 : 1;

  QvpReflowSpec copyWith({
    double? zoom,
    String? fill,
    String? breaks,
    String? gaps,
    double? wordGap,
    double? maxStretch,
    double? relax,
  }) =>
      QvpReflowSpec(
        zoom: zoom ?? this.zoom,
        fill: fill ?? this.fill,
        breaks: breaks ?? this.breaks,
        gaps: gaps ?? this.gaps,
        wordGap: wordGap ?? this.wordGap,
        maxStretch: maxStretch ?? this.maxStretch,
        relax: relax ?? this.relax,
      );

  @override
  bool operator ==(Object other) =>
      other is QvpReflowSpec &&
      other.zoom == zoom &&
      other.fill == fill &&
      other.breaks == breaks &&
      other.gaps == gaps &&
      other.wordGap == wordGap &&
      other.maxStretch == maxStretch &&
      other.relax == relax;

  @override
  int get hashCode => Object.hash(zoom, fill, breaks, gaps, wordGap, maxStretch, relax);
}

/// What a pinch does to the page.
enum QvpZoomMode {
  /// The pinch lands on the page's own zoom steps and the page reflows onto one. The default:
  /// a reader never ends up at a zoom that breaks the page badly.
  stepped,

  /// The pinch drives the reflow zoom freely, between the printed page and [QvpPage.reflowMaxZoom].
  continuous,

  /// The pinch scales the printed page as it is. The rows never change.
  magnify,
}

/// Where the reader's zoom control stands. A host keeps this beside its [QvpView]; all zero is
/// the default control, stepped and on the printed page.
@immutable
final class QvpZoom {
  const QvpZoom({this.mode = QvpZoomMode.stepped, this.step = 0, this.zoom = 1});

  final QvpZoomMode mode;

  /// 0 is the printed page, 1 upwards the page's own steps. What [QvpZoomMode.stepped] reads.
  final int step;

  /// The size in force, 1 at the printed page, whichever field the mode steers by.
  final double zoom;

  @override
  bool operator ==(Object other) => other is QvpZoom && other.mode == mode && other.step == step && other.zoom == zoom;

  @override
  int get hashCode => Object.hash(mode, step, zoom);
}

/// A point `p` draws at `offset + scale · p`. The reader's pan and zoom, which the engine moves.
@immutable
final class QvpView {
  const QvpView({this.scale = 1, this.offsetX = 0, this.offsetY = 0});
  final double scale, offsetX, offsetY;

  @override
  bool operator ==(Object other) =>
      other is QvpView && other.scale == scale && other.offsetX == offsetX && other.offsetY == offsetY;

  @override
  int get hashCode => Object.hash(scale, offsetX, offsetY);
}

/// What a gesture produced: the control to keep, the view to draw with, and whether the page was
/// laid out again under it.
@immutable
final class QvpZoomChange {
  const QvpZoomChange({required this.zoom, required this.view, required this.relaid});
  final QvpZoom zoom;
  final QvpView view;
  final bool relaid;
}

/// What a sideways drag means on the page in hand.
enum QvpSideways { pan, turnPage }

/// Where a group of paths is drawn: `x' = kx · x + dx`, `y' = ky · y + dy`, in page units.
@immutable
final class QvpPlacement {
  const QvpPlacement(this.dx, this.dy, this.kx, this.ky);
  static const identity = QvpPlacement(0, 0, 1, 1);
  final double dx, dy, kx, ky;
}

/// One stroke of a layout: the path to draw, under the placement of that index.
@immutable
final class QvpDraw {
  const QvpDraw(this.path, this.placement);
  final int path, placement;
}

final class QvpLayoutSpec {
  const QvpLayoutSpec({
    this.viewportW = 0,
    this.viewportH = 0,
    this.padTop = 0,
    this.padBottom = 0,
    this.padLeft = 0,
    this.padRight = 0,
    this.lineSpacing = 1,
    this.fillHeight = false,
    this.gridLines = 0,
    this.cropLeft = 0,
    this.cropRight = 0,
    this.maxAspectSlack = 0,
    this.reflow,
    this.bannerZoom = 0,
    this.surahFrames = true,
  });
  final double viewportW, viewportH, padTop, padBottom, padLeft, padRight, lineSpacing;

  /// Reflow the page onto rows of the viewport's own width, or null for the printed page.
  /// The reader's zoom control writes this: see [QvpPage.zoomSpec].
  final QvpReflowSpec? reflow;
  final bool fillHeight;
  final int gridLines;

  /// Printed side margins to cut, in page units (0 = keep the print's margins).
  final double cropLeft, cropRight;

  /// The content is never wider than `viewportH · pageW / pageH · maxAspectSlack` (0 = no bound).
  final double maxAspectSlack;

  /// How big a banner — a surah name, a basmalah — may get as the reader zooms in, as a
  /// multiple of its PRINTED size. 0 leaves it uncapped: the drawing grows with the words
  /// around it until it fills the row. 1 holds it at the printed size however far the reader
  /// zooms, which is what a host drawing its own frame around the name wants.
  ///
  /// It sits here and not on [reflow] because it must survive the zoom control: a host that
  /// pinches never builds a [QvpReflowSpec] itself — [QvpPage.zoomSpec] does, from this spec.
  final double bannerZoom;

  /// Draw source-native frames around surah names on the printed page. Reflow stays frameless.
  final bool surahFrames;

  double get reflowZoomValue => reflow?.zoom ?? 0;
  int get reflowFillCode => reflow?.fillCode ?? 255;
  int get reflowBreaksCode => reflow?.breaksCode ?? 255;
  int get reflowGapsCode => reflow?.gapsCode ?? 1;
  double get reflowWordGapValue => reflow?.wordGap ?? 1;
  double get reflowMaxStretchValue => reflow?.maxStretch ?? 0;
  double get reflowRelaxValue => reflow?.relax ?? -1;

  QvpLayoutSpec copyWith({
    double? viewportW,
    double? viewportH,
    double? padTop,
    double? padBottom,
    double? padLeft,
    double? padRight,
    double? lineSpacing,
    bool? fillHeight,
    int? gridLines,
    double? cropLeft,
    double? cropRight,
    double? maxAspectSlack,
    QvpReflowSpec? reflow,
    double? bannerZoom,
    bool? surahFrames,
  }) =>
      QvpLayoutSpec(
        viewportW: viewportW ?? this.viewportW,
        viewportH: viewportH ?? this.viewportH,
        padTop: padTop ?? this.padTop,
        padBottom: padBottom ?? this.padBottom,
        padLeft: padLeft ?? this.padLeft,
        padRight: padRight ?? this.padRight,
        lineSpacing: lineSpacing ?? this.lineSpacing,
        fillHeight: fillHeight ?? this.fillHeight,
        gridLines: gridLines ?? this.gridLines,
        cropLeft: cropLeft ?? this.cropLeft,
        cropRight: cropRight ?? this.cropRight,
        maxAspectSlack: maxAspectSlack ?? this.maxAspectSlack,
        reflow: reflow ?? this.reflow,
        bannerZoom: bannerZoom ?? this.bannerZoom,
        surahFrames: surahFrames ?? this.surahFrames,
      );

  @override
  bool operator ==(Object other) =>
      other is QvpLayoutSpec &&
      other.viewportW == viewportW &&
      other.viewportH == viewportH &&
      other.padTop == padTop &&
      other.padBottom == padBottom &&
      other.padLeft == padLeft &&
      other.padRight == padRight &&
      other.lineSpacing == lineSpacing &&
      other.fillHeight == fillHeight &&
      other.gridLines == gridLines &&
      other.cropLeft == cropLeft &&
      other.cropRight == cropRight &&
      other.maxAspectSlack == maxAspectSlack &&
      other.reflow == reflow &&
      other.bannerZoom == bannerZoom &&
      other.surahFrames == surahFrames;

  @override
  int get hashCode => Object.hash(viewportW, viewportH, padTop, padBottom, padLeft, padRight, lineSpacing, fillHeight, gridLines, cropLeft,
      cropRight, maxAspectSlack, reflow, bannerZoom, surahFrames);
}

/// Output of [QvpPage.layout]. Page → viewport: `viewX = offsetX + x*scale`, `viewY = offsetY + (y + lineDy[line])*scale`.
@immutable
final class QvpLayout {
  const QvpLayout({required this.scale, required this.offsetX, required this.offsetY, required this.contentW, required this.contentH, required this.lineSpacing, required this.lineDy, required this.slots, this.fitScale = 1, this.fitX = 0, this.fitY = 0, this.reflowed = false, this.rows = 0});
  final double scale, offsetX, offsetY, contentW, contentH, lineSpacing;

  /// Whether the page was reflowed onto rows of the viewport's width, and how many rows it made.
  /// When it was, [lineDy] and [slots] describe the rows rather than the printed lines.
  final bool reflowed;
  final int rows;

  /// The view transform that shows the whole content in the viewport (shrink to height, never
  /// enlarge, centred). The host's pan and zoom go on top.
  final double fitScale, fitX, fitY;

  /// Per-line vertical shift in page units (index = line record index).
  final Float32List lineDy;

  /// Per-line `(top, bottom)` slot in viewport px.
  final List<(double, double)> slots;
}

/// One highlight description. Colours accept anything [rgba] does.
@immutable
final class QvpHighlightStyle {
  const QvpHighlightStyle({
    this.mode = 'band',
    this.height = 'lineSpacing',
    this.ink = QvpDefaults.highlightInk,
    this.band = QvpDefaults.highlightBand,
    this.padX = QvpDefaults.highlightPadX,
    this.padY = 0,
    this.radius = 0,
    this.seam = QvpDefaults.highlightSeam,
    this.ms = 0,
    this.layer = QvpLayer.highlight,
  });

  /// 'ink' | 'band' | 'both'
  final String mode;

  /// 'lineSpacing' | 'ink'
  final String height;
  final Object ink, band;
  final double padX, padY, radius, seam;
  final int ms, layer;

  int get modeCode => switch (mode) {
        'ink' => 0,
        'both' => 2,
        _ => 1,
      };

  int get heightCode => height == 'ink' ? 1 : 0;
  int get inkRgba => rgba(ink);
  int get bandRgba => rgba(band);
}

/// A theme: every colour is optional (0 / null = leave alone); `marks` maps mark name or id → colour.
@immutable
final class QvpTheme {
  const QvpTheme({this.ink, this.diacritics, this.dots, this.waqf, this.sifr, this.ayahMark, this.numeral, this.headers, this.marks = const {}, this.ms = 0});
  final Object? ink, diacritics, dots, waqf, sifr, ayahMark, numeral, headers;
  final Map<Object, Object> marks;
  final int ms;
}

@immutable
final class QvpSurah {
  const QvpSurah({required this.number, required this.ayahCount, required this.hasBanner, required this.hasBasmalah, required this.place, required this.bannerDecoration, required this.arabic, required this.latin, required this.english});
  final int number, ayahCount, bannerDecoration;
  final bool hasBanner, hasBasmalah;

  /// 'makkah' | 'madinah' | ''
  final String place, arabic, latin, english;
}

@immutable
final class QvpDivision {
  const QvpDivision({required this.division, required this.line, required this.number, required this.surah, required this.ayah, required this.ayahIndex});

  /// 'juz' | 'hizb' | 'nisf' | 'rubuAlHizb'
  final String division;
  final int line, number, surah, ayah, ayahIndex;
}

@immutable
final class QvpSurahHeader {
  const QvpSurahHeader({required this.decoration, required this.surah, required this.line, required this.x0, required this.y0, required this.x1, required this.y1, required this.titleX0, required this.titleY0, required this.titleX1, required this.titleY1});
  final int decoration, surah, line;

  /// The box a frame fills: the page's text block wide, the heading's row tall.
  final double x0, y0, x1, y1;

  /// The title ink inside that box, with any native frame left out.
  final double titleX0, titleY0, titleX1, titleY1;
}

@immutable
final class QvpAyahMark {
  const QvpAyahMark({required this.decoration, required this.surah, required this.ayah, required this.line, required this.cx, required this.cy, required this.r, required this.ornamentPath, required this.numeralPath});
  final int decoration, surah, ayah, line, ornamentPath, numeralPath;
  final double cx, cy, r;
}

@immutable
final class QvpRosette {
  const QvpRosette({required this.decoration, required this.surah, required this.ayah, required this.juz, required this.hizb, required this.nisf, required this.rubuAlHizb, required this.rubuAlHizbInHizb});
  final int decoration, surah, ayah, juz, hizb, nisf, rubuAlHizb, rubuAlHizbInHizb;
}

@immutable
final class QvpSajdah {
  const QvpSajdah({required this.decoration, required this.surah, required this.ayah, required this.signPath});
  final int decoration, surah, ayah, signPath;
}

@immutable
final class QvpMatch {
  const QvpMatch({
    required this.word,
    required this.index,
    required this.isLooseMatch,
    this.wordKey = '',
    this.text = '',
  });
  final int word, index;
  final bool isLooseMatch;
  final String wordKey, text;
}

@immutable
final class QvpCropBounds {
  const QvpCropBounds({required this.x0, required this.y0, required this.x1, required this.y1, required this.nWords, required this.ayahMarkDecoration});
  final double x0, y0, x1, y1;
  final int nWords, ayahMarkDecoration;
}

@immutable
final class QvpAtlasSurah {
  const QvpAtlasSurah({required this.number, required this.page, required this.ayahCount, required this.place, required this.arabic, required this.latin, required this.english});
  final int number, page, ayahCount;
  final String place, arabic, latin, english;
}

@immutable
final class QvpAtlasRubuAlHizb {
  const QvpAtlasRubuAlHizb({required this.rubuAlHizb, required this.surah, required this.ayah, required this.page});
  final int rubuAlHizb, surah, ayah, page;
  String get ayahKey => '$surah:$ayah';
}

/// One entry of [QvpPage.styled].
typedef QvpStyledPath = ({int path, int color});

// ───────────── dress: another mushaf's ornaments ─────────────

/// What an ornament replaces. The order is `QVP_ORNAMENT_*`.
enum QvpOrnamentKind {
  /// The medallion that closes an ayah.
  ayahMark,

  /// The band that carries a surah's name.
  surahHeader,

  /// The border around the page.
  pageFrame,
}

/// Where an ornament's artwork came from. The order is `QVP_LINEAGE_*`.
enum QvpLineage {
  /// A printed mushaf, traced from a scan.
  scan,

  /// A font.
  font,
}

/// What an ornament may be redistributed under. Read it before you publish a page wearing it.
@immutable
final class QvpOrnamentLicence {
  const QvpOrnamentLicence({required this.id, required this.status, required this.redistributable, required this.attribution});

  /// An SPDX id, or empty when the source does not state one.
  final String id;

  /// How sure the catalogue is of [id].
  final String status;
  final bool redistributable;
  final String attribution;
}

/// One printed colour of an ornament's design. A part with alpha 0 is a window the design
/// leaves open (its slot).
@immutable
final class QvpOrnamentPart {
  const QvpOrnamentPart({required this.index, required this.color, required this.stroke, required this.name});
  final int index;

  /// 0xRRGGBBAA.
  final int color;

  /// True for a line-art part, drawn as constant-width strokes.
  final bool stroke;
  final String name;
}

/// One ornament of a [QvpOrnaments] set.
@immutable
final class QvpOrnament {
  const QvpOrnament({
    required this.index,
    required this.kind,
    required this.lineage,
    required this.style,
    required this.riwayah,
    required this.hasSlices,
    required this.licence,
    required this.parts,
  });

  /// Its index in the set, which is what [QvpDressInfo] reports.
  final int index;
  final QvpOrnamentKind kind;
  final QvpLineage lineage;

  /// The mushaf or font it comes from.
  final String style;
  final String riwayah;

  /// True when a border can be tiled along the edges. Without slices it keeps its printed
  /// proportions.
  final bool hasSlices;
  final QvpOrnamentLicence licence;

  /// The design's printed palette, one entry per colour.
  final List<QvpOrnamentPart> parts;
}

/// A style of a [QvpOrnaments] set, with the ornament it has of each kind or null.
@immutable
final class QvpOrnamentStyle {
  const QvpOrnamentStyle({required this.style, required this.riwayah, required this.lineage, this.ayahMark, this.surahHeader, this.pageFrame});
  final String style, riwayah;
  final QvpLineage lineage;
  final QvpOrnament? ayahMark, surahHeader, pageFrame;

  /// The ornament of [kind], or null.
  QvpOrnament? of(QvpOrnamentKind kind) => switch (kind) {
        QvpOrnamentKind.ayahMark => ayahMark,
        QvpOrnamentKind.surahHeader => surahHeader,
        QvpOrnamentKind.pageFrame => pageFrame,
      };

  /// True when the style has all three kinds, so it can dress a page on its own.
  bool get isComplete => ayahMark != null && surahHeader != null && pageFrame != null;
}

/// What [QvpPage.dress] puts on the page. [style] names a mushaf and takes its medallion,
/// band and border together. Each of [ayahMark], [surahHeader] and [pageFrame] is a
/// [QvpOrnament], its index, or a style name, and overrides [style] for that kind. Lengths are
/// page units.
@immutable
final class QvpDressSpec {
  const QvpDressSpec({
    this.style,
    this.ayahMark,
    this.surahHeader,
    this.pageFrame,
    this.gap = 5,
    this.bandGap = 5,
    this.ayahMarkScale = 0,
    this.pageFrameScale = 1,
    this.lineArt = const {},
    this.colors = const [],
  });

  /// A mushaf whose three ornaments are taken together.
  final String? style;

  /// A [QvpOrnament], its index or a style name. Null takes [style].
  final Object? ayahMark, surahHeader, pageFrame;

  /// The air between the text and the border.
  final double gap;

  /// The air between a band and the border.
  final double bandGap;

  /// The medallion's size against the printed ring. 0 takes the design's own:
  /// [QvpDefaults.ayahMarkScaleScan] for a scanned mushaf and 1 for a font marker.
  final double ayahMarkScale;

  /// The border's size against the design's own. The pattern scales as a whole, so a bigger
  /// border fits fewer motifs along each edge. Nothing is stretched.
  final double pageFrameScale;

  /// The kinds drawn as line art, their constant-width strokes alone. Pass
  /// `QvpOrnamentKind.values.toSet()` for all of them.
  final Set<QvpOrnamentKind> lineArt;

  /// Repaints: `(ornament, part, colour)`. The ornament is a [QvpOrnament] or its index, and the
  /// colour is anything [rgba] takes. A part left out keeps the design's own colour.
  final List<(Object, int, Object)> colors;

  QvpDressSpec copyWith({
    Object? ayahMark = _keep,
    Object? surahHeader = _keep,
    Object? pageFrame = _keep,
    double? gap,
    double? bandGap,
    double? ayahMarkScale,
    double? pageFrameScale,
    Set<QvpOrnamentKind>? lineArt,
    List<(Object, int, Object)>? colors,
  }) =>
      QvpDressSpec(
        style: style,
        ayahMark: identical(ayahMark, _keep) ? this.ayahMark : ayahMark,
        surahHeader: identical(surahHeader, _keep) ? this.surahHeader : surahHeader,
        pageFrame: identical(pageFrame, _keep) ? this.pageFrame : pageFrame,
        gap: gap ?? this.gap,
        bandGap: bandGap ?? this.bandGap,
        ayahMarkScale: ayahMarkScale ?? this.ayahMarkScale,
        pageFrameScale: pageFrameScale ?? this.pageFrameScale,
        lineArt: lineArt ?? this.lineArt,
        colors: colors ?? this.colors,
      );

  int get lineArtBits => lineArt.fold(0, (acc, k) => acc | (1 << k.index));

  static const Object _keep = Object();
}

/// The readout of a dressed page.
@immutable
final class QvpDressInfo {
  const QvpDressInfo({
    required this.ayahMark,
    required this.surahHeader,
    required this.pageFrame,
    required this.ayahMarks,
    required this.surahHeaders,
    required this.frameRepeats,
    required this.frameStretched,
    required this.draws,
    required this.revision,
    required this.viewBox,
    required this.overflow,
  });

  /// The ornament index of each kind on the page, or null.
  final int? ayahMark, surahHeader, pageFrame;

  /// How many medallions and bands were placed.
  final int ayahMarks, surahHeaders;

  /// How many times the border's repeat was tiled. 0 when it is stretched.
  final int frameRepeats;

  /// True when the border has no slices and is stretched whole.
  final bool frameStretched;

  /// How many entries [QvpPage.dressGeometry] holds.
  final int draws;

  /// Counts up on every rebuild: a new dress, and every layout. Key an ornament raster on it.
  final int revision;

  /// `x, y, w, h` in page units. A border grows it.
  final List<double> viewBox;

  /// `left, top, right, bottom` in viewport px: how far the border reaches past the laid-out
  /// content. Fit content plus overflow, or the border is cropped off.
  final List<double> overflow;
}

/// [QvpPage.dressView]: the view for a host that scrolls the page, and the dressed box's size.
@immutable
final class QvpDressView {
  const QvpDressView({required this.view, required this.width, required this.height});

  /// Shows the dressed box with its top at 0, centred across the viewport.
  final QvpView view;

  /// The dressed box at the asked scale, in viewport px: the size to give the canvas.
  final double width, height;
}

/// One entry of the ornament display list, in page units. Paint it behind the page ink.
@immutable
final class QvpDressDraw {
  const QvpDressDraw({required this.path, required this.color, required this.kind, required this.evenOdd, required this.stroke, required this.strokeWidth, required this.part, required this.placement});

  /// The outline, with the fill rule already set.
  final Path path;

  /// 0xRRGGBBAA.
  final int color;
  final QvpOrnamentKind kind;
  final bool evenOdd;

  /// True to stroke the path with [strokeWidth], round caps and round joins. False to fill it.
  final bool stroke;

  /// Page units.
  final double strokeWidth;

  /// The part of the ornament's palette it draws.
  final int part;

  /// The index into [QvpPage.layoutPlacements] to draw it under, as a page draw. Null for the
  /// border, which is drawn in layout space.
  final int? placement;
}

// ───────────── passage ─────────────

/// Where the rows of a passage start. The order is `QVP_ALIGN_*`.
enum QvpPassageAlign {
  /// At the right edge, as Arabic text starts.
  right,

  /// In the middle of the width.
  center,

  /// Across the width.
  justified,
}

/// What a layout of a passage asks for. Lengths are layout px.
@immutable
final class QvpPassageSpec {
  /// The defaults put the passage on one row at the printed size.
  const QvpPassageSpec({
    this.width = 0,
    this.scale = 1,
    this.lineSpacing = 1,
    this.padding = 2,
    this.align = QvpPassageAlign.right,
    this.maxRows = 0,
    this.keepAyahMark = false,
    this.ellipsisWidth = 0,
    this.maxStretch = QvpDefaults.reflowMaxStretch,
  });

  final double width;
  final double scale;
  final double lineSpacing;
  final double padding;
  final QvpPassageAlign align;
  final int maxRows;
  final bool keepAyahMark;
  final double ellipsisWidth;
  final double maxStretch;

  int get alignCode => align.index;

  @override
  bool operator ==(Object other) =>
      other is QvpPassageSpec &&
      other.width == width &&
      other.scale == scale &&
      other.lineSpacing == lineSpacing &&
      other.padding == padding &&
      other.align == align &&
      other.maxRows == maxRows &&
      other.keepAyahMark == keepAyahMark &&
      other.ellipsisWidth == ellipsisWidth &&
      other.maxStretch == maxStretch;

  @override
  int get hashCode => Object.hash(width, scale, lineSpacing, padding, align, maxRows, keepAyahMark, ellipsisWidth, maxStretch);
}

/// One ayah of a passage, with its text from the page's own word records.
@immutable
final class QvpPassageText {
  const QvpPassageText({required this.surah, required this.ayah, required this.text});
  final int surah, ayah;
  final String text;

  /// `surah:ayah`
  String get ayahKey => '$surah:$ayah';
}

/// One row of a laid-out passage, in layout px: the box of the row's ink, and the height its
/// words sit on.
@immutable
final class QvpPassageRow {
  const QvpPassageRow({required this.x0, required this.y0, required this.x1, required this.y1, required this.baseline});
  final double x0, y0, x1, y1, baseline;
}

/// One word of a laid-out passage with the signs that go with it, in layout px.
@immutable
final class QvpPassageWord {
  const QvpPassageWord({
    required this.surah,
    required this.ayah,
    required this.word,
    required this.page,
    required this.row,
    required this.x0,
    required this.y0,
    required this.x1,
    required this.y1,
    required this.wordX0,
    required this.wordY0,
    required this.wordX1,
    required this.wordY1,
  });

  final int surah, ayah, word, page, row;
  final double x0, y0, x1, y1, wordX0, wordY0, wordX1, wordY1;

  /// `surah:ayah:word`
  String get wordKey => '$surah:$ayah:$word';
}

/// The bounds of one ayah that a layout shows, in layout px.
@immutable
final class QvpPassageAyah {
  const QvpPassageAyah({required this.surah, required this.ayah, required this.x0, required this.y0, required this.x1, required this.y1});
  final int surah, ayah;
  final double x0, y0, x1, y1;
}

/// One path that a passage layout draws: its page, its index on that page, and which of
/// [QvpPassageLayout.placements] it goes under.
@immutable
final class QvpPassageDraw {
  const QvpPassageDraw(this.page, this.path, this.placement);
  final int page, path, placement;
}

/// A laid-out passage.
@immutable
final class QvpPassageLayout {
  const QvpPassageLayout({
    required this.width,
    required this.height,
    required this.scale,
    required this.lineSpacing,
    required this.rows,
    required this.words,
    required this.ayahs,
    required this.draws,
    required this.placements,
    required this.isTruncated,
    required this.ellipsis,
  });

  final double width, height, scale, lineSpacing;
  final List<QvpPassageRow> rows;
  final List<QvpPassageWord> words;
  final List<QvpPassageAyah> ayahs;
  final List<QvpPassageDraw> draws;
  final List<QvpPlacement> placements;
  final bool isTruncated;
  final Rect? ellipsis;
}

/// Decodes QVP curve opcodes into [path]. Shared by page path caching and dress geometry.
void decodeQvpPath(Path path, Uint8List ops, int opStart, int opCount, Float32List pts, int ptStart) {
  var o = opStart;
  final oe = opStart + opCount;
  var k = ptStart;
  for (; o < oe; o++) {
    switch (ops[o]) {
      case QvpOp.moveTo:
        path.moveTo(pts[k], pts[k + 1]);
        k += 2;
      case QvpOp.lineTo:
        path.lineTo(pts[k], pts[k + 1]);
        k += 2;
      case QvpOp.quadTo:
        path.quadraticBezierTo(pts[k], pts[k + 1], pts[k + 2], pts[k + 3]);
        k += 4;
      case QvpOp.cubicTo:
        path.cubicTo(pts[k], pts[k + 1], pts[k + 2], pts[k + 3], pts[k + 4], pts[k + 5]);
        k += 6;
      case QvpOp.close:
        path.close();
    }
  }
}



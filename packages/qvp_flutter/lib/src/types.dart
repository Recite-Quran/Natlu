// Plain data types of the Dart API: the structs the engine reads back, and the specs it takes.
import 'dart:ui' show Color, Path, Rect;

import 'package:flutter/foundation.dart';

/// `QVP_NONE`: absent index.
const int qvpNone = 0xffffffff;

// ───────────── enums (ints, so they interoperate with the geometry table) ─────────────

/// `QVP_KIND_*`
abstract final class QvpKind {
  /// The path kinds. [body] is a letter's body and [mark] a mark on a word. [ayahNumber]
  /// is the numeral in an ayah mark, and [ayahMarkOrnament] the ring around it.
  /// [headerInk] is the ink of a surah header, and [ornament] a printed ornament, such as
  /// the frame around a surah name. [pageNumber] is the printed page number, and [runningHead] the surah name and
  /// juz printed above the page. [other] is a path the source did not classify.
  static const int body = 0,
      mark = 1,
      ayahNumber = 2,
      ayahMarkOrnament = 3,
      headerInk = 4,
      ornament = 5,
      pageNumber = 6,
      runningHead = 7,
      other = 255;
}

/// `QVP_FAMILY_*`
abstract final class QvpFamily {
  /// The families: [none] for a path that is not a mark, then [diacritic], [tanwin], [dots],
  /// [waqf], [sifr], [sajdah] and [readingSign] as the source classes them.
  static const int none = 0,
      diacritic = 1,
      tanwin = 2,
      dots = 3,
      waqf = 4,
      sifr = 5,
      sajdah = 6,
      readingSign = 7;
}

/// `QVP_CATEGORY_*`
abstract final class QvpCategory {
  /// The categories of the mark taxonomy: [none] for a path that is not a mark, then
  /// [harakah], [tanwin], [letterDot], [orthographic], [dabt], [waqf], [readingSign] and
  /// [standalone].
  static const int none = 0,
      harakah = 1,
      tanwin = 2,
      letterDot = 3,
      orthographic = 4,
      dabt = 5,
      waqf = 6,
      readingSign = 7,
      standalone = 8;
}

/// `QVP_DECORATION_*`
abstract final class QvpDecorationKind {
  /// The decoration kinds: an ayah mark, a surah name, the basmalah, a division mark, a
  /// sajdah mark, the printed page number and the running head. [other] is a decoration
  /// the source did not classify.
  static const int ayahMark = 0,
      surahName = 1,
      basmalah = 2,
      divisionMark = 3,
      sajdahMark = 4,
      pageNumber = 5,
      runningHead = 6,
      other = 255;
}

/// `QVP_FORM_*` — text forms. Strings 'rasmUthmani' | 'rasmImlai' | 'qpc' | 'rasm' | 'search' are accepted everywhere a form is.
abstract final class QvpForm {
  /// The forms: [rasmUthmani] is the text of record, in the page file. [rasmImlai], [qpc],
  /// [rasm] and [search] come from the words sidecar ([QvpPage.attachWords]).
  static const int rasmUthmani = 0,
      rasmImlai = 1,
      qpc = 2,
      rasm = 3,
      search = 4;

  /// Both the Dart spelling and the engine's own `rasm_uthmani` / `rasm_imlai` resolve.
  static const Map<String, int> byName = {
    'rasmUthmani': 0,
    'rasm_uthmani': 0,
    'rasmImlai': 1,
    'rasm_imlai': 1,
    'qpc': 2,
    'rasm': 3,
    'search': 4,
  };

  /// The form code of [f]: an int passes through, a name resolves through [byName], and an
  /// unknown name is [rasmUthmani].
  static int of(Object f) => f is int ? f : (byName[f as String] ?? 0);
}

/// `QVP_LAYER_*` — style layers (higher wins).
abstract final class QvpLayer {
  /// The named layers. A rule on a higher layer wins over one on a lower layer.
  static const int base = 0,
      theme = 10,
      highlight = 50,
      selection = 60,
      top = 100;
}

/// The defaults every wrapper shares (`QVP_DEFAULT_*` in qvp.h; the parity check compares them).
/// Colours are 0xRRGGBBAA, lengths page units.
abstract final class QvpDefaults {
  /// The colours, 0xRRGGBBAA: the page ink, a highlight's ink and band, the selection band, a
  /// mask block and the grey of a reveal.
  static const int ink = 0x231f20ff,
      highlightInk = 0x1a73e8ff,
      highlightBand = 0xd6a3264d,
      selectionBand = 0x2d6fd640,
      maskBlock = 0xd9d4c8ff,
      revealGrey = 0xc9c4b8ff;

  /// The pads, the seam, [tapDistance], [maskPad], [maskRadius] and [cropPad] are page
  /// units. The others are ratios. [gapBias] is the share of a gap the hit test gives the
  /// word before it. [aspectSlack] bounds how wide a view's content gets.
  /// [ayahMarkScaleScan] is a scanned medallion's size in a dress, against the printed ring.
  static const double highlightPadX = 1.2,
      highlightPadY = 0,
      highlightSeam = 0.25,
      selectionPadX = 0.6,
      gapBias = 0.6,
      tapDistance = 6,
      aspectSlack = 1.15,
      maskPad = 0.6,
      maskRadius = 0.8,
      cropPad = 2,
      ayahMarkScaleScan = 1.5;

  /// The lines of a mushaf page's grid, and how many steps a reveal lights at once.
  static const int gridLines = 15, revealLit = 1;

  /// The reader's pinch and swipe: the engine's own limits, which every platform holds to.
  static const double minZoom = 0.5, maxZoom = 12, zoomedThreshold = 1.02;

  /// What makes a drag a page swipe. It must be [swipeAxisRatio] times longer across than
  /// down. It must also go [swipeDistance] px, or end at [swipeVelocity] px per second.
  static const double swipeAxisRatio = 1.5,
      swipeDistance = 40,
      swipeVelocity = 500;

  /// [zoomSnapHysteresis] is how far past the midpoint between two zoom steps a pinch must
  /// reach before it commits to the next step, either way, as a factor: 0.03 means 1.03 times
  /// the midpoint going up, and the midpoint divided by 1.03 going down. When a short reach
  /// from the current step is nearer than the midpoint, the factor applies to that reach. It
  /// holds a finger that rests on the line from flickering between two layouts.
  /// [zoomQuantum] is the smallest change in reflow zoom a free pinch asks the page for.
  static const double zoomSnapHysteresis = 0.03, zoomQuantum = 0.01;

  /// How far a justified row's gaps may open, as a multiple of the usual air between two
  /// words: what a reflowed page and a passage stretch to unless the host says otherwise.
  static const double reflowMaxStretch = 2;

  /// How far a reflowed row much shorter than its neighbours opens towards them, as a share
  /// of the difference.
  static const double reflowRelax = 0.5;

  /// The tallest band of ink a view draws at once, in viewport px: what
  /// [QvpPage.layoutInkBand] holds a band to by default.
  static const double maxInkHeight = 4096;
}

/// The engine's name tables (`QVP_NAMES_*`), loaded from the engine when a [QvpEngine] opens.
/// No table lives in this package.
abstract final class QvpNames {
  /// The table ids, as `QVP_NAMES_*` numbers them.
  static const int mark = 0,
      kind = 1,
      family = 2,
      category = 3,
      decoration = 4,
      division = 5,
      place = 6;
  static final Map<int, List<String>> _tables = {};

  /// Every name of a table, index = id. Empty until a [QvpEngine] has opened.
  static void setTable(int table, List<String> names) => _tables[table] = names;

  /// Every name of [table], at the index of its id. Empty until a [QvpEngine] has opened.
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
  /// The division ids.
  static const int juz = 0, hizb = 1, nisf = 2, rubuAlHizb = 3;

  /// Every division name, at the index of its id.
  static List<String> get names => QvpNames.of(QvpNames.division);

  /// The division id of [k]: an int passes through, and a name resolves through the engine's
  /// table. `rubuAlHizb` and `rubu_al_hizb` both work; an unknown name is 255.
  static int of(Object k) => k is int
      ? k
      : QvpNames.idOf(
          QvpNames.division,
          k == 'rubuAlHizb' ? 'rubu_al_hizb' : k,
        );
}

/// Mark ids ↔ names, from the engine. Index = id; 255 = unknown.
abstract final class QvpMark {
  /// Every mark name, at the index of its id.
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
  /// The opcodes. [moveTo] and [lineTo] read one point from [QvpPage.pts], [quadTo] two,
  /// [cubicTo] three, and [close] none.
  static const int moveTo = 0, lineTo = 1, quadTo = 2, cubicTo = 3, close = 4;
}

// ───────────── colours ─────────────

/// An alpha of 0..1 as 0..255, rounded to the nearest step; NaN and out-of-range values clamp first.
int _alpha8(double alpha) =>
    ((alpha.isNaN ? 0.0 : alpha.clamp(0.0, 1.0)) * 255).round();

/// 0xRRGGBBAA from an int (passed through), a `#rgb` / `#rrggbb` / `#rrggbbaa` string, or a Flutter [Color].
/// [alpha] (0..1) replaces the alpha of 6-digit strings and Colors.
int rgba(Object c, [double? alpha]) {
  if (c is int) return c & 0xffffffff;
  if (c is Color) return QvpColor.fromColor(c, alpha);
  var h = (c as String).trim();
  if (h.startsWith('#')) h = h.substring(1);
  if (h.length == 3 || h.length == 4) h = h.split('').map((x) => x + x).join();
  if (h.length == 6) {
    h += alpha != null
        ? _alpha8(alpha).toRadixString(16).padLeft(2, '0')
        : 'ff';
  }
  return int.parse(h, radix: 16) & 0xffffffff;
}

/// 0xRRGGBBAA ↔ Flutter [Color].
abstract final class QvpColor {
  /// The Flutter [Color] of a 0xRRGGBBAA value.
  static Color toColor(int rgba) => Color.fromARGB(
    rgba & 0xff,
    (rgba >> 24) & 0xff,
    (rgba >> 16) & 0xff,
    (rgba >> 8) & 0xff,
  );

  /// The 0xRRGGBBAA value of [c]. [alpha] (0 to 1) replaces its alpha.
  static int fromColor(Color c, [double? alpha]) {
    final a = alpha != null ? _alpha8(alpha) : (c.a * 255).round();
    return (((c.r * 255).round() << 24) |
            ((c.g * 255).round() << 16) |
            ((c.b * 255).round() << 8) |
            a) &
        0xffffffff;
  }

  /// CSS-style string `#rrggbbaa`.
  static String hex(int rgba) => '#${rgba.toRadixString(16).padLeft(8, '0')}';

  /// [rgba] with its alpha set to [alpha], 0 to 1.
  static int withAlpha(int rgba, double alpha) =>
      (rgba & 0xffffff00) | _alpha8(alpha);
}

// ───────────── selectors & targets ─────────────

/// What a style rule applies to (`QvpSelector`, `QVP_SELECTOR_*`). Build with [Sel].
@immutable
final class QvpSelector {
  /// A selector from its `QVP_SELECTOR_*` code and up to three arguments. [Sel] builds them by
  /// name.
  const QvpSelector(this.selector, [this.a = 0, this.b = 0, this.c = 0]);

  /// The `QVP_SELECTOR_*` code, and its arguments in the order [Sel] takes them; unused ones
  /// are 0.
  final int selector, a, b, c;

  /// The same as [selector].
  int get code => selector;

  /// The same as [a].
  int get argA => a;

  /// The same as [b].
  int get argB => b;

  /// The same as [c].
  int get argC => c;

  @override
  String toString() => 'Sel($selector,$a,$b,$c)';
}

/// Selector constructors (same names as web/qvp.js `Sel`).
abstract final class Sel {
  /// Every path on the page.
  static QvpSelector page() => const QvpSelector(0);

  /// One path, by its index in the path table.
  static QvpSelector path(int i) => QvpSelector(1, i);

  /// The [n]th path of word [w], from 0, in file order.
  static QvpSelector wordPath(int w, int n) => QvpSelector(2, w, n);

  /// The [n]th mark of word [w], from 0, counting marks only.
  static QvpSelector wordMark(int w, int n) => QvpSelector(3, w, n);

  /// The [n]th mark named [mark] in word [w], from 0. [mark] is a mark id or name.
  static QvpSelector wordMarkNamed(int w, Object mark, [int n = 0]) =>
      QvpSelector(4, w, QvpMark.id(mark), n);

  /// The letter bodies of word [w], without its marks.
  static QvpSelector wordBody(int w) => QvpSelector(5, w);

  /// The marks of word [w], without its letter bodies.
  static QvpSelector wordMarks(int w) => QvpSelector(6, w);

  /// Every path of word [w].
  static QvpSelector word(int w) => QvpSelector(7, w);

  /// Every path of ayah [a] of surah [s] on this page.
  static QvpSelector ayah(int s, int a) => QvpSelector(8, s, a);

  /// Every path on printed line [n], from 1.
  static QvpSelector line(int n) => QvpSelector(9, n);

  /// Every mark named [m] on the page. [m] is a mark id or name, such as `shaddah`.
  static QvpSelector mark(Object m) => QvpSelector(10, QvpMark.id(m));

  /// Every mark of [QvpCategory] [c].
  static QvpSelector category(int c) => QvpSelector(11, c);

  /// Every path of [QvpFamily] [f].
  static QvpSelector family(int f) => QvpSelector(12, f);

  /// Every path of [QvpKind] [k].
  static QvpSelector kind(int k) => QvpSelector(13, k);

  /// Every path of the decorations of [QvpDecorationKind] [k].
  static QvpSelector decoration(int k) => QvpSelector(14, k);

  /// Every path of decoration [i], by its index in [QvpPage.decorations].
  static QvpSelector decorationIndex(int i) => QvpSelector(15, i);
}

/// What resolves to a word list (`QvpTarget`, `QVP_TARGET_*`). Build with [T]
/// or pass a string anywhere a target is accepted: 'page', '2:255', '2:255:3',
/// '2:255-257', 'line:7', 'surah:2'. A `List<int>` of word indices is a target too.
@immutable
final class QvpTarget {
  /// A target from its `QVP_TARGET_*` code and arguments. [T] builds them by name, and [of]
  /// parses the string form.
  const QvpTarget(
    this.target, {
    this.a = 0,
    this.b = 0,
    this.c = 0,
    this.words,
    this.wordKey,
  });

  /// The `QVP_TARGET_*` code, and its arguments in the order [T] takes them; unused ones are 0.
  final int target, a, b, c;

  /// The word indices of a [T.words] target; null for every other kind.
  final List<int>? words;

  /// Numeric code for the target kind.
  int get code => target;

  /// The same as [a].
  int get argA => a;

  /// The same as [b].
  int get argB => b;

  /// The same as [c].
  int get argC => c;

  /// `[surah, ayah, word]` for the '2:255:3' string form; resolved per page via `findWord`.
  final List<int>? wordKey;

  /// Parses the string form: 'page', '2:255', '2:255:3', '2:255-257', 'line:7' or 'surah:2'.
  /// Throws an [ArgumentError] for anything else.
  static QvpTarget parse(String s) {
    if (s == 'page') return T.page();
    RegExpMatch? m;
    if ((m = RegExp(r'^line:(\d+)$').firstMatch(s)) != null) {
      return T.line(int.parse(m!.group(1)!));
    }
    if ((m = RegExp(r'^surah:(\d+)$').firstMatch(s)) != null) {
      return T.surah(int.parse(m!.group(1)!));
    }
    if ((m = RegExp(r'^(\d+):(\d+)-(\d+)$').firstMatch(s)) != null) {
      return T.ayahRange(
        int.parse(m!.group(1)!),
        int.parse(m.group(2)!),
        int.parse(m.group(3)!),
      );
    }
    if ((m = RegExp(r'^(\d+):(\d+):(\d+)$').firstMatch(s)) != null) {
      return QvpTarget(
        1,
        wordKey: [
          int.parse(m!.group(1)!),
          int.parse(m.group(2)!),
          int.parse(m.group(3)!),
        ],
      );
    }
    if ((m = RegExp(r'^(\d+):(\d+)$').firstMatch(s)) != null) {
      return T.ayah(int.parse(m!.group(1)!), int.parse(m.group(2)!));
    }
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
  /// Every word on the page.
  static QvpTarget page() => const QvpTarget(0);

  /// Word [i], by its index on the page.
  static QvpTarget word(int i) => QvpTarget(1, a: i);

  /// The words at the indices [ws].
  static QvpTarget words(List<int> ws) => QvpTarget(2, words: ws);

  /// The words of ayah [a] of surah [s] on this page.
  static QvpTarget ayah(int s, int a) => QvpTarget(3, a: s, b: a);

  /// The words of ayahs [a] to [b] of surah [s] on this page, both included.
  static QvpTarget ayahRange(int s, int a, int b) =>
      QvpTarget(4, a: s, b: a, c: b);

  /// The words on printed line [n], from 1.
  static QvpTarget line(int n) => QvpTarget(5, a: n);

  /// The words of surah [s] on this page.
  static QvpTarget surah(int s) => QvpTarget(6, a: s);

  /// The words from index [a] to index [b], both included, in either order.
  static QvpTarget range(int a, int b) => QvpTarget(7, a: a, b: b);
}

// ───────────── records ─────────────

/// One word of a page ([QvpPage.words]), in page units.
@immutable
final class QvpWordInfo {
  /// The backend fills one from `qvp_word_info`.
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

  /// [index] is the word's position in [QvpPage.words]. [surah], [ayah] and [word] are its key,
  /// each from 1. [line] is the printed line number, from 1, and [lineIndex] and [ayahIndex]
  /// are positions in [QvpPage.lines] and [QvpPage.ayahs]. The word's paths are [nPaths]
  /// paths from [firstPath] in the path table.
  final int index,
      surah,
      ayah,
      word,
      line,
      ayahIndex,
      lineIndex,
      firstPath,
      nPaths;

  /// The word's ink box: left, top, right, bottom.
  final double x0, y0, x1, y1;

  /// `rasm_uthmani`, the text of record (inline in the QVP file).
  final String text;

  /// `surah:ayah:word`
  String get wordKey => '$surah:$ayah:$word';

  /// `surah:ayah`
  String get ayahKey => '$surah:$ayah';
}

/// One ayah fragment of a page ([QvpPage.ayahs]): the part of an ayah on one printed line,
/// in page units.
@immutable
final class QvpAyahInfo {
  /// The backend fills one from `qvp_ayah_info`.
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

  /// [index] is the fragment's position in [QvpPage.ayahs], and [surah] and [ayah] its key.
  /// [fragment] counts from 1 up to [fragments], the number of lines the ayah covers. [flags]
  /// marks a division that starts at the ayah: 1 juz, 2 hizb, 4 `rubu_al_hizb`, 8 nisf. When
  /// any is set, [rubuAlHizb] is the number (1 to 240) that starts there, else 0. The
  /// fragment's words are [nWords] words from [firstWord].
  final int index,
      surah,
      ayah,
      fragment,
      fragments,
      flags,
      rubuAlHizb,
      firstWord,
      nWords;

  /// Deco index of the ayah mark or [qvpNone].
  final int ayahMarkDecoration;

  /// The fragment's ink box: left, top, right, bottom.
  final double x0, y0, x1, y1;
}

/// One printed line of a page ([QvpPage.lines]), in page units.
@immutable
final class QvpLineInfo {
  /// The backend fills one from `qvp_line_info`.
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

  /// [index] is the line's position in [QvpPage.lines], and [lineNumber] its printed number,
  /// from 1. Its words are [nWords] words from [firstWord]; a header line has none.
  final int index, lineNumber, firstWord, nWords;

  /// True for a line that holds a surah name or the basmalah and no words.
  final bool isHeader;

  /// The line's ink box (left, top, right, bottom), its line-spacing band from [bandY0] to
  /// [bandY1], and the y of its body's centre.
  final double x0, y0, x1, y1, bandY0, bandY1, centre;
}

/// One decoration of a page ([QvpPage.decorations]): an ayah mark, a surah name, the
/// basmalah, a division mark, a sajdah sign or page furniture, in page units.
@immutable
final class QvpDecorationInfo {
  /// The backend fills one from `qvp_decoration_info`.
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

  /// [index] is the position in [QvpPage.decorations], and [decoration] the [QvpDecorationKind].
  /// [surah] and [ayah] are the ayah it belongs to, 0 when it has none. [line] is the line
  /// index of its first path, so every decoration has a real line. Its paths are [nPaths]
  /// paths from [firstPath].
  final int index, decoration, surah, ayah, line, firstPath, nPaths;

  /// The decoration's ink box: left, top, right, bottom.
  final double x0, y0, x1, y1;

  /// The decoration's text, such as a surah name; empty when it has none.
  final String text;
}

/// The one hit shape for every hit test (`QvpHit`); the exact variants report distance 0.
/// `isExact` is true only when the point is inside an outline. Indices are -1 when absent.
@immutable
final class QvpHit {
  /// The backend fills one from a hit test, and the page adds [wordKey] and [ayahKey].
  const QvpHit({
    required this.word,
    required this.path,
    required this.decoration,
    required this.line,
    required this.distance,
    required this.isExact,
    this.wordKey,
    this.ayahKey,
  });

  /// The word, path, decoration and line index that were hit; -1 for each that is absent.
  final int word, path, decoration, line;

  /// How far the point is from the ink of the word it chose, in page units; 0 for an exact hit.
  final double distance;

  /// True when the point is inside an outline. A hit on a box alone is false.
  final bool isExact;

  /// `surah:ayah:word` and `surah:ayah` of the word hit; null when no word was hit.
  final String? wordKey, ayahKey;
  @override
  String toString() =>
      'QvpHit(word: $word, path: $path, decoration: $decoration, line: $line, distance: $distance, isExact: $isExact)';
}

/// Options of the gap-aware hit test.
@immutable
final class QvpHitOptions {
  /// The defaults: no distance limit, the engine's gap bias, and an exact hit first.
  const QvpHitOptions({
    this.maxDistance = 0,
    this.gapBias = QvpDefaults.gapBias,
    this.preferExact = true,
  });

  /// Page units; <= 0 unlimited.
  final double maxDistance;

  /// The share of a gap between two words that goes to the word before it, 0 to 1. A
  /// negative value is the engine default, [QvpDefaults.gapBias].
  final double gapBias;

  /// True to take a point inside an outline before the nearest word.
  final bool preferExact;
}

/// A band / mask box in layout viewport px (`QvpBox`).
@immutable
final class QvpBox {
  /// The backend fills one from `qvp_highlight_boxes_view`, `qvp_word_bands`,
  /// `qvp_word_bands_view` or `qvp_mask_boxes_view`.
  const QvpBox({
    required this.id,
    required this.line,
    required this.x0,
    required this.y0,
    required this.x1,
    required this.y1,
    required this.color,
    required this.radius,
  });

  /// [id] is the highlight handle of a highlight band, 0 for a word band or a mask box. [line]
  /// is the line index for a box on a printed page. On a reflowed page a highlight band and a
  /// band from [QvpPage.wordBandsView] carry their row instead. A band from
  /// [QvpPage.wordBands] is in page units and carries the printed line index, and so does a
  /// mask box.
  /// [color] is 0xRRGGBBAA, mid-transition included; 0 for a word band.
  final int id, line, color;

  /// The box (left, top, right, bottom) and its corner radius.
  final double x0, y0, x1, y1, radius;
}

/// The gap-aware box of one word ([QvpPage.hitAreas]): the ink box grown to meet its
/// neighbours and to fill the line band.
@immutable
final class QvpHitArea {
  /// The backend fills one from `qvp_hit_areas` or `qvp_hit_areas_view`.
  const QvpHitArea({
    required this.word,
    required this.line,
    required this.x0,
    required this.y0,
    required this.x1,
    required this.y1,
    required this.inkX0,
    required this.inkY0,
    required this.inkX1,
    required this.inkY1,
  });

  /// The word index, and the printed line index. On a reflowed page an area from
  /// [QvpPage.hitAreasView] carries its row index instead.
  final int word, line;

  /// The gap-aware box (left, top, right, bottom), and the word's ink box inside it.
  final double x0, y0, x1, y1, inkX0, inkY0, inkX1, inkY1;
}

/// The vertical band of one printed line ([QvpPage.lineBands]), in page units.
@immutable
final class QvpLineBand {
  /// The backend fills one from `qvp_line_bands`.
  const QvpLineBand({
    required this.line,
    required this.lineNumber,
    required this.y0,
    required this.y1,
    required this.mid,
    required this.inkY0,
    required this.inkY1,
  });

  /// The line index, and the printed line number, from 1.
  final int line, lineNumber;

  /// The band from the line spacing ([y0] to [y1]), its middle, and the ink's top and bottom.
  final double y0, y1, mid, inkY0, inkY1;
}

/// How a page reflows when the reader zooms in: the ink grows, fewer words fit a row, the rest
/// move down and the page scrolls. Every field but [zoom] is a typographic knob with a default
/// the engine chose; a reader's control only ever moves [zoom].
@immutable
final class QvpReflowSpec {
  /// The defaults are the engine's: centred rows, fitted breaks, uniform gaps, at a zoom of 1.
  const QvpReflowSpec({
    this.zoom = 1,
    this.fill = 'centred',
    this.breaks = 'fitted',
    this.gaps = 'uniform',
    this.wordGap = 1,
    this.maxStretch = QvpDefaults.reflowMaxStretch,
    this.relax = QvpDefaults.reflowRelax,
  });

  /// 1 or less is the printed page; [QvpPage.zoomSpec] hands back 0 there, as the C header
  /// does. The largest this page can reach is [QvpPage.reflowMaxZoom].
  final double zoom;

  /// `ragged` | `justified` | `centred`; `greedy` | `even` | `fitted` | `printed`; `printed` | `uniform`.
  final String fill, breaks, gaps;

  /// [wordGap] multiplies every gap between words; 0 is 1. [maxStretch] caps how far a justified
  /// row's gaps open, as a multiple of the usual gap: 0 is the engine default and a negative
  /// value is no cap. [relax] is how far a row much shorter than its neighbour opens towards
  /// it, 0 to 1; a negative value is the engine default.
  final double wordGap, maxStretch, relax;

  /// [fill] as the engine's code: 0 ragged, 1 justified, 2 centred (either spelling), and 255,
  /// the engine default, for any other name.
  int get fillCode => switch (fill) {
    'ragged' => 0,
    'justified' => 1,
    'centred' || 'centered' => 2,
    _ => 255,
  };

  /// [breaks] as the engine's code: 0 greedy, 1 even, 2 fitted, 3 printed, and 255, the engine
  /// default, for any other name.
  int get breaksCode => switch (breaks) {
    'greedy' => 0,
    'even' => 1,
    'fitted' => 2,
    'printed' => 3,
    _ => 255,
  };

  /// [gaps] as the engine's code: 0 printed, 1 for anything else, the page's median gap.
  int get gapsCode => gaps == 'printed' ? 0 : 1;

  /// This spec with the given fields changed.
  QvpReflowSpec copyWith({
    double? zoom,
    String? fill,
    String? breaks,
    String? gaps,
    double? wordGap,
    double? maxStretch,
    double? relax,
  }) => QvpReflowSpec(
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
  int get hashCode =>
      Object.hash(zoom, fill, breaks, gaps, wordGap, maxStretch, relax);
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

/// Where the reader's zoom control stands. A host keeps this beside its [QvpView]. The
/// default, `QvpZoom()`, is stepped and on the printed page, at zoom 1.
@immutable
final class QvpZoom {
  /// The default control: stepped, on the printed page.
  const QvpZoom({
    this.mode = QvpZoomMode.stepped,
    this.step = 0,
    this.zoom = 1,
  });

  /// What a pinch does under this control.
  final QvpZoomMode mode;

  /// 0 is the printed page, 1 upwards the page's own steps. What [QvpZoomMode.stepped] reads.
  final int step;

  /// The size in force, 1 at the printed page, whichever field the mode steers by.
  final double zoom;

  @override
  bool operator ==(Object other) =>
      other is QvpZoom &&
      other.mode == mode &&
      other.step == step &&
      other.zoom == zoom;

  @override
  int get hashCode => Object.hash(mode, step, zoom);
}

/// [QvpPage.layoutInkBand]: the band of the layout a host keeps drawn, in layout px. It sits
/// on the screen at `view.offsetY + view.scale·y`.
@immutable
final class QvpInkBand {
  /// The backend fills one from `qvp_layout_ink_band`.
  const QvpInkBand({required this.top, required this.height});

  /// The band's top and height in layout px. Pass `top` and `top + height` to
  /// [QvpPage.layoutDrawList].
  final double top, height;

  @override
  bool operator ==(Object other) =>
      other is QvpInkBand && other.top == top && other.height == height;

  @override
  int get hashCode => Object.hash(top, height);

  @override
  String toString() => 'QvpInkBand(top: $top, height: $height)';
}

/// A point `p` draws at `offset + scale · p`. The reader's pan and zoom, which the engine moves.
@immutable
final class QvpView {
  /// The defaults are no zoom and no pan.
  const QvpView({this.scale = 1, this.offsetX = 0, this.offsetY = 0});

  /// The zoom, and the pan in viewport px.
  final double scale, offsetX, offsetY;

  @override
  bool operator ==(Object other) =>
      other is QvpView &&
      other.scale == scale &&
      other.offsetX == offsetX &&
      other.offsetY == offsetY;

  @override
  int get hashCode => Object.hash(scale, offsetX, offsetY);
}

/// What a gesture produced: the control to keep, the view to draw with, and whether the page was
/// laid out again under it.
@immutable
final class QvpZoomChange {
  /// The backend fills one from `qvp_zoom_pinch` or `qvp_zoom_to_step`.
  const QvpZoomChange({
    required this.zoom,
    required this.view,
    required this.relaid,
  });

  /// The control to keep for the next gesture.
  final QvpZoom zoom;

  /// The view to draw with.
  final QvpView view;

  /// True when the page was laid out again: read [QvpPage.readLayout] and redraw.
  final bool relaid;
}

/// What a sideways drag means on the page in hand.
enum QvpSideways {
  /// Pan the page. Only a magnified page pans.
  pan,

  /// Turn the page: the page is fitted or reflowed, so it has no sideways travel.
  turnPage,
}

/// Where a group of paths is drawn: `x' = kx · x + dx`, `y' = ky · y + dy`, in page units.
@immutable
final class QvpPlacement {
  /// A placement that shifts by [dx], [dy] and scales by [kx], [ky].
  const QvpPlacement(this.dx, this.dy, this.kx, this.ky);

  /// The placement that leaves a path where it is.
  static const identity = QvpPlacement(0, 0, 1, 1);

  /// The shift in page units, and the scale on each axis.
  final double dx, dy, kx, ky;
}

/// One stroke of a layout: the path to draw, under the placement of that index.
@immutable
final class QvpDraw {
  /// The backend fills one from `qvp_layout_draw_list`.
  const QvpDraw(this.path, this.placement);

  /// The path index on the page, and the index into [QvpPage.layoutPlacements].
  final int path, placement;
}

/// Input of [QvpPage.layout]; lengths in viewport px. Spacing only opens up:
/// `lineSpacing` < 1 is clamped by the engine. `gridLines` 0 = the page's own grid.
final class QvpLayoutSpec {
  /// Every field defaults to the printed page with no padding. Set the viewport size before
  /// you lay out.
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

  /// The viewport size and the padding inside it, in viewport px. [lineSpacing] multiplies the
  /// printed spacing: 1 is as printed, and a value below 1 is 1.
  final double viewportW,
      viewportH,
      padTop,
      padBottom,
      padLeft,
      padRight,
      lineSpacing;

  /// Reflow the page onto rows of the viewport's own width, or null for the printed page.
  /// The reader's zoom control writes this: see [QvpPage.zoomSpec].
  final QvpReflowSpec? reflow;

  /// True to open the line spacing until the page fills the padded height.
  final bool fillHeight;

  /// The grid to lay the page out inside, in lines; 0 is the page's own ([QvpPage.grid]).
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

  /// The reflow zoom the engine reads: [QvpReflowSpec.zoom], or 0 without [reflow].
  double get reflowZoomValue => reflow?.zoom ?? 0;

  /// [QvpReflowSpec.fillCode], or 255 (the engine default) without [reflow].
  int get reflowFillCode => reflow?.fillCode ?? 255;

  /// [QvpReflowSpec.breaksCode], or 255 (the engine default) without [reflow].
  int get reflowBreaksCode => reflow?.breaksCode ?? 255;

  /// [QvpReflowSpec.gapsCode], or 1 (the median gap) without [reflow].
  int get reflowGapsCode => reflow?.gapsCode ?? 1;

  /// [QvpReflowSpec.wordGap], or 1 without [reflow].
  double get reflowWordGapValue => reflow?.wordGap ?? 1;

  /// [QvpReflowSpec.maxStretch], or 0 (the engine default) without [reflow].
  double get reflowMaxStretchValue => reflow?.maxStretch ?? 0;

  /// [QvpReflowSpec.relax], or -1 (the engine default) without [reflow].
  double get reflowRelaxValue => reflow?.relax ?? -1;

  /// This spec with the given fields changed. A null [reflow] keeps the current one.
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
  }) => QvpLayoutSpec(
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
  int get hashCode => Object.hash(
    viewportW,
    viewportH,
    padTop,
    padBottom,
    padLeft,
    padRight,
    lineSpacing,
    fillHeight,
    gridLines,
    cropLeft,
    cropRight,
    maxAspectSlack,
    reflow,
    bannerZoom,
    surahFrames,
  );
}

/// Output of [QvpPage.layout]. Page → viewport: `viewX = offsetX + x*scale`, `viewY = offsetY + (y + lineDy[line])*scale`.
@immutable
final class QvpLayout {
  /// The backend fills one from `qvp_layout` or `qvp_layout_current`.
  const QvpLayout({
    required this.scale,
    required this.offsetX,
    required this.offsetY,
    required this.contentW,
    required this.contentH,
    required this.lineSpacing,
    required this.lineDy,
    required this.slots,
    this.fitScale = 1,
    this.fitX = 0,
    this.fitY = 0,
    this.reflowed = false,
    this.rows = 0,
  });

  /// [scale], [offsetX] and [offsetY] map page units to viewport px, as the class block says.
  /// [contentW] and [contentH] are the laid-out content in viewport px, padding included.
  /// [lineSpacing] is the spacing the layout produced, in page units.
  final double scale, offsetX, offsetY, contentW, contentH, lineSpacing;

  /// Whether the page was reflowed onto rows of the viewport's width, and how many rows it made.
  /// When it was, [lineDy] and [slots] describe the rows rather than the printed lines.
  final bool reflowed;

  /// How many rows a reflowed page made; 0 when it was not reflowed.
  final int rows;

  /// The view transform for the content: draw at `fitX + fitScale*viewX`,
  /// `fitY + fitScale*viewY`, and put the host's pan and zoom on top. The fit shows a
  /// box: the content, plus the dress overflow on each side when the page is dressed
  /// ([QvpDressInfo.overflow]). On a printed page [fitScale] shrinks the box to fit both
  /// the viewport width and height (never above 1), and the box is centred. On a reflowed
  /// page [fitScale] is 1 and the host scrolls: the box is centred across the viewport,
  /// and its top is at the top of the viewport. [fitX] and [fitY] place the content's own
  /// origin, so the overflow sits to their left and above them.
  final double fitScale, fitX, fitY;

  /// Per-line vertical shift in page units (index = line record index).
  final Float32List lineDy;

  /// Per-line `(top, bottom)` slot in viewport px.
  final List<(double, double)> slots;
}

/// One highlight description. Colours accept anything [rgba] does.
@immutable
final class QvpHighlightStyle {
  /// The default is a band at the line spacing's height, in the default highlight colours,
  /// with no fade, on [QvpLayer.highlight].
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

  /// The colour of the words' ink and of the band behind them. Each is anything [rgba] takes.
  final Object ink, band;

  /// Lengths in page units. [padX] pads the band at the sides and [padY] above and below.
  /// [radius] rounds its corners. [seam] is how far the boxes of two neighbouring lines
  /// overlap, so no hairline shows between them.
  final double padX, padY, radius, seam;

  /// The fade in milliseconds, and the style layer the ink colour goes on (see [QvpLayer]).
  final int ms, layer;

  /// [mode] as the engine's code: 0 ink, 1 band, 2 both. Any other name is band.
  int get modeCode => switch (mode) {
    'ink' => 0,
    'both' => 2,
    _ => 1,
  };

  /// [height] as the engine's code: 0 line spacing, 1 ink.
  int get heightCode => height == 'ink' ? 1 : 0;

  /// [ink] as 0xRRGGBBAA.
  int get inkRgba => rgba(ink);

  /// [band] as 0xRRGGBBAA.
  int get bandRgba => rgba(band);
}

/// A theme: every colour is optional (0 / null = leave alone); `marks` maps mark name or id → colour.
@immutable
final class QvpTheme {
  /// Every colour defaults to null, which leaves it alone.
  const QvpTheme({
    this.ink,
    this.diacritics,
    this.dots,
    this.waqf,
    this.sifr,
    this.ayahMark,
    this.numeral,
    this.headers,
    this.marks = const {},
    this.ms = 0,
  });

  /// The colours, each anything [rgba] takes. [ink] colours the page. [diacritics] colours
  /// harakah, tanwin and maddah. [dots] colours letter dots, [waqf] waqf signs and [sifr] the
  /// sifr family. [ayahMark] colours the ring of an ayah mark and [numeral] its number.
  /// [headers] colours the ink of a surah header.
  final Object? ink, diacritics, dots, waqf, sifr, ayahMark, numeral, headers;

  /// A colour for each mark named, keyed by mark id or name.
  final Map<Object, Object> marks;

  /// The fade in milliseconds.
  final int ms;
}

/// Static Tajweed color mapping for vector mark rendering.
@immutable
final class QvpTajweedColors {
  const QvpTajweedColors({
    required this.madd,
    required this.iqlab,
    required this.waqf,
    required this.tanwin,
    required this.harakah,
    required this.dabt,
  });

  final Object madd;
  final Object iqlab;
  final Object waqf;
  final Object tanwin;
  final Object harakah;
  final Object dabt;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is QvpTajweedColors &&
          madd == other.madd &&
          iqlab == other.iqlab &&
          waqf == other.waqf &&
          tanwin == other.tanwin &&
          harakah == other.harakah &&
          dabt == other.dabt;

  @override
  int get hashCode => Object.hash(madd, iqlab, waqf, tanwin, harakah, dabt);
}

/// One surah on a page ([QvpPage.surahs]): a surah with words here, or one whose name banner
/// or basmalah is here.
@immutable
final class QvpSurah {
  /// The backend fills one from `qvp_surah_at`.
  const QvpSurah({
    required this.number,
    required this.ayahCount,
    required this.hasBanner,
    required this.hasBasmalah,
    required this.place,
    required this.bannerDecoration,
    required this.arabic,
    required this.latin,
    required this.english,
  });

  /// The surah's number, from 1. [ayahCount] is how many ayahs it has in all, but only when
  /// its name banner or basmalah is on this page; a surah that continues from an earlier page
  /// has 0. [bannerDecoration] is the index in [QvpPage.decorations] of its name banner, or
  /// [qvpNone] when the banner is on another page.
  final int number, ayahCount, bannerDecoration;

  /// Whether this page prints the surah's name banner, and whether it prints the basmalah,
  /// which sits below the name and above the surah's first ayah.
  final bool hasBanner, hasBasmalah;

  /// 'makkah' | 'madinah' | '', and the names in Arabic, Latin letters and English. Like
  /// [ayahCount], they come from the name banner or the basmalah on this page: a surah that
  /// continues from an earlier page has every one empty. [QvpAtlas.surah] has them for every
  /// surah.
  final String place, arabic, latin, english;
}

/// A juz, hizb, nisf or `rubu_al_hizb` that starts on a page ([QvpPage.divisions]).
@immutable
final class QvpDivision {
  /// The backend fills one from `qvp_divisions`.
  const QvpDivision({
    required this.division,
    required this.line,
    required this.number,
    required this.surah,
    required this.ayah,
    required this.ayahIndex,
  });

  /// 'juz' | 'hizb' | 'nisf' | 'rubuAlHizb'
  final String division;

  /// The printed line number it starts on, and its number (a juz is 1 to 30). It starts at
  /// ayah [ayah] of surah [surah], which is [QvpPage.ayahs] entry [ayahIndex].
  final int line, number, surah, ayah, ayahIndex;
}

/// A surah heading on a page, in page units ([QvpPage.surahHeaders]) or in viewport px
/// ([QvpPage.surahHeadersView]).
@immutable
final class QvpSurahHeader {
  /// The backend fills one from `qvp_surah_headers` or `qvp_surah_headers_view`.
  const QvpSurahHeader({
    required this.decoration,
    required this.surah,
    required this.line,
    required this.x0,
    required this.y0,
    required this.x1,
    required this.y1,
    required this.titleX0,
    required this.titleY0,
    required this.titleX1,
    required this.titleY1,
  });

  /// Its index in [QvpPage.decorations], the surah number, and the line index it sits in.
  final int decoration, surah, line;

  /// The box a frame fills: the page's text block wide, the heading's row tall.
  final double x0, y0, x1, y1;

  /// The title ink inside that box, with any native frame left out.
  final double titleX0, titleY0, titleX1, titleY1;
}

/// An ayah medallion on a page, in page units ([QvpPage.ayahMarks]) or in viewport px
/// ([QvpPage.ayahMarksView]).
@immutable
final class QvpAyahMark {
  /// The backend fills one from `qvp_ayah_marks` or `qvp_ayah_marks_view`.
  const QvpAyahMark({
    required this.decoration,
    required this.surah,
    required this.ayah,
    required this.line,
    required this.cx,
    required this.cy,
    required this.r,
    required this.ornamentPath,
    required this.numeralPath,
  });

  /// Its index in [QvpPage.decorations], the ayah it closes, and the line index it is laid out
  /// with. [ornamentPath] is the first path of its ring and [numeralPath] the path of its
  /// number; each is [qvpNone] when the medallion has none. Restyle or hide them by these.
  final int decoration, surah, ayah, line, ornamentPath, numeralPath;

  /// The medallion's centre and radius.
  final double cx, cy, r;
}

/// A drawn hizb rosette on a page ([QvpPage.rosettes]).
@immutable
final class QvpRosette {
  /// The backend fills one from `qvp_rosettes`.
  const QvpRosette({
    required this.decoration,
    required this.surah,
    required this.ayah,
    required this.juz,
    required this.hizb,
    required this.nisf,
    required this.rubuAlHizb,
    required this.rubuAlHizbInHizb,
  });

  /// Its index in [QvpPage.decorations], and the ayah it marks. [juz], [hizb], [nisf] and
  /// [rubuAlHizb] are the division numbers it shows, 0 for each it does not. [rubuAlHizbInHizb]
  /// is which quarter of the hizb it marks, 1 to 4, or 0.
  final int decoration,
      surah,
      ayah,
      juz,
      hizb,
      nisf,
      rubuAlHizb,
      rubuAlHizbInHizb;
}

/// A sajdah sign on a page ([QvpPage.sajdahs]).
@immutable
final class QvpSajdah {
  /// The backend fills one from `qvp_sajdahs`.
  const QvpSajdah({
    required this.decoration,
    required this.surah,
    required this.ayah,
    required this.signPath,
  });

  /// Its index in [QvpPage.decorations], the ayah it belongs to, and the path that draws the
  /// sign.
  final int decoration, surah, ayah, signPath;
}

/// One search hit on a page ([QvpPage.search]).
@immutable
final class QvpMatch {
  /// The backend fills one from `qvp_search`.
  const QvpMatch({
    required this.word,
    required this.index,
    required this.isLooseMatch,
    this.wordKey = '',
    this.text = '',
  });

  /// The word index, and the byte offset of the match in the word's normalised text.
  final int word, index;

  /// True when only the loose fallback found it ([QvpEngine.looseKey]). Tell the reader: the
  /// loose key merges different words.
  final bool isLooseMatch;

  /// The word's `surah:ayah:word`, and its `rasm_uthmani` text.
  final String wordKey, text;
}

/// The crop box of a target ([QvpPage.cropBounds]), in page units.
@immutable
final class QvpCropBounds {
  /// The backend fills one from `qvp_crop_bounds`.
  const QvpCropBounds({
    required this.x0,
    required this.y0,
    required this.x1,
    required this.y1,
    required this.nWords,
    required this.ayahMarkDecoration,
  });

  /// The box (left, top, right, bottom), padding included.
  final double x0, y0, x1, y1;

  /// How many words are inside, and the decoration index of the medallion kept in the box, or
  /// [qvpNone].
  final int nWords, ayahMarkDecoration;
}

/// One surah of the atlas ([QvpAtlas.surah]).
@immutable
final class QvpAtlasSurah {
  /// The backend fills one from `qvp_atlas_surah`.
  const QvpAtlasSurah({
    required this.number,
    required this.page,
    required this.ayahCount,
    required this.place,
    required this.arabic,
    required this.latin,
    required this.english,
  });

  /// The surah's number, from 1, the page it starts on, and how many ayahs it has.
  final int number, page, ayahCount;

  /// 'makkah', 'madinah' or '' for the place, and the surah's name in Arabic, in Latin letters
  /// and in English.
  final String place, arabic, latin, english;
}

/// Where a division starts, from the atlas ([QvpAtlas.division]).
@immutable
final class QvpAtlasRubuAlHizb {
  /// The backend fills one from `qvp_atlas_division`.
  const QvpAtlasRubuAlHizb({
    required this.rubuAlHizb,
    required this.surah,
    required this.ayah,
    required this.page,
  });

  /// The `rubu_al_hizb` it starts at (1 to 240), its first ayah, and the page of that ayah.
  final int rubuAlHizb, surah, ayah, page;

  /// `surah:ayah` of the first ayah.
  String get ayahKey => '$surah:$ayah';
}

/// One entry of [QvpPage.styledPaths].
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
  /// The backend fills one from `qvp_ornament_info`.
  const QvpOrnamentLicence({
    required this.id,
    required this.status,
    required this.redistributable,
    required this.attribution,
  });

  /// An SPDX id, or empty when the source does not state one.
  final String id;

  /// How sure the catalogue is of [id]: 'confirmed', 'provisional' or 'pending'.
  final String status;

  /// True when [status] is confirmed, so a page wearing the ornament may be published.
  final bool redistributable;

  /// The credit line to show with the ornament.
  final String attribution;
}

/// One printed colour of an ornament's design. A part with alpha 0 is a window the design
/// leaves open (its slot).
@immutable
final class QvpOrnamentPart {
  /// The backend fills one from `qvp_ornament_part`.
  const QvpOrnamentPart({
    required this.index,
    required this.color,
    required this.stroke,
    required this.name,
  });

  /// Its position in [QvpOrnament.parts]: the part number a repaint in [QvpDressSpec.colors]
  /// names.
  final int index;

  /// 0xRRGGBBAA.
  final int color;

  /// True for a line-art part, drawn as constant-width strokes.
  final bool stroke;

  /// The part's name in the catalogue.
  final String name;
}

/// One ornament of a [QvpOrnaments] set.
@immutable
final class QvpOrnament {
  /// The backend fills one from `qvp_ornament_info`.
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

  /// What the ornament replaces on a page.
  final QvpOrnamentKind kind;

  /// Where its artwork came from.
  final QvpLineage lineage;

  /// The mushaf or font it comes from.
  final String style;

  /// The riwayah the mushaf prints; empty for a font.
  final String riwayah;

  /// True when a border can be tiled along the edges. Without slices it keeps its printed
  /// proportions.
  final bool hasSlices;

  /// What the ornament may be redistributed under.
  final QvpOrnamentLicence licence;

  /// The design's printed palette, one entry per colour.
  final List<QvpOrnamentPart> parts;
}

/// A style of a [QvpOrnaments] set, with the ornament it has of each kind or null.
@immutable
final class QvpOrnamentStyle {
  /// [QvpOrnaments.styles] builds these from the set.
  const QvpOrnamentStyle({
    required this.style,
    required this.riwayah,
    required this.lineage,
    this.ayahMark,
    this.surahHeader,
    this.pageFrame,
  });

  /// The style's name, and the riwayah its mushaf prints (empty for a font).
  final String style, riwayah;

  /// Where its artwork came from.
  final QvpLineage lineage;

  /// The style's medallion, band and border; null for each kind it lacks.
  final QvpOrnament? ayahMark, surahHeader, pageFrame;

  /// The ornament of [kind], or null.
  QvpOrnament? of(QvpOrnamentKind kind) => switch (kind) {
    QvpOrnamentKind.ayahMark => ayahMark,
    QvpOrnamentKind.surahHeader => surahHeader,
    QvpOrnamentKind.pageFrame => pageFrame,
  };

  /// True when the style has all three kinds, so it can dress a page on its own.
  bool get isComplete =>
      ayahMark != null && surahHeader != null && pageFrame != null;
}

/// What [QvpPage.dress] puts on the page. [style] names a mushaf and takes its medallion,
/// band and border together. Each of [ayahMark], [surahHeader] and [pageFrame] is a
/// [QvpOrnament], its index, or a style name, and overrides [style] for that kind. Lengths are
/// page units.
@immutable
final class QvpDressSpec {
  /// The default takes no ornament, so set [style] or one of the kinds. Gaps default to 5 page
  /// units, the medallion to the design's own size and the border to its own scale.
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

  /// This spec with the given fields changed. [style] stays. For [ayahMark], [surahHeader] and
  /// [pageFrame], an argument left out keeps the field and null clears it.
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
  }) => QvpDressSpec(
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

  /// [lineArt] as the engine's `QVP_LINE_ART_*` bits.
  int get lineArtBits => lineArt.fold(0, (acc, k) => acc | (1 << k.index));

  static const Object _keep = Object();
}

/// The readout of a dressed page.
@immutable
final class QvpDressInfo {
  /// The backend fills one from `qvp_dress_info`.
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

  /// `left, top, right, bottom` in layout px: how far the border reaches past the laid-out
  /// content. The layout's fit ([QvpLayout.fitScale]) already holds it, so a host that
  /// draws at the fit shows the whole border.
  final List<double> overflow;
}

/// [QvpPage.dressView]: the view for a host that scrolls the page, and the dressed box's size.
@immutable
final class QvpDressView {
  /// The backend fills one from `qvp_dress_view`.
  const QvpDressView({
    required this.view,
    required this.width,
    required this.height,
  });

  /// Shows the dressed box with its top at 0, centred across the viewport.
  final QvpView view;

  /// The dressed box at the asked scale, in viewport px: the size to give the canvas.
  final double width, height;
}

/// One entry of the ornament display list, in page units. Paint it behind the page ink.
@immutable
final class QvpDressDraw {
  /// The backend fills one from `qvp_dress_geometry`.
  const QvpDressDraw({
    required this.path,
    required this.color,
    required this.kind,
    required this.evenOdd,
    required this.stroke,
    required this.strokeWidth,
    required this.part,
    required this.placement,
  });

  /// The outline, with the fill rule already set.
  final Path path;

  /// 0xRRGGBBAA.
  final int color;

  /// The kind of ornament the draw belongs to, so a host can paint or skip one kind.
  final QvpOrnamentKind kind;

  /// True when [path] fills with the even-odd rule. [path] has the rule set already.
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

  /// The width of the rows. 0 or less puts the passage on one row, as wide as it is.
  final double width;

  /// Layout px per page unit. It shrinks only when one word and its signs are wider than the
  /// rows.
  final double scale;

  /// The distance between two rows' baselines, as a multiple of the printed one. At least 1: a
  /// row moves down further when its ink needs the room.
  final double lineSpacing;

  /// The empty margin on every side.
  final double padding;

  /// Where each row starts.
  final QvpPassageAlign align;

  /// The most rows to show; 0 shows every row. A cut passage has
  /// [QvpPassageLayout.isTruncated] set.
  final int maxRows;

  /// After a cut, put the medallion of the last ayah after the ellipsis, so the reader still
  /// sees which ayah it is.
  final bool keepAyahMark;

  /// The room the host needs for its ellipsis after a cut.
  final double ellipsisWidth;

  /// How far a justified row's gaps may open, as a multiple of the usual air between two
  /// words. 0 is the engine default, and a negative value lifts the cap.
  final double maxStretch;

  /// [align] as the engine's `QVP_ALIGN_*` code.
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
  int get hashCode => Object.hash(
    width,
    scale,
    lineSpacing,
    padding,
    align,
    maxRows,
    keepAyahMark,
    ellipsisWidth,
    maxStretch,
  );
}

/// One ayah of a passage, with its text from the page's own word records.
@immutable
final class QvpPassageText {
  /// The backend fills one from `qvp_passage_ayah_text`.
  const QvpPassageText({
    required this.surah,
    required this.ayah,
    required this.text,
  });

  /// The ayah's key.
  final int surah, ayah;

  /// The ayah's text, joined from the page's own word texts.
  final String text;

  /// `surah:ayah`
  String get ayahKey => '$surah:$ayah';
}

/// One row of a laid-out passage, in layout px: the box of the row's ink, and the height its
/// words sit on.
@immutable
final class QvpPassageRow {
  /// The backend fills one from `qvp_passage_rows`.
  const QvpPassageRow({
    required this.x0,
    required this.y0,
    required this.x1,
    required this.y1,
    required this.baseline,
  });

  /// The box of the row's ink (left, top, right, bottom), and the y its words sit on.
  final double x0, y0, x1, y1, baseline;
}

/// One word of a laid-out passage with the signs that go with it, in layout px.
@immutable
final class QvpPassageWord {
  /// The backend fills one from `qvp_passage_words`.
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

  /// The word's key, the page number it was printed on, and the index of its row in
  /// [QvpPassageLayout.rows].
  final int surah, ayah, word, page, row;

  /// The box of the word with its signs, such as the medallion that closes its ayah, and from
  /// [wordX0] to [wordY1] the box of the word alone.
  final double x0, y0, x1, y1, wordX0, wordY0, wordX1, wordY1;

  /// `surah:ayah:word`
  String get wordKey => '$surah:$ayah:$word';
}

/// The bounds of one ayah that a layout shows, in layout px.
@immutable
final class QvpPassageAyah {
  /// The backend fills one from `qvp_passage_ayahs`.
  const QvpPassageAyah({
    required this.surah,
    required this.ayah,
    required this.x0,
    required this.y0,
    required this.x1,
    required this.y1,
  });

  /// The ayah's key.
  final int surah, ayah;

  /// The box of the ayah's words that the layout shows.
  final double x0, y0, x1, y1;
}

/// One path that a passage layout draws: its page, its index on that page, and which of
/// [QvpPassageLayout.placements] it goes under.
@immutable
final class QvpPassageDraw {
  /// The backend fills one from `qvp_passage_draw_list`.
  const QvpPassageDraw(this.page, this.path, this.placement);

  /// The page number, the path index on that page, and the index into
  /// [QvpPassageLayout.placements].
  final int page, path, placement;
}

/// A laid-out passage.
@immutable
final class QvpPassageLayout {
  /// The backend fills one from `qvp_passage_layout`.
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

  /// The passage's size in layout px. [scale] is the layout px per page unit it was laid out
  /// at, and [lineSpacing] the printed line spacing in page units.
  final double width, height, scale, lineSpacing;

  /// The rows, from the top.
  final List<QvpPassageRow> rows;

  /// The words the layout shows, in reading order.
  final List<QvpPassageWord> words;

  /// The ayahs with at least one word shown.
  final List<QvpPassageAyah> ayahs;

  /// Every path to draw, in drawing order. Draw each with its page's geometry. A point `(x, y)`
  /// goes to `scale · (kx · x + dx)`, `scale · (ky · y + dy)` under its placement.
  final List<QvpPassageDraw> draws;

  /// What [QvpPassageDraw.placement] indexes.
  final List<QvpPlacement> placements;

  /// True when [QvpPassageSpec.maxRows] cut the passage.
  final bool isTruncated;

  /// Where the host draws its ellipsis after a cut, from the last row's top to its baseline;
  /// null when the passage was not cut.
  final Rect? ellipsis;
}

/// Decodes QVP curve opcodes into [path]. Shared by page path caching and dress geometry.
void decodeQvpPath(
  Path path,
  Uint8List ops,
  int opStart,
  int opCount,
  Float32List pts,
  int ptStart,
) {
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
        path.cubicTo(
          pts[k],
          pts[k + 1],
          pts[k + 2],
          pts[k + 3],
          pts[k + 4],
          pts[k + 5],
        );
        k += 6;
      case QvpOp.close:
        path.close();
    }
  }
}

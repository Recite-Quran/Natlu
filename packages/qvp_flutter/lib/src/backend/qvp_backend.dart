import 'dart:typed_data';

import '../types.dart';

export 'qvp_backend_native.dart'
    if (dart.library.js_interop) 'qvp_backend_web.dart';

/// Opaque handle representing a loaded page in backend memory.
abstract interface class PageHandle {}

/// Opaque handle representing a loaded atlas in backend memory.
abstract interface class AtlasHandle {}

/// Opaque handle representing a loaded passage in backend memory.
abstract interface class PassageHandle {}

/// Opaque handle representing a loaded ornaments set in backend memory.
abstract interface class OrnamentsHandle {}

/// Unpacked page data copied once upon loading.
class QvpPageData {
  const QvpPageData({
    required this.width,
    required this.height,
    required this.lineSpacing,
    required this.page,
    required this.nLines,
    required this.nAyahs,
    required this.nWords,
    required this.nPaths,
    required this.nDecorations,
    required this.ops,
    required this.pts,
    required this.table,
    required this.words,
    required this.ayahs,
    required this.lines,
    required this.decorations,
  });

  final double width;
  final double height;
  final double lineSpacing;
  final int page;
  final int nLines;
  final int nAyahs;
  final int nWords;
  final int nPaths;
  final int nDecorations;
  final Uint8List ops;
  final Float32List pts;
  final Uint32List table;
  final List<QvpWordInfo> words;
  final List<QvpAyahInfo> ayahs;
  final List<QvpLineInfo> lines;
  final List<QvpDecorationInfo> decorations;
}

/// Abstract contract for QVP engine platform operations.
///
/// Implemented by [QvpNativeBackend] on native platforms via `dart:ffi`
/// and [QvpWebBackend] on Web via `dart:js_interop` / WebAssembly.
abstract interface class QvpBackend {
  // ── Engine information & name tables ──
  String get version;
  int get formatVersion;
  String get engineName;
  int nameCount(int table);
  String name(int table, int id);
  int nameId(int table, String s);
  String markName(int m);
  String familyName(int f);
  String kindName(int k);
  String categoryName(int c);
  int markCategory(int m);
  int markFromName(String s);
  String arabic(int op, String s);
  QvpView viewZoomAbout(QvpView view, double focalX, double focalY, double factor, {double min = 0, double max = 0});
  void dispose();

  // ── Page lifecycle & data ──
  (PageHandle, QvpPageData) pageLoad(Uint8List bytes);
  void pageFree(PageHandle handle);

  // ── Page text & query ──
  String wordForm(PageHandle handle, int wordIndex, int form);
  int findWord(PageHandle handle, int surah, int ayah, int word);
  List<int> targetWords(PageHandle handle, QvpTarget target);
  List<QvpSurah> surahs(PageHandle handle);
  List<QvpDivision> divisions(PageHandle handle);
  List<QvpSurahHeader> surahHeaders(PageHandle handle, {required bool view});
  List<QvpAyahMark> ayahMarks(PageHandle handle);
  List<QvpRosette> rosettes(PageHandle handle);
  List<QvpSajdah> sajdahs(PageHandle handle);
  List<(int, int)> ayahKeys(PageHandle handle);
  ({int count, bool isComplete}) ayahWordCount(PageHandle handle, int surah, int ayah);
  List<int>? reciteMap(PageHandle handle, int surah, int ayah, int nSegments);
  String wordLabel(PageHandle handle, int wordIndex);
  String ayahLabel(PageHandle handle, int ayahIndex);
  String text(PageHandle handle, QvpTarget target, int form, String wordSep, String lineSep);
  List<QvpMatch> search(PageHandle handle, String query, {int form = 4, String mode = 'includes', bool normalize = true, bool looseMatch = true, int limit = 0});
  String citation(PageHandle handle, List<int> words);
  int attachWords(PageHandle handle, List<int> bytes);
  bool hasForm(PageHandle handle, int form);

  // ── Page hit-testing ──
  QvpHit? hitTestExact(PageHandle handle, double x, double y);
  QvpHit? hitTestExactView(PageHandle handle, double viewX, double viewY);
  QvpHit? hitTest(PageHandle handle, double x, double y, QvpHitOptions options);
  QvpHit? hitTestView(PageHandle handle, double viewX, double viewY, QvpHitOptions options);
  List<QvpLineBand> lineBands(PageHandle handle);
  List<QvpHitArea> hitAreas(PageHandle handle, double gapBias);

  // ── Page layout & zoom ──
  QvpLayout layout(PageHandle handle, QvpLayoutSpec spec);
  QvpZoomChange zoomPinch(PageHandle handle, QvpLayoutSpec spec, QvpZoom zoom, QvpView view, double factor, double focalX, double focalY);
  QvpZoomChange zoomToStep(PageHandle handle, QvpLayoutSpec spec, QvpZoom zoom, int step, QvpView view);
  QvpZoom zoomMode(PageHandle handle, QvpLayoutSpec spec, QvpZoom zoom, QvpZoomMode mode);
  QvpLayoutSpec zoomSpec(PageHandle handle, QvpLayoutSpec spec, QvpZoom zoom);
  QvpZoom zoomCarried(PageHandle handle, QvpLayoutSpec spec, QvpZoom zoom);
  double zoomAtStep(PageHandle handle, QvpLayoutSpec spec, int step);
  Float32List zoomSteps(PageHandle handle, QvpLayoutSpec spec);
  double reflowMaxZoom(PageHandle handle, QvpLayoutSpec spec);
  bool isZoomed(QvpZoom zoom, QvpView view, double fitScale);
  QvpSideways sidewaysDrag(PageHandle handle, QvpZoom zoom, QvpView view, double fitScale);
  List<QvpDraw> layoutDrawList(PageHandle handle, {double bandTop = 0, double bandBottom = 0});
  List<QvpPlacement> layoutPlacements(PageHandle handle);
  QvpLayout? readLayout(PageHandle handle);
  int? layoutWordRow(PageHandle handle, int word);
  Uint32List layoutRowWords(PageHandle handle, int row);
  ({int lines, double lineSpacing}) pageGrid(PageHandle handle);
  double layoutWastedFraction(PageHandle handle, QvpLayoutSpec spec);
  double layoutPrintedHeight(PageHandle handle, QvpLayoutSpec spec);
  double layoutLineSpacingToFill(PageHandle handle, QvpLayoutSpec spec, double max);
  ({double x0, double y0, double x1, double y1}) wordBoundsView(PageHandle handle, int wordIndex);

  // ── Page styling & themes ──
  int style(PageHandle handle, QvpSelector sel, int color, {int ms = 0, int layer = 0});
  int styleTarget(PageHandle handle, QvpTarget target, int color, {int ms = 0, int layer = 0});
  int removeStyle(PageHandle handle, int styleHandle);
  int recolorStyle(PageHandle handle, int styleHandle, int color, int ms);
  int hide(PageHandle handle, QvpSelector sel);
  void clearStyles(PageHandle handle);
  void clearLayer(PageHandle handle, int layer);
  void setDefaultColor(PageHandle handle, int color);
  int theme(PageHandle handle, QvpTheme t);
  List<int> styleHandles(PageHandle handle);

  // ── Page animation & display ──
  bool tick(PageHandle handle, double nowMs);
  Uint32List colors(PageHandle handle, int nPaths);
  List<QvpStyledPath> styledPaths(PageHandle handle);
  int colorOf(PageHandle handle, int path);

  // ── Highlights ──
  int highlight(PageHandle handle, QvpTarget target, QvpHighlightStyle style);
  bool moveHighlight(PageHandle handle, int highlightHandle, QvpTarget target);
  bool restyleHighlight(PageHandle handle, int highlightHandle, QvpHighlightStyle style);
  bool removeHighlight(PageHandle handle, int highlightHandle);
  void clearHighlights(PageHandle handle);
  List<int> highlightHandles(PageHandle handle);
  List<int> highlightWords(PageHandle handle, int highlightHandle);
  List<QvpBox> highlightBoxesView(PageHandle handle);
  List<QvpBox> wordBands(PageHandle handle, List<int> ws, {required bool inkHeight, required double padX, required double padY});

  // ── Selection ──
  void select(PageHandle handle, int anchor, int focus);
  List<int> selection(PageHandle handle);
  String selectionText(PageHandle handle, int form, bool includeCitation);

  // ── Masks & Memorisation ──
  void mask(PageHandle handle, QvpTarget target, int mode);
  void maskFrom(PageHandle handle, int wordIndex, int mode);
  void maskOptions(PageHandle handle, int blockColor, double padX, double padY, double radius, bool reverse);
  int unmaskNext(PageHandle handle, int n);
  int maskBack(PageHandle handle, int n);
  bool unmaskWord(PageHandle handle, int wordIndex);
  bool maskWord(PageHandle handle, int wordIndex);
  void unmaskAll(PageHandle handle);
  void maskAll(PageHandle handle);
  void unmask(PageHandle handle);
  List<int> maskHidden(PageHandle handle);
  List<int> maskWords(PageHandle handle);
  List<QvpBox> maskBoxesView(PageHandle handle);

  // ── Reveal ──
  int revealStart(PageHandle handle, {required int lit, required bool byAyah, required int grey, required int ink, required bool ayahMarks, required int ms});
  bool revealGoto(PageHandle handle, int at);
  int? revealPosition(PageHandle handle);
  int revealStepCount(PageHandle handle);
  int revealStepOf(PageHandle handle, int wordIndex);
  void revealStop(PageHandle handle);

  // ── Dress ──
  bool dress(PageHandle page, OrnamentsHandle set, QvpDressSpec spec);
  void undress(PageHandle page);
  QvpView dressClamp(PageHandle page, QvpView view, double viewportW, double viewportH);
  QvpDressView dressView(PageHandle page, double scale, double viewportW);
  QvpDressInfo? dressInfo(PageHandle page);
  List<QvpDressDraw> dressGeometry(PageHandle page);

  // ── Crop ──
  QvpCropBounds? cropBounds(PageHandle handle, QvpTarget target, {required double pad, required bool keepAyahMarks});
  String? cropSvg(PageHandle handle, QvpTarget target, {required double pad, required bool keepAyahMarks, int? background});

  // ── Atlas ──
  (AtlasHandle, int pageCount) atlasLoad(Uint8List bytes);
  void atlasFree(AtlasHandle handle);
  int? atlasPageOf(AtlasHandle handle, int surah, int ayah);
  ({(int, int) first, (int, int) last})? atlasPageRange(AtlasHandle handle, int page);
  QvpAtlasSurah? atlasSurah(AtlasHandle handle, int n);
  List<QvpAtlasSurah> atlasSurahs(AtlasHandle handle);
  QvpAtlasRubuAlHizb? atlasDivision(AtlasHandle handle, int division, int n);
  int? atlasDivisionOf(AtlasHandle handle, int division, int surah, int ayah);
  List<int>? atlasPagesOfJuz(AtlasHandle handle, int n);
  List<int> atlasSearchSurahs(AtlasHandle handle, String text);
  String atlasJson(AtlasHandle handle);

  // ── Passage ──
  (PassageHandle, List<QvpPassageText> ayahs, double lineSpacing) passageLoad(List<PageHandle> pages, int surah, int from, int to);
  (PassageHandle, List<QvpPassageText> ayahs, double lineSpacing) passageLoadBasmalah(List<PageHandle> pages, int surah);
  void passageFree(PassageHandle handle);
  QvpPassageLayout? passageLayout(PassageHandle handle, QvpPassageSpec spec);

  // ── Ornaments ──
  (OrnamentsHandle, List<QvpOrnament>) ornamentsLoad(Uint8List bytes);
  void ornamentsFree(OrnamentsHandle handle);
  int ornamentFind(OrnamentsHandle handle, int kind, String style);
}

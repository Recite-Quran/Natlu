// dart:ffi bindings for crates/qvp-ffi/include/qvp.h.
import 'dart:ffi' as ffi;

/// `typedef struct { const uint8_t* ptr; uint32_t len; } QvpStr;`
final class QvpStrC extends ffi.Struct {
  external ffi.Pointer<ffi.Uint8> ptr;
  @ffi.Uint32() external int len;
}

final class QvpPageInfoC extends ffi.Struct {
  @ffi.Float() external double width;
  @ffi.Float() external double height;
  @ffi.Uint32() external int page;
  @ffi.Uint32() external int nLines;
  @ffi.Uint32() external int nAyahs;
  @ffi.Uint32() external int nWords;
  @ffi.Uint32() external int nPaths;
  @ffi.Uint32() external int nDecorations;
}

final class QvpGeometryC extends ffi.Struct {
  external ffi.Pointer<ffi.Uint8> ops;
  @ffi.Uint32() external int opsLen;
  external ffi.Pointer<ffi.Float> pts;
  @ffi.Uint32() external int ptsLen;
  external ffi.Pointer<ffi.Uint32> table;
  @ffi.Uint32() external int nPaths;
}

final class QvpWordInfoC extends ffi.Struct {
  @ffi.Uint16() external int surah;
  @ffi.Uint16() external int ayah;
  @ffi.Uint16() external int word;
  @ffi.Uint16() external int lineNumber;
  @ffi.Uint32() external int ayahIndex;
  @ffi.Uint32() external int lineIndex;
  @ffi.Float() external double x0;
  @ffi.Float() external double y0;
  @ffi.Float() external double x1;
  @ffi.Float() external double y1;
  external QvpStrC text;
  @ffi.Uint32() external int firstPath;
  @ffi.Uint32() external int nPaths;
}

final class QvpAyahInfoC extends ffi.Struct {
  @ffi.Uint16() external int surah;
  @ffi.Uint16() external int ayah;
  @ffi.Uint8() external int fragment;
  @ffi.Uint8() external int fragments;
  @ffi.Uint8() external int flags;
  @ffi.Uint8() external int pad;
  @ffi.Uint16() external int rubuAlHizb;
  @ffi.Uint32() external int firstWord;
  @ffi.Uint32() external int nWords;
  @ffi.Uint32() external int ayahMarkDecoration;
  @ffi.Float() external double x0;
  @ffi.Float() external double y0;
  @ffi.Float() external double x1;
  @ffi.Float() external double y1;
}

final class QvpLineInfoC extends ffi.Struct {
  @ffi.Uint8() external int lineNumber;
  @ffi.Uint8() external int isHeader;
  @ffi.Uint32() external int firstWord;
  @ffi.Uint32() external int nWords;
  @ffi.Float() external double x0;
  @ffi.Float() external double y0;
  @ffi.Float() external double x1;
  @ffi.Float() external double y1;
  @ffi.Float() external double bandY0;
  @ffi.Float() external double bandY1;
  @ffi.Float() external double centre;
}

final class QvpDecorationInfoC extends ffi.Struct {
  @ffi.Uint8() external int decoration;
  @ffi.Uint8() external int pad;
  @ffi.Uint16() external int surah;
  @ffi.Uint16() external int ayah;
  @ffi.Uint16() external int pad2;
  @ffi.Uint32() external int line;
  @ffi.Float() external double x0;
  @ffi.Float() external double y0;
  @ffi.Float() external double x1;
  @ffi.Float() external double y1;
  external QvpStrC text;
  @ffi.Uint32() external int firstPath;
  @ffi.Uint32() external int nPaths;
}

final class QvpHitC extends ffi.Struct {
  @ffi.Uint32() external int word;
  @ffi.Uint32() external int path;
  @ffi.Uint32() external int decoration;
  @ffi.Uint32() external int line;
  @ffi.Float() external double distance;
  @ffi.Uint8() external int isExact;
}

final class QvpHitOptionsC extends ffi.Struct {
  @ffi.Float() external double maxDistance;
  @ffi.Float() external double gapBias;
  @ffi.Uint8() external int preferExact;
}

final class QvpBoxC extends ffi.Struct {
  @ffi.Uint32() external int id;
  @ffi.Uint32() external int line;
  @ffi.Float() external double x0;
  @ffi.Float() external double y0;
  @ffi.Float() external double x1;
  @ffi.Float() external double y1;
  @ffi.Uint32() external int color;
  @ffi.Float() external double radius;
}

final class QvpHitAreaC extends ffi.Struct {
  @ffi.Uint32() external int word;
  @ffi.Uint32() external int line;
  @ffi.Float() external double x0;
  @ffi.Float() external double y0;
  @ffi.Float() external double x1;
  @ffi.Float() external double y1;
  @ffi.Float() external double inkX0;
  @ffi.Float() external double inkY0;
  @ffi.Float() external double inkX1;
  @ffi.Float() external double inkY1;
}

final class QvpLineBandC extends ffi.Struct {
  @ffi.Uint32() external int line;
  @ffi.Uint32() external int lineNumber;
  @ffi.Float() external double y0;
  @ffi.Float() external double y1;
  @ffi.Float() external double mid;
  @ffi.Float() external double inkY0;
  @ffi.Float() external double inkY1;
}

final class QvpLayoutSpecC extends ffi.Struct {
  @ffi.Float() external double viewportW;
  @ffi.Float() external double viewportH;
  @ffi.Float() external double padTop;
  @ffi.Float() external double padBottom;
  @ffi.Float() external double padLeft;
  @ffi.Float() external double padRight;
  @ffi.Float() external double lineSpacing;
  @ffi.Uint8() external int fillHeight;
  @ffi.Uint32() external int gridLines;
  @ffi.Float() external double cropLeft;
  @ffi.Float() external double cropRight;
  @ffi.Float() external double maxAspectSlack;
  @ffi.Float() external double reflowZoom;
  @ffi.Uint8() external int reflowFill;
  @ffi.Uint8() external int reflowBreaks;
  @ffi.Uint8() external int reflowGaps;
  @ffi.Float() external double reflowWordGap;
  @ffi.Float() external double reflowMaxStretch;
  @ffi.Float() external double reflowRelax;
  @ffi.Float() external double bannerZoom;
  @ffi.Uint8() external int surahFrames;
}

final class QvpGridC extends ffi.Struct {
  @ffi.Uint32() external int lines;
  @ffi.Float() external double lineSpacing;
}

final class QvpLayoutC extends ffi.Struct {
  @ffi.Float() external double scale;
  @ffi.Float() external double offsetX;
  @ffi.Float() external double offsetY;
  @ffi.Float() external double contentW;
  @ffi.Float() external double contentH;
  @ffi.Float() external double lineSpacing;
  @ffi.Uint32() external int nLines;
  external ffi.Pointer<ffi.Float> lines;
  @ffi.Float() external double fitScale;
  @ffi.Float() external double fitX;
  @ffi.Float() external double fitY;
  @ffi.Uint32() external int reflowed;
  @ffi.Uint32() external int nRows;
}

final class QvpViewC extends ffi.Struct {
  @ffi.Float() external double scale;
  @ffi.Float() external double offsetX;
  @ffi.Float() external double offsetY;
}

final class QvpZoomC extends ffi.Struct {
  @ffi.Uint32() external int mode;
  @ffi.Uint32() external int step;
  @ffi.Float() external double zoom;
}

final class QvpZoomChangeC extends ffi.Struct {
  external QvpZoomC zoom;
  external QvpViewC view;
  @ffi.Uint32() external int relaid;
}

final class QvpTargetC extends ffi.Struct {
  @ffi.Uint8() external int target;
  @ffi.Uint32() external int a;
  @ffi.Uint32() external int b;
  @ffi.Uint32() external int c;
  external ffi.Pointer<ffi.Uint32> words;
  @ffi.Uint32() external int nWords;
}

final class QvpSelectorC extends ffi.Struct {
  @ffi.Uint8() external int selector;
  @ffi.Uint32() external int a;
  @ffi.Uint32() external int b;
  @ffi.Uint32() external int c;
}

final class QvpHighlightStyleC extends ffi.Struct {
  @ffi.Uint8() external int mode;
  @ffi.Uint8() external int height;
  @ffi.Uint32() external int ink;
  @ffi.Uint32() external int band;
  @ffi.Float() external double padX;
  @ffi.Float() external double padY;
  @ffi.Float() external double radius;
  @ffi.Float() external double seam;
  @ffi.Uint32() external int transitionMs;
  @ffi.Int32() external int layer;
}

final class QvpThemeC extends ffi.Struct {
  @ffi.Uint32() external int ink;
  @ffi.Uint32() external int diacritics;
  @ffi.Uint32() external int dots;
  @ffi.Uint32() external int waqf;
  @ffi.Uint32() external int sifr;
  @ffi.Uint32() external int ayahMark;
  @ffi.Uint32() external int numeral;
  @ffi.Uint32() external int headers;
  @ffi.Uint32() external int transitionMs;
  external ffi.Pointer<ffi.Uint32> marks;
  @ffi.Uint32() external int nMarks;
}

final class QvpSurahC extends ffi.Struct {
  @ffi.Uint16() external int number;
  @ffi.Uint16() external int ayahCount;
  @ffi.Uint8() external int hasBanner;
  @ffi.Uint8() external int hasBasmalah;
  @ffi.Uint8() external int place;
  @ffi.Uint8() external int pad;
  @ffi.Uint32() external int bannerDecoration;
  external QvpStrC arabic;
  external QvpStrC latin;
  external QvpStrC english;
}

final class QvpDivisionC extends ffi.Struct {
  @ffi.Uint8() external int division;
  @ffi.Uint8() external int line;
  @ffi.Uint16() external int number;
  @ffi.Uint16() external int surah;
  @ffi.Uint16() external int ayah;
  @ffi.Uint32() external int ayahIndex;
}

final class QvpSurahHeaderC extends ffi.Struct {
  @ffi.Uint32() external int decoration;
  @ffi.Uint16() external int surah;
  @ffi.Uint16() external int pad;
  @ffi.Uint32() external int line;
  @ffi.Float() external double x0;
  @ffi.Float() external double y0;
  @ffi.Float() external double x1;
  @ffi.Float() external double y1;
  @ffi.Float() external double titleX0;
  @ffi.Float() external double titleY0;
  @ffi.Float() external double titleX1;
  @ffi.Float() external double titleY1;
}

final class QvpAyahMarkC extends ffi.Struct {
  @ffi.Uint32() external int decoration;
  @ffi.Uint16() external int surah;
  @ffi.Uint16() external int ayah;
  @ffi.Uint32() external int line;
  @ffi.Float() external double cx;
  @ffi.Float() external double cy;
  @ffi.Float() external double r;
  @ffi.Uint32() external int ornamentPath;
  @ffi.Uint32() external int numeralPath;
}

final class QvpRosetteC extends ffi.Struct {
  @ffi.Uint32() external int decoration;
  @ffi.Uint16() external int surah;
  @ffi.Uint16() external int ayah;
  @ffi.Uint16() external int juz;
  @ffi.Uint16() external int hizb;
  @ffi.Uint16() external int nisf;
  @ffi.Uint16() external int rubuAlHizb;
  @ffi.Uint16() external int rubuAlHizbInHizb;
  @ffi.Uint16() external int pad;
}

final class QvpSajdahC extends ffi.Struct {
  @ffi.Uint32() external int decoration;
  @ffi.Uint16() external int surah;
  @ffi.Uint16() external int ayah;
  @ffi.Uint32() external int signPath;
}

final class QvpMatchC extends ffi.Struct {
  @ffi.Uint32() external int word;
  @ffi.Uint32() external int index;
  @ffi.Uint8() external int isLooseMatch;
}

final class QvpCropBoundsC extends ffi.Struct {
  @ffi.Float() external double x0;
  @ffi.Float() external double y0;
  @ffi.Float() external double x1;
  @ffi.Float() external double y1;
  @ffi.Uint32() external int nWords;
  @ffi.Uint32() external int ayahMarkDecoration;
}

final class QvpAtlasSurahC extends ffi.Struct {
  @ffi.Uint16() external int number;
  @ffi.Uint16() external int firstPage;
  @ffi.Uint16() external int ayahCount;
  @ffi.Uint8() external int place;
  @ffi.Uint8() external int pad;
  external QvpStrC arabic;
  external QvpStrC latin;
  external QvpStrC english;
}

final class QvpAtlasRubuAlHizbC extends ffi.Struct {
  @ffi.Uint16() external int rubuAlHizb;
  @ffi.Uint16() external int surah;
  @ffi.Uint16() external int ayah;
  @ffi.Uint16() external int page;
}

final class QvpPassageSpecC extends ffi.Struct {
  @ffi.Float() external double width;
  @ffi.Float() external double scale;
  @ffi.Float() external double lineSpacing;
  @ffi.Float() external double padding;
  @ffi.Uint8() external int align;
  @ffi.Uint8() external int keepAyahMark;
  @ffi.Array(2) external ffi.Array<ffi.Uint8> pad;
  @ffi.Uint32() external int maxRows;
  @ffi.Float() external double ellipsisWidth;
  @ffi.Float() external double maxStretch;
}

final class QvpPassageLayoutC extends ffi.Struct {
  @ffi.Float() external double width;
  @ffi.Float() external double height;
  @ffi.Float() external double scale;
  @ffi.Float() external double lineSpacing;
  @ffi.Uint32() external int nRows;
  @ffi.Uint32() external int nWords;
  @ffi.Uint32() external int nAyahs;
  @ffi.Uint32() external int nDraws;
  @ffi.Uint8() external int isTruncated;
  @ffi.Array(3) external ffi.Array<ffi.Uint8> pad;
  @ffi.Float() external double ellipsisX0;
  @ffi.Float() external double ellipsisY0;
  @ffi.Float() external double ellipsisX1;
  @ffi.Float() external double ellipsisY1;
}

final class QvpPassageRowC extends ffi.Struct {
  @ffi.Float() external double x0;
  @ffi.Float() external double y0;
  @ffi.Float() external double x1;
  @ffi.Float() external double y1;
  @ffi.Float() external double baseline;
}

final class QvpPassageWordC extends ffi.Struct {
  @ffi.Uint16() external int surah;
  @ffi.Uint16() external int ayah;
  @ffi.Uint16() external int word;
  @ffi.Uint16() external int page;
  @ffi.Uint32() external int row;
  @ffi.Float() external double x0;
  @ffi.Float() external double y0;
  @ffi.Float() external double x1;
  @ffi.Float() external double y1;
  @ffi.Float() external double wordX0;
  @ffi.Float() external double wordY0;
  @ffi.Float() external double wordX1;
  @ffi.Float() external double wordY1;
}

final class QvpPassageAyahC extends ffi.Struct {
  @ffi.Uint16() external int surah;
  @ffi.Uint16() external int ayah;
  @ffi.Float() external double x0;
  @ffi.Float() external double y0;
  @ffi.Float() external double x1;
  @ffi.Float() external double y1;
}

final class QvpOrnamentC extends ffi.Struct {
  @ffi.Uint32() external int kind;
  @ffi.Uint32() external int lineage;
  @ffi.Uint32() external int nParts;
  @ffi.Uint32() external int hasSlices;
  @ffi.Uint32() external int redistributable;
  @ffi.Uint32() external int pad;
  external QvpStrC style;
  external QvpStrC riwayah;
  external QvpStrC licenseId;
  external QvpStrC licenseStatus;
  external QvpStrC attribution;
}

final class QvpOrnamentPartC extends ffi.Struct {
  @ffi.Uint32() external int color;
  @ffi.Uint32() external int stroke;
  external QvpStrC name;
}

final class QvpDressSpecC extends ffi.Struct {
  @ffi.Uint32() external int ayahMark;
  @ffi.Uint32() external int surahHeader;
  @ffi.Uint32() external int pageFrame;
  @ffi.Float() external double gap;
  @ffi.Float() external double bandGap;
  @ffi.Float() external double ayahMarkScale;
  @ffi.Float() external double pageFrameScale;
  @ffi.Uint32() external int lineArt;
  external ffi.Pointer<ffi.Uint32> colors;
  @ffi.Uint32() external int nColors;
}

final class QvpDressInfoC extends ffi.Struct {
  @ffi.Uint32() external int ayahMark;
  @ffi.Uint32() external int surahHeader;
  @ffi.Uint32() external int pageFrame;
  @ffi.Uint32() external int nAyahMarks;
  @ffi.Uint32() external int nSurahHeaders;
  @ffi.Uint32() external int nFrameRepeats;
  @ffi.Uint32() external int frameStretched;
  @ffi.Uint32() external int nDraws;
  @ffi.Uint32() external int revision;
  @ffi.Array(4) external ffi.Array<ffi.Float> viewBox;
  @ffi.Array(4) external ffi.Array<ffi.Float> overflow;
}

final class QvpDressGeometryC extends ffi.Struct {
  external ffi.Pointer<ffi.Uint8> ops;
  @ffi.Uint32() external int opsLen;
  external ffi.Pointer<ffi.Float> pts;
  @ffi.Uint32() external int ptsLen;
  external ffi.Pointer<ffi.Uint32> table;
  @ffi.Uint32() external int nDraws;
}

final class QvpPageC extends ffi.Opaque {}
final class QvpAtlasC extends ffi.Opaque {}
final class QvpPassageC extends ffi.Opaque {}
final class QvpOrnamentsC extends ffi.Opaque {}

typedef PtrPage = ffi.Pointer<QvpPageC>;
typedef PtrAtlas = ffi.Pointer<QvpAtlasC>;
typedef PtrPassage = ffi.Pointer<QvpPassageC>;
typedef PtrOrnaments = ffi.Pointer<QvpOrnamentsC>;
typedef PtrPages = ffi.Pointer<PtrPage>;
typedef PtrU8 = ffi.Pointer<ffi.Uint8>;
typedef PtrU16 = ffi.Pointer<ffi.Uint16>;
typedef PtrU32 = ffi.Pointer<ffi.Uint32>;
typedef PtrF32 = ffi.Pointer<ffi.Float>;
typedef PtrStr = ffi.Pointer<QvpStrC>;
typedef PtrTarget = ffi.Pointer<QvpTargetC>;

/// Resolved C functions of one loaded `libqvp_ffi`. Field names are the C
/// names without the `qvp_` prefix, camel-cased.
final class QvpBindings {
  QvpBindings(this.lib);
  final ffi.DynamicLibrary lib;

  // memory
  late final alloc = lib.lookupFunction<PtrU8 Function(ffi.Size), PtrU8 Function(int)>('qvp_alloc');
  late final dealloc = lib.lookupFunction<ffi.Void Function(PtrU8, ffi.Size), void Function(PtrU8, int)>('qvp_dealloc');

  // page
  late final pageLoad = lib.lookupFunction<PtrPage Function(PtrU8, ffi.Size), PtrPage Function(PtrU8, int)>('qvp_page_load');
  late final pageFree = lib.lookupFunction<ffi.Void Function(PtrPage), void Function(PtrPage)>('qvp_page_free');
  late final pageInfo = lib.lookupFunction<ffi.Void Function(PtrPage, ffi.Pointer<QvpPageInfoC>), void Function(PtrPage, ffi.Pointer<QvpPageInfoC>)>('qvp_page_info');
  late final geometry = lib.lookupFunction<ffi.Void Function(PtrPage, ffi.Pointer<QvpGeometryC>), void Function(PtrPage, ffi.Pointer<QvpGeometryC>)>('qvp_geometry');
  late final wordInfo = lib.lookupFunction<ffi.Int32 Function(PtrPage, ffi.Uint32, ffi.Pointer<QvpWordInfoC>), int Function(PtrPage, int, ffi.Pointer<QvpWordInfoC>)>('qvp_word_info');
  late final wordForm = lib.lookupFunction<ffi.Int32 Function(PtrPage, ffi.Uint32, ffi.Uint8, PtrStr), int Function(PtrPage, int, int, PtrStr)>('qvp_word_form');
  late final ayahInfo = lib.lookupFunction<ffi.Int32 Function(PtrPage, ffi.Uint32, ffi.Pointer<QvpAyahInfoC>), int Function(PtrPage, int, ffi.Pointer<QvpAyahInfoC>)>('qvp_ayah_info');
  late final lineInfo = lib.lookupFunction<ffi.Int32 Function(PtrPage, ffi.Uint32, ffi.Pointer<QvpLineInfoC>), int Function(PtrPage, int, ffi.Pointer<QvpLineInfoC>)>('qvp_line_info');
  late final decorationInfo = lib.lookupFunction<ffi.Int32 Function(PtrPage, ffi.Uint32, ffi.Pointer<QvpDecorationInfoC>), int Function(PtrPage, int, ffi.Pointer<QvpDecorationInfoC>)>('qvp_decoration_info');
  late final findWord = lib.lookupFunction<ffi.Int32 Function(PtrPage, ffi.Uint16, ffi.Uint16, ffi.Uint16), int Function(PtrPage, int, int, int)>('qvp_find_word');
  late final targetWords = lib.lookupFunction<ffi.Uint32 Function(PtrPage, PtrTarget, PtrU32, ffi.Uint32), int Function(PtrPage, PtrTarget, PtrU32, int)>('qvp_target_words');
  late final pageLineSpacing = lib.lookupFunction<ffi.Float Function(PtrPage), double Function(PtrPage)>('qvp_page_line_spacing');
  late final pageGrid = lib.lookupFunction<ffi.Void Function(PtrPage, ffi.Pointer<QvpGridC>), void Function(PtrPage, ffi.Pointer<QvpGridC>)>('qvp_page_grid');

  // metadata
  late final surahCount = lib.lookupFunction<ffi.Uint32 Function(PtrPage), int Function(PtrPage)>('qvp_surah_count');
  late final surahAt = lib.lookupFunction<ffi.Int32 Function(PtrPage, ffi.Uint32, ffi.Pointer<QvpSurahC>), int Function(PtrPage, int, ffi.Pointer<QvpSurahC>)>('qvp_surah_at');
  late final divisions = lib.lookupFunction<ffi.Uint32 Function(PtrPage, ffi.Pointer<QvpDivisionC>, ffi.Uint32), int Function(PtrPage, ffi.Pointer<QvpDivisionC>, int)>('qvp_divisions');
  late final surahHeaders = lib.lookupFunction<ffi.Uint32 Function(PtrPage, ffi.Pointer<QvpSurahHeaderC>, ffi.Uint32), int Function(PtrPage, ffi.Pointer<QvpSurahHeaderC>, int)>('qvp_surah_headers');
  late final surahHeadersView = lib.lookupFunction<ffi.Uint32 Function(PtrPage, ffi.Pointer<QvpSurahHeaderC>, ffi.Uint32), int Function(PtrPage, ffi.Pointer<QvpSurahHeaderC>, int)>('qvp_surah_headers_view');
  late final ayahMarks = lib.lookupFunction<ffi.Uint32 Function(PtrPage, ffi.Pointer<QvpAyahMarkC>, ffi.Uint32), int Function(PtrPage, ffi.Pointer<QvpAyahMarkC>, int)>('qvp_ayah_marks');
  late final ayahMarksView = lib.lookupFunction<ffi.Uint32 Function(PtrPage, ffi.Pointer<QvpAyahMarkC>, ffi.Uint32), int Function(PtrPage, ffi.Pointer<QvpAyahMarkC>, int)>('qvp_ayah_marks_view');
  late final rosettes = lib.lookupFunction<ffi.Uint32 Function(PtrPage, ffi.Pointer<QvpRosetteC>, ffi.Uint32), int Function(PtrPage, ffi.Pointer<QvpRosetteC>, int)>('qvp_rosettes');
  late final sajdahs = lib.lookupFunction<ffi.Uint32 Function(PtrPage, ffi.Pointer<QvpSajdahC>, ffi.Uint32), int Function(PtrPage, ffi.Pointer<QvpSajdahC>, int)>('qvp_sajdahs');
  late final ayahKeys = lib.lookupFunction<ffi.Uint32 Function(PtrPage, PtrU32, ffi.Uint32), int Function(PtrPage, PtrU32, int)>('qvp_ayah_keys');
  late final ayahWordCount = lib.lookupFunction<ffi.Uint32 Function(PtrPage, ffi.Uint16, ffi.Uint16, PtrU8), int Function(PtrPage, int, int, PtrU8)>('qvp_ayah_word_count');
  late final reciteMap = lib.lookupFunction<ffi.Int32 Function(PtrPage, ffi.Uint16, ffi.Uint16, ffi.Uint32, PtrU32, ffi.Uint32), int Function(PtrPage, int, int, int, PtrU32, int)>('qvp_recite_map');
  late final wordLabel = lib.lookupFunction<ffi.Void Function(PtrPage, ffi.Uint32, PtrStr), void Function(PtrPage, int, PtrStr)>('qvp_word_label');
  late final ayahLabel = lib.lookupFunction<ffi.Void Function(PtrPage, ffi.Uint32, PtrStr), void Function(PtrPage, int, PtrStr)>('qvp_ayah_label');

  // text & search
  late final text = lib.lookupFunction<ffi.Void Function(PtrPage, PtrTarget, ffi.Uint8, PtrU8, ffi.Uint32, PtrU8, ffi.Uint32, PtrStr), void Function(PtrPage, PtrTarget, int, PtrU8, int, PtrU8, int, PtrStr)>('qvp_text');
  late final search = lib.lookupFunction<ffi.Uint32 Function(PtrPage, PtrU8, ffi.Uint32, ffi.Uint8, ffi.Uint8, ffi.Uint8, ffi.Uint8, ffi.Uint32, ffi.Pointer<QvpMatchC>, ffi.Uint32), int Function(PtrPage, PtrU8, int, int, int, int, int, int, ffi.Pointer<QvpMatchC>, int)>('qvp_search');
  late final arabic = lib.lookupFunction<ffi.Void Function(ffi.Uint8, PtrU8, ffi.Uint32, PtrStr), void Function(int, PtrU8, int, PtrStr)>('qvp_arabic');
  late final citation = lib.lookupFunction<ffi.Void Function(PtrPage, PtrU32, ffi.Uint32, PtrStr), void Function(PtrPage, PtrU32, int, PtrStr)>('qvp_citation');
  late final attachWords = lib.lookupFunction<ffi.Int32 Function(PtrPage, PtrU8, ffi.Uint32), int Function(PtrPage, PtrU8, int)>('qvp_attach_words');
  late final hasForm = lib.lookupFunction<ffi.Uint8 Function(PtrPage, ffi.Uint8), int Function(PtrPage, int)>('qvp_has_form');

  // hit testing
  late final hitTestExact = lib.lookupFunction<ffi.Int32 Function(PtrPage, ffi.Float, ffi.Float, ffi.Pointer<QvpHitC>), int Function(PtrPage, double, double, ffi.Pointer<QvpHitC>)>('qvp_hit_test_exact');
  late final hitTestExactView = lib.lookupFunction<ffi.Int32 Function(PtrPage, ffi.Float, ffi.Float, ffi.Pointer<QvpHitC>), int Function(PtrPage, double, double, ffi.Pointer<QvpHitC>)>('qvp_hit_test_exact_view');
  late final hitTest = lib.lookupFunction<ffi.Int32 Function(PtrPage, ffi.Float, ffi.Float, ffi.Pointer<QvpHitOptionsC>, ffi.Pointer<QvpHitC>), int Function(PtrPage, double, double, ffi.Pointer<QvpHitOptionsC>, ffi.Pointer<QvpHitC>)>('qvp_hit_test');
  late final hitTestView = lib.lookupFunction<ffi.Int32 Function(PtrPage, ffi.Float, ffi.Float, ffi.Pointer<QvpHitOptionsC>, ffi.Pointer<QvpHitC>), int Function(PtrPage, double, double, ffi.Pointer<QvpHitOptionsC>, ffi.Pointer<QvpHitC>)>('qvp_hit_test_view');
  late final lineBands = lib.lookupFunction<ffi.Uint32 Function(PtrPage, ffi.Pointer<QvpLineBandC>, ffi.Uint32), int Function(PtrPage, ffi.Pointer<QvpLineBandC>, int)>('qvp_line_bands');
  late final hitAreas = lib.lookupFunction<ffi.Uint32 Function(PtrPage, ffi.Float, ffi.Pointer<QvpHitAreaC>, ffi.Uint32), int Function(PtrPage, double, ffi.Pointer<QvpHitAreaC>, int)>('qvp_hit_areas');
  late final hitAreasView = lib.lookupFunction<ffi.Uint32 Function(PtrPage, ffi.Float, ffi.Pointer<QvpHitAreaC>, ffi.Uint32), int Function(PtrPage, double, ffi.Pointer<QvpHitAreaC>, int)>('qvp_hit_areas_view');

  // layout
  late final layout = lib.lookupFunction<ffi.Void Function(PtrPage, ffi.Pointer<QvpLayoutSpecC>, ffi.Pointer<QvpLayoutC>), void Function(PtrPage, ffi.Pointer<QvpLayoutSpecC>, ffi.Pointer<QvpLayoutC>)>('qvp_layout');
  late final layoutLineSpacingToFill = lib.lookupFunction<ffi.Float Function(PtrPage, ffi.Pointer<QvpLayoutSpecC>, ffi.Float), double Function(PtrPage, ffi.Pointer<QvpLayoutSpecC>, double)>('qvp_layout_line_spacing_to_fill');
  late final layoutWastedFraction = lib.lookupFunction<ffi.Float Function(PtrPage, ffi.Pointer<QvpLayoutSpecC>), double Function(PtrPage, ffi.Pointer<QvpLayoutSpecC>)>('qvp_layout_wasted_fraction');
  late final layoutPrintedHeight = lib.lookupFunction<ffi.Float Function(PtrPage, ffi.Pointer<QvpLayoutSpecC>), double Function(PtrPage, ffi.Pointer<QvpLayoutSpecC>)>('qvp_layout_printed_height');
  late final wordBoundsView = lib.lookupFunction<ffi.Int32 Function(PtrPage, ffi.Uint32, PtrF32), int Function(PtrPage, int, PtrF32)>('qvp_word_bounds_view');

  // styles
  late final styleAdd = lib.lookupFunction<ffi.Uint32 Function(PtrPage, ffi.Int32, ffi.Pointer<QvpSelectorC>, ffi.Uint32, ffi.Uint32), int Function(PtrPage, int, ffi.Pointer<QvpSelectorC>, int, int)>('qvp_style_add');
  late final styleAddTarget = lib.lookupFunction<ffi.Uint32 Function(PtrPage, ffi.Int32, PtrTarget, ffi.Uint32, ffi.Uint32), int Function(PtrPage, int, PtrTarget, int, int)>('qvp_style_add_target');
  late final styleRemove = lib.lookupFunction<ffi.Uint32 Function(PtrPage, ffi.Uint32), int Function(PtrPage, int)>('qvp_style_remove');
  late final styleRecolor = lib.lookupFunction<ffi.Uint32 Function(PtrPage, ffi.Uint32, ffi.Uint32, ffi.Uint32), int Function(PtrPage, int, int, int)>('qvp_style_recolor');
  late final styleClear = lib.lookupFunction<ffi.Void Function(PtrPage), void Function(PtrPage)>('qvp_style_clear');
  late final styleClearLayer = lib.lookupFunction<ffi.Void Function(PtrPage, ffi.Int32), void Function(PtrPage, int)>('qvp_style_clear_layer');
  late final styleDefaultColor = lib.lookupFunction<ffi.Void Function(PtrPage, ffi.Uint32), void Function(PtrPage, int)>('qvp_style_default_color');
  late final hide = lib.lookupFunction<ffi.Uint32 Function(PtrPage, ffi.Pointer<QvpSelectorC>), int Function(PtrPage, ffi.Pointer<QvpSelectorC>)>('qvp_style_hide');
  late final theme = lib.lookupFunction<ffi.Uint32 Function(PtrPage, ffi.Pointer<QvpThemeC>), int Function(PtrPage, ffi.Pointer<QvpThemeC>)>('qvp_theme');
  late final styleHandles = lib.lookupFunction<ffi.Uint32 Function(PtrPage, PtrU32, ffi.Uint32), int Function(PtrPage, PtrU32, int)>('qvp_style_handles');

  // clock & display list
  late final tick = lib.lookupFunction<ffi.Uint8 Function(PtrPage, ffi.Double), int Function(PtrPage, double)>('qvp_tick');
  late final colors = lib.lookupFunction<PtrU32 Function(PtrPage), PtrU32 Function(PtrPage)>('qvp_colors');
  late final styledPaths = lib.lookupFunction<ffi.Uint32 Function(PtrPage, PtrU32, ffi.Uint32), int Function(PtrPage, PtrU32, int)>('qvp_styled_paths');
  late final colorOf = lib.lookupFunction<ffi.Uint32 Function(PtrPage, ffi.Uint32), int Function(PtrPage, int)>('qvp_color_of');

  // highlights
  late final highlight = lib.lookupFunction<ffi.Uint32 Function(PtrPage, PtrTarget, ffi.Pointer<QvpHighlightStyleC>), int Function(PtrPage, PtrTarget, ffi.Pointer<QvpHighlightStyleC>)>('qvp_highlight_add');
  late final moveHighlight = lib.lookupFunction<ffi.Uint8 Function(PtrPage, ffi.Uint32, PtrTarget), int Function(PtrPage, int, PtrTarget)>('qvp_highlight_move');
  late final restyleHighlight = lib.lookupFunction<ffi.Uint8 Function(PtrPage, ffi.Uint32, ffi.Pointer<QvpHighlightStyleC>), int Function(PtrPage, int, ffi.Pointer<QvpHighlightStyleC>)>('qvp_highlight_restyle');
  late final removeHighlight = lib.lookupFunction<ffi.Uint8 Function(PtrPage, ffi.Uint32), int Function(PtrPage, int)>('qvp_highlight_remove');
  late final clearHighlights = lib.lookupFunction<ffi.Void Function(PtrPage), void Function(PtrPage)>('qvp_highlight_clear');
  late final highlightHandles = lib.lookupFunction<ffi.Uint32 Function(PtrPage, PtrU32, ffi.Uint32), int Function(PtrPage, PtrU32, int)>('qvp_highlight_handles');
  late final highlightWords = lib.lookupFunction<ffi.Uint32 Function(PtrPage, ffi.Uint32, PtrU32, ffi.Uint32), int Function(PtrPage, int, PtrU32, int)>('qvp_highlight_words');
  late final highlightBoxesView = lib.lookupFunction<ffi.Uint32 Function(PtrPage, ffi.Pointer<QvpBoxC>, ffi.Uint32), int Function(PtrPage, ffi.Pointer<QvpBoxC>, int)>('qvp_highlight_boxes_view');
  late final wordBands = lib.lookupFunction<ffi.Uint32 Function(PtrPage, PtrU32, ffi.Uint32, ffi.Uint8, ffi.Float, ffi.Float, ffi.Pointer<QvpBoxC>, ffi.Uint32), int Function(PtrPage, PtrU32, int, int, double, double, ffi.Pointer<QvpBoxC>, int)>('qvp_word_bands');
  late final wordBandsView = lib.lookupFunction<ffi.Uint32 Function(PtrPage, PtrU32, ffi.Uint32, ffi.Uint8, ffi.Float, ffi.Float, ffi.Pointer<QvpBoxC>, ffi.Uint32), int Function(PtrPage, PtrU32, int, int, double, double, ffi.Pointer<QvpBoxC>, int)>('qvp_word_bands_view');

  // selection
  late final select = lib.lookupFunction<ffi.Void Function(PtrPage, ffi.Uint32, ffi.Uint32), void Function(PtrPage, int, int)>('qvp_select');
  late final selection = lib.lookupFunction<ffi.Uint32 Function(PtrPage, PtrU32, ffi.Uint32), int Function(PtrPage, PtrU32, int)>('qvp_selection');
  late final selectionText = lib.lookupFunction<ffi.Void Function(PtrPage, ffi.Uint8, ffi.Uint8, PtrStr), void Function(PtrPage, int, int, PtrStr)>('qvp_selection_text');

  // memorisation
  late final mask = lib.lookupFunction<ffi.Void Function(PtrPage, PtrTarget, ffi.Uint8), void Function(PtrPage, PtrTarget, int)>('qvp_mask');
  late final maskFrom = lib.lookupFunction<ffi.Void Function(PtrPage, ffi.Uint32, ffi.Uint8), void Function(PtrPage, int, int)>('qvp_mask_from');
  late final maskOptions = lib.lookupFunction<ffi.Void Function(PtrPage, ffi.Uint32, ffi.Float, ffi.Float, ffi.Float, ffi.Uint8), void Function(PtrPage, int, double, double, double, int)>('qvp_mask_options');
  late final unmaskNext = lib.lookupFunction<ffi.Uint32 Function(PtrPage, ffi.Uint32), int Function(PtrPage, int)>('qvp_unmask_next');
  late final maskBack = lib.lookupFunction<ffi.Uint32 Function(PtrPage, ffi.Uint32), int Function(PtrPage, int)>('qvp_mask_back');
  late final unmaskWord = lib.lookupFunction<ffi.Uint8 Function(PtrPage, ffi.Uint32), int Function(PtrPage, int)>('qvp_unmask_word');
  late final maskWord = lib.lookupFunction<ffi.Uint8 Function(PtrPage, ffi.Uint32), int Function(PtrPage, int)>('qvp_mask_word');
  late final unmaskAll = lib.lookupFunction<ffi.Void Function(PtrPage), void Function(PtrPage)>('qvp_unmask_all');
  late final maskAll = lib.lookupFunction<ffi.Void Function(PtrPage), void Function(PtrPage)>('qvp_mask_all');
  late final unmask = lib.lookupFunction<ffi.Void Function(PtrPage), void Function(PtrPage)>('qvp_unmask');
  late final maskHidden = lib.lookupFunction<ffi.Uint32 Function(PtrPage, PtrU32, ffi.Uint32), int Function(PtrPage, PtrU32, int)>('qvp_mask_hidden');
  late final maskWords = lib.lookupFunction<ffi.Uint32 Function(PtrPage, PtrU32, ffi.Uint32), int Function(PtrPage, PtrU32, int)>('qvp_mask_words');
  late final maskBoxesView = lib.lookupFunction<ffi.Uint32 Function(PtrPage, ffi.Pointer<QvpBoxC>, ffi.Uint32), int Function(PtrPage, ffi.Pointer<QvpBoxC>, int)>('qvp_mask_boxes_view');
  late final revealStart = lib.lookupFunction<ffi.Uint32 Function(PtrPage, ffi.Uint32, ffi.Uint8, ffi.Uint32, ffi.Uint32, ffi.Uint8, ffi.Uint32), int Function(PtrPage, int, int, int, int, int, int)>('qvp_reveal_start');
  late final revealGoto = lib.lookupFunction<ffi.Uint8 Function(PtrPage, ffi.Int64), int Function(PtrPage, int)>('qvp_reveal_goto');
  late final revealPosition = lib.lookupFunction<ffi.Int64 Function(PtrPage), int Function(PtrPage)>('qvp_reveal_position');
  late final revealStepCount = lib.lookupFunction<ffi.Uint32 Function(PtrPage), int Function(PtrPage)>('qvp_reveal_step_count');
  late final revealStepOf = lib.lookupFunction<ffi.Int64 Function(PtrPage, ffi.Uint32), int Function(PtrPage, int)>('qvp_reveal_step_of');
  late final revealStop = lib.lookupFunction<ffi.Void Function(PtrPage), void Function(PtrPage)>('qvp_reveal_stop');

  // crop
  late final cropBounds = lib.lookupFunction<ffi.Int32 Function(PtrPage, PtrTarget, ffi.Float, ffi.Uint8, ffi.Pointer<QvpCropBoundsC>), int Function(PtrPage, PtrTarget, double, int, ffi.Pointer<QvpCropBoundsC>)>('qvp_crop_bounds');
  late final cropSvg = lib.lookupFunction<ffi.Int32 Function(PtrPage, PtrTarget, ffi.Float, ffi.Uint8, ffi.Uint32, PtrStr), int Function(PtrPage, PtrTarget, double, int, int, PtrStr)>('qvp_crop_svg');

  // atlas
  late final atlasLoad = lib.lookupFunction<PtrAtlas Function(PtrU8, ffi.Size), PtrAtlas Function(PtrU8, int)>('qvp_atlas_load');
  late final atlasFree = lib.lookupFunction<ffi.Void Function(PtrAtlas), void Function(PtrAtlas)>('qvp_atlas_free');
  late final atlasPageOf = lib.lookupFunction<ffi.Int32 Function(PtrAtlas, ffi.Uint16, ffi.Uint16), int Function(PtrAtlas, int, int)>('qvp_atlas_page_of');
  late final atlasPageRange = lib.lookupFunction<ffi.Int32 Function(PtrAtlas, ffi.Uint16, PtrU16), int Function(PtrAtlas, int, PtrU16)>('qvp_atlas_page_range');
  late final atlasPageCount = lib.lookupFunction<ffi.Uint32 Function(PtrAtlas), int Function(PtrAtlas)>('qvp_atlas_page_count');
  late final atlasSurahs = lib.lookupFunction<ffi.Uint32 Function(PtrAtlas), int Function(PtrAtlas)>('qvp_atlas_surah_count');
  late final atlasSurah = lib.lookupFunction<ffi.Int32 Function(PtrAtlas, ffi.Uint16, ffi.Pointer<QvpAtlasSurahC>), int Function(PtrAtlas, int, ffi.Pointer<QvpAtlasSurahC>)>('qvp_atlas_surah');
  late final atlasSurahAt = lib.lookupFunction<ffi.Int32 Function(PtrAtlas, ffi.Uint32, ffi.Pointer<QvpAtlasSurahC>), int Function(PtrAtlas, int, ffi.Pointer<QvpAtlasSurahC>)>('qvp_atlas_surah_at');
  late final atlasDivision = lib.lookupFunction<ffi.Int32 Function(PtrAtlas, ffi.Uint8, ffi.Uint16, ffi.Pointer<QvpAtlasRubuAlHizbC>), int Function(PtrAtlas, int, int, ffi.Pointer<QvpAtlasRubuAlHizbC>)>('qvp_atlas_division');
  late final atlasDivisionOf = lib.lookupFunction<ffi.Int32 Function(PtrAtlas, ffi.Uint8, ffi.Uint16, ffi.Uint16), int Function(PtrAtlas, int, int, int)>('qvp_atlas_division_of');
  late final atlasPagesOfJuz = lib.lookupFunction<ffi.Int32 Function(PtrAtlas, ffi.Uint16, PtrU16), int Function(PtrAtlas, int, PtrU16)>('qvp_atlas_pages_of_juz');
  late final atlasSearchSurahs = lib.lookupFunction<ffi.Uint32 Function(PtrAtlas, PtrU8, ffi.Uint32, PtrU16, ffi.Uint32), int Function(PtrAtlas, PtrU8, int, PtrU16, int)>('qvp_atlas_search_surahs');
  late final atlasJson = lib.lookupFunction<ffi.Void Function(PtrAtlas, PtrStr), void Function(PtrAtlas, PtrStr)>('qvp_atlas_json');

  // passage
  late final passageLoad = lib.lookupFunction<PtrPassage Function(PtrPages, ffi.Uint32, ffi.Uint16, ffi.Uint16, ffi.Uint16), PtrPassage Function(PtrPages, int, int, int, int)>('qvp_passage_load');
  late final passageLoadBasmalah = lib.lookupFunction<PtrPassage Function(PtrPages, ffi.Uint32, ffi.Uint16), PtrPassage Function(PtrPages, int, int)>('qvp_passage_load_basmalah');
  late final passageFree = lib.lookupFunction<ffi.Void Function(PtrPassage), void Function(PtrPassage)>('qvp_passage_free');
  late final passageAyahCount = lib.lookupFunction<ffi.Uint32 Function(PtrPassage), int Function(PtrPassage)>('qvp_passage_ayah_count');
  late final passageAyahText = lib.lookupFunction<ffi.Void Function(PtrPassage, ffi.Uint32, PtrStr), void Function(PtrPassage, int, PtrStr)>('qvp_passage_ayah_text');
  late final passageLineSpacing = lib.lookupFunction<ffi.Float Function(PtrPassage), double Function(PtrPassage)>('qvp_passage_line_spacing');
  late final passageLayout = lib.lookupFunction<ffi.Int32 Function(PtrPassage, ffi.Pointer<QvpPassageSpecC>, ffi.Pointer<QvpPassageLayoutC>), int Function(PtrPassage, ffi.Pointer<QvpPassageSpecC>, ffi.Pointer<QvpPassageLayoutC>)>('qvp_passage_layout');
  late final passageRows = lib.lookupFunction<ffi.Uint32 Function(PtrPassage, ffi.Pointer<QvpPassageRowC>, ffi.Uint32), int Function(PtrPassage, ffi.Pointer<QvpPassageRowC>, int)>('qvp_passage_rows');
  late final passageWords = lib.lookupFunction<ffi.Uint32 Function(PtrPassage, ffi.Pointer<QvpPassageWordC>, ffi.Uint32), int Function(PtrPassage, ffi.Pointer<QvpPassageWordC>, int)>('qvp_passage_words');
  late final passageAyahs = lib.lookupFunction<ffi.Uint32 Function(PtrPassage, ffi.Pointer<QvpPassageAyahC>, ffi.Uint32), int Function(PtrPassage, ffi.Pointer<QvpPassageAyahC>, int)>('qvp_passage_ayahs');
  late final passageDrawList = lib.lookupFunction<ffi.Uint32 Function(PtrPassage, PtrU32, ffi.Uint32), int Function(PtrPassage, PtrU32, int)>('qvp_passage_draw_list');
  late final passagePlacements = lib.lookupFunction<ffi.Uint32 Function(PtrPassage, PtrF32, ffi.Uint32), int Function(PtrPassage, PtrF32, int)>('qvp_passage_placements');

  // dress: another mushaf's ornaments
  late final ornamentsLoad = lib.lookupFunction<PtrOrnaments Function(PtrU8, ffi.Size), PtrOrnaments Function(PtrU8, int)>('qvp_ornaments_load');
  late final ornamentsFree = lib.lookupFunction<ffi.Void Function(PtrOrnaments), void Function(PtrOrnaments)>('qvp_ornaments_free');
  late final ornamentCount = lib.lookupFunction<ffi.Uint32 Function(PtrOrnaments), int Function(PtrOrnaments)>('qvp_ornament_count');
  late final ornamentInfo = lib.lookupFunction<ffi.Int32 Function(PtrOrnaments, ffi.Uint32, ffi.Pointer<QvpOrnamentC>), int Function(PtrOrnaments, int, ffi.Pointer<QvpOrnamentC>)>('qvp_ornament_info');
  late final ornamentFind = lib.lookupFunction<ffi.Int32 Function(PtrOrnaments, ffi.Uint32, PtrU8, ffi.Uint32), int Function(PtrOrnaments, int, PtrU8, int)>('qvp_ornament_find');
  late final ornamentPart = lib.lookupFunction<ffi.Int32 Function(PtrOrnaments, ffi.Uint32, ffi.Uint32, ffi.Pointer<QvpOrnamentPartC>), int Function(PtrOrnaments, int, int, ffi.Pointer<QvpOrnamentPartC>)>('qvp_ornament_part');
  late final dress = lib.lookupFunction<ffi.Int32 Function(PtrPage, PtrOrnaments, ffi.Pointer<QvpDressSpecC>), int Function(PtrPage, PtrOrnaments, ffi.Pointer<QvpDressSpecC>)>('qvp_dress');
  late final undress = lib.lookupFunction<ffi.Void Function(PtrPage), void Function(PtrPage)>('qvp_undress');
  late final dressInfo = lib.lookupFunction<ffi.Int32 Function(PtrPage, ffi.Pointer<QvpDressInfoC>), int Function(PtrPage, ffi.Pointer<QvpDressInfoC>)>('qvp_dress_info');
  late final dressClamp = lib.lookupFunction<ffi.Void Function(PtrPage, ffi.Pointer<QvpViewC>, ffi.Float, ffi.Float, ffi.Pointer<QvpViewC>), void Function(PtrPage, ffi.Pointer<QvpViewC>, double, double, ffi.Pointer<QvpViewC>)>('qvp_dress_clamp');
  late final dressView = lib.lookupFunction<ffi.Void Function(PtrPage, ffi.Float, ffi.Float, ffi.Pointer<QvpViewC>, ffi.Pointer<ffi.Float>), void Function(PtrPage, double, double, ffi.Pointer<QvpViewC>, ffi.Pointer<ffi.Float>)>('qvp_dress_view');
  late final dressGeometry = lib.lookupFunction<ffi.Void Function(PtrPage, ffi.Pointer<QvpDressGeometryC>), void Function(PtrPage, ffi.Pointer<QvpDressGeometryC>)>('qvp_dress_geometry');

  // names
  late final markName = lib.lookupFunction<ffi.Void Function(ffi.Uint8, PtrStr), void Function(int, PtrStr)>('qvp_mark_name');
  late final familyName = lib.lookupFunction<ffi.Void Function(ffi.Uint8, PtrStr), void Function(int, PtrStr)>('qvp_family_name');
  late final kindName = lib.lookupFunction<ffi.Void Function(ffi.Uint8, PtrStr), void Function(int, PtrStr)>('qvp_kind_name');
  late final categoryName = lib.lookupFunction<ffi.Void Function(ffi.Uint8, PtrStr), void Function(int, PtrStr)>('qvp_category_name');
  late final markFromName = lib.lookupFunction<ffi.Uint8 Function(PtrU8, ffi.Uint32), int Function(PtrU8, int)>('qvp_mark_from_name');
  late final markCategory = lib.lookupFunction<ffi.Uint8 Function(ffi.Uint8), int Function(int)>('qvp_mark_category');
  late final nameCount = lib.lookupFunction<ffi.Uint32 Function(ffi.Uint8), int Function(int)>('qvp_name_count');
  late final name = lib.lookupFunction<ffi.Void Function(ffi.Uint8, ffi.Uint8, PtrStr), void Function(int, int, PtrStr)>('qvp_name');
  late final nameId = lib.lookupFunction<ffi.Uint8 Function(ffi.Uint8, PtrU8, ffi.Uint32), int Function(int, PtrU8, int)>('qvp_name_id');
  late final version = lib.lookupFunction<ffi.Void Function(PtrStr), void Function(PtrStr)>('qvp_version');
  late final formatVersion = lib.lookupFunction<ffi.Uint32 Function(), int Function()>('qvp_format_version');
  late final engineName = lib.lookupFunction<ffi.Pointer<ffi.Char> Function(), ffi.Pointer<ffi.Char> Function()>('qvp_engine_name');

  // the reader's pan and zoom
  late final viewZoomAbout = lib.lookupFunction<ffi.Void Function(ffi.Pointer<QvpViewC>, ffi.Float, ffi.Float, ffi.Float, ffi.Float, ffi.Float, ffi.Pointer<QvpViewC>), void Function(ffi.Pointer<QvpViewC>, double, double, double, double, double, ffi.Pointer<QvpViewC>)>('qvp_view_zoom_about');
  late final viewPan = lib.lookupFunction<ffi.Void Function(ffi.Pointer<QvpViewC>, ffi.Float, ffi.Float, ffi.Pointer<QvpViewC>), void Function(ffi.Pointer<QvpViewC>, double, double, ffi.Pointer<QvpViewC>)>('qvp_view_pan');
  late final viewClamp = lib.lookupFunction<ffi.Void Function(ffi.Pointer<QvpViewC>, ffi.Float, ffi.Float, ffi.Float, ffi.Float, ffi.Pointer<QvpViewC>), void Function(ffi.Pointer<QvpViewC>, double, double, double, double, ffi.Pointer<QvpViewC>)>('qvp_view_clamp');
  late final viewAnchor = lib.lookupFunction<ffi.Void Function(PtrPage, ffi.Pointer<QvpViewC>, ffi.Uint32, ffi.Float, ffi.Float, ffi.Float, ffi.Float, ffi.Float, ffi.Float, ffi.Pointer<QvpViewC>), void Function(PtrPage, ffi.Pointer<QvpViewC>, int, double, double, double, double, double, double, ffi.Pointer<QvpViewC>)>('qvp_view_anchor');
  late final viewToLayout = lib.lookupFunction<ffi.Void Function(PtrPage, ffi.Pointer<QvpViewC>, ffi.Float, ffi.Float, PtrF32), void Function(PtrPage, ffi.Pointer<QvpViewC>, double, double, PtrF32)>('qvp_view_to_layout');
  late final viewSwipe = lib.lookupFunction<ffi.Int32 Function(ffi.Float, ffi.Float, ffi.Float, ffi.Float), int Function(double, double, double, double)>('qvp_view_swipe');
  late final swipePages = lib.lookupFunction<ffi.Int32 Function(ffi.Float, ffi.Float, ffi.Float, ffi.Float), int Function(double, double, double, double)>('qvp_swipe_pages');
  late final zoomMode = lib.lookupFunction<ffi.Void Function(PtrPage, ffi.Pointer<QvpLayoutSpecC>, ffi.Pointer<QvpZoomC>, ffi.Uint32, ffi.Pointer<QvpZoomC>), void Function(PtrPage, ffi.Pointer<QvpLayoutSpecC>, ffi.Pointer<QvpZoomC>, int, ffi.Pointer<QvpZoomC>)>('qvp_zoom_mode');
  late final zoomPinch = lib.lookupFunction<ffi.Void Function(PtrPage, ffi.Pointer<QvpLayoutSpecC>, ffi.Pointer<QvpZoomC>, ffi.Pointer<QvpViewC>, ffi.Float, ffi.Float, ffi.Float, ffi.Pointer<QvpZoomChangeC>), void Function(PtrPage, ffi.Pointer<QvpLayoutSpecC>, ffi.Pointer<QvpZoomC>, ffi.Pointer<QvpViewC>, double, double, double, ffi.Pointer<QvpZoomChangeC>)>('qvp_zoom_pinch');
  late final zoomToStep = lib.lookupFunction<ffi.Void Function(PtrPage, ffi.Pointer<QvpLayoutSpecC>, ffi.Pointer<QvpZoomC>, ffi.Uint32, ffi.Pointer<QvpViewC>, ffi.Pointer<QvpZoomChangeC>), void Function(PtrPage, ffi.Pointer<QvpLayoutSpecC>, ffi.Pointer<QvpZoomC>, int, ffi.Pointer<QvpViewC>, ffi.Pointer<QvpZoomChangeC>)>('qvp_zoom_to_step');
  late final zoomSpec = lib.lookupFunction<ffi.Void Function(PtrPage, ffi.Pointer<QvpLayoutSpecC>, ffi.Pointer<QvpZoomC>, ffi.Pointer<QvpLayoutSpecC>), void Function(PtrPage, ffi.Pointer<QvpLayoutSpecC>, ffi.Pointer<QvpZoomC>, ffi.Pointer<QvpLayoutSpecC>)>('qvp_zoom_spec');
  late final zoomCarried = lib.lookupFunction<ffi.Void Function(PtrPage, ffi.Pointer<QvpLayoutSpecC>, ffi.Pointer<QvpZoomC>, ffi.Pointer<QvpZoomC>), void Function(PtrPage, ffi.Pointer<QvpLayoutSpecC>, ffi.Pointer<QvpZoomC>, ffi.Pointer<QvpZoomC>)>('qvp_zoom_carried');
  late final zoomAtStep = lib.lookupFunction<ffi.Float Function(PtrPage, ffi.Pointer<QvpLayoutSpecC>, ffi.Uint32), double Function(PtrPage, ffi.Pointer<QvpLayoutSpecC>, int)>('qvp_zoom_at_step');
  late final zoomIsZoomed = lib.lookupFunction<ffi.Int Function(ffi.Pointer<QvpZoomC>, ffi.Pointer<QvpViewC>, ffi.Float), int Function(ffi.Pointer<QvpZoomC>, ffi.Pointer<QvpViewC>, double)>('qvp_zoom_is_zoomed');
  late final sidewaysDrag = lib.lookupFunction<ffi.Uint32 Function(PtrPage, ffi.Pointer<QvpZoomC>, ffi.Pointer<QvpViewC>, ffi.Float), int Function(PtrPage, ffi.Pointer<QvpZoomC>, ffi.Pointer<QvpViewC>, double)>('qvp_sideways_drag');
  late final zoomSteps = lib.lookupFunction<ffi.Uint32 Function(PtrPage, ffi.Pointer<QvpLayoutSpecC>, PtrF32, ffi.Uint32), int Function(PtrPage, ffi.Pointer<QvpLayoutSpecC>, PtrF32, int)>('qvp_zoom_steps');
  late final zoomLevels = lib.lookupFunction<ffi.Uint32 Function(PtrPage, ffi.Pointer<QvpLayoutSpecC>, PtrF32, ffi.Uint32, ffi.Float, PtrF32, ffi.Uint32), int Function(PtrPage, ffi.Pointer<QvpLayoutSpecC>, PtrF32, int, double, PtrF32, int)>('qvp_zoom_levels');
  late final zoomLevelCandidates = lib.lookupFunction<ffi.Uint32 Function(PtrPage, ffi.Pointer<QvpLayoutSpecC>, ffi.Float, ffi.Float, ffi.Float, PtrF32, PtrF32, ffi.Uint32), int Function(PtrPage, ffi.Pointer<QvpLayoutSpecC>, double, double, double, PtrF32, PtrF32, int)>('qvp_zoom_level_candidates');
  late final reflowMaxZoom = lib.lookupFunction<ffi.Float Function(PtrPage, ffi.Pointer<QvpLayoutSpecC>), double Function(PtrPage, ffi.Pointer<QvpLayoutSpecC>)>('qvp_reflow_max_zoom');

  // layout draws
  late final layoutCurrent = lib.lookupFunction<ffi.Int Function(PtrPage, ffi.Pointer<QvpLayoutC>), int Function(PtrPage, ffi.Pointer<QvpLayoutC>)>('qvp_layout_current');
  late final layoutDrawList = lib.lookupFunction<ffi.Uint32 Function(PtrPage, ffi.Float, ffi.Float, PtrU32, ffi.Uint32), int Function(PtrPage, double, double, PtrU32, int)>('qvp_layout_draw_list');
  late final layoutPlacements = lib.lookupFunction<ffi.Uint32 Function(PtrPage, PtrF32, ffi.Uint32), int Function(PtrPage, PtrF32, int)>('qvp_layout_placements');
  late final layoutGroups = lib.lookupFunction<ffi.Uint32 Function(PtrPage, PtrF32, ffi.Uint32), int Function(PtrPage, PtrF32, int)>('qvp_layout_groups');
  late final layoutRepeats = lib.lookupFunction<ffi.Uint32 Function(PtrPage, PtrF32, ffi.Uint32), int Function(PtrPage, PtrF32, int)>('qvp_layout_repeats');
  late final layoutPathGroups = lib.lookupFunction<ffi.Uint32 Function(PtrPage, PtrU32, ffi.Uint32), int Function(PtrPage, PtrU32, int)>('qvp_layout_path_groups');
  late final layoutOmittedPaths = lib.lookupFunction<ffi.Uint32 Function(PtrPage, PtrU32, ffi.Uint32), int Function(PtrPage, PtrU32, int)>('qvp_layout_omitted_paths');
  late final layoutRowWords = lib.lookupFunction<ffi.Uint32 Function(PtrPage, ffi.Uint32, PtrU32, ffi.Uint32), int Function(PtrPage, int, PtrU32, int)>('qvp_layout_row_words');
  late final layoutWordRow = lib.lookupFunction<ffi.Uint32 Function(PtrPage, ffi.Uint32), int Function(PtrPage, int)>('qvp_layout_word_row');
}

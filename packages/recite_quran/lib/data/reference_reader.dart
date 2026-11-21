// lib/data/reference_reader_v4.dart
// Reader for expected_tj3.zfx: the reference data (expected units of each ayah).
// Compatible with both pure Dart and FFI zf_tajweed_reference C API.

import 'dart:io';
import 'dart:typed_data';

/// One madd site of an ayah (from the zfx madd section).
class MaddEntry {
  /// Token index (within the ayah) the entry is attached to.
  final int tokenIndex;

  /// Rule class: 1 fixed2, 2 muttasil, 3 free, 4 lazim, 5 consonant length
  /// (leen & ghunna lengths, not on the madd ladder).
  final int ruleClass;

  /// Kind: 0 fixed, 1 free.
  final int kind;

  /// Allowed elongation counts (bit c = count c is a legal recitation).
  final int allowedCounts;

  /// Counts accepted when scoring (bit c = count c).
  final int scoringCounts;

  /// Canonical elongation count in Harakat.
  final int canonicalCount;

  /// Bit 0 = the entry's base is a madd letter (the madd ladder applies);
  /// clear = consonant length (leen / ghunna).
  final int flags;

  const MaddEntry({
    required this.tokenIndex,
    required this.ruleClass,
    required this.kind,
    required this.allowedCounts,
    required this.scoringCounts,
    required this.canonicalCount,
    required this.flags,
  });

  /// Whether the entry's base is a madd letter (alef/waw/yeh madd).
  bool get isMaddLetterBase => (flags & 1) != 0;
}

/// All expected tajweed rule classes attached to one reference token.
///
/// An ayah can carry multiple sites of every rule: each token independently
/// flags gemination, qalqalah, ghunna, tafkheem and madd, and a token with a
/// madd site links to its full [MaddEntry] (allowed/scoring/canonical counts).
class TokenRuleSite {
  /// Index of the token within the ayah.
  final int tokenIndex;

  /// Raw 16-bit flag word from the zfx token-flags section.
  final int flags;

  /// The madd entry attached to this token, if any.
  final MaddEntry? madd;

  const TokenRuleSite({
    required this.tokenIndex,
    required this.flags,
    this.madd,
  });

  /// Geminate (Shaddah) consonant — hold ~1.5 harakat (tj3 rule 9).
  bool get isGeminate => (flags & (1 << 0)) != 0;

  /// Qalqalah release site (b j d T q with no vowel after).
  bool get isQalqalahSite => (flags & (1 << 1)) != 0;

  /// Expected qalqalah class: 0 none, 1 sughra, 2 kubra.
  int get qalqalahExpected => (flags >> 2) & 0x3;

  /// Expected ghunna class (0-4) on this token (nasal sites).
  int get ghunnaExpected => (flags >> 4) & 0x7;

  /// Madd class of the entry at this token: 0 none, 1 fixed2, 2 muttasil,
  /// 3 free, 4 lazim, 5 consonant length.
  int get maddClass => madd?.ruleClass ?? ((flags >> 9) & 0x7);
}

/// The expected reference units for a specific Quranic ayah in TajweedFormer v4.
class AyahReferenceUnits {
  final int surah;
  final int ayah;
  final List<int> units;
  final List<int> wordIndices;
  final int wordCount;

  /// Per-token tj3 flag word (u16), parallel to [units]:
  ///   bit 0     geminate (Shaddah) consonant
  ///   bit 1     qalqalah site
  ///   bits 2-3  qalqalah expected class (0-2)
  ///   bits 4-6  ghunna expected class (0-4)
  ///   bits 7-8  tafkheem expected class (0-2)
  ///   bits 9-11 madd class of the entry at this token (0 none, 1 fixed2,
  ///             2 muttasil, 3 free, 4 lazim, 5 consonant length)
  final List<int> tokenFlags;

  /// Madd entries of this ayah (one per madd site, sorted by token).
  final List<MaddEntry> maddEntries;

  const AyahReferenceUnits({
    required this.surah,
    required this.ayah,
    required this.units,
    required this.wordIndices,
    required this.wordCount,
    this.tokenFlags = const [],
    this.maddEntries = const [],
  });

  /// All expected tajweed rule sites of this ayah, one per token. A token can
  /// carry several rules at once (e.g. geminate + ghunna), and different
  /// tokens carry different rules — an ayah may hold any number of sites of
  /// any rule.
  List<TokenRuleSite> get ruleSites {
    return List.generate(
      units.length,
      (i) => TokenRuleSite(
        tokenIndex: i,
        flags: i < tokenFlags.length ? tokenFlags[i] : 0,
        madd: maddByToken?[i],
      ),
      growable: false,
    );
  }

  Map<int, MaddEntry>? get maddByToken {
    if (maddEntries.isEmpty) return null;
    return {for (final e in maddEntries) e.tokenIndex: e};
  }
}

/// Reader for expected_tj3.zfx binary table containing canonical Hafs recitation units.
class TajweedFormerReferenceReader {
  static const int _headerSize = 160;
  static const List<int> _magic = [
    0x5A,
    0x46,
    0x54,
    0x4A,
    0x45,
    0x58,
    0x50,
    0x31
  ]; // 'ZFTJEXP1'
  static const int _ayahRecordSize = 20;

  final Uint8List _bytes;
  final ByteData _bd;

  late final int surahs;
  late final int totalAyahs;
  late final int totalTokens;
  late final int totalMadd;
  late final int formsBytes;
  late final Uint8List tokensSha256;

  late final int _offAyahCounts;
  late final int _offAyahIndex;
  late final int _offTokens;
  late final int _offWords;
  late final int _offFlags;
  late final int _offMadd;

  late final List<int> _surahFirst;

  TajweedFormerReferenceReader._(this._bytes)
      : _bd = ByteData.sublistView(_bytes) {
    _parse();
  }

  /// Opens a reference table from disk.
  static Future<TajweedFormerReferenceReader> fromFile(String filePath) async {
    final file = File(filePath);
    final bytes = await file.readAsBytes();
    return TajweedFormerReferenceReader._(bytes);
  }

  /// Opens a reference table synchronously from disk.
  static TajweedFormerReferenceReader fromFileSync(String filePath) {
    final file = File(filePath);
    final bytes = file.readAsBytesSync();
    return TajweedFormerReferenceReader._(bytes);
  }

  /// Opens a reference table from memory bytes.
  factory TajweedFormerReferenceReader.fromBytes(Uint8List bytes) {
    return TajweedFormerReferenceReader._(bytes);
  }

  void _parse() {
    if (_bytes.length < _headerSize) {
      throw const FormatException('reference data: too short for header');
    }
    for (int i = 0; i < 8; i++) {
      if (_bytes[i] != _magic[i]) {
        throw const FormatException('reference data: not a ZFTJEXP1 file');
      }
    }

    final version = _bd.getUint32(8, Endian.little);
    if (version != 1) {
      throw FormatException('reference data: unsupported version $version');
    }

    final headerSize = _bd.getUint32(12, Endian.little);
    final fileSize = _bd.getUint32(16, Endian.little);
    if (headerSize != _headerSize || fileSize != _bytes.length) {
      throw const FormatException(
          'reference data: header or size mismatch (truncated?)');
    }

    surahs = _bd.getUint32(20, Endian.little);
    totalAyahs = _bd.getUint32(24, Endian.little);
    totalTokens = _bd.getUint32(28, Endian.little);
    totalMadd = _bd.getUint32(32, Endian.little);
    formsBytes = _bd.getUint32(36, Endian.little);

    tokensSha256 = Uint8List.fromList(_bytes.sublist(72, 104));

    _offAyahCounts = _bd.getUint32(104, Endian.little);
    _offAyahIndex = _bd.getUint32(108, Endian.little);
    _offTokens = _bd.getUint32(112, Endian.little);
    _offWords = _bd.getUint32(116, Endian.little);
    _offFlags = _bd.getUint32(120, Endian.little);
    _offMadd = _bd.getUint32(124, Endian.little);

    _surahFirst = List<int>.filled(surahs + 1, 0);
    int acc = 0;
    for (int s = 0; s < surahs; s++) {
      _surahFirst[s] = acc;
      acc += _bd.getUint16(_offAyahCounts + 2 * s, Endian.little);
    }
    _surahFirst[surahs] = acc;

    if (acc != totalAyahs) {
      throw const FormatException('reference data: ayah counts do not add up');
    }
  }

  /// Number of ayahs in [surah] (1-114). Returns 0 if surah is out of range.
  int ayahCount(int surah) {
    if (surah < 1 || surah > surahs) return 0;
    return _surahFirst[surah] - _surahFirst[surah - 1];
  }

  /// Resolves the expected units and word indices for [surah] and [ayah] (both 1-indexed).
  /// Returns null if [surah] or [ayah] is not present in the table.
  AyahReferenceUnits? getAyahUnits(int surah, int ayah) {
    if (surah < 1 || surah > surahs) return null;
    final totalInSurah = ayahCount(surah);
    if (ayah < 1 || ayah > totalInSurah) return null;

    final int ayahIndex = _surahFirst[surah - 1] + ayah - 1;
    final int recordOffset = _offAyahIndex + ayahIndex * _ayahRecordSize;

    final int firstToken = _bd.getUint32(recordOffset, Endian.little);
    final int firstMadd = _bd.getUint32(recordOffset + 4, Endian.little);
    final int count = _bd.getUint16(recordOffset + 12, Endian.little);
    final int maddCount = _bd.getUint16(recordOffset + 14, Endian.little);
    final int wordCount = _bytes[recordOffset + 16];

    final units = List<int>.generate(
      count,
      (i) => _bytes[_offTokens + firstToken + i],
      growable: false,
    );

    final wordIndices = List<int>.generate(
      count,
      (i) => _bytes[_offWords + firstToken + i],
      growable: false,
    );

    final tokenFlags = List<int>.generate(
      count,
      (i) => _bd.getUint16(_offFlags + 2 * (firstToken + i), Endian.little),
      growable: false,
    );

    // Madd entries (8 bytes each, sorted by token within the ayah).
    final maddEntries = List<MaddEntry>.generate(
      maddCount,
      (i) {
        final int entryOffset = _offMadd + (firstMadd + i) * 8;
        return MaddEntry(
          tokenIndex: _bd.getUint16(entryOffset, Endian.little),
          ruleClass: _bytes[entryOffset + 2],
          kind: _bytes[entryOffset + 3],
          allowedCounts: _bytes[entryOffset + 4],
          scoringCounts: _bytes[entryOffset + 5],
          canonicalCount: _bytes[entryOffset + 6],
          flags: _bytes[entryOffset + 7],
        );
      },
      growable: false,
    );

    return AyahReferenceUnits(
      surah: surah,
      ayah: ayah,
      units: units,
      wordIndices: wordIndices,
      wordCount: wordCount,
      tokenFlags: tokenFlags,
      maddEntries: maddEntries,
    );
  }

  /// Vocabulary mapping of tj3 IDs (0-37) to standard string representations.
  static const List<String> vocabTokens = [
    '<blk>', // 0
    '|', // 1
    'ء', // 2
    'ب', // 3
    'ت', // 4
    'ث', // 5
    'ج', // 6
    'ح', // 7
    'خ', // 8
    'د', // 9
    'ذ', // 10
    'ر', // 11
    'ز', // 12
    'س', // 13
    'ش', // 14
    'ص', // 15
    'ض', // 16
    'ط', // 17
    'ظ', // 18
    'ع', // 19
    'غ', // 20
    'ف', // 21
    'ق', // 22
    'ك', // 23
    'ل', // 24
    'م', // 25
    'ن', // 26
    'ه', // 27
    'و', // 28
    'ي', // 29
    'ں', // 30
    'a', // 31
    'i', // 32
    'u', // 33
    'aa', // 34
    'ii', // 35
    'uu', // 36
    '<foreign>', // 37
  ];

  /// Translates a single tj3 id to its token string ('?' if out of range).
  static String idToToken(int id) {
    if (id >= 0 && id < vocabTokens.length) {
      return vocabTokens[id];
    }
    return '?';
  }

  GlobalPhoneticSearchIndex? _cachedGlobalSearchIndex;

  /// Extracts the full continuous Quran phonetic text and (surah, ayah, wordIndex) coordinate index.
  ///
  /// Derives character sequences and coordinates directly from expected_tj3.zfx in memory,
  /// matching the Python reference implementation in QuranReciteToText/src/matching/reference.py.
  GlobalPhoneticSearchIndex getGlobalPhoneticSearchIndex() {
    if (_cachedGlobalSearchIndex != null) return _cachedGlobalSearchIndex!;

    final StringBuffer phBuffer = StringBuffer();
    // 522,475 chars * 3 coords = 1,567,425 elements.
    final List<int> coords = [];

    int gIdx = 0;
    for (int sIdx = 0; sIdx < surahs; sIdx++) {
      final int s = sIdx + 1;
      final int numAyahs =
          _bd.getUint16(_offAyahCounts + 2 * sIdx, Endian.little);

      for (int a = 1; a <= numAyahs; a++) {
        final int recordOffset = _offAyahIndex + gIdx * _ayahRecordSize;
        gIdx++;

        final int firstToken = _bd.getUint32(recordOffset, Endian.little);
        final int tokCount = _bd.getUint16(recordOffset + 12, Endian.little);

        for (int i = 0; i < tokCount; i++) {
          final int t = _bytes[_offTokens + firstToken + i];
          if (t == 1) continue; // skip '|' (word bar)
          if (t == 0 || t == 37) continue; // skip <blk> and <foreign>

          final String tokStr = idToToken(t);
          if (tokStr.isEmpty || tokStr == '?') continue;

          final int wid = _bytes[_offWords + firstToken + i];

          phBuffer.write(tokStr);
          for (int c = 0; c < tokStr.length; c++) {
            coords.add(s);
            coords.add(a);
            coords.add(wid);
          }
        }
      }
    }

    final String refPhNorm = phBuffer.toString();
    final Uint16List indexArray = Uint16List.fromList(coords);

    _cachedGlobalSearchIndex = GlobalPhoneticSearchIndex(
      refPhNorm: refPhNorm,
      indexArray: indexArray,
    );
    return _cachedGlobalSearchIndex!;
  }
}

/// Full global phonetic search index derived directly from expected_tj3.zfx.
class GlobalPhoneticSearchIndex {
  /// Continuous phoneme string for the whole Quran (522,475 chars).
  final String refPhNorm;

  /// Parallel (surah, ayah, wordIndex) coordinate array of shape (N * 3).
  final Uint16List indexArray;

  const GlobalPhoneticSearchIndex({
    required this.refPhNorm,
    required this.indexArray,
  });
}

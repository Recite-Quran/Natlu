import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'reference_reader.dart';

export 'reference_reader.dart';

// ---------------------------------------------------------------------------
// quran_data.dart
//
// Tracking reference data model (TajweedFormer V4).
// expected_tj3.zfx is the sole source of truth for phonemes, word segmentation,
// and Tajweed rule sites.
// No UI display text, font metadata, or Surah names belong in this engine package.
// ---------------------------------------------------------------------------

/// Number of initial acoustic letter units to merge into 1 calligraphy word
/// for verses starting with Muqatta'at (disjoint letters).
///
/// In expected_tj3.zfx acoustic units, disjoint letters are separated by '|'
/// (e.g. 'الم' is 3 units, 'طس' is 2 units).
/// Verses with single disjoint letters (38:1 'ص', 50:1 'ق', 68:1 'ن') are
/// already 1 word in zfx and need no merging.
const Map<int, int> _kMuqattaatPrefixMergeCounts = {
  (2 << 16) | 1: 3, // الم
  (3 << 16) | 1: 3, // الم
  (7 << 16) | 1: 4, // المص
  (10 << 16) | 1: 3, // الر (followed by: تلك آيات الكتاب الحكيم)
  (11 << 16) | 1: 3, // الر (followed by: كتاب أحكمت آياته...)
  (12 << 16) | 1: 3, // الر (followed by: تلك آيات الكتاب المبين)
  (13 << 16) | 1: 4, // المر (followed by: تلك آيات الكتاب...)
  (14 << 16) | 1: 3, // الر (followed by: كتاب أنزلناه...)
  (15 << 16) | 1: 3, // الر (followed by: تلك آيات الكتاب...)
  (19 << 16) | 1: 5, // كهيعص
  (20 << 16) | 1: 2, // طه
  (26 << 16) | 1: 3, // طسم
  (27 << 16) | 1: 2, // طس (followed by: تلك آيات القرآن...)
  (28 << 16) | 1: 3, // طسم
  (29 << 16) | 1: 3, // الم
  (30 << 16) | 1: 3, // الم
  (31 << 16) | 1: 3, // الم
  (32 << 16) | 1: 3, // الم
  (36 << 16) | 1: 2, // يس
  (40 << 16) | 1: 2, // حم
  (41 << 16) | 1: 2, // حم
  (42 << 16) | 1: 2, // حم
  (42 << 16) | 2: 3, // عسق
  (43 << 16) | 1: 2, // حم
  (44 << 16) | 1: 2, // حم
  (45 << 16) | 1: 2, // حم
  (46 << 16) | 1: 2, // حم
};

class WordTajweedRule {
  final int ruleId; // 1-7 (Madd), 9 (Shaddah), 10 (Ghunnah)
  final String nameAr;
  final String nameEn;
  final num goldenLen; // in Harakat (1, 1.5, 2, 4, 6)

  const WordTajweedRule({
    required this.ruleId,
    required this.nameAr,
    required this.nameEn,
    required this.goldenLen,
  });

  Map<String, dynamic> toMap() => {
        'ruleId': ruleId,
        'nameAr': nameAr,
        'nameEn': nameEn,
        'goldenLen': goldenLen,
      };

  factory WordTajweedRule.fromMap(Map map) => WordTajweedRule(
        ruleId: map['ruleId'] as int? ?? 0,
        nameAr: map['nameAr'] as String? ?? '',
        nameEn: map['nameEn'] as String? ?? '',
        goldenLen: (map['goldenLen'] as num?) ?? 0,
      );
}

class QuranVerse {
  /// The surah (chapter) number, 1-indexed (1-114).
  final int surah;

  /// The ayah (verse) number within [surah], 1-indexed.
  final int ayah;

  /// Full tj3 phonetic text of this ayah (composed from the zfx tokens).
  final String textPhoneme;

  /// Per-word tj3 token strings composed from the zfx reference units.
  final List<String> phonemeWords;

  /// Expected tajweed rules per word, composed from the zfx rule sites.
  final List<List<WordTajweedRule>> wordRules;

  /// Per-word rule-class code per character of the word's phoneme string:
  /// 0 = plain, 1-based index into the word's [wordRules] otherwise.
  final List<List<int>> wordCharClasses;

  /// 1:1 word index map.
  List<int> get wordMap => List.generate(phonemeWords.length, (i) => i);

  /// Word count of this verse in the reference model.
  int get wordCount => phonemeWords.length;

  /// Words list alias for downstream callers.
  List<String> get uthmaniWords => phonemeWords;

  /// Text alias for downstream callers.
  String get textUthmani => textPhoneme;

  QuranVerse({
    required this.surah,
    required this.ayah,
    required this.textPhoneme,
    required this.phonemeWords,
    this.wordRules = const [],
    this.wordCharClasses = const [],
    List<int>? wordMap,
  });
}

class QuranMetadataService {
  /// Path to expected_tj3.zfx on disk, or null to load from bundled assets.
  QuranMetadataService({this.zfxFilePath});

  final String? zfxFilePath;

  TajweedFormerReferenceReader? _reference;

  /// The engine's tj3 reference table (expected units, words and rule sites).
  TajweedFormerReferenceReader? get reference => _reference;

  Future<void> loadData() async {
    if (_reference != null) return;

    try {
      final Uint8List zfxBytes;
      if (zfxFilePath != null) {
        if (!kIsWeb && File(zfxFilePath!).existsSync()) {
          zfxBytes = await File(zfxFilePath!).readAsBytes();
        } else {
          final data = await rootBundle.load(zfxFilePath!);
          zfxBytes = data.buffer.asUint8List(
            data.offsetInBytes,
            data.lengthInBytes,
          );
        }
      } else {
        File? localFile;
        if (!kIsWeb) {
          try {
            final appDir = await getApplicationDocumentsDirectory();
            final f = File('${appDir.path}/model/expected_tj3.zfx');
            if (f.existsSync()) localFile = f;
          } catch (_) {}
        }

        if (localFile != null) {
          zfxBytes = await localFile.readAsBytes();
        } else {
          final data = await _loadZfxFromBundle();
          zfxBytes = data.buffer.asUint8List(
            data.offsetInBytes,
            data.lengthInBytes,
          );
        }
      }
      _reference = TajweedFormerReferenceReader.fromBytes(zfxBytes);
    } catch (e) {
      debugPrint(
        'ReciteQuran: expected_tj3.zfx reference table unavailable: $e',
      );
      _reference = null;
    }
  }

  Future<ByteData> _loadZfxFromBundle() async {
    try {
      return await rootBundle.load(
          'packages/quran_tajweedformer/assets/tajweedformer_v4/expected_tj3.zfx');
    } catch (_) {
      return await rootBundle.load('assets/tajweedformer_v4/expected_tj3.zfx');
    }
  }
}

class ContinuousQuranWord {
  final int globalIndex;
  final int surah;
  final int ayah;
  final int wordInAyah;
  final String phoneme;
  final List<WordTajweedRule> rules;
  final List<int> charRuleClasses;

  const ContinuousQuranWord({
    required this.globalIndex,
    required this.surah,
    required this.ayah,
    required this.wordInAyah,
    required this.phoneme,
    this.rules = const [],
    this.charRuleClasses = const [],
  });
}

/// One composed reference word.
class ComposedWord {
  /// tj3 token string of the word (e.g. 'بaسa' — literal zfx tokens).
  final String phoneme;

  /// Rule-class code per character of [phoneme]: 0 = plain, otherwise
  /// 1-based index into [rules] (the rule expected at this character).
  final List<int> charRuleClasses;

  /// Expected tajweed rules of this word (any rule, multiple allowed).
  final List<WordTajweedRule> rules;

  const ComposedWord({
    required this.phoneme,
    required this.charRuleClasses,
    required this.rules,
  });
}

class ReferenceComposer {
  /// Composes the words of an ayah from its zfx reference units.
  ///
  /// Tokens sharing the same [AyahReferenceUnits.wordIndices] entry form one
  /// word; the '|' word bar is a separator and never enters the phoneme text.
  static List<ComposedWord> compose(AyahReferenceUnits ref) {
    final int n = ref.units.length;
    if (n == 0 || ref.wordIndices.isEmpty) return const [];

    final List<TokenRuleSite> sites = ref.ruleSites;
    final List<ComposedWord> words = [];

    int wordStart = 0;
    for (int i = 1; i <= n; i++) {
      final bool wordEnded =
          i == n || ref.wordIndices[i] != ref.wordIndices[i - 1];
      if (wordEnded) {
        words.add(_composeWord(ref, sites, wordStart, i));
        wordStart = i;
      }
    }
    return words;
  }

  /// Composes one word from the token slice [start, end) and its rule sites.
  static ComposedWord _composeWord(
    AyahReferenceUnits ref,
    List<TokenRuleSite> sites,
    int start,
    int end,
  ) {
    final StringBuffer sb = StringBuffer();
    final List<int> charClasses = [];

    // Flattened rule list for this word; char class = ruleIndex + 1.
    final List<WordTajweedRule> rules = [];
    final List<int> ruleOfClass = []; // parallel: zfx class code per rule

    for (int i = start; i < end; i++) {
      final String token = TajweedFormerReferenceReader.idToToken(ref.units[i]);
      if (token == '|') continue; // word bar: separator, not a sound

      final int? ruleIndex = _assignRule(sites[i], rules, ruleOfClass);

      sb.write(token);
      for (int c = 0; c < token.length; c++) {
        charClasses.add(ruleIndex ?? 0);
      }
    }

    return ComposedWord(
      phoneme: sb.toString(),
      charRuleClasses: charClasses,
      rules: rules,
    );
  }

  /// Maps one token's expected rule site to a WordTajweedRule, appending it to
  /// the word's rule list on first occurrence. Returns the 1-based class code
  /// for the char array, or null for a plain token.
  static int? _assignRule(
    TokenRuleSite site,
    List<WordTajweedRule> rules,
    List<int> ruleOfClass,
  ) {
    // Priority: madd site > ghunna > shaddah (a token carries at most one
    // graded duration rule in the reference data).
    final MaddEntry? madd = site.madd;
    final int maddFlagClass = site.maddClass;

    if (madd != null || maddFlagClass != 0) {
      final int klass = madd?.ruleClass ?? maddFlagClass;
      final int canonical = madd?.canonicalCount ?? _defaultCanonical(klass);
      final bool maddLetterBase = madd?.isMaddLetterBase ?? false;
      final int ruleId = _maddRuleId(klass, maddLetterBase);
      if (ruleId == 0) return null;
      return _intern(rules, ruleOfClass, ruleId, canonical <= 0 ? 2 : canonical, klass);
    }

    if (site.ghunnaExpected > 0) {
      return _intern(rules, ruleOfClass, 10, 2, 0);
    }

    if (site.isGeminate) {
      return _intern(rules, ruleOfClass, 9, 1, 0);
    }

    if (site.isQalqalahSite) {
      return _intern(rules, ruleOfClass, 8, 1, site.qalqalahExpected);
    }

    return null;
  }

  /// Default canonical elongation per madd class when the zfx entry is absent
  /// (flag-only sites): 1 fixed2 -> 2, 2 muttasil -> 4, 3 free -> 4,
  /// 4 lazim -> 6, 5 consonant length -> 2.
  static int _defaultCanonical(int klass) => switch (klass) {
        1 => 2,
        2 => 4,
        3 => 4,
        4 => 6,
        5 => 2,
        _ => 2,
      };

  /// zfx madd class -> WordTajweedRule rule id.
  /// 1 fixed2 -> rule 1, 2 muttasil -> rule 3, 3 free -> rule 5,
  /// 4 lazim -> rule 6, 5 consonant length -> rule 7 (madd letter base: leen)
  /// or rule 10 (consonant base: ghunna length). 0 = not a graded site.
  static int _maddRuleId(int klass, bool maddLetterBase) {
    switch (klass) {
      case 1:
        return 1;
      case 2:
        return 3;
      case 3:
        return 5;
      case 4:
        return 6;
      case 5:
        return maddLetterBase ? 7 : 10;
      default:
        return 0;
    }
  }

  /// Finds an existing identical rule in the word's list or appends a new one.
  /// Returns the 1-based class code to mark the token's characters with.
  static int _intern(
    List<WordTajweedRule> rules,
    List<int> ruleOfClass,
    int ruleId,
    int goldenLen,
    int zfxClass,
  ) {
    for (int i = 0; i < rules.length; i++) {
      final r = rules[i];
      if (r.ruleId == ruleId &&
          r.goldenLen == goldenLen &&
          (zfxClass == 0 || ruleOfClass[i] == zfxClass)) {
        return i + 1;
      }
    }
    rules.add(
      WordTajweedRule(
        ruleId: ruleId,
        nameAr: _defaultRuleNameAr(ruleId),
        nameEn: _defaultRuleNameEn(ruleId),
        goldenLen: goldenLen,
      ),
    );
    ruleOfClass.add(zfxClass);
    return rules.length;
  }

  static String _defaultRuleNameAr(int ruleId) => switch (ruleId) {
        1 => 'المد الطبيعي',
        3 => 'المد المتصل',
        5 => 'المد العارض للسكون',
        6 => 'المد اللازم',
        7 => 'مد اللين',
        8 => 'القلقلة',
        9 => 'الشدة',
        10 => 'الغنة',
        _ => 'حكم تجويد',
      };

  static String _defaultRuleNameEn(int ruleId) => switch (ruleId) {
        1 => 'Normal Madd',
        3 => 'Mottasel Madd',
        5 => 'Aared Madd',
        6 => 'Lazem Madd',
        7 => 'Leen Madd',
        8 => 'Qalqalah',
        9 => 'Shaddah',
        10 => 'Ghunnah',
        _ => 'Tajweed Rule',
      };
}

class QuranRepository {
  final QuranMetadataService _service;

  bool _isLoaded = false;
  bool get isLoaded => _isLoaded || _service.reference != null;

  final Map<int, List<QuranVerse>> _surahCache = {};
  final Map<int, List<ContinuousQuranWord>> _surahWordsCache = {};
  final Map<int, Map<int, int>> _ayahStartWordIndexCache = {};

  QuranRepository(this._service);

  /// The underlying metadata service providing reference units.
  QuranMetadataService get service => _service;

  /// The engine's tj3 reference table (expected units, words and rule sites).
  TajweedFormerReferenceReader? get reference => _service.reference;

  /// Whether the dataset is native to Hafs.
  bool get isNativeDataset => true;

  /// Whether Tajweed evaluation is supported (requires the zfx reference).
  bool get isTajweedSupported => _service.reference != null;

  Future<void> loadSurahAsync(int surah) async {
    if (!isLoaded) {
      await _service.loadData();
      _isLoaded = true;
    }
    _ensureSurahParsed(surah);
  }

  void _ensureSurahParsed(int surah) {
    if (_surahCache.containsKey(surah)) return;

    final ref = _service.reference;
    if (ref == null) return;

    final int totalAyahs = ref.ayahCount(surah);
    final List<QuranVerse> verses = [];

    for (int ayah = 1; ayah <= totalAyahs; ayah++) {
      final ayahUnits = ref.getAyahUnits(surah, ayah);
      if (ayahUnits == null) continue;

      final composed = ReferenceComposer.compose(ayahUnits);

      // Muqatta'at letters (e.g. الم, حم, كهيعص, الر) are separated by '|' in zfx
      // acoustic units, but the initial letters form 1 word in Hafs calligraphy.
      // Merge only the initial Muqatta'at letters into 1 word so phonetic words
      // and calligraphy words align 1:1, leaving subsequent verse words intact.
      final List<ComposedWord> effectiveComposed;
      final int? mergeCount =
          _kMuqattaatPrefixMergeCounts[(surah << 16) | ayah];
      if (mergeCount != null &&
          mergeCount > 1 &&
          composed.length >= mergeCount) {
        final mergedPhoneme = StringBuffer();
        final mergedRules = <WordTajweedRule>[];
        final mergedCharClasses = <int>[];
        for (int i = 0; i < mergeCount; i++) {
          final w = composed[i];
          mergedPhoneme.write(w.phoneme);
          mergedRules.addAll(w.rules);
          mergedCharClasses.addAll(w.charRuleClasses);
        }
        effectiveComposed = [
          ComposedWord(
            phoneme: mergedPhoneme.toString(),
            rules: mergedRules,
            charRuleClasses: mergedCharClasses,
          ),
          ...composed.sublist(mergeCount),
        ];
      } else {
        effectiveComposed = composed;
      }

      final phonemeWords = effectiveComposed.map((w) => w.phoneme).toList();
      final wordRules = effectiveComposed.map((w) => w.rules).toList();
      final wordCharClasses =
          effectiveComposed.map((w) => w.charRuleClasses).toList();

      verses.add(
        QuranVerse(
          surah: surah,
          ayah: ayah,
          textPhoneme: phonemeWords.join(''),
          phonemeWords: phonemeWords,
          wordRules: wordRules,
          wordCharClasses: wordCharClasses,
        ),
      );
    }

    _surahCache[surah] = verses;
  }

  List<QuranVerse> getSurah(int surah) {
    if (!isLoaded) return [];
    _ensureSurahParsed(surah);
    return _surahCache[surah] ?? [];
  }

  List<ContinuousQuranWord> getSurahWords(int surah) {
    if (!isLoaded) return [];
    if (_surahWordsCache.containsKey(surah)) {
      return _surahWordsCache[surah]!;
    }

    final verses = getSurah(surah);

    final List<ContinuousQuranWord> words = [];
    final Map<int, int> ayahStartMap = {};
    int globalIdx = 0;

    for (final verse in verses) {
      ayahStartMap[verse.ayah] = globalIdx;
      for (int i = 0; i < verse.phonemeWords.length; i++) {
        final rules = (i < verse.wordRules.length)
            ? verse.wordRules[i]
            : const <WordTajweedRule>[];
        final charClasses = (i < verse.wordCharClasses.length)
            ? verse.wordCharClasses[i]
            : const <int>[];
        words.add(
          ContinuousQuranWord(
            globalIndex: globalIdx++,
            surah: verse.surah,
            ayah: verse.ayah,
            wordInAyah: i,
            phoneme: verse.phonemeWords[i],
            rules: rules,
            charRuleClasses: charClasses,
          ),
        );
      }
    }

    _ayahStartWordIndexCache[surah] = ayahStartMap;
    _surahWordsCache[surah] = words;
    return words;
  }

  int getAyahStartGlobalIndex(int surah, int ayah) {
    if (!_surahWordsCache.containsKey(surah)) {
      getSurahWords(surah);
    }
    return _ayahStartWordIndexCache[surah]?[ayah] ?? 0;
  }

  /// Returns the global word index within the Surah for a given (surah, ayah, wordIndex).
  int getWordGlobalIndex(int surah, int ayah, int wordIndex) {
    return getAyahStartGlobalIndex(surah, ayah) + wordIndex;
  }

  QuranVerse? getVerse(int surah, int ayah) {
    if (!isLoaded) return null;
    final verses = getSurah(surah);
    if (ayah >= 1 && ayah <= verses.length) {
      return verses[ayah - 1];
    }
    return null;
  }

  QuranVerse? getNextVerse(int surah, int ayah) {
    final verses = getSurah(surah);
    if (ayah >= 1 && ayah < verses.length) {
      return verses[ayah];
    }
    return null;
  }
}

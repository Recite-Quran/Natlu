// lib/tracking/tajweed/error_explainer.dart
// ═══════════════════════════════════════════════════════════════════════════════
// TAJWEED DIAGNOSTIC ENTITIES & EVALUATION FACADE
// ═══════════════════════════════════════════════════════════════════════════════

import '../../data/quran_data.dart';
import '../../engine/core/transcription_result.dart';
import '../word/dictation_matcher.dart';
import 'tajweed_engine.dart';

export 'tajweed_checkers.dart';
export 'tajweed_config.dart';
export 'tajweed_engine.dart';
export 'tajweed_rule.dart';

// ─────────────────────────────────────────────────────────────────────────────
// 1. Domain Enums & Trace Models
// ─────────────────────────────────────────────────────────────────────────────

/// Broad classification of reciter errors used by UI color highlighting and statistics.
enum ErrorCategory {
  /// Acoustic duration or Shaddah doubling mismatch (`Yellow highlight`).
  tajweed,

  /// Base letter replacement, total deletion, or insertion (`Red highlight`).
  normal,

  /// Same base consonant but incorrect diacritics/vowels (`Yellow highlight`).
  tashkeel,
}

/// Specific speech modification operation detected during phoneme alignment.
enum SpeechErrorType {
  /// Reciter added an extra phoneme or syllable not present in reference.
  insert,

  /// Reciter skipped or swallowed a required phoneme or syllable.
  delete,

  /// Reciter substituted a phoneme with a different sound or diacritic.
  replace,
}

/// Represents the alignment opcode between a single reference phoneme group and predicted phoneme group.
class PhonemeGroupAlignment {
  final String opType; // 'match', 'replace', 'delete', 'insert'
  final int refIdx;
  final int predIdx;

  const PhonemeGroupAlignment({
    required this.opType,
    required this.refIdx,
    required this.predIdx,
  });
}

/// Represents a cohesive phonetic span inside a word for Tajweed and phonetic grading.
class PhoneticSpan {
  final int refStart; // absolute index in fullPhonemes
  final int refEnd; // absolute index in fullPhonemes
  final String refText;
  final String baseChar;
  final bool isMadd;
  final bool isShaddah;
  final bool isGhunnah;
  final bool isQalqalah;
  final WordTajweedRule? matchedWordRule;

  const PhoneticSpan({
    required this.refStart,
    required this.refEnd,
    required this.refText,
    required this.baseChar,
    required this.isMadd,
    required this.isShaddah,
    required this.isGhunnah,
    this.isQalqalah = false,
    this.matchedWordRule,
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// 2. Reciter Error Entity
// ─────────────────────────────────────────────────────────────────────────────

/// Immutable diagnostic record detailing a detected recitation mismatch.
class ReciterError {
  final ErrorCategory errorType;
  final SpeechErrorType speechErrorType;
  final TajweedDurationStatus? durationStatus;
  final String expectedPh;
  final String predictedPh;
  final TajweedRule? expectedRule;
  final TajweedRule? predictedRule;
  final double? expectedDuration;
  final double? actualDuration;

  const ReciterError({
    required this.errorType,
    required this.speechErrorType,
    this.durationStatus,
    required this.expectedPh,
    required this.predictedPh,
    this.expectedRule,
    this.predictedRule,
    this.expectedDuration,
    this.actualDuration,
  });

  /// Structured machine-readable diagnostic error code (e.g., 'tajweed.maddNormal.underheld').
  String get errorCode {
    if (errorType == ErrorCategory.tajweed) {
      final ruleCode = expectedRule?.ruleType.name ?? 'unknown';
      final status = durationStatus?.name ?? 'mismatch';
      return 'tajweed.$ruleCode.$status';
    } else if (errorType == ErrorCategory.tashkeel) {
      return 'tashkeel.mismatch';
    } else {
      return 'phonetic.${speechErrorType.name}';
    }
  }

  @override
  String toString() {
    return 'ReciterError(code: $errorCode, expected: "$expectedPh", predicted: "$predictedPh", rule: ${expectedRule?.ruleType.name}, expDur: $expectedDuration, actDur: $actualDuration)';
  }

  Map<String, dynamic> toMap() {
    return {
      'errorType': errorType.name,
      'errorTypeIndex': errorType.index,
      'speechErrorType': speechErrorType.name,
      'speechErrorTypeIndex': speechErrorType.index,
      'durationStatus': durationStatus?.name,
      'durationStatusIndex': durationStatus?.index,
      'expectedPh': expectedPh,
      'predictedPh': predictedPh,
      'expectedRule': TajweedRuleFactory.toMap(expectedRule),
      'predictedRule': TajweedRuleFactory.toMap(predictedRule),
      'expectedDuration': expectedDuration,
      'actualDuration': actualDuration,
    };
  }

  static ReciterError fromMap(Map<String, dynamic> map) {
    final rawErrorType = map['errorType'];
    final ErrorCategory errorType = (rawErrorType is int)
        ? ErrorCategory.values[rawErrorType]
        : (rawErrorType is String
            ? ErrorCategory.values.firstWhere(
                (e) => e.name == rawErrorType,
                orElse: () => ErrorCategory.normal,
              )
            : ErrorCategory.normal);

    final rawSpeechType = map['speechErrorType'];
    final SpeechErrorType speechErrorType = (rawSpeechType is int)
        ? SpeechErrorType.values[rawSpeechType]
        : (rawSpeechType is String
            ? SpeechErrorType.values.firstWhere(
                (e) => e.name == rawSpeechType,
                orElse: () => SpeechErrorType.replace,
              )
            : SpeechErrorType.replace);

    final rawDurationStatus = map['durationStatus'];
    final TajweedDurationStatus? durationStatus = (rawDurationStatus is int)
        ? TajweedDurationStatus.values[rawDurationStatus]
        : (rawDurationStatus is String
            ? TajweedDurationStatus.values.firstWhere(
                (e) => e.name == rawDurationStatus,
                orElse: () => TajweedDurationStatus.valid,
              )
            : null);

    return ReciterError(
      errorType: errorType,
      speechErrorType: speechErrorType,
      durationStatus: durationStatus,
      expectedPh: map['expectedPh'] as String? ?? '',
      predictedPh: map['predictedPh'] as String? ?? '',
      expectedRule: TajweedRuleFactory.fromMap(
        map['expectedRule'] as Map<String, dynamic>?,
      ),
      predictedRule: TajweedRuleFactory.fromMap(
        map['predictedRule'] as Map<String, dynamic>?,
      ),
      expectedDuration: (map['expectedDuration'] as num?)?.toDouble(),
      actualDuration: (map['actualDuration'] as num?)?.toDouble(),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 3. ASR Noise Filter & Error Prioritization
// ─────────────────────────────────────────────────────────────────────────────

/// Filters expected acoustic ASR dropouts/noise and orders errors by UI priority.
class AsrNoiseFilter {
  static bool isExpectedNoise(
    ReciterError e, [
    TrackerConfig config = const TrackerConfig(),
  ]) {
    final int refCode =
        e.expectedPh.isNotEmpty ? e.expectedPh.codeUnitAt(0) : 0;
    final int asrCode =
        e.predictedPh.isNotEmpty ? e.predictedPh.codeUnitAt(0) : 0;

    switch (e.speechErrorType) {
      case SpeechErrorType.replace:
        return refCode > 0 &&
            asrCode > 0 &&
            PhoneticCostEngine.getSubstitutionCost(
                    asrCode, refCode, config.acousticConfusionCost) <=
                config.acousticConfusionCost;

      case SpeechErrorType.delete:
        // Common tj3 ASR drops: ghunna nasal, hamza, lam, and any vowel character
        return refCode == 0x6BA || // ں ghunna nasal
            refCode == 0x621 || // ء hamza
            refCode == 0x644 || // ل lam
            PhoneticCostEngine.isVowelChar(refCode);

      case SpeechErrorType.insert:
        return asrCode > 0 &&
            (PhoneticCostEngine.isTashkeel(asrCode) ||
                PhoneticCostEngine.getInsertionCost(
                        e.predictedPh,
                        0,
                        config.standardInsertionCost,
                        config.acousticConfusionCost) <=
                    config.acousticConfusionCost);
    }
  }

  static int getErrorPriority(ReciterError e) {
    if (e.errorType == ErrorCategory.normal) return 0;
    if (e.errorType == ErrorCategory.tashkeel) return 1;
    if (e.expectedRule is MaddRule) return 2;
    if (e.expectedRule is MushaddadGhunnahRule) return 3;
    if (e.expectedRule is ShaddahRule) return 4;
    if (e.expectedRule is QalqalahRule) return 5;
    return 6;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 4. Public Backward-Compatible Error Explainer Facade
// ─────────────────────────────────────────────────────────────────────────────

/// High-level orchestration facade coordinating word span building, acoustic duration
/// evaluation, neural burst scoring, and noise filtering via [TajweedEngine].
class ErrorExplainer {
  /// Evaluates pre-aligned phoneme trace for a single word.
  static List<ReciterError> evaluateSingleWord({
    required List<PhonemeGroupAlignment> alignments,
    required String wordPhonemes,
    required String currentAsrText,
    required List<double> trackingTimestamps,
    List<TokenNeuralAcoustics>? trackingAcoustics,
    List<WordTajweedRule> expectedWordRules = const [],
    List<int>? charRuleClasses,
    TrackerConfig config = const TrackerConfig(),
  }) {
    final engine = TajweedEngine(config: config.tajweed, trackerConfig: config);
    final res = engine.evaluateWordAlignments(
      alignments: alignments,
      fullPhonemes: wordPhonemes,
      wordBoundaries: [0, wordPhonemes.length],
      currentAsrText: currentAsrText,
      trackingTimestamps: trackingTimestamps,
      trackingAcoustics: trackingAcoustics,
      bestAsrStartIdx: 0,
      targetCharCursor: 0,
      startWordId: 0,
      nextWordId: 1,
      totalAyahWords: 1,
      expectedWordRules: expectedWordRules,
      charRuleClasses: charRuleClasses,
    );
    return res[0] ?? const [];
  }

  /// Evaluates pre-aligned phoneme traces for a specific committed word window.
  static Map<int, List<ReciterError>> evaluatePreAlignedWords({
    required List<PhonemeGroupAlignment> alignments,
    required String fullPhonemes,
    required List<int> wordBoundaries,
    required String currentAsrText,
    required List<double> trackingTimestamps,
    List<TokenNeuralAcoustics>? trackingAcoustics,
    List<int>? charTokenIndices,
    List<double>? tokenDurations,
    List<double>? tokenStarts,
    List<double>? tokenEnds,
    required int bestAsrStartIdx,
    required int targetCharCursor,
    required int startWordId,
    required int nextWordId,
    required int totalAyahWords,
    List<WordTajweedRule> expectedWordRules = const [],
    List<int>? charRuleClasses,
    TrackerConfig config = const TrackerConfig(),
  }) {
    final engine = TajweedEngine(config: config.tajweed, trackerConfig: config);
    return engine.evaluateWordAlignments(
      alignments: alignments,
      fullPhonemes: fullPhonemes,
      wordBoundaries: wordBoundaries,
      currentAsrText: currentAsrText,
      trackingTimestamps: trackingTimestamps,
      trackingAcoustics: trackingAcoustics,
      charTokenIndices: charTokenIndices,
      tokenDurations: tokenDurations,
      tokenStarts: tokenStarts,
      tokenEnds: tokenEnds,
      bestAsrStartIdx: bestAsrStartIdx,
      targetCharCursor: targetCharCursor,
      startWordId: startWordId,
      nextWordId: nextWordId,
      totalAyahWords: totalAyahWords,
      expectedWordRules: expectedWordRules,
      charRuleClasses: charRuleClasses,
    );
  }
}

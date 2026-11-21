// lib/tracking/tajweed/error_explainer.dart
// ═══════════════════════════════════════════════════════════════════════════════
// TAJWEED EVALUATION & ERROR EXPLAINER ENGINE
//
// Evaluates aligned phoneme traces against Tajweed rules, acoustic holding durations,
// neural attribute heads, and diacritics directly without heuristics.
// ═══════════════════════════════════════════════════════════════════════════════

import 'dart:math';

import '../../data/quran_data.dart';
import '../../engine/core/transcription_result.dart';
import '../../utils/debug_logger.dart';
import '../word/dictation_matcher.dart';
import 'tajweed_rule.dart';

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
// 3. Evaluator Sub-Engines
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

/// Evaluates vowel and diacritic marks (Tashkeel) between reference and predicted spans.
class TashkeelEvaluator {
  static String extractVowels(String text) {
    final sb = StringBuffer();
    int lastCode = -1;
    for (int i = 0; i < text.length; i++) {
      int code = text.codeUnitAt(i);
      if (code == 0x61) {
        code = 0x064E; // a -> Fatha
      } else if (code == 0x69) {
        code = 0x0650; // i -> Kasra
      } else if (code == 0x75) {
        code = 0x064F; // u -> Damma
      } else if (code != 0x064E && code != 0x064F && code != 0x0650) {
        continue;
      }
      if (code == lastCode) continue;
      sb.writeCharCode(code);
      lastCode = code;
    }
    return sb.toString();
  }

  static ReciterError? evaluate({
    required PhoneticSpan span,
    required String predText,
    required int wordRefEnd,
  }) {
    final String refVowels = extractVowels(span.refText);
    final String predVowels = extractVowels(predText);

    if (refVowels.isNotEmpty || predVowels.isNotEmpty) {
      final bool isTerminalWaqf =
          span.refEnd == wordRefEnd && predVowels.isEmpty;
      if (!isTerminalWaqf && refVowels != predVowels) {
        return ReciterError(
          errorType: ErrorCategory.tashkeel,
          speechErrorType: SpeechErrorType.replace,
          expectedPh: span.refText,
          predictedPh: predText,
        );
      }
    }
    return null;
  }
}

/// Evaluates acoustic duration rules for Madd, Ghunnah, and Shaddah.
class DurationEvaluator {
  static ReciterError? evaluateRule({
    required TajweedRule rule,
    required PhoneticSpan span,
    required String predText,
    required double spanDuration,
    required RecitationSpeed speed,
    required String categoryTag,
  }) {
    final double req = rule.getRequiredDuration(speed);
    final double minReq = rule.getMinAllowedDuration(speed);
    final TajweedDurationStatus durStatus =
        rule.checkDurationStatus(spanDuration, speed);

    DebugLogger.log(
      'Tajweed',
      '🎯 [GRADING $categoryTag] Span: "${span.refText}" (${rule.ruleType.name}) | ASR: "$predText" | Measured: ${spanDuration.toStringAsFixed(3)}s | Target: ${req.toStringAsFixed(3)}s (min: ${minReq.toStringAsFixed(3)}s) | Status: ${durStatus.name.toUpperCase()}',
    );

    if (durStatus == TajweedDurationStatus.underheld ||
        durStatus == TajweedDurationStatus.overheld) {
      return ReciterError(
        errorType: ErrorCategory.tajweed,
        speechErrorType: SpeechErrorType.replace,
        durationStatus: durStatus,
        expectedPh: span.refText,
        predictedPh: predText,
        expectedRule: rule,
        expectedDuration: req,
        actualDuration: spanDuration,
      );
    }
    return null;
  }

  static ReciterError? evaluateShaddah({
    required PhoneticSpan span,
    required String predText,
    required double spanDuration,
    required RecitationSpeed speed,
  }) {
    final rule = const ShaddahRule();
    final double minReq = rule.getMinAllowedDuration(speed);
    final double req = rule.getRequiredDuration(speed);
    final int predBaseCount = countBaseOccurrences(predText, span.baseChar);

    final bool shaddahHeld = spanDuration >= minReq || predBaseCount >= 2;

    DebugLogger.log(
      'Tajweed',
      '🎯 [GRADING SHADDAH] Span: "${span.refText}" | ASR: "$predText" | Dur: ${spanDuration.toStringAsFixed(3)}s (req: ${req.toStringAsFixed(3)}s) | Held: $shaddahHeld',
    );

    if (!shaddahHeld) {
      return ReciterError(
        errorType: ErrorCategory.tajweed,
        speechErrorType: SpeechErrorType.replace,
        durationStatus: TajweedDurationStatus.underheld,
        expectedPh: span.refText,
        predictedPh: predText,
        expectedRule: rule,
        expectedDuration: req,
        actualDuration: spanDuration,
      );
    }
    return null;
  }

  static int countBaseOccurrences(String text, String baseChar) {
    if (text.isEmpty || baseChar.isEmpty) return 0;
    final int baseCode = baseChar.codeUnitAt(0);
    int count = 0;
    for (int i = 0; i < text.length; i++) {
      final int c = text.codeUnitAt(i);
      if (c == baseCode || PhoneticCostEngine.isEquivalentGlyph(c, baseCode)) {
        count++;
      }
    }
    return count;
  }
}

/// Evaluates Qalqalah release burst neural score from TajweedFormer V4 attr_qalqalah head.
class QalqalahEvaluator {
  static const double calibratedTau = 0.2646;

  static ReciterError? evaluate({
    required PhoneticSpan span,
    required String predText,
    required TokenNeuralAcoustics spanAcoustics,
    TrackerConfig config = const TrackerConfig(),
  }) {
    final rule = span.matchedWordRule != null
        ? TajweedRuleFactory.instantiate(span.matchedWordRule!, config)
        : const QalqalahRule();

    DebugLogger.log(
      'Tajweed',
      '🎯 [GRADING QALQALAH] Span: "${span.refText}" | ASR: "$predText" | QalqalahScore: ${spanAcoustics.qalqalahScore.toStringAsFixed(3)} (calibrated tau: $calibratedTau)',
    );

    if (spanAcoustics.qalqalahScore < calibratedTau) {
      return ReciterError(
        errorType: ErrorCategory.tajweed,
        speechErrorType: SpeechErrorType.replace,
        durationStatus: TajweedDurationStatus.underheld,
        expectedPh: span.refText,
        predictedPh: predText,
        expectedRule: rule,
      );
    }
    return null;
  }
}

/// Builds cohesive phonetic spans for a word driven strictly by the per-character
/// rule classes derived from expected_tj3.zfx reference data.
class WordSpanBuilder {
  static List<PhoneticSpan> build({
    required String fullPhonemes,
    required int wordRefStart,
    required int wordRefEnd,
    required List<WordTajweedRule> expectedWordRules,
    List<int>? charRuleClasses,
  }) {
    final List<PhoneticSpan> spans = [];
    int cursor = wordRefStart;

    while (cursor < wordRefEnd) {
      final int cls =
          (charRuleClasses != null && cursor < charRuleClasses.length)
              ? charRuleClasses[cursor]
              : 0;

      // Rule-site span: contiguous characters marked with the same class code
      if (cls > 0) {
        int end = cursor;
        while (end < wordRefEnd &&
            end < charRuleClasses!.length &&
            charRuleClasses[end] == cls) {
          end++;
        }
        final String refText = fullPhonemes.substring(cursor, end);
        final WordTajweedRule? rule = (cls - 1 < expectedWordRules.length)
            ? expectedWordRules[cls - 1]
            : null;
        final int ruleId = rule?.ruleId ?? 0;

        spans.add(
          PhoneticSpan(
            refStart: cursor,
            refEnd: end,
            refText: refText,
            baseChar: refText.isNotEmpty ? refText[0] : '',
            isMadd: (ruleId >= 1 && ruleId <= 7) ||
                refText.startsWith('aa') ||
                refText.startsWith('ii') ||
                refText.startsWith('uu'),
            isShaddah: ruleId == 9,
            isGhunnah: ruleId == 10,
            isQalqalah: ruleId == 8,
            matchedWordRule: rule,
          ),
        );
        cursor = end;
        continue;
      }

      // Plain span: one tj3 token + following class-0 short vowels (a/i/u)
      final String ch = fullPhonemes[cursor];
      int end = cursor + 1;
      while (end < wordRefEnd &&
          (charRuleClasses == null ||
              end >= charRuleClasses.length ||
              charRuleClasses[end] == 0) &&
          PhoneticCostEngine.isVowelChar(fullPhonemes.codeUnitAt(end))) {
        end++;
      }
      final String refText = fullPhonemes.substring(cursor, end);

      spans.add(
        PhoneticSpan(
          refStart: cursor,
          refEnd: end,
          refText: refText,
          baseChar: ch,
          isMadd: false,
          isShaddah: false,
          isGhunnah: false,
        ),
      );
      cursor = end;
    }

    return spans;
  }
}

/// Single-span evaluation pipeline coordinating letter identity, duration, burst, and tashkeel checks.
class SpanEvaluator {
  static List<ReciterError> evaluate({
    required PhoneticSpan span,
    required String predText,
    required double spanDuration,
    TokenNeuralAcoustics spanAcoustics = const TokenNeuralAcoustics(),
    required bool hasDelete,
    required String wordText,
    required int wordRefEnd,
    TrackerConfig config = const TrackerConfig(),
  }) {
    final List<ReciterError> errors = [];
    final speed = config.recitationSpeed;

    // ── Phase 1: Base Character Verification (Letter Identity & Deletion) ──
    if (span.refText.isNotEmpty) {
      if (predText.isEmpty) {
        if (span.isMadd ||
            span.isShaddah ||
            span.isGhunnah ||
            span.isQalqalah) {
          final rule = span.matchedWordRule != null
              ? TajweedRuleFactory.instantiate(span.matchedWordRule!, config)
              : (span.isMadd
                  ? TajweedRuleFactory.deriveMaddRuleFromLength(
                      span.refText.length, config)
                  : (span.isShaddah
                      ? const ShaddahRule()
                      : (span.isGhunnah
                          ? const MushaddadGhunnahRule()
                          : const QalqalahRule())));
          errors.add(
            ReciterError(
              errorType: ErrorCategory.tajweed,
              speechErrorType: SpeechErrorType.delete,
              durationStatus: TajweedDurationStatus.underheld,
              expectedPh: span.refText,
              predictedPh: '',
              expectedRule: rule,
              expectedDuration: rule.getRequiredDuration(speed),
              actualDuration: 0.0,
            ),
          );
          return errors;
        }
        errors.add(
          ReciterError(
            errorType: ErrorCategory.normal,
            speechErrorType: SpeechErrorType.delete,
            expectedPh: span.refText,
            predictedPh: '',
          ),
        );
        return errors;
      } else if (span.baseChar != predText[0] &&
          !PhoneticCostEngine.isEquivalentGlyph(
            span.baseChar.codeUnitAt(0),
            predText.codeUnitAt(0),
          )) {
        errors.add(
          ReciterError(
            errorType: ErrorCategory.normal,
            speechErrorType: SpeechErrorType.replace,
            expectedPh: span.refText,
            predictedPh: predText,
          ),
        );
        return errors;
      }
    }

    // ── Phase 2: Tajweed Duration & Multi-Head Neural Diagnostics ──
    if (span.isMadd) {
      if (spanDuration <= 0.0) return errors;

      final rule = span.matchedWordRule != null
          ? TajweedRuleFactory.instantiate(span.matchedWordRule!, config)
          : TajweedRuleFactory.deriveMaddRuleFromLength(
              span.refText.length, config);

      final err = DurationEvaluator.evaluateRule(
        rule: rule,
        span: span,
        predText: predText,
        spanDuration: spanDuration,
        speed: speed,
        categoryTag: 'MADD',
      );
      if (err != null) errors.add(err);
      return errors;
    }

    if (span.isGhunnah) {
      if (spanDuration <= 0.0) return errors;

      final rule = span.matchedWordRule != null
          ? TajweedRuleFactory.instantiate(span.matchedWordRule!, config)
          : const MushaddadGhunnahRule();

      final err = DurationEvaluator.evaluateRule(
        rule: rule,
        span: span,
        predText: predText,
        spanDuration: spanDuration,
        speed: speed,
        categoryTag: 'GHUNNAH',
      );
      if (err != null) errors.add(err);
      return errors;
    }

    if (span.isShaddah) {
      final err = DurationEvaluator.evaluateShaddah(
        span: span,
        predText: predText,
        spanDuration: spanDuration,
        speed: speed,
      );
      if (err != null) errors.add(err);
      return errors;
    }

    if (span.isQalqalah) {
      final err = QalqalahEvaluator.evaluate(
        span: span,
        predText: predText,
        spanAcoustics: spanAcoustics,
        config: config,
      );
      if (err != null) errors.add(err);
      return errors;
    }

    // ── Phase 3: Tashkeel / Harakat Evaluation on Matching Base Consonants ──
    final tashkeelErr = TashkeelEvaluator.evaluate(
      span: span,
      predText: predText,
      wordRefEnd: wordRefEnd,
    );
    if (tashkeelErr != null) {
      errors.add(tashkeelErr);
    }

    return errors;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 4. Public Error Explainer Facade
// ─────────────────────────────────────────────────────────────────────────────

/// High-level orchestration facade coordinating word span building, acoustic duration
/// evaluation, neural burst scoring, and noise filtering.
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
    final res = evaluatePreAlignedWords(
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
      config: config,
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
    required int bestAsrStartIdx,
    required int targetCharCursor,
    required int startWordId,
    required int nextWordId,
    required int totalAyahWords,
    List<WordTajweedRule> expectedWordRules = const [],
    List<int>? charRuleClasses,
    TrackerConfig config = const TrackerConfig(),
  }) {
    final Map<int, List<ReciterError>> errorsByWord = {};

    for (int w = startWordId; w < nextWordId; w++) {
      if (w >= wordBoundaries.length) break;

      final int wordRefStart = wordBoundaries[w];
      final int wordRefEnd = (w + 1 < wordBoundaries.length)
          ? wordBoundaries[w + 1]
          : fullPhonemes.length;

      final String wordText = fullPhonemes.substring(
        wordRefStart,
        min(wordRefEnd, fullPhonemes.length),
      );

      // 1. Build cohesive phonetic spans for this word
      final List<PhoneticSpan> spans = WordSpanBuilder.build(
        fullPhonemes: fullPhonemes,
        wordRefStart: wordRefStart,
        wordRefEnd: wordRefEnd,
        expectedWordRules: expectedWordRules,
        charRuleClasses: charRuleClasses,
      );

      final List<ReciterError> wordErrors = [];

      // 2. Evaluate each span with aggregated ASR alignments and durations
      for (final span in spans) {
        final spanAlignments = alignments.where((a) {
          final absRef = targetCharCursor + a.refIdx;
          return absRef >= span.refStart && absRef < span.refEnd;
        }).toList();

        if (spanAlignments.isEmpty) continue;

        final List<String> predChunks = [];
        final Set<int> usedPredIndices = {};
        double totalSpanDuration = 0.0;
        bool hasDelete = false;
        double sumQalqalah = 0.0;
        double sumConf = 0.0;
        int acousticsCount = 0;

        for (final a in spanAlignments) {
          if (a.opType == 'delete') {
            hasDelete = true;
          }
          final absPred = bestAsrStartIdx + a.predIdx;
          if (absPred >= 0 && absPred < currentAsrText.length) {
            predChunks.add(currentAsrText[absPred]);
            if (!usedPredIndices.contains(absPred)) {
              usedPredIndices.add(absPred);
              if (absPred < trackingTimestamps.length) {
                totalSpanDuration += trackingTimestamps[absPred];
              }
              if (trackingAcoustics != null &&
                  absPred < trackingAcoustics.length) {
                final ac = trackingAcoustics[absPred];
                sumQalqalah += ac.qalqalahScore;
                sumConf += ac.confScore;
                acousticsCount++;
              }
            }
          }
        }

        final TokenNeuralAcoustics spanAcoustics = acousticsCount > 0
            ? TokenNeuralAcoustics(
                qalqalahScore: sumQalqalah / acousticsCount,
                confScore: sumConf / acousticsCount,
              )
            : const TokenNeuralAcoustics();

        final String predText = predChunks.join('');

        final spanErrors = SpanEvaluator.evaluate(
          span: span,
          predText: predText,
          spanDuration: totalSpanDuration,
          spanAcoustics: spanAcoustics,
          hasDelete: hasDelete,
          wordText: wordText,
          wordRefEnd: wordRefEnd,
          config: config,
        );

        wordErrors.addAll(spanErrors);
      }

      if (wordErrors.isNotEmpty) {
        // Sort errors by UI priority
        wordErrors.sort(
          (a, b) => AsrNoiseFilter.getErrorPriority(a)
              .compareTo(AsrNoiseFilter.getErrorPriority(b)),
        );

        // Filter out expected ASR noise
        wordErrors.removeWhere((e) {
          if (e.errorType == ErrorCategory.normal) {
            return config.hideExpectedAsrNoise &&
                AsrNoiseFilter.isExpectedNoise(e, config);
          }
          return false;
        });

        // Deduplicate identical errors on the same rule/phoneme
        final List<ReciterError> deduplicated = [];
        final Set<String> seenKeys = {};
        for (final e in wordErrors) {
          final key =
              '${e.errorType.name}_${e.expectedRule?.ruleType.name ?? ''}_${e.expectedPh}';
          if (!seenKeys.contains(key)) {
            seenKeys.add(key);
            deduplicated.add(e);
          }
        }

        if (deduplicated.isNotEmpty) {
          errorsByWord[w] = deduplicated;

          for (var e in deduplicated) {
            final String ruleInfo = e.expectedRule != null
                ? ' | Rule: ${e.expectedRule!.ruleType.name} (req: ${e.expectedDuration?.toStringAsFixed(2)}s, got: ${e.actualDuration?.toStringAsFixed(2)}s)'
                : '';
            DebugLogger.log(
              'Error',
              '🚨 [ERROR LOG] Word "$wordText" ($w) | ${e.errorType.name.toUpperCase()} -> ${e.speechErrorType.name.toUpperCase()} (Exp: "${e.expectedPh}" vs Got: "${e.predictedPh}")$ruleInfo',
            );
          }
        }
      }
    }

    return errorsByWord;
  }
}

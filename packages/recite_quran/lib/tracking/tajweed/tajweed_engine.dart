// lib/tracking/tajweed/tajweed_engine.dart
// ═══════════════════════════════════════════════════════════════════════════════
// STANDALONE ISOLATED TAJWEED EVALUATION ENGINE
// ═══════════════════════════════════════════════════════════════════════════════

import 'dart:math';

import '../../data/quran_data.dart';
import '../../engine/core/transcription_result.dart';
import '../word/dictation_matcher.dart';
import 'error_explainer.dart';

export 'tajweed_checkers.dart';
export 'tajweed_config.dart';
export 'tajweed_rule.dart';

/// An isolated, standalone Tajweed evaluation engine.
///
/// Can be invoked independently of ASR models to evaluate phonetic spans,
/// acoustic holding durations, and multi-head neural attributes against canonical Tajweed rules.
class TajweedEngine {
  final TajweedConfig config;
  final TrackerConfig trackerConfig;

  const TajweedEngine({
    this.config = const TajweedConfig(),
    this.trackerConfig = const TrackerConfig(),
  });

  /// Evaluates a single phonetic span against enabled Tajweed rule checkers.
  List<ReciterError> evaluateSpan({
    required PhoneticSpan span,
    required String predText,
    required double spanDuration,
    TokenNeuralAcoustics spanAcoustics = const TokenNeuralAcoustics(),
    required bool hasDelete,
    required String wordText,
    required int wordRefEnd,
  }) {
    if (!config.isAnyCheckEnabled) return const [];
    final List<ReciterError> errors = [];
    final speed = trackerConfig.recitationSpeed;

    // ── Phase 1: Base Character Verification (Letter Identity & Deletion) ──
    if (span.refText.isNotEmpty) {
      if (predText.isEmpty) {
        // When sound is missing entirely, check if it was a Tajweed duration site
        if (span.isMadd ||
            span.isShaddah ||
            span.isGhunnah ||
            span.isQalqalah) {
          final rule = span.matchedWordRule != null
              ? TajweedRuleFactory.instantiate(
                  span.matchedWordRule!, trackerConfig)
              : (span.isMadd
                  ? TajweedRuleFactory.deriveMaddRuleFromLength(
                      span.refText.length, trackerConfig)
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
      } else if (config.checkLetterSwap) {
        final swapError = LetterSwapChecker.check(
          span: span,
          predText: predText,
        );
        if (swapError != null) {
          errors.add(swapError);
          return errors;
        }
      }
    }

    // ── Phase 2: Tajweed Duration & Multi-Head Neural Diagnostics ──
    if (span.isMadd && config.checkMadd) {
      final err = MaddChecker.check(
        span: span,
        predText: predText,
        spanDuration: spanDuration,
        speed: speed,
        config: trackerConfig,
      );
      if (err != null) errors.add(err);
      return errors;
    }

    if (span.isGhunnah && config.checkGhunnah) {
      final err = GhunnahChecker.check(
        span: span,
        predText: predText,
        spanDuration: spanDuration,
        speed: speed,
        config: trackerConfig,
      );
      if (err != null) errors.add(err);
      return errors;
    }

    if (span.isShaddah && config.checkShaddah) {
      final err = ShaddahChecker.check(
        span: span,
        predText: predText,
        spanDuration: spanDuration,
        speed: speed,
      );
      if (err != null) errors.add(err);
      return errors;
    }

    if (span.isQalqalah && config.checkQalqalah) {
      final err = QalqalahChecker.check(
        span: span,
        predText: predText,
        spanAcoustics: spanAcoustics,
        config: trackerConfig,
      );
      if (err != null) errors.add(err);
      return errors;
    }

    // ── Phase 3: Tashkeel / Harakat Evaluation on Matching Base Consonants ──
    if (config.checkTashkeel) {
      final tashkeelErr = TashkeelChecker.check(
        span: span,
        predText: predText,
        wordRefEnd: wordRefEnd,
      );
      if (tashkeelErr != null) {
        errors.add(tashkeelErr);
      }
    }

    return errors;
  }

  /// Evaluates pre-aligned phoneme traces for a specific committed word window.
  Map<int, List<ReciterError>> evaluateWordAlignments({
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
  }) {
    if (!config.isAnyCheckEnabled) return const {};
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

      final List<PhoneticSpan> spans = WordSpanBuilder.build(
        fullPhonemes: fullPhonemes,
        wordRefStart: wordRefStart,
        wordRefEnd: wordRefEnd,
        expectedWordRules: expectedWordRules,
        charRuleClasses: charRuleClasses,
      );

      final List<ReciterError> wordErrors = [];

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

        final spanErrors = evaluateSpan(
          span: span,
          predText: predText,
          spanDuration: totalSpanDuration,
          spanAcoustics: spanAcoustics,
          hasDelete: hasDelete,
          wordText: wordText,
          wordRefEnd: wordRefEnd,
        );

        wordErrors.addAll(spanErrors);
      }

      if (wordErrors.isNotEmpty) {
        wordErrors.sort(
          (a, b) => AsrNoiseFilter.getErrorPriority(a)
              .compareTo(AsrNoiseFilter.getErrorPriority(b)),
        );

        wordErrors.removeWhere((e) {
          if (e.errorType == ErrorCategory.normal) {
            return trackerConfig.hideExpectedAsrNoise &&
                AsrNoiseFilter.isExpectedNoise(e, trackerConfig);
          }
          return false;
        });

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
        }
      }
    }

    return errorsByWord;
  }
}

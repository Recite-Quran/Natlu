// lib/tracking/tajweed/tajweed_engine.dart
// ═══════════════════════════════════════════════════════════════════════════════
// TAJWEED EVALUATION ENGINE & SPAN ALIGNMENT ORCHESTRATOR
// ═══════════════════════════════════════════════════════════════════════════════

import 'dart:math';

import '../../data/quran_data.dart';
import '../../engine/core/transcription_result.dart';
import '../word/dictation_matcher.dart';
import 'error_explainer.dart';

export 'tajweed_checkers.dart';
export 'tajweed_config.dart';
export 'tajweed_rule.dart';

// ─────────────────────────────────────────────────────────────────────────────
// 1. Phonetic Word Span Builder
// ─────────────────────────────────────────────────────────────────────────────

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
            isMadd: ruleId >= 1 && ruleId <= 7,
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

// ─────────────────────────────────────────────────────────────────────────────
// 2. Standalone Tajweed Evaluation Engine
// ─────────────────────────────────────────────────────────────────────────────

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
              : (span.isShaddah
                  ? const ShaddahRule()
                  : (span.isGhunnah
                      ? const MushaddadGhunnahRule()
                      : const QalqalahRule()));
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
        final Set<int> touchedTokens = {};
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
              if (charTokenIndices != null &&
                  absPred < charTokenIndices.length) {
                touchedTokens.add(charTokenIndices[absPred]);
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

        // Acoustic holding duration strictly for the aligned tokens of this span:
        double spanDuration = 0.0;
        if (tokenDurations != null && touchedTokens.isNotEmpty) {
          for (final t in touchedTokens) {
            if (t >= 0 && t < tokenDurations.length) {
              spanDuration += tokenDurations[t];
            }
          }
        }

        // Selective CTC blank allocation exclusively for held rule spans (from expected_tj3.zfx):
        // 1. Shaddah (rule 9): consonant closure occurs in blanks preceding consonant release,
        //    or prolongation occurs in blanks following fricative/liquid consonant.
        if (span.isShaddah &&
            tokenStarts != null &&
            tokenEnds != null &&
            touchedTokens.isNotEmpty) {
          final int firstT = touchedTokens.reduce(min);
          final int lastT = touchedTokens.reduce(max);
          double shaddahBlanks = 0.0;
          if (firstT > 0 &&
              firstT < tokenStarts.length &&
              (firstT - 1) < tokenEnds.length) {
            final double gapBefore =
                tokenStarts[firstT] - tokenEnds[firstT - 1];
            if (gapBefore >= 0.040 && gapBefore < 1.25) {
              shaddahBlanks += gapBefore;
            }
          }
          if (lastT >= 0 &&
              lastT < tokenEnds.length &&
              (lastT + 1) < tokenStarts.length) {
            final double gapAfter =
                tokenStarts[lastT + 1] - tokenEnds[lastT];
            if (gapAfter >= 0.040 && gapAfter < 1.25) {
              shaddahBlanks += gapAfter;
            }
          }
          spanDuration += min(1.25, shaddahBlanks);
        }

        // 2. Ghunnah (rule 10): nasal holding between preceding vowel and following consonant.
        if (span.isGhunnah &&
            tokenStarts != null &&
            tokenEnds != null &&
            touchedTokens.isNotEmpty) {
          final int firstT = touchedTokens.reduce(min);
          final int lastT = touchedTokens.reduce(max);
          double ghunnahBlanks = 0.0;
          if (firstT > 0 &&
              firstT < tokenStarts.length &&
              (firstT - 1) < tokenEnds.length) {
            final double gapBefore =
                tokenStarts[firstT] - tokenEnds[firstT - 1];
            if (gapBefore >= 0.040 && gapBefore < 1.25) {
              ghunnahBlanks += gapBefore;
            }
          }
          if (lastT >= 0 &&
              lastT < tokenEnds.length &&
              (lastT + 1) < tokenStarts.length) {
            final double gapAfter =
                tokenStarts[lastT + 1] - tokenEnds[lastT];
            if (gapAfter >= 0.040 && gapAfter < 1.25) {
              ghunnahBlanks += gapAfter;
            }
          }
          spanDuration += min(1.25, ghunnahBlanks);
        }

        // 3. Madd (rules 1-7): acoustic holding continues forward in the blanks following the sound.
        if (span.isMadd &&
            tokenStarts != null &&
            tokenEnds != null &&
            touchedTokens.isNotEmpty) {
          final int lastT = touchedTokens.reduce(max);
          if (lastT >= 0 &&
              lastT < tokenEnds.length &&
              (lastT + 1) < tokenStarts.length) {
            final double continuationGap =
                tokenStarts[lastT + 1] - tokenEnds[lastT];
            if (continuationGap >= 0.040 && continuationGap < 1.25) {
              spanDuration += continuationGap;
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
          spanDuration: spanDuration,
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


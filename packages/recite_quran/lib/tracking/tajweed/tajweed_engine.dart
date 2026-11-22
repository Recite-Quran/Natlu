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
    int wordBaseCount = 0,
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
        wordBaseCount: wordBaseCount,
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
              if (charTokenIndices != null &&
                  absPred < charTokenIndices.length) {
                touchedTokens.add(charTokenIndices[absPred]);
              }
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

        // High-precision acoustic holding duration for Tajweed continuants (Madd, Ghunnah, Shaddah):
        // If the span aligned to tokens whose duration was tracked in the neural acoustic pipeline,
        // use the exact token holding duration rather than summing chopped character fractions.
        if (tokenDurations != null && touchedTokens.isNotEmpty) {
          double neuralTokenHold = 0.0;
          if (tokenStarts != null &&
              tokenEnds != null &&
              touchedTokens.length > 1) {
            final int minTok = touchedTokens.reduce(min);
            final int maxTok = touchedTokens.reduce(max);
            if (minTok < tokenStarts.length && maxTok < tokenEnds.length) {
              neuralTokenHold =
                  max(0.0, tokenEnds[maxTok] - tokenStarts[minTok]);
            }
          }
          if (neuralTokenHold <= 0.0) {
            for (final t in touchedTokens) {
              if (t < tokenDurations.length) {
                neuralTokenHold += tokenDurations[t];
              }
            }
          }
          if (neuralTokenHold > 0.0) {
            totalSpanDuration = max(totalSpanDuration, neuralTokenHold);
          }
        }

        int wordBaseCount = 0;
        if (span.isShaddah && span.baseChar.isNotEmpty) {
          int baseOccurrencesInAsr = 0;
          double baseConsonantDuration = 0.0;
          for (int i = 0; i < currentAsrText.length; i++) {
            final int c = currentAsrText.codeUnitAt(i);
            if (c == span.baseChar.codeUnitAt(0) ||
                PhoneticCostEngine.isEquivalentGlyph(
                    c, span.baseChar.codeUnitAt(0))) {
              baseOccurrencesInAsr++;
              if (i < trackingTimestamps.length) {
                baseConsonantDuration += trackingTimestamps[i];
              }
            }
          }
          wordBaseCount = baseOccurrencesInAsr;
          if (baseOccurrencesInAsr >= 2) {
            totalSpanDuration = max(totalSpanDuration, baseConsonantDuration);
            if (predChunks.length < 2) {
              predChunks.add(span.baseChar);
            }
          } else if (baseConsonantDuration > totalSpanDuration) {
            totalSpanDuration = baseConsonantDuration;
          }
        }

        if (span.isMadd) {
          double vowelDurationSum = 0.0;
          for (int i = 0; i < currentAsrText.length; i++) {
            final int ch = currentAsrText.codeUnitAt(i);
            if (PhoneticCostEngine.isVowelChar(ch) ||
                PhoneticCostEngine.isMaddVowel(ch)) {
              if (i < trackingTimestamps.length) {
                vowelDurationSum += trackingTimestamps[i];
              }
            }
          }
          if (vowelDurationSum > totalSpanDuration) {
            totalSpanDuration = vowelDurationSum;
          }
        }

        if (span.isGhunnah) {
          double nasalDurationSum = 0.0;
          for (int i = 0; i < currentAsrText.length; i++) {
            final int ch = currentAsrText.codeUnitAt(i);
            if (ch == 0x6BA || ch == 0x646 || ch == 0x645) { // ں, ن, م
              if (i < trackingTimestamps.length) {
                nasalDurationSum += trackingTimestamps[i];
              }
            }
          }
          if (nasalDurationSum > totalSpanDuration) {
            totalSpanDuration = nasalDurationSum;
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
          wordBaseCount: wordBaseCount,
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


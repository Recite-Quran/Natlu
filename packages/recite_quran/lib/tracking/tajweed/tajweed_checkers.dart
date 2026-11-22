// lib/tracking/tajweed/tajweed_checkers.dart
// ═══════════════════════════════════════════════════════════════════════════════
// MODULAR TAJWEED RULE CHECKERS (ISOLATED RULE EVALUATORS)
// ═══════════════════════════════════════════════════════════════════════════════

import '../../engine/core/transcription_result.dart';
import '../word/dictation_matcher.dart';
import 'error_explainer.dart';

/// Evaluates Madd acoustic prolongation rules (2, 4, 5, 6 Harakat).
class MaddChecker {
  static ReciterError? check({
    required PhoneticSpan span,
    required String predText,
    required double spanDuration,
    required RecitationSpeed speed,
    required TrackerConfig config,
  }) {
    if (spanDuration <= 0.0) return null;

    final rule = span.matchedWordRule != null
        ? TajweedRuleFactory.instantiate(span.matchedWordRule!, config)
        : TajweedRuleFactory.deriveMaddRuleFromLength(
            span.refText.length,
            config,
          );

    return DurationEvaluator.evaluateRule(
      rule: rule,
      span: span,
      predText: predText,
      spanDuration: spanDuration,
      speed: speed,
      categoryTag: 'MADD',
    );
  }
}

/// Evaluates Ghunnah nasal resonance holding time on doubled Noon and Meem.
class GhunnahChecker {
  static ReciterError? check({
    required PhoneticSpan span,
    required String predText,
    required double spanDuration,
    required RecitationSpeed speed,
    required TrackerConfig config,
  }) {
    if (spanDuration <= 0.0) return null;

    final rule = span.matchedWordRule != null
        ? TajweedRuleFactory.instantiate(span.matchedWordRule!, config)
        : const MushaddadGhunnahRule();

    return DurationEvaluator.evaluateRule(
      rule: rule,
      span: span,
      predText: predText,
      spanDuration: spanDuration,
      speed: speed,
      categoryTag: 'GHUNNAH',
    );
  }
}

/// Evaluates Shaddah consonant gemination and closure holding time.
class ShaddahChecker {
  static ReciterError? check({
    required PhoneticSpan span,
    required String predText,
    required double spanDuration,
    required RecitationSpeed speed,
  }) {
    return DurationEvaluator.evaluateShaddah(
      span: span,
      predText: predText,
      spanDuration: spanDuration,
      speed: speed,
    );
  }
}

/// Evaluates Qalqalah release burst neural score from TajweedFormer V4's multi-head network.
class QalqalahChecker {
  static ReciterError? check({
    required PhoneticSpan span,
    required String predText,
    required TokenNeuralAcoustics spanAcoustics,
    required TrackerConfig config,
  }) {
    return QalqalahEvaluator.evaluate(
      span: span,
      predText: predText,
      spanAcoustics: spanAcoustics,
      config: config,
    );
  }
}

/// Evaluates vowel and diacritic marks (Tashkeel / Harakat) on matching base consonants.
class TashkeelChecker {
  static ReciterError? check({
    required PhoneticSpan span,
    required String predText,
    required int wordRefEnd,
  }) {
    return TashkeelEvaluator.evaluate(
      span: span,
      predText: predText,
      wordRefEnd: wordRefEnd,
    );
  }
}

/// Evaluates consonant letter swaps / substitution errors (إبدال وتبديل الحروف والمخارج).
class LetterSwapChecker {
  static ReciterError? check({
    required PhoneticSpan span,
    required String predText,
  }) {
    if (span.baseChar.isEmpty || predText.isEmpty) return null;
    final int baseCode = span.baseChar.codeUnitAt(0);
    final int predCode = predText.codeUnitAt(0);

    if (baseCode != predCode &&
        !PhoneticCostEngine.isEquivalentGlyph(baseCode, predCode)) {
      return ReciterError(
        errorType: ErrorCategory.normal,
        speechErrorType: SpeechErrorType.replace,
        expectedPh: span.refText,
        predictedPh: predText,
      );
    }
    return null;
  }
}

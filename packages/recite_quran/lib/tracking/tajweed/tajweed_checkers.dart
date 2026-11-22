// lib/tracking/tajweed/tajweed_checkers.dart
// ═══════════════════════════════════════════════════════════════════════════════
// MODULAR TAJWEED RULE EVALUATORS & ACOUSTIC CHECKERS
// ═══════════════════════════════════════════════════════════════════════════════

import '../../engine/core/transcription_result.dart';
import '../../utils/debug_logger.dart';
import '../word/dictation_matcher.dart';
import 'error_explainer.dart';

// ─────────────────────────────────────────────────────────────────────────────
// 1. Shared Duration & Tashkeel Evaluators
// ─────────────────────────────────────────────────────────────────────────────

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
    // Gemination (Shaddah) is calculated the exact same way as Madd and Ghunnah
    return evaluateRule(
      rule: const ShaddahRule(),
      span: span,
      predText: predText,
      spanDuration: spanDuration,
      speed: speed,
      categoryTag: 'SHADDAH',
    );
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

// ─────────────────────────────────────────────────────────────────────────────
// 2. Modular Tajweed Rule Checkers
// ─────────────────────────────────────────────────────────────────────────────

/// Evaluates Madd acoustic prolongation rules (2, 4, 5, 6 Harakat).
class MaddChecker {
  static ReciterError? check({
    required PhoneticSpan span,
    required String predText,
    required double spanDuration,
    required RecitationSpeed speed,
    required TrackerConfig config,
  }) {
    if (spanDuration <= 0.0 || span.matchedWordRule == null) return null;

    final rule = TajweedRuleFactory.instantiate(span.matchedWordRule!, config);

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

import 'package:flutter/material.dart';
import '../core/highlighting_controller.dart';
import '../core/app_state.dart';

export '../core/highlighting_controller.dart' show QuranTypography, QuranInteractionService;

/// Core interactive actions for the Mushaf vector layout.
abstract final class MushafActions {
  /// Converts an integer to Eastern Arabic numeral glyphs (e.g. 1 -> '١').
  static String toArabicDigits(int number) =>
      QuranTypography.toArabicDigits(number);

  /// Handles selecting/tapping an Ayah: haptic feedback, manual selection, and persisting last position.
  static Future<void> selectAyah({
    required int surah,
    required int ayah,
    required HighlightingController controller,
    VoidCallback? onTap,
  }) =>
      QuranInteractionService.selectAyah(
        surah: surah,
        ayah: ayah,
        controller: controller,
        onTap: onTap,
      );

  /// Handles tapping a Quranic word in Mushaf:
  /// - Selects the Ayah.
  /// - If yellow word -> opens Tajweed error dialog.
  /// - If non-yellow word and (already selected or [playWordDirectly]) -> plays word audio.
  static void handleWordTap({
    required BuildContext context,
    required int surah,
    required int ayah,
    required int wordIndex,
    required String wordText,
    required HighlightingController controller,
    VoidCallback? onWordErrorTap,
    VoidCallback? onAyahTap,
    bool playWordDirectly = false,
    List<ReciterError>? overrideErrors,
  }) =>
      QuranInteractionService.handleWordTap(
        context: context,
        surah: surah,
        ayah: ayah,
        wordIndex: wordIndex,
        wordText: wordText,
        controller: controller,
        onWordErrorTap: onWordErrorTap,
        onAyahTap: onAyahTap,
        playWordDirectly: playWordDirectly,
        overrideErrors: overrideErrors,
      );

  /// Toggles Ayah audio playback with buffering debounce and haptic feedback.
  static Future<void> toggleAyahAudio({
    required int surah,
    required int ayah,
    required HighlightingController controller,
    required bool isRecording,
    VoidCallback? onTap,
    VoidCallback? onExplicitToggle,
  }) =>
      QuranInteractionService.toggleAyahAudio(
        surah: surah,
        ayah: ayah,
        controller: controller,
        isRecording: isRecording,
        onTap: onTap,
        onExplicitToggle: onExplicitToggle,
      );

  /// Checks whether a word is marked yellow (Tajweed error/rule),
  /// querying the unified highlight controller directly.
  static bool isWordYellow({
    required int surah,
    required int ayah,
    required int wordIndex,
    required HighlightingController controller,
  }) {
    return controller.isWordYellow(ayah, wordIndex, surah: surah);
  }

  /// Resolves the word display color, handling zero-GPU blur hiding for unrecited words in a single clean pass.
  /// Concealing unrecited words only occurs when [isBlurEffective] is true (i.e. recording or Maglis session active).
  static Color resolveWordDisplayColor({
    required int ayah,
    required int wordIndex,
    required HighlightingController controller,
    required AppState app,
    required ThemeColors colors,
    int? surah,
    bool isBlurEffective = false,
  }) {
    if (wordIndex < 0) return colors.text;
    final int s = surah ??
        (controller.targetSurah != 0
            ? controller.targetSurah
            : AppState.instance.lastSurah);

    // 1. Check recitation status in most-likely order (Green is ~95% of recited words)
    if (controller.isWordGreen(ayah, wordIndex, surah: s)) {
      return colors.green;
    }
    if (controller.isWordYellow(ayah, wordIndex, surah: s)) {
      return colors.warning;
    }
    if (controller.isWordRed(ayah, wordIndex, surah: s)) {
      return colors.red;
    }

    // 2. Check neutral (spoken/passed word without tint)
    final bool isNeutral = controller.isWordNeutral(ayah, wordIndex, surah: s);

    // 3. Blur concealing: hide unrecited words (zero-GPU masking)
    if (isBlurEffective) {
      if (isNeutral) return colors.text;
      return Colors.transparent;
    }

    return colors.text;
  }

  /// Resolves the foreground color for word at index [wordIndex].
  static Color resolveWordColor({
    required int ayah,
    required int wordIndex,
    required HighlightingController controller,
    required ThemeColors colors,
    int? surah,
  }) =>
      resolveWordDisplayColor(
        ayah: ayah,
        wordIndex: wordIndex,
        controller: controller,
        app: AppState.instance,
        colors: colors,
        surah: surah,
        isBlurEffective: false,
      );
}

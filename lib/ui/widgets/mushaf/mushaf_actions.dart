import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:recite_quran/recite_quran.dart';

import '../../../services/quran_audio_service.dart';
import '../../../state/app_state.dart';
import '../dialogs/error_detail_dialog.dart';

/// Core interactive actions for the Mushaf vector layout.
abstract final class MushafActions {
  static final List<String> _arabicDigitsCache = List<String>.generate(650, (i) {
    const digits = ['٠', '١', '٢', '٣', '٤', '٥', '٦', '٧', '٨', '٩'];
    return i.toString().split('').map((e) => digits[int.parse(e)]).join('');
  });

  /// Converts an integer to Eastern Arabic numeral glyphs (e.g. 1 -> '١').
  static String toArabicDigits(int number) {
    if (number >= 0 && number < _arabicDigitsCache.length) {
      return _arabicDigitsCache[number];
    }
    const digits = ['٠', '١', '٢', '٣', '٤', '٥', '٦', '٧', '٨', '٩'];
    return number.toString().split('').map((e) => digits[int.parse(e)]).join('');
  }

  /// Handles selecting/tapping an Ayah: haptic feedback, manual selection, and persisting last position.
  static Future<void> selectAyah({
    required int surah,
    required int ayah,
    required HighlightingController controller,
    VoidCallback? onTap,
  }) async {
    HapticFeedback.lightImpact();
    if (controller.targetSurah != surah) {
      await controller.setTargetSurah(surah, preserveOtherSurahStates: true);
    }
    controller.setManualAyah(surah, ayah);
    AppState.instance.saveLastPosition(surah, ayah);
    onTap?.call();
  }

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
  }) {

    final bool isAlreadySelected =
        controller.targetSurah == surah && controller.activeAyah.value == ayah;

    selectAyah(
      surah: surah,
      ayah: ayah,
      controller: controller,
      onTap: onAyahTap,
    );

    if (controller.isWordYellow(ayah, wordIndex, surah: surah)) {
      AppState.instance.markTajweedWordClicked();
      final errors = controller.getWordErrors(ayah, wordIndex);
      if (errors != null && errors.isNotEmpty) {
        ErrorDetailDialog.show(
          context,
          word: wordText,
          errors: errors,
          surah: surah,
          ayah: ayah,
          wordIndex: wordIndex,
        );
        onWordErrorTap?.call();
      }
    } else if (isAlreadySelected || playWordDirectly) {
      QuranAudioService.instance.playWord(
        surah: surah,
        ayah: ayah,
        wordIndex: wordIndex,
      );
    }
  }

  /// Toggles Ayah audio playback with buffering debounce and haptic feedback.
  static Future<void> toggleAyahAudio({
    required int surah,
    required int ayah,
    required HighlightingController controller,
    required bool isRecording,
    VoidCallback? onTap,
    VoidCallback? onExplicitToggle,
  }) async {
    if (AppState.instance.isAudioBuffering.value &&
        AppState.instance.activeAudioSurah.value == surah &&
        AppState.instance.activeAudioAyah.value == ayah) {
      return;
    }
    HapticFeedback.selectionClick();
    if (controller.targetSurah != surah) {
      await controller.setTargetSurah(
        surah,
        preserveOtherSurahStates: true,
        clearTargetSurah: false,
      );
    }
    controller.setManualAyah(surah, ayah);
    AppState.instance.saveLastPosition(surah, ayah);
    onTap?.call();
    if (onExplicitToggle != null) {
      onExplicitToggle();
    } else {
      AppState.instance.toggleVerseAudio(
        surah: surah,
        ayah: ayah,
        continuous: !isRecording,
      );
    }
  }

  /// Resolves the foreground color for word at index [wordIndex].
  static Color resolveWordColor({
    required int ayah,
    required int wordIndex,
    required HighlightingController controller,
    required ThemeColors colors,
    int? surah,
  }) {
    if (wordIndex < 0) return colors.text;
    if (controller.isWordGreen(ayah, wordIndex, surah: surah)) return colors.green;
    if (controller.isWordRed(ayah, wordIndex, surah: surah)) return colors.red;
    if (controller.isWordYellow(ayah, wordIndex, surah: surah)) return colors.warning;
    return colors.text;
  }

  /// Resolves the word display color, handling zero-GPU blur hiding for unrecited words.
  static Color resolveWordDisplayColor({
    required int ayah,
    required int wordIndex,
    required HighlightingController controller,
    required AppState app,
    required ThemeColors colors,
    int? surah,
  }) {
    if (wordIndex < 0) return colors.text;
    if (app.isBlurMode) {
      final isRead = controller.isWordGreen(ayah, wordIndex, surah: surah) ||
          controller.isWordRed(ayah, wordIndex, surah: surah) ||
          controller.isWordYellow(ayah, wordIndex, surah: surah) ||
          controller.isWordNeutral(ayah, wordIndex, surah: surah);
      if (!isRead) return Colors.transparent;
    }

    return resolveWordColor(
      ayah: ayah,
      wordIndex: wordIndex,
      controller: controller,
      colors: colors,
      surah: surah,
    );
  }
}

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import '../state/highlighting_controller.dart';
import '../state/app_state.dart';

/// Pure helper for generating high-performance, styled [InlineSpan] lists for Quranic verses.
/// Handles zero-GPU blur hiding, color status resolution, and word gesture binding.
class VerseSpanBuilder {
  /// Resolves the foreground color for word at index [wordIndex].
  /// Kept at [colors.text] so sacred Uthmani typography remains crisp black/pearl,
  /// while background pastel pills handle recitation status matching Mushaf mode.
  static Color resolveWordColor({
    required int ayah,
    required int wordIndex,
    required HighlightingController controller,
    required ThemeColors colors,
    int? surah,
  }) {
    if (wordIndex < 0) return colors.text;
    return colors.text;
  }

  /// Resolves the word display color, handling zero-GPU blur hiding for unrecited words.
  static Color resolveWordDisplayColor({
    required int ayah,
    required int wordIndex,
    required HighlightingController controller,
    required AppState app,
    required ThemeColors colors,
    required bool isAutoScrolling,
    int? surah,
    bool isBlurEffective = false,
  }) {
    if (wordIndex < 0) return colors.text;
    if (isBlurEffective && !isAutoScrolling) {
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

  /// Builds the complete list of [InlineSpan]s representing an Ayah's text.
  static List<InlineSpan> buildSpans({
    required List<String> words,
    required int ayah,
    int? surah,
    required bool isActive,
    required bool isAutoScrolling,
    bool isRecording = false,
    required HighlightingController controller,
    required AppState app,
    required ThemeColors colors,
    required List<TapGestureRecognizer> recognizersSink,
    required VoidCallback? onVerseTap,
    required void Function(int ayah, int wordIndex, String word) onWordErrorTap,
    void Function(int ayah, int wordIndex)? onWordAudioTap,
  }) {
    final List<InlineSpan> spans = [];
    final bool enableGestures = !isAutoScrolling;
    final bool isBlurEffective =
        app.isBlurEffective(isRecording: isRecording);

    final TextStyle defaultStyle = TextStyle(
      fontFamily: 'HafsSmart',
      fontSize: app.fontSize,
      height: 2.6,
      wordSpacing: 5.0,
      color: colors.text,
    );

    final InlineSpan spaceSpan = TextSpan(
      text: ' ',
      style: defaultStyle,
    );

    // Bug fix: also check globalRevision > 0 — if any words were matched in this session,
    // keep resolving colors for ALL ayahs so previously-recited ayahs don't lose their color
    // when the user deselects them or stops recording.
    final bool hasHighlights = isActive ||
        isRecording ||
        isBlurEffective ||
        controller.globalRevision.value > 0 ||
        controller.completedAyahsFor(surah ?? controller.targetSurah).contains(ayah);

    for (int i = 0; i < words.length; i++) {
      final Color color = hasHighlights
          ? resolveWordDisplayColor(
              ayah: ayah,
              wordIndex: i,
              controller: controller,
              app: app,
              colors: colors,
              isAutoScrolling: isAutoScrolling,
              surah: surah,
              isBlurEffective: isBlurEffective,
            )
          : colors.text;

      final word = words[i];
      final wordIdx = i;

      TapGestureRecognizer? recognizer;
      if (enableGestures) {
        recognizer = TapGestureRecognizer()
          ..onTap = () {
            if (controller.isWordYellow(ayah, wordIdx, surah: surah)) {
              onWordErrorTap(ayah, wordIdx, word);
            } else {
              onWordAudioTap?.call(ayah, wordIdx);
            }
          };
        recognizersSink.add(recognizer);
      }

      final TextStyle? style = (color == colors.text)
          ? defaultStyle
          : defaultStyle.copyWith(color: color);

      // ALWAYS add the word as a standard TextSpan!
      spans.add(
        TextSpan(
          text: word,
          style: style,
          recognizer: recognizer,
        ),
      );

      // Word separator
      if (i < words.length - 1) {
        spans.add(spaceSpan);
      }
    }

    return spans;
  }
}

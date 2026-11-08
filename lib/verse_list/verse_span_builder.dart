import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import '../core/highlighting_controller.dart';
import '../core/app_state.dart';

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
      if (!controller.isWordRead(ayah, wordIndex, surah: surah)) {
        return Colors.transparent;
      }
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


class TajweedTooltipPainter extends CustomPainter {
  final List<String> words;
  final int ayah;
  final int? surah;
  final HighlightingController controller;
  final AppState app;
  final List<InlineSpan> cachedSpans;

  TajweedTooltipPainter({
    required this.words,
    required this.ayah,
    this.surah,
    required this.controller,
    required this.app,
    required this.cachedSpans,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (app.hasClickedTajweedWord) return;

    // Fast check: if this Ayah has no yellow words, exit immediately!
    // Eliminates 100% of synchronous HarfBuzz layout passes across idle verses during scrolling.
    bool hasYellowWord = false;
    for (int i = 0; i < words.length; i++) {
      if (controller.isWordYellow(ayah, i, surah: surah)) {
        hasYellowWord = true;
        break;
      }
    }
    if (!hasYellowWord) return;

    // We must exactly replicate the RichText layout to get accurate coordinates
    // We MUST set minWidth to size.width so the TextPainter matches the full width of the
    // stretched RichText, otherwise the RTL text will be offset to the left!
    final painter = TextPainter(
      text: TextSpan(children: cachedSpans),
      textAlign: TextAlign.justify,
      textDirection: TextDirection.rtl,
    );
    painter.layout(minWidth: size.width, maxWidth: size.width);

    final String text = app.isArabic ? 'Ø§Ø¶ØºØ· Ù‡Ù†Ø§' : 'Tap here';
    final textStyle = const TextStyle(
      color: Colors.white,
      fontSize: 7, // Too small causes pixel-bleed; 7 is the absolute minimum for legibility
      fontWeight: FontWeight.w600, // Bold is too thick at this size and causes letters to smudge
      fontFamily: 'sans-serif',
    );
    final textPainter = TextPainter(
      text: TextSpan(text: text, style: textStyle),
      textAlign: TextAlign.center,
      textDirection: app.isArabic ? TextDirection.rtl : TextDirection.ltr,
    )..layout();

    final bgPaint = Paint()
      ..color = app.colors.gold
      ..style = PaintingStyle.fill;
      
    final rrectRadius = const Radius.circular(4);

    int charOffset = 0;
    for (int i = 0; i < words.length; i++) {
      final word = words[i];
      if (controller.isWordYellow(ayah, i, surah: surah)) {
        final rects = painter.getBoxesForSelection(
          TextSelection(baseOffset: charOffset, extentOffset: charOffset + word.length),
        );
        if (rects.isNotEmpty) {
          double left = rects.first.left;
          double right = rects.first.right;
          double bottom = rects.first.bottom;
          for (final r in rects) {
            if (r.left < left) left = r.left;
            if (r.right > right) right = r.right;
            if (r.bottom > bottom) bottom = r.bottom;
          }
          final centerX = left + (right - left) / 2;

          // Draw the tooltip perfectly centered at the bottom of the bounding box.
          // Restore the 4px padding on each side (total 8) to match the original Container look
          final tooltipWidth = (textPainter.width + 8).roundToDouble(); 
          final tooltipHeight = (textPainter.height + 2).roundToDouble(); 
          
          final tooltipX = (centerX - tooltipWidth / 2).roundToDouble();
          final tooltipY = (bottom + 2).roundToDouble();
          
          final bgRect = RRect.fromLTRBR(
            tooltipX,
            tooltipY,
            tooltipX + tooltipWidth,
            tooltipY + tooltipHeight,
            rrectRadius,
          );
          
          canvas.drawRRect(bgRect, bgPaint);
          
          // Re-layout the text painter to perfectly match the box width,
          // so Flutter's internal TextAlign.center completely handles the text centering!
          textPainter.layout(minWidth: tooltipWidth, maxWidth: tooltipWidth);
          
          textPainter.paint(
            canvas,
            Offset(tooltipX, tooltipY + 1),
          );
          
          // Only 1 label per ayah: stop after painting the first yellow word
          break;
        }
      }
      charOffset += word.length + 1; // +1 for the space separator
    }

    painter.dispose();
    textPainter.dispose();
  }

  @override
  bool shouldRepaint(covariant TajweedTooltipPainter oldDelegate) {
    return oldDelegate.app.hasClickedTajweedWord != app.hasClickedTajweedWord ||
           oldDelegate.ayah != ayah || 
           oldDelegate.words.length != words.length;
  }
}

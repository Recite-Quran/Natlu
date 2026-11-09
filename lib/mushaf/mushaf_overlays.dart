import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:qvp_flutter/qvp_flutter.dart';
import '../core/app_state.dart';
import '../core/highlighting_controller.dart';

/// Ultra-lightweight, zero-allocation single-pass overlay/underlay painters
/// for Surah headers, Ayah audio indicators, and Tajweed tutorial tooltips.
class MushafOverlays {
  MushafOverlays._();

  static final Paint _headerFillPaint = Paint()..style = PaintingStyle.fill;
  static final Paint _headerBorderPaint = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 0.8;
  static final Paint _highlightFillPaint = Paint()..style = PaintingStyle.fill;

  static final Paint _bgPaint = Paint()..style = PaintingStyle.fill;
  static final Paint _ringPaint = Paint()..style = PaintingStyle.stroke;
  static final Paint _goldPaint = Paint()..style = PaintingStyle.fill;
  static final Paint _spinnerPaint = Paint()
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round;

  static final Paint _tooltipBgPaint = Paint()..style = PaintingStyle.fill;
  static const Radius _tooltipRadius = Radius.circular(4);
  static const TextStyle _tooltipTextStyle = TextStyle(
    color: Colors.white,
    fontSize: 7,
    fontWeight: FontWeight.w600,
    fontFamily: 'sans-serif',
  );

  static TextPainter? _cachedPainterAr;
  static TextPainter? _cachedPainterEn;

  static TextPainter _getTooltipTextPainter(bool isArabic) {
    if (isArabic) {
      if (_cachedPainterAr == null) {
        _cachedPainterAr = TextPainter(
          text: const TextSpan(text: 'اضغط هنا', style: _tooltipTextStyle),
          textAlign: TextAlign.center,
          textDirection: TextDirection.rtl,
        )..layout();
        final w = (_cachedPainterAr!.width + 8).roundToDouble();
        _cachedPainterAr!.layout(minWidth: w, maxWidth: w);
      }
      return _cachedPainterAr!;
    } else {
      if (_cachedPainterEn == null) {
        _cachedPainterEn = TextPainter(
          text: const TextSpan(text: 'Tap here', style: _tooltipTextStyle),
          textAlign: TextAlign.center,
          textDirection: TextDirection.ltr,
        )..layout();
        final w = (_cachedPainterEn!.width + 8).roundToDouble();
        _cachedPainterEn!.layout(minWidth: w, maxWidth: w);
      }
      return _cachedPainterEn!;
    }
  }

  /// Single-pass underlay: Paints elegant modern cards behind Surah titles.
  static void paintSurahHeaders(
    Canvas canvas,
    QvpPage page,
    QvpLayout? layout, {
    required bool isDark,
    required ThemeColors colors,
  }) {
    if (page.isDisposed) return;
    final headers = page.surahHeadersView();
    if (headers.isEmpty) return;

    final l = layout ?? page.readLayout() ?? page.currentLayout;
    if (l == null) return;

    final double contentW = l.contentW;

    _headerFillPaint.color = isDark
        ? const Color(0xFF1E252D).withValues(alpha: 0.75)
        : const Color(0xFFF7F4EB);

    _headerBorderPaint.color = isDark
        ? colors.gold.withValues(alpha: 0.20)
        : colors.gold.withValues(alpha: 0.30);

    for (final h in headers) {
      final double top = h.y1 > h.y0 ? h.y0 : (h.titleY0 - 6.0);
      final double bottom = h.y1 > h.y0 ? h.y1 : (h.titleY1 + 6.0);
      if (bottom <= top) continue;

      final double left = (h.x1 > h.x0 && h.x0 >= 0) ? h.x0 : 0.0;
      final double right = (h.x1 > h.x0 && h.x1 <= contentW) ? h.x1 : contentW;

      final rect = Rect.fromLTRB(left, top, right, bottom);
      canvas.drawRect(rect, _headerFillPaint);
      canvas.drawLine(Offset(left, top), Offset(right, top), _headerBorderPaint);
      canvas.drawLine(Offset(left, bottom), Offset(right, bottom), _headerBorderPaint);
    }
  }

  /// Single-pass underlay: Paints continuous Ayah highlight boxes and word state segments.
  /// Renders behind the base ink:
  /// - The selected/active ayah is ONE continuous rounded highlight box on each line.
  /// - Unrecited words in the active ayah are grey.
  /// - The current awaited word is neon highlighted.
  /// - Correctly recited words seamlessly become green.
  /// - Mispronounced words become red, Tajweed warnings yellow.
  /// - Adjacent words on the same line meet at their midpoint with ZERO overlap and ZERO gap.
  ///   Colors NEVER merge, blend, or darken into dark red.
  static void paintAyahHighlights(
    Canvas canvas,
    QvpPage page,
    QvpLayout? layout, {
    required HighlightingController controller,
    required AppState app,
    required bool isRecording,
  }) {
    if (page.isDisposed) return;

    final isDark = app.isDarkMode;
    final palette =
        QuranHighlightPalette.fromTheme(colors: app.colors, isDark: isDark);

    // 1. Resolve Active Ayah Coordinate (surah, ayah)
    final coord = controller.activeAyahCoordinate ??
        (app.lastSurah != 0 && app.lastAyah != 0
            ? (app.lastSurah, app.lastAyah)
            : null);

    final int activeSurah = coord?.$1 ?? 0;
    final int activeAyah = coord?.$2 ?? 0;

    // 2. Resolve Active / Waited Lead Word on this page
    int? activeWordPageIdx;
    if (activeSurah != 0 && activeAyah != 0) {
      int maxWordOnPage = 0;
      for (final w in page.words) {
        if (w.surah == activeSurah &&
            w.ayah == activeAyah &&
            w.word > maxWordOnPage) {
          maxWordOnPage = w.word;
        }
      }
      final leadW0 = controller.getLeadWordIndex(
        surah: activeSurah,
        ayah: activeAyah,
        totalWords: maxWordOnPage,
        isRecording: isRecording,
      );
      if (leadW0 != null) {
        final idx = page.findWord(activeSurah, activeAyah, leadW0 + 1);
        if (idx >= 0) activeWordPageIdx = idx;
      }
    }

    // 3. Identify all ayahs to render on this page:
    //    a) The active selected ayah (if present)
    //    b) Completed ayahs for surahs on this page
    //    c) Any ayah with stored highlights (evaluated words)
    final ayahsToPaint = <(int, int)>{};
    if (activeSurah != 0 && activeAyah != 0) {
      ayahsToPaint.add((activeSurah, activeAyah));
    }

    for (final w in page.words) {
      final key = (w.surah, w.ayah);
      if (ayahsToPaint.contains(key)) continue;

      if (controller.completedAyahsFor(w.surah).contains(w.ayah) ||
          controller.hasAyahHighlights(w.surah, w.ayah) ||
          controller.getWordStatus(w.ayah, w.word - 1, surah: w.surah) != null) {
        ayahsToPaint.add(key);
      }
    }

    if (ayahsToPaint.isEmpty) return;

    final wordBoxes = page.wordBoxesView();
    if (wordBoxes.isEmpty) return;

    // 4. Render continuous line boxes for each ayah
    for (final (s, a) in ayahsToPaint) {
      final bool isActiveAyah = (s == activeSurah && a == activeAyah);

      final wordsInAyah = <QvpWordInfo>[];
      for (final w in page.words) {
        if (w.surah == s && w.ayah == a) {
          wordsInAyah.add(w);
        }
      }
      if (wordsInAyah.isEmpty) continue;

      // Group words by line
      final wordsByLine = <int, List<QvpWordInfo>>{};
      for (final w in wordsInAyah) {
        (wordsByLine[w.line] ??= []).add(w);
      }

      for (final lineWords in wordsByLine.values) {
        if (lineWords.isEmpty) continue;

        // Sort in Arabic reading order: word 1 is on the right
        lineWords.sort((w1, w2) => w1.word.compareTo(w2.word));
        final int k = lineWords.length;

        // Find the outer bounds of this ayah on this line
        double lineX0 = double.infinity;
        double lineX1 = double.negativeInfinity;
        double lineY0 = double.infinity;
        double lineY1 = double.negativeInfinity;

        for (var i = 0; i < k; i++) {
          final b = wordBoxes[lineWords[i].index];
          if (b != null) {
            if (b.x0 < lineX0) lineX0 = b.x0;
            if (b.x1 > lineX1) lineX1 = b.x1;
            if (b.y0 < lineY0) lineY0 = b.y0;
            if (b.y1 > lineY1) lineY1 = b.y1;
          }
        }

        if (lineX1 <= lineX0 || lineY1 <= lineY0) continue;

        // Compute non-overlapping split boundaries between adjacent words
        // In RTL: lineWords[0] is rightmost (highest X), lineWords[k-1] is leftmost (lowest X)
        final splitX = List<double>.filled(k > 1 ? k - 1 : 0, 0.0);
        for (var i = 0; i < k - 1; i++) {
          final bCurr = wordBoxes[lineWords[i].index];
          final bNext = wordBoxes[lineWords[i + 1].index];
          if (bCurr != null && bNext != null) {
            // bCurr is to the right of bNext:
            // bCurr.x0 is left edge of bCurr, bNext.x1 is right edge of bNext
            splitX[i] = ((bCurr.x0 + bNext.x1) / 2.0).clamp(lineX0, lineX1);
          } else {
            splitX[i] = lineX0 + (lineX1 - lineX0) * ((k - 1 - i) / k);
          }
        }

        final outerRect = Rect.fromLTRB(lineX0, lineY0, lineX1, lineY1);
        final outerRRect =
            RRect.fromRectAndRadius(outerRect, const Radius.circular(3.0));

        canvas.save();
        canvas.clipRRect(outerRRect);

        for (var i = 0; i < k; i++) {
          final w = lineWords[i];
          final double left = (i == k - 1) ? lineX0 : splitX[i];
          final double right = (i == 0) ? lineX1 : splitX[i - 1];

          final double minX = math.min(left, right);
          final double maxX = math.max(left, right);
          if (maxX - minX <= 0.1) continue;

          final wordRect = Rect.fromLTRB(minX, lineY0, maxX, lineY1);
          final color = _resolveWordColor(
            w: w,
            isActiveAyah: isActiveAyah,
            activeWordPageIdx: activeWordPageIdx,
            controller: controller,
            palette: palette,
          );

          if (color.a > 0) {
            _highlightFillPaint.color = color;
            canvas.drawRect(wordRect, _highlightFillPaint);
          }
        }

        canvas.restore();
      }
    }
  }

  static Color _resolveWordColor({
    required QvpWordInfo w,
    required bool isActiveAyah,
    required int? activeWordPageIdx,
    required HighlightingController controller,
    required QuranHighlightPalette palette,
  }) {
    // 1. Current active / waited word -> Neon
    if (activeWordPageIdx != null && w.index == activeWordPageIdx) {
      return palette.leadWordBand;
    }

    final int w0 = w.word - 1;
    int? status = controller.getWordStatus(w.ayah, w0, surah: w.surah);

    // Completed ayah words are treated as green
    if ((status == null || status == 0) &&
        controller.completedAyahsFor(w.surah).contains(w.ayah)) {
      status = 1;
    }

    if (status == 1) {
      return palette.greenBand;
    } else if (status == 2) {
      return palette.yellowBand;
    } else if (status == 3) {
      return palette.redBand;
    } else if (isActiveAyah) {
      // Selected/active ayah unrecited words -> Grey!
      return palette.activeAyahBand;
    }
    return Colors.transparent;
  }

  /// Single-pass overlay: Paints Ayah audio loading spinner arc, and stop icon.
  static void paintAyahMarks(
    Canvas canvas,
    QvpPage page,
    QvpLayout? layout, {
    required AppState app,
    required double spinnerProgress,
    required Color surfaceColor,
    required Color goldColor,
    Color? neutralRingColor,
    Color? ayahHighlightColor,
    HighlightingController? controller,
  }) {
    if (page.isDisposed) return;
    final l = layout ?? page.currentLayout;
    if (l == null) return;

    // Upgraded: ayahMarksView() computes exact layout/viewport coordinates directly in Rust core
    final marks = page.ayahMarksView();
    if (marks.isEmpty) return;

    _goldPaint.color = goldColor;
    _spinnerPaint.color = goldColor;

    final ringColor = neutralRingColor ??
        (app.isDarkMode
            ? Colors.white.withValues(alpha: 0.25)
            : const Color(0xFF64748B).withValues(alpha: 0.35));

    for (final m in marks) {
      final center = Offset(m.cx, m.cy);
      final double customR = m.r * 0.80;

      final bool isThisBuffering = controller != null &&
          controller.isAyahAudioBuffering(m.surah, m.ayah);
      final bool isThisPlaying = controller != null &&
          controller.isAyahAudioPlaying(m.surah, m.ayah);

      if (isThisBuffering) {
        _bgPaint.color = surfaceColor;
        canvas.drawCircle(center, customR, _bgPaint);

        _ringPaint.color = goldColor;
        _ringPaint.strokeWidth = 1.2;
        canvas.drawCircle(center, customR, _ringPaint);

        final double spinRadius = customR * 0.58;
        final double strokeW = math.max(customR * 0.18, 1.4);
        _spinnerPaint.strokeWidth = strokeW;
        final double startAngle = spinnerProgress * 2 * math.pi;
        canvas.drawArc(
          Rect.fromCircle(center: center, radius: spinRadius),
          startAngle,
          2.4,
          false,
          _spinnerPaint,
        );
      } else if (isThisPlaying) {
        _bgPaint.color = surfaceColor;
        canvas.drawCircle(center, customR, _bgPaint);

        _ringPaint.color = goldColor;
        _ringPaint.strokeWidth = 1.2;
        canvas.drawCircle(center, customR, _ringPaint);

        final double stopHalf = customR * 0.32;
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromCenter(
              center: center,
              width: stopHalf * 2,
              height: stopHalf * 2,
            ),
            Radius.circular(stopHalf * 0.25),
          ),
          _goldPaint,
        );
      } else {
        // Normal state: ring color stays strictly consistent and neutral.
        // It NEVER changes color on completion or during recitation highlighting.
        _ringPaint.color = ringColor;
        _ringPaint.strokeWidth = 1.0;
        canvas.drawCircle(center, customR, _ringPaint);
      }
    }
  }

  /// Single-pass overlay: Paints onboarding Tajweed tutorial tooltip ("اضغط هنا") beneath yellow words.
  static void paintTajweedTooltip(
    Canvas canvas,
    Size size,
    QvpPage page,
    QvpLayout? layout, {
    required AppState app,
    required Color goldColor,
    required List<int> yellowWords,
  }) {
    if (app.hasClickedTajweedWord ||
        app.currentMode != AppMode.tajweed ||
        page.isDisposed ||
        yellowWords.isEmpty) {
      return;
    }

    final l = layout ?? page.readLayout() ?? page.currentLayout;
    if (l == null) return;

    final textPainter = _getTooltipTextPainter(app.isArabic);
    final tooltipWidth = textPainter.width;
    final tooltipHeight = (textPainter.height + 2).roundToDouble();

    _tooltipBgPaint.color = goldColor;

    final Map<int, List<int>> wordsByLine = {};
    for (final wordIdx in yellowWords) {
      if (wordIdx < 0 || wordIdx >= page.words.length) continue;
      final line = page.words[wordIdx].line;
      (wordsByLine[line] ??= []).add(wordIdx);
    }

    const double minGap = 2.0;

    final double maxW = l.contentW > 0 ? l.contentW : size.width;

    final wordBoxes = page.wordBoxesView();
    for (final entry in wordsByLine.entries) {
      final wordsOnLine = entry.value;
      final List<_BadgePosition> lineBadges = [];

      for (final wordIdx in wordsOnLine) {
        final box = wordBoxes[wordIdx];
        if (box == null) continue;
        final double centerX = (box.x0 + box.x1) / 2.0;
        final double idealX = centerX - tooltipWidth / 2.0;
        final double tooltipY = (box.y1 + 1.0).roundToDouble();

        lineBadges.add(_BadgePosition(x: idealX, y: tooltipY));
      }

      if (lineBadges.length > 1) {
        lineBadges.sort((a, b) => a.x.compareTo(b.x));

        for (int i = 0; i < lineBadges.length - 1; i++) {
          final cur = lineBadges[i];
          final next = lineBadges[i + 1];
          if (cur.x + tooltipWidth + minGap > next.x) {
            final overlap = (cur.x + tooltipWidth + minGap) - next.x;
            cur.x -= overlap / 2.0;
            next.x += overlap / 2.0;
          }
        }

        for (int i = 1; i < lineBadges.length; i++) {
          if (lineBadges[i].x < lineBadges[i - 1].x + tooltipWidth + minGap) {
            lineBadges[i].x = lineBadges[i - 1].x + tooltipWidth + minGap;
          }
        }

        if (lineBadges.last.x + tooltipWidth > maxW - 4.0) {
          final shift = (lineBadges.last.x + tooltipWidth) - (maxW - 4.0);
          for (final b in lineBadges) {
            b.x -= shift;
          }
        }
        if (lineBadges.first.x < 4.0) {
          final shift = 4.0 - lineBadges.first.x;
          for (final b in lineBadges) {
            b.x += shift;
          }
        }
      } else if (lineBadges.isNotEmpty) {
        lineBadges.first.x = lineBadges.first.x
            .clamp(4.0, maxW - tooltipWidth - 4.0)
            .roundToDouble();
      }

      for (final badge in lineBadges) {
        final double bx = badge.x.roundToDouble();
        final double by = badge.y;

        final bgRect = RRect.fromLTRBR(
          bx,
          by,
          bx + tooltipWidth,
          by + tooltipHeight,
          _tooltipRadius,
        );

        canvas.drawRRect(bgRect, _tooltipBgPaint);
        textPainter.paint(canvas, Offset(bx, by + 1.0));
      }
    }
  }
}

class _BadgePosition {
  double x;
  final double y;
  _BadgePosition({required this.x, required this.y});
}

/// Backward compatibility class adapters
class SurahHeaderPainter extends CustomPainter {
  final QvpPage page;
  final bool isDark;
  final ThemeColors colors;
  SurahHeaderPainter({required this.page, required this.isDark, required this.colors, Listenable? repaintListenable}) : super(repaint: repaintListenable);
  @override
  void paint(Canvas canvas, Size size) => MushafOverlays.paintSurahHeaders(canvas, page, page.currentLayout, isDark: isDark, colors: colors);
  @override
  bool shouldRepaint(SurahHeaderPainter old) => old.page != page || old.isDark != isDark || old.colors != colors;
}

class AyahMarkPainter extends CustomPainter {
  final QvpPage page;
  final AppState app;
  final Animation<double> spinnerAnimation;
  final Color surfaceColor;
  final Color goldColor;
  final Color neutralRingColor;
  final Color ayahHighlightColor;
  final HighlightingController? controller;
  AyahMarkPainter({
    required this.page,
    required this.app,
    required this.spinnerAnimation,
    required this.surfaceColor,
    required this.goldColor,
    required this.neutralRingColor,
    required this.ayahHighlightColor,
    this.controller,
    Listenable? repaintListenable,
  }) : super(repaint: repaintListenable);
  @override
  void paint(Canvas canvas, Size size) => MushafOverlays.paintAyahMarks(
        canvas,
        page,
        page.currentLayout,
        app: app,
        spinnerProgress: spinnerAnimation.value,
        surfaceColor: surfaceColor,
        goldColor: goldColor,
        neutralRingColor: neutralRingColor,
        ayahHighlightColor: ayahHighlightColor,
        controller: controller,
      );
  @override
  bool shouldRepaint(AyahMarkPainter old) => true;
}

class MushafTajweedTooltipPainter extends CustomPainter {
  final QvpPage page;
  final HighlightingController controller;
  final AppState app;
  final Color goldColor;
  final List<int>? explicitYellowWords;
  MushafTajweedTooltipPainter({
    required this.page,
    required this.controller,
    required this.app,
    required this.goldColor,
    this.explicitYellowWords,
    Listenable? repaintListenable,
  }) : super(repaint: repaintListenable);
  @override
  void paint(Canvas canvas, Size size) => MushafOverlays.paintTajweedTooltip(
        canvas,
        size,
        page,
        page.currentLayout,
        app: app,
        goldColor: goldColor,
        yellowWords: explicitYellowWords ?? const [],
      );
  @override
  bool shouldRepaint(MushafTajweedTooltipPainter old) => true;
}

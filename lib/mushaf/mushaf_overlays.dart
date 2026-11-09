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

    final double fitScale = l.fitScale;
    final double fitX = l.fitX;
    final double fitY = l.fitY;
    final double contentW = l.contentW;

    _headerFillPaint.color = isDark
        ? const Color(0xFF1E252D).withValues(alpha: 0.75)
        : const Color(0xFFF7F4EB);

    _headerBorderPaint.color = isDark
        ? colors.gold.withValues(alpha: 0.20)
        : colors.gold.withValues(alpha: 0.30);

    for (final h in headers) {
      final double rawTop = h.y1 > h.y0 ? h.y0 : (h.titleY0 - 6.0);
      final double rawBottom = h.y1 > h.y0 ? h.y1 : (h.titleY1 + 6.0);
      final double top = fitY + fitScale * rawTop;
      final double bottom = fitY + fitScale * rawBottom;
      if (bottom <= top) continue;

      final double left = fitX + fitScale * (h.x1 > h.x0 ? h.x0 : 0.0);
      final double right = fitX + fitScale * (h.x1 > h.x0 ? h.x1 : contentW);

      final rect = Rect.fromLTRB(left, top, right, bottom);
      canvas.drawRect(rect, _headerFillPaint);
      canvas.drawLine(Offset(left, top), Offset(right, top), _headerBorderPaint);
      canvas.drawLine(Offset(left, bottom), Offset(right, bottom), _headerBorderPaint);
    }
  }

  /// Single-pass overlay: Paints Ayah rings, live audio loading spinner arc, and stop icon.
  static void paintAyahMarks(
    Canvas canvas,
    QvpPage page,
    QvpLayout? layout, {
    required AppState app,
    required double spinnerProgress,
    required Color surfaceColor,
    required Color goldColor,
    required Color neutralRingColor,
    required Color ayahHighlightColor,
    HighlightingController? controller,
  }) {
    if (page.isDisposed) return;
    final l = layout ?? page.currentLayout;
    if (l == null) return;

    // Upgraded: ayahMarksView() computes exact layout/viewport coordinates directly in Rust core
    final marks = page.ayahMarksView();
    if (marks.isEmpty) return;

    final int? audioSurah = app.activeAudioSurah.value;
    final int? audioAyah = app.activeAudioAyah.value;
    final bool isBuffering = app.isAudioBuffering.value;
    final bool isPlaying = app.isAudioPlaying.value;

    final Color blendedMaskColor =
        Color.alphaBlend(ayahHighlightColor, surfaceColor);

    _goldPaint.color = goldColor;
    _spinnerPaint.color = goldColor;

    for (final m in marks) {
      final center = Offset(m.cx, m.cy);
      final double customR = m.r * 0.80;

      final bool isThisBuffering =
          isBuffering && audioSurah == m.surah && audioAyah == m.ayah;
      final bool isThisPlaying =
          isPlaying && audioSurah == m.surah && audioAyah == m.ayah;

      if (isThisBuffering) {
        _bgPaint.color = blendedMaskColor;
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
        _bgPaint.color = blendedMaskColor;
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
        final bool isCompleted = controller != null &&
            controller.completedAyahsFor(m.surah).contains(m.ayah);
        if (isCompleted) {
          _ringPaint.color = goldColor.withValues(alpha: 0.65);
          _ringPaint.strokeWidth = 1.2;
        } else {
          _ringPaint.color = neutralRingColor;
          _ringPaint.strokeWidth = 1.0;
        }
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

    for (final entry in wordsByLine.entries) {
      final wordsOnLine = entry.value;
      final List<_BadgePosition> lineBadges = [];

      for (final wordIdx in wordsOnLine) {
        final bands = page.wordBandsView([wordIdx]);
        if (bands.isEmpty) continue;
        final box = bands.first;
        final double centerX = (box.x0 + box.x1) / 2.0;
        final double idealX = centerX - tooltipWidth / 2.0;
        final double tooltipY = (box.y1 - 4.0).roundToDouble();

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

        if (lineBadges.last.x + tooltipWidth > size.width - 4.0) {
          final shift = (lineBadges.last.x + tooltipWidth) - (size.width - 4.0);
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
            .clamp(4.0, size.width - tooltipWidth - 4.0)
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

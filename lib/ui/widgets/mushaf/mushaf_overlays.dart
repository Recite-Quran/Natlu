import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:qvp_flutter/qvp_flutter.dart';

import '../../../state/app_state.dart';

/// Modern flat card behind the Surah title calligraphy.
/// Uses exact viewport coordinates from [page.surahHeadersView()].
class SurahHeaderPainter extends CustomPainter {
  final QvpPage page;
  final bool isDark;
  final ThemeColors colors;

  SurahHeaderPainter({
    required this.page,
    required this.isDark,
    required this.colors,
  });

  static final Paint _fillPaint = Paint()..style = PaintingStyle.fill;
  static final Paint _borderPaint = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 0.8;

  @override
  void paint(Canvas canvas, Size size) {
    if (page.isDisposed) return;
    final headers = page.surahHeadersView();
    if (headers.isEmpty) return;

    final boxFillColor = isDark
        ? const Color(0xFF1E252D).withValues(alpha: 0.75)
        : const Color(0xFFF7F4EB);

    final borderLineColor = isDark
        ? colors.gold.withValues(alpha: 0.20)
        : colors.gold.withValues(alpha: 0.30);

    _fillPaint.color = boxFillColor;
    _borderPaint.color = borderLineColor;

    for (final h in headers) {
      // surahHeadersView() returns exact viewport pixels through the current layout
      final double top = math.min(h.y0, h.y1);
      final double bottom = math.max(h.y0, h.y1);
      if (bottom <= top) continue;

      final rect = Rect.fromLTRB(0.0, top, size.width, bottom);
      canvas.drawRect(rect, _fillPaint);
      canvas.drawLine(Offset(0.0, top), Offset(size.width, top), _borderPaint);
      canvas.drawLine(Offset(0.0, bottom), Offset(size.width, bottom), _borderPaint);
    }
  }

  @override
  bool shouldRepaint(SurahHeaderPainter old) =>
      old.page != page || old.isDark != isDark || old.colors != colors;
}

/// Minimalist vector circle around the Ayah numeral:
/// - Idle: Subtle neutral ring with generous clearance from adjacent words.
/// - Buffering: Gold spinning vector loader arc over a highlight-matched mask.
/// - Playing: Gold rounded stop icon.
/// - Stopped: Clean return to neutral ring with the native numeral showing through.
class AyahMarkPainter extends CustomPainter {
  final QvpPage page;
  final AppState app;
  final Animation<double> spinnerAnimation;
  final Color surfaceColor;
  final Color goldColor;
  final Color neutralRingColor;
  final Color ayahHighlightColor;

  AyahMarkPainter({
    required this.page,
    required this.app,
    required this.spinnerAnimation,
    required this.surfaceColor,
    required this.goldColor,
    required this.neutralRingColor,
    required this.ayahHighlightColor,
  }) : super(
          repaint: Listenable.merge([
            spinnerAnimation,
            app.activeAudioAyah,
            app.activeAudioSurah,
            app.isAudioBuffering,
            app.isAudioPlaying,
          ]),
        );

  static final Paint _bgPaint = Paint()..style = PaintingStyle.fill;
  static final Paint _ringPaint = Paint()..style = PaintingStyle.stroke;
  static final Paint _goldPaint = Paint()..style = PaintingStyle.fill;
  static final Paint _spinnerPaint = Paint()
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round;

  @override
  void paint(Canvas canvas, Size size) {
    if (page.isDisposed) return;
    final layout = page.currentLayout;
    if (layout == null) return;

    final marks = page.ayahMarks();
    if (marks.isEmpty) return;

    final ls = layout.scale;
    final fitScale = layout.fitScale;
    final fitX = layout.fitX;
    final fitY = layout.fitY;
    final lineDy = layout.lineDy;

    final int? audioSurah = app.activeAudioSurah.value;
    final int? audioAyah = app.activeAudioAyah.value;
    final bool isBuffering = app.isAudioBuffering.value;
    final bool isPlaying = app.isAudioPlaying.value;

    final Color blendedMaskColor =
        Color.alphaBlend(ayahHighlightColor, surfaceColor);

    _goldPaint.color = goldColor;
    _spinnerPaint.color = goldColor;

    for (final m in marks) {
      final lineOffset =
          (m.line >= 0 && m.line < lineDy.length) ? lineDy[m.line] : 0.0;
      final double vx = layout.offsetX + m.cx * ls;
      final double vy = layout.offsetY + (m.cy + lineOffset) * ls;
      final double vr = m.r * ls;

      final double sx = fitX + fitScale * vx;
      final double sy = fitY + fitScale * vy;
      final double sr = fitScale * vr;

      // 0.80 radius ratio leaves 3-5px breathing space so words never touch the ring
      final double customR = sr * 0.80;
      final center = Offset(sx, sy);

      final bool isThisBuffering =
          isBuffering && audioSurah == m.surah && audioAyah == m.ayah;
      final bool isThisPlaying =
          isPlaying && audioSurah == m.surah && audioAyah == m.ayah;

      if (isThisBuffering) {
        // Mask numeral seamlessly matching background + ayah highlight
        _bgPaint.color = blendedMaskColor;
        canvas.drawCircle(center, customR, _bgPaint);

        // Gold active ring
        _ringPaint.color = goldColor;
        _ringPaint.strokeWidth = 1.2;
        canvas.drawCircle(center, customR, _ringPaint);

        // Rotating gold loader arc
        final double spinRadius = customR * 0.58;
        _spinnerPaint.strokeWidth = math.max(customR * 0.18, 1.4);
        final double startAngle = spinnerAnimation.value * 2 * math.pi;
        canvas.drawArc(
          Rect.fromCircle(center: center, radius: spinRadius),
          startAngle,
          2.4,
          false,
          _spinnerPaint,
        );
      } else if (isThisPlaying) {
        // Mask numeral seamlessly matching background + ayah highlight
        _bgPaint.color = blendedMaskColor;
        canvas.drawCircle(center, customR, _bgPaint);

        // Gold active ring
        _ringPaint.color = goldColor;
        _ringPaint.strokeWidth = 1.2;
        canvas.drawCircle(center, customR, _ringPaint);

        // Rounded gold stop square
        final double stopHalf = customR * 0.32;
        final stopRect = Rect.fromCenter(
          center: center,
          width: stopHalf * 2,
          height: stopHalf * 2,
        );
        canvas.drawRRect(
          RRect.fromRectAndRadius(stopRect, Radius.circular(stopHalf * 0.25)),
          _goldPaint,
        );
      } else {
        // Idle state: Subtle neutral ring, native numeral visible
        _ringPaint.color = neutralRingColor;
        _ringPaint.strokeWidth = 1.0;
        canvas.drawCircle(center, customR, _ringPaint);
      }
    }
  }

  @override
  bool shouldRepaint(AyahMarkPainter old) =>
      old.page != page ||
      old.surfaceColor != surfaceColor ||
      old.goldColor != goldColor ||
      old.neutralRingColor != neutralRingColor ||
      old.ayahHighlightColor != ayahHighlightColor;
}

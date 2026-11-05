import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:qvp_flutter/qvp_flutter.dart';
import 'package:recite_quran/recite_quran.dart';

import '../../../state/app_state.dart';
import '../../../maglis/maglis_controller.dart';

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
  }) : super(repaint: page);

  static final Paint _fillPaint = Paint()..style = PaintingStyle.fill;
  static final Paint _borderPaint = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 0.8;

  @override
  void paint(Canvas canvas, Size size) {
    if (page.isDisposed) return;
    final headers = page.surahHeadersView();
    if (headers.isEmpty) return;

    final layout = page.readLayout() ?? page.currentLayout;
    if (layout == null) return;

    final double fitScale = layout.fitScale;
    final double fitX = layout.fitX;
    final double fitY = layout.fitY;
    final double contentW = layout.contentW;

    final boxFillColor = isDark
        ? const Color(0xFF1E252D).withValues(alpha: 0.75)
        : const Color(0xFFF7F4EB);

    final borderLineColor = isDark
        ? colors.gold.withValues(alpha: 0.20)
        : colors.gold.withValues(alpha: 0.30);

    _fillPaint.color = boxFillColor;
    _borderPaint.color = borderLineColor;

    for (final h in headers) {
      final double rawTop = h.y1 > h.y0 ? h.y0 : (h.titleY0 - 6.0);
      final double rawBottom = h.y1 > h.y0 ? h.y1 : (h.titleY1 + 6.0);
      final double top = fitY + fitScale * rawTop;
      final double bottom = fitY + fitScale * rawBottom;
      if (bottom <= top) continue;

      final double left = fitX + fitScale * (h.x1 > h.x0 ? h.x0 : 0.0);
      final double right = fitX + fitScale * (h.x1 > h.x0 ? h.x1 : contentW);

      final rect = Rect.fromLTRB(left, top, right, bottom);
      canvas.drawRect(rect, _fillPaint);
      canvas.drawLine(Offset(left, top), Offset(right, top), _borderPaint);
      canvas.drawLine(Offset(left, bottom), Offset(right, bottom), _borderPaint);
    }
  }

  @override
  bool shouldRepaint(SurahHeaderPainter old) =>
      old.page != page || old.isDark != isDark || old.colors != colors;
}

class _CachedMarkGeometry {
  final int surah;
  final int ayah;
  final Offset center;
  final double customR;
  final Rect spinRect;
  final double spinnerStrokeWidth;
  final RRect stopRRect;

  const _CachedMarkGeometry({
    required this.surah,
    required this.ayah,
    required this.center,
    required this.customR,
    required this.spinRect,
    required this.spinnerStrokeWidth,
    required this.stopRRect,
  });
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

  Object? _lastLayout;
  List<_CachedMarkGeometry>? _cachedMarks;

  AyahMarkPainter({
    required this.page,
    required this.app,
    required this.spinnerAnimation,
    required this.surfaceColor,
    required this.goldColor,
    required this.neutralRingColor,
    required this.ayahHighlightColor,
    Listenable? repaintListenable,
  }) : super(
          repaint: repaintListenable ??
              Listenable.merge([
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

  List<_CachedMarkGeometry> _computeGeometries(
      dynamic layout, List<QvpAyahMark> marks) {
    final ls = layout.scale as double;
    final fitScale = layout.fitScale as double;
    final fitX = layout.fitX as double;
    final fitY = layout.fitY as double;
    final lineDy = layout.lineDy as List<double>;

    final result = <_CachedMarkGeometry>[];
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

      final double spinRadius = customR * 0.58;
      final double strokeW = math.max(customR * 0.18, 1.4);
      final spinRect = Rect.fromCircle(center: center, radius: spinRadius);

      final double stopHalf = customR * 0.32;
      final stopRect = Rect.fromCenter(
        center: center,
        width: stopHalf * 2,
        height: stopHalf * 2,
      );
      final stopRRect = RRect.fromRectAndRadius(
        stopRect,
        Radius.circular(stopHalf * 0.25),
      );

      result.add(_CachedMarkGeometry(
        surah: m.surah,
        ayah: m.ayah,
        center: center,
        customR: customR,
        spinRect: spinRect,
        spinnerStrokeWidth: strokeW,
        stopRRect: stopRRect,
      ));
    }
    return result;
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (page.isDisposed) return;
    final layout = page.currentLayout;
    if (layout == null) return;

    if (!identical(_lastLayout, layout) || _cachedMarks == null) {
      final marks = page.ayahMarks();
      if (marks.isEmpty) return;
      _lastLayout = layout;
      _cachedMarks = _computeGeometries(layout, marks);
    }

    final cachedMarks = _cachedMarks;
    if (cachedMarks == null || cachedMarks.isEmpty) return;

    final int? audioSurah = app.activeAudioSurah.value;
    final int? audioAyah = app.activeAudioAyah.value;
    final bool isBuffering = app.isAudioBuffering.value;
    final bool isPlaying = app.isAudioPlaying.value;

    final Color blendedMaskColor =
        Color.alphaBlend(ayahHighlightColor, surfaceColor);

    _goldPaint.color = goldColor;
    _spinnerPaint.color = goldColor;

    for (final m in cachedMarks) {
      final bool isThisBuffering =
          isBuffering && audioSurah == m.surah && audioAyah == m.ayah;
      final bool isThisPlaying =
          isPlaying && audioSurah == m.surah && audioAyah == m.ayah;

      if (isThisBuffering) {
        // Mask numeral seamlessly matching background + ayah highlight
        _bgPaint.color = blendedMaskColor;
        canvas.drawCircle(m.center, m.customR, _bgPaint);

        // Gold active ring
        _ringPaint.color = goldColor;
        _ringPaint.strokeWidth = 1.2;
        canvas.drawCircle(m.center, m.customR, _ringPaint);

        // Rotating gold loader arc
        _spinnerPaint.strokeWidth = m.spinnerStrokeWidth;
        final double startAngle = spinnerAnimation.value * 2 * math.pi;
        canvas.drawArc(
          m.spinRect,
          startAngle,
          2.4,
          false,
          _spinnerPaint,
        );
      } else if (isThisPlaying) {
        // Mask numeral seamlessly matching background + ayah highlight
        _bgPaint.color = blendedMaskColor;
        canvas.drawCircle(m.center, m.customR, _bgPaint);

        // Gold active ring
        _ringPaint.color = goldColor;
        _ringPaint.strokeWidth = 1.2;
        canvas.drawCircle(m.center, m.customR, _ringPaint);

        // Rounded gold stop square
        canvas.drawRRect(m.stopRRect, _goldPaint);
      } else {
        // Idle state: Subtle neutral ring, native numeral visible
        _ringPaint.color = neutralRingColor;
        _ringPaint.strokeWidth = 1.0;
        canvas.drawCircle(m.center, m.customR, _ringPaint);
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

/// Minimalist Tajweed tutorial tooltip ("اضغط هنا" / "Tap here")
/// painted directly beneath yellow Tajweed error words on the Mushaf vector page.
///
/// Performance & UI invariants:
/// - Only active in Tajweed mode during onboarding (!hasClickedTajweedWord).
/// - Positioned strictly DOWN underneath the word ink baseline using exact layout math.
/// - Anti-collision: concurrent/adjacent yellow words share a single clean badge (never collapses/overlaps).
/// - Instant O(1) exit if no words on this page are yellow.
/// - Zero impact on non-Tajweed modes or once onboarding clicks reach 10.
class MushafTajweedTooltipPainter extends CustomPainter {
  final QvpPage page;
  final HighlightingController controller;
  final AppState app;
  final Color goldColor;

  MushafTajweedTooltipPainter({
    required this.page,
    required this.controller,
    required this.app,
    required this.goldColor,
    Listenable? repaintListenable,
  }) : super(
          repaint: repaintListenable ??
              Listenable.merge([
                page,
                app,
                app.modeNotifier,
                controller.globalRevision,
                MaglisController.instance,
              ]),
        );

  static final Paint _bgPaint = Paint()..style = PaintingStyle.fill;
  static const Radius _rrectRadius = Radius.circular(4);
  static const TextStyle _textStyle = TextStyle(
    color: Colors.white,
    fontSize: 7,
    fontWeight: FontWeight.w600,
    fontFamily: 'sans-serif',
  );

  @override
  void paint(Canvas canvas, Size size) {
    if (app.hasClickedTajweedWord ||
        app.currentMode != AppMode.tajweed ||
        page.isDisposed) {
      return;
    }

    final maglis = MaglisController.instance;

    bool isWordYellow(int a, int w0, int s) =>
        controller.isWordYellow(a, w0, surah: s) ||
        (maglis.inSession &&
            (maglis.remoteYellowWords.contains(w0) ||
                maglis.getWordHighlight(s, a, w0) == 2 ||
                maglis.getWordErrors(s, a, w0) != null));

    final yellowWords = <int>[];
    final seenAyahs = <int>{};
    for (int i = 0; i < page.words.length; i++) {
      final w = page.words[i];
      final ayahKey = (w.surah << 16) | w.ayah;
      if (seenAyahs.contains(ayahKey)) continue;
      final w0 = w.word - 1;
      if (isWordYellow(w.ayah, w0, w.surah)) {
        yellowWords.add(i);
        seenAyahs.add(ayahKey);
      }
    }

    if (yellowWords.isEmpty) return;

    final layout = page.readLayout() ?? page.currentLayout;
    if (layout == null) return;

    final String text = app.isArabic ? 'اضغط هنا' : 'Tap here';
    final textPainter = TextPainter(
      text: TextSpan(text: text, style: _textStyle),
      textAlign: TextAlign.center,
      textDirection: app.isArabic ? TextDirection.rtl : TextDirection.ltr,
    )..layout();

    final tooltipWidth = (textPainter.width + 8).roundToDouble();
    final tooltipHeight = (textPainter.height + 2).roundToDouble();
    textPainter.layout(minWidth: tooltipWidth, maxWidth: tooltipWidth);

    _bgPaint.color = goldColor;

    final double ls = layout.scale;
    final double fitScale = layout.fitScale;
    final double fitX = layout.fitX;
    final double fitY = layout.fitY;
    final List<double> lineDy = layout.lineDy;

    // Group yellow words by line so concurrent/adjacent words on the same line
    // can each have their own badge without overlapping or collapsing.
    final Map<int, List<int>> wordsByLine = {};
    for (final wordIdx in yellowWords) {
      if (wordIdx < 0 || wordIdx >= page.words.length) continue;
      final line = page.words[wordIdx].line;
      (wordsByLine[line] ??= []).add(wordIdx);
    }

    const double minGap = 2.0;

    for (final entry in wordsByLine.entries) {
      final wordsOnLine = entry.value;

      final List<_MushafBadgeItem> lineBadges = [];
      for (final wordIdx in wordsOnLine) {
        final w = page.words[wordIdx];
        final double lineOffset =
            (w.line >= 0 && w.line < lineDy.length) ? lineDy[w.line] : 0.0;
        final double vx0 = layout.offsetX + w.x0 * ls;
        final double vx1 = layout.offsetX + w.x1 * ls;
        final double vy0 = layout.offsetY + (w.y0 + lineOffset) * ls;
        final double vy1 = layout.offsetY + (w.y1 + lineOffset) * ls;

        final double left = fitX + fitScale * math.min(vx0, vx1);
        final double right = fitX + fitScale * math.max(vx0, vx1);
        final double bottom = fitY + fitScale * math.max(vy0, vy1);
        final double centerX = (left + right) / 2.0;

        final double idealX = centerX - tooltipWidth / 2.0;
        // Positioned closer to the word from down, tucked snugly beneath the baseline
        final double tooltipY = (bottom - 4.0).roundToDouble();

        lineBadges.add(_MushafBadgeItem(x: idealX, y: tooltipY));
      }

      if (lineBadges.length > 1) {
        // Sort left-to-right
        lineBadges.sort((a, b) => a.x.compareTo(b.x));

        // Push overlapping adjacent badges apart so both words get their own distinct badge
        for (int i = 0; i < lineBadges.length - 1; i++) {
          final cur = lineBadges[i];
          final next = lineBadges[i + 1];
          if (cur.x + tooltipWidth + minGap > next.x) {
            final overlap = (cur.x + tooltipWidth + minGap) - next.x;
            cur.x -= overlap / 2.0;
            next.x += overlap / 2.0;
          }
        }

        // Enforce strictly non-overlapping positions
        for (int i = 1; i < lineBadges.length; i++) {
          if (lineBadges[i].x < lineBadges[i - 1].x + tooltipWidth + minGap) {
            lineBadges[i].x = lineBadges[i - 1].x + tooltipWidth + minGap;
          }
        }

        // Clamp group within screen boundaries
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

      // Paint all badges on this line
      for (final badge in lineBadges) {
        final double bx = badge.x.roundToDouble();
        final double by = badge.y;

        final bgRect = RRect.fromLTRBR(
          bx,
          by,
          bx + tooltipWidth,
          by + tooltipHeight,
          _rrectRadius,
        );

        canvas.drawRRect(bgRect, _bgPaint);
        textPainter.paint(canvas, Offset(bx, by + 1.0));
      }
    }

    textPainter.dispose();
  }

  @override
  bool shouldRepaint(MushafTajweedTooltipPainter oldDelegate) =>
      oldDelegate.page != page ||
      oldDelegate.goldColor != goldColor ||
      oldDelegate.app.isArabic != app.isArabic ||
      oldDelegate.app.hasClickedTajweedWord != app.hasClickedTajweedWord ||
      oldDelegate.app.currentMode != app.currentMode;
}

class _MushafBadgeItem {
  double x;
  final double y;
  _MushafBadgeItem({required this.x, required this.y});
}

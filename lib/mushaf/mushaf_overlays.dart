import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show listEquals;
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

  static final Paint _ringPaint = Paint()..style = PaintingStyle.stroke;
  static final Paint _goldPaint = Paint()..style = PaintingStyle.fill;

  static final Paint _tooltipBgPaint = Paint()..style = PaintingStyle.fill;
  static const Radius _tooltipRadius = Radius.circular(4);
  static const Radius _highlightCornerRadius = Radius.circular(3.0);
  static final List<Color> _lineColorsScratch = <Color>[];
  static const TextStyle _tooltipTextStyle = TextStyle(
    color: Colors.white,
    fontSize: 7,
    fontWeight: FontWeight.w600,
    fontFamily: 'sans-serif',
  );

  static TextPainter? _cachedPainterAr;
  static TextPainter? _cachedPainterEn;

  static final Expando<_PageWordLayoutCache> _pageWordCaches =
      Expando<_PageWordLayoutCache>();

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

    // 1. Resolve Active Ayah Coordinate (surah, ayah)
    // Strictly from controller only — no fallback to app.lastSurah/lastAyah.
    final coord = controller.activeAyahCoordinate;
    final int activeSurah = coord?.$1 ?? 0;
    final int activeAyah = coord?.$2 ?? 0;

    final l = layout ?? page.currentLayout ?? page.readLayout();
    final cached = _pageWordCaches[page];
    final _PageWordLayoutCache cache;
    if (cached == null || cached.layout != l) {
      cache = _PageWordLayoutCache.fromPage(page, l);
      _pageWordCaches[page] = cache;
    } else {
      cache = cached;
    }
    final wordsByAyah = cache.wordsByAyah;

    // 2. Identify all ayahs to render on this page BEFORE allocating palettes or geometry.
    final ayahsToPaint = <(int, int)>[];
    if (activeSurah != 0 &&
        activeAyah != 0 &&
        wordsByAyah.containsKey((activeSurah, activeAyah))) {
      ayahsToPaint.add((activeSurah, activeAyah));
    }

    for (final key in wordsByAyah.keys) {
      if (key.$1 == activeSurah && key.$2 == activeAyah) continue;
      if (controller.hasAyahHighlights(key.$1, key.$2)) {
        ayahsToPaint.add(key);
      }
    }

    if (ayahsToPaint.isEmpty) return;

    final isDark = app.isDarkMode;
    final palette =
        QuranHighlightPalette.fromTheme(colors: app.colors, isDark: isDark);

    // 3. Resolve Active / Waited Lead Word on this page with zero FFI calls.
    int? activeWordPageIdx;
    if (activeSurah != 0 && activeAyah != 0) {
      final activeWords = wordsByAyah[(activeSurah, activeAyah)];
      final maxWordOnPage = cache.maxWordPerAyah[(activeSurah, activeAyah)] ?? 0;
      if (activeWords != null && maxWordOnPage > 0) {
        final leadW0 = controller.getLeadWordIndex(
          surah: activeSurah,
          ayah: activeAyah,
          totalWords: maxWordOnPage,
          isRecording: isRecording,
        );
        if (leadW0 != null) {
          final targetWord1Based = leadW0 + 1;
          for (final w in activeWords) {
            if (w.word == targetWord1Based) {
              activeWordPageIdx = w.index;
              break;
            }
          }
        }
      }
    }

    // 4. Lazy per-ayah highlight geometry & direct rounded-run drawing (no per-line save/clipRRect).
    for (final (s, a) in ayahsToPaint) {
      final bool isActiveAyah = (s == activeSurah && a == activeAyah);
      final lines = cache.lineGeometriesFor(page, s, a);
      if (lines.isEmpty) continue;

      for (final line in lines) {
        final rects = line.wordRects;
        final k = rects.length;
        if (k == 0) continue;

        _lineColorsScratch.clear();
        for (var j = 0; j < k; j++) {
          _lineColorsScratch.add(
            _resolveWordColor(
              w: rects[j].word,
              isActiveAyah: isActiveAyah,
              activeWordPageIdx: activeWordPageIdx,
              controller: controller,
              palette: palette,
            ),
          );
        }

        var i = 0;
        while (i < k) {
          final color = _lineColorsScratch[i];
          var end = i;
          while (end + 1 < k && _lineColorsScratch[end + 1] == color) {
            end++;
          }
          if (color.a > 0) {
            _highlightFillPaint.color = color;
            if (i == 0 && end == k - 1) {
              canvas.drawRRect(line.outerRRect, _highlightFillPaint);
            } else {
              final runRect = Rect.fromLTRB(
                rects[end].rect.left,
                line.outerRRect.top,
                rects[i].rect.right,
                line.outerRRect.bottom,
              );
              if (i == 0) {
                canvas.drawRRect(
                  RRect.fromRectAndCorners(
                    runRect,
                    topRight: _highlightCornerRadius,
                    bottomRight: _highlightCornerRadius,
                  ),
                  _highlightFillPaint,
                );
              } else if (end == k - 1) {
                canvas.drawRRect(
                  RRect.fromRectAndCorners(
                    runRect,
                    topLeft: _highlightCornerRadius,
                    bottomLeft: _highlightCornerRadius,
                  ),
                  _highlightFillPaint,
                );
              } else {
                canvas.drawRect(runRect, _highlightFillPaint);
              }
            }
          }
          i = end + 1;
        }
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

    // 2. Stored word verdict only — the renderer never invents color.
    // Words without a verdict (never received from the package) stay
    // transparent; "ayah completed" is a separate concept used by flow
    // decisions, not a paint instruction.
    final int? status =
        controller.getWordStatus(w.ayah, w.word - 1, surah: w.surah);

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

  /// Single-pass overlay: Paints Ayah audio indicators (loading ring, stop icon).
  ///
  /// The rotating buffering arc is NOT painted here: it lives on an isolated
  /// top layer driven only by the spinner controller, so its 60–120Hz ticks
  /// repaint just that tiny painter instead of re-recording this whole page.
  /// This painter redraws only when audio state actually changes (ring/icon).
  static void paintAyahMarks(
    Canvas canvas,
    QvpPage page,
    QvpLayout? layout, {
    required AppState app,
    required Color surfaceColor,
    required Color goldColor,
    Color? neutralRingColor,
    Color? ayahHighlightColor,
    HighlightingController? controller,
    bool paintNeutral = true,
    bool paintActive = true,
  }) {
    if (page.isDisposed) return;
    if (!paintNeutral && !paintActive) return;
    if (!paintNeutral &&
        (controller == null ||
            controller.audioSurah == null ||
            controller.audioAyah == null)) {
      return;
    }
    final l = layout ?? page.currentLayout;
    if (l == null) return;

    final marks = page.ayahMarksView();
    if (marks.isEmpty) return;

    final Color greenBtnColor = app.colors.primary;

    final ringColor = neutralRingColor ??
        (app.isDarkMode
            ? const Color(0xFF94A3B8).withValues(alpha: 0.30)
            : const Color(0xFF64748B).withValues(alpha: 0.35));

    for (final m in marks) {
      final bool isThisBuffering = paintActive &&
          controller != null &&
          controller.isAyahAudioBuffering(m.surah, m.ayah);
      final bool isThisPlaying = paintActive &&
          controller != null &&
          controller.isAyahAudioPlaying(m.surah, m.ayah);

      if (!isThisBuffering && !isThisPlaying && !paintNeutral) continue;

      final center = Offset(m.cx, m.cy);
      final double customR = m.r * 0.80;

      if (isThisBuffering) {
        _headerFillPaint.color = surfaceColor;
        canvas.drawCircle(center, customR - 0.5, _headerFillPaint);

        _ringPaint.color = greenBtnColor;
        _ringPaint.strokeWidth = 1.2;
        canvas.drawCircle(center, customR, _ringPaint);
      } else if (isThisPlaying) {
        _headerFillPaint.color = surfaceColor;
        canvas.drawCircle(center, customR - 0.5, _headerFillPaint);

        _ringPaint.color = greenBtnColor;
        _ringPaint.strokeWidth = 1.2;
        canvas.drawCircle(center, customR, _ringPaint);

        final double stopHalf = customR * 0.32;
        _goldPaint.color = greenBtnColor;
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
      } else if (paintNeutral) {
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

    final l = layout ?? page.currentLayout ?? page.readLayout();
    if (l == null) return;

    final textPainter = _getTooltipTextPainter(app.isArabic);
    final tooltipWidth = textPainter.width;
    final tooltipHeight = (textPainter.height + 2).roundToDouble();

    final double maxW = l.contentW > 0 ? l.contentW : size.width;

    // Badge geometry is cached per (page, layout, yellowWords) with zero full-page FFI calls.
    if (!identical(page, _tooltipCachePage) ||
        !identical(l, _tooltipCacheLayout) ||
        !listEquals(yellowWords, _tooltipCacheWords)) {
      _tooltipCachePage = page;
      _tooltipCacheLayout = l;
      _tooltipCacheWords = yellowWords;
      _tooltipCacheBadges = _computeTooltipBadges(
        page,
        l,
        yellowWords,
        tooltipWidth: tooltipWidth,
        tooltipHeight: tooltipHeight,
        maxW: maxW,
      );
    }
    final badges = _tooltipCacheBadges;
    if (badges == null || badges.isEmpty) return;

    _tooltipBgPaint.color = goldColor;
    for (final (rawX, by) in badges) {
      final double bx = rawX.roundToDouble();

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

  static QvpPage? _tooltipCachePage;
  static QvpLayout? _tooltipCacheLayout;
  static List<int>? _tooltipCacheWords;
  static List<(double, double)>? _tooltipCacheBadges;

  /// Resolves badge positions for the current yellow words: one badge per
  /// ayah, placed beneath its first word's line, then spread apart so badges
  /// never overlap and stay inside the content bounds.
  static List<(double, double)> _computeTooltipBadges(
    QvpPage page,
    QvpLayout layout,
    List<int> yellowWords, {
    required double tooltipWidth,
    required double tooltipHeight,
    required double maxW,
  }) {
    final Set<int> seenAyahs = {};
    final Map<int, List<int>> wordsByLine = {};
    for (final wordIdx in yellowWords) {
      if (wordIdx < 0 || wordIdx >= page.words.length) continue;
      final w = page.words[wordIdx];
      final ayahKey = QuranCoordinate.packAyahKey(w.surah, w.ayah);
      if (seenAyahs.add(ayahKey)) {
        final line = w.line;
        (wordsByLine[line] ??= []).add(wordIdx);
      }
    }

    const double minGap = 2.0;

    final badges = <(double, double)>[];
    for (final wordsOnLine in wordsByLine.values) {
      final List<_BadgePosition> lineBadges = [];

      for (final wordIdx in wordsOnLine) {
        final box = page.wordBoxView(wordIdx, layout: layout);
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
        badges.add((badge.x, badge.y));
      }
    }
    return badges;
  }
}

class _BadgePosition {
  double x;
  final double y;
  _BadgePosition({required this.x, required this.y});
}

class _LineHighlightGeometry {
  final RRect outerRRect;
  final List<({QvpWordInfo word, Rect rect})> wordRects;

  const _LineHighlightGeometry({
    required this.outerRRect,
    required this.wordRects,
  });
}

class _PageWordLayoutCache {
  final QvpLayout? layout;
  final Map<(int, int), List<QvpWordInfo>> wordsByAyah;
  final Map<(int, int), int> maxWordPerAyah;
  final Map<(int, int), List<_LineHighlightGeometry>> _lineGeometriesCache = {};

  _PageWordLayoutCache._({
    required this.layout,
    required this.wordsByAyah,
    required this.maxWordPerAyah,
  });

  factory _PageWordLayoutCache.fromPage(QvpPage page, [QvpLayout? currentLayout]) {
    final wordsByAyah = <(int, int), List<QvpWordInfo>>{};
    final maxWordPerAyah = <(int, int), int>{};
    for (final w in page.words) {
      final key = (w.surah, w.ayah);
      (wordsByAyah[key] ??= []).add(w);
      final currentMax = maxWordPerAyah[key] ?? 0;
      if (w.word > currentMax) {
        maxWordPerAyah[key] = w.word;
      }
    }

    return _PageWordLayoutCache._(
      layout: currentLayout,
      wordsByAyah: wordsByAyah,
      maxWordPerAyah: maxWordPerAyah,
    );
  }

  /// Lazily computes continuous midpoint-split line geometries for one ayah on demand,
  /// using zero-FFI layout box math via [QvpPage.wordBoxView].
  List<_LineHighlightGeometry> lineGeometriesFor(
    QvpPage page,
    int surah,
    int ayah,
  ) {
    final ayahKey = (surah, ayah);
    final existing = _lineGeometriesCache[ayahKey];
    if (existing != null) return existing;

    final ayahWords = wordsByAyah[ayahKey];
    if (ayahWords == null || ayahWords.isEmpty) {
      return _lineGeometriesCache[ayahKey] = const [];
    }

    final byLine = <int, List<QvpWordInfo>>{};
    for (final w in ayahWords) {
      (byLine[w.line] ??= []).add(w);
    }

    final list = <_LineHighlightGeometry>[];
    for (final lineWords in byLine.values) {
      if (lineWords.isEmpty) continue;
      if (lineWords.length > 1) {
        lineWords.sort((w1, w2) => w1.word.compareTo(w2.word));
      }
      final int k = lineWords.length;

      final boxes = List<QvpBox>.generate(
        k,
        (i) => page.wordBoxView(lineWords[i].index, layout: layout),
      );

      double lineX0 = double.infinity;
      double lineX1 = double.negativeInfinity;
      double lineY0 = double.infinity;
      double lineY1 = double.negativeInfinity;

      for (var i = 0; i < k; i++) {
        final b = boxes[i];
        if (b.x0 < lineX0) lineX0 = b.x0;
        if (b.x1 > lineX1) lineX1 = b.x1;
        if (b.y0 < lineY0) lineY0 = b.y0;
        if (b.y1 > lineY1) lineY1 = b.y1;
      }

      if (lineX1 <= lineX0 || lineY1 <= lineY0) continue;

      final outerRect = Rect.fromLTRB(lineX0, lineY0, lineX1, lineY1);
      final outerRRect =
          RRect.fromRectAndRadius(outerRect, const Radius.circular(3.0));

      final rects = <({QvpWordInfo word, Rect rect})>[];
      for (var i = 0; i < k; i++) {
        final w = lineWords[i];
        final b = boxes[i];

        final double right = (i == 0)
            ? lineX1
            : ((boxes[i - 1].x0 + b.x1) / 2.0).clamp(lineX0, lineX1);

        final double left = (i == k - 1)
            ? lineX0
            : ((b.x0 + boxes[i + 1].x1) / 2.0).clamp(lineX0, lineX1);

        final double minX = math.min(left, right);
        final double maxX = math.max(left, right);
        if (maxX > minX) {
          rects.add((
            word: w,
            rect: Rect.fromLTRB(minX, lineY0, maxX, lineY1),
          ));
        }
      }

      list.add(_LineHighlightGeometry(
        outerRRect: outerRRect,
        wordRects: rects,
      ));
    }

    return _lineGeometriesCache[ayahKey] = list;
  }
}

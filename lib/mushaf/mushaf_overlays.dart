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

    final isDark = app.isDarkMode;
    final palette =
        QuranHighlightPalette.fromTheme(colors: app.colors, isDark: isDark);

    // 1. Resolve Active Ayah Coordinate (surah, ayah)
    // Strictly from controller only — no fallback to app.lastSurah/lastAyah.
    // When no ayah is selected, coord is null and we return early (no word loops, no FFI).
    final coord = controller.activeAyahCoordinate;

    final int activeSurah = coord?.$1 ?? 0;
    final int activeAyah = coord?.$2 ?? 0;

    // Cache completed ayahs per unique surah on the page (1-3 surahs max),
    // eliminating hundreds of Set allocations per frame.
    final completedAyahsCache = <int, Set<int>>{};
    Set<int> getCompletedAyahs(int surah) =>
        completedAyahsCache.putIfAbsent(surah, () => controller.completedAyahsFor(surah));

    // Pre-group words by (surah, ayah) and pre-sort by line once per page lifetime
    final cache = _pageWordCaches[page] ??= _PageWordLayoutCache.fromPage(page);
    final wordsByAyah = cache.wordsByAyah;

    // 2. Resolve Active / Waited Lead Word on this page
    int? activeWordPageIdx;
    if (activeSurah != 0 && activeAyah != 0) {
      final maxWordOnPage = cache.maxWordPerAyah[(activeSurah, activeAyah)] ?? 0;
      if (maxWordOnPage > 0) {
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
    }

    // 3. Identify all ayahs to render on this page:
    //    a) The active selected ayah (if present)
    //    b) Completed ayahs for surahs on this page
    //    c) Any ayah with stored highlights (evaluated words)
    final ayahsToPaint = <(int, int)>{};
    if (activeSurah != 0 && activeAyah != 0 && wordsByAyah.containsKey((activeSurah, activeAyah))) {
      ayahsToPaint.add((activeSurah, activeAyah));
    }

    for (final entry in wordsByAyah.entries) {
      final key = entry.key;
      if (ayahsToPaint.contains(key)) continue;
      final s = key.$1;
      final a = key.$2;

      if (getCompletedAyahs(s).contains(a) ||
          controller.hasAyahHighlights(s, a)) {
        ayahsToPaint.add(key);
        continue;
      }

      for (final w in entry.value) {
        if (controller.getWordStatus(w.ayah, w.word - 1, surah: w.surah) != null) {
          ayahsToPaint.add(key);
          break;
        }
      }
    }

    if (ayahsToPaint.isEmpty) return;

    final wordBoxes = page.wordBoxesView();
    if (wordBoxes.isEmpty) return;

    // 4. Render continuous line boxes for each ayah
    for (final (s, a) in ayahsToPaint) {
      final bool isActiveAyah = (s == activeSurah && a == activeAyah);
      final wordsByLine = cache.wordsByAyahAndLine[(s, a)];
      if (wordsByLine == null || wordsByLine.isEmpty) continue;

      for (final lineWords in wordsByLine.values) {
        if (lineWords.isEmpty) continue;
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

        // Word boundaries are computed inline from the neighbour boxes —
        // zero per-line allocations. In RTL: lineWords[0] is rightmost
        // (highest X). The boundary between adjacent words sits at the
        // midpoint of the left edge of the right word and the right edge of
        // the left word, clamped to the ayah's outer bounds on that line.
        final outerRect = Rect.fromLTRB(lineX0, lineY0, lineX1, lineY1);
        final outerRRect =
            RRect.fromRectAndRadius(outerRect, const Radius.circular(3.0));

        canvas.save();
        canvas.clipRRect(outerRRect);

        for (var i = 0; i < k; i++) {
          final w = lineWords[i];
          final b = wordBoxes[w.index];

          // Right edge of word i = split between word i-1 and word i.
          final double right;
          if (i == 0) {
            right = lineX1;
          } else {
            final bPrev = wordBoxes[lineWords[i - 1].index];
            right = (bPrev != null && b != null)
                ? ((bPrev.x0 + b.x1) / 2.0).clamp(lineX0, lineX1)
                : lineX0 + (lineX1 - lineX0) * ((k - i) / k);
          }

          // Left edge of word i = split between word i and word i+1.
          final double left;
          if (i == k - 1) {
            left = lineX0;
          } else {
            final bNext = wordBoxes[lineWords[i + 1].index];
            left = (b != null && bNext != null)
                ? ((b.x0 + bNext.x1) / 2.0).clamp(lineX0, lineX1)
                : lineX0 + (lineX1 - lineX0) * ((k - 1 - i) / k);
          }

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
            getCompletedAyahs: getCompletedAyahs,
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
    required Set<int> Function(int surah) getCompletedAyahs,
  }) {
    // 1. Current active / waited word -> Neon
    if (activeWordPageIdx != null && w.index == activeWordPageIdx) {
      return palette.leadWordBand;
    }

    final int w0 = w.word - 1;
    int? status = controller.getWordStatus(w.ayah, w0, surah: w.surah);

    // Completed ayah words are treated as green
    if ((status == null || status == 0) &&
        getCompletedAyahs(w.surah).contains(w.ayah)) {
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
  }) {
    if (page.isDisposed) return;
    final l = layout ?? page.currentLayout;
    if (l == null) return;

    // Upgraded: ayahMarksView() computes exact layout/viewport coordinates directly in Rust core
    final marks = page.ayahMarksView();
    if (marks.isEmpty) return;

    final Color greenBtnColor = app.colors.primary;

    final ringColor = neutralRingColor ??
        (app.isDarkMode
            ? const Color(0xFF94A3B8).withValues(alpha: 0.30)
            : const Color(0xFF64748B).withValues(alpha: 0.35));

    for (final m in marks) {
      final center = Offset(m.cx, m.cy);
      final double customR = m.r * 0.80;

      final bool isThisBuffering = controller != null &&
          controller.isAyahAudioBuffering(m.surah, m.ayah);
      final bool isThisPlaying = controller != null &&
          controller.isAyahAudioPlaying(m.surah, m.ayah);

      if (isThisBuffering) {
        _headerFillPaint.color = surfaceColor;
        canvas.drawCircle(center, customR - 0.5, _headerFillPaint);

        _ringPaint.color = greenBtnColor;
        _ringPaint.strokeWidth = 1.2;
        canvas.drawCircle(center, customR, _ringPaint);
        // The rotating arc for this mark is painted by the isolated spinner
        // layer (see _BufferingSpinnerPainter in mushaf_view.dart), not here.
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

    final double maxW = l.contentW > 0 ? l.contentW : size.width;

    // Badge geometry is cached per (page, yellowWords): the tooltip only
    // moves when the yellow set or the page changes — never per frame — so
    // a paint runs two list compares and performs zero layout allocation.
    if (!identical(page, _tooltipCachePage) ||
        !listEquals(yellowWords, _tooltipCacheWords)) {
      _tooltipCachePage = page;
      _tooltipCacheWords = yellowWords;
      _tooltipCacheBadges = _computeTooltipBadges(
        page,
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
  static List<int>? _tooltipCacheWords;
  static List<(double, double)>? _tooltipCacheBadges;

  /// Resolves badge positions for the current yellow words: one badge per
  /// ayah, placed beneath its first word's line, then spread apart so badges
  /// never overlap and stay inside the content bounds.
  static List<(double, double)> _computeTooltipBadges(
    QvpPage page,
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

    final wordBoxes = page.wordBoxesView();
    final badges = <(double, double)>[];
    for (final wordsOnLine in wordsByLine.values) {
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

class _PageWordLayoutCache {
  final Map<(int, int), List<QvpWordInfo>> wordsByAyah;
  final Map<(int, int), int> maxWordPerAyah;
  final Map<(int, int), Map<int, List<QvpWordInfo>>> wordsByAyahAndLine;

  _PageWordLayoutCache._({
    required this.wordsByAyah,
    required this.maxWordPerAyah,
    required this.wordsByAyahAndLine,
  });

  factory _PageWordLayoutCache.fromPage(QvpPage page) {
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

    final wordsByAyahAndLine = <(int, int), Map<int, List<QvpWordInfo>>>{};
    for (final entry in wordsByAyah.entries) {
      final ayahKey = entry.key;
      final byLine = <int, List<QvpWordInfo>>{};
      for (final w in entry.value) {
        (byLine[w.line] ??= []).add(w);
      }
      for (final lineWords in byLine.values) {
        lineWords.sort((w1, w2) => w1.word.compareTo(w2.word));
      }
      wordsByAyahAndLine[ayahKey] = byLine;
    }

    return _PageWordLayoutCache._(
      wordsByAyah: wordsByAyah,
      maxWordPerAyah: maxWordPerAyah,
      wordsByAyahAndLine: wordsByAyahAndLine,
    );
  }
}

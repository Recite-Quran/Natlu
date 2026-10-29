import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:qvp_flutter/qvp_flutter.dart';
import 'mushaf_provider.dart';

/// Compact, high-performance Ayah vector preview powered directly by [QvpPassage].
/// Supports word-level highlighting for matched search terms.
class MushafAyahPreview extends StatefulWidget {
  final int surah;
  final int ayah;
  final int? startAyah;
  final int? endAyah;
  final Color color;
  final double scale;
  final double lineSpacing;
  final int maxRows;
  final int? highlightStartWord;
  final int? highlightEndWord;
  final Color? highlightColor;

  const MushafAyahPreview({
    super.key,
    required this.surah,
    required this.ayah,
    this.startAyah,
    this.endAyah,
    required this.color,
    this.scale = 0.68,
    this.lineSpacing = 1.0,
    this.maxRows = 0,
    this.highlightStartWord,
    this.highlightEndWord,
    this.highlightColor,
  });

  @override
  State<MushafAyahPreview> createState() => _MushafAyahPreviewState();
}

class _MushafAyahPreviewState extends State<MushafAyahPreview> {
  QvpPassage? _passage;
  QvpPage? _page;
  int? _pageNum;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant MushafAyahPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.surah != oldWidget.surah || widget.ayah != oldWidget.ayah) {
      _passage?.dispose();
      _passage = null;
      _page = null;
      _pageNum = null;
      _load();
    }
  }

  @override
  void dispose() {
    _passage?.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final provider = MushafProvider.instance;
    final pageNum = provider.getPageForAyah(widget.surah, widget.ayah);
    if (pageNum == null) return;
    final page = await provider.getPage(pageNum);
    if (page == null || page.isDisposed || !mounted) return;

    try {
      final passage =
          QvpPassage.load([page], widget.surah, widget.ayah, to: widget.ayah);
      if (!mounted) {
        passage.dispose();
        return;
      }
      setState(() {
        _passage?.dispose();
        _passage = passage;
        _page = page;
        _pageNum = pageNum;
      });
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    if (_passage == null || _page == null || _pageNum == null) {
      return const SizedBox(height: 16);
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        if (w <= 0) return const SizedBox.shrink();

        // Scale adaptively based on word count so long Ayahs fit completely inside
        // without consuming excessive card height.
        final wordCount = _passage!.ayahs.isNotEmpty
            ? _passage!.ayahs.first.text.trim().split(RegExp(r'\s+')).length
            : 10;
        double effectiveScale = widget.scale;
        if (wordCount > 35) {
          effectiveScale = (widget.scale * 0.78).clamp(0.48, 0.70);
        } else if (wordCount > 20) {
          effectiveScale = (widget.scale * 0.88).clamp(0.55, 0.70);
        }

        final layout = _passage!.layout(QvpPassageSpec(
          width: w,
          scale: effectiveScale,
          lineSpacing: widget.lineSpacing,
          align: QvpPassageAlign.right,
          maxRows: widget.maxRows,
          keepAyahMark: false,
        ));

        if (layout == null || layout.draws.isEmpty) {
          return const SizedBox.shrink();
        }

        final highlightedWords = _computeHighlightedWords(_page!);

        return SizedBox(
          width: w,
          height: layout.height,
          child: CustomPaint(
            size: Size(w, layout.height),
            painter: _PassagePainter(
              layout: layout,
              page: _page!,
              pageNum: _pageNum!,
              color: widget.color,
              highlightedWords: highlightedWords,
              highlightColor: widget.highlightColor,
            ),
          ),
        );
      },
    );
  }

  Set<int> _computeHighlightedWords(QvpPage page) {
    if (widget.highlightColor == null) return const {};

    final rawEnd = widget.highlightEndWord ?? -1;
    if (rawEnd < 0) return const {};

    int effectiveStart = widget.highlightStartWord ?? 0;
    int effectiveEnd = rawEnd;

    // Cross-verse match handling:
    // If the match began in an earlier verse (e.g. wasl recitation or query had prefix words):
    if ((widget.startAyah != null && widget.startAyah! < widget.ayah) ||
        (effectiveStart > effectiveEnd && effectiveEnd >= 0)) {
      effectiveStart = 0;
    }

    final totalWords = page.words
        .where((w) => w.surah == widget.surah && w.ayah == widget.ayah)
        .length;
    if (totalWords <= 0) return const {};

    // If the match extends beyond this verse into subsequent verses:
    if (widget.endAyah != null && widget.endAyah! > widget.ayah) {
      effectiveEnd = totalWords - 1;
    }

    effectiveStart = effectiveStart.clamp(0, totalWords - 1);
    effectiveEnd = effectiveEnd.clamp(0, totalWords - 1);

    if (effectiveEnd >= effectiveStart) {
      return {for (int i = effectiveStart; i <= effectiveEnd; i++) i};
    }
    return const {};
  }
}

class _PassagePainter extends CustomPainter {
  final QvpPassageLayout layout;
  final QvpPage page;
  final int pageNum;
  final Color color;
  final Set<int> highlightedWords;
  final Color? highlightColor;

  _PassagePainter({
    required this.layout,
    required this.page,
    required this.pageNum,
    required this.color,
    required this.highlightedWords,
    this.highlightColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (page.isDisposed) return;

    final places = layout.placements;
    final s = layout.scale;
    final defaultPaint = Paint()
      ..color = color
      ..isAntiAlias = true;
    final activeHighlight = highlightColor;
    final highlightPaint = (activeHighlight != null)
        ? (Paint()
          ..color = activeHighlight
          ..isAntiAlias = true)
        : defaultPaint;

    var cur = -1, open = false;
    for (final d in layout.draws) {
      if (d.page != pageNum) continue;

      // Filter out ayah number and its marker ornament so only pure verse words render
      final kind = page.pathKind(d.path);
      if (kind == QvpKind.ayahNumber || kind == QvpKind.ayahMarkOrnament) {
        continue;
      }

      final path = page.path(d.path);
      if (d.placement != cur) {
        if (open) canvas.restore();
        canvas.save();
        final q = d.placement < places.length
            ? places[d.placement]
            : QvpPlacement.identity;
        canvas.translate(s * q.dx, s * q.dy);
        canvas.scale(s * q.kx, s * q.ky);
        open = true;
        cur = d.placement;
      }

      final wIdx = page.pathWord(d.path);
      final bool isHighlighted = wIdx >= 0 &&
          wIdx < page.words.length &&
          highlightedWords.contains(page.words[wIdx].word - 1);

      canvas.drawPath(path, isHighlighted ? highlightPaint : defaultPaint);
    }
    if (open) canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _PassagePainter old) =>
      old.layout != layout ||
      old.color != color ||
      old.highlightColor != highlightColor ||
      !setEquals(old.highlightedWords, highlightedWords);
}

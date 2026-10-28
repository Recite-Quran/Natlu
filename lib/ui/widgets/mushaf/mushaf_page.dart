import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' hide Page;
import 'package:flutter/services.dart';
import 'package:qvp_flutter/qvp_flutter.dart';
import 'package:recite_quran/recite_quran.dart';

import '../../../state/app_state.dart';
import 'mushaf_actions.dart';
import 'mushaf_provider.dart';

/// High-performance Mushaf vector page backed directly by [QvpPageView].
class MushafPageWidget extends StatefulWidget {
  final int pageNumber;
  final HighlightingController controller;
  final bool isRecording;
  final VoidCallback onStateChangeRequested;

  const MushafPageWidget({
    super.key,
    required this.pageNumber,
    required this.controller,
    required this.isRecording,
    required this.onStateChangeRequested,
  });

  @override
  State<MushafPageWidget> createState() => _MushafPageWidgetState();
}

class _MushafPageWidgetState extends State<MushafPageWidget>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  QvpPage? _page;
  bool _isLoading = true;

  // Native highlight handles (zero cache invalidation, drawn in GPU band batches)
  int _ayahHighlightHandle = 0;
  int _wordHighlightHandle = 0;
  int _recitationGreenHandle = 0;
  int _recitationYellowHandle = 0;
  int _recitationRedHandle = 0;

  (int, int)? _lastActiveAyah;
  int? _lastActiveWord;
  List<int> _lastGreenWords = const [];
  List<int> _lastYellowWords = const [];
  List<int> _lastRedWords = const [];
  List<int> _lastHiddenWords = const [];
  bool _hasMasks = false;

  @override
  void initState() {
    super.initState();
    _attachListeners();

    final cached = MushafProvider.instance.getCachedPage(widget.pageNumber);
    if (cached != null && !cached.isDisposed) {
      _page = cached;
      _isLoading = false;
      _syncVisuals();
    } else {
      _loadPage();
    }
  }

  Future<void> _loadPage() async {
    final page = await MushafProvider.instance.getPage(widget.pageNumber);
    if (!mounted) return;
    setState(() {
      _page = page;
      _isLoading = false;
    });
    if (page != null && !page.isDisposed) {
      _syncVisuals();
    }
  }

  @override
  void didUpdateWidget(MushafPageWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.pageNumber != widget.pageNumber || _page == null || _page!.isDisposed) {
      _lastActiveAyah = null;
      _lastActiveWord = null;
      _lastGreenWords = const [];
      _lastYellowWords = const [];
      _lastRedWords = const [];
      _lastHiddenWords = const [];
      _ayahHighlightHandle = 0;
      _wordHighlightHandle = 0;
      _recitationGreenHandle = 0;
      _recitationYellowHandle = 0;
      _recitationRedHandle = 0;
      _loadPage();
    }
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_syncVisuals);
      oldWidget.controller.activeAyah.removeListener(_syncVisuals);
      oldWidget.controller.globalRevision.removeListener(_syncVisuals);
      widget.controller.addListener(_syncVisuals);
      widget.controller.activeAyah.addListener(_syncVisuals);
      widget.controller.globalRevision.addListener(_syncVisuals);
    }
    _syncVisuals();
  }

  @override
  void dispose() {
    _detachListeners();
    final page = _page;
    if (page != null && !page.isDisposed) {
      page.clearHighlights();
      page.unmaskAll();
    }
    super.dispose();
  }

  void _attachListeners() {
    final app = AppState.instance;
    app.currentMushafPage.addListener(_syncVisuals);
    app.activeAudioWordIndex.addListener(_syncVisuals);
    app.activeAudioAyah.addListener(_syncVisuals);
    app.activeAudioSurah.addListener(_syncVisuals);
    app.isAudioPlaying.addListener(_syncVisuals);
    app.blurModeNotifier.addListener(_syncVisuals);
    widget.controller.addListener(_syncVisuals);
    widget.controller.activeAyah.addListener(_syncVisuals);
    widget.controller.globalRevision.addListener(_syncVisuals);
  }

  void _detachListeners() {
    final app = AppState.instance;
    app.currentMushafPage.removeListener(_syncVisuals);
    app.activeAudioWordIndex.removeListener(_syncVisuals);
    app.activeAudioAyah.removeListener(_syncVisuals);
    app.activeAudioSurah.removeListener(_syncVisuals);
    app.isAudioPlaying.removeListener(_syncVisuals);
    app.blurModeNotifier.removeListener(_syncVisuals);
    widget.controller.removeListener(_syncVisuals);
    widget.controller.activeAyah.removeListener(_syncVisuals);
    widget.controller.globalRevision.removeListener(_syncVisuals);
  }

  void _syncVisuals() {
    final page = _page;
    if (page == null || page.isDisposed || !mounted) return;

    final app = AppState.instance;
    final int currentPage = app.currentMushafPage.value;
    final bool isThisPage = (widget.pageNumber == currentPage);
    if (currentPage > 0 && (widget.pageNumber - currentPage).abs() > 1) return;

    final ctrl = widget.controller;
    final activeAyah = ctrl.activeAyah.value;
    final targetSurah = ctrl.targetSurah != 0 ? ctrl.targetSurah : app.lastSurah;
    final activeMatch = ctrl.currentMatchedVerse;

    final audioSurah = app.activeAudioSurah.value;
    final audioAyah = app.activeAudioAyah.value;
    final audioWordIdx = app.activeAudioWordIndex.value;
    final bool isAudioActive = (app.isAudioPlaying.value || app.isAudioBuffering.value) &&
        audioSurah != null &&
        audioAyah != null &&
        audioWordIdx != null;

    final provider = MushafProvider.instance;

    final bool hasRecitingAyah = activeAyah != null &&
        provider.isAyahOnPage(pageNumber: widget.pageNumber, surah: targetSurah, ayah: activeAyah);
    final bool hasMatchedAyah = activeMatch != null &&
        provider.isAyahOnPage(pageNumber: widget.pageNumber, surah: activeMatch.verse.surah, ayah: activeMatch.verse.ayah);
    final bool hasAudioAyah = isAudioActive &&
        provider.isAyahOnPage(pageNumber: widget.pageNumber, surah: audioSurah, ayah: audioAyah);

    // If no active element is on this page and this is not the current page, clear and bail out
    if (!hasRecitingAyah && !hasMatchedAyah && !hasAudioAyah && !isThisPage) {
      if (_ayahHighlightHandle != 0 || _wordHighlightHandle != 0) {
        page.batch(() {
          if (_ayahHighlightHandle != 0) {
            page.removeHighlight(_ayahHighlightHandle);
            _ayahHighlightHandle = 0;
          }
          if (_wordHighlightHandle != 0) {
            page.removeHighlight(_wordHighlightHandle);
            _wordHighlightHandle = 0;
          }
          _lastActiveAyah = null;
          _lastActiveWord = null;
        });
      }
      return;
    }

    page.batch(() {
      final c = app.colors;
      final isDark = app.isDarkMode;

      // 1. ACTIVE AYAH HIGHLIGHT
      (int, int)? targetAyah;
      if (hasMatchedAyah) {
        targetAyah = (activeMatch.verse.surah, activeMatch.verse.ayah);
      } else if (hasRecitingAyah) {
        targetAyah = (targetSurah, activeAyah);
      } else if (hasAudioAyah) {
        targetAyah = (audioSurah, audioAyah);
      }

      if (targetAyah != _lastActiveAyah) {
        _lastActiveAyah = targetAyah;
        if (targetAyah != null) {
          final Color ayahColor = isDark
              ? Colors.white.withValues(alpha: 0.10)
              : const Color(0xFF64748B).withValues(alpha: 0.09);
          final style = QvpHighlightStyle(
            mode: 'band',
            height: 'lineSpacing',
            band: ayahColor,
            padX: 1.2,
            radius: 4.0,
            layer: QvpLayer.highlight - 2,
          );
          if (_ayahHighlightHandle != 0) {
            page.moveHighlight(_ayahHighlightHandle, T.ayah(targetAyah.$1, targetAyah.$2));
            page.restyleHighlight(_ayahHighlightHandle, style);
          } else {
            _ayahHighlightHandle = page.highlight(
              T.ayah(targetAyah.$1, targetAyah.$2),
              style,
            );
          }
        } else if (_ayahHighlightHandle != 0) {
          page.removeHighlight(_ayahHighlightHandle);
          _ayahHighlightHandle = 0;
        }
      }

      // 2. ACTIVE WORD HIGHLIGHT (Audio Word or Reciting Word cursor)
      int? activeWord;
      if (hasAudioAyah) {
        final idx = page.findWord(audioSurah, audioAyah, audioWordIdx + 1);
        if (idx >= 0) activeWord = idx;
      } else if (widget.isRecording && (hasMatchedAyah || hasRecitingAyah)) {
        final int s = activeMatch?.verse.surah ?? targetSurah;
        final int a = activeMatch?.verse.ayah ?? activeAyah!;
        for (final w in page.words) {
          if (w.surah == s && w.ayah == a) {
            final w0 = w.word - 1;
            if (!ctrl.isWordGreen(w.ayah, w0, surah: w.surah) &&
                !ctrl.isWordRed(w.ayah, w0, surah: w.surah) &&
                !ctrl.isWordYellow(w.ayah, w0, surah: w.surah) &&
                !ctrl.isWordNeutral(w.ayah, w0, surah: w.surah)) {
              activeWord = w.index;
              break;
            }
          }
        }
      }

      if (activeWord != _lastActiveWord) {
        _lastActiveWord = activeWord;
        if (activeWord != null) {
          final Color wordColor = c.wordHighlight.withValues(alpha: isDark ? 0.32 : 0.22);
          final style = QvpHighlightStyle(
            mode: 'band',
            height: 'lineSpacing',
            band: wordColor,
            padX: 2.0,
            radius: 4.0,
            ms: isAudioActive ? 180 : 0,
            layer: QvpLayer.highlight - 1,
          );
          if (_wordHighlightHandle != 0) {
            page.moveHighlight(_wordHighlightHandle, T.word(activeWord));
            page.restyleHighlight(_wordHighlightHandle, style);
          } else {
            _wordHighlightHandle = page.highlight(
              T.word(activeWord),
              style,
            );
          }
        } else if (_wordHighlightHandle != 0) {
          page.removeHighlight(_wordHighlightHandle);
          _wordHighlightHandle = 0;
        }
      }

      // 3. RECITATION FEEDBACK (TEXT INK + BACKGROUND BANDS) & HIFZ CONCEALING
      final green = <int>[];
      final yellow = <int>[];
      final red = <int>[];
      final hidden = <int>[];

      for (final w in page.words) {
        final w0 = w.word - 1;
        final color = MushafActions.resolveWordDisplayColor(
          ayah: w.ayah,
          wordIndex: w0,
          controller: ctrl,
          app: app,
          colors: c,
          surah: w.surah,
        );
        if (color == Colors.transparent) {
          hidden.add(w.index);
        } else if (color == c.green) {
          green.add(w.index);
        } else if (color == c.warning) {
          yellow.add(w.index);
        } else if (color == c.red) {
          red.add(w.index);
        }
      }

      if (!listEquals(green, _lastGreenWords)) {
        _lastGreenWords = green;
        _updateHighlightGroup(
          page,
          green,
          ref: _recitationGreenHandle,
          inkColor: c.green,
          bandColor: c.green.withValues(alpha: isDark ? 0.22 : 0.14),
          onHandleChanged: (h) => _recitationGreenHandle = h,
        );
      }

      if (!listEquals(yellow, _lastYellowWords)) {
        _lastYellowWords = yellow;
        _updateHighlightGroup(
          page,
          yellow,
          ref: _recitationYellowHandle,
          inkColor: c.warning,
          bandColor: c.warning.withValues(alpha: isDark ? 0.25 : 0.16),
          onHandleChanged: (h) => _recitationYellowHandle = h,
        );
      }

      if (!listEquals(red, _lastRedWords)) {
        _lastRedWords = red;
        _updateHighlightGroup(
          page,
          red,
          ref: _recitationRedHandle,
          inkColor: c.red,
          bandColor: c.red.withValues(alpha: isDark ? 0.25 : 0.16),
          onHandleChanged: (h) => _recitationRedHandle = h,
        );
      }

      if (!listEquals(hidden, _lastHiddenWords)) {
        _lastHiddenWords = hidden;
        if (hidden.isNotEmpty) {
          page.mask(T.words(hidden), 'hide');
          _hasMasks = true;
        } else if (_hasMasks) {
          page.unmaskAll();
          _hasMasks = false;
        }
      }
    });
  }

  void _updateHighlightGroup(
    QvpPage page,
    List<int> words, {
    required int ref,
    required Color inkColor,
    required Color bandColor,
    required ValueChanged<int> onHandleChanged,
  }) {
    if (words.isNotEmpty) {
      final style = QvpHighlightStyle(
        mode: 'both',
        ink: inkColor,
        band: bandColor,
        radius: 4.0,
        padX: 1.0,
        layer: QvpLayer.highlight,
      );
      if (ref != 0) {
        page.moveHighlight(ref, T.words(words));
        page.restyleHighlight(ref, style);
      } else {
        final h = page.highlight(
          T.words(words),
          style,
        );
        onHandleChanged(h);
      }
    } else if (ref != 0) {
      page.removeHighlight(ref);
      onHandleChanged(0);
    }
  }

  void _onWordTap(BuildContext context, QvpPage page, int wordIndex) {
    if (wordIndex < 0 || wordIndex >= page.words.length) return;
    final w = page.words[wordIndex];
    final surah = w.surah;
    final ayah = w.ayah;
    final wordIndex0 = w.word - 1;

    if (widget.controller.isWordYellow(ayah, wordIndex0, surah: surah)) {
      MushafActions.handleWordTap(
        context: context,
        surah: surah,
        ayah: ayah,
        wordIndex: wordIndex0,
        wordText: w.text,
        controller: widget.controller,
        onAyahTap: widget.onStateChangeRequested,
        playWordDirectly: false,
      );
      return;
    }

    final activeAyah = widget.controller.activeAyah.value;
    final activeSurah = widget.controller.targetSurah != 0
        ? widget.controller.targetSurah
        : AppState.instance.lastSurah;
    final isAlreadyActive = (activeSurah == surah && activeAyah == ayah);

    if (isAlreadyActive) {
      MushafActions.handleWordTap(
        context: context,
        surah: surah,
        ayah: ayah,
        wordIndex: wordIndex0,
        wordText: w.text,
        controller: widget.controller,
        onAyahTap: widget.onStateChangeRequested,
        playWordDirectly: true,
      );
    } else {
      HapticFeedback.lightImpact();
      MushafActions.selectAyah(
        surah: surah,
        ayah: ayah,
        controller: widget.controller,
        onTap: widget.onStateChangeRequested,
      );
    }
  }

  void _onDecorationTap(QvpDecorationInfo dec) {
    if (dec.surah > 0 && dec.ayah > 0) {
      HapticFeedback.selectionClick();
      AppState.instance.markMushafAudioAyahClicked();
      MushafActions.toggleAyahAudio(
        surah: dec.surah,
        ayah: dec.ayah,
        controller: widget.controller,
        isRecording: widget.isRecording,
        onTap: widget.onStateChangeRequested,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final c = AppState.instance.colors;

    if (_isLoading || _page == null || _page!.isDisposed) {
      if (!_isLoading) _loadPage();
      return ColoredBox(
        color: c.surface,
        child: const SizedBox.expand(),
      );
    }

    final page = _page!;
    return Directionality(
      textDirection: TextDirection.rtl,
      child: QvpPageView(
        key: ValueKey('qvp_page_view_${widget.pageNumber}'),
        page: page,
        panZoomEnabled: false,
        selectionEnabled: false,
        layout: const QvpViewLayout(
          padTop: 0,
          padBottom: 0,
          padSide: 4,
          lineSpacing: 1.0,
          fillHeight: true,
          surahFrames: true,
        ),
        paper: null,
        paperShadow: false,
        defaultInk: c.text,
        onWordTap: (wordIndex, _) => _onWordTap(context, page, wordIndex),
        onDecorationTap: _onDecorationTap,
      ),
    );
  }
}

/// Backward compatibility alias
typedef PageWidget = MushafPageWidget;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' hide Page;
import 'package:qvp_flutter/qvp_flutter.dart';
import 'package:recite_quran/recite_quran.dart';

import '../../../services/app_haptics.dart';
import '../../../state/app_state.dart';
import '../../../maglis/maglis_controller.dart';
import 'mushaf_actions.dart';
import 'mushaf_overlays.dart';
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
    with AutomaticKeepAliveClientMixin, TickerProviderStateMixin {
  @override
  bool get wantKeepAlive => false;

  QvpPage? _page;
  bool _isLoading = true;
  late final AnimationController _spinnerController;

  // Native highlight handles (zero cache invalidation, drawn in GPU band batches)
  int _ayahHighlightHandle = 0;
  int _wordHighlightHandle = 0;
  int _recitationGreenHandle = 0;
  int _recitationYellowHandle = 0;
  int _recitationRedHandle = 0;

  (int, int)? _lastActiveAyah;
  int? _lastActiveWord;
  bool? _lastIsDark;
  List<int> _lastGreenWords = const [];
  List<int> _lastYellowWords = const [];
  List<int> _lastRedWords = const [];
  List<int> _lastHiddenWords = const [];
  bool _hasMasks = false;

  @override
  void initState() {
    super.initState();
    _spinnerController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    );
    _attachListeners();

    final cached = MushafProvider.instance.getCachedPage(widget.pageNumber);
    if (cached != null && !cached.isDisposed) {
      _page = cached;
      _isLoading = false;
      _checkSpinnerAnimation();
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
      _checkSpinnerAnimation();
      _syncVisuals();
    }
  }

  @override
  void didUpdateWidget(MushafPageWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.pageNumber != widget.pageNumber || _page == null || _page!.isDisposed) {
      _lastActiveAyah = null;
      _lastActiveWord = null;
      _lastIsDark = null;
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
    _checkSpinnerAnimation();
    _syncVisuals();
  }

  @override
  void dispose() {
    _detachListeners();
    _spinnerController.dispose();
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
    app.activeAudioAyah.addListener(_onAudioStateChanged);
    app.activeAudioSurah.addListener(_onAudioStateChanged);
    app.isAudioPlaying.addListener(_onAudioStateChanged);
    app.isAudioBuffering.addListener(_onAudioStateChanged);
    app.blurModeNotifier.addListener(_syncVisuals);
    app.themeNotifier.addListener(_syncVisuals);
    widget.controller.addListener(_syncVisuals);
    widget.controller.activeAyah.addListener(_syncVisuals);
    widget.controller.globalRevision.addListener(_syncVisuals);
    MaglisController.instance.addListener(_syncVisuals);
  }

  void _detachListeners() {
    final app = AppState.instance;
    app.currentMushafPage.removeListener(_syncVisuals);
    app.activeAudioWordIndex.removeListener(_syncVisuals);
    app.activeAudioAyah.removeListener(_onAudioStateChanged);
    app.activeAudioSurah.removeListener(_onAudioStateChanged);
    app.isAudioPlaying.removeListener(_onAudioStateChanged);
    app.isAudioBuffering.removeListener(_onAudioStateChanged);
    app.blurModeNotifier.removeListener(_syncVisuals);
    app.themeNotifier.removeListener(_syncVisuals);
    widget.controller.removeListener(_syncVisuals);
    widget.controller.activeAyah.removeListener(_syncVisuals);
    widget.controller.globalRevision.removeListener(_syncVisuals);
    MaglisController.instance.removeListener(_syncVisuals);
  }

  void _onAudioStateChanged() {
    _checkSpinnerAnimation();
    _syncVisuals();
  }

  void _checkSpinnerAnimation() {
    if (!mounted) return;
    final app = AppState.instance;
    final bool isBuffering = app.isAudioBuffering.value;
    final surah = app.activeAudioSurah.value;
    final ayah = app.activeAudioAyah.value;
    final page = _page;
    final bool isBufferingOnThisPage = isBuffering &&
        surah != null &&
        ayah != null &&
        page != null &&
        !page.isDisposed &&
        MushafProvider.instance.isAyahOnPage(
          pageNumber: widget.pageNumber,
          surah: surah,
          ayah: ayah,
        );

    if (isBufferingOnThisPage) {
      if (!_spinnerController.isAnimating) {
        _spinnerController.repeat();
      }
    } else {
      if (_spinnerController.isAnimating) {
        _spinnerController.stop();
      }
    }
  }

  void _syncVisuals() {
    final page = _page;
    if (page == null || page.isDisposed || !mounted) return;

    final app = AppState.instance;
    final int currentPage = app.currentMushafPage.value;
    if (currentPage > 0 && (widget.pageNumber - currentPage).abs() > 1) return;

    final ctrl = widget.controller;
    final activeAyah = ctrl.activeAyah.value;
    final targetSurah = ctrl.targetSurah != 0 ? ctrl.targetSurah : app.lastSurah;
    final activeMatch = ctrl.currentMatchedVerse;

    final audioSurah = app.activeAudioSurah.value;
    final audioAyah = app.activeAudioAyah.value;
    final audioWordIdx = app.activeAudioWordIndex.value;
    final bool isAudioActive = audioSurah != null &&
        audioAyah != null &&
        audioWordIdx != null;

    final provider = MushafProvider.instance;

    final maglis = MaglisController.instance;
    final bool isMaglisRemote = maglis.isRemoteReciting;
    final int maglisSurah = maglis.remoteSurah;
    final int maglisAyah = maglis.remoteAyah;
    final int? maglisWord = maglis.remoteWord;
    final bool hasMaglisAyah = isMaglisRemote &&
        provider.isAyahOnPage(pageNumber: widget.pageNumber, surah: maglisSurah, ayah: maglisAyah);

    final bool hasRecitingAyah = activeAyah != null &&
        provider.isAyahOnPage(pageNumber: widget.pageNumber, surah: targetSurah, ayah: activeAyah);
    final bool hasMatchedAyah = activeMatch != null &&
        provider.isAyahOnPage(pageNumber: widget.pageNumber, surah: activeMatch.verse.surah, ayah: activeMatch.verse.ayah);
    final bool hasAudioAyah = isAudioActive &&
        provider.isAyahOnPage(pageNumber: widget.pageNumber, surah: audioSurah, ayah: audioAyah);

    page.batch(() {
      final c = app.colors;
      final isDark = app.isDarkMode;
      final bool themeChanged = (_lastIsDark != isDark);

      // 1. ACTIVE AYAH HIGHLIGHT
      (int, int)? targetAyah;
      if (isMaglisRemote && hasMaglisAyah) {
        targetAyah = (maglisSurah, maglisAyah);
      } else if (hasMatchedAyah) {
        targetAyah = (activeMatch.verse.surah, activeMatch.verse.ayah);
      } else if (hasRecitingAyah) {
        targetAyah = (targetSurah, activeAyah);
      } else if (hasAudioAyah) {
        targetAyah = (audioSurah, audioAyah);
      }

      if (targetAyah != _lastActiveAyah || themeChanged) {
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
            ms: 0,
            layer: QvpLayer.highlight - 2,
          );
          if (_ayahHighlightHandle != 0) {
            page.removeHighlight(_ayahHighlightHandle);
            _ayahHighlightHandle = 0;
          }
          _ayahHighlightHandle = page.highlight(
            T.ayah(targetAyah.$1, targetAyah.$2),
            style,
          );
        } else if (_ayahHighlightHandle != 0) {
          page.removeHighlight(_ayahHighlightHandle);
          _ayahHighlightHandle = 0;
        }
      }

      // 2. ACTIVE WORD HIGHLIGHT (Audio Word, Reciting Word cursor, or Remote Maglis cursor)
      int? activeWord;
      if (isMaglisRemote && hasMaglisAyah && maglisWord != null) {
        final idx = page.findWord(maglisSurah, maglisAyah, maglisWord + 1);
        if (idx >= 0) activeWord = idx;
      } else if (hasAudioAyah) {
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

      if (activeWord != _lastActiveWord || themeChanged) {
        _lastActiveWord = activeWord;
        if (activeWord != null) {
          final Color wordColor = c.wordHighlight.withValues(alpha: isDark ? 0.35 : 0.25);

          final style = QvpHighlightStyle(
            mode: 'band',
            height: 'lineSpacing',
            band: wordColor,
            padX: 1.0,
            radius: 4.0,
            ms: 0,
            layer: QvpLayer.highlight - 1,
          );

          if (_wordHighlightHandle != 0) {
            page.restyleHighlight(_wordHighlightHandle, style);
            page.moveHighlight(_wordHighlightHandle, T.word(activeWord));
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

      // 3. RECITATION FEEDBACK (TEXT INK ONLY) & HIFZ CONCEALING
      final bool needsWordEvaluation = widget.isRecording ||
          isMaglisRemote ||
          app.isBlurMode ||
          _lastGreenWords.isNotEmpty ||
          _lastYellowWords.isNotEmpty ||
          _lastRedWords.isNotEmpty ||
          _lastHiddenWords.isNotEmpty;

      if (needsWordEvaluation) {
        final green = <int>[];
        final yellow = <int>[];
        final red = <int>[];
        final hidden = <int>[];

        for (final w in page.words) {
          final w0 = w.word - 1;
          Color color;
          final int? maglisColor =
              MaglisController.instance.getWordHighlight(w.surah, w.ayah, w0);
          if (maglisColor != null) {
            if (maglisColor == 1) {
              color = c.green;
            } else if (maglisColor == 2) {
              color = c.warning;
            } else if (maglisColor == 3) {
              color = c.red;
            } else {
              color = c.text;
            }
          } else if (isMaglisRemote &&
              w.surah == maglisSurah &&
              w.ayah == maglisAyah) {
            if (maglis.remoteGreenWords.contains(w0)) {
              color = c.green;
            } else if (maglis.remoteYellowWords.contains(w0)) {
              color = c.warning;
            } else if (maglis.remoteRedWords.contains(w0)) {
              color = c.red;
            } else {
              color = c.text;
            }
          } else {
            color = MushafActions.resolveWordDisplayColor(
              ayah: w.ayah,
              wordIndex: w0,
              controller: ctrl,
              app: app,
              colors: c,
              surah: w.surah,
            );
          }
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

        if (!listEquals(green, _lastGreenWords) || themeChanged) {
          _lastGreenWords = green;
          _updateHighlightGroup(
            page,
            green,
            ref: _recitationGreenHandle,
            inkColor: c.green,
            onHandleChanged: (h) => _recitationGreenHandle = h,
          );
        }

        if (!listEquals(yellow, _lastYellowWords) || themeChanged) {
          _lastYellowWords = yellow;
          _updateHighlightGroup(
            page,
            yellow,
            ref: _recitationYellowHandle,
            inkColor: c.warning,
            onHandleChanged: (h) => _recitationYellowHandle = h,
          );
        }

        if (!listEquals(red, _lastRedWords) || themeChanged) {
          _lastRedWords = red;
          _updateHighlightGroup(
            page,
            red,
            ref: _recitationRedHandle,
            inkColor: c.red,
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
      }

      _lastIsDark = isDark;
    });
  }

  void _updateHighlightGroup(
    QvpPage page,
    List<int> words, {
    required int ref,
    required Color inkColor,
    required ValueChanged<int> onHandleChanged,
  }) {
    if (words.isNotEmpty) {
      final style = QvpHighlightStyle(
        mode: 'ink',
        ink: inkColor,
        ms: 0,
        layer: QvpLayer.highlight,
      );
      if (ref != 0) {
        page.removeHighlight(ref);
      }
      final h = page.highlight(
        T.words(words),
        style,
      );
      onHandleChanged(h);
    } else if (ref != 0) {
      page.removeHighlight(ref);
      onHandleChanged(0);
    }
  }

  void _onWordTap(BuildContext context, QvpPage page, int wordIndex) {
    if (wordIndex < 0 || wordIndex >= page.words.length) return;
    int effectiveIndex = wordIndex;
    var w = page.words[effectiveIndex];
    var surah = w.surah;
    var ayah = w.ayah;
    var wordIndex0 = w.word - 1;

    // Smart yellow word magnetism:
    // If the hit word is not yellow, check if an immediately adjacent neighbor on the same line is yellow.
    // Small Arabic words often result in touch points landing on the neighboring word or gap.
    if (!widget.controller.isWordYellow(ayah, wordIndex0, surah: surah)) {
      if (effectiveIndex > 0 &&
          page.words[effectiveIndex - 1].line == w.line &&
          widget.controller.isWordYellow(
            page.words[effectiveIndex - 1].ayah,
            page.words[effectiveIndex - 1].word - 1,
            surah: page.words[effectiveIndex - 1].surah,
          )) {
        effectiveIndex = effectiveIndex - 1;
        w = page.words[effectiveIndex];
        surah = w.surah;
        ayah = w.ayah;
        wordIndex0 = w.word - 1;
      } else if (effectiveIndex + 1 < page.words.length &&
          page.words[effectiveIndex + 1].line == w.line &&
          widget.controller.isWordYellow(
            page.words[effectiveIndex + 1].ayah,
            page.words[effectiveIndex + 1].word - 1,
            surah: page.words[effectiveIndex + 1].surah,
          )) {
        effectiveIndex = effectiveIndex + 1;
        w = page.words[effectiveIndex];
        surah = w.surah;
        ayah = w.ayah;
        wordIndex0 = w.word - 1;
      }
    }

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
      AppHaptics.lightImpact();
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
      AppHaptics.selectionClick();
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
    final app = AppState.instance;
    final isDark = app.isDarkMode;
    final neutralRingColor = isDark
        ? Colors.white.withValues(alpha: 0.25)
        : const Color(0xFF64748B).withValues(alpha: 0.35);

    return Directionality(
      textDirection: TextDirection.rtl,
      child: Stack(
        fit: StackFit.expand,
        children: [
          IgnorePointer(
            child: CustomPaint(
              painter: SurahHeaderPainter(
                page: page,
                isDark: isDark,
                colors: c,
              ),
            ),
          ),
          QvpPageView(
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
              surahFrames: false,
            ),
            hitMaxDistance: 28.0,
            paper: null,
            paperShadow: false,
            defaultInk: c.text,
            onWordTap: (wordIndex, _) => _onWordTap(context, page, wordIndex),
            onDecorationTap: _onDecorationTap,
          ),
          IgnorePointer(
            child: RepaintBoundary(
              child: CustomPaint(
                painter: AyahMarkPainter(
                  page: page,
                  app: app,
                  spinnerAnimation: _spinnerController,
                  surfaceColor: c.surface,
                  goldColor: c.gold,
                  neutralRingColor: neutralRingColor,
                  ayahHighlightColor: isDark
                      ? Colors.white.withValues(alpha: 0.10)
                      : const Color(0xFF64748B).withValues(alpha: 0.09),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Backward compatibility alias
typedef PageWidget = MushafPageWidget;

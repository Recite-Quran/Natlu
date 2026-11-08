import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' hide Page;
import 'package:flutter/scheduler.dart';
import 'package:qvp_flutter/qvp_flutter.dart';
import '../core/platform_utils.dart';
import '../core/app_state.dart';
import '../core/highlighting_controller.dart';
import '../maglis/maglis_controller.dart';
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
    with TickerProviderStateMixin, AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive {
    final curr = AppState.instance.currentMushafPage.value;
    if (curr <= 0) return true;
    return (widget.pageNumber - curr).abs() <= 1;
  }
  QvpPage? _page;
  bool _isLoading = true;
  bool _hasError = false;
  late final AnimationController _spinnerController;
  late final Listenable _ayahMarkRepaintListenable;
  late final Listenable _tajweedVisibilityListenable;
  final ValueNotifier<List<int>> _yellowWordsNotifier =
      ValueNotifier<List<int>>(const []);

  // Native highlight handles (zero cache invalidation, drawn in GPU band batches)
  int _ayahHighlightHandle = 0;
  int _wordHighlightHandle = 0;
  // Recitation handles diff cache: key = startWordIndex, value = (state, lastWordIndex, handle)
  Map<int, ({int state, int lastWord, int handle})> _activeRunHandles = {};

  (int, int)? _lastActiveAyah;
  int? _lastActiveWord;
  bool? _lastIsDark;
  List<int> _lastGreenWords = const [];
  List<int> _lastYellowWords = const [];
  List<int> _lastRedWords = const [];
  List<int> _lastHiddenWords = const [];
  bool _hasMasks = false;
  bool _hasEvaluatedWords = false;
  bool? _lastBlurEffective;
  bool? _lastIsRecording;
  bool? _hasSurahHeaders;

  Map<int, int> _pageWordMap = {};
  final Map<int, List<QvpWordInfo>> _pageAyahWords = {};
  final Map<int, List<int>> _cachedCompletedGreenWords = {};
  final Map<int, List<int>> _cachedCompletedYellowWords = {};
  final Map<int, List<int>> _cachedCompletedRedWords = {};
  final Map<int, List<int>> _cachedCompletedHiddenWords = {};

  void _clearCompletedAyahCache() {
    _cachedCompletedGreenWords.clear();
    _cachedCompletedYellowWords.clear();
    _cachedCompletedRedWords.clear();
    _cachedCompletedHiddenWords.clear();
    _lastVisualFingerprint = -1;
    _lastSyncRevision = -1;
  }

  int _lastIndexedPage = -1;
  bool _reloadScheduled = false;

  void _ensurePageWordsIndexed(QvpPage page) {
    if (_lastIndexedPage == widget.pageNumber && _pageWordMap.isNotEmpty) {
      return;
    }
    final map = <int, int>{};
    for (final w in page.words) {
      map[MaglisController.wordKey(w.surah, w.ayah, w.word - 1)] = w.index;
    }
    _pageWordMap = map;
    _lastIndexedPage = widget.pageNumber;
  }

  void _ensurePageAyahsGrouped(QvpPage page) {
    if (_lastIndexedPage == widget.pageNumber && _pageAyahWords.isNotEmpty) {
      return;
    }
    _pageAyahWords.clear();
    for (final w in page.words) {
      final key = (w.surah << 16) | w.ayah;
      (_pageAyahWords[key] ??= []).add(w);
    }
  }

  @override
  void initState() {
    super.initState();
    final app = AppState.instance;
    _spinnerController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    );
    _ayahMarkRepaintListenable = Listenable.merge([
      _spinnerController,
      app.activeAudioAyah,
      app.activeAudioSurah,
      app.isAudioBuffering,
      app.isAudioPlaying,
      widget.controller.activeAyah,
    ]);
    _tajweedVisibilityListenable = Listenable.merge([
      app.modeNotifier,
      app.hasClickedTajweedNotifier,
    ]);
    _attachListeners();

    final cached = MushafProvider.instance.getCachedPage(widget.pageNumber);
    if (cached != null && !cached.isDisposed) {
      _page = cached;
      _isLoading = false;
      _checkSpinnerAnimation();
      _requestSyncVisuals();
    } else {
      _loadPage();
    }
  }

  Future<void> _loadPage() async {
    _isLoading = true;
    _hasError = false;
    _reloadScheduled = false;
    final page = await MushafProvider.instance.getPage(widget.pageNumber);
    if (!mounted) return;
    setState(() {
      _page = page;
      _isLoading = false;
      _hasError = (page == null);
    });
    if (page != null && !page.isDisposed) {
      _hasSurahHeaders = page.surahHeaders().isNotEmpty;
      _checkSpinnerAnimation();
      _requestSyncVisuals();
    }
  }

  void _onModalStateChanged() {
    if (!mounted) return;
    if (!AppModalRouteObserver.instance.isModalOpen && _needsSyncAfterModal) {
      _needsSyncAfterModal = false;
      _requestSyncVisuals();
    }
  }

  void _onPageScrollingChanged() {
    if (!MushafProvider.instance.isPageScrolling.value &&
        _needsSyncAfterScroll &&
        mounted) {
      _needsSyncAfterScroll = false;
      _requestSyncVisuals();
    }
  }

  @override
  void didUpdateWidget(MushafPageWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.pageNumber != widget.pageNumber ||
        _page == null ||
        _page!.isDisposed) {
      _lastActiveAyah = null;
      _lastActiveWord = null;
      _lastIsDark = null;
      _lastIndexedPage = -1;
      _hasEvaluatedWords = false;
      _lastBlurEffective = null;
      _lastIsRecording = null;
      _hasSurahHeaders = null;
      _pageWordMap.clear();
      _pageAyahWords.clear();
      _clearCompletedAyahCache();
      _lastGreenWords = const [];
      _lastYellowWords = const [];
      _yellowWordsNotifier.value = const [];
      _lastRedWords = const [];
      _lastHiddenWords = const [];
      _ayahHighlightHandle = 0;
      _wordHighlightHandle = 0;
      _activeRunHandles.clear();
      _lastVisualFingerprint = -1;
      final cached = MushafProvider.instance.getCachedPage(widget.pageNumber);
      if (cached != null && !cached.isDisposed) {
        _page = cached;
        _isLoading = false;
        _hasError = false;
        _syncVisuals();
      } else {
        _hasError = false;
        _loadPage();
      }
    }
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_requestSyncVisuals);
      widget.controller.addListener(_requestSyncVisuals);
      _clearCompletedAyahCache();
      _lastSyncRevision = -1;
      _ayahMarkRepaintListenable = Listenable.merge([
        _spinnerController,
        AppState.instance.activeAudioAyah,
        AppState.instance.activeAudioSurah,
        AppState.instance.isAudioBuffering,
        AppState.instance.isAudioPlaying,
        widget.controller.activeAyah,
      ]);
    }
    _checkSpinnerAnimation();
    _syncVisuals();
  }

  @override
  void dispose() {
    _detachListeners();
    _spinnerController.dispose();
    _yellowWordsNotifier.dispose();
    _clearCompletedAyahCache();
    _pageAyahWords.clear();
    final page = _page;
    if (page != null && !page.isDisposed) {
      page.clearHighlights();
      page.unmaskAll();
    }
    _activeRunHandles.clear();
    super.dispose();
  }

  bool _syncScheduled = false;
  bool _needsSyncAfterModal = false;
  bool _needsSyncAfterScroll = false;
  int _lastVisualFingerprint = -1;
  int _lastSyncRevision = -1;
  int? _lastSyncActiveAyah;
  int? _lastSyncActiveWord;
  int _lastSyncTargetSurah = -1;
  bool _lastSyncDarkMode = false;
  bool _lastSyncBlur = false;
  bool _lastSyncRecording = false;

  final List<int> _evalGreen = [];
  final List<int> _evalYellow = [];
  final List<int> _evalRed = [];
  final List<int> _evalHidden = [];

  int _computeVisualFingerprint() {
    final app = AppState.instance;
    final ctrl = widget.controller;

    int hash = widget.pageNumber;
    hash = 31 * hash + (app.isDarkMode ? 1 : 0);
    hash = 31 * hash +
        (app.isBlurEffective(isRecording: widget.isRecording) ? 1 : 0);
    hash = 31 * hash + (widget.isRecording ? 1 : 0);

    final bool isRemote = ctrl.isRemoteReciting ||
        (MaglisController.instance.inSession &&
            !widget.isRecording &&
            MaglisController.instance.isRemoteReciting);
    hash = 31 * hash + (isRemote ? 1 : 0);

    final int targetSurah =
        ctrl.targetSurah != 0 ? ctrl.targetSurah : app.lastSurah;
    hash = 31 * hash + targetSurah;

    final int? activeAyah = ctrl.activeAyah.value;
    hash = 31 * hash + (activeAyah ?? 0);

    final activeMatch = ctrl.currentMatchedVerse;
    if (activeMatch != null) {
      hash = 31 * hash + activeMatch.verse.surah;
      hash = 31 * hash + activeMatch.verse.ayah;
    }

    final bool isAudioActive = ctrl.isAudioActive;
    if (isAudioActive) {
      hash = 31 * hash + (ctrl.audioSurah ?? 0);
      hash = 31 * hash + (ctrl.audioAyah ?? 0);
      hash = 31 * hash + (ctrl.audioWordIndex ?? -1);
      hash = 31 * hash + (ctrl.isAudioPlaying ? 1 : 0);
      hash = 31 * hash + (ctrl.isAudioBuffering ? 1 : 0);
    }

    final int s = activeMatch?.verse.surah ?? targetSurah;
    final int a = activeMatch?.verse.ayah ?? (activeAyah ?? 0);
    final bool isReciting = widget.isRecording || isRemote;

    if (ctrl.activeWordIndex != null) {
      hash = 31 * hash + ctrl.activeWordIndex!;
    }

    // Word coloring status for the active reciting ayah on this page:
    final page = _page;
    if (isReciting && page != null && !page.isDisposed && a > 0) {
      _ensurePageAyahsGrouped(page);
      final ayahWords = _pageAyahWords[(s << 16) | a];
      if (ayahWords != null && ayahWords.isNotEmpty) {
        int wordHash = 17;
        for (final w in ayahWords) {
          final w0 = w.word - 1;
          final state = ctrl.getWordStatus(w.ayah, w0, surah: w.surah) ?? 0;
          wordHash = 31 * wordHash + state;
        }
        hash = 31 * hash + wordHash;
      }
      hash = 31 * hash + ctrl.completedAyahsFor(s).length;
    }

    return hash;
  }

  void _requestSyncVisuals() {
    if (!mounted) return;
    final curr = AppState.instance.currentMushafPage.value;
    if (curr > 0 &&
        (widget.pageNumber - curr).abs() > 1 &&
        _lastActiveAyah == null &&
        _lastActiveWord == null) {
      return;
    }

    // Fast-path bypass for adjacent pre-cached pages during active recitation:
    // If the active reciting/matched ayah is not on this page and has no stale highlight, skip microtask!
    if (curr > 0 && widget.pageNumber != curr) {
      final ctrl = widget.controller;
      final activeAyah = ctrl.activeAyah.value;
      final targetSurah = ctrl.targetSurah != 0
          ? ctrl.targetSurah
          : AppState.instance.lastSurah;
      final activeMatch = ctrl.currentMatchedVerse;
      final provider = MushafProvider.instance;

      final bool hasRecitingAyah = activeAyah != null &&
          provider.isAyahOnPage(
              pageNumber: widget.pageNumber,
              surah: targetSurah,
              ayah: activeAyah);
      final bool hasMatchedAyah = activeMatch != null &&
          provider.isAyahOnPage(
              pageNumber: widget.pageNumber,
              surah: activeMatch.verse.surah,
              ayah: activeMatch.verse.ayah);
      final bool hasAudioAyah = ctrl.isAudioActive &&
          ctrl.audioSurah != null &&
          ctrl.audioAyah != null &&
          provider.isAyahOnPage(
              pageNumber: widget.pageNumber,
              surah: ctrl.audioSurah!,
              ayah: ctrl.audioAyah!);

      if (!hasRecitingAyah &&
          !hasMatchedAyah &&
          !hasAudioAyah &&
          _lastActiveAyah == null &&
          _lastActiveWord == null) {
        return;
      }
    }

    // Fast check for active user page swiping: defer sync until gesture settles
    if (MushafProvider.instance.isPageScrolling.value) {
      _needsSyncAfterScroll = true;
      return;
    }

    // Defer visual sync if a modal dialog or bottom sheet is open
    if (AppModalRouteObserver.instance.isModalOpen) {
      _needsSyncAfterModal = true;
      return;
    }

    // Fast O(1) controller & app state check: if revision, cursor, and modes didn't change,
    // skip the full fingerprint word-loop computation entirely!
    final ctrl = widget.controller;
    final app = AppState.instance;
    final int rev = ctrl.globalRevision.value;
    final int? activeAyah = ctrl.activeAyah.value;
    final int? activeWord = ctrl.activeWordIndex;
    final int targetSurah =
        ctrl.targetSurah != 0 ? ctrl.targetSurah : app.lastSurah;
    final bool isDark = app.isDarkMode;
    final bool isBlur =
        app.isBlurEffective(isRecording: widget.isRecording);
    final bool isRec = widget.isRecording;

    if (_lastVisualFingerprint != -1 &&
        rev == _lastSyncRevision &&
        activeAyah == _lastSyncActiveAyah &&
        activeWord == _lastSyncActiveWord &&
        targetSurah == _lastSyncTargetSurah &&
        isDark == _lastSyncDarkMode &&
        isBlur == _lastSyncBlur &&
        isRec == _lastSyncRecording &&
        !ctrl.isAudioActive) {
      return;
    }

    // Fast fingerprint check: if nothing visual on this page changed, skip scheduling frame callback entirely!
    final int fp = _computeVisualFingerprint();
    if (fp == _lastVisualFingerprint && _lastVisualFingerprint != -1) {
      return;
    }

    if (_syncScheduled) return;
    _syncScheduled = true;
    SchedulerBinding.instance.scheduleFrameCallback((_) {
      _syncScheduled = false;
      if (!mounted) return;
      if (MushafProvider.instance.isPageScrolling.value) {
        _needsSyncAfterScroll = true;
        return;
      }
      if (AppModalRouteObserver.instance.isModalOpen) {
        _needsSyncAfterModal = true;
        return;
      }
      final int currentFp = _computeVisualFingerprint();
      if (currentFp == _lastVisualFingerprint && _lastVisualFingerprint != -1) {
        return;
      }
      _syncVisuals();
    });
  }

  void _onCurrentMushafPageChanged() {
    updateKeepAlive();
    final curr = AppState.instance.currentMushafPage.value;
    if (widget.pageNumber == curr ||
        (widget.pageNumber - curr).abs() <= 1 ||
        _lastActiveAyah != null) {
      if (_page == null || _page!.isDisposed) {
        _loadPage();
      } else {
        _requestSyncVisuals();
      }
    }
  }

  void _onAudioWordChanged() {
    final app = AppState.instance;
    final surah = app.activeAudioSurah.value;
    final ayah = app.activeAudioAyah.value;
    if (surah == null || ayah == null) {
      if (_wordHighlightHandle != 0) _requestSyncVisuals();
      return;
    }
    final bool hasAudioAyah = MushafProvider.instance.isAyahOnPage(
      pageNumber: widget.pageNumber,
      surah: surah,
      ayah: ayah,
    );
    if (hasAudioAyah || _wordHighlightHandle != 0) {
      _requestSyncVisuals();
    }
  }

  void _onAudioStateChanged() {
    _checkSpinnerAnimation();
    _requestSyncVisuals();
  }

  void _onMaglisSessionListenableChanged() {
    _requestSyncVisuals();
  }

  void _attachListeners() {
    final app = AppState.instance;
    app.currentMushafPage.addListener(_onCurrentMushafPageChanged);
    app.activeAudioWordIndex.addListener(_onAudioWordChanged);
    app.activeAudioAyah.addListener(_onAudioStateChanged);
    app.activeAudioSurah.addListener(_onAudioStateChanged);
    app.isAudioPlaying.addListener(_onAudioStateChanged);
    app.isAudioBuffering.addListener(_onAudioStateChanged);
    app.blurModeNotifier.addListener(_requestSyncVisuals);
    app.themeNotifier.addListener(_requestSyncVisuals);
    app.modeNotifier.addListener(_requestSyncVisuals);
    widget.controller.addListener(_requestSyncVisuals);
    MushafProvider.instance.isPageScrolling
        .addListener(_onPageScrollingChanged);
    AppModalRouteObserver.instance.activeModalsNotifier
        .addListener(_onModalStateChanged);
    MaglisController.instance.sessionListenable
        .addListener(_onMaglisSessionListenableChanged);
  }

  void _detachListeners() {
    final app = AppState.instance;
    app.currentMushafPage.removeListener(_onCurrentMushafPageChanged);
    app.activeAudioWordIndex.removeListener(_onAudioWordChanged);
    app.activeAudioAyah.removeListener(_onAudioStateChanged);
    app.activeAudioSurah.removeListener(_onAudioStateChanged);
    app.isAudioPlaying.removeListener(_onAudioStateChanged);
    app.isAudioBuffering.removeListener(_onAudioStateChanged);
    app.blurModeNotifier.removeListener(_requestSyncVisuals);
    app.themeNotifier.removeListener(_requestSyncVisuals);
    app.modeNotifier.removeListener(_requestSyncVisuals);
    widget.controller.removeListener(_requestSyncVisuals);
    MushafProvider.instance.isPageScrolling
        .removeListener(_onPageScrollingChanged);
    AppModalRouteObserver.instance.activeModalsNotifier
        .removeListener(_onModalStateChanged);
    MaglisController.instance.sessionListenable
        .removeListener(_onMaglisSessionListenableChanged);
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
    if (currentPage > 0 && (widget.pageNumber - currentPage).abs() > 1) {
      if (_lastActiveAyah != null || _lastActiveWord != null) {
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

    final ctrl = widget.controller;
    final activeAyah = ctrl.activeAyah.value;
    final targetSurah =
        ctrl.targetSurah != 0 ? ctrl.targetSurah : app.lastSurah;
    final activeMatch = ctrl.currentMatchedVerse;

    final isRemoteReciting = ctrl.isRemoteReciting ||
        (MaglisController.instance.inSession &&
            !widget.isRecording &&
            MaglisController.instance.isRemoteReciting);
    final bool isReciting = widget.isRecording || isRemoteReciting;

    final bool isAudioActive = ctrl.isAudioActive;
    final int? audioSurah = ctrl.audioSurah;
    final int? audioAyah = ctrl.audioAyah;
    final int? audioWordIdx = ctrl.audioWordIndex;

    final provider = MushafProvider.instance;

    final bool hasRecitingAyah = activeAyah != null &&
        provider.isAyahOnPage(
            pageNumber: widget.pageNumber,
            surah: targetSurah,
            ayah: activeAyah);
    final bool hasMatchedAyah = activeMatch != null &&
        provider.isAyahOnPage(
            pageNumber: widget.pageNumber,
            surah: activeMatch.verse.surah,
            ayah: activeMatch.verse.ayah);
    final bool hasAudioAyah = isAudioActive &&
        audioSurah != null &&
        audioAyah != null &&
        provider.isAyahOnPage(
            pageNumber: widget.pageNumber, surah: audioSurah, ayah: audioAyah);

    // Fast early exit: if this is an adjacent pre-cached page and not the reciter's page,
    // and has no stale cursors or highlights to clear, exit immediately with zero allocations.
    if (widget.pageNumber != currentPage &&
        !hasRecitingAyah &&
        !hasAudioAyah &&
        !hasMatchedAyah &&
        _lastActiveAyah == null &&
        _lastActiveWord == null &&
        _lastIsDark == app.isDarkMode) {
      return;
    }

    page.batch(() {
      final c = app.colors;
      final isDark = app.isDarkMode;
      final bool themeChanged = (_lastIsDark != isDark);

      // 1. ACTIVE AYAH HIGHLIGHT (Only active during idle browsing/playback, NEVER during live recitation!)
      (int, int)? targetAyah;
      if (!isReciting) {
        if (hasAudioAyah) {
          targetAyah = (audioSurah, audioAyah);
        } else if (hasMatchedAyah) {
          targetAyah = (activeMatch.verse.surah, activeMatch.verse.ayah);
        } else if (hasRecitingAyah) {
          targetAyah = (targetSurah, activeAyah);
        }
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
            if (themeChanged) {
              page.restyleHighlight(_ayahHighlightHandle, style);
            }
            page.moveHighlight(
              _ayahHighlightHandle,
              T.ayah(targetAyah.$1, targetAyah.$2),
            );
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

      // 2. ACTIVE WORD HIGHLIGHT (Audio Word, or Reciter cursor)
      int? activeWord;
      if (hasAudioAyah) {
        final int targetWord1 = (audioWordIdx ?? 0) + 1;
        int idx = page.findWord(audioSurah, audioAyah, targetWord1);
        if (idx < 0) {
          _ensurePageWordsIndexed(page);
          idx = _pageWordMap[MaglisController.wordKey(
                  audioSurah, audioAyah, targetWord1 - 1)] ??
              -1;
        }
        if (idx >= 0) activeWord = idx;
      } else if (isReciting && (hasMatchedAyah || hasRecitingAyah)) {
        final int s = activeMatch?.verse.surah ?? targetSurah;
        final int a = activeMatch?.verse.ayah ?? activeAyah!;
        final int? specifiedWord = ctrl.activeWordIndex;

        if (specifiedWord != null) {
          _ensurePageWordsIndexed(page);
          final idx =
              _pageWordMap[MaglisController.wordKey(s, a, specifiedWord)] ??
                  page.findWord(s, a, specifiedWord + 1);
          if (idx >= 0) activeWord = idx;
        } else {
          _ensurePageAyahsGrouped(page);
          final ayahWords = _pageAyahWords[(s << 16) | a];
          if (ayahWords != null && ayahWords.isNotEmpty) {
            int firstUnrecitedWord0 = -1;
            for (final w in ayahWords) {
              final w0 = w.word - 1;
              if (!ctrl.isWordGreen(w.ayah, w0, surah: w.surah) &&
                  !ctrl.isWordRed(w.ayah, w0, surah: w.surah) &&
                  !ctrl.isWordYellow(w.ayah, w0, surah: w.surah) &&
                  !ctrl.isWordNeutral(w.ayah, w0, surah: w.surah)) {
                firstUnrecitedWord0 = w0;
                break;
              }
            }
            if (firstUnrecitedWord0 >= 0) {
              _ensurePageWordsIndexed(page);
              final idx = _pageWordMap[
                  MaglisController.wordKey(s, a, firstUnrecitedWord0)];
              activeWord = (idx != null && idx >= 0) ? idx : null;
            } else {
              activeWord = null;
            }
          }
        }
      }

      if (activeWord != _lastActiveWord || themeChanged) {
        _lastActiveWord = activeWord;
        if (activeWord != null) {
          final Color wordColor =
              c.wordHighlight.withValues(alpha: isDark ? 0.24 : 0.16);

          final style = QvpHighlightStyle(
            mode: 'band',
            height: 'lineSpacing',
            band: wordColor,
            padX: 1.2,
            radius: 4.0,
            ms: 0,
            layer: QvpLayer.highlight,
          );

          if (_wordHighlightHandle != 0) {
            if (themeChanged) {
              page.restyleHighlight(_wordHighlightHandle, style);
            }
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
      final bool isBlurEffective =
          app.isBlurEffective(isRecording: widget.isRecording);
      final bool blurChanged = (_lastBlurEffective != isBlurEffective);
      final bool recordingChanged = (_lastIsRecording != widget.isRecording);

      final bool hasReciterOnPage =
          isReciting && (hasRecitingAyah || hasMatchedAyah);

      final bool needsWordEvaluation = hasReciterOnPage ||
          blurChanged ||
          recordingChanged ||
          themeChanged ||
          !_hasEvaluatedWords ||
          _lastIndexedPage != widget.pageNumber;

      if (needsWordEvaluation) {
        _evalGreen.clear();
        _evalYellow.clear();
        _evalRed.clear();
        _evalHidden.clear();

        _ensurePageWordsIndexed(page);

        // Unified high-performance cached Ayah recitation pipeline (Normal ASR & Maglis)
        final bool hasAnyRecitationOrBlur = isReciting ||
            isBlurEffective ||
            ctrl.globalRevision.value > 0 ||
            _hasMasks ||
            _lastGreenWords.isNotEmpty ||
            _lastYellowWords.isNotEmpty ||
            _lastRedWords.isNotEmpty ||
            _lastHiddenWords.isNotEmpty;

        if (hasAnyRecitationOrBlur) {
          if (themeChanged ||
              blurChanged ||
              recordingChanged ||
              !_hasEvaluatedWords) {
            _clearCompletedAyahCache();
          }

          _ensurePageAyahsGrouped(page);

          final int activeSurahVal = activeMatch?.verse.surah ?? targetSurah;
          final int activeAyahVal =
              activeMatch?.verse.ayah ?? (activeAyah ?? 0);

          final Set<int> completedAyahs =
              ctrl.completedAyahsFor(activeSurahVal);

          _pageAyahWords.forEach((ayahKey, words) {
            if (words.isEmpty) return;
            final first = words.first;
            final s = first.surah;
            final a = first.ayah;

            // 1. Future unrecited ayahs
            final bool isFuture = (s > activeSurahVal) ||
                (s == activeSurahVal &&
                    a > activeAyahVal &&
                    !completedAyahs.contains(a));

            if (isFuture) {
              if (isBlurEffective) {
                for (final w in words) {
                  _evalHidden.add(w.index);
                }
              }
              return;
            }

            // 2. Completed or past ayahs fast-path: use cached evaluation if available
            final bool isPast = (s < activeSurahVal) ||
                (s == activeSurahVal && a < activeAyahVal) ||
                completedAyahs.contains(a);

            if (isPast && a != activeAyahVal) {
              final cachedG = _cachedCompletedGreenWords[ayahKey];
              if (cachedG != null) {
                _evalGreen.addAll(cachedG);
                final cachedY = _cachedCompletedYellowWords[ayahKey];
                if (cachedY != null) _evalYellow.addAll(cachedY);
                final cachedR = _cachedCompletedRedWords[ayahKey];
                if (cachedR != null) _evalRed.addAll(cachedR);
                final cachedH = _cachedCompletedHiddenWords[ayahKey];
                if (cachedH != null) _evalHidden.addAll(cachedH);
                return;
              }
            }

            // 3. Evaluate words for this ayah (active ayah or newly completed ayah)
            final ayGreen = <int>[];
            final ayYellow = <int>[];
            final ayRed = <int>[];
            final ayHidden = <int>[];

            for (final w in words) {
              final w0 = w.word - 1;
              final color = QuranInteractionService.resolveWordDisplayColor(
                ayah: w.ayah,
                wordIndex: w0,
                controller: ctrl,
                app: app,
                colors: c,
                surah: w.surah,
                isBlurEffective: isBlurEffective,
              );
              if (color == Colors.transparent) {
                ayHidden.add(w.index);
              } else if (color == c.green) {
                ayGreen.add(w.index);
              } else if (color == c.warning) {
                ayYellow.add(w.index);
              } else if (color == c.red) {
                ayRed.add(w.index);
              }
            }

            _evalGreen.addAll(ayGreen);
            _evalYellow.addAll(ayYellow);
            _evalRed.addAll(ayRed);
            _evalHidden.addAll(ayHidden);

            // Cache if this ayah is completed or in the past
            if (isPast && a != activeAyahVal) {
              _cachedCompletedGreenWords[ayahKey] = ayGreen;
              if (ayYellow.isNotEmpty) {
                _cachedCompletedYellowWords[ayahKey] = ayYellow;
              }
              if (ayRed.isNotEmpty) {
                _cachedCompletedRedWords[ayahKey] = ayRed;
              }
              if (ayHidden.isNotEmpty) {
                _cachedCompletedHiddenWords[ayahKey] = ayHidden;
              }
            }
          });
        }

        bool listsDiffer(List<int> a, List<int> b) {
          if (a.length != b.length) return true;
          if (a.isEmpty) return false;
          if (a.first != b.first || a.last != b.last) return true;
          return !listEquals(a, b);
        }

        final Color greenBandColor =
            c.green.withValues(alpha: isDark ? 0.22 : 0.15);
        final Color yellowBandColor =
            c.warning.withValues(alpha: isDark ? 0.24 : 0.18);
        final Color redBandColor =
            c.red.withValues(alpha: isDark ? 0.22 : 0.14);

        final bool recitationDiffers = themeChanged ||
            listsDiffer(_evalGreen, _lastGreenWords) ||
            listsDiffer(_evalYellow, _lastYellowWords) ||
            listsDiffer(_evalRed, _lastRedWords);

        if (recitationDiffers) {
          _lastGreenWords = List<int>.from(_evalGreen);
          _lastYellowWords = List<int>.from(_evalYellow);
          _yellowWordsNotifier.value = _lastYellowWords;
          _lastRedWords = List<int>.from(_evalRed);

          _updateRecitationHighlights(
            page,
            greenBandColor: greenBandColor,
            yellowBandColor: yellowBandColor,
            redBandColor: redBandColor,
            themeChanged: themeChanged,
          );
        }

        if (!listEquals(_evalHidden, _lastHiddenWords)) {
          _lastHiddenWords = List<int>.from(_evalHidden);
          if (_lastHiddenWords.isNotEmpty) {
            page.mask(T.words(_lastHiddenWords), 'hide');
            _hasMasks = true;
          } else if (_hasMasks) {
            page.unmaskAll();
            _hasMasks = false;
          }
        }
        _hasEvaluatedWords = true;
        _lastBlurEffective = isBlurEffective;
        _lastIsRecording = widget.isRecording;
      }

      _lastIsDark = isDark;
      _lastVisualFingerprint = _computeVisualFingerprint();
      _lastSyncRevision = ctrl.globalRevision.value;
      _lastSyncActiveAyah = ctrl.activeAyah.value;
      _lastSyncActiveWord = ctrl.activeWordIndex;
      _lastSyncTargetSurah =
          ctrl.targetSurah != 0 ? ctrl.targetSurah : app.lastSurah;
      _lastSyncDarkMode = isDark;
      _lastSyncBlur = isBlurEffective;
      _lastSyncRecording = widget.isRecording;
    });
  }

  void _updateRecitationHighlights(
    QvpPage page, {
    required Color greenBandColor,
    required Color yellowBandColor,
    required Color redBandColor,
    bool themeChanged = false,
  }) {
    final wordCount = page.words.length;
    if (wordCount == 0) {
      for (final r in _activeRunHandles.values) {
        page.removeHighlight(r.handle);
      }
      _activeRunHandles.clear();
      return;
    }

    if (themeChanged) {
      for (final r in _activeRunHandles.values) {
        page.removeHighlight(r.handle);
      }
      _activeRunHandles.clear();
    }

    // Fast state lookup array: 0=none, 1=green, 2=yellow, 3=red
    final states = Uint8List(wordCount);
    for (final idx in _lastGreenWords) {
      if (idx >= 0 && idx < wordCount) states[idx] = 1;
    }
    for (final idx in _lastYellowWords) {
      if (idx >= 0 && idx < wordCount) states[idx] = 2;
    }
    for (final idx in _lastRedWords) {
      if (idx >= 0 && idx < wordCount) states[idx] = 3;
    }

    // 2. Group into contiguous runs of the same state within the same Ayah.
    // Splitting at Ayah boundaries guarantees that Ayah medallions (۝) sitting between verses
    // are NEVER swallowed into a multi-verse spanning bounding box.
    // Splitting by contiguous indices guarantees that QVP's word_bands never bridges
    // across words of another color (stopping yellow from ever being covered by green or red).
    int currentRunState = 0;
    int currentAyahKey = 0;
    List<int>? currentRunWords;
    final List<({int state, List<int> words})> runs = [];

    for (int i = 0; i < wordCount; i++) {
      final int st = states[i];
      if (st == 0) {
        if (currentRunWords != null) {
          runs.add((state: currentRunState, words: currentRunWords));
          currentRunWords = null;
          currentRunState = 0;
          currentAyahKey = 0;
        }
        continue;
      }

      final w = page.words[i];
      final int ayahKey = (w.surah << 16) | w.ayah;

      if (currentRunWords != null &&
          currentRunState == st &&
          currentAyahKey == ayahKey) {
        currentRunWords.add(i);
      } else {
        if (currentRunWords != null) {
          runs.add((state: currentRunState, words: currentRunWords));
        }
        currentRunState = st;
        currentAyahKey = ayahKey;
        currentRunWords = [i];
      }
    }

    if (currentRunWords != null) {
      runs.add((state: currentRunState, words: currentRunWords));
    }

    if (runs.isEmpty) {
      for (final r in _activeRunHandles.values) {
        page.removeHighlight(r.handle);
      }
      _activeRunHandles.clear();
      return;
    }

    // 3. Highlight styles using engine-standard selection padding (0.6)
    final styleGreen = QvpHighlightStyle(
      mode: 'band',
      height: 'lineSpacing',
      band: greenBandColor,
      padX: 0.6,
      radius: 2.0,
      ms: 0,
      layer: QvpLayer.highlight - 1,
    );
    final styleYellow = QvpHighlightStyle(
      mode: 'band',
      height: 'lineSpacing',
      band: yellowBandColor,
      padX: 0.6,
      radius: 2.0,
      ms: 0,
      layer: QvpLayer.highlight - 1,
    );
    final styleRed = QvpHighlightStyle(
      mode: 'band',
      height: 'lineSpacing',
      band: redBandColor,
      padX: 0.6,
      radius: 2.0,
      ms: 0,
      layer: QvpLayer.highlight - 1,
    );

    // 4. Differential handle reconciliation:
    // Retain valid handles for all completed ayahs and unchanged runs.
    // Only drop and re-add handles for newly added or mutated runs.
    final Map<int, ({int state, int lastWord, int handle})> newActiveHandles =
        {};
    for (final run in runs) {
      final int startWord = run.words.first;
      final int lastWord = run.words.last;
      final int state = run.state;

      final existing = _activeRunHandles[startWord];
      if (existing != null && existing.state == state) {
        if (existing.lastWord != lastWord) {
          page.moveHighlight(existing.handle, T.words(run.words));
        }
        newActiveHandles[startWord] =
            (state: state, lastWord: lastWord, handle: existing.handle);
        _activeRunHandles.remove(startWord);
      } else {
        if (existing != null) {
          page.removeHighlight(existing.handle);
          _activeRunHandles.remove(startWord);
        }
        final QvpHighlightStyle style;
        if (state == 1) {
          style = styleGreen;
        } else if (state == 2) {
          style = styleYellow;
        } else {
          style = styleRed;
        }
        final h = page.highlight(T.words(run.words), style);
        newActiveHandles[startWord] =
            (state: state, lastWord: lastWord, handle: h);
      }
    }

    // Drop handles that no longer exist in new runs
    for (final remaining in _activeRunHandles.values) {
      page.removeHighlight(remaining.handle);
    }
    _activeRunHandles = newActiveHandles;
  }

  void _onWordTap(BuildContext context, QvpPage page, int wordIndex) {
    if (wordIndex < 0 || wordIndex >= page.words.length) return;
    int effectiveIndex = wordIndex;
    var w = page.words[effectiveIndex];
    var surah = w.surah;
    var ayah = w.ayah;
    var wordIndex0 = w.word - 1;

    final maglis = MaglisController.instance;

    bool isWordYellow(int a, int w0, int s) =>
        widget.controller.isWordYellow(a, w0, surah: s);

    // Smart yellow word magnetism:
    // If the hit word is not yellow, check if an immediately adjacent neighbor on the same line is yellow.
    // Small Arabic words often result in touch points landing on the neighboring word or gap.
    if (!isWordYellow(ayah, wordIndex0, surah)) {
      if (effectiveIndex > 0 &&
          page.words[effectiveIndex - 1].line == w.line &&
          isWordYellow(
            page.words[effectiveIndex - 1].ayah,
            page.words[effectiveIndex - 1].word - 1,
            page.words[effectiveIndex - 1].surah,
          )) {
        effectiveIndex = effectiveIndex - 1;
        w = page.words[effectiveIndex];
        surah = w.surah;
        ayah = w.ayah;
        wordIndex0 = w.word - 1;
      } else if (effectiveIndex + 1 < page.words.length &&
          page.words[effectiveIndex + 1].line == w.line &&
          isWordYellow(
            page.words[effectiveIndex + 1].ayah,
            page.words[effectiveIndex + 1].word - 1,
            page.words[effectiveIndex + 1].surah,
          )) {
        effectiveIndex = effectiveIndex + 1;
        w = page.words[effectiveIndex];
        surah = w.surah;
        ayah = w.ayah;
        wordIndex0 = w.word - 1;
      }
    }

    if (isWordYellow(ayah, wordIndex0, surah)) {
      QuranInteractionService.handleWordTap(
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

    // While another peer is actively reciting in Maglis, the selected verse
    // is strictly maintained by the reciter. Non-reciters cannot hijack the selection
    // or trigger word audio playback.
    if (maglis.inSession && maglis.isRemoteReciting) {
      return;
    }

    final activeAyah = widget.controller.activeAyah.value;
    final activeSurah = widget.controller.targetSurah != 0
        ? widget.controller.targetSurah
        : AppState.instance.lastSurah;
    final isAlreadyActive = (activeSurah == surah && activeAyah == ayah);

    if (isAlreadyActive) {
      QuranInteractionService.handleWordTap(
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
      QuranInteractionService.selectAyah(
        surah: surah,
        ayah: ayah,
        controller: widget.controller,
        onTap: widget.onStateChangeRequested,
      );
    }
  }

  void _onDecorationTap(QvpDecorationInfo dec) {
    // In a Maglis session, verse audio playback is disabled so the room audio call
    // and live reciter are never interrupted by recorded audio!
    if (MaglisController.instance.inSession) return;

    if (dec.surah > 0 && dec.ayah > 0) {
      AppHaptics.selectionClick();
      AppState.instance.markMushafAudioAyahClicked();
      QuranInteractionService.toggleAyahAudio(
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
      if (!_isLoading && !_hasError && !_reloadScheduled) {
        final current = AppState.instance.currentMushafPage.value;
        // Guard: Only schedule reload if this page is in the active reading viewport window
        if ((widget.pageNumber - current).abs() <= 1) {
          _reloadScheduled = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _reloadScheduled = false;
            if (!mounted || _isLoading) return;
            if (_page == null || _page!.isDisposed) {
              _loadPage();
            }
          });
        }
      }
      return ColoredBox(
        color: c.surface,
        child: _hasError
            ? Center(
                child: IconButton(
                  icon: const Icon(Icons.refresh_rounded),
                  color: c.textSecondary,
                  tooltip: 'إعادة المحاولة / Retry',
                  onPressed: () {
                    setState(() {
                      _hasError = false;
                      _loadPage();
                    });
                  },
                ),
              )
            : const SizedBox.expand(),
      );
    }

    final page = _page!;
    final app = AppState.instance;
    final isDark = app.isDarkMode;
    final neutralRingColor = isDark
        ? Colors.white.withValues(alpha: 0.25)
        : const Color(0xFF64748B).withValues(alpha: 0.35);

    _hasSurahHeaders ??= page.surahHeaders().isNotEmpty;
    final bool hasSurahHeaders = _hasSurahHeaders!;

    return Directionality(
      textDirection: TextDirection.rtl,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (hasSurahHeaders)
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
            onWordTap: (word, _) => _onWordTap(context, page, word.index),
            onDecorationTap: (dec, _) => _onDecorationTap(dec),
          ),
          IgnorePointer(
            child: CustomPaint(
              painter: AyahMarkPainter(
                page: page,
                app: app,
                spinnerAnimation: _spinnerController,
                repaintListenable: _ayahMarkRepaintListenable,
                surfaceColor: c.surface,
                goldColor: c.gold,
                neutralRingColor: neutralRingColor,
                ayahHighlightColor: isDark
                    ? Colors.white.withValues(alpha: 0.10)
                    : const Color(0xFF64748B).withValues(alpha: 0.09),
                controller: widget.controller,
              ),
            ),
          ),
          ListenableBuilder(
            listenable: _tajweedVisibilityListenable,
            builder: (context, _) {
              if (app.hasClickedTajweedWord ||
                  app.currentMode != AppMode.tajweed) {
                return const SizedBox.shrink();
              }
              return ValueListenableBuilder<List<int>>(
                valueListenable: _yellowWordsNotifier,
                builder: (context, yellowWords, _) {
                  if (yellowWords.isEmpty) {
                    return const SizedBox.shrink();
                  }
                  return IgnorePointer(
                    child: CustomPaint(
                      painter: MushafTajweedTooltipPainter(
                        page: page,
                        controller: widget.controller,
                        app: app,
                        goldColor: c.gold,
                        explicitYellowWords: yellowWords,
                        repaintListenable: _yellowWordsNotifier,
                      ),
                    ),
                  );
                },
              );
            },
          ),
        ],
      ),
    );
  }
}

/// Backward compatibility alias
typedef PageWidget = MushafPageWidget;

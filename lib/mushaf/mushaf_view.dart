import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:qvp_flutter/qvp_flutter.dart';
import '../core/app_state.dart';
import '../core/highlighting_controller.dart';
import '../core/platform_utils.dart';
import '../maglis/maglis_controller.dart';
import 'mushaf_overlays.dart';
import 'mushaf_provider.dart';

export 'mushaf_provider.dart';

/// Single-view Mushaf architecture matching Native Android (MainActivity.kt).
///
/// Instead of mounting multi-page PageViews and competing gesture recognizers,
/// this view hosts a single [QvpPageView] with native swipe fling detection
/// and a 150ms GPU slide transition.
class MushafView extends StatefulWidget {
  final HighlightingController controller;
  final bool isRecording;
  final bool showBottomPageNumber;

  const MushafView({
    super.key,
    required this.controller,
    required this.isRecording,
    this.showBottomPageNumber = true,
  });

  static bool get isSyncingSurah => MushafProvider.instance.isSyncingSurah;
  static set isSyncingSurah(bool v) =>
      MushafProvider.instance.isSyncingSurah = v;

  static void preloadData() => MushafProvider.instance.preloadData();

  static (int surah, int ayah)? getFirstAyahOnPage(int pageNumber) =>
      MushafProvider.instance.getFirstAyahOnPage(pageNumber);

  static int? getDominantSurahOnPage(int pageNumber) =>
      MushafProvider.instance.getDominantSurahOnPage(pageNumber);

  static int? getPageForAyah(int surah, int ayah) =>
      MushafProvider.instance.getPageForAyah(surah, ayah);

  static bool isAyahOnPage({
    required int pageNumber,
    required int surah,
    required int ayah,
  }) =>
      MushafProvider.instance.isAyahOnPage(
        pageNumber: pageNumber,
        surah: surah,
        ayah: ayah,
      );

  static MushafWordRef? getLastWordOnPage(int pageNumber) =>
      MushafProvider.instance.getLastWordOnPage(pageNumber);

  static Future<void> ensureActiveAyahOnCurrentPage({
    required HighlightingController controller,
    int? pageNumber,
  }) =>
      MushafProvider.instance.ensureActiveAyahOnCurrentPage(
        controller: controller,
        pageNumber: pageNumber,
      );

  @override
  State<MushafView> createState() => _MushafViewState();
}

class _MushafViewState extends State<MushafView> with TickerProviderStateMixin {
  int _currentPage = 1;
  QvpPage? _currentPageObject;
  bool _isLoading = true;
  final FocusNode _focusNode = FocusNode();
  (int surah, int ayah)? _navigationTargetAyah;
  Timer? _savePositionDebounce;

  // Auto-advance state during live recitation
  int? _lastAutoAdvancedFromPage;
  bool _isAutoAdvancingPage = false;
  int? _lastAdvancedSurah;
  bool _isAdvancingSurah = false;
  int? _lastProgressSurah;
  int? _lastProgressAyah;
  int? _lastProgressWord;
  int? _lastProgressRev;

  // Native 150ms Slide animation
  late final AnimationController _slideController;
  late final Animation<double> _slideAnimation;
  int _turnDir = 0;
  int _activeSlideDir = 0;

  // Audio spinner animation & overlays repaint
  late final AnimationController _spinnerController;
  late final Listenable _combinedRepaintListenable;
  final ValueNotifier<List<int>> _yellowWordsNotifier =
      ValueNotifier<List<int>>(const []);

  // Recitation & Highlight handles on the single active QvpPage
  int _ayahHighlightHandle = 0;
  int _wordHighlightHandle = 0;
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

  int _lastWordsIndexedPage = -1;
  int _lastAyahsGroupedPage = -1;

  void _ensurePageWordsIndexed(QvpPage page) {
    if (_lastWordsIndexedPage == _currentPage && _pageWordMap.isNotEmpty) {
      return;
    }
    final map = <int, int>{};
    for (final w in page.words) {
      map[QuranCoordinate.packWordKey(w.surah, w.ayah, w.word - 1)] = w.index;
    }
    _pageWordMap = map;
    _lastWordsIndexedPage = _currentPage;
  }

  void _ensurePageAyahsGrouped(QvpPage page) {
    if (_lastAyahsGroupedPage == _currentPage && _pageAyahWords.isNotEmpty) {
      return;
    }
    _pageAyahWords.clear();
    for (final w in page.words) {
      final key = QuranCoordinate.packAyahKey(w.surah, w.ayah);
      (_pageAyahWords[key] ??= []).add(w);
    }
    _lastAyahsGroupedPage = _currentPage;
  }

  // Keyboard navigation: Left = Next page (+1 in RTL), Right = Prev page (-1 in RTL)
  KeyEventResult _controlRLByKeyboard(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;

    if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      _nextPage();
      return KeyEventResult.handled;
    } else if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
      _prevPage();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  int _lastWheelMs = 0;

  void _onPointerSignal(PointerSignalEvent event) {
    if (event is PointerScrollEvent) {
      final now = DateTime.now().millisecondsSinceEpoch;
      if (now - _lastWheelMs < 240) return;

      final double delta =
          event.scrollDelta.dy.abs() > event.scrollDelta.dx.abs()
              ? event.scrollDelta.dy
              : event.scrollDelta.dx;

      if (delta.abs() > 12.0) {
        _lastWheelMs = now;
        if (delta > 0) {
          _nextPage();
        } else {
          _prevPage();
        }
      }
    }
  }

  @override
  void initState() {
    super.initState();
    final provider = MushafProvider.instance;
    _currentPage = _findInitialPage();
    _isLoading = !provider.isReady;

    _slideController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 150),
    );
    _slideAnimation = CurvedAnimation(
      parent: _slideController,
      curve: Curves.decelerate,
    );

    _spinnerController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    );

    final app = AppState.instance;
    _combinedRepaintListenable = Listenable.merge([
      _spinnerController,
      app.activeAudioAyah,
      app.activeAudioSurah,
      app.isAudioBuffering,
      app.isAudioPlaying,
      app.modeNotifier,
      app.hasClickedTajweedNotifier,
      widget.controller.activeAyah,
      _yellowWordsNotifier,
    ]);

    widget.controller.activeAyah.addListener(_onActiveAyahChanged);
    widget.controller.addListener(_onControllerProgress);
    widget.controller.addListener(_requestSyncVisuals);
    app.activeAudioAyah.addListener(_onAudioAyahChanged);
    app.activeAudioSurah.addListener(_onAudioAyahChanged);
    app.themeNotifier.addListener(_requestSyncVisuals);
    MaglisController.instance.sessionListenable
        .addListener(_onMaglisSessionChanged);
    AppModalRouteObserver.instance.activeModalsNotifier
        .addListener(_onModalStateChanged);

    MaglisController.instance.onSyncMushafUI = (page, surah, ayah) {
      if (!mounted) return;
      _navigationTargetAyah = (surah, ayah);
      if (QuranMetadata.isValidPage(page)) {
        if (page != _currentPage) {
          _goToPage(page, animated: true);
        } else {
          _syncPageSelection(page);
        }
      }
    };

    if (provider.isReady) {
      _isLoading = false;
      _loadCurrentPage(_currentPage);
    } else {
      _initMushafData();
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        AppState.instance.currentMushafPage.value = _currentPage;
        MushafProvider.instance.preloadAdjacentPages(
          _currentPage,
          MushafProvider.instance.lastViewportSize,
        );
        if (!AppState.instance.hasClickedMushafAudioAyah) {
          AppState.instance.showMushafAudioBanner();
        }
      }
    });
  }

  @override
  void didUpdateWidget(MushafView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.activeAyah.removeListener(_onActiveAyahChanged);
      oldWidget.controller.removeListener(_onControllerProgress);
      oldWidget.controller.removeListener(_requestSyncVisuals);
      widget.controller.activeAyah.addListener(_onActiveAyahChanged);
      widget.controller.addListener(_onControllerProgress);
      widget.controller.addListener(_requestSyncVisuals);
      _clearCompletedAyahCache();
      _requestSyncVisuals();
    }
    if (!oldWidget.isRecording && widget.isRecording) {
      final active = widget.controller.activeAyah.value;
      final int targetSurah = widget.controller.targetSurah != 0
          ? widget.controller.targetSurah
          : AppState.instance.lastSurah;
      if (active == null ||
          !MushafView.isAyahOnPage(
            pageNumber: _currentPage,
            surah: targetSurah,
            ayah: active,
          )) {
        MushafView.ensureActiveAyahOnCurrentPage(
          controller: widget.controller,
          pageNumber: _currentPage,
        ).then((_) {
          if (mounted) {
            _requestSyncVisuals();
            setState(() {});
          }
        });
      }
    } else if (oldWidget.isRecording && !widget.isRecording) {
      _lastAutoAdvancedFromPage = null;
      _lastAdvancedSurah = null;
      _requestSyncVisuals();
    }
  }

  void _onModalStateChanged() {
    if (!mounted) return;
    if (!AppModalRouteObserver.instance.isModalOpen &&
        _needsSyncAfterModal) {
      _needsSyncAfterModal = false;
      _onActiveAyahChanged();
      _requestSyncVisuals();
    }
  }

  int _findInitialPage() {
    final cachedPage = AppState.instance.currentMushafPage.value;
    if (cachedPage > 1 && QuranMetadata.isValidPage(cachedPage)) {
      return cachedPage;
    }
    final surah = widget.controller.targetSurah != 0
        ? widget.controller.targetSurah
        : AppState.instance.lastSurah;
    final ayah =
        widget.controller.activeAyah.value ?? AppState.instance.lastAyah;
    final provider = MushafProvider.instance;
    final mapped = provider.getPageForAyah(surah, ayah) ??
        provider.getPageForAyah(surah, 1);
    if (mapped != null && QuranMetadata.isValidPage(mapped)) {
      return mapped;
    }
    return QuranMetadata.clampPage(cachedPage);
  }

  Future<void> _initMushafData() async {
    await MushafProvider.instance.loadData();
    if (mounted) {
      final initialPage = _findInitialPage();
      _currentPage = initialPage;
      AppState.instance.currentMushafPage.value = _currentPage;
      await _loadCurrentPage(_currentPage);
      setState(() => _isLoading = false);
    }
  }

  void _debouncedSavePosition(int pageNum, int surah, int ayah) {
    _savePositionDebounce?.cancel();
    _savePositionDebounce = Timer(const Duration(milliseconds: 400), () {
      AppState.instance.saveMushafPage(pageNum);
      AppState.instance.saveLastPosition(surah, ayah);
    });
  }

  @override
  void dispose() {
    _slideController.dispose();
    _spinnerController.dispose();
    _yellowWordsNotifier.dispose();
    AppModalRouteObserver.instance.activeModalsNotifier
        .removeListener(_onModalStateChanged);
    MaglisController.instance.sessionListenable
        .removeListener(_onMaglisSessionChanged);
    MaglisController.instance.onSyncMushafUI = null;
    _savePositionDebounce?.cancel();
    widget.controller.activeAyah.removeListener(_onActiveAyahChanged);
    widget.controller.removeListener(_onControllerProgress);
    widget.controller.removeListener(_requestSyncVisuals);
    final app = AppState.instance;
    app.activeAudioAyah.removeListener(_onAudioAyahChanged);
    app.activeAudioSurah.removeListener(_onAudioAyahChanged);
    app.themeNotifier.removeListener(_requestSyncVisuals);
    _focusNode.dispose();
    _clearPageVisuals(_currentPageObject);
    super.dispose();
  }

  bool _lastMaglisInSession = false;

  void _onMaglisSessionChanged() {
    final inSession = MaglisController.instance.inSession;
    if (_lastMaglisInSession != inSession) {
      _lastMaglisInSession = inSession;
      _requestSyncVisuals();
      if (mounted) setState(() {});
    }
  }

  Future<void> _advanceToNextSurah(int currentSurah) async {
    if (_isAdvancingSurah || !mounted || !widget.isRecording) return;
    final int nextSurah = currentSurah + 1;
    if (!QuranMetadata.isValidSurah(nextSurah)) return;

    _isAdvancingSurah = true;
    _lastAdvancedSurah = currentSurah;

    try {
      AppHaptics.mediumImpact();
      final provider = MushafProvider.instance;
      const int nextAyah = 1;

      final targetPage = provider.getPageForAyah(nextSurah, nextAyah);
      if (targetPage != null && targetPage != _currentPage) {
        _navigationTargetAyah = (nextSurah, nextAyah);
        _goToPage(targetPage, animated: true);
      }

      await widget.controller.advanceToNextSurah(
        isRecording: widget.isRecording,
      );
    } catch (e) {
      debugPrint('Error advancing to next surah: $e');
    } finally {
      await Future.delayed(const Duration(milliseconds: 300));
      _isAdvancingSurah = false;
    }
  }

  void _onControllerProgress() {
    final provider = MushafProvider.instance;
    final isCoveredOrTransitioning = AppModalRouteObserver.instance.isModalOpen;
    if (!mounted ||
        isCoveredOrTransitioning ||
        _isAutoAdvancingPage ||
        _isAdvancingSurah ||
        !provider.isReady ||
        !widget.isRecording) {
      return;
    }

    final ctrl = widget.controller;
    final int activeSurah =
        ctrl.targetSurah != 0 ? ctrl.targetSurah : AppState.instance.lastSurah;
    final int? activeAyah = ctrl.activeAyah.value;
    final int? activeWord = ctrl.activeWordIndex;
    final int rev = ctrl.globalRevision.value;

    if (activeSurah == _lastProgressSurah &&
        activeAyah == _lastProgressAyah &&
        activeWord == _lastProgressWord &&
        rev == _lastProgressRev) {
      return;
    }
    _lastProgressSurah = activeSurah;
    _lastProgressAyah = activeAyah;
    _lastProgressWord = activeWord;
    _lastProgressRev = rev;

    // 1. Hands-free recitation flow across Surahs
    if (ctrl.isSurahFinished(activeSurah)) {
      if (activeSurah < QuranMetadata.maxSurah && _lastAdvancedSurah != activeSurah) {
        _advanceToNextSurah(activeSurah);
        return;
      }
    } else {
      if (_lastAdvancedSurah == activeSurah) {
        _lastAdvancedSurah = null;
      }
    }

    final lastWord = provider.getLastWordOnPage(_currentPage);
    if (lastWord == null) return;

    final isLastWordOnPageRead =
        ctrl.isWordRead(lastWord.ayah, lastWord.wordIndex0, surah: lastWord.surah);
    final isLastAyahOnPageCompleted =
        ctrl.completedAyahsFor(lastWord.surah).contains(lastWord.ayah);

    if (isLastWordOnPageRead || isLastAyahOnPageCompleted) {
      if (_currentPage < QuranMetadata.maxPage && _lastAutoAdvancedFromPage != _currentPage) {
        _isAutoAdvancingPage = true;
        _lastAutoAdvancedFromPage = _currentPage;

        AppHaptics.lightImpact();
        final nextPage = _currentPage + 1;

        final nextAyahInfo = provider.getFirstAyahOnPage(nextPage);
        if (nextAyahInfo != null) {
          final nextSurah = nextAyahInfo.$1;
          final nextAyah = nextAyahInfo.$2;

          _navigationTargetAyah = (nextSurah, nextAyah);
          _goToPage(nextPage, animated: true);

          if (ctrl.targetSurah != nextSurah) {
            ctrl.setTargetSurah(
              nextSurah,
              preserveOtherSurahStates: true,
              clearTargetSurah: false,
            );
          }
          ctrl.setManualAyah(nextSurah, nextAyah);
        } else {
          _goToPage(nextPage, animated: true);
        }

        Future.delayed(const Duration(milliseconds: 600), () {
          _isAutoAdvancingPage = false;
        });
      }
    } else {
      if (_lastAutoAdvancedFromPage == _currentPage) {
        _lastAutoAdvancedFromPage = null;
      }
    }
  }

  void _onActiveAyahChanged() {
    if (!mounted) return;
    if (AppModalRouteObserver.instance.isModalOpen) {
      _needsSyncAfterModal = true;
      return;
    }
    final activeAyah = widget.controller.activeAyah.value;
    if (activeAyah == null) return;

    final surah = widget.controller.targetSurah != 0
        ? widget.controller.targetSurah
        : AppState.instance.lastSurah;

    final provider = MushafProvider.instance;
    final page = provider.getPageForAyah(surah, activeAyah);
    if (page != null && page != _currentPage) {
      _navigationTargetAyah = (surah, activeAyah);
      _goToPage(page, animated: true);
    }
    _requestSyncVisuals();
  }

  void _onAudioAyahChanged() {
    if (!mounted) return;
    final audioSurah = widget.controller.audioSurah;
    final audioAyah = widget.controller.audioAyah;
    _checkSpinnerAnimation();

    if (audioSurah == null || audioAyah == null) {
      _requestSyncVisuals();
      return;
    }

    final provider = MushafProvider.instance;
    final page = provider.getPageForAyah(audioSurah, audioAyah);
    if (page != null && page != _currentPage) {
      _navigationTargetAyah = (audioSurah, audioAyah);
      _goToPage(page, animated: true);
    }
    _requestSyncVisuals();
  }

  void _checkSpinnerAnimation() {
    final isBuffering = widget.controller.isAudioBuffering;
    final surah = widget.controller.audioSurah;
    final ayah = widget.controller.audioAyah;
    final page = _currentPageObject;

    final bool isBufferingOnThisPage = isBuffering &&
        surah != null &&
        ayah != null &&
        page != null &&
        !page.isDisposed &&
        MushafProvider.instance.isAyahOnPage(
          pageNumber: _currentPage,
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

  void _syncPageSelection(int pageNum) {
    final provider = MushafProvider.instance;
    if (_navigationTargetAyah != null) {
      final target = _navigationTargetAyah!;
      if (provider.isAyahOnPage(
        pageNumber: pageNum,
        surah: target.$1,
        ayah: target.$2,
      )) {
        _navigationTargetAyah = null;
        _debouncedSavePosition(pageNum, target.$1, target.$2);
        return;
      }
    }

    final first = provider.getFirstAyahOnPage(pageNum);
    _debouncedSavePosition(
      pageNum,
      first?.$1 ?? AppState.instance.lastSurah,
      first?.$2 ?? AppState.instance.lastAyah,
    );
  }

  void _stepPage(int dir) {
    final target = QuranMetadata.clampPage(_currentPage + dir);
    if (target == _currentPage) return;
    _turnDir = dir;
    _goToPage(target, animated: true);
  }

  void _nextPage() {
    _navigationTargetAyah = null;
    _stepPage(1);
  }

  void _prevPage() {
    _navigationTargetAyah = null;
    _stepPage(-1);
  }

  void _goToPage(int page, {bool animated = false}) {
    final clamped = QuranMetadata.clampPage(page);
    if (clamped == _currentPage && _currentPageObject != null) return;
    if (_turnDir == 0) {
      _turnDir = clamped > _currentPage ? 1 : -1;
    }
    _currentPage = clamped;
    AppState.instance.currentMushafPage.value = clamped;
    _syncPageSelection(clamped);
    _loadCurrentPage(clamped, triggerSlide: animated);
  }

  Future<void> _loadCurrentPage(int pageNumber, {bool triggerSlide = false}) async {
    final cached = MushafProvider.instance.getCachedPage(pageNumber);
    if (cached != null && !cached.isDisposed) {
      _clearPageVisuals(_currentPageObject);
      _currentPageObject = cached;
      _checkSpinnerAnimation();
      _syncVisuals();
      if (triggerSlide && _turnDir != 0) {
        _triggerSlide();
      }
      if (mounted) setState(() {});
    } else {
      final p = await MushafProvider.instance.getPage(pageNumber);
      if (!mounted || pageNumber != _currentPage) return;
      _clearPageVisuals(_currentPageObject);
      _currentPageObject = p;
      _checkSpinnerAnimation();
      _syncVisuals();
      if (triggerSlide && _turnDir != 0) {
        _triggerSlide();
      }
      if (mounted) setState(() {});
    }
    MushafProvider.instance.preloadAdjacentPages(
      pageNumber,
      MushafProvider.instance.lastViewportSize,
    );
  }

  void _triggerSlide() {
    final d = _turnDir;
    _turnDir = 0;
    if (d == 0) return;
    _activeSlideDir = d;
    _slideController.forward(from: 0.0);
  }

  void _clearPageVisuals(QvpPage? page) {
    if (page == null || page.isDisposed) return;
    page.batch(() {
      if (_ayahHighlightHandle != 0) {
        page.removeHighlight(_ayahHighlightHandle);
        _ayahHighlightHandle = 0;
      }
      if (_wordHighlightHandle != 0) {
        page.removeHighlight(_wordHighlightHandle);
        _wordHighlightHandle = 0;
      }
      for (final r in _activeRunHandles.values) {
        page.removeHighlight(r.handle);
      }
      _activeRunHandles.clear();
      if (_hasMasks) {
        page.unmaskAll();
        _hasMasks = false;
      }
    });
    _lastActiveAyah = null;
    _lastActiveWord = null;
    _lastGreenWords = const [];
    _lastYellowWords = const [];
    _yellowWordsNotifier.value = const [];
    _lastRedWords = const [];
    _lastHiddenWords = const [];
    _hasEvaluatedWords = false;
    _clearCompletedAyahCache();
  }

  // Visual synchronization & recitation highlights
  bool _syncScheduled = false;
  bool _needsSyncAfterModal = false;
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

    int hash = _currentPage;
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

    final page = _currentPageObject;
    if (isReciting && page != null && !page.isDisposed && a > 0) {
      _ensurePageAyahsGrouped(page);
      final ayahWords = _pageAyahWords[QuranCoordinate.packAyahKey(s, a)];
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
    if (AppModalRouteObserver.instance.isModalOpen) {
      _needsSyncAfterModal = true;
      return;
    }

    final ctrl = widget.controller;
    final app = AppState.instance;
    final int rev = ctrl.globalRevision.value;
    final int? activeAyah = ctrl.activeAyah.value;
    final int? activeWord = ctrl.activeWordIndex;
    final int targetSurah =
        ctrl.targetSurah != 0 ? ctrl.targetSurah : app.lastSurah;
    final bool isDark = app.isDarkMode;
    final bool isBlur = app.isBlurEffective(isRecording: widget.isRecording);
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

    final int fp = _computeVisualFingerprint();
    if (fp == _lastVisualFingerprint && _lastVisualFingerprint != -1) {
      return;
    }

    if (_syncScheduled) return;
    _syncScheduled = true;
    SchedulerBinding.instance.scheduleFrameCallback((_) {
      _syncScheduled = false;
      if (!mounted) return;
      if (AppModalRouteObserver.instance.isModalOpen) {
        _needsSyncAfterModal = true;
        return;
      }
      _syncVisuals();
    });
  }

  void _syncVisuals() {
    final page = _currentPageObject;
    if (page == null || page.isDisposed || !mounted) return;

    final app = AppState.instance;
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

    final provider = MushafProvider.instance;

    final bool hasRecitingAyah = activeAyah != null &&
        provider.isAyahOnPage(
            pageNumber: _currentPage,
            surah: targetSurah,
            ayah: activeAyah);
    final bool hasMatchedAyah = activeMatch != null &&
        provider.isAyahOnPage(
            pageNumber: _currentPage,
            surah: activeMatch.verse.surah,
            ayah: activeMatch.verse.ayah);
    final bool hasAudioAyah = isAudioActive &&
        audioSurah != null &&
        audioAyah != null &&
        provider.isAyahOnPage(
            pageNumber: _currentPage, surah: audioSurah, ayah: audioAyah);

    page.batch(() {
      final c = app.colors;
      final isDark = app.isDarkMode;
      final bool themeChanged = (_lastIsDark != isDark);
      final palette = QuranHighlightPalette.fromTheme(colors: c, isDark: isDark);

      // 1. ACTIVE AYAH HIGHLIGHT
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
          final style = QvpHighlightStyle(
            mode: 'band',
            height: 'lineSpacing',
            band: palette.activeAyahBand,
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

      // 2. ACTIVE WORD HIGHLIGHT
      int? activeWord;
      final int s = hasAudioAyah
          ? audioSurah
          : (activeMatch?.verse.surah ?? targetSurah);
      final int a = hasAudioAyah
          ? audioAyah
          : (activeMatch?.verse.ayah ?? (activeAyah ?? 0));

      if (hasAudioAyah || (isReciting && (hasMatchedAyah || hasRecitingAyah))) {
        _ensurePageAyahsGrouped(page);
        final ayahWords = _pageAyahWords[QuranCoordinate.packAyahKey(s, a)];
        final int? leadWord0 = ctrl.getLeadWordIndex(
          surah: s,
          ayah: a,
          totalWords: ayahWords?.length ?? 0,
          isRecording: isReciting,
        );

        if (leadWord0 != null) {
          _ensurePageWordsIndexed(page);
          final idx = _pageWordMap[QuranCoordinate.packWordKey(s, a, leadWord0)] ??
              page.findWord(s, a, leadWord0 + 1);
          if (idx >= 0) activeWord = idx;
        }
      }

      if (activeWord != _lastActiveWord || themeChanged) {
        _lastActiveWord = activeWord;
        if (activeWord != null) {
          final style = QvpHighlightStyle(
            mode: 'band',
            height: 'lineSpacing',
            band: palette.leadWordBand,
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
          _lastWordsIndexedPage != _currentPage ||
          _lastAyahsGroupedPage != _currentPage;

      if (needsWordEvaluation) {
        _evalGreen.clear();
        _evalYellow.clear();
        _evalRed.clear();
        _evalHidden.clear();

        _ensurePageWordsIndexed(page);

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

        final Color greenBandColor = palette.greenBand;
        final Color yellowBandColor = palette.yellowBand;
        final Color redBandColor = palette.redBand;

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
      final int ayahKey = QuranCoordinate.packAyahKey(w.surah, w.ayah);

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

    if (maglis.inSession && maglis.isRemoteReciting) {
      return;
    }

    QuranInteractionService.handleWordTap(
      context: context,
      surah: surah,
      ayah: ayah,
      wordIndex: wordIndex0,
      wordText: w.text,
      controller: widget.controller,
      onAyahTap: () => setState(() {}),
    );
  }

  void _onDecorationTap(QvpDecorationInfo dec) {
    if (MaglisController.instance.inSession) return;

    if (dec.surah > 0 && dec.ayah > 0) {
      AppHaptics.selectionClick();
      AppState.instance.markMushafAudioAyahClicked();
      QuranInteractionService.toggleAyahAudio(
        surah: dec.surah,
        ayah: dec.ayah,
        controller: widget.controller,
        isRecording: widget.isRecording,
        onTap: () => setState(() {}),
      );
    }
  }

  void _paintUnderlay(ui.Canvas canvas, Size size, QvpPage page, QvpLayout? layout) {
    if (page.isDisposed) return;
    if (page.surahHeaders().isNotEmpty) {
      MushafOverlays.paintSurahHeaders(
        canvas,
        page,
        layout,
        isDark: AppState.instance.isDarkMode,
        colors: AppState.instance.colors,
      );
    }
  }

  void _paintOverlay(ui.Canvas canvas, Size size, QvpPage page, QvpLayout? layout) {
    if (page.isDisposed) return;
    final app = AppState.instance;
    final c = app.colors;
    final isDark = app.isDarkMode;
    final neutralRingColor = isDark
        ? Colors.white.withValues(alpha: 0.25)
        : const Color(0xFF64748B).withValues(alpha: 0.35);

    MushafOverlays.paintAyahMarks(
      canvas,
      page,
      layout,
      app: app,
      spinnerProgress: _spinnerController.value,
      surfaceColor: c.surface,
      goldColor: c.gold,
      neutralRingColor: neutralRingColor,
      ayahHighlightColor: isDark
          ? Colors.white.withValues(alpha: 0.10)
          : const Color(0xFF64748B).withValues(alpha: 0.09),
      controller: widget.controller,
    );

    if (!app.hasClickedTajweedWord &&
        app.currentMode == AppMode.tajweed &&
        _yellowWordsNotifier.value.isNotEmpty) {
      MushafOverlays.paintTajweedTooltip(
        canvas,
        size,
        page,
        layout,
        app: app,
        goldColor: c.gold,
        yellowWords: _yellowWordsNotifier.value,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = AppState.instance.colors;

    if (_isLoading) {
      return ColoredBox(
        color: c.surface,
        child: const SizedBox.expand(),
      );
    }

    final padding = MediaQuery.paddingOf(context);
    final viewPadding = MediaQuery.viewPaddingOf(context);
    final safeTop = math.max(padding.top, viewPadding.top);
    final safeBottom = math.max(padding.bottom, viewPadding.bottom);
    final safeLeft = math.max(padding.left, viewPadding.left);

    final double topPadding = safeTop > 0 ? safeTop + 4.0 : 8.0;

    final bool isSessionActive =
        widget.isRecording || MaglisController.instance.inSession;

    final double pageLabelBottom =
        isSessionActive ? (safeBottom + 27.0) : (safeBottom + 60.0);

    final double bottomPadding = safeBottom + 74.0;

    return Directionality(
      textDirection: TextDirection.rtl,
      child: Focus(
        focusNode: _focusNode,
        autofocus: true,
        onKeyEvent: _controlRLByKeyboard,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final double usableHeight = math.max(
                0.0, constraints.maxHeight - topPadding - bottomPadding);
            final bool isWideScreen = constraints.maxWidth > 650;
            final double pageContainerWidth = isWideScreen
                ? math.min(constraints.maxWidth, usableHeight * 0.72)
                : constraints.maxWidth;

            final viewportSize = Size(
              pageContainerWidth,
              usableHeight,
            );
            MushafProvider.instance.lastViewportSize = viewportSize;

            final double pageLabelLeft =
                isWideScreen && constraints.maxWidth > pageContainerWidth
                    ? ((constraints.maxWidth - pageContainerWidth) / 2 + 16.0)
                    : (safeLeft + 16.0);

            return Listener(
              onPointerSignal: _onPointerSignal,
              child: Stack(
                children: [
                  Padding(
                    padding:
                        EdgeInsets.only(top: topPadding, bottom: bottomPadding),
                    child: Center(
                      child: SizedBox(
                        width: pageContainerWidth,
                        child: _currentPageObject == null
                            ? const SizedBox.expand()
                            : AnimatedBuilder(
                                animation: _slideAnimation,
                                builder: (context, child) {
                                  if (!_slideController.isAnimating &&
                                      _slideAnimation.value == 1.0) {
                                    return child!;
                                  }
                                  final progress = _slideAnimation.value;
                                  final double offsetFraction =
                                      (1.0 - progress) *
                                          (-_activeSlideDir * 0.16);
                                  final double alpha =
                                      0.55 + 0.45 * progress;
                                  return Transform.translate(
                                    offset: Offset(
                                      offsetFraction * pageContainerWidth,
                                      0.0,
                                    ),
                                    child: Opacity(
                                      opacity: alpha.clamp(0.0, 1.0),
                                      child: child,
                                    ),
                                  );
                                },
                                child: RepaintBoundary(
                                  key: const ValueKey('mushaf_single_qvp_view'),
                                  child: QvpPageView(
                                    page: _currentPageObject!,
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
                                    onWordTap: (word, _) => _onWordTap(
                                      context,
                                      _currentPageObject!,
                                      word.index,
                                    ),
                                    onDecorationTap: (dec, _) =>
                                        _onDecorationTap(dec),
                                    onSwipe: (pages) => _stepPage(pages),
                                    underlay: _paintUnderlay,
                                    overlay: _paintOverlay,
                                    repaintListenable:
                                        _combinedRepaintListenable,
                                  ),
                                ),
                              ),
                      ),
                    ),
                  ),
                  if (isWideScreen && constraints.maxWidth > 750) ...[
                    // Left navigation button (Next page in RTL reading order)
                    Positioned(
                      left: math.max(
                          12.0,
                          (constraints.maxWidth - pageContainerWidth) / 4 -
                              24.0),
                      top: topPadding + usableHeight / 2 - 24.0,
                      child: IconButton(
                        icon: const Icon(Icons.arrow_back_ios_new_rounded),
                        color: c.textSecondary.withValues(alpha: 0.6),
                        hoverColor: c.gold.withValues(alpha: 0.15),
                        tooltip: 'الصفحة التالية • Next Page',
                        onPressed: _currentPage < QuranMetadata.maxPage ? _nextPage : null,
                      ),
                    ),
                    // Right navigation button (Previous page in RTL reading order)
                    Positioned(
                      right: math.max(
                          12.0,
                          (constraints.maxWidth - pageContainerWidth) / 4 -
                              24.0),
                      top: topPadding + usableHeight / 2 - 24.0,
                      child: IconButton(
                        icon: const Icon(Icons.arrow_forward_ios_rounded),
                        color: c.textSecondary.withValues(alpha: 0.6),
                        hoverColor: c.gold.withValues(alpha: 0.15),
                        tooltip: 'الصفحة السابقة • Previous Page',
                        onPressed: _currentPage > 1 ? _prevPage : null,
                      ),
                    ),
                  ],
                  if (widget.showBottomPageNumber)
                    AnimatedPositioned(
                      duration: const Duration(milliseconds: 320),
                      curve: Curves.easeInOutCubic,
                      left: pageLabelLeft,
                      bottom: pageLabelBottom,
                      child: ValueListenableBuilder<int>(
                        valueListenable: AppState.instance.currentMushafPage,
                        builder: (context, currentPage, _) {
                          final int page =
                              currentPage > 0 ? currentPage : _currentPage;
                          return Text(
                            QuranTypography.toArabicDigits(page),
                            textDirection: TextDirection.rtl,
                            textScaler: TextScaler.noScaling,
                            style: TextStyle(
                              fontFamily: 'cairo',
                              fontSize: 10.5,
                              fontWeight: FontWeight.w600,
                              color: c.textSecondary,
                              height: 1.0,
                            ),
                          );
                        },
                      ),
                    ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

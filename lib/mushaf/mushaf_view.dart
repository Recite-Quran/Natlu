import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
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

  List<int> _lastHiddenWords = const [];
  bool _hasMasks = false;

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
      value: 1.0,
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
      widget.controller,
      app.modeNotifier,
      app.blurModeNotifier,
      app.hasClickedTajweedNotifier,
      _yellowWordsNotifier,
    ]);

    widget.controller.addListener(_onControllerProgress);
    widget.controller.activeAyah.addListener(_onActiveAyahChanged);
    app.currentMushafPage.addListener(_onExternalPageChanged);
    app.themeNotifier.addListener(_syncVisuals);
    app.blurModeNotifier.addListener(_syncVisuals);
    app.modeNotifier.addListener(_syncVisuals);
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
      oldWidget.controller.removeListener(_onControllerProgress);
      oldWidget.controller.activeAyah.removeListener(_onActiveAyahChanged);
      widget.controller.addListener(_onControllerProgress);
      widget.controller.activeAyah.addListener(_onActiveAyahChanged);
      _syncVisuals();
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
            _syncVisuals();
          }
        });
      } else {
        _syncVisuals();
      }
    } else if (oldWidget.isRecording && !widget.isRecording) {
      _lastAdvancedSurah = null;
      _syncVisuals();
    }
  }

  void _onModalStateChanged() {
    if (!mounted) return;
    if (!AppModalRouteObserver.instance.isModalOpen && _needsSyncAfterModal) {
      _needsSyncAfterModal = false;
      _syncVisuals();
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

  void _debouncedSavePosition(int pageNum, [int? surah, int? ayah]) {
    _savePositionDebounce?.cancel();
    _savePositionDebounce = Timer(const Duration(milliseconds: 400), () {
      AppState.instance.saveMushafPage(pageNum);
      if (surah != null && ayah != null) {
        AppState.instance.saveLastPosition(surah, ayah);
      }
    });
  }

  @override
  void dispose() {
    _clearPageVisuals(_currentPageObject);
    _slideController.dispose();
    _spinnerController.dispose();
    _yellowWordsNotifier.dispose();
    AppModalRouteObserver.instance.activeModalsNotifier
        .removeListener(_onModalStateChanged);
    MaglisController.instance.sessionListenable
        .removeListener(_onMaglisSessionChanged);
    MaglisController.instance.onSyncMushafUI = null;
    _savePositionDebounce?.cancel();
    widget.controller.removeListener(_onControllerProgress);
    widget.controller.activeAyah.removeListener(_onActiveAyahChanged);
    final app = AppState.instance;
    app.currentMushafPage.removeListener(_onExternalPageChanged);
    app.themeNotifier.removeListener(_syncVisuals);
    app.blurModeNotifier.removeListener(_syncVisuals);
    app.modeNotifier.removeListener(_syncVisuals);
    _focusNode.dispose();
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
        nextSurah: nextSurah,
        isRecording: widget.isRecording,
      );
      _requestSyncVisuals();
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
        _isAdvancingSurah ||
        !provider.isReady) {
      return;
    }

    // Audio follow across page boundaries (when naturally listening to continuous recitation)
    if (widget.controller.isAudioActive) {
      final audioSurah = widget.controller.audioSurah;
      final audioAyah = widget.controller.audioAyah;
      if (audioSurah != null && audioAyah != null) {
        if (_lastProgressSurah == audioSurah && _lastProgressAyah == audioAyah) {
          return;
        }
        final bool wasFollowing = _lastProgressSurah != null &&
            provider.isAyahOnPage(
              pageNumber: _currentPage,
              surah: _lastProgressSurah!,
              ayah: _lastProgressAyah!,
            );
        _lastProgressSurah = audioSurah;
        _lastProgressAyah = audioAyah;

        if (wasFollowing &&
            !provider.isAyahOnPage(
              pageNumber: _currentPage,
              surah: audioSurah,
              ayah: audioAyah,
            )) {
          final nextPage = provider.getPageForAyah(audioSurah, audioAyah);
          if (nextPage != null && nextPage != _currentPage) {
            _navigationTargetAyah = (audioSurah, audioAyah);
            _goToPage(nextPage, animated: true);
          }
        }
      }
      return;
    }

    final ctrl = widget.controller;
    final int activeSurah =
        ctrl.targetSurah != 0 ? ctrl.targetSurah : AppState.instance.lastSurah;
    final int? activeAyah = ctrl.activeAyah.value;
    final int? activeWord = ctrl.activeWordIndex ??
        ctrl.getLeadWordIndex(
          surah: activeSurah,
          ayah: activeAyah ?? 0,
          totalWords: 999,
          isRecording: widget.isRecording,
        );
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

    // Visual synchronization (Unhide recited words live AND update yellow words for Tajweed tooltips)
    _syncVisuals();

    if (!widget.isRecording) return;

    // 1. Hands-free recitation flow across Surahs (only when reciting the final ayah of the surah)
    final bool isOnLastAyahOfSurah = activeAyah != null &&
        QuranMetadata.isLastAyahInSurah(activeSurah, activeAyah);
    final bool isLastAyahOfSurahCompleted = isOnLastAyahOfSurah &&
        (ctrl.completedAyahsFor(activeSurah).contains(activeAyah) ||
            ctrl.isSurahFinished(activeSurah));

    if (isOnLastAyahOfSurah && isLastAyahOfSurahCompleted) {
      if (activeSurah < QuranMetadata.maxSurah &&
          _lastAdvancedSurah != activeSurah) {
        _advanceToNextSurah(activeSurah);
        return;
      }
    } else {
      if (_lastAdvancedSurah == activeSurah) {
        _lastAdvancedSurah = null;
      }
    }
  }

  void _onExternalPageChanged() {
    if (!mounted) return;
    if (widget.controller.isAudioActive) return;
    final targetPage = AppState.instance.currentMushafPage.value;
    if (targetPage > 0 &&
        targetPage != _currentPage &&
        QuranMetadata.isValidPage(targetPage)) {
      _goToPage(targetPage, animated: true);
    }
  }

  int? _lastHandledAyah;
  int? _lastHandledSurah;

  void _onActiveAyahChanged() {
    if (!mounted) return;

    final activeAyah = widget.controller.activeAyah.value;
    final int activeSurah = widget.controller.targetSurah != 0
        ? widget.controller.targetSurah
        : AppState.instance.lastSurah;

    // Guard: skip all work if coord hasn't changed.
    // This prevents redundant FFI calls and word loops on every ASR phoneme tick.
    if (_lastHandledAyah == activeAyah && _lastHandledSurah == activeSurah) {
      return;
    }

    _lastHandledAyah = activeAyah;
    _lastHandledSurah = activeSurah;

    // Check spinner only when ayah coord actually changes (not every word tick).
    _checkSpinnerAnimation();

    if (activeAyah != null && activeSurah != 0) {
      final provider = MushafProvider.instance;
      if (provider.isReady &&
          !provider.isAyahOnPage(
            pageNumber: _currentPage,
            surah: activeSurah,
            ayah: activeAyah,
          )) {
        final targetPage = provider.getPageForAyah(activeSurah, activeAyah);
        if (targetPage != null && targetPage != _currentPage) {
          _navigationTargetAyah = (activeSurah, activeAyah);
          _goToPage(targetPage, animated: true);
          return;
        }
      }
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
        if (!widget.controller.isAudioActive) {
          if (widget.controller.activeAyah.value != target.$2 ||
              widget.controller.targetSurah != target.$1) {
            widget.controller.setManualAyah(target.$1, target.$2);
          }
        }
        return;
      }
    }

    // Preserve any existing selected ayah and save the page position.
    _debouncedSavePosition(pageNum);
  }

  void _stepPage(int dir) {
    final target = QuranMetadata.clampPage(_currentPage + dir);
    if (target == _currentPage) return;
    _navigationTargetAyah = null;
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
    if (AppState.instance.currentMushafPage.value != clamped) {
      AppState.instance.currentMushafPage.value = clamped;
    }
    _syncPageSelection(clamped);
    _loadCurrentPage(clamped, triggerSlide: animated);
  }

  Future<void> _loadCurrentPage(int pageNumber,
      {bool triggerSlide = false}) async {
    final cached = MushafProvider.instance.getCachedPage(pageNumber);
    if (cached != null && !cached.isDisposed) {
      _clearPageVisuals(_currentPageObject);
      _currentPageObject = cached;
      _checkSpinnerAnimation();
      _syncVisuals();
      if (triggerSlide && _turnDir != 0) {
        _triggerSlide();
      } else {
        _turnDir = 0;
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
      } else {
        _turnDir = 0;
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
    if (_hasMasks) {
      page.unmask();
      _hasMasks = false;
    }
    _lastHiddenWords = const [];
    if (_yellowWordsNotifier.value.isNotEmpty) {
      _yellowWordsNotifier.value = const [];
    }
  }

  // Visual synchronization & recitation highlights
  bool _needsSyncAfterModal = false;

  void _requestSyncVisuals() {
    if (!mounted) return;
    if (AppModalRouteObserver.instance.isModalOpen) {
      _needsSyncAfterModal = true;
      return;
    }
    _syncVisuals();
  }

  void _syncVisuals() {
    final page = _currentPageObject;
    if (page == null || page.isDisposed || !mounted) return;

    final app = AppState.instance;
    final ctrl = widget.controller;
    final bool isBlurEffective =
        app.isBlurEffective(isRecording: widget.isRecording);
    final bool needsTajweedTooltip =
        !app.hasClickedTajweedWord && app.currentMode == AppMode.tajweed;

    if (!isBlurEffective &&
        !needsTajweedTooltip &&
        !_hasMasks &&
        _yellowWordsNotifier.value.isEmpty) {
      return;
    }

    final int wordCount = page.words.length;
    final List<int> yellowWords = [];
    final List<int> hiddenWords = [];
    final Set<int> seenAyahsWithYellow = {};

    for (int i = 0; i < wordCount; i++) {
      final w = page.words[i];
      final int state =
          ctrl.getWordStatus(w.ayah, w.word - 1, surah: w.surah) ?? 0;

      if (needsTajweedTooltip && state == 2) {
        final ayahKey = QuranCoordinate.packAyahKey(w.surah, w.ayah);
        if (seenAyahsWithYellow.add(ayahKey)) {
          yellowWords.add(i);
        }
      } else if (isBlurEffective && state == 0) {
        hiddenWords.add(i);
      }
    }

    // Hifz Concealing masks (Native vector invisible ink)
    if (hiddenWords.isNotEmpty) {
      if (!listEquals(_lastHiddenWords, hiddenWords) || !_hasMasks) {
        page.mask(T.words(hiddenWords), 'hide');
        _hasMasks = true;
        _lastHiddenWords = List<int>.from(hiddenWords);
      }
    } else if (_hasMasks || _lastHiddenWords.isNotEmpty) {
      page.unmask();
      _hasMasks = false;
      _lastHiddenWords = const [];
    }

    // Notify Tajweed tooltips
    if (!listEquals(_yellowWordsNotifier.value, yellowWords)) {
      _yellowWordsNotifier.value = yellowWords;
    }
  }

  void _onWordTap(BuildContext context, QvpPage page, int wordIndex) {
    if (wordIndex < 0 || wordIndex >= page.words.length) return;
    final w = page.words[wordIndex];
    final surah = w.surah;
    final ayah = w.ayah;
    final wordIndex0 = w.word - 1;

    final maglis = MaglisController.instance;
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
      playWordDirectly: false,
    );
  }

  void _onDecorationTap(QvpDecorationInfo dec) {
    if (dec.surah > 0 && dec.ayah > 0) {
      AppHaptics.selectionClick();
      AppState.instance.markMushafAudioAyahClicked();
      QuranInteractionService.toggleAyahAudio(
        surah: dec.surah,
        ayah: dec.ayah,
        controller: widget.controller,
        isRecording: widget.isRecording,
      );
    }
  }

  void _paintUnderlay(
      ui.Canvas canvas, Size size, QvpPage page, QvpLayout? layout) {
    if (page.isDisposed) return;
    MushafOverlays.paintSurahHeaders(
      canvas,
      page,
      layout,
      isDark: AppState.instance.isDarkMode,
      colors: AppState.instance.colors,
    );
    MushafOverlays.paintAyahHighlights(
      canvas,
      page,
      layout,
      controller: widget.controller,
      app: AppState.instance,
      isRecording: widget.isRecording,
    );
  }

  void _paintOverlay(
      ui.Canvas canvas, Size size, QvpPage page, QvpLayout? layout) {
    if (page.isDisposed) return;
    final app = AppState.instance;
    final c = app.colors;
    final isDark = app.isDarkMode;
    final neutralRingColor = isDark
        ? const Color(0xFF94A3B8).withValues(alpha: 0.30)
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
          ? const Color(0xFF64748B).withValues(alpha: 0.20)
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
                        height: usableHeight,
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
                                  return Transform.translate(
                                    offset: Offset(
                                      offsetFraction * pageContainerWidth,
                                      0.0,
                                    ),
                                    child: child,
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
                                      maxAspectSlack: 0.0,
                                      surahFrames: false,
                                    ),
                                    hitMaxDistance: 28.0,
                                    paper: null,
                                    paperShadow: false,
                                    defaultInk: c.text,
                                    tashkeelInk: c.tashkeel,
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
                        onPressed: _currentPage < QuranMetadata.maxPage
                            ? _nextPage
                            : null,
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

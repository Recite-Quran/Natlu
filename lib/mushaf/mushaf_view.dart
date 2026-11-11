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
/// and the Swift DemoModel snapshot slide: the old page slides away over the
/// new page drawn beneath it (280 ms, easeInOut — identical to iOS).
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

class _MushafViewState extends State<MushafView> with SingleTickerProviderStateMixin {
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
              : -event.scrollDelta.dx;

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

    _spinnerController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    );

    final app = AppState.instance;
    // NOTE: _spinnerController is deliberately NOT in this merge. The
    // buffering spinner arc renders on its own tiny layer (see the
    // _BufferingSpinnerPainter in build), driven by the controller alone, so
    // its 60–120Hz ticks never re-record the whole page picture.
    _combinedRepaintListenable = Listenable.merge([
      widget.controller,
      app.modeNotifier,
      app.blurModeNotifier,
      app.hasClickedTajweedNotifier,
      _yellowWordsNotifier,
    ]);

    widget.controller.addListener(_onControllerProgress);
    widget.controller.activeAyah.addListener(_onActiveAyahChanged);
    app.currentMushafPage.addListener(_onExternalPageChanged);
    app.themeNotifier.addListener(_onVisualSettingsChanged);
    app.blurModeNotifier.addListener(_onVisualSettingsChanged);
    app.modeNotifier.addListener(_onVisualSettingsChanged);
    MaglisController.instance.sessionListenable
        .addListener(_onMaglisSessionChanged);
    AppModalRouteObserver.instance.activeModalsNotifier
        .addListener(_onModalStateChanged);

    MaglisController.instance.onSyncMushafUI = (page, surah, ayah) {
      if (!mounted) return;
      _navigationTargetAyah = (surah, ayah);
      if (QuranMetadata.isValidPage(page)) {
        if (page != _currentPage) {
          _goToPage(page);
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
      final int targetSurah = widget.controller.recitationCoordinate.$1;
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
    if (!AppModalRouteObserver.instance.isModalOpen) {
      final ctrl = widget.controller;
      final (int activeSurah, int? activeAyah) = ctrl.recitationCoordinate;
      if (ctrl.isCoordinateSettled &&
          (activeSurah != _lastHandledSurah || activeAyah != _lastHandledAyah)) {
        _onActiveAyahChanged();
      }
      if (_needsSyncAfterModal) {
        _needsSyncAfterModal = false;
        _syncVisuals();
      }
    }
  }

  int _findInitialPage() {
    final cachedPage = AppState.instance.currentMushafPage.value;
    if (cachedPage > 1 && QuranMetadata.isValidPage(cachedPage)) {
      return cachedPage;
    }
    final coord = widget.controller.recitationCoordinate;
    final surah = coord.$1;
    final ayah = coord.$2 ?? AppState.instance.lastAyah;
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
      if (!mounted || pageNum != _currentPage) return;
      AppState.instance.saveMushafPage(pageNum);
      if (surah != null && ayah != null) {
        AppState.instance.saveLastPosition(surah, ayah);
      }
    });
  }

  @override
  void dispose() {
    _clearPageVisuals(_currentPageObject);
    _spinnerController.dispose();
    _spinnerMark.dispose();
    _qvpViewCtrl.dispose();
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
    app.themeNotifier.removeListener(_onVisualSettingsChanged);
    app.blurModeNotifier.removeListener(_onVisualSettingsChanged);
    app.modeNotifier.removeListener(_onVisualSettingsChanged);
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
      // Same base page-sync rule as every other coordinate move.
      _syncPageFollow(nextSurah, 1);

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

    // NOTE: Page-turn sync is unified in _onActiveAyahChanged (_syncPageFollow).
    // Audio playback writes the same coordinate into the controller (activeAyah +
    // targetSurah — applyAudioProgress mirrors it), so it is followed by that one
    // rule like every other source. There is no audio-specific page branch here.

    final ctrl = widget.controller;
    final (int activeSurah, int? activeAyah) = ctrl.recitationCoordinate;

    // Follow settled coordinate if it changed (e.g. after surah retarget or manual selection)
    if (ctrl.isCoordinateSettled &&
        (activeSurah != _lastHandledSurah || activeAyah != _lastHandledAyah)) {
      _onActiveAyahChanged();
    }

    // One lead-word resolver for every source: audio cursor, peer's word, or
    // first unread while recording — decided by source priority inside it.
    final int? activeWord = ctrl.getLeadWordIndex(
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

    // Spinner start/stop also depends on audio state transitions that don't
    // move the coordinate (buffering -> playing on the same ayah), so check
    // it on every progress change; it is an O(1) guard when nothing changed.
    _checkSpinnerAnimation();

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
    final targetPage = AppState.instance.currentMushafPage.value;
    if (targetPage > 0 &&
        targetPage != _currentPage &&
        QuranMetadata.isValidPage(targetPage)) {
      _goToPage(targetPage);
    }
  }

  int? _lastHandledAyah;
  int? _lastHandledSurah;

  void _onActiveAyahChanged() {
    if (!mounted) return;

    // Do NOT process or record coordinate changes while the controller is retargeting.
    // Transient writes (null wipe, engine reset to 1) are merge noise.
    if (!widget.controller.isCoordinateSettled) {
      return;
    }

    final (int activeSurah, int? activeAyah) =
        widget.controller.recitationCoordinate;

    // Guard: skip all work if coord hasn't changed.
    // This prevents redundant FFI calls and word loops on every ASR phoneme tick.
    if (_lastHandledAyah == activeAyah && _lastHandledSurah == activeSurah) {
      return;
    }

    _lastHandledAyah = activeAyah;
    _lastHandledSurah = activeSurah;

    // Check spinner only when ayah coord actually changes (not every word tick).
    _checkSpinnerAnimation();

    // The one page-sync rule for every recitation source. Local ASR, audio
    // playback and Maglis packets all write the same coordinate into the
    // controller (activeAyah + targetSurah), so whenever that coordinate
    // changes, the mushaf follows it — through ayahs, pages and surahs — with
    // no per-source branch. A manual page turn never rewrites the coordinate:
    // the newest event wins, each event only applies once, as it is received.
    _syncPageFollow(activeSurah, activeAyah);

    _requestSyncVisuals();
  }

  /// Follows the controller's current coordinate to its page. This is the only
  /// place a source (audio playback, local ASR recitation, Maglis packets)
  /// moves the mushaf by itself: they all write (surah, ayah) into the
  /// controller, so the rule is source-agnostic.
  void _syncPageFollow(int surah, int? ayah) {
    // One base rule for every source: never chase the coordinate while the
    // controller is mid-merge — a surah retarget emits transient writes
    // (null wipe, engine reset to ayah 1) through the shared coordinate.
    // The merge's final write re-broadcasts the settled coordinate, which
    // re-triggers this method with the truth.
    if (!widget.controller.isCoordinateSettled) return;
    final provider = MushafProvider.instance;
    if (surah == 0 || ayah == null || !provider.isReady) return;
    if (provider.isAyahOnPage(
      pageNumber: _currentPage,
      surah: surah,
      ayah: ayah,
    )) {
      return;
    }
    final targetPage = provider.getPageForAyah(surah, ayah);
    if (targetPage == null || targetPage == _currentPage) return;
    _navigationTargetAyah = (surah, ayah);
    _goToPage(targetPage);
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
      _updateSpinnerMark(page, surah, ayah);
    } else {
      if (_spinnerController.isAnimating) {
        _spinnerController.stop();
      }
      _spinnerMark.value = null;
      _spinnerMarkKey = null;
    }
  }

  // Isolated buffering-spinner layer state: cached mark geometry plus the
  // key it was computed for, so word ticks during buffering hit an O(1)
  // identity guard instead of an FFI mark scan.
  //
  // The mark is a ValueNotifier, not a plain field: the presence/absence of
  // the arc layer must be reactive. A plain field clear happens with no
  // rebuild attached, so the arc widget would stay in the tree — frozen on
  // screen forever after buffering ends. The builder below reads the
  // geometry once per mark change; per-frame rotation stays on
  // _spinnerController.
  final ValueNotifier<({Offset center, double radius})?> _spinnerMark =
      ValueNotifier(null);
  ({int surah, int ayah, QvpPage page})? _spinnerMarkKey;

  /// Shared view controller for the single-page Qvp view. The page view's fit
  /// writes `view px = offsetX + scale · layout px` into it (page_view.dart's
  /// fit path); the buffering-spinner painter reads the same values at paint
  /// time, so the arc lands exactly on the ayah mark instead of in raw layout
  /// space — the fit transform is part of the page's geometry, not optional.
  final QvpViewController _qvpViewCtrl = QvpViewController();

  /// Caches the buffering ayah mark's geometry for the spinner layer: zero
  /// FFI and zero allocation per animation tick. The FFI mark scan runs only
  /// when the buffering ayah or page actually changes.
  void _updateSpinnerMark(QvpPage page, int surah, int ayah) {
    final key = (surah: surah, ayah: ayah, page: page);
    if (_spinnerMarkKey == key && _spinnerMark.value != null) return;
    _spinnerMarkKey = key;
    _spinnerMark.value = null;
    for (final m in page.ayahMarksView()) {
      if (widget.controller.isAyahAudioBuffering(m.surah, m.ayah)) {
        _spinnerMark.value = (center: Offset(m.cx, m.cy), radius: m.r * 0.80);
        return;
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

    // Manual page turn: the page never rewrites the recitation coordinate —
    // the coordinate belongs to the session (selection, ASR anchor, audio,
    // Maglis), the page is only the viewport. Swiping away leaves the anchor
    // in place: the active-ayah band and lead word stay bound to it, and the
    // moment the live source's next word lands, the newest event wins and
    // the view follows it. Clearing here used to orphan the anchor — after
    // swiping back, no coordinate existed to paint, and the highlight only
    // reappeared once the reciter's first word re-created it.

    // Preserve any existing selected ayah and save the page position.
    _debouncedSavePosition(pageNum);
  }

  void _stepPage(int dir) {
    final target = QuranMetadata.clampPage(_currentPage + dir);
    if (target == _currentPage) return;
    _savePositionDebounce?.cancel();
    _navigationTargetAyah = null;
    _goToPage(target);
  }

  void _nextPage() {
    _navigationTargetAyah = null;
    _stepPage(1);
  }

  void _prevPage() {
    _navigationTargetAyah = null;
    _stepPage(-1);
  }

  void _goToPage(int page) {
    _savePositionDebounce?.cancel();
    final clamped = QuranMetadata.clampPage(page);
    if (clamped == _currentPage && _currentPageObject != null) return;

    _syncPageSelection(clamped);
    MushafProvider.instance.preloadAdjacentPages(
      clamped,
      MushafProvider.instance.lastViewportSize,
    );

    _currentPage = clamped;
    if (AppState.instance.currentMushafPage.value != clamped) {
      AppState.instance.currentMushafPage.value = clamped;
    }
    _loadCurrentPage(clamped);
  }

  Future<void> _loadCurrentPage(int pageNumber) async {
    final cached = MushafProvider.instance.getCachedPage(pageNumber);
    if (cached != null && !cached.isDisposed) {
      _clearPageVisuals(_currentPageObject);
      _currentPageObject = cached;
      _checkSpinnerAnimation();
      _syncVisuals();
      if (mounted) setState(() {});
    } else {
      final p = await MushafProvider.instance.getPage(pageNumber);
      if (!mounted || pageNumber != _currentPage) return;
      _clearPageVisuals(_currentPageObject);
      _currentPageObject = p;
      _checkSpinnerAnimation();
      _syncVisuals();
      if (mounted) setState(() {});
    }
  }

  void _clearPageVisuals(QvpPage? page) {
    if (page == null || page.isDisposed) return;
    if (_hasMasks) {
      page.unmask();
      _hasMasks = false;
    }
    _lastHiddenWords = const [];
    _spinnerMark.value = null;
    _spinnerMarkKey = null;
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

  void _onVisualSettingsChanged() {
    _syncVisuals();
    if (mounted) {
      setState(() {});
      MushafProvider.instance.preloadAdjacentPages(_currentPage);
    }
  }

  void _syncVisuals() {
    final page = _currentPageObject;
    if (page == null || page.isDisposed || !mounted) return;

    final app = AppState.instance;
    final ctrl = widget.controller;
    final bool isSessionActive =
        widget.isRecording || MaglisController.instance.inSession;
    final bool isBlurEffective =
        app.isBlurEffective(isRecording: isSessionActive);
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
    int effectiveIndex = wordIndex;
    var w = page.words[effectiveIndex];
    var surah = w.surah;
    var ayah = w.ayah;
    var wordIndex0 = w.word - 1;

    bool isWordYellow(int a, int w0, int s) =>
        widget.controller.isWordYellow(a, w0, surah: s);

    // Proximity snap: if tapped adjacent to a yellow word on the same line, snap to it.
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

    QuranInteractionService.handleWordTap(
      context: context,
      surah: surah,
      ayah: ayah,
      wordIndex: wordIndex0,
      wordText: w.text,
      controller: widget.controller,
      isRecording: widget.isRecording,
      onAyahTap: () => setState(() {}),
    );
  }

  void _onDecorationTap(QvpDecorationInfo dec) {
    if (dec.surah > 0 && dec.ayah > 0) {
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
    final app = AppState.instance;
    final c = app.colors;

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
                            : Stack(
                                clipBehavior: Clip.none,
                                children: [
                                  // Base layer: The current page (already drawn beneath)
                                  RepaintBoundary(
                                    key: const ValueKey('mushaf_single_qvp_view'),
                                    child: QvpPageView(
                                      page: _currentPageObject!,
                                      controller: _qvpViewCtrl,
                                      panZoomEnabled: false,
                                      selectionEnabled: false,
                                      layout: MushafProvider.mushafLayout,
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
                                  // Isolated buffering-spinner layer: paints only the
                                  // rotating arc at the cached mark position. Its
                                  // repaint listenable is the spinner controller
                                  // alone, so spinner ticks (60–120Hz) repaint this
                                  // tiny layer — never the page picture. Layer
                                  // presence is driven by the mark ValueNotifier,
                                  // so the arc is removed from the tree the moment
                                  // buffering ends.
                                  ValueListenableBuilder<
                                      ({Offset center, double radius})?>(
                                    valueListenable: _spinnerMark,
                                    builder: (context, spinnerMark, _) =>
                                        spinnerMark == null
                                            ? const SizedBox.shrink()
                                            : Positioned.fill(
                                                child: IgnorePointer(
                                                  child: RepaintBoundary(
                                                    child: CustomPaint(
                                                      painter:
                                                          _BufferingSpinnerPainter(
                                                        spinner:
                                                            _spinnerController,
                                                        viewCtrl: _qvpViewCtrl,
                                                        center: spinnerMark
                                                            .center,
                                                        ringRadius:
                                                            spinnerMark.radius,
                                                        color: c.primary,
                                                      ),
                                                    ),
                                                  ),
                                                ),
                                              ),
                                  ),
                                ],
                              ),
                      ),
                    ),
                  ),
                  if (widget.showBottomPageNumber)
                    Positioned(
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

/// Isolated buffering-spinner layer: paints ONLY the rotating arc, at the
/// cached mark geometry, in the same layout coordinate space the page's
/// overlay painters use. Repaint is driven by the spinner controller alone,
/// so its ticks cost one tiny arc draw instead of a full page re-record.
class _BufferingSpinnerPainter extends CustomPainter {
  _BufferingSpinnerPainter({
    required AnimationController spinner,
    required QvpViewController viewCtrl,
    required this.center,
    required this.ringRadius,
    required this.color,
  }) : _spinner = spinner,
       _viewCtrl = viewCtrl,
       super(repaint: spinner);

  final AnimationController _spinner;

  /// The page view's live fit transform (`view px = offset + scale · layout
  /// px`). Read at paint time, never cached: a viewport resize re-fits before
  /// the next spinner tick, so the arc stays glued to the ayah mark.
  final QvpViewController _viewCtrl;
  final Offset center;
  final double ringRadius;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (ringRadius <= 0) return;
    final double scale = _viewCtrl.scale;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..color = color
      ..strokeWidth = math.max(ringRadius * scale * 0.18, 1.4);
    canvas.drawArc(
      Rect.fromCircle(
        center: Offset(
          _viewCtrl.offsetX + center.dx * scale,
          _viewCtrl.offsetY + center.dy * scale,
        ),
        radius: ringRadius * scale * 0.58,
      ),
      _spinner.value * 2 * math.pi,
      2.4,
      false,
      paint,
    );
  }

  // Repaint comes from the controller listenable; painter identity changes
  // (new center/radius/color) rebuild the widget instead.
  @override
  bool shouldRepaint(_BufferingSpinnerPainter old) => false;
}

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:recite_quran/recite_quran.dart';

import '../../../state/app_state.dart';
import '../../../maglis/maglis_controller.dart';
import 'mushaf_actions.dart';
import 'mushaf_page.dart';
import 'mushaf_provider.dart';

export 'mushaf_page.dart';
export 'mushaf_provider.dart';

/// Desktop & Mobile friendly scroll behavior allowing mouse/touch drag on PageView.
class MushafScrollBehavior extends MaterialScrollBehavior {
  const MushafScrollBehavior();

  @override
  Set<PointerDeviceKind> get dragDevices => {
        PointerDeviceKind.touch,
        PointerDeviceKind.mouse,
        PointerDeviceKind.trackpad,
        PointerDeviceKind.stylus,
      };
}


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
  static set isSyncingSurah(bool v) => MushafProvider.instance.isSyncingSurah = v;

  static void preloadData() => MushafProvider.instance.preloadData();

  static (int surah, int ayah)? getFirstAyahOnPage(int pageNumber) =>
      MushafProvider.instance.getFirstAyahOnPage(pageNumber);

  static int? getDominantSurahOnPage(int pageNumber) =>
      MushafProvider.instance.getDominantSurahOnPage(pageNumber);

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

class _MushafViewState extends State<MushafView> {
  late PageController _pageController;
  int _currentPage = 1;
  bool _isLoading = true;
  final FocusNode _focusNode = FocusNode();
  (int surah, int ayah)? _navigationTargetAyah;
  Timer? _savePositionDebounce;
  int? _lastAutoAdvancedFromPage;
  bool _isAutoAdvancingPage = false;
  int? _lastAdvancedSurah;
  bool _isAdvancingSurah = false;

  KeyEventResult _controlRLByKeyboard(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (!_pageController.hasClients) return KeyEventResult.ignored;

    if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      _nextPage();
      return KeyEventResult.handled;
    } else if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
      _prevPage();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  void initState() {
    super.initState();
    final provider = MushafProvider.instance;
    _currentPage = _findInitialPage();
    _pageController = PageController(initialPage: 604 - _currentPage);
    _isLoading = !provider.isReady;

    widget.controller.activeAyah.addListener(_onActiveAyahChanged);
    widget.controller.addListener(_onControllerProgress);
    AppState.instance.activeAudioAyah.addListener(_onAudioAyahChanged);
    AppState.instance.activeAudioSurah.addListener(_onAudioAyahChanged);
    MaglisController.instance.addListener(_onMaglisSessionChanged);

    MaglisController.instance.onSyncMushafUI = (page, surah, ayah) {
      if (!mounted) return;
      if (page != _currentPage && page >= 1 && page <= 604) {
        _goToPage(page);
      }
    };

    if (provider.isReady) {
      _isLoading = false;
    } else {
      _initMushafData();
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        AppState.instance.currentMushafPage.value = _currentPage;
        MushafProvider.instance.preloadAdjacentPages(_currentPage);
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
      widget.controller.activeAyah.addListener(_onActiveAyahChanged);
      widget.controller.addListener(_onControllerProgress);
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
          if (mounted) setState(() {});
        });
      }
    } else if (oldWidget.isRecording && !widget.isRecording) {
      _lastAutoAdvancedFromPage = null;
      _lastAdvancedSurah = null;
    }
  }

  int _findInitialPage() {
    final cachedPage = AppState.instance.currentMushafPage.value;
    if (cachedPage > 1 && cachedPage <= 604) {
      return cachedPage;
    }
    final surah = widget.controller.targetSurah != 0
        ? widget.controller.targetSurah
        : AppState.instance.lastSurah;
    final ayah = widget.controller.activeAyah.value ?? AppState.instance.lastAyah;
    final provider = MushafProvider.instance;
    final mapped = provider.getPageForAyah(surah, ayah) ?? provider.getPageForAyah(surah, 1);
    if (mapped != null && mapped >= 1 && mapped <= 604) {
      return mapped;
    }
    return cachedPage.clamp(1, 604);
  }

  Future<void> _initMushafData() async {
    await MushafProvider.instance.loadData();
    if (mounted) {
      final initialPage = _findInitialPage();
      _currentPage = initialPage;
      AppState.instance.currentMushafPage.value = _currentPage;
      final targetIndex = 604 - _currentPage;
      if (_pageController.hasClients) {
        if ((_pageController.page?.round() ?? 0) != targetIndex) {
          _pageController.jumpToPage(targetIndex);
        }
      }
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
    MaglisController.instance.removeListener(_onMaglisSessionChanged);
    MaglisController.instance.onSyncMushafUI = null;
    _savePositionDebounce?.cancel();
    widget.controller.activeAyah.removeListener(_onActiveAyahChanged);
    widget.controller.removeListener(_onControllerProgress);
    AppState.instance.activeAudioAyah.removeListener(_onAudioAyahChanged);
    AppState.instance.activeAudioSurah.removeListener(_onAudioAyahChanged);
    _pageController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _onMaglisSessionChanged() {
    if (mounted) setState(() {});
  }

  bool _isSurahFinished(HighlightingController ctrl, int surah) {
    if (surah < 1 || surah > 114) return false;
    final surahWords = ctrl.repository.getSurahWords(surah);
    if (surahWords.isEmpty) return false;
    final lastWord = surahWords.last;
    return ctrl.completedAyahsFor(surah).contains(lastWord.ayah) ||
        ctrl.isWordGreen(lastWord.ayah, lastWord.wordInAyah, surah: surah) ||
        ctrl.isWordYellow(lastWord.ayah, lastWord.wordInAyah, surah: surah) ||
        ctrl.isWordNeutral(lastWord.ayah, lastWord.wordInAyah, surah: surah);
  }

  Future<void> _advanceToNextSurah(int currentSurah) async {
    if (_isAdvancingSurah || !mounted || !widget.isRecording) return;
    final int nextSurah = currentSurah + 1;
    if (nextSurah > 114) return;

    _isAdvancingSurah = true;
    _lastAdvancedSurah = currentSurah;

    try {
      final provider = MushafProvider.instance;
      final ctrl = widget.controller;
      const int nextAyah = 1;

      final targetPage = provider.getPageForAyah(nextSurah, nextAyah);
      if (targetPage != null && targetPage != _currentPage) {
        _navigationTargetAyah = (nextSurah, nextAyah);
        _goToPage(targetPage);
      }

      await ctrl.setTargetSurah(
        nextSurah,
        preserveOtherSurahStates: true,
        clearTargetSurah: false,
      );
      ctrl.setManualAyah(nextSurah, nextAyah);
      AppState.instance.saveLastPosition(nextSurah, nextAyah);
      if (widget.isRecording) {
        ctrl.startRecordingSession();
      }
    } catch (e) {
      debugPrint('Error advancing to next surah: $e');
    } finally {
      await Future.delayed(const Duration(milliseconds: 300));
      _isAdvancingSurah = false;
    }
  }

  void _onControllerProgress() {
    final provider = MushafProvider.instance;
    if (!mounted ||
        _isAutoAdvancingPage ||
        _isAdvancingSurah ||
        !provider.isReady ||
        !widget.isRecording) {
      return;
    }

    final ctrl = widget.controller;
    final int activeSurah = ctrl.targetSurah != 0
        ? ctrl.targetSurah
        : AppState.instance.lastSurah;

    // 1. Hands-free recitation flow across Surahs (same page or next page)
    if (_isSurahFinished(ctrl, activeSurah)) {
      if (activeSurah < 114 && _lastAdvancedSurah != activeSurah) {
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

    final int? activeAyah = ctrl.activeAyah.value;

    if (activeAyah != null &&
        (activeSurah != lastWord.surah || activeAyah != lastWord.ayah) &&
        provider.isAyahOnPage(
          pageNumber: _currentPage,
          surah: activeSurah,
          ayah: activeAyah,
        )) {
      _lastAutoAdvancedFromPage = null;
    }

    final bool isLastWordFinished = ctrl.isWordGreen(
            lastWord.ayah, lastWord.wordIndex0, surah: lastWord.surah) ||
        ctrl.isWordNeutral(
            lastWord.ayah, lastWord.wordIndex0, surah: lastWord.surah) ||
        ctrl.isWordYellow(
            lastWord.ayah, lastWord.wordIndex0, surah: lastWord.surah) ||
        ctrl.completedAyahsFor(lastWord.surah).contains(lastWord.ayah);

    final int nextPage = _currentPage + 1;
    if (nextPage > 604) return;

    final bool isRecitingNextPage = activeAyah != null &&
        provider.isAyahOnPage(
          pageNumber: nextPage,
          surah: activeSurah,
          ayah: activeAyah,
        );

    final bool shouldAdvance =
        (isLastWordFinished || isRecitingNextPage) &&
        _lastAutoAdvancedFromPage != _currentPage;

    if (!shouldAdvance) {
      if (!isLastWordFinished && !isRecitingNextPage && _lastAutoAdvancedFromPage == _currentPage) {
        _lastAutoAdvancedFromPage = null;
      }
      return;
    }

    _advanceToPage(nextPage);
  }

  Future<void> _advanceToPage(int nextPage) async {
    final provider = MushafProvider.instance;
    final nextFirst = provider.getFirstAyahOnPage(nextPage);
    if (nextFirst == null) return;

    final int nextSurah = nextFirst.$1;
    final int nextAyah = nextFirst.$2;

    _lastAutoAdvancedFromPage = _currentPage;
    _isAutoAdvancingPage = true;

    try {
      final ctrl = widget.controller;
      _navigationTargetAyah = (nextSurah, nextAyah);
      _goToPage(nextPage);

      if (nextSurah != ctrl.targetSurah) {
        await ctrl.setTargetSurah(
          nextSurah,
          preserveOtherSurahStates: true,
          clearTargetSurah: false,
        );
        ctrl.setManualAyah(nextSurah, nextAyah);
        AppState.instance.saveLastPosition(nextSurah, nextAyah);
        if (widget.isRecording) {
          ctrl.startRecordingSession();
        }
      } else {
        if (ctrl.activeAyah.value != nextAyah) {
          ctrl.setManualAyah(nextSurah, nextAyah);
          AppState.instance.saveLastPosition(nextSurah, nextAyah);
        }
      }
    } catch (e) {
      debugPrint('Error advancing page on last word: $e');
    } finally {
      await Future.delayed(const Duration(milliseconds: 300));
      _isAutoAdvancingPage = false;
    }
  }

  void _onAudioAyahChanged() {
    final provider = MushafProvider.instance;
    final active = AppState.instance.activeAudioAyah.value;
    final surah = AppState.instance.activeAudioSurah.value;
    if (active != null && surah != null && provider.isReady) {
      if (provider.isAyahOnPage(
        pageNumber: _currentPage,
        surah: surah,
        ayah: active,
      )) {
        _navigationTargetAyah = null;
        return;
      }
      final targetPage = provider.getPageForAyah(surah, active);
      if (targetPage != null && targetPage != _currentPage) {
        _navigationTargetAyah = (surah, active);
        _goToPage(targetPage);
      }
    }
  }

  void _onActiveAyahChanged() {
    final provider = MushafProvider.instance;
    if (provider.isSyncingSurah || _isAutoAdvancingPage) return;
    final active = widget.controller.activeAyah.value;
    if (active != null) {
      final surah = widget.controller.targetSurah;
      AppState.instance.saveLastPosition(surah, active);

      if (provider.isAyahOnPage(
        pageNumber: _currentPage,
        surah: surah,
        ayah: active,
      )) {
        _navigationTargetAyah = null;
        return;
      }

      if (provider.isReady) {
        final targetPage = provider.getPageForAyah(surah, active);
        if (targetPage != null && targetPage != _currentPage) {
          _navigationTargetAyah = (surah, active);
          _goToPage(targetPage);
        }
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

  void _goToPage(int page) {
    final clamped = page.clamp(1, 604);
    if (clamped == _currentPage) return;
    final pageDiff = (clamped - _currentPage).abs();
    _currentPage = clamped;
    AppState.instance.currentMushafPage.value = clamped;
    MushafProvider.instance.preloadAdjacentPages(clamped);
    if (_pageController.hasClients) {
      final targetIndex = 604 - clamped;
      if (pageDiff > 1) {
        _pageController.jumpToPage(targetIndex);
      } else {
        _pageController.animateToPage(
          targetIndex,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOut,
        );
      }
    }
    _syncPageSelection(clamped);
  }

  void _onPageChanged(int pageIndex) {
    final newPage = 604 - pageIndex;
    if (_currentPage == newPage) return;
    _currentPage = newPage;
    _navigationTargetAyah = null;
    AppState.instance.currentMushafPage.value = newPage;
    _syncPageSelection(newPage);
    MushafProvider.instance.preloadAdjacentPages(
      newPage,
      MushafProvider.instance.lastViewportSize,
    );
  }

  void _goToNextPage() {
    if (_currentPage < 604) {
      _pageController.previousPage(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    }
  }

  void _goToPreviousPage() {
    if (_currentPage > 1) {
      _pageController.nextPage(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    }
  }

  void _nextPage() {
    if (_currentPage < 604) {
      _navigationTargetAyah = null;
      _goToNextPage();
    }
  }

  void _prevPage() {
    if (_currentPage > 1) {
      _navigationTargetAyah = null;
      _goToPreviousPage();
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = AppState.instance.colors;

    if (_isLoading) {
      return Center(
        child: CircularProgressIndicator.adaptive(
          valueColor: AlwaysStoppedAnimation<Color>(c.gold),
        ),
      );
    }

    final padding = MediaQuery.paddingOf(context);
    final viewPadding = MediaQuery.viewPaddingOf(context);
    final safeTop = math.max(padding.top, viewPadding.top);
    final safeBottom = math.max(padding.bottom, viewPadding.bottom);
    final safeLeft = math.max(padding.left, viewPadding.left);

    // Stretch to the top: on notch/cutout devices, safeTop protects the notch/status bar.
    // Adding a tight 4.0dp buffer (or 8.0dp when safeTop == 0 on desktop/immersive) prevents
    // collision while maximizing vertical screen space.
    final double topPadding = safeTop > 0 ? safeTop + 4.0 : 8.0;

    // Bar dock: height = 46dp, bottom margin = 10dp.
    // Idle: page number sits just above the dock band (safeBottom + 60dp).
    // Recording/Maglis: page number drops into the left clearance (safeBottom + 27dp).
    final bool isSessionActive = widget.isRecording || MaglisController.instance.inSession;

    final double pageLabelBottom = isSessionActive
        ? (safeBottom + 27.0)
        : (safeBottom + 60.0);

    // Content bottom padding keeps ayahs clear of the bar:
    final double bottomPadding = isSessionActive
        ? (safeBottom + 62.0)
        : (safeBottom + 74.0);



    return Directionality(
      textDirection: TextDirection.rtl,
      child: Focus(
        focusNode: _focusNode,
        autofocus: true,
        onKeyEvent: _controlRLByKeyboard,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final viewportSize = Size(
              constraints.maxWidth,
              constraints.maxHeight - topPadding - bottomPadding,
            );
            MushafProvider.instance.lastViewportSize = viewportSize;

            return Stack(
              children: [
                AnimatedPadding(
                  duration: const Duration(milliseconds: 320),
                  curve: Curves.easeInOutCubic,
                  padding: EdgeInsets.only(top: topPadding, bottom: bottomPadding),
                  child: ScrollConfiguration(
                    behavior: const MushafScrollBehavior(),
                    child: Directionality(
                      textDirection: TextDirection.ltr,
                      child: PageView.builder(
                        key: const ValueKey('mushaf_single_page_view'),
                        controller: _pageController,
                        reverse: false,
                        itemCount: 604,
                        padEnds: false,
                        allowImplicitScrolling: true,
                        onPageChanged: _onPageChanged,
                        itemBuilder: (context, index) {
                          final pageNumber = 604 - index;
                          return RepaintBoundary(
                            key: ValueKey('mushaf_page_boundary_$pageNumber'),
                            child: MushafPageWidget(
                              key: ValueKey('mushaf_page_$pageNumber'),
                              pageNumber: pageNumber,
                              controller: widget.controller,
                              isRecording: widget.isRecording,
                              onStateChangeRequested: () {},
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                ),
                if (widget.showBottomPageNumber)
                  AnimatedPositioned(
                    duration: const Duration(milliseconds: 320),
                    curve: Curves.easeInOutCubic,
                    left: safeLeft + 16.0,
                    bottom: pageLabelBottom,
                    child: ValueListenableBuilder<int>(
                      valueListenable: AppState.instance.currentMushafPage,
                      builder: (context, currentPage, _) {
                        final int page = currentPage > 0 ? currentPage : _currentPage;
                        return Text(
                          MushafActions.toArabicDigits(page),
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
            );
          },
        ),
      ),
    );
  }
}

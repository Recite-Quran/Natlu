import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:recite_quran/recite_quran.dart';

import '../../../state/app_state.dart';
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


/// Exact replica of PatchedPreloadPageView from quran_library (alquranalkareem).
/// Uses Viewport with CacheExtentStyle.viewport to ensure 2 pages ahead and behind are always
/// fully mounted and rasterized in GPU layers before any swipe gesture begins.
class PatchedPreloadPageView extends StatefulWidget {
  PatchedPreloadPageView.builder({
    super.key,
    this.scrollDirection = Axis.horizontal,
    this.reverse = false,
    required this.controller,
    this.physics,
    this.pageSnapping = true,
    this.onPageChanged,
    required IndexedWidgetBuilder itemBuilder,
    int? itemCount,
    this.preloadPagesCount = 2,
    this.padEnds = false,
  }) : childrenDelegate =
            SliverChildBuilderDelegate(itemBuilder, childCount: itemCount);

  final Axis scrollDirection;
  final bool reverse;
  final PageController controller;
  final ScrollPhysics? physics;
  final bool pageSnapping;
  final ValueChanged<int>? onPageChanged;
  final SliverChildDelegate childrenDelegate;
  final int preloadPagesCount;
  final bool padEnds;

  @override
  State<PatchedPreloadPageView> createState() => _PatchedPreloadPageViewState();
}

class _PatchedPreloadPageViewState extends State<PatchedPreloadPageView> {
  int _lastReportedPage = 0;

  @override
  void initState() {
    super.initState();
    _lastReportedPage = widget.controller.initialPage;
  }

  AxisDirection _getDirection(BuildContext context) {
    switch (widget.scrollDirection) {
      case Axis.horizontal:
        assert(debugCheckHasDirectionality(context));
        final TextDirection textDirection = Directionality.of(context);
        final AxisDirection axisDirection =
            textDirectionToAxisDirection(textDirection);
        return widget.reverse
            ? flipAxisDirection(axisDirection)
            : axisDirection;
      case Axis.vertical:
        return widget.reverse ? AxisDirection.up : AxisDirection.down;
    }
  }

  @override
  Widget build(BuildContext context) {
    final AxisDirection axisDirection = _getDirection(context);
    final ScrollPhysics? physics = widget.pageSnapping
        ? const PageScrollPhysics().applyTo(widget.physics)
        : widget.physics;

    final int preload = widget.preloadPagesCount;

    return NotificationListener<ScrollNotification>(
      onNotification: (ScrollNotification notification) {
        if (notification.depth == 0 &&
            widget.onPageChanged != null &&
            notification is ScrollUpdateNotification) {
          final int currentPage =
              widget.controller.page?.round() ?? _lastReportedPage;
          if (currentPage != _lastReportedPage) {
            _lastReportedPage = currentPage;
            widget.onPageChanged!(currentPage);
          }
        }
        return false;
      },
      child: Scrollable(
        axisDirection: axisDirection,
        controller: widget.controller,
        physics: physics,
        viewportBuilder: (BuildContext context, ViewportOffset position) {
          return Viewport(
            scrollCacheExtent: ScrollCacheExtent.viewport(
              preload < 1 ? 0.0 : preload.toDouble(),
            ),
            axisDirection: axisDirection,
            offset: position,
            slivers: <Widget>[
              SliverFillViewport(
                viewportFraction: widget.controller.viewportFraction,
                padEnds: widget.padEnds,
                delegate: widget.childrenDelegate,
              ),
            ],
          );
        },
      ),
    );
  }
}

/// High-performance Mushaf View layout backed by qvp_flutter.
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
    _pageController = PageController(initialPage: _currentPage - 1);
    _isLoading = !provider.isReady;

    widget.controller.activeAyah.addListener(_onActiveAyahChanged);
    widget.controller.addListener(_onControllerProgress);
    AppState.instance.activeAudioAyah.addListener(_onAudioAyahChanged);
    AppState.instance.activeAudioSurah.addListener(_onAudioAyahChanged);

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
      final targetIndex = _currentPage - 1;
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
    _savePositionDebounce?.cancel();
    widget.controller.activeAyah.removeListener(_onActiveAyahChanged);
    widget.controller.removeListener(_onControllerProgress);
    AppState.instance.activeAudioAyah.removeListener(_onAudioAyahChanged);
    AppState.instance.activeAudioSurah.removeListener(_onAudioAyahChanged);
    _pageController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _onControllerProgress() {
    final provider = MushafProvider.instance;
    if (!mounted || _isAutoAdvancingPage || !provider.isReady || !widget.isRecording) return;

    final ctrl = widget.controller;
    final lastWord = provider.getLastWordOnPage(_currentPage);
    if (lastWord == null) return;

    final int? activeAyah = ctrl.activeAyah.value;
    final int activeSurah = ctrl.targetSurah != 0
        ? ctrl.targetSurah
        : AppState.instance.lastSurah;

    if (activeAyah != null &&
        activeAyah != lastWord.ayah &&
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
      if (pageDiff > 1) {
        _pageController.jumpToPage(clamped - 1);
      } else {
        _pageController.animateToPage(
          clamped - 1,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOut,
        );
      }
    }
    _syncPageSelection(clamped);
  }

  void _nextPage() {
    if (_currentPage < 604) {
      _navigationTargetAyah = null;
      _goToPage(_currentPage + 1);
    }
  }

  void _prevPage() {
    if (_currentPage > 1) {
      _navigationTargetAyah = null;
      _goToPage(_currentPage - 1);
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

    final media = MediaQuery.of(context);
    final safeTop = math.max(media.padding.top, media.viewPadding.top);
    final safeBottom = math.max(media.padding.bottom, media.viewPadding.bottom);
    final safeLeft = math.max(media.padding.left, media.viewPadding.left);

    // Stretch to the top: on notch/cutout devices, safeTop protects the notch/status bar.
    // Adding a tight 4.0dp buffer (or 8.0dp when safeTop == 0 on desktop/immersive) prevents
    // collision while maximizing vertical screen space.
    final double topPadding = safeTop > 0 ? safeTop + 4.0 : 8.0;

    // Bottom command dock is at safeBottom + 14.0 (margin) + 56.0 (height) = safeBottom + 70.0.
    // When idle: page number sits snugly 1.5dp above the dock at the bottom-left (safeBottom + 71.5).
    // When recording: toolbar collapses to the center, so page number drops down to be
    // vertically centered with the 56dp bottom bar at the left:
    // safeBottom + 14.0 + (56.0 - 10.5) / 2 = safeBottom + 36.75 ~ safeBottom + 36.5.
    final double pageLabelBottom = widget.isRecording
        ? (safeBottom + 36.5)
        : (safeBottom + 71.5);

    // Constrain the mushaf content:
    // When idle: stops just above the page number (safeBottom + 84.5).
    // When recording: page number drops down to the bottom bar row, allowing the ayahs to
    // stretch down right to the top of the collapsed dock (safeBottom + 71.0).
    final double bottomPadding = widget.isRecording
        ? (safeBottom + 71.0)
        : (safeBottom + 84.5);

    const ScrollPhysics physics = ClampingScrollPhysics();

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
                    child: PatchedPreloadPageView.builder(
                      key: const ValueKey('mushaf_single_page_view'),
                      controller: _pageController,
                      itemCount: 604,
                      padEnds: false,
                      preloadPagesCount: 1,
                      physics: physics,
                      onPageChanged: (index) {
                        WidgetsBinding.instance.addPostFrameCallback((_) {
                          if (!mounted) return;
                          final newPage = index + 1;
                          if (_currentPage == newPage) return;
                          _currentPage = newPage;
                          AppState.instance.currentMushafPage.value = newPage;
                          _syncPageSelection(newPage);
                          MushafProvider.instance.preloadAdjacentPages(newPage, viewportSize);
                        });
                      },
                      itemBuilder: (context, index) {
                        final pageNumber = index + 1;
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

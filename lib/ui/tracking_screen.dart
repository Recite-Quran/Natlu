import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:super_sliver_list/super_sliver_list.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'package:recite_quran/recite_quran.dart';
import '../services/quran_timing_service.dart';
import '../services/quran_audio_service.dart';
import '../state/app_state.dart';
import 'widgets/dialogs/voice_search_dialog.dart';
import 'widgets/mic_bar.dart';
import '../services/prayer/prayer_session.dart';
import '../services/prayer/recited_word.dart';
import 'prayer/prayer_event_text.dart';
import 'prayer/prayer_start_sheet.dart';
import 'prayer/prayer_status_card.dart';
import 'widgets/settings_dialog.dart';
import 'widgets/surah_picker.dart';
import 'widgets/verse_row.dart';
import 'widgets/mushaf/mushaf_view.dart';
import 'widgets/dialogs/speed_selection_dialog.dart';

/// Main interactive screen for real-time recitation tracking and reading.
/// Manages scrolling, distraction-free reading headers, and mode switches.
class TrackingScreen extends StatefulWidget {
  final HighlightingController controller;
  final bool isRecording;
  final bool isVoiceSearching;
  final String voiceSearchText;
  final ValueListenable<String>? voiceSearchTextNotifier;
  final VoidCallback onToggleRecord;
  final VoidCallback onVoiceSearchToggle;
  final bool isLoadingEngine;
  final ValueNotifier<bool>? isVoiceSearchLoading;
  final VoiceSearchController? voiceSearchController;
  final void Function(int surah, int ayah)? onSelectVoiceCandidate;
  final VoidCallback onClearBuffer;

  /// Prayer mode (rehearsal): the current or last session, and how to
  /// start, stop and close it.
  final ValueListenable<PrayerSession?>? prayerSession;
  final Future<void> Function(int surah, int ayah)? onStartPrayer;
  final VoidCallback? onStopPrayer;
  final VoidCallback? onClosePrayer;

  const TrackingScreen({
    super.key,
    required this.controller,
    required this.isRecording,
    required this.isVoiceSearching,
    this.voiceSearchText = '',
    this.voiceSearchTextNotifier,
    this.voiceSearchController,
    this.onSelectVoiceCandidate,
    required this.onToggleRecord,
    required this.onVoiceSearchToggle,
    this.isLoadingEngine = false,
    this.isVoiceSearchLoading,
    required this.onClearBuffer,
    this.prayerSession,
    this.onStartPrayer,
    this.onStopPrayer,
    this.onClosePrayer,
  });

  @override
  State<TrackingScreen> createState() => _TrackingScreenState();
}

class _TrackingScreenState extends State<TrackingScreen>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  final ScrollController _scroll = ScrollController();
  final ListController _listController = ListController();
  final Map<int, GlobalKey> _keys = {};
  final ValueNotifier<String> _voiceSearchNotifier = ValueNotifier('');

  int? _lastAyah;
  int? _lastSurah;
  bool _isAutoScrolling = false;
  bool _isUserDragging = false;
  DateTime? _lastScrollTime;
  Ticker? _autoScrollTicker;
  Duration? _lastAutoScrollElapsed;
  double _currentAutoScrollVelocity = 0.0;

  AppBannerInfo? _lastBanner;
  bool _wasAudioPlaying = false;
  List<QuranVerse>? _cachedDisplayVerses;
  int? _cachedTargetSurah;

  List<QuranVerse> get _displayVerses {
    if (_cachedDisplayVerses == null ||
        _cachedTargetSurah != widget.controller.targetSurah) {
      _cachedTargetSurah = widget.controller.targetSurah;
      _cachedDisplayVerses =
          widget.controller.repository.getSurah(widget.controller.targetSurah);
    }
    return _cachedDisplayVerses!;
  }

  @override
  void initState() {
    super.initState();
    if (!kIsWeb) {
      WidgetsBinding.instance.addObserver(this);
      try {
        WakelockPlus.enable();
      } catch (_) {}
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    }
    widget.controller.addListener(_onControllerUpdate);
    widget.controller.activeAyah.addListener(_onActiveAyahChanged);
    AppState.instance.activeAudioAyah.addListener(_onActiveAudioAyahChanged);
    AppState.instance.activeAudioSurah.addListener(_onActiveAudioAyahChanged);
    AppState.instance.isAudioPlaying.addListener(_onActiveAudioAyahChanged);

    // Warm up Surah timings and Ayah 1 audio in memory/disk in the background for zero-latency instant play
    unawaited(QuranTimingService.instance
        .ensureSurahLoaded(widget.controller.targetSurah));
    if (!kIsWeb) {
      unawaited(QuranAudioService.ensureAyahDownloaded(
          widget.controller.targetSurah, 1));
    }

    // Auto-scroll to saved last Ayah on startup
    if (AppState.instance.lastAyah > 1) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _lastAyah = AppState.instance.lastAyah;
          _ensureAyahVisibleSmart(AppState.instance.lastAyah,
              isManualTap: false);
        }
      });
    }
  }

  void _syncScreenWakeLock() {
    if (kIsWeb) return;
    final bool shouldStayAwake = widget.isRecording ||
        widget.isVoiceSearching ||
        _isAutoScrolling ||
        AppState.instance.isAudioPlaying.value;

    try {
      if (shouldStayAwake) {
        WakelockPlus.enable();
      } else {
        WakelockPlus.disable();
      }
    } catch (_) {}
  }

  void _onActiveAudioAyahChanged() {
    _syncScreenWakeLock();
    final isPlaying = AppState.instance.isAudioPlaying.value;
    final ayah = AppState.instance.activeAudioAyah.value;
    final int? audioSurah = AppState.instance.activeAudioSurah.value;

    // Never auto-scroll when a single word is tapped by the user
    if (QuranAudioService.instance.isSingleWordMode) {
      _lastAyah = ayah;
      return;
    }

    if (isPlaying && ayah != null && !_isAutoScrolling) {
      _wasAudioPlaying = true;
      final int targetSurah = audioSurah ?? widget.controller.targetSurah;
      AppState.instance.saveLastPosition(targetSurah, ayah);
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (mounted) {
          if (widget.controller.targetSurah != targetSurah) {
            await widget.controller.setTargetSurah(
              targetSurah,
              preserveOtherSurahStates: true,
              clearTargetSurah: false,
            );
          }
          widget.controller.setManualAyah(targetSurah, ayah);
          _lastAyah = ayah;
          _ensureAyahVisibleSmart(ayah);
        }
      });
    } else if (!isPlaying &&
        _wasAudioPlaying &&
        !QuranAudioService.instance.isPaused) {
      _wasAudioPlaying = false;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.detached ||
        widget.isRecording ||
        QuranAudioService.instance.isSingleWordMode) {
      AppState.instance.stopVerseAudio();
    }
    if (kIsWeb) return;

    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      if (widget.isRecording) {
        widget.onToggleRecord();
      }
      if (widget.isVoiceSearching) {
        widget.onVoiceSearchToggle();
      }
      if (_isAutoScrolling) {
        _toggleAutoScroll();
      }
    }
  }

  @override
  void dispose() {
    AppState.instance.stopVerseAudio();
    if (!kIsWeb) {
      WidgetsBinding.instance.removeObserver(this);
      try {
        WakelockPlus.disable();
      } catch (_) {}
    }
    widget.controller.removeListener(_onControllerUpdate);
    widget.controller.activeAyah.removeListener(_onActiveAyahChanged);
    AppState.instance.activeAudioAyah.removeListener(_onActiveAudioAyahChanged);
    AppState.instance.activeAudioSurah.removeListener(_onActiveAudioAyahChanged);
    AppState.instance.isAudioPlaying.removeListener(_onActiveAudioAyahChanged);
    _autoScrollTicker?.dispose();
    _autoScrollTicker = null;
    _scroll.dispose();
    _voiceSearchNotifier.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(TrackingScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isRecording != oldWidget.isRecording ||
        widget.isVoiceSearching != oldWidget.isVoiceSearching) {
      _syncScreenWakeLock();
    }
    if (widget.isRecording && !oldWidget.isRecording) {
      AppState.instance.dismissBanner();
      final int targetAyah =
          widget.controller.currentMatchedVerse?.verse.ayah ??
              widget.controller.activeAyah.value ??
              1;
      _lastAyah = targetAyah;
      _ensureAyahVisibleSmart(targetAyah);
    }

    if (widget.isVoiceSearching && !oldWidget.isVoiceSearching) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          VoiceSearchDialog.show(
            context,
            onStop: widget.onVoiceSearchToggle,
            isLoading: widget.isVoiceSearchLoading,
            asrTextNotifier:
                widget.voiceSearchTextNotifier ?? _voiceSearchNotifier,
            searchResultNotifier: widget.voiceSearchController?.currentResult,
            onSelectCandidate: widget.onSelectVoiceCandidate,
          );
        }
      });
    } else if (!widget.isVoiceSearching && oldWidget.isVoiceSearching) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && Navigator.of(context).canPop()) {
          Navigator.of(context).popUntil((route) => route.isFirst);
        }
      });
    }
  }

  void _onControllerUpdate() {
    if (widget.controller.targetSurah != _lastSurah) {
      void applyUpdate() {
        if (!mounted) return;
        setState(() {
          _lastSurah = widget.controller.targetSurah;
          _cachedDisplayVerses = null;
          _keys.clear();
          _lastAyah = null;
        });

        if (_scroll.hasClients) {
          _scroll.jumpTo(0);
        }
      }

      if (SchedulerBinding.instance.schedulerPhase ==
          SchedulerPhase.persistentCallbacks) {
        SchedulerBinding.instance.addPostFrameCallback((_) => applyUpdate());
      } else {
        applyUpdate();
      }
    }
  }

  void _onActiveAyahChanged() {
    if (QuranAudioService.instance.isSingleWordMode) return;

    final active = widget.controller.activeAyah.value;
    if (active != null && active != _lastAyah) {
      _lastAyah = active;
      AppState.instance.saveLastPosition(widget.controller.targetSurah, active);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _ensureAyahVisibleSmart(active);
        }
      });
    }
  }

  /// Calculates the safe, unobstructed reading boundaries between top and bottom chrome.
  ({double upperSafeY, double lowerSafeY, double screenHeight})
      _getSafeViewportBounds() {
    final mediaQuery = MediaQuery.of(context);
    final double screenHeight = mediaQuery.size.height;
    final double topPadding = mediaQuery.padding.top;
    final double bottomPadding = mediaQuery.padding.bottom;
    final bool isFullscreenMode = widget.isRecording || _isAutoScrolling;

    // 1. Top Obstruction:
    // In recording/autoscroll, the top bar is hidden, only status bar + margin (topPadding + 10).
    // In normal mode, top floating header takes topPadding + 74.
    final double topObstruction =
        isFullscreenMode ? (topPadding + 10.0) : (topPadding + 74.0);

    // 2. Bottom Obstruction:
    // Floating island dock is 56px (normal) or 46px (recording/autoscroll) + 16px bottom padding = 72px / 62px.
    double bottomBarHeight = isFullscreenMode ? 62.0 : 74.0;

    // Account for any active bottom banners:
    if (AppState.instance.isBannerVisible) {
      bottomBarHeight += 58.0;
    }
    final double bottomObstruction = bottomPadding + bottomBarHeight;

    // Safe boundaries: lowerSafeY marks the precise top edge of the bottom dock
    final double upperSafeY = topObstruction + 10.0;
    final double lowerSafeY = (screenHeight - bottomObstruction - 6.0).clamp(
      upperSafeY + 100.0,
      screenHeight,
    );

    return (
      upperSafeY: upperSafeY,
      lowerSafeY: lowerSafeY,
      screenHeight: screenHeight,
    );
  }

  /// Unified "Eye-Comfort" verse viewport manager:
  /// - ZERO-MOTION RULE: If the Ayah is visible on screen or manually tapped, the viewport DOES NOT MOVE AT ALL!
  /// - NEW PAGE ADVANCE: Only when the coming Ayah is genuinely cut off / out of bounds (>40% below the dock).
  /// - TOP RECOVERY: If scrolled too far up under the top bar, glides down to the natural eye view.
  /// - DISTANT NAVIGATION: If completely off-screen (picker, voice search), animates to natural 25% gaze.
  void _ensureAyahVisibleSmart(int ayah, {bool isManualTap = false}) {
    if (!_scroll.hasClients || _isAutoScrolling) return;
    if (_isUserDragging && !isManualTap) return;

    final bounds = _getSafeViewportBounds();
    final upperSafeY = bounds.upperSafeY;
    final lowerSafeY = bounds.lowerSafeY;
    final screenHeight = bounds.screenHeight;

    // Natural reciter eye horizon: ~25% from top of screen, with comfortable breathing cushion under top header
    final double targetGazeY = screenHeight > 0
        ? (screenHeight * 0.25).clamp(upperSafeY + 32.0, lowerSafeY - 100.0)
        : upperSafeY + 32.0;

    final renderBox =
        _keys[ayah]?.currentContext?.findRenderObject() as RenderBox?;

    // ── CASE 1: AYAH IS ATTACHED & RENDERED IN VIEWPORT ──
    if (renderBox != null && renderBox.hasSize && renderBox.attached) {
      final Offset globalPos = renderBox.localToGlobal(Offset.zero);
      final double ayahTop = globalPos.dy;
      final double ayahHeight = renderBox.size.height;
      final double ayahBottom = ayahTop + ayahHeight;

      // 0. MANUAL TAP / WORD AUDITION RULE:
      // If user manually tapped a word or verse and any part of it is currently visible:
      // ZERO SCROLLING! Never yank the viewport away from user's manual focus point.
      if ((isManualTap || QuranAudioService.instance.isSingleWordMode) &&
          ayahBottom >= upperSafeY &&
          ayahTop <= lowerSafeY) {
        return;
      }

      // 1. Obscured under top bar (scrolled too far up):
      // Gently glide down to the comfortable eye view.
      if (ayahTop < upperSafeY) {
        final double delta = ayahTop - targetGazeY;
        _smoothScrollByDelta(delta);
        return;
      }

      // 2. ENTIRE AYAH IS FULLY VISIBLE ON SCREEN:
      // If the Ayah fits between the top header and bottom dock: ZERO SCROLLING!
      // Even if it sits right above the bottom dock!
      if (ayahTop >= upperSafeY && ayahBottom <= lowerSafeY) {
        return;
      }

      // 3. MANUAL TAP RULE:
      // If the user tapped this Ayah with their finger and its start is already visible:
      // ZERO SCROLLING! Never yank the screen away from the user's touch.
      if (isManualTap &&
          ayahTop >= upperSafeY &&
          ayahTop <= (lowerSafeY - 24.0)) {
        return;
      }

      // 4. CHECK IF AYAH IS MOSTLY VISIBLE:
      // How much of this Ayah is visible before the bottom dock?
      final double visibleHeight =
          (lowerSafeY - ayahTop).clamp(0.0, ayahHeight);
      final double visibleRatio =
          ayahHeight > 0 ? (visibleHeight / ayahHeight) : 1.0;

      // If at least 60% of the Ayah is clear above the dock: ZERO SCROLLING!
      if (ayahTop >= upperSafeY && visibleRatio >= 0.60) {
        return;
      }

      // 5. NEW PAGE ADVANCE:
      // The coming Ayah is genuinely out of bounds (clipped by bottom dock or mostly hidden).
      // Smoothly advance it to the natural reciter eye view (~25% horizon).
      final double delta = ayahTop - targetGazeY;
      _smoothScrollByDelta(delta);
      return;
    }

    // ── CASE 2: AYAH IS COMPLETELY OFF-SCREEN / UNRENDERED (Far off navigation / search) ──
    final double targetAlignment =
        screenHeight > 0 ? (targetGazeY / screenHeight).clamp(0.0, 1.0) : 0.25;

    _lastScrollTime = DateTime.now();
    _listController.animateToItem(
      index: ayah,
      scrollController: _scroll,
      alignment: targetAlignment,
      rect: const Rect.fromLTWH(0, 0, 10, 10),
      duration: (_) => const Duration(milliseconds: 340),
      curve: (_) => Curves.easeOutCubic,
    );
  }

  void _smoothScrollByDelta(double delta) {
    if (!_scroll.hasClients || delta.abs() < 4.0) return;

    final double targetPixels = (_scroll.position.pixels + delta).clamp(
      0.0,
      _scroll.position.maxScrollExtent,
    );

    if ((targetPixels - _scroll.position.pixels).abs() < 4.0) return;

    _lastScrollTime = DateTime.now();
    _scroll.animateTo(
      targetPixels,
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
    );
  }

  void _maintainWordInEyeView(int ayah, int wordIndex, Rect globalWordRect) {
    if (_isAutoScrolling || _isUserDragging || !_scroll.hasClients) {
      return;
    }

    if (_lastScrollTime != null &&
        DateTime.now().difference(_lastScrollTime!).inMilliseconds < 350) {
      return;
    }

    final bool isAudio = AppState.instance.isAudioPlaying.value;
    final int? activeAyah = isAudio
        ? (AppState.instance.activeAudioAyah.value ??
            widget.controller.activeAyah.value)
        : widget.controller.activeAyah.value;
    if (activeAyah == null || ayah != activeAyah) {
      return;
    }

    final bounds = _getSafeViewportBounds();
    final upperSafeY = bounds.upperSafeY;
    final lowerSafeY = bounds.lowerSafeY;

    if (lowerSafeY <= upperSafeY) return;

    final double wordTop = globalWordRect.top;
    final double wordBottom = globalWordRect.bottom;

    // ── ABSOLUTE ZERO-MOTION RULE: NEVER SCROLL WHILE WORD IS WITHIN SAFE EYE BOUNDS ──
    if (wordTop >= upperSafeY && wordBottom <= lowerSafeY) {
      return;
    }

    // ── WORD IS OUT OF BOUNDS AT BOTTOM: GENTLE, MINIMAL REVEAL ──
    // Scrolls only by the small space needed to bring the word comfortably clear of the bottom bar
    if (wordBottom > lowerSafeY) {
      final double delta = (wordBottom - lowerSafeY) + 36.0;
      _smoothScrollByDelta(delta);
      return;
    }

    // ── WORD IS OUT OF BOUNDS AT TOP: GENTLE DOWNWARD REVEAL ──
    if (wordTop < upperSafeY) {
      final double delta = wordTop - (upperSafeY + 16.0);
      _smoothScrollByDelta(delta);
      return;
    }
  }

  void _toggleAutoScroll() {
    if (_isAutoScrolling) {
      _stopAutoScrolling();
    } else {
      AppState.instance.stopVerseAudio();
      if (AppState.instance.isMushafMode) {
        widget.controller.clearHighlights();
        widget.controller.finalize();
        setState(() => _isAutoScrolling = true);
        _syncScreenWakeLock();
        return;
      }
      if (!AppState.instance.hasChosenAutoScrollSpeed && mounted) {
        showDialog(
          context: context,
          barrierDismissible: true,
          builder: (ctx) => SpeedSelectionDialog(
            onSpeedSelected: () {
              AppState.instance.setHasChosenAutoScrollSpeed(true);
              if (Navigator.of(ctx).canPop()) {
                Navigator.of(ctx).pop();
              }
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted && !_isAutoScrolling) {
                  _startAutoScrolling();
                }
              });
            },
          ),
        );
        return;
      }

      _startAutoScrolling();
    }
  }

  void _startAutoScrolling() {
    AppState.instance.stopVerseAudio();
    widget.controller.clearHighlights();
    widget.controller.finalize();
    setState(() => _isAutoScrolling = true);

    _lastAutoScrollElapsed = null;
    _currentAutoScrollVelocity = 0.0;
    _autoScrollTicker ??= createTicker(_onAutoScrollTick);
    if (!_autoScrollTicker!.isTicking) {
      _autoScrollTicker!.start();
    }

    _syncScreenWakeLock();
  }

  void _stopAutoScrolling() {
    _autoScrollTicker?.stop();
    _lastAutoScrollElapsed = null;
    _currentAutoScrollVelocity = 0.0;
    if (_isAutoScrolling) {
      setState(() => _isAutoScrolling = false);
    }
    _syncScreenWakeLock();
  }

  /// Hardware VSYNC frame-rate independent teleprompter engine:
  /// - Runs at native display refresh rate (60 FPS / 120 FPS / 144 FPS).
  /// - Uses delta-time (dt) integration: perfectly constant velocity regardless of frame drops.
  /// - Organic exponential velocity ramping (smooth ease-in over ~300ms; zero shock on speed switch).
  /// - Completely immune to SuperSliverList dynamic maxScrollExtent expansions.
  void _onAutoScrollTick(Duration elapsed) {
    if (!_isAutoScrolling || !mounted || !_scroll.hasClients) {
      _stopAutoScrolling();
      return;
    }

    if (_lastAutoScrollElapsed == null) {
      _lastAutoScrollElapsed = elapsed;
      return;
    }

    final double dt =
        (elapsed - _lastAutoScrollElapsed!).inMicroseconds / 1000000.0;
    _lastAutoScrollElapsed = elapsed;

    // Safety guard against massive dt spikes (e.g. app backgrounded or debugger paused)
    if (dt <= 0.0 || dt > 0.1) return;

    final position = _scroll.position;
    final double max = position.maxScrollExtent;
    final double current = position.pixels;

    // Stop cleanly when the genuine end of the content is reached
    if (current >= max - 0.5) {
      _stopAutoScrolling();
      return;
    }

    final double baseSpeed =
        ((AppState.instance.fontSize / 24.0) * 1.5) * (16.0 / 50.0);
    final speedMultipliers = AppState.autoScrollMultipliers;
    final int speedIndex = AppState.instance.autoScrollSpeed.clamp(
      0,
      speedMultipliers.length - 1,
    );
    final double targetPixelsPerSec =
        baseSpeed * speedMultipliers[speedIndex] * 60.0;

    // Smooth exponential velocity ramping (velvety ease-in and speed changes over ~300ms):
    final double blend = (1.0 - math.exp(-7.5 * dt)).clamp(0.0, 1.0);
    _currentAutoScrollVelocity +=
        (targetPixelsPerSec - _currentAutoScrollVelocity) * blend;

    final double delta = _currentAutoScrollVelocity * dt;
    final double nextOffset = (current + delta).clamp(0.0, max);

    if (nextOffset != current) {
      _scroll.jumpTo(nextOffset);
    }
  }

  int get _effectiveSurah {
    final app = AppState.instance;
    if (app.isMushafMode) {
      final page = app.currentMushafPage.value;
      final activeAyah = widget.controller.activeAyah.value;
      final activeSurah = widget.controller.targetSurah;
      if (activeAyah != null &&
          MushafView.isAyahOnPage(
            pageNumber: page,
            surah: activeSurah,
            ayah: activeAyah,
          )) {
        return activeSurah;
      }
      final dominant = MushafView.getDominantSurahOnPage(page);
      if (dominant != null) {
        return dominant;
      }
      final first = MushafView.getFirstAyahOnPage(page);
      if (first != null) {
        return first.$1;
      }
    }
    return widget.controller.targetSurah;
  }

  void _showSurahPicker() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => SurahPickerSheet(
        current: _effectiveSurah,
        controller: widget.controller,
        isRecording: widget.isRecording,
        isVoiceSearching: widget.isVoiceSearching,
        onToggleRecord: widget.onToggleRecord,
        onVoiceSearchToggle: widget.onVoiceSearchToggle,
        onPick: (n, {ayah}) async {
          AppState.instance.stopVerseAudio();
          if (widget.isRecording) {
            widget.onToggleRecord();
          }
          if (_isAutoScrolling) {
            _stopAutoScrolling();
          }
          if (Navigator.of(context).canPop()) {
            Navigator.pop(context);
          }
          if (_scroll.hasClients) {
            _scroll.jumpTo(0);
          }

          await widget.controller.setTargetSurah(n);
          unawaited(QuranTimingService.instance.ensureSurahLoaded(n));
          if (!kIsWeb) {
            unawaited(QuranAudioService.ensureAyahDownloaded(n, 1));
          }
          if (ayah != null) {
            widget.controller.setManualAyah(n, ayah);
            AppState.instance.saveLastPosition(n, ayah);
          } else {
            AppState.instance.saveLastPosition(n, 1);
          }

          setState(() {
            _keys.clear();
            _lastAyah = null;
          });
        },
      ),
    );
  }

  void _showSettingsDialog() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => SettingsDialog(
        controller: widget.controller,
        onOpenPrayerMode: widget.onStartPrayer == null
            ? null
            : () {
                Navigator.of(context).pop();
                _showPrayerStart();
              },
      ),
    );
  }

  String _surahName(int surah) {
    final metadata = widget.controller.repository.surahMetadata;
    if (surah < 1 || surah > metadata.length) return '';
    final s = metadata[surah - 1];
    return AppState.instance.isArabic ? s.surahName : s.surahNameEn;
  }

  /// Prayer mode starts at the current ayah.
  void _showPrayerStart() {
    final surah = widget.controller.targetSurah;
    final ayah = widget.controller.activeAyah.value ?? 1;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => PrayerStartSheet(
        startText: prayerPositionText(
          MushafWord(surah, ayah, 0),
          AppState.instance.isArabic,
          _surahName,
        ),
        onStart: () {
          Navigator.of(sheetContext).pop();
          widget.onStartPrayer?.call(surah, ayah);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.of(context).padding.top;
    final bottom = MediaQuery.of(context).padding.bottom;
    final app = AppState.instance;

    return ListenableBuilder(
      listenable: app,
      builder: (context, child) {
        final c = app.colors;

        return Directionality(
          textDirection: app.isArabic ? TextDirection.rtl : TextDirection.ltr,
          child: Scaffold(
            backgroundColor: c.bg,
            body: Stack(
              fit: StackFit.expand,
              children: [
                // Main Verse Content
                Positioned.fill(child: _buildVerseContent(c, app, top)),

                // Top Floating Header
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 300),
                    transitionBuilder: (child, animation) {
                      return SlideTransition(
                        position: Tween<Offset>(
                          begin: const Offset(0, -1),
                          end: Offset.zero,
                        ).animate(
                          CurvedAnimation(
                            parent: animation,
                            curve: Curves.easeOutCubic,
                          ),
                        ),
                        child: child,
                      );
                    },
                    child: _buildHeader(c, app, top),
                  ),
                ),

                // Prayer mode status, above the recitation controls
                if (widget.prayerSession != null)
                  Positioned(
                    left: 12,
                    right: 12,
                    bottom: bottom + 96,
                    child: ValueListenableBuilder<PrayerSession?>(
                      valueListenable: widget.prayerSession!,
                      builder: (context, session, _) => session == null
                          ? const SizedBox.shrink()
                          : PrayerStatusCard(
                              session: session,
                              surahName: _surahName,
                              onStop: () => widget.onStopPrayer?.call(),
                              onClose: () => widget.onClosePrayer?.call(),
                            ),
                    ),
                  ),

                // Bottom Action Bar
                AnimatedPositioned(
                  duration: const Duration(milliseconds: 250),
                  curve: Curves.easeOutCubic,
                  bottom: 0,
                  left: 0,
                  right: 0,
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 400),
                    transitionBuilder: (child, animation) {
                      return SlideTransition(
                        position: Tween<Offset>(
                          begin: const Offset(0, 1),
                          end: Offset.zero,
                        ).animate(
                          CurvedAnimation(
                            parent: animation,
                            curve: Curves.easeOutCubic,
                          ),
                        ),
                        child: child,
                      );
                    },
                    child: BottomActionBar(
                      key: const ValueKey('word_checker_bar'),
                      isRecording: widget.isRecording,
                      isLoadingEngine: widget.isLoadingEngine,
                      isAutoScrolling: _isAutoScrolling,
                      c: c,
                      onMic: () async {
                        app.dismissBanner();
                        if (widget.isVoiceSearching) {
                          widget.onVoiceSearchToggle();
                        } else {
                          if (app.isMushafMode && !widget.isRecording) {
                            await MushafView.ensureActiveAyahOnCurrentPage(
                              controller: widget.controller,
                              pageNumber: app.currentMushafPage.value,
                            );
                          }
                          widget.onToggleRecord();
                        }
                      },
                      onToggleAutoScroll: () {
                        app.dismissBanner();
                        _toggleAutoScroll();
                      },
                      onSettingsTap: _showSettingsDialog,
                      isTajweed: app.currentMode == AppMode.tajweed,
                      onToggleTajweed: () {
                        final bool newIsTajweed =
                            app.currentMode != AppMode.tajweed;
                        if (newIsTajweed) {
                          app.setMode(AppMode.tajweed);
                          widget.controller.setTajweedMode(true);
                          app.showTajweedBanner();
                        } else {
                          app.setMode(AppMode.wordChecker);
                          widget.controller.setTajweedMode(false);
                          app.dismissTajweedBanner();
                        }
                      },
                      isBlur: app.isBlurMode,
                      onToggleBlur: () {
                        app.toggleBlurMode();
                        if (app.isBlurMode && !widget.isRecording) {
                          app.showBlurBanner(true);
                        } else {
                          app.dismissBanner();
                        }
                      },
                    ),
                  ),
                ),

                // Modern Floating Slide-Up Banner (Slides UP above bottom toolbar for all notifications)
                _buildModernBottomBanner(c, app, bottom),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildHeader(ThemeColors c, AppState app, double top) {
    if (widget.isRecording || _isAutoScrolling) {
      return const SizedBox.shrink(key: ValueKey('header_hidden'));
    }

    return Padding(
      key: const ValueKey('header_main'),
      padding: EdgeInsetsDirectional.only(
        top: top + 10,
        start: 14,
        end: 14,
        bottom: 8,
      ),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: c.surface,
          borderRadius: BorderRadius.circular(28),
          border: Border.all(
            color: app.isDarkMode
                ? Colors.white.withValues(alpha: 0.16)
                : Colors.black.withValues(alpha: 0.12),
            width: 0.9,
          ),
          boxShadow: [
            BoxShadow(
              color:
                  Colors.black.withValues(alpha: app.isDarkMode ? 0.35 : 0.06),
              blurRadius: 16,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.max,
          children: [
            // ── 1. 2026 Surah Selector — Clean Frosted Capsule ──
            Expanded(
              child: _TactileScaleButton(
                onTap: () {
                  HapticFeedback.lightImpact();
                  _showSurahPicker();
                },
                child: Container(
                  height: 44,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  decoration: BoxDecoration(
                    color: app.isDarkMode
                        ? Colors.white.withValues(alpha: 0.06)
                        : c.surfaceHigh.withValues(alpha: 0.85),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: app.isDarkMode
                          ? Colors.white.withValues(alpha: 0.10)
                          : c.border.withValues(alpha: 0.55),
                      width: 0.8,
                    ),
                  ),
                  child: Row(
                    children: [
                      // Mini emerald icon badge
                      Container(
                        width: 28,
                        height: 28,
                        decoration: BoxDecoration(
                          color: c.primary
                              .withValues(alpha: app.isDarkMode ? 0.18 : 0.10),
                          borderRadius: BorderRadius.circular(9),
                        ),
                        alignment: Alignment.center,
                        child: Icon(
                          Icons.menu_book_rounded,
                          color: c.primary,
                          size: 15,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: AnimatedBuilder(
                          animation: Listenable.merge([
                            app.currentMushafPage,
                            widget.controller.activeAyah,
                            widget.controller,
                          ]),
                          builder: (context, _) {
                            final effectiveSurah = _effectiveSurah;
                            final metadata =
                                widget.controller.repository.surahMetadata;
                            final String name;
                            if (effectiveSurah >= 1 &&
                                effectiveSurah <= metadata.length) {
                              final s = metadata[effectiveSurah - 1];
                              name = app.isArabic ? s.surahName : s.surahNameEn;
                            } else {
                              final verse1 = widget.controller.repository
                                  .getVerse(effectiveSurah, 1);
                              name = app.isArabic
                                  ? (verse1?.surahName ?? '')
                                  : (verse1?.surahNameEn ?? '');
                            }
                            return Text(
                              name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: c.text,
                                fontSize: app.isArabic ? 16 : 14.5,
                                fontWeight: FontWeight.bold,
                              ),
                            );
                          },
                        ),
                      ),
                      const SizedBox(width: 4),
                      Icon(
                        Icons.keyboard_arrow_down_rounded,
                        color: c.textSecondary.withValues(alpha: 0.65),
                        size: 18,
                      ),
                    ],
                  ),
                ),
              ),
            ),

            const SizedBox(width: 6),

            // ── 2. Voice Search Action Button (Small Toolbar Icon) ──
            _buildIconActionButton(
              icon: Icons.graphic_eq_rounded,
              isActive: widget.isVoiceSearching,
              c: c,
              tooltip: app.isArabic ? 'بحث صوتي' : 'Voice Search',
              onTap: () {
                HapticFeedback.lightImpact();
                app.dismissBanner();
                AppState.instance.stopVerseAudio();
                widget.onVoiceSearchToggle();
              },
            ),

            const SizedBox(width: 4),

            // ── 3. Read (Auto-Scroll) / Fullscreen Action Button ──
            _buildIconActionButton(
              icon: app.isMushafMode
                  ? Icons.auto_stories_rounded
                  : Icons.keyboard_double_arrow_down_rounded,
              isActive: _isAutoScrolling,
              c: c,
              tooltip: app.isMushafMode
                  ? (app.isArabic
                      ? (_isAutoScrolling ? 'إيقاف ملء الشاشة' : 'ملء الشاشة')
                      : (_isAutoScrolling ? 'Exit Full Screen' : 'Full Screen'))
                  : (app.isArabic
                      ? (_isAutoScrolling ? 'إيقاف التمرير' : 'قراءة تلقائية')
                      : (_isAutoScrolling
                          ? 'Pause Reading'
                          : 'Auto-scroll Read')),
              onTap: () {
                HapticFeedback.mediumImpact();
                app.dismissBanner();
                AppState.instance.stopVerseAudio();
                _toggleAutoScroll();
              },
            ),

            const SizedBox(width: 4),

            // ── 4. Settings Action ──
            _buildIconActionButton(
              icon: Icons.settings_rounded,
              isActive: false,
              c: c,
              tooltip: app.isArabic ? 'الإعدادات' : 'Settings',
              onTap: () {
                HapticFeedback.lightImpact();
                _showSettingsDialog();
              },
            ),
          ],
        ),
      ),
    );
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Modern Floating Slide-Up Banner (Slides UP from bottom toolbar for all notices)
  // ──────────────────────────────────────────────────────────────────────────
  Widget _buildModernBottomBanner(ThemeColors c, AppState app, double bottom) {
    final bool isDark = app.isDarkMode;
    final bool isAr = app.isArabic;
    final bool isVisible = app.isBannerVisible;

    if (app.currentBanner != null) {
      _lastBanner = app.currentBanner;
    }
    final banner = app.currentBanner ?? _lastBanner;
    if (banner == null) {
      return const SizedBox.shrink();
    }

    final Color accentColor;
    if (banner.customColor != null) {
      accentColor = banner.customColor!(c, isDark);
    } else if (banner.isWarning) {
      accentColor = isDark ? const Color(0xFFF59E0B) : const Color(0xFFD97706);
    } else {
      accentColor = c.primary;
    }

    final Color iconColor =
        (banner.isWarning && isDark) ? const Color(0xFFFBBF24) : accentColor;
    final String message = isAr ? banner.messageAr : banner.messageEn;

    return AnimatedPositioned(
      duration: Duration(milliseconds: isVisible ? 600 : 300),
      curve: isVisible ? Curves.elasticOut : Curves.easeOutCubic,
      bottom: isVisible ? (bottom + 84) : (bottom + 16),
      left: 16,
      right: 16,
      child: IgnorePointer(
        ignoring: !isVisible,
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 260),
          opacity: isVisible ? 1.0 : 0.0,
          child: Center(
            child: GestureDetector(
              onTap: () {
                app.dismissBanner();
              },
              child: Container(
                constraints: const BoxConstraints(maxWidth: 460),
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: isDark ? c.surfaceHigh : c.surface,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: accentColor.withValues(alpha: isDark ? 0.38 : 0.30),
                    width: 1.1,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color:
                          Colors.black.withValues(alpha: isDark ? 0.35 : 0.08),
                      blurRadius: 14,
                      offset: const Offset(0, -3),
                    ),
                  ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 28,
                      height: 28,
                      decoration: BoxDecoration(
                        color:
                            accentColor.withValues(alpha: isDark ? 0.20 : 0.12),
                        borderRadius: BorderRadius.circular(9),
                        border: Border.all(
                          color: accentColor.withValues(
                              alpha: isDark ? 0.42 : 0.32),
                          width: 0.8,
                        ),
                      ),
                      alignment: Alignment.center,
                      child: Icon(
                        banner.icon,
                        color: iconColor,
                        size: 16,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Flexible(
                      child: Text(
                        message,
                        style: TextStyle(
                          color: c.text,
                          height: 1.35,
                          fontWeight: FontWeight.w600,
                          fontSize: 12.5,
                        ),
                        textAlign: isAr ? TextAlign.right : TextAlign.left,
                        textDirection:
                            isAr ? TextDirection.rtl : TextDirection.ltr,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildIconActionButton({
    required IconData icon,
    required bool isActive,
    required ThemeColors c,
    required String tooltip,
    required VoidCallback onTap,
  }) {
    final bool isDark = AppState.instance.isDarkMode;
    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 400),
      child: _TactileScaleButton(
        onTap: onTap,
        child: Container(
          width: 42,
          height: 42,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: isActive
                ? c.primary.withValues(alpha: isDark ? 0.22 : 0.14)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(15),
            border: Border.all(
              color: isActive
                  ? c.primary.withValues(alpha: isDark ? 0.50 : 0.38)
                  : Colors.transparent,
              width: 0.85,
            ),
            boxShadow: isActive
                ? [
                    BoxShadow(
                      color: c.primary.withValues(alpha: isDark ? 0.28 : 0.15),
                      blurRadius: 10,
                      offset: const Offset(0, 2),
                    ),
                  ]
                : null,
          ),
          child: Icon(
            icon,
            size: 20,
            color: isActive ? c.primary : c.textSecondary,
          ),
        ),
      ),
    );
  }

  Widget _buildVerseContent(ThemeColors c, AppState app, double top) {
    if (app.isMushafMode) {
      return MushafView(
        key: const ValueKey('mushaf_view_main'),
        controller: widget.controller,
        isRecording: widget.isRecording,
        isAutoScrolling: _isAutoScrolling,
        onToggleAutoScroll: _toggleAutoScroll,
        wordFontFamily: 'HafsSmart',
        ayahMarkerFontFamily: 'cairo',
        showBottomPageNumber: true,
      );
    }

    return Builder(
      key: const ValueKey('verse_list_content'),
      builder: (context) {
        final displayVerses = _displayVerses;

        final bool isFullscreenMode = widget.isRecording || _isAutoScrolling;
        final topPadding = isFullscreenMode ? top + 10.0 : top + 74.0;
        // Ergonomic bottom clearance: provides exact breathing room so the End-of-Surah
        // navigation capsule floats gracefully above the bottom action bar dock.
        // Completely removes the redundant ~850px empty space void.
        final double bottomSafeArea = MediaQuery.of(context).padding.bottom;
        final double bottomClearance =
            bottomSafeArea + (isFullscreenMode ? 72.0 : 96.0);

        return NotificationListener<ScrollNotification>(
          onNotification: (notification) {
            if (notification is ScrollStartNotification &&
                notification.dragDetails != null) {
              _isUserDragging = true;
            } else if (notification is ScrollEndNotification) {
              _isUserDragging = false;
            }
            return false;
          },
          child: CustomScrollView(
            controller: _scroll,
            physics: _isAutoScrolling
                ? const NeverScrollableScrollPhysics()
                : const AlwaysScrollableScrollPhysics(),
            slivers: [
              SuperSliverList(
                listController: _listController,
                delegate: SliverChildBuilderDelegate(
                  (_, i) {
                    if (i == 0) {
                      return SizedBox(height: topPadding);
                    }

                    if (i == displayVerses.length + 2) {
                      return SizedBox(height: bottomClearance);
                    }

                    if (i == displayVerses.length + 1) {
                      return _buildEndOfSurahSection(c, app);
                    }

                    final v = displayVerses[i - 1];

                    return RepaintBoundary(
                      key: _keys.putIfAbsent(v.ayah, () => GlobalKey()),
                      child: VerseRow(
                        key: ValueKey('verse_${v.surah}_${v.ayah}'),
                        verse: v,
                        controller: widget.controller,
                        isRecording: widget.isRecording,
                        isAutoScrolling: _isAutoScrolling,
                        onTap: () {
                          widget.controller.setManualAyah(v.surah, v.ayah);
                          _lastAyah = v.ayah;
                          AppState.instance.saveLastPosition(v.surah, v.ayah);
                          _ensureAyahVisibleSmart(v.ayah, isManualTap: true);
                        },
                        onWordErrorTap: null,
                        onActiveWordPositioned: _maintainWordInEyeView,
                      ),
                    );
                  },
                  childCount: displayVerses.length + 3,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  void _navigateToSurah(int newSurah) async {
    if (newSurah < 1 || newSurah > 114) return;
    HapticFeedback.mediumImpact();
    AppState.instance.stopVerseAudio();

    if (widget.isRecording) {
      widget.onToggleRecord();
    }
    if (_isAutoScrolling) {
      _stopAutoScrolling();
    }
    if (_scroll.hasClients) {
      _scroll.jumpTo(0);
    }

    await widget.controller.setTargetSurah(newSurah);
    AppState.instance.saveLastPosition(newSurah, 1);
    unawaited(QuranTimingService.instance.ensureSurahLoaded(newSurah));
    if (!kIsWeb) {
      unawaited(QuranAudioService.ensureAyahDownloaded(newSurah, 1));
    }

    if (mounted) {
      setState(() {
        _keys.clear();
        _lastAyah = null;
      });
    }
  }

  void _scrollToTop() {
    HapticFeedback.lightImpact();
    if (_isAutoScrolling) {
      _stopAutoScrolling();
    }
    if (_scroll.hasClients) {
      _scroll.animateTo(
        0,
        duration: const Duration(milliseconds: 500),
        curve: Curves.easeOutCubic,
      );
    }
  }

  /// 2026 End-of-Surah Navigation Section:
  /// - Minimalist 3-button navigation capsule (Next, Go to Top, Previous).
  /// - Direction-invariant layout (identical across English & Arabic):
  ///   Visual Left   = Next Surah (التالية / Next) with chevron left (←),
  ///   Visual Center = Scroll to Top (للأعلى / Top) with arrow up (↑),
  ///   Visual Right  = Previous Surah (السابقة / Previous) with chevron right (→).
  /// - Color parity with the bottom bar:
  ///   Dark mode  = c.surfaceHigh (alpha 0.75),
  ///   White mode = Colors.white (alpha 0.92) matching the bottom bar.
  Widget _buildEndOfSurahSection(ThemeColors c, AppState app) {
    final int currentSurah = widget.controller.targetSurah;
    final bool hasPrev = currentSurah > 1;
    final bool hasNext = currentSurah < 114;
    final bool isAr = app.isArabic;
    final bool isDark = app.isDarkMode;

    return Padding(
      padding: const EdgeInsets.only(top: 24, bottom: 16, left: 16, right: 16),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 290),
          child: Container(
            height: 38,
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            decoration: BoxDecoration(
              color: isDark ? c.surfaceHigh : c.surface,
              borderRadius: BorderRadius.circular(19),
              border: Border.all(
                color: isDark
                    ? Colors.white.withValues(alpha: 0.16)
                    : Colors.black.withValues(alpha: 0.12),
                width: 0.9,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: isDark ? 0.35 : 0.06),
                  blurRadius: 16,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Directionality(
              textDirection: TextDirection.ltr,
              child: Row(
                children: [
                  // Visual Left: Next Surah (التالية / Next)
                  // Advances deeper in Quran (Surah + 1), chevron points left (←)
                  Expanded(
                    child: _buildSurahNavButton(
                      icon: Icons.chevron_left_rounded,
                      label: isAr ? 'التالية' : 'Next',
                      isEnabled: hasNext,
                      iconOnLeft: true,
                      c: c,
                      isDark: isDark,
                      onTap: () => _navigateToSurah(currentSurah + 1),
                    ),
                  ),

                  // Subtle Vertical Divider
                  Container(
                    width: 1,
                    height: 14,
                    color: (isDark ? Colors.white : Colors.black)
                        .withValues(alpha: isDark ? 0.14 : 0.08),
                  ),

                  // Visual Center: Scroll to Top (للأعلى / Top)
                  Expanded(
                    child: _buildSurahNavButton(
                      icon: Icons.arrow_upward_rounded,
                      label: isAr ? 'للأعلى' : 'Top',
                      isEnabled: true,
                      iconOnLeft: true,
                      c: c,
                      isDark: isDark,
                      onTap: _scrollToTop,
                    ),
                  ),

                  // Subtle Vertical Divider
                  Container(
                    width: 1,
                    height: 14,
                    color: (isDark ? Colors.white : Colors.black)
                        .withValues(alpha: isDark ? 0.14 : 0.08),
                  ),

                  // Visual Right: Previous Surah (السابقة / Previous)
                  // Returns to previous surah (Surah - 1), chevron points right (→)
                  Expanded(
                    child: _buildSurahNavButton(
                      icon: Icons.chevron_right_rounded,
                      label: isAr ? 'السابقة' : 'Previous',
                      isEnabled: hasPrev,
                      iconOnLeft: false,
                      c: c,
                      isDark: isDark,
                      onTap: () => _navigateToSurah(currentSurah - 1),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSurahNavButton({
    required IconData icon,
    required String label,
    required bool isEnabled,
    required bool iconOnLeft,
    required ThemeColors c,
    required bool isDark,
    required VoidCallback onTap,
  }) {
    final Color textColor =
        !isEnabled ? c.muted.withValues(alpha: 0.35) : c.text;
    final Color iconColor =
        !isEnabled ? c.muted.withValues(alpha: 0.35) : c.textSecondary;

    final Widget iconWidget = Icon(icon, size: 15, color: iconColor);
    final Widget textWidget = Text(
      label,
      style: TextStyle(
        fontFamily: null,
        fontSize: 11.0,
        fontWeight: FontWeight.w600,
        color: textColor,
        height: 1.0,
      ),
    );

    final Widget content = Container(
      height: 32,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: iconOnLeft
              ? [
                  iconWidget,
                  const SizedBox(width: 3),
                  textWidget,
                ]
              : [
                  textWidget,
                  const SizedBox(width: 3),
                  iconWidget,
                ],
        ),
      ),
    );

    if (!isEnabled) {
      return Opacity(opacity: 0.35, child: content);
    }

    return _TactileScaleButton(
      onTap: onTap,
      child: content,
    );
  }
}

/// 2026 Spring-scale tactile feedback button wrapper.
class _TactileScaleButton extends StatefulWidget {
  final Widget child;
  final VoidCallback onTap;
  const _TactileScaleButton({required this.child, required this.onTap});

  @override
  State<_TactileScaleButton> createState() => _TactileScaleButtonState();
}

class _TactileScaleButtonState extends State<_TactileScaleButton> {
  bool _isDown = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => setState(() => _isDown = true),
      onTapUp: (_) => setState(() => _isDown = false),
      onTapCancel: () => setState(() => _isDown = false),
      onTap: widget.onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedScale(
        scale: _isDown ? 0.92 : 1.0,
        duration: const Duration(milliseconds: 120),
        curve: _isDown ? Curves.easeOutQuad : Curves.easeOutCubic,
        child: widget.child,
      ),
    );
  }
}

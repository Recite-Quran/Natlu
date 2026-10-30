import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'package:recite_quran/recite_quran.dart';
import '../services/quran_timing_service.dart';
import '../services/quran_audio_service.dart';
import '../services/app_haptics.dart';
import '../state/app_state.dart';
import 'widgets/dialogs/voice_search_dialog.dart';
import 'widgets/mic_bar.dart';
import 'widgets/settings_dialog.dart';
import 'widgets/surah_picker.dart';
import 'widgets/mushaf/mushaf_view.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../maglis/maglis_controller.dart';
import 'widgets/dialogs/maglis_entry_dialog.dart';
import 'widgets/dialogs/maglis_explanation_dialog.dart';
import 'widgets/dialogs/whats_new_dialog.dart';

/// Main interactive screen for real-time recitation tracking and reading.
/// Powered by the high-performance Mushaf vector layout.
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
  final ValueChanged<bool>? onVoiceSearchHoldChanged;
  final VoidCallback onClearBuffer;

  const TrackingScreen({
    super.key,
    required this.controller,
    required this.isRecording,
    required this.isVoiceSearching,
    this.voiceSearchText = '',
    this.voiceSearchTextNotifier,
    this.voiceSearchController,
    this.onSelectVoiceCandidate,
    this.onVoiceSearchHoldChanged,
    required this.onToggleRecord,
    required this.onVoiceSearchToggle,
    this.isLoadingEngine = false,
    this.isVoiceSearchLoading,
    required this.onClearBuffer,
  });

  @override
  State<TrackingScreen> createState() => _TrackingScreenState();
}

class _TrackingScreenState extends State<TrackingScreen>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  final ValueNotifier<String> _voiceSearchNotifier = ValueNotifier('');

  static const MethodChannel _lifecycleChannel =
      MethodChannel('com.recitequran.app/audio_lifecycle');

  AppBannerInfo? _lastBanner;
  int? _lastAyah;
  int? _lastSurah;
  bool _wasAudioPlaying = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    try {
      WakelockPlus.enable();
    } catch (_) {}
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    widget.controller.addListener(_onControllerUpdate);
    widget.controller.activeAyah.addListener(_onActiveAyahChanged);
    AppState.instance.activeAudioAyah.addListener(_onActiveAudioAyahChanged);
    AppState.instance.activeAudioSurah.addListener(_onActiveAudioAyahChanged);
    AppState.instance.isAudioPlaying.addListener(_onActiveAudioAyahChanged);

    // Listen for explicit native user leave hint (Home button pressed or app switched)
    _lifecycleChannel.setMethodCallHandler((call) async {
      if (call.method == 'onUserLeaveHome') {
        AppState.instance.stopVerseAudio();
      }
    });

    // Warm up Surah timings and Ayah 1 audio in memory/disk in the background for zero-latency instant play
    unawaited(QuranTimingService.instance
        .ensureSurahLoaded(widget.controller.targetSurah));
    unawaited(QuranAudioService.ensureAyahDownloaded(
        widget.controller.targetSurah, 1));

    // Show What's New dialog for new updates if not seen yet
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final prefs = await SharedPreferences.getInstance();
      final hasSeen = prefs.getBool('has_seen_v1_2_maglis_whats_new') ?? false;
      if (!hasSeen && mounted) {
        await WhatsNewDialog.show(context);
      }
    });
  }

  void _syncScreenWakeLock() {
    final bool shouldStayAwake = widget.isRecording ||
        widget.isVoiceSearching ||
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

    if (isPlaying && ayah != null) {
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
    if (state == AppLifecycleState.detached) {
      AppState.instance.stopVerseAudio();
    } else if (state == AppLifecycleState.paused ||
               state == AppLifecycleState.inactive ||
               state == AppLifecycleState.hidden) {
      if (widget.isRecording || QuranAudioService.instance.isSingleWordMode) {
        AppState.instance.stopVerseAudio();
      } else if (defaultTargetPlatform == TargetPlatform.android) {
        // Query native Android PowerManager / KeyguardManager:
        // If screen is interactive and unlocked, user went to Home screen or another app -> stop audio!
        // If screen is OFF or locked, audio continues playing!
        _checkAndStopIfBackgrounded();
      } else {
        AppState.instance.stopVerseAudio();
      }
    }

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
    }
  }

  Future<void> _checkAndStopIfBackgrounded() async {
    try {
      final isOffOrLocked =
          await _lifecycleChannel.invokeMethod<bool>('isScreenOffOrLocked') ?? false;
      if (!isOffOrLocked) {
        AppState.instance.stopVerseAudio();
      }
    } catch (_) {
      AppState.instance.stopVerseAudio();
    }
  }

  @override
  void dispose() {
    AppState.instance.stopVerseAudio();
    WidgetsBinding.instance.removeObserver(this);
    try {
      WakelockPlus.disable();
    } catch (_) {}
    widget.controller.removeListener(_onControllerUpdate);
    widget.controller.activeAyah.removeListener(_onActiveAyahChanged);
    AppState.instance.activeAudioAyah.removeListener(_onActiveAudioAyahChanged);
    AppState.instance.activeAudioSurah.removeListener(_onActiveAudioAyahChanged);
    AppState.instance.isAudioPlaying.removeListener(_onActiveAudioAyahChanged);
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
            onHoldChanged: widget.onVoiceSearchHoldChanged,
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
          _lastAyah = null;
        });
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
    }
  }



  int get _effectiveSurah {
    final page = AppState.instance.currentMushafPage.value;
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
    return widget.controller.targetSurah;
  }

  void _showSurahPicker() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      enableDrag: false,
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
          if (Navigator.of(context).canPop()) {
            Navigator.pop(context);
          }
          if (!mounted) return;

          final targetAyah = ayah ?? 1;
          await widget.controller.setTargetSurah(
            n,
            preserveOtherSurahStates: true,
            clearTargetSurah: false,
          );
          widget.controller.setManualAyah(n, targetAyah);
          AppState.instance.saveLastPosition(n, targetAyah);
          final mappedPage = MushafProvider.instance.getPageForAyah(n, targetAyah);
          if (mappedPage != null) {
            AppState.instance.saveMushafPage(mappedPage);
          }
          unawaited(QuranTimingService.instance.ensureSurahLoaded(n));
          unawaited(QuranAudioService.ensureAyahDownloaded(n, 1));

          setState(() {
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
      builder: (_) => const SettingsDialog(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.paddingOf(context).bottom;
    final app = AppState.instance;

    return ListenableBuilder(
      listenable: Listenable.merge([app.themeNotifier, app.languageNotifier]),
      builder: (context, child) {
        final c = app.colors;

        return Directionality(
          textDirection: app.isArabic ? TextDirection.rtl : TextDirection.ltr,
          child: Scaffold(
            resizeToAvoidBottomInset: false,
            backgroundColor: c.bg,
            body: Stack(
              fit: StackFit.expand,
              children: [
                // Main Verse Content
                Positioned.fill(child: _buildVerseContent(c, app)),

                // Bottom Action Bar (Unified Glassmorphic Command Dock)
                Positioned(
                  bottom: 0,
                  left: 0,
                  right: 0,
                  child: AnimatedBuilder(
                    animation: Listenable.merge([
                      app,
                      app.currentMushafPage,
                      widget.controller.activeAyah,
                      widget.controller,
                      MaglisController.instance.sessionListenable,
                    ]),
                    builder: (context, _) {
                      final effectiveSurah = _effectiveSurah;
                      final surahName =
                          _getSurahName(effectiveSurah, app.isArabic);
                      final maglis = MaglisController.instance;
                      final int peerCount = maglis.participantCount;

                      return RepaintBoundary(
                        child: BottomActionBar(
                          key: const ValueKey('unified_dock_bar'),
                          isRecording: widget.isRecording,
                        isLoadingEngine: widget.isLoadingEngine,
                        c: c,
                        onMic: () {
                          app.dismissBanner();
                          if (widget.isVoiceSearching) {
                            widget.onVoiceSearchToggle();
                          } else {
                            widget.onToggleRecord();
                          }
                        },
                        isBlur: app.isBlurMode,
                        onToggleBlur: () {
                          app.toggleBlurMode();
                          if (app.isBlurMode) {
                            app.showBlurBanner(true);
                          } else {
                            app.dismissBanner();
                          }
                        },
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
                        surahName: surahName,
                        onSurahTap: _showSurahPicker,
                        onSettingsTap: () {
                          AppHaptics.lightImpact();
                          _showSettingsDialog();
                        },
                        isInMaglis: maglis.inSession,
                        maglisRoomCode: maglis.roomCode,
                        maglisPeerCount: peerCount,
                        isRemoteReciting: maglis.isRemoteReciting,
                        onMaglisTap: () async {
                          AppHaptics.lightImpact();
                          app.recordMaglisTap();
                          final prefs = await SharedPreferences.getInstance();
                          final hasSeen = prefs.getBool('has_seen_maglis_explanation') ?? false;
                          if (!context.mounted) return;
                          if (!hasSeen) {
                            await MaglisExplanationDialog.show(context);
                            if (context.mounted) {
                              MaglisEntryDialog.show(context);
                            }
                          } else {
                            MaglisEntryDialog.show(context);
                          }
                        },
                        onMaglisExitTap: () async {
                          AppHaptics.heavyImpact();
                          if (widget.isRecording) {
                            widget.onToggleRecord();
                          }
                          await maglis.leaveSession();
                          app.showBanner(AppBannerInfo(
                            id: 'maglis_left',
                            messageAr: 'تمت مغادرة المجلس بنجاح',
                            messageEn: 'Left Maglis session',
                            icon: Icons.exit_to_app_rounded,
                          ));
                        },
                      ),
                    );
                  },
                  ),
                ),

                // Modern Floating Slide-Up Banner (Scoped listener prevents full screen rebuilds)
                ValueListenableBuilder<AppBannerInfo?>(
                  valueListenable: app.bannerNotifier,
                  builder: (context, activeBanner, _) =>
                      _buildModernBottomBanner(c, app, bottom, activeBanner),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  String _getSurahName(int surahNum, bool isArabic) {
    final metadata = widget.controller.repository.surahMetadata;
    if (surahNum >= 1 && surahNum <= metadata.length) {
      final s = metadata[surahNum - 1];
      return isArabic ? s.surahName : s.surahNameEn;
    }
    final verse1 = widget.controller.repository.getVerse(surahNum, 1);
    return isArabic ? (verse1?.surahName ?? '') : (verse1?.surahNameEn ?? '');
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Modern Floating Slide-Up Banner (Slides UP from bottom toolbar for all notices)
  // ──────────────────────────────────────────────────────────────────────────
  Widget _buildModernBottomBanner(
      ThemeColors c, AppState app, double bottom, AppBannerInfo? activeBanner) {
    final bool isDark = app.isDarkMode;
    final bool isAr = app.isArabic;
    final bool isVisible = activeBanner != null;

    if (activeBanner != null) {
      _lastBanner = activeBanner;
    }
    final banner = activeBanner ?? _lastBanner;
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
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
      bottom: isVisible ? (bottom + 84) : (bottom + 16),
      left: 16,
      right: 16,
      child: IgnorePointer(
        ignoring: !isVisible,
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 240),
          opacity: isVisible ? 1.0 : 0.0,
          child: RepaintBoundary(
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
      ),
    );
  }

  Widget _buildVerseContent(ThemeColors c, AppState app) {
    return MushafView(
      key: const ValueKey('mushaf_view_main'),
      controller: widget.controller,
      isRecording: widget.isRecording,
      showBottomPageNumber: true,
    );
  }
}

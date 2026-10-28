import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'package:recite_quran/recite_quran.dart';
import '../services/quran_timing_service.dart';
import '../services/quran_audio_service.dart';
import '../state/app_state.dart';
import 'widgets/dialogs/voice_search_dialog.dart';
import 'widgets/mic_bar.dart';
import 'widgets/settings_dialog.dart';
import 'widgets/surah_picker.dart';
import 'widgets/mushaf/mushaf_view.dart';

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

    // Warm up Surah timings and Ayah 1 audio in memory/disk in the background for zero-latency instant play
    unawaited(QuranTimingService.instance
        .ensureSurahLoaded(widget.controller.targetSurah));
    unawaited(QuranAudioService.ensureAyahDownloaded(
        widget.controller.targetSurah, 1));
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
    if (state == AppLifecycleState.detached ||
        widget.isRecording ||
        QuranAudioService.instance.isSingleWordMode) {
      AppState.instance.stopVerseAudio();
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

          final targetAyah = ayah ?? 1;
          await widget.controller.setTargetSurah(n);
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
                      c: c,
                      onMic: () async {
                        app.dismissBanner();
                        if (widget.isVoiceSearching) {
                          widget.onVoiceSearchToggle();
                        } else {
                          if (!widget.isRecording) {
                            await MushafView.ensureActiveAyahOnCurrentPage(
                              controller: widget.controller,
                              pageNumber: app.currentMushafPage.value,
                            );
                          }
                          widget.onToggleRecord();
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
    if (widget.isRecording) {
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
        child: LayoutBuilder(
          builder: (context, constraints) {
            final isCompact = constraints.maxWidth < 240;
            return Row(
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

                if (!isCompact) ...[
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
              ],
            );
          },
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
    return MushafView(
      key: const ValueKey('mushaf_view_main'),
      controller: widget.controller,
      isRecording: widget.isRecording,
      showBottomPageNumber: true,
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

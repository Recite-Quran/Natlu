import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import '../core/app_state.dart';
import '../core/highlighting_controller.dart';
import 'verse_span_builder.dart';

/// Displays a single Quranic verse (Ayah) with word-by-word highlighting.
///
/// Features:
/// - Fingerprint-based diffing for near-zero CPU / 60 FPS scrolling.
/// - Selective listener attachment (only active + adjacent Ayahs subscribe to ASR frames).
/// - Modular TextSpan rendering via [VerseSpanBuilder].
/// - Interactive Tajweed error breakdown via [ErrorDetailDialog].
class VerseRow extends StatefulWidget {
  final QuranVerse verse;
  final HighlightingController controller;
  final bool isRecording;
  final bool isAutoScrolling;
  final VoidCallback? onTap;
  final VoidCallback? onWordErrorTap;
  final bool? isAudioPlaying;
  final VoidCallback? onAudioPlayToggle;
  final void Function(int ayah, int wordIndex, Rect globalWordRect)?
      onActiveWordPositioned;

  const VerseRow({
    super.key,
    required this.verse,
    required this.controller,
    this.isRecording = false,
    required this.isAutoScrolling,
    this.onTap,
    this.onWordErrorTap,
    this.isAudioPlaying,
    this.onAudioPlayToggle,
    this.onActiveWordPositioned,
  });

  /// Converts an integer to Eastern Arabic numeral glyphs (e.g. 1 -> '١').
  static String toArabicDigits(int number) =>
      QuranTypography.toArabicDigits(number);

  /// Checks if audio is currently actively playing or buffering on this Ayah.
  static bool isAyahAudioActive({
    required int surah,
    required int ayah,
    required HighlightingController controller,
  }) {
    return (controller.isAudioPlaying || controller.isAudioBuffering) &&
        controller.audioSurah == surah &&
        controller.audioAyah == ayah;
  }

  /// Checks if the audio player is currently actively playing this Ayah.
  static bool isAyahAudioPlaying({
    required int surah,
    required int ayah,
    required HighlightingController controller,
  }) {
    return controller.audioSurah == surah &&
        controller.audioAyah == ayah &&
        controller.isAudioPlaying;
  }

  /// Checks if the audio player is currently buffering this Ayah.
  static bool isAyahAudioBuffering({
    required int surah,
    required int ayah,
    required HighlightingController controller,
  }) {
    return controller.audioSurah == surah &&
        controller.audioAyah == ayah &&
        controller.isAudioBuffering;
  }

  /// Handles selecting/tapping an Ayah: haptic feedback, manual selection, and persisting last position.
  static Future<void> selectAyah({
    required int surah,
    required int ayah,
    required HighlightingController controller,
    VoidCallback? onTap,
  }) =>
      QuranInteractionService.selectAyah(
        surah: surah,
        ayah: ayah,
        controller: controller,
        onTap: onTap,
      );

  /// Determines if an Ayah is active (reciting active, selected, or audio active).
  static bool isAyahActive({
    required int surah,
    required int ayah,
    required HighlightingController controller,
    required AppState app,
    bool isAutoScrolling = false,
  }) {
    if (isAutoScrolling) return false;
    final activeMatch = controller.currentMatchedVerse;
    final bool isRecitingActive = activeMatch != null &&
        activeMatch.verse.surah == surah &&
        activeMatch.verse.ayah == ayah;
    final bool isSelected = controller.activeAyah.value == ayah;
    final bool isAudioActive =
        isAyahAudioActive(surah: surah, ayah: ayah, controller: controller);
    return isRecitingActive || isSelected || isAudioActive;
  }

  /// Determines the active target word index (for audio word playback or recording focus).
  static int getTargetWordIndex({
    required int surah,
    required int ayah,
    required List<String> words,
    required HighlightingController controller,
    required AppState app,
    required bool isRecording,
    required bool isActive,
  }) {
    final bool isAudioActive =
        isAyahAudioActive(surah: surah, ayah: ayah, controller: controller);

    if (isAudioActive) {
      return controller.audioWordIndex ?? -1;
    }

    if (isActive && isRecording) {
      for (int i = 0; i < words.length; i++) {
        if (!controller.isWordRead(ayah, i, surah: surah)) {
          return i;
        }
      }
    }
    return -1;
  }

  /// Handles tapping a Quranic word:
  /// - Selects the Ayah.
  /// - If yellow word -> opens Tajweed error dialog.
  /// - If non-yellow word and (already selected or [playWordDirectly]) -> plays word audio.
  static void handleWordTap({
    required BuildContext context,
    required int surah,
    required int ayah,
    required int wordIndex,
    required String wordText,
    required HighlightingController controller,
    required bool isAutoScrolling,
    VoidCallback? onWordErrorTap,
    VoidCallback? onAyahTap,
    bool playWordDirectly = false,
  }) {
    if (isAutoScrolling) return;
    QuranInteractionService.handleWordTap(
      context: context,
      surah: surah,
      ayah: ayah,
      wordIndex: wordIndex,
      wordText: wordText,
      controller: controller,
      onWordErrorTap: onWordErrorTap,
      onAyahTap: onAyahTap,
      playWordDirectly: playWordDirectly,
    );
  }

  /// Toggles Ayah audio playback with buffering debounce and haptic feedback.
  static Future<void> toggleAyahAudio({
    required int surah,
    required int ayah,
    required HighlightingController controller,
    required bool isRecording,
    VoidCallback? onTap,
    VoidCallback? onExplicitToggle,
  }) =>
      QuranInteractionService.toggleAyahAudio(
        surah: surah,
        ayah: ayah,
        controller: controller,
        isRecording: isRecording,
        onTap: onTap,
        onExplicitToggle: onExplicitToggle,
      );

  /// Generates the active focus background pill decoration.
  static BoxDecoration? activeHighlightDecoration({
    required bool isWordActive,
    required AppState app,
  }) {
    if (!isWordActive) return null;
    final bool isBlack = app.isDarkMode;
    return BoxDecoration(
      color: app.colors.wordHighlight.withValues(
        alpha: isBlack ? 0.12 : 0.085,
      ),
      borderRadius: BorderRadius.circular(8),
    );
  }

  /// Generates the active Ayah gold border decoration.
  static BoxDecoration activeAyahBorderDecoration({
    required bool isActive,
    required AppState app,
    double borderRadius = 10,
  }) {
    final c = app.colors;
    return BoxDecoration(
      borderRadius: BorderRadius.circular(borderRadius),
      border: Border.all(
        color: isActive
            ? c.gold.withValues(alpha: app.isDarkMode ? 0.70 : 0.60)
            : Colors.transparent,
        width: 1.0,
      ),
      color: Colors.transparent,
    );
  }

  @override
  State<VerseRow> createState() => _VerseRowState();
}

class _VerseRowState extends State<VerseRow> {
  /// Cached fingerprint — only rebuilds when visual state changes.
  int _lastFingerprint = -1;

  /// Cached TextSpan list — avoids re-allocating on every build.
  List<InlineSpan>? _cachedSpans;
  bool _isListeningToController = false;
  bool _wasAudioActive = false;

  /// Fast O(1) word colors hash cache for idle/unrecited verses.
  int? _cachedWordColorsHash;
  int? _cachedWordColorsRevision;

  final List<TapGestureRecognizer> _recognizers = [];
  final GlobalKey _textKey = GlobalKey();
  bool _positionCheckScheduled = false;
  Timer? _delayedWordPositionTimer;
  _AyahWordLayout? _wordLayout;

  @override
  void initState() {
    super.initState();
    widget.controller.activeAyah.addListener(_onActiveAyahChanged);
    widget.controller.globalRevision.addListener(_onStateChanged);
    AppState.instance.blurModeNotifier.addListener(_onStateChanged);
    AppState.instance.fontSizeNotifier.addListener(_onStateChanged);
    _updateSubscription();
    if (_getActiveTargetIndex() >= 0) {
      _scheduleWordPositionCheck();
      _scheduleWordPositionCheck(delay: const Duration(milliseconds: 450));
    }
  }

  @override
  void didUpdateWidget(VerseRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.activeAyah.removeListener(_onActiveAyahChanged);
      oldWidget.controller.globalRevision.removeListener(_onStateChanged);
      if (_isListeningToController) {
        oldWidget.controller.removeListener(_onStateChanged);
      }
      widget.controller.activeAyah.addListener(_onActiveAyahChanged);
      widget.controller.globalRevision.addListener(_onStateChanged);
      _isListeningToController = false;
      _updateSubscription();
      _invalidate();
    }
    if (oldWidget.isAutoScrolling != widget.isAutoScrolling) {
      _invalidate();
      _onStateChanged();
    }
    if (oldWidget.isRecording != widget.isRecording) {
      _invalidate();
      _updateSubscription();
      _onStateChanged();
      _scheduleWordPositionCheck();
    }
    if (oldWidget.isAudioPlaying != widget.isAudioPlaying) {
      _scheduleWordPositionCheck();
      setState(() {});
    }
  }

  void _disposeRecognizers() {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
  }

  @override
  void dispose() {
    widget.controller.activeAyah.removeListener(_onActiveAyahChanged);
    widget.controller.globalRevision.removeListener(_onStateChanged);
    if (_isListeningToController) {
      widget.controller.removeListener(_onStateChanged);
    }
    AppState.instance.blurModeNotifier.removeListener(_onStateChanged);
    widget.controller.removeListener(_onActiveAyahChanged);
    AppState.instance.fontSizeNotifier.removeListener(_onStateChanged);
    _delayedWordPositionTimer?.cancel();
    _disposeRecognizers();
    _wordLayout?.dispose();
    _wordLayout = null;
    super.dispose();
  }

  void _onActiveAyahChanged() {
    _updateSubscription();
    _onStateChanged();
    if (_getActiveTargetIndex() >= 0) {
      _scheduleWordPositionCheck();
      _scheduleWordPositionCheck(delay: const Duration(milliseconds: 450));
    }
  }

  void _updateSubscription() {
    final int? active = widget.controller.activeAyah.value;
    final int myAyah = widget.verse.ayah;

    // Listen to highlights if we are the active, preceding, or upcoming Ayah
    bool shouldListen = false;
    final int effectiveActive = active ?? (widget.isRecording ? 1 : -999);
    if (myAyah == effectiveActive ||
        myAyah == effectiveActive - 1 ||
        myAyah == effectiveActive + 1) {
      shouldListen = true;
    }
    if (shouldListen && !_isListeningToController) {
      widget.controller.addListener(_onStateChanged);
      _isListeningToController = true;
    } else if (!shouldListen && _isListeningToController) {
      widget.controller.removeListener(_onStateChanged);
      _isListeningToController = false;
    }
  }

  void _invalidate() {
    _lastFingerprint = -1;
    _cachedSpans = null;
    _wordLayout?.dispose();
    _wordLayout = null;
    _cachedWordColorsHash = null;
    _cachedWordColorsRevision = null;
  }

  void _onStateChanged() {
    final fp = _computeFingerprint();
    if (fp != _lastFingerprint) {
      _lastFingerprint = fp;
      _cachedSpans = null;
      _wordLayout?.dispose();
      _wordLayout = null;
      if (mounted) {
        if (SchedulerBinding.instance.schedulerPhase ==
            SchedulerPhase.persistentCallbacks) {
          SchedulerBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              setState(() {});
              _scheduleWordPositionCheck();
            }
          });
        } else {
          setState(() {});
          _scheduleWordPositionCheck();
        }
      }
    } else {
      _scheduleWordPositionCheck();
    }
  }

  int _getActiveTargetIndex() {
    final surah = widget.verse.surah;
    final ayah = widget.verse.ayah;

    final bool isAudioActive = VerseRow.isAyahAudioActive(
      surah: surah,
      ayah: ayah,
      controller: widget.controller,
    );

    if (isAudioActive) {
      return widget.controller.audioWordIndex ?? -1;
    }

    final activeMatch = widget.controller.currentMatchedVerse;
    final bool isRecitingActive = activeMatch != null &&
        activeMatch.verse.surah == surah &&
        activeMatch.verse.ayah == ayah;
    final bool isSelected = widget.controller.activeAyah.value == ayah;
    final bool isReciting =
        widget.isRecording && (isRecitingActive || isSelected);

    if (!isReciting) {
      return -1;
    }

    final words = widget.verse.uthmaniWords;
    int lastSpoken = -1;
    for (int i = 0; i < words.length; i++) {
      if (widget.controller.isWordRead(ayah, i, surah: widget.verse.surah)) {
        lastSpoken = i;
      }
    }
    final int nextTarget = lastSpoken >= 0 ? lastSpoken + 1 : 0;
    if (nextTarget < words.length) {
      return nextTarget;
    }
    return -1; // All words in this Ayah have been recited
  }

  void _scheduleWordPositionCheck({Duration? delay}) {
    if (!mounted ||
        widget.isAutoScrolling ||
        widget.onActiveWordPositioned == null) {
      return;
    }

    // Fast exit: If this Ayah is not the active target or audio-active, skip position layout checks completely.
    // Eliminates thousands of redundant Timer and post-frame layouts across idle verses during scrolling!
    if (_getActiveTargetIndex() < 0) {
      return;
    }

    if (delay != null) {
      _delayedWordPositionTimer?.cancel();
      _delayedWordPositionTimer = Timer(delay, () {
        if (!mounted) return;
        _checkActiveWordPosition();
      });
      return;
    }

    if (_positionCheckScheduled) return;
    _positionCheckScheduled = true;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _positionCheckScheduled = false;
      if (!mounted) return;
      _checkActiveWordPosition();
    });
  }

  void _checkActiveWordPosition() {
    if (!mounted ||
        widget.isAutoScrolling ||
        widget.onActiveWordPositioned == null) {
      return;
    }

    final targetIndex = _getActiveTargetIndex();
    if (targetIndex < 0) return;

    final textBox = _textKey.currentContext?.findRenderObject() as RenderBox?;
    if (textBox == null || !textBox.hasSize || !textBox.attached) return;

    final localRect = _calculateWordRect(targetIndex, textBox.size.width);
    if (localRect == null) return;

    final globalTopLeft = textBox.localToGlobal(localRect.topLeft);
    final globalBottomRight = textBox.localToGlobal(localRect.bottomRight);
    final globalRect = Rect.fromPoints(globalTopLeft, globalBottomRight);

    widget.onActiveWordPositioned?.call(
      widget.verse.ayah,
      targetIndex,
      globalRect,
    );
  }

  _AyahWordLayout? _getOrCreateWordLayout(double maxWidth) {
    if (_cachedSpans == null || maxWidth <= 0) return null;
    if (_wordLayout != null &&
        (_wordLayout!.width - maxWidth).abs() < 0.5 &&
        identical(_wordLayout!.spans, _cachedSpans)) {
      return _wordLayout;
    }
    _wordLayout?.dispose();
    _wordLayout = _AyahWordLayout.compute(
      spans: _cachedSpans!,
      words: widget.verse.uthmaniWords,
      width: maxWidth,
    );
    return _wordLayout;
  }

  Rect? _calculateWordRect(int targetIndex, double maxWidth) {
    if (_cachedSpans == null ||
        targetIndex < 0 ||
        targetIndex >= widget.verse.uthmaniWords.length ||
        maxWidth <= 0) {
      return null;
    }

    final layout = _getOrCreateWordLayout(maxWidth);
    if (layout == null) {
      return null;
    }
    return layout.getWordRect(targetIndex);
  }

  /// Compact hash representing active state, word colors, blur, theme, and font size.
  int _computeFingerprint() {
    final ctrl = widget.controller;
    final app = AppState.instance;
    final ayah = widget.verse.ayah;
    final surah = widget.verse.surah;
    final bool isSelected =
        !widget.isAutoScrolling && ctrl.activeAyah.value == ayah;
    final bool isAudioActive = VerseRow.isAyahAudioActive(
        surah: surah, ayah: ayah, controller: widget.controller);
    final bool isActive = VerseRow.isAyahActive(
      surah: surah,
      ayah: ayah,
      controller: ctrl,
      app: app,
      isAutoScrolling: widget.isAutoScrolling,
    );
    final bool isCompleted = ctrl.completedAyahs.contains(ayah);

    int hash = isActive ? 1 : 0;
    hash = hash * 31 + (isSelected ? 1 : 0);
    hash = hash * 31 + (isAudioActive ? 1 : 0);
    hash = hash * 31 + (isCompleted ? 1 : 0);
    hash = hash * 31 + (widget.isRecording ? 1 : 0);

    final int currentRevision = ctrl.globalRevision.value;
    // Bug fix: also include globalRevision > 0 so partially-recited ayahs (words colored
    // but ayah not yet "completed") keep their colors when the user deselects them or
    // stops recording.
    final bool hasHighlights = isActive ||
        isAudioActive ||
        _wasAudioActive ||
        isCompleted ||
        widget.isRecording ||
        currentRevision > 0;

    final int wordColorsHash;
    final int? activeAyahVal = ctrl.activeAyah.value;
    final int effectiveActiveAyah =
        activeAyahVal ?? (widget.isRecording ? 1 : -999);
    final bool isNearActive =
        (ayah >= effectiveActiveAyah - 1 && ayah <= effectiveActiveAyah + 1);
    final bool couldHaveNewHighlights = isActive ||
        isAudioActive ||
        _wasAudioActive ||
        isCompleted ||
        isNearActive ||
        (_cachedWordColorsHash != null && _cachedWordColorsHash != 17);

    if (!couldHaveNewHighlights && _cachedWordColorsHash == 17) {
      wordColorsHash = 17;
      _cachedWordColorsRevision = currentRevision;
    } else if (!hasHighlights) {
      wordColorsHash = 17;
      _cachedWordColorsHash = 17;
      _cachedWordColorsRevision = currentRevision;
    } else {
      final bool isLiveActive =
          (widget.isRecording || isAudioActive) && (isActive || isNearActive);
      final bool needsWordScan = isLiveActive ||
          _cachedWordColorsRevision != currentRevision ||
          _cachedWordColorsHash == null;

      if (needsWordScan) {
        int wHash = 17;
        final wordCount = widget.verse.uthmaniWords.length;
        const multipliers = [0, 7, 17, 13, 23];
        for (int i = 0; i < wordCount; i++) {
          final status = ctrl.getWordStatus(ayah, i, surah: widget.verse.surah);
          if (status != null) {
            wHash = wHash * 31 + (i + 1) * multipliers[status];
          }
        }
        _cachedWordColorsHash = wHash;
        _cachedWordColorsRevision = currentRevision;
        wordColorsHash = wHash;
      } else {
        wordColorsHash = _cachedWordColorsHash!;
      }
    }
    hash = hash * 31 + wordColorsHash;

    final bool isBlurEffective =
        app.isBlurEffective(isRecording: widget.isRecording);
    hash = hash * 31 + (isBlurEffective ? 1 : 0);
    hash = hash * 31 + (isBlurEffective && widget.isAutoScrolling ? 1 : 0);
    hash = hash * 31 + app.fontSize.hashCode;
    hash = hash * 31 + app.theme.index;
    hash = hash * 31 + (app.hasClickedTajweedWord ? 1 : 0);
    hash = hash * 31 + (widget.isAutoScrolling ? 1 : 0);

    return hash;
  }

  static String _toArabicDigits(int number) => VerseRow.toArabicDigits(number);

  @override
  Widget build(BuildContext context) {
    final int fp = _computeFingerprint();
    if (fp != _lastFingerprint) {
      _lastFingerprint = fp;
      _cachedSpans = null;
      _wordLayout?.dispose();
      _wordLayout = null;
    }
    final AppState app = AppState.instance;
    final ThemeColors c = app.colors;
    final words = widget.verse.uthmaniWords;
    final surah = widget.verse.surah;
    final ayah = widget.verse.ayah;
    final bool isAudioActive = VerseRow.isAyahAudioActive(
        surah: surah, ayah: ayah, controller: widget.controller);
    final bool isActive = VerseRow.isAyahActive(
      surah: surah,
      ayah: ayah,
      controller: widget.controller,
      app: app,
      isAutoScrolling: widget.isAutoScrolling,
    );
    _wasAudioActive = isAudioActive;
    final bool hasHighlights = isActive ||
        isAudioActive ||
        widget.isRecording ||
        widget.controller.completedAyahsFor(surah).contains(ayah) ||
        widget.controller.globalRevision.value > 0;

    if (_cachedSpans == null) {
      _disposeRecognizers();
      _cachedSpans = VerseSpanBuilder.buildSpans(
        words: words,
        ayah: widget.verse.ayah,
        surah: widget.verse.surah,
        isActive: isActive,
        isAutoScrolling: widget.isAutoScrolling,
        isRecording: widget.isRecording,
        controller: widget.controller,
        app: app,
        colors: c,
        recognizersSink: _recognizers,
        onVerseTap: widget.onTap,
        onWordErrorTap: (ayah, wordIdx, word) {
          VerseRow.handleWordTap(
            context: context,
            surah: widget.verse.surah,
            ayah: ayah,
            wordIndex: wordIdx,
            wordText: word,
            controller: widget.controller,
            isAutoScrolling: widget.isAutoScrolling,
            onWordErrorTap: widget.onWordErrorTap,
            onAyahTap: widget.onTap,
          );
        },
        onWordAudioTap: (ayah, wordIdx) {
          VerseRow.handleWordTap(
            context: context,
            surah: widget.verse.surah,
            ayah: ayah,
            wordIndex: wordIdx,
            wordText: widget.verse.uthmaniWords[wordIdx],
            controller: widget.controller,
            isAutoScrolling: widget.isAutoScrolling,
            onAyahTap: widget.onTap,
          );
        },
      );
    }

    return ExcludeSemantics(
      child: GestureDetector(
        onTap: widget.isAutoScrolling
            ? null
            : () => VerseRow.selectAyah(
                  surah: widget.verse.surah,
                  ayah: widget.verse.ayah,
                  controller: widget.controller,
                  onTap: widget.onTap,
                ),
        child: Directionality(
          textDirection: TextDirection.rtl,
          child: Container(
            margin: const EdgeInsets.symmetric(
              horizontal: 10,
              vertical: 3.5,
            ),
            decoration: VerseRow.activeAyahBorderDecoration(
              isActive: isActive,
              app: app,
              borderRadius: 16,
            ),
            child: Stack(
              children: [
                Padding(
                  padding: const EdgeInsets.only(
                    right: 8,
                    left: 26,
                    top: 6,
                    bottom: 6,
                  ),
                  child: CustomPaint(
                    painter: _cachedSpans != null &&
                            ((isActive && widget.isRecording) ||
                                isAudioActive ||
                                hasHighlights)
                        ? _ActiveWordHighlightPainter(
                            surah: widget.verse.surah,
                            ayah: widget.verse.ayah,
                            words: words,
                            controller: widget.controller,
                            app: app,
                            cachedSpans: _cachedSpans!,
                            isAudioMode: isAudioActive,
                            isRecording: widget.isRecording,
                            isActive: isActive,
                            getWordLayout: _getOrCreateWordLayout,
                          )
                        : null,
                    foregroundPainter: _cachedSpans != null &&
                            !app.hasClickedTajweedWord &&
                            app.currentMode == AppMode.tajweed
                        ? TajweedTooltipPainter(
                            words: words,
                            ayah: widget.verse.ayah,
                            surah: widget.verse.surah,
                            controller: widget.controller,
                            app: app,
                            cachedSpans: _cachedSpans!,
                          )
                        : null,
                    child: RichText(
                      key: _textKey,
                      textAlign: TextAlign.justify,
                      textDirection: TextDirection.rtl,
                      text: TextSpan(children: _cachedSpans),
                    ),
                  ),
                ),

                // Injected Ayah number & audio play button with expanded comfortable touch area
                Positioned(
                  left: 0,
                  bottom: 2,
                  width: 32,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      if (!widget.isAutoScrolling) ...[
                        _VerseAudioButton(
                          surah: widget.verse.surah,
                          ayah: widget.verse.ayah,
                          colors: c,
                          isDark: app.isDarkMode,
                          isActiveVerse: isActive,
                          isRecording: widget.isRecording,
                          controller: widget.controller,
                          onTapVerse: widget.onTap,
                          explicitIsPlaying: widget.isAudioPlaying ??
                              (isAudioActive &&
                                  widget.controller.isAudioPlaying),
                          explicitIsBuffering: isAudioActive &&
                              widget.controller.isAudioBuffering,
                          onExplicitToggle: widget.onAudioPlayToggle,
                        ),
                      ],
                      GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => VerseRow.toggleAyahAudio(
                          surah: widget.verse.surah,
                          ayah: widget.verse.ayah,
                          controller: widget.controller,
                          isRecording: widget.isRecording,
                          onTap: widget.onTap,
                          onExplicitToggle: widget.onAudioPlayToggle,
                        ),
                        child: Container(
                          width: 32,
                          padding: const EdgeInsets.symmetric(vertical: 2),
                          color: Colors.transparent,
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text(
                              _toArabicDigits(widget.verse.ayah),
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontFamily: 'HafsSmart',
                                fontSize: 21.5,
                                fontWeight: FontWeight.bold,
                                height: 1.0,
                                color: isActive
                                    ? c.gold
                                    : c.textSecondary.withValues(alpha: 0.75),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Injected minimal audio play/pause button located above the Ayah number.
///
/// Designed with:
/// - Zero disruption to verse layout & typography (fitted inside the 42px left margin).
/// - Eye-comfortable palettes adaptive to both White (Linen) and Black (OLED) themes.
/// - Fluid animated play/pause state ready for backend audio engine binding.
class _VerseAudioButton extends StatefulWidget {
  final int surah;
  final int ayah;
  final ThemeColors colors;
  final bool isDark;
  final bool isActiveVerse;
  final bool isRecording;
  final HighlightingController controller;
  final VoidCallback? onTapVerse;
  final bool? explicitIsPlaying;
  final bool? explicitIsBuffering;
  final VoidCallback? onExplicitToggle;

  const _VerseAudioButton({
    required this.surah,
    required this.ayah,
    required this.colors,
    required this.isDark,
    required this.isActiveVerse,
    required this.isRecording,
    required this.controller,
    this.onTapVerse,
    this.explicitIsPlaying,
    this.explicitIsBuffering,
    this.onExplicitToggle,
  });

  @override
  State<_VerseAudioButton> createState() => _VerseAudioButtonState();
}

class _VerseAudioButtonState extends State<_VerseAudioButton> {
  bool? _lastIsPlaying;
  bool? _lastIsBuffering;
  Widget? _cachedWidget;

  @override
  void didUpdateWidget(_VerseAudioButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.colors != widget.colors ||
        oldWidget.isDark != widget.isDark ||
        oldWidget.isActiveVerse != widget.isActiveVerse ||
        oldWidget.isRecording != widget.isRecording ||
        oldWidget.explicitIsPlaying != widget.explicitIsPlaying ||
        oldWidget.explicitIsBuffering != widget.explicitIsBuffering) {
      _cachedWidget = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.explicitIsPlaying != null) {
      return _buildButton(
        context,
        widget.explicitIsPlaying!,
        isBuffering: widget.explicitIsBuffering ?? false,
      );
    }

    return ListenableBuilder(
      listenable: widget.controller.globalRevision,
      builder: (context, _) {
        final bool isPlaying = VerseRow.isAyahAudioPlaying(
          surah: widget.surah,
          ayah: widget.ayah,
          controller: widget.controller,
        );
        final bool isBuffering = VerseRow.isAyahAudioBuffering(
          surah: widget.surah,
          ayah: widget.ayah,
          controller: widget.controller,
        );

        if (_cachedWidget != null &&
            _lastIsPlaying == isPlaying &&
            _lastIsBuffering == isBuffering) {
          return _cachedWidget!;
        }

        _lastIsPlaying = isPlaying;
        _lastIsBuffering = isBuffering;
        _cachedWidget =
            _buildButton(context, isPlaying, isBuffering: isBuffering);
        return _cachedWidget!;
      },
    );
  }

  Widget _buildButton(BuildContext context, bool isPlaying,
      {bool isBuffering = false}) {
    final Color iconColor;
    final Color bgColor;
    final Color borderColor;

    if (isPlaying || isBuffering) {
      // Active / Connecting state: Serene, dignified emerald accent across both themes
      if (widget.isDark) {
        bgColor = widget.colors.primary.withValues(alpha: 0.22);
        borderColor = widget.colors.primary.withValues(alpha: 0.60);
        iconColor = widget.colors.primary;
      } else {
        bgColor = widget.colors.primary.withValues(alpha: 0.12);
        borderColor = widget.colors.primary.withValues(alpha: 0.45);
        iconColor = widget.colors.primary;
      }
    } else {
      // Idle state: Subtle, gentle, eye-comforting — never competing with the Quran text
      // (Kept neutral and never tinted gold, so only the Ayah number and card border highlight)
      if (widget.isDark) {
        bgColor = widget.colors.surfaceHigh.withValues(alpha: 0.35);
        borderColor = widget.colors.border.withValues(alpha: 0.28);
        iconColor = widget.colors.textSecondary.withValues(alpha: 0.60);
      } else {
        bgColor = widget.colors.surfaceHigh.withValues(alpha: 0.50);
        borderColor = widget.colors.border.withValues(alpha: 0.55);
        iconColor = widget.colors.textSecondary.withValues(alpha: 0.65);
      }
    }

    return Semantics(
      button: true,
      label: isPlaying ? 'إيقاف مؤقت' : 'تشغيل التلاوة',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => VerseRow.toggleAyahAudio(
          surah: widget.surah,
          ayah: widget.ayah,
          controller: widget.controller,
          isRecording: widget.isRecording,
          onTap: widget.onTapVerse,
          onExplicitToggle: widget.onExplicitToggle,
        ),
        child: Container(
          width: 32,
          height: 30,
          color: Colors.transparent,
          child: Center(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOutCubic,
              width: 21.5,
              height: 21.5,
              decoration: BoxDecoration(
                color: bgColor,
                shape: BoxShape.circle,
                border: Border.all(
                  color: borderColor,
                  width: 0.85,
                ),
              ),
              child: Center(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 150),
                  transitionBuilder: (child, anim) => FadeTransition(
                    opacity: anim,
                    child: ScaleTransition(scale: anim, child: child),
                  ),
                  child: isBuffering
                      ? SizedBox(
                          key: const ValueKey('buffering'),
                          width: 10.5,
                          height: 10.5,
                          child: CircularProgressIndicator(
                            strokeWidth: 1.5,
                            valueColor:
                                AlwaysStoppedAnimation<Color>(iconColor),
                          ),
                        )
                      : Padding(
                          key: ValueKey(isPlaying),
                          padding: EdgeInsets.only(left: isPlaying ? 0 : 0.8),
                          child: Icon(
                            isPlaying
                                ? Icons.stop_rounded
                                : Icons.play_arrow_rounded,
                            size: 13.0,
                            color: iconColor,
                          ),
                        ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _VerseSpanItem {
  final int state;
  final bool isActive;
  final int startWord;
  final int endWord;
  double left;
  double right;
  final double top;
  final double bottom;
  final double lineCenterY;
  bool flatLeft = false;
  bool flatRight = false;

  _VerseSpanItem({
    required this.state,
    required this.isActive,
    required this.startWord,
    required this.endWord,
    required this.left,
    required this.right,
    required this.top,
    required this.bottom,
    required this.lineCenterY,
  });
}

/// Paints background highlight pills behind words in the verse row:
/// - Active lead word: Soft calming teal pill (Word N+1 anticipatory cursor).
/// - Correct words: Soft botanical sage pastel ribbon.
/// - Tajweed words: Soft warm amber pastel ribbon.
/// - Skipped/Error words: Soft terracotta coral pastel ribbon.
///
/// Text ink sits directly on top in crisp black/pearl, matching Mushaf mode.
class _ActiveWordHighlightPainter extends CustomPainter {
  final int surah;
  final int ayah;
  final List<String> words;
  final HighlightingController controller;
  final AppState app;
  final List<InlineSpan> cachedSpans;
  final bool isAudioMode;
  final bool isRecording;
  final bool isActive;
  final _AyahWordLayout? Function(double width) getWordLayout;

  _ActiveWordHighlightPainter({
    required this.surah,
    required this.ayah,
    required this.words,
    required this.controller,
    required this.app,
    required this.cachedSpans,
    required this.isAudioMode,
    required this.isRecording,
    required this.isActive,
    required this.getWordLayout,
  }) : super(repaint: controller.globalRevision);

  static final Paint _greenPaint = Paint()..style = PaintingStyle.fill;
  static final Paint _yellowPaint = Paint()..style = PaintingStyle.fill;
  static final Paint _redPaint = Paint()..style = PaintingStyle.fill;
  static final Paint _activePaint = Paint()..style = PaintingStyle.fill;

  @override
  void paint(Canvas canvas, Size size) {
    int activeIndex = -1;
    if (isAudioMode) {
      if (controller.isAudioPlaying || controller.isAudioBuffering) {
        activeIndex = controller.audioWordIndex ?? -1;
      }
    } else if (isActive && isRecording) {
      // Recitation matching mode: highlight the coming word to be recited (anticipatory lead cursor)
      for (int i = 0; i < words.length; i++) {
        if (!controller.isWordRead(ayah, i, surah: surah)) {
          activeIndex = i;
          break;
        }
      }
    }

    int getHighlightState(int i) {
      final s = controller.getWordStatus(ayah, i, surah: surah);
      if (s == null || s == 4) return 0;
      return s; // 1: green, 2: yellow, 3: red
    }

    bool hasAnyHighlights = (activeIndex >= 0);
    if (!hasAnyHighlights) {
      for (int i = 0; i < words.length; i++) {
        if (getHighlightState(i) > 0) {
          hasAnyHighlights = true;
          break;
        }
      }
    }
    if (!hasAnyHighlights) return;

    final layout = getWordLayout(size.width);
    if (layout == null) return;

    final bool isBlack = app.isDarkMode;
    final c = app.colors;
    _greenPaint.color = c.green.withValues(alpha: isBlack ? 0.22 : 0.15);
    _yellowPaint.color = c.warning.withValues(alpha: isBlack ? 0.24 : 0.18);
    _redPaint.color = c.red.withValues(alpha: isBlack ? 0.22 : 0.14);
    _activePaint.color =
        c.wordHighlight.withValues(alpha: isBlack ? 0.24 : 0.16);

    Paint getPaintForState(int state, bool isActiveWord) {
      if (isActiveWord) return _activePaint;
      if (state == 1) return _greenPaint;
      if (state == 2) return _yellowPaint;
      return _redPaint;
    }

    final List<_VerseSpanItem> spans = [];
    int i = 0;
    while (i < words.length) {
      final int state = getHighlightState(i);
      final bool isActiveWord = (i == activeIndex);
      if (state == 0 && !isActiveWord) {
        i++;
        continue;
      }

      final lineRects = layout.getWordLineRects(i);
      if (lineRects.isEmpty) {
        i++;
        continue;
      }

      final curRect = lineRects.first;
      double spanLeft = curRect.left;
      double spanRight = curRect.right;
      double spanTop = curRect.top;
      double spanBottom = curRect.bottom;
      final double lineCenterY = curRect.center.dy;

      int j = i + 1;
      if (!isActiveWord) {
        // Merge contiguous same-state words on the same line into one continuous ribbon
        while (j < words.length &&
            j != activeIndex &&
            getHighlightState(j) == state) {
          final nextRects = layout.getWordLineRects(j);
          if (nextRects.isNotEmpty &&
              (nextRects.first.center.dy - lineCenterY).abs() < 14.0) {
            spanLeft = math.min(spanLeft, nextRects.first.left);
            spanRight = math.max(spanRight, nextRects.first.right);
            spanTop = math.min(spanTop, nextRects.first.top);
            spanBottom = math.max(spanBottom, nextRects.first.bottom);
            j++;
          } else {
            break;
          }
        }
      }

      spans.add(_VerseSpanItem(
        state: state,
        isActive: isActiveWord,
        startWord: i,
        endWord: j,
        left: spanLeft,
        right: spanRight,
        top: spanTop,
        bottom: spanBottom,
        lineCenterY: lineCenterY,
      ));

      i = j;
    }

    // Detect and resolve boundaries between adjacent highlighted spans on the same line
    // Guarantees adjacent highlights (e.g. Yellow next to Green/Red) never bleed alpha or distort
    for (int p = 0; p < spans.length; p++) {
      final a = spans[p];
      for (int q = p + 1; q < spans.length; q++) {
        final b = spans[q];
        if ((a.lineCenterY - b.lineCenterY).abs() >= 14.0) continue;

        // Check if spans are direct word neighbors or overlap on screen
        final bool isWordNeighbor =
            (a.endWord == b.startWord || b.endWord == a.startWord);

        // Orient left/right on screen
        final _VerseSpanItem leftSpan;
        final _VerseSpanItem rightSpan;
        if (a.left <= b.left) {
          leftSpan = a;
          rightSpan = b;
        } else {
          leftSpan = b;
          rightSpan = a;
        }

        final bool overlapsOrTouches = leftSpan.right >= rightSpan.left - 2.5;

        if (isWordNeighbor || overlapsOrTouches) {
          final double midX = (leftSpan.right + rightSpan.left) / 2.0;
          leftSpan.right = midX - 0.8;
          rightSpan.left = midX + 0.8;
          leftSpan.flatRight = true;
          rightSpan.flatLeft = true;
        }
      }
    }

    for (final span in spans) {
      if (span.right <= span.left) continue;
      final double padLeft = span.flatLeft ? 0.0 : 3.0;
      final double padRight = span.flatRight ? 0.0 : 3.0;

      final rrect = RRect.fromRectAndCorners(
        Rect.fromLTRB(
          span.left - padLeft,
          span.top - 1.5,
          span.right + padRight,
          span.bottom + 1.5,
        ),
        topLeft: span.flatLeft ? Radius.zero : const Radius.circular(5.0),
        bottomLeft: span.flatLeft ? Radius.zero : const Radius.circular(5.0),
        topRight: span.flatRight ? Radius.zero : const Radius.circular(5.0),
        bottomRight: span.flatRight ? Radius.zero : const Radius.circular(5.0),
      );
      canvas.drawRRect(rrect, getPaintForState(span.state, span.isActive));
    }
  }

  @override
  bool shouldRepaint(covariant _ActiveWordHighlightPainter oldDelegate) {
    return oldDelegate.surah != surah ||
        oldDelegate.ayah != ayah ||
        oldDelegate.cachedSpans != cachedSpans ||
        oldDelegate.isAudioMode != isAudioMode ||
        oldDelegate.isRecording != isRecording ||
        oldDelegate.isActive != isActive;
  }
}

/// Precomputed layout geometry for an Ayah's words at a specific layout width.
/// Lazily evaluates HarfBuzz bounding boxes per requested word on demand.
class _AyahWordLayout {
  final double width;
  final List<InlineSpan> spans;
  final List<String> words;
  final TextPainter _painter;
  final List<int> _wordOffsets;
  final List<Rect?> _wordRects;
  final List<List<Rect>?> _wordLineRects;

  _AyahWordLayout._({
    required this.width,
    required this.spans,
    required this.words,
    required TextPainter painter,
    required List<int> wordOffsets,
    required List<Rect?> wordRects,
    required List<List<Rect>?> wordLineRects,
  })  : _painter = painter,
        _wordOffsets = wordOffsets,
        _wordRects = wordRects,
        _wordLineRects = wordLineRects;

  static _AyahWordLayout compute({
    required List<InlineSpan> spans,
    required List<String> words,
    required double width,
  }) {
    final painter = TextPainter(
      text: TextSpan(children: spans),
      textAlign: TextAlign.justify,
      textDirection: TextDirection.rtl,
    )..layout(minWidth: width, maxWidth: width);

    final wordOffsets = List<int>.filled(words.length, 0);
    int offset = 0;
    for (int i = 0; i < words.length; i++) {
      wordOffsets[i] = offset;
      offset += words[i].length + 1;
    }

    return _AyahWordLayout._(
      width: width,
      spans: spans,
      words: words,
      painter: painter,
      wordOffsets: wordOffsets,
      wordRects: List<Rect?>.filled(words.length, null),
      wordLineRects: List<List<Rect>?>.filled(words.length, null),
    );
  }

  void _computeWord(int i) {
    if (i < 0 || i >= words.length) return;
    final int charOffset = _wordOffsets[i];
    final int wordLen = words[i].length;
    final rawBoxes = _painter.getBoxesForSelection(
      TextSelection(
        baseOffset: charOffset,
        extentOffset: charOffset + wordLen,
      ),
    );

    final validBoxes =
        rawBoxes.where((b) => (b.right - b.left).abs() > 1.0).toList();

    if (validBoxes.isNotEmpty) {
      double left = math.min(validBoxes.first.left, validBoxes.first.right);
      double right = math.max(validBoxes.first.left, validBoxes.first.right);
      double top = math.min(validBoxes.first.top, validBoxes.first.bottom);
      double bottom = math.max(validBoxes.first.top, validBoxes.first.bottom);

      final List<Rect> lineBoxes = [];

      for (final box in validBoxes) {
        final bLeft = math.min(box.left, box.right);
        final bRight = math.max(box.left, box.right);
        final bTop = math.min(box.top, box.bottom);
        final bBottom = math.max(box.top, box.bottom);
        if (bLeft < left) left = bLeft;
        if (bRight > right) right = bRight;
        if (bTop < top) top = bTop;
        if (bBottom > bottom) bottom = bBottom;

        final rect = Rect.fromLTRB(bLeft, bTop, bRight, bBottom);

        int lineIndex = -1;
        for (int k = 0; k < lineBoxes.length; k++) {
          final existing = lineBoxes[k];
          if ((rect.top - existing.top).abs() < 12.0 ||
              (rect.bottom - existing.bottom).abs() < 12.0) {
            lineIndex = k;
            break;
          }
        }

        if (lineIndex >= 0) {
          lineBoxes[lineIndex] = lineBoxes[lineIndex].expandToInclude(rect);
        } else {
          lineBoxes.add(rect);
        }
      }

      _wordLineRects[i] = lineBoxes;
      _wordRects[i] = Rect.fromLTRB(left, top, right, bottom);
    } else {
      _wordLineRects[i] = const [];
      _wordRects[i] = null;
    }
  }

  List<Rect> getWordLineRects(int i) {
    if (i < 0 || i >= words.length) return const [];
    if (_wordLineRects[i] == null) {
      _computeWord(i);
    }
    return _wordLineRects[i] ?? const [];
  }

  Rect? getWordRect(int i) {
    if (i < 0 || i >= words.length) return null;
    if (_wordRects[i] == null && _wordLineRects[i] == null) {
      _computeWord(i);
    }
    return _wordRects[i];
  }

  void dispose() {
    _painter.dispose();
  }
}

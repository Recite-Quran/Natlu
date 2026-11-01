import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:recite_quran/recite_quran.dart';
import '../../../services/quran_audio_service.dart';
import '../../../state/app_state.dart';
import '../dialogs/error_detail_dialog.dart';
import 'verse_span_builder.dart';
import 'tajweed_tutorial_word.dart';

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

  static final List<String> _arabicDigitsCache = List<String>.generate(650, (i) {
    const digits = ['٠', '١', '٢', '٣', '٤', '٥', '٦', '٧', '٨', '٩'];
    return i.toString().split('').map((e) => digits[int.parse(e)]).join('');
  });

  /// Converts an integer to Eastern Arabic numeral glyphs (e.g. 1 -> '١').
  static String toArabicDigits(int number) {
    if (number >= 0 && number < _arabicDigitsCache.length) {
      return _arabicDigitsCache[number];
    }
    const digits = ['٠', '١', '٢', '٣', '٤', '٥', '٦', '٧', '٨', '٩'];
    return number.toString().split('').map((e) => digits[int.parse(e)]).join('');
  }

  /// Checks if audio is currently actively playing or buffering on this Ayah.
  static bool isAyahAudioActive({
    required int surah,
    required int ayah,
    required AppState app,
  }) {
    return (app.isAudioPlaying.value || app.isAudioBuffering.value) &&
        app.activeAudioSurah.value == surah &&
        app.activeAudioAyah.value == ayah;
  }

  /// Checks if the audio player is currently actively playing this Ayah.
  static bool isAyahAudioPlaying(int surah, int ayah) {
    final app = AppState.instance;
    return app.activeAudioSurah.value == surah &&
        app.activeAudioAyah.value == ayah &&
        app.isAudioPlaying.value;
  }

  /// Checks if the audio player is currently buffering this Ayah.
  static bool isAyahAudioBuffering(int surah, int ayah) {
    final app = AppState.instance;
    return app.activeAudioSurah.value == surah &&
        app.activeAudioAyah.value == ayah &&
        app.isAudioBuffering.value;
  }

  /// Handles selecting/tapping an Ayah: haptic feedback, manual selection, and persisting last position.
  static Future<void> selectAyah({
    required int surah,
    required int ayah,
    required HighlightingController controller,
    VoidCallback? onTap,
  }) async {
    HapticFeedback.lightImpact();
    if (controller.targetSurah != surah) {
      await controller.setTargetSurah(surah, preserveOtherSurahStates: true);
    }
    controller.setManualAyah(surah, ayah);
    AppState.instance.saveLastPosition(surah, ayah);
    onTap?.call();
  }

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
    final bool isAudioActive = isAyahAudioActive(surah: surah, ayah: ayah, app: app);
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
    final bool isAudioActive = isAyahAudioActive(surah: surah, ayah: ayah, app: app);

    if (isAudioActive) {
      return app.activeAudioWordIndex.value ?? -1;
    }

    if (isActive && isRecording) {
      for (int i = 0; i < words.length; i++) {
        if (!controller.isWordGreen(ayah, i, surah: surah) &&
            !controller.isWordRed(ayah, i, surah: surah) &&
            !controller.isWordYellow(ayah, i, surah: surah) &&
            !controller.isWordNeutral(ayah, i, surah: surah)) {
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

    final bool isAlreadySelected =
        controller.targetSurah == surah && controller.activeAyah.value == ayah;

    selectAyah(
      surah: surah,
      ayah: ayah,
      controller: controller,
      onTap: onAyahTap,
    );

    if (controller.isWordYellow(ayah, wordIndex, surah: surah)) {
      AppState.instance.markTajweedWordClicked();
      final errors = controller.getWordErrors(ayah, wordIndex);
      if (errors != null && errors.isNotEmpty) {
        ErrorDetailDialog.show(
          context,
          word: wordText,
          errors: errors,
          surah: surah,
          ayah: ayah,
          wordIndex: wordIndex,
        );
        onWordErrorTap?.call();
      }
    } else if (isAlreadySelected || playWordDirectly) {
      QuranAudioService.instance.playWord(
        surah: surah,
        ayah: ayah,
        wordIndex: wordIndex,
      );
    }
  }

  /// Toggles Ayah audio playback with buffering debounce and haptic feedback.
  static Future<void> toggleAyahAudio({
    required int surah,
    required int ayah,
    required HighlightingController controller,
    required bool isRecording,
    VoidCallback? onTap,
    VoidCallback? onExplicitToggle,
  }) async {
    if (AppState.instance.isAudioBuffering.value &&
        AppState.instance.activeAudioSurah.value == surah &&
        AppState.instance.activeAudioAyah.value == ayah) {
      return;
    }
    HapticFeedback.selectionClick();
    if (controller.targetSurah != surah) {
      await controller.setTargetSurah(
        surah,
        preserveOtherSurahStates: true,
        clearTargetSurah: false,
      );
    }
    controller.setManualAyah(surah, ayah);
    AppState.instance.saveLastPosition(surah, ayah);
    onTap?.call();
    if (onExplicitToggle != null) {
      onExplicitToggle();
    } else {
      AppState.instance.toggleVerseAudio(
        surah: surah,
        ayah: ayah,
        continuous: !isRecording,
      );
    }
  }

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
  int? _cachedRectTargetIndex;
  double? _cachedRectMaxWidth;
  Rect? _cachedWordRect;

  @override
  void initState() {
    super.initState();
    widget.controller.activeAyah.addListener(_onActiveAyahChanged);
    widget.controller.globalRevision.addListener(_onStateChanged);
    AppState.instance.blurModeNotifier.addListener(_onStateChanged);
    AppState.instance.isAudioPlaying.addListener(_onAudioStateChanged);
    AppState.instance.isAudioBuffering.addListener(_onAudioStateChanged);
    AppState.instance.activeAudioAyah.addListener(_onAudioStateChanged);
    AppState.instance.activeAudioSurah.addListener(_onAudioStateChanged);
    AppState.instance.activeAudioWordIndex.addListener(_onAudioWordChanged);
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
    AppState.instance.isAudioPlaying.removeListener(_onAudioStateChanged);
    AppState.instance.isAudioBuffering.removeListener(_onAudioStateChanged);
    AppState.instance.activeAudioAyah.removeListener(_onAudioStateChanged);
    AppState.instance.activeAudioSurah.removeListener(_onAudioStateChanged);
    AppState.instance.activeAudioWordIndex.removeListener(_onAudioWordChanged);
    _delayedWordPositionTimer?.cancel();
    _disposeRecognizers();
    super.dispose();
  }

  void _onAudioStateChanged() {
    final app = AppState.instance;
    final bool isAudioActive = VerseRow.isAyahAudioActive(
      surah: widget.verse.surah,
      ayah: widget.verse.ayah,
      app: app,
    );
    if (isAudioActive != _wasAudioActive) {
      _wasAudioActive = isAudioActive;
      _invalidate();
      if (mounted) setState(() {});
    }
    _scheduleWordPositionCheck();
  }

  void _onAudioWordChanged() {
    final app = AppState.instance;
    final bool isAudioActive = VerseRow.isAyahAudioActive(
      surah: widget.verse.surah,
      ayah: widget.verse.ayah,
      app: app,
    );
    if (isAudioActive) {
      _invalidate();
      _onStateChanged();
      _scheduleWordPositionCheck();
    }
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
    if (active != null) {
      if (myAyah == active || myAyah == active - 1 || myAyah == active + 1) {
        shouldListen = true;
      }
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
    _cachedWordColorsHash = null;
    _cachedWordColorsRevision = null;
    _cachedRectTargetIndex = null;
    _cachedRectMaxWidth = null;
    _cachedWordRect = null;
  }

  void _onStateChanged() {
    final fp = _computeFingerprint();
    if (fp != _lastFingerprint) {
      _lastFingerprint = fp;
      _cachedSpans = null;
      if (mounted) {
        if (SchedulerBinding.instance.schedulerPhase == SchedulerPhase.persistentCallbacks) {
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
    }
  }

  int _getActiveTargetIndex() {
    final app = AppState.instance;
    final surah = widget.verse.surah;
    final ayah = widget.verse.ayah;

    final bool isAudioActive = VerseRow.isAyahAudioActive(
      surah: surah,
      ayah: ayah,
      app: app,
    );

    if (isAudioActive) {
      return app.activeAudioWordIndex.value ?? -1;
    }

    final activeMatch = widget.controller.currentMatchedVerse;
    final bool isRecitingActive = activeMatch != null &&
        activeMatch.verse.surah == surah &&
        activeMatch.verse.ayah == ayah;
    final bool isSelected = widget.controller.activeAyah.value == ayah;
    final bool isReciting = widget.isRecording && (isRecitingActive || isSelected);

    if (!isReciting) {
      return -1;
    }

    final words = widget.verse.uthmaniWords;
    int lastSpoken = -1;
    for (int i = 0; i < words.length; i++) {
      if (widget.controller.isWordGreen(ayah, i, surah: widget.verse.surah) ||
          widget.controller.isWordRed(ayah, i, surah: widget.verse.surah) ||
          widget.controller.isWordYellow(ayah, i, surah: widget.verse.surah) ||
          widget.controller.isWordNeutral(ayah, i, surah: widget.verse.surah)) {
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
    if (!mounted || widget.isAutoScrolling || widget.onActiveWordPositioned == null) {
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
    if (!mounted || widget.isAutoScrolling || widget.onActiveWordPositioned == null) {
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

  Rect? _calculateWordRect(int targetIndex, double maxWidth) {
    if (_cachedSpans == null ||
        targetIndex < 0 ||
        targetIndex >= widget.verse.uthmaniWords.length ||
        maxWidth <= 0) {
      return null;
    }

    if (_cachedRectTargetIndex == targetIndex &&
        _cachedRectMaxWidth == maxWidth &&
        _cachedWordRect != null) {
      return _cachedWordRect;
    }

    final painter = TextPainter(
      text: TextSpan(children: _cachedSpans),
      textAlign: TextAlign.justify,
      textDirection: TextDirection.rtl,
    )..layout(minWidth: maxWidth, maxWidth: maxWidth);

    int charOffset = 0;
    final words = widget.verse.uthmaniWords;
    for (int i = 0; i < targetIndex; i++) {
      charOffset += words[i].length + 1;
    }

    final rawBoxes = painter.getBoxesForSelection(
      TextSelection(
        baseOffset: charOffset,
        extentOffset: charOffset + words[targetIndex].length,
      ),
    );
    painter.dispose();

    final validBoxes =
        rawBoxes.where((b) => (b.right - b.left).abs() > 1.0).toList();
    if (validBoxes.isEmpty) return null;

    double left = math.min(validBoxes.first.left, validBoxes.first.right);
    double right = math.max(validBoxes.first.left, validBoxes.first.right);
    double top = math.min(validBoxes.first.top, validBoxes.first.bottom);
    double bottom = math.max(validBoxes.first.top, validBoxes.first.bottom);

    for (int k = 1; k < validBoxes.length; k++) {
      final b = validBoxes[k];
      final bLeft = math.min(b.left, b.right);
      final bRight = math.max(b.left, b.right);
      final bTop = math.min(b.top, b.bottom);
      final bBottom = math.max(b.top, b.bottom);
      if (bLeft < left) left = bLeft;
      if (bRight > right) right = bRight;
      if (bTop < top) top = bTop;
      if (bBottom > bottom) bottom = bBottom;
    }

    final result = Rect.fromLTRB(left, top, right, bottom);
    _cachedRectTargetIndex = targetIndex;
    _cachedRectMaxWidth = maxWidth;
    _cachedWordRect = result;
    return result;
  }

  /// Compact hash representing active state, word colors, blur, theme, and font size.
  int _computeFingerprint() {
    final ctrl = widget.controller;
    final app = AppState.instance;
    final ayah = widget.verse.ayah;
    final surah = widget.verse.surah;
    final bool isSelected = !widget.isAutoScrolling && ctrl.activeAyah.value == ayah;
    final bool isAudioActive = VerseRow.isAyahAudioActive(surah: surah, ayah: ayah, app: app);
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
    hash = hash * 31 + (app.activeAudioWordIndex.value ?? -1);
    hash = hash * 31 + _getActiveTargetIndex();

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
    if (!hasHighlights) {
      wordColorsHash = 17;
      _cachedWordColorsHash = 17;
      _cachedWordColorsRevision = currentRevision;
    } else {
      final bool needsWordScan =
          _cachedWordColorsRevision != currentRevision ||
          _cachedWordColorsHash == null;

      if (needsWordScan) {
        int wHash = 17;
        final wordCount = widget.verse.uthmaniWords.length;
        for (int i = 0; i < wordCount; i++) {
          if (ctrl.isWordGreen(ayah, i, surah: widget.verse.surah)) {
            wHash = wHash * 31 + (i + 1) * 7;
          } else if (ctrl.isWordRed(ayah, i, surah: widget.verse.surah)) {
            wHash = wHash * 31 + (i + 1) * 13;
          } else if (ctrl.isWordYellow(ayah, i, surah: widget.verse.surah)) {
            wHash = wHash * 31 + (i + 1) * 17;
          } else if (ctrl.isWordNeutral(ayah, i, surah: widget.verse.surah)) {
            wHash = wHash * 31 + (i + 1) * 23;
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
    }
    final AppState app = AppState.instance;
    final ThemeColors c = app.colors;
    final words = widget.verse.uthmaniWords;
    final surah = widget.verse.surah;
    final ayah = widget.verse.ayah;
    final bool isAudioActive = VerseRow.isAyahAudioActive(surah: surah, ayah: ayah, app: app);
    final bool isActive = VerseRow.isAyahActive(
      surah: surah,
      ayah: ayah,
      controller: widget.controller,
      app: app,
      isAutoScrolling: widget.isAutoScrolling,
    );
    _wasAudioActive = isAudioActive;

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
                            ((isActive && widget.isRecording) || isAudioActive)
                        ? _ActiveWordHighlightPainter(
                            surah: widget.verse.surah,
                            ayah: widget.verse.ayah,
                            words: words,
                            controller: widget.controller,
                            app: app,
                            cachedSpans: _cachedSpans!,
                            isAudioMode: isAudioActive,
                            isRecording: widget.isRecording,
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
                          explicitIsPlaying: widget.isAudioPlaying,
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
class _VerseAudioButton extends StatelessWidget {
  final int surah;
  final int ayah;
  final ThemeColors colors;
  final bool isDark;
  final bool isActiveVerse;
  final bool isRecording;
  final HighlightingController controller;
  final VoidCallback? onTapVerse;
  final bool? explicitIsPlaying;
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
    this.onExplicitToggle,
  });

  @override
  Widget build(BuildContext context) {
    if (explicitIsPlaying != null) {
      return _buildButton(context, explicitIsPlaying!);
    }

    final app = AppState.instance;
    return ListenableBuilder(
      listenable: Listenable.merge([
        app.activeAudioAyah,
        app.activeAudioSurah,
        app.isAudioPlaying,
        app.isAudioBuffering,
      ]),
      builder: (context, _) {
        final bool isPlaying = VerseRow.isAyahAudioPlaying(surah, ayah);
        final bool isBuffering = VerseRow.isAyahAudioBuffering(surah, ayah);
        return _buildButton(context, isPlaying, isBuffering: isBuffering);
      },
    );
  }

  Widget _buildButton(BuildContext context, bool isPlaying, {bool isBuffering = false}) {
    final Color iconColor;
    final Color bgColor;
    final Color borderColor;

    if (isPlaying || isBuffering) {
      // Active / Connecting state: Serene, dignified emerald accent across both themes
      if (isDark) {
        bgColor = colors.primary.withValues(alpha: 0.22);
        borderColor = colors.primary.withValues(alpha: 0.60);
        iconColor = colors.primary;
      } else {
        bgColor = colors.primary.withValues(alpha: 0.12);
        borderColor = colors.primary.withValues(alpha: 0.45);
        iconColor = colors.primary;
      }
    } else {
      // Idle state: Subtle, gentle, eye-comforting — never competing with the Quran text
      // (Kept neutral and never tinted gold, so only the Ayah number and card border highlight)
      if (isDark) {
        bgColor = colors.surfaceHigh.withValues(alpha: 0.35);
        borderColor = colors.border.withValues(alpha: 0.28);
        iconColor = colors.textSecondary.withValues(alpha: 0.60);
      } else {
        bgColor = colors.surfaceHigh.withValues(alpha: 0.50);
        borderColor = colors.border.withValues(alpha: 0.55);
        iconColor = colors.textSecondary.withValues(alpha: 0.65);
      }
    }

    return Semantics(
      button: true,
      label: isPlaying ? 'إيقاف مؤقت' : 'تشغيل التلاوة',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => VerseRow.toggleAyahAudio(
          surah: surah,
          ayah: ayah,
          controller: controller,
          isRecording: isRecording,
          onTap: onTapVerse,
          onExplicitToggle: onExplicitToggle,
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
                            valueColor: AlwaysStoppedAnimation<Color>(iconColor),
                          ),
                        )
                      : Padding(
                          key: ValueKey(isPlaying),
                          padding: EdgeInsets.only(left: isPlaying ? 0 : 0.8),
                          child: Icon(
                            isPlaying ? Icons.stop_rounded : Icons.play_arrow_rounded,
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

/// Paints a tight, rounded background pill behind the current active target word.
/// Fits the word's actual font bounds instead of the entire line height.
class _ActiveWordHighlightPainter extends CustomPainter {
  final int surah;
  final int ayah;
  final List<String> words;
  final HighlightingController controller;
  final AppState app;
  final List<InlineSpan> cachedSpans;
  final bool isAudioMode;
  final bool isRecording;

  _ActiveWordHighlightPainter({
    required this.surah,
    required this.ayah,
    required this.words,
    required this.controller,
    required this.app,
    required this.cachedSpans,
    required this.isAudioMode,
    required this.isRecording,
  }) : super(
          repaint: isAudioMode
              ? Listenable.merge([
                  app.activeAudioWordIndex,
                  app.isAudioPlaying,
                  app.isAudioBuffering,
                ])
              : controller,
        );

  @override
  void paint(Canvas canvas, Size size) {
    final int activeIndex;
    if (isAudioMode) {
      if (!app.isAudioPlaying.value && !app.isAudioBuffering.value) return;
      activeIndex = app.activeAudioWordIndex.value ?? -1;
    } else {
      if (!isRecording) return;
      // Recitation matching mode: highlight the coming word to be recited
      int nextUnspoken = -1;
      for (int i = 0; i < words.length; i++) {
        if (!controller.isWordGreen(ayah, i, surah: surah) &&
            !controller.isWordRed(ayah, i, surah: surah) &&
            !controller.isWordYellow(ayah, i, surah: surah) &&
            !controller.isWordNeutral(ayah, i, surah: surah)) {
          nextUnspoken = i;
          break;
        }
      }
      activeIndex = nextUnspoken;
    }

    if (activeIndex < 0 || activeIndex >= words.length) return;

    final painter = TextPainter(
      text: TextSpan(children: cachedSpans),
      textAlign: TextAlign.justify,
      textDirection: TextDirection.rtl,
    )..layout(minWidth: size.width, maxWidth: size.width);

    int charOffset = 0;
    for (int i = 0; i < activeIndex; i++) {
      charOffset += words[i].length + 1;
    }

    final rawBoxes = painter.getBoxesForSelection(
      TextSelection(
        baseOffset: charOffset,
        extentOffset: charOffset + words[activeIndex].length,
      ),
    );
    painter.dispose();

    // Filter out zero-width cursor affinity / line margin boxes that cause bounds explosion
    final validBoxes =
        rawBoxes.where((b) => (b.right - b.left).abs() > 1.0).toList();
    if (validBoxes.isEmpty) return;

    final bool isBlack = app.isDarkMode;
    final Color highlightColor = app.colors.wordHighlight;
    final double opacity = isBlack ? 0.14 : 0.095;
    final paint = Paint()
      ..color = highlightColor.withValues(alpha: opacity)
      ..style = PaintingStyle.fill;

    // Group boxes by line to unite all letter/glyph boxes into one smooth, single word pill
    final List<Rect> lineRects = [];
    for (final box in validBoxes) {
      final bLeft = math.min(box.left, box.right);
      final bRight = math.max(box.left, box.right);
      final bTop = math.min(box.top, box.bottom);
      final bBottom = math.max(box.top, box.bottom);
      final rect = Rect.fromLTRB(bLeft, bTop, bRight, bBottom);

      int lineIndex = -1;
      for (int i = 0; i < lineRects.length; i++) {
        final existing = lineRects[i];
        if ((rect.top - existing.top).abs() < 12.0 ||
            (rect.bottom - existing.bottom).abs() < 12.0) {
          lineIndex = i;
          break;
        }
      }

      if (lineIndex >= 0) {
        lineRects[lineIndex] = lineRects[lineIndex].expandToInclude(rect);
      } else {
        lineRects.add(rect);
      }
    }

    for (final lineRect in lineRects) {
      final rrect = RRect.fromRectAndRadius(
        Rect.fromLTRB(
          lineRect.left - 4.0,
          lineRect.top - 2.0,
          lineRect.right + 4.0,
          lineRect.bottom + 2.0,
        ),
        const Radius.circular(8),
      );
      canvas.drawRRect(rrect, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _ActiveWordHighlightPainter oldDelegate) {
    return oldDelegate.surah != surah ||
        oldDelegate.ayah != ayah ||
        oldDelegate.cachedSpans != cachedSpans ||
        oldDelegate.isAudioMode != isAudioMode ||
        oldDelegate.isRecording != isRecording;
  }
}


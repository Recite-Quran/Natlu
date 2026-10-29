import 'package:flutter/material.dart';
import 'package:recite_quran/recite_quran.dart';
import '../../../services/app_haptics.dart';
import '../../../services/quran_audio_service.dart';
import '../../../state/app_state.dart';

/// 2026 Tajweed & Pronunciation Breakdown Modal Bottom Sheet.
///
/// Features:
/// - Lightweight modern background adhering strictly to Natlu's theme tokens.
/// - Top row strictly displays target word on the right and audio player on the left.
/// - Multi-card layout: 2 cards side-by-side per row, and if 3 cards, 2 beside each other and 1 down.
/// - Single card displays at full comfortable width.
/// - 100% overflow-proof architecture with Flexible/FittedBox protection across all screen widths.
/// - Ample spacing and comfortable heights prioritizing breathing room without collapsing elements.
/// - Completely removes redundant robotic labels ("خطأ في نطق الحرف: المتوقع... ونطق...").
/// - Phonetic comparison arrow flipped to always point from user recitation towards the correct letter.
/// - Actionable guidance banner using app's warm elevation styling.
class ErrorDetailDialog extends StatelessWidget {
  final String word;
  final List<ReciterError> errors;
  final int? surah;
  final int? ayah;
  final int? wordIndex;

  const ErrorDetailDialog({
    super.key,
    required this.word,
    required this.errors,
    this.surah,
    this.ayah,
    this.wordIndex,
  });

  /// Static helper to display the modal bottom sheet cleanly.
  static void show(
    BuildContext context, {
    required String word,
    required List<ReciterError> errors,
    int? surah,
    int? ayah,
    int? wordIndex,
  }) {
    if (errors.isEmpty) return;
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => ErrorDetailDialog(
        word: word,
        errors: errors,
        surah: surah,
        ayah: ayah,
        wordIndex: wordIndex,
      ),
    ).then((_) {
      QuranAudioService.instance.stop();
    });
  }

  @override
  Widget build(BuildContext context) {
    final app = AppState.instance;
    return RepaintBoundary(
      child: ListenableBuilder(
        listenable: app,
        builder: (context, _) {
          final c = app.colors;
          final isAr = app.isArabic;
          final isDark = app.isDarkMode;

          return Directionality(
            textDirection: isAr ? TextDirection.rtl : TextDirection.ltr,
            child: Container(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(context).size.height * 0.82,
              ),
              decoration: BoxDecoration(
                color: c.surface,
                borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
                border: Border.all(
                  color: isDark
                      ? c.border.withValues(alpha: 0.35)
                      : c.border.withValues(alpha: 0.70),
                  width: 1,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: isDark ? 0.35 : 0.08),
                    blurRadius: 16,
                    offset: const Offset(0, -4),
                  ),
                ],
              ),
              child: Material(
                color: Colors.transparent,
                child: SafeArea(
                  top: false,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // ── Handle Bar ──
                      Padding(
                        padding: const EdgeInsets.only(top: 14, bottom: 12),
                        child: Container(
                          width: 44,
                          height: 4,
                            decoration: BoxDecoration(
                              color: isDark
                                  ? c.border.withValues(alpha: 0.8)
                                  : c.border,
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                        ),

                        // ── Top Row: Word strictly on Right & Audio Player on Left (Overflow-Proof) ──
                        Directionality(
                          textDirection: TextDirection.rtl,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 18),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Expanded(
                                  child: Text(
                                    word,
                                    textDirection: TextDirection.rtl,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 30,
                                      color: c.text,
                                      height: 1.25,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                if (surah != null && ayah != null && wordIndex != null)
                                  _buildWordAudioPlayerButton(c, isAr, isDark),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 16),

                        // ── Scrollable Body: 2 cards side-by-side, 3rd down ──
                        Flexible(
                          child: SingleChildScrollView(
                            physics: const BouncingScrollPhysics(),
                            padding: const EdgeInsets.fromLTRB(12, 0, 12, 30),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: _buildErrorCardsLayout(c, isAr, isDark),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      );
    }

  // ──────────────────────────────────────────────────────────────────────────
  // Word Audio Player Button (Theme Emerald Styling)
  // ──────────────────────────────────────────────────────────────────────────
  Widget _buildWordAudioPlayerButton(ThemeColors c, bool isAr, bool isDark) {
    final app = AppState.instance;
    return ListenableBuilder(
      listenable: Listenable.merge([
        app.isAudioPlaying,
        app.activeAudioSurah,
        app.activeAudioAyah,
        app.activeAudioWordIndex,
      ]),
      builder: (context, _) {
        final bool isPlaying = app.isAudioPlaying.value &&
            app.activeAudioSurah.value == surah &&
            app.activeAudioAyah.value == ayah &&
            app.activeAudioWordIndex.value == wordIndex;

        return Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: () {
              AppHaptics.lightImpact();
              if (isPlaying) {
                QuranAudioService.instance.pause();
              } else {
                QuranAudioService.instance.playWord(
                  surah: surah!,
                  ayah: ayah!,
                  wordIndex: wordIndex!,
                );
              }
            },
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOutCubic,
              padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
              decoration: BoxDecoration(
                color: isPlaying
                    ? c.primary
                    : c.primary.withValues(alpha: isDark ? 0.16 : 0.10),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: isPlaying
                      ? c.primary
                      : c.primary.withValues(alpha: isDark ? 0.40 : 0.35),
                  width: 1.2,
                ),
                boxShadow: isPlaying
                    ? [
                        BoxShadow(
                          color: c.primary.withValues(alpha: 0.35),
                          blurRadius: 12,
                          offset: const Offset(0, 3),
                        ),
                      ]
                    : null,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    isPlaying ? Icons.pause_rounded : Icons.volume_up_rounded,
                    size: 18,
                    color: isPlaying
                        ? Colors.white
                        : (isDark ? Colors.white : c.primary),
                  ),
                  const SizedBox(width: 7),
                  Text(
                    isPlaying
                        ? (isAr ? 'إيقاف' : 'Pause')
                        : (isAr ? 'استمع للقارئ' : 'Listen'),
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: isPlaying
                          ? Colors.white
                          : (isDark ? Colors.white : c.primary),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Layout Logic: 2 cards side-by-side; if 3, 2 beside and 1 down
  // ──────────────────────────────────────────────────────────────────────────
  List<Widget> _buildErrorCardsLayout(
    ThemeColors c,
    bool isAr,
    bool isDark,
  ) {
    if (errors.length == 1) {
      return [_buildErrorCard(errors[0], c, isAr, isDark, isCompact: false)];
    }

    final List<Widget> rows = [];
    int i = 0;
    while (i < errors.length) {
      if (i + 1 < errors.length) {
        // Two cards beside each other
        rows.add(
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: _buildErrorCard(
                    errors[i],
                    c,
                    isAr,
                    isDark,
                    isCompact: true,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _buildErrorCard(
                    errors[i + 1],
                    c,
                    isAr,
                    isDark,
                    isCompact: true,
                  ),
                ),
              ],
            ),
          ),
        );
        i += 2;
      } else {
        // Odd card down below at full width
        rows.add(
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: _buildErrorCard(
              errors[i],
              c,
              isAr,
              isDark,
              isCompact: false,
            ),
          ),
        );
        i += 1;
      }
    }
    return rows;
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Error Card Widget (Unified App Theme & Zero Collapsed Heights)
  // ──────────────────────────────────────────────────────────────────────────
  Widget _buildErrorCard(
    ReciterError e,
    ThemeColors c,
    bool isAr,
    bool isDark, {
    required bool isCompact,
  }) {
    final expected = e.expectedPh.isEmpty ? '—' : _cleanPhonetic(e.expectedPh);
    final predicted = e.predictedPh.isEmpty ? '—' : _cleanPhonetic(e.predictedPh);
    final bool isDurationErr = e.expectedDuration != null && e.actualDuration != null;

    String title;
    Color accent;
    String advice = '';

    if (e.errorType == ErrorCategory.tajweed) {
      String ruleName = isAr
          ? (e.expectedRule?.name.ar ?? '')
          : (e.expectedRule?.name.en ?? '');
      if (ruleName.isEmpty) {
        ruleName = isAr ? 'حكم تجويد' : 'Tajweed Rule';
      }
      title = ruleName;
      accent = c.primary; // Serene theme emerald
      advice = isAr ? e.adviceAr : e.adviceEn;
    } else if (e.errorType == ErrorCategory.tashkeel) {
      title = isAr ? 'خطأ في التشكيل' : 'Vowel Mark';
      accent = c.info;
      advice = isAr ? e.adviceAr : e.adviceEn;
    } else {
      if (e.speechErrorType == SpeechErrorType.insert) {
        title = isAr ? 'إضافة حرف زائد' : 'Extra Letter';
      } else if (e.speechErrorType == SpeechErrorType.delete) {
        title = isAr ? 'حرف ساقط' : 'Omitted Letter';
      } else {
        title = isAr ? 'خطأ في النطق' : 'Pronunciation';
      }
      accent = c.red;
      advice = isAr ? e.adviceAr : e.adviceEn;
    }

    final Color cardBackground = isDark ? c.surfaceHigh : c.surface;
    final Color cardBorderColor = isDark
        ? accent.withValues(alpha: 0.30)
        : accent.withValues(alpha: 0.22);

    return Container(
      decoration: BoxDecoration(
        color: cardBackground,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: cardBorderColor,
          width: 1.2,
        ),
        boxShadow: [
          BoxShadow(
            color: isDark
                ? Colors.black.withValues(alpha: 0.25)
                : Colors.black.withValues(alpha: 0.04),
            blurRadius: 12,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── Card Header ──
          Container(
            padding: EdgeInsets.symmetric(
              horizontal: isCompact ? 10 : 16,
              vertical: isCompact ? 9 : 12,
            ),
            decoration: BoxDecoration(
              color: accent.withValues(alpha: isDark ? 0.12 : 0.08),
              borderRadius: const BorderRadius.vertical(top: Radius.circular(18)),
              border: Border(
                bottom: BorderSide(
                  color: accent.withValues(alpha: isDark ? 0.22 : 0.16),
                  width: 1,
                ),
              ),
            ),
            child: Row(
              children: [
                Container(
                  width: isCompact ? 6 : 8,
                  height: isCompact ? 6 : 8,
                  decoration: BoxDecoration(
                    color: accent,
                    shape: BoxShape.circle,
                  ),
                ),
                SizedBox(width: isCompact ? 6 : 10),
                Expanded(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: accent,
                      fontWeight: FontWeight.w700,
                      fontSize: isCompact ? 13 : 15.5,
                      letterSpacing: isAr ? 0.0 : -0.2,
                      height: isAr ? 1.3 : 1.2,
                    ),
                  ),
                ),
              ],
            ),
          ),

          // ── Card Body with Longer Spaces & Zero Collapsed Heights ──
          Padding(
            padding: EdgeInsets.all(isCompact ? 9 : 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // ── 1. Visual Letter Showcase or Phonetic Box (NO redundant labels!) ──
                if (isDurationErr || e.errorType == ErrorCategory.tajweed) ...[
                  if (expected != '—' && expected.isNotEmpty) ...[
                    _buildLetterShowcaseBox(
                      expected,
                      accent,
                      c,
                      isAr,
                      isDark,
                      isCompact: isCompact,
                    ),
                    SizedBox(height: isCompact ? 8 : 14), // Longer space
                  ],
                ] else ...[
                  if (expected != '—' || predicted != '—') ...[
                    _buildPhoneticComparison(
                      expected,
                      predicted,
                      c,
                      isAr,
                      isDark,
                      isCompact: isCompact,
                    ),
                    SizedBox(height: isCompact ? 8 : 14), // Longer space
                  ],
                ],

                // ── 2. Duration Visualizer (if duration error) ──
                if (isDurationErr) ...[
                  _buildDurationVisualizer(
                    e.expectedDuration!,
                    e.actualDuration!,
                    accent,
                    c,
                    isAr,
                    durationStatus: e.durationStatus,
                    isDark: isDark,
                    isCompact: isCompact,
                  ),
                  if (advice.isNotEmpty) SizedBox(height: isCompact ? 8 : 14), // Longer space
                ],

                // ── 3. Actionable Advice Banner (Clean & Helpful guidance only) ──
                if (advice.isNotEmpty) ...[
                  Container(
                    padding: EdgeInsets.symmetric(
                      horizontal: isCompact ? 8 : 14,
                      vertical: isCompact ? 7 : 12,
                    ),
                    decoration: BoxDecoration(
                      color: isDark
                          ? c.surfaceVariant.withValues(alpha: 0.50)
                          : c.surfaceHigh.withValues(alpha: 0.70),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: accent.withValues(alpha: 0.20),
                        width: 1,
                      ),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.lightbulb_outline_rounded,
                          size: isCompact ? 14 : 18,
                          color: accent,
                        ),
                        SizedBox(width: isCompact ? 6 : 10),
                        Expanded(
                          child: Text(
                            advice,
                            maxLines: isCompact ? 3 : null,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: c.text,
                              fontSize: isCompact ? 11 : 13.5,
                              fontWeight: FontWeight.w600,
                              height: 1.35,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Duration Visualizer Bar Component (Guaranteed 100% Overflow-Proof)
  // ──────────────────────────────────────────────────────────────────────────
  Widget _buildDurationVisualizer(
    double expected,
    double actual,
    Color accent,
    ThemeColors c,
    bool isAr, {
    TajweedDurationStatus? durationStatus,
    required bool isDark,
    required bool isCompact,
  }) {
    final double rawRatio = expected > 0 ? (actual / expected).clamp(0.0, 1.0) : 0.0;
    final double visibleWidthFactor = rawRatio.clamp(0.05, 1.0);

    final bool isUnderheld = durationStatus == TajweedDurationStatus.underheld ||
        (durationStatus == null && actual < expected);
    final bool isOverheld = durationStatus == TajweedDurationStatus.overheld ||
        (durationStatus == null && actual > expected);

    final String statusLabel = isUnderheld
        ? (isAr ? 'نقص' : 'Underheld')
        : isOverheld
            ? (isAr ? 'زيادة' : 'Overheld')
            : (isAr ? 'صحيح' : 'Valid');

    final Color statusColor = isUnderheld
        ? c.red
        : isOverheld
            ? (isDark ? c.gold : c.warning)
            : c.primary;

    return Container(
      padding: EdgeInsets.all(isCompact ? 8 : 14),
      decoration: BoxDecoration(
        color: isDark
            ? c.surfaceVariant.withValues(alpha: 0.45)
            : c.surfaceHigh.withValues(alpha: 0.65),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isDark
              ? c.border.withValues(alpha: 0.35)
              : c.border.withValues(alpha: 0.60),
          width: 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Line 1: Duration label on start, Status badge on end (Protected against overflow with Flexible/Ellipsis)
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Flexible(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.timer_outlined,
                      size: isCompact ? 12 : 16,
                      color: c.muted,
                    ),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text(
                        isAr ? 'المدة:' : 'Duration:',
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: c.textSecondary,
                          fontSize: isCompact ? 9.5 : 12.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 4),
              Container(
                padding: EdgeInsets.symmetric(
                  horizontal: isCompact ? 5 : 10,
                  vertical: isCompact ? 2 : 3.5,
                ),
                decoration: BoxDecoration(
                  color: statusColor.withValues(alpha: isDark ? 0.16 : 0.12),
                  borderRadius: BorderRadius.circular(5),
                  border: Border.all(
                    color: statusColor.withValues(alpha: isDark ? 0.35 : 0.28),
                    width: 0.8,
                  ),
                ),
                child: Text(
                  statusLabel,
                  style: TextStyle(
                    color: statusColor,
                    fontSize: isCompact ? 8.5 : 11.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          SizedBox(height: isCompact ? 5 : 10), // Longer space

          // Line 2: Actual vs Expected seconds (Protected with Flexible)
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Flexible(
                child: Text(
                  '${actual.toStringAsFixed(2)}s',
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: statusColor,
                    fontSize: isCompact ? 11.5 : 15,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              Flexible(
                child: Text(
                  ' / ${expected.toStringAsFixed(2)}s',
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: c.muted,
                    fontSize: isCompact ? 10 : 13.5,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
          SizedBox(height: isCompact ? 5 : 10), // Longer space

          // Line 3: Progress Track
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: SizedBox(
              height: isCompact ? 5.5 : 7,
              child: Stack(
                alignment: AlignmentDirectional.centerStart,
                children: [
                  Container(
                    decoration: BoxDecoration(
                      color: isDark
                          ? c.border.withValues(alpha: 0.35)
                          : c.border.withValues(alpha: 0.65),
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                  FractionallySizedBox(
                    widthFactor: visibleWidthFactor,
                    child: Container(
                      decoration: BoxDecoration(
                        color: statusColor,
                        borderRadius: BorderRadius.circular(4),
                        boxShadow: [
                          BoxShadow(
                            color: statusColor.withValues(alpha: 0.35),
                            blurRadius: 4,
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          SizedBox(height: isCompact ? 5 : 8),

          // Line 4: Duration Advice Guidance (Protected with ellipsis)
          Text(
            isUnderheld
                ? (isAr ? 'نقص: أطِل المد ↑' : 'Underheld: Hold longer ↑')
                : isOverheld
                    ? (isAr ? 'زيادة: لا تبالغ ↓' : 'Overheld: Avoid excess ↓')
                    : (isAr ? 'المدة صحيحة ✓' : 'Duration is valid ✓'),
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: statusColor,
              fontSize: isCompact ? 9.5 : 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Letter Showcase Box (Comfortable Height & Longer Spacing)
  // ──────────────────────────────────────────────────────────────────────────
  Widget _buildLetterShowcaseBox(
    String expected,
    Color accent,
    ThemeColors c,
    bool isAr,
    bool isDark, {
    required bool isCompact,
  }) {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.symmetric(
        vertical: isCompact ? 7 : 12,
        horizontal: isCompact ? 8 : 16,
      ),
      decoration: BoxDecoration(
        color: isDark
            ? c.surfaceVariant.withValues(alpha: 0.45)
            : c.surfaceHigh.withValues(alpha: 0.65),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isDark
              ? c.border.withValues(alpha: 0.35)
              : c.border.withValues(alpha: 0.60),
          width: 1,
        ),
      ),
      alignment: Alignment.center,
      child: Directionality(
        textDirection: TextDirection.rtl,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                isAr ? 'حرف' : 'Letter',
                style: TextStyle(
                  color: accent,
                  fontSize: isCompact ? 11 : 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            SizedBox(width: isCompact ? 6 : 12), // Longer space
            Flexible(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  expected,
                  textDirection: TextDirection.rtl,
                  style: TextStyle(
                    color: c.text,
                    fontSize: isCompact ? 21 : 26,
                    fontWeight: FontWeight.bold,
                    height: 1.15,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Phonetic Comparison Box: Arrow points FROM user attempt TO correct letter
  // ──────────────────────────────────────────────────────────────────────────
  // In Arabic (RTL):
  //   Right: "نطقك" (Yours) ──► Middle Arrow (pointing Left ←) ──► Left: "الصواب" (Correct)
  // In English (LTR):
  //   Left: "Yours" ──► Middle Arrow (pointing Right →) ──► Right: "Correct"
  // In both reading directions:
  //   The arrow points TOWARDS the correct standard, NEVER towards the wrong letter.
  // ──────────────────────────────────────────────────────────────────────────
  Widget _buildPhoneticComparison(
    String expected,
    String predicted,
    ThemeColors c,
    bool isAr,
    bool isDark, {
    required bool isCompact,
  }) {
    final Color correctGreen = c.primary;
    final Color errorRed = c.red;

    // Display string for user attempt (clean dash if omitted)
    final String displayPredicted = (predicted.isEmpty || predicted == '—')
        ? '—'
        : predicted;

    final Widget yoursBox = Expanded(
      child: Container(
        padding: EdgeInsets.symmetric(
          vertical: isCompact ? 6 : 10,
          horizontal: isCompact ? 3 : 12,
        ),
        decoration: BoxDecoration(
          color: errorRed.withValues(alpha: isDark ? 0.12 : 0.08),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: errorRed.withValues(alpha: 0.30),
            width: 1,
          ),
        ),
        child: Column(
          children: [
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                isAr ? 'نطقك' : 'Yours',
                style: TextStyle(
                  color: errorRed,
                  fontSize: isCompact ? 10 : 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            SizedBox(height: isCompact ? 3 : 6), // Longer space
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                displayPredicted,
                textDirection: TextDirection.rtl,
                style: TextStyle(
                  color: c.text,
                  fontSize: isCompact ? 16 : 22,
                  fontWeight: FontWeight.bold,
                  height: 1.2,
                ),
              ),
            ),
          ],
        ),
      ),
    );

    // Arrow pointing towards the correct standard:
    // In RTL reading: pointing Left (←) towards Correct on the left
    // In LTR reading: pointing Right (→) towards Correct on the right
    final Widget arrowWidget = Padding(
      padding: EdgeInsets.symmetric(horizontal: isCompact ? 3 : 14),
      child: Icon(
        isAr ? Icons.arrow_back_rounded : Icons.arrow_forward_rounded,
        color: isDark ? c.muted : const Color(0xFF64748B),
        size: isCompact ? 15 : 22,
      ),
    );

    final Widget correctBox = Expanded(
      child: Container(
        padding: EdgeInsets.symmetric(
          vertical: isCompact ? 6 : 10,
          horizontal: isCompact ? 3 : 12,
        ),
        decoration: BoxDecoration(
          color: correctGreen.withValues(alpha: isDark ? 0.12 : 0.08),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: correctGreen.withValues(alpha: 0.35),
            width: 1,
          ),
        ),
        child: Column(
          children: [
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                isAr ? 'الصواب' : 'Correct',
                style: TextStyle(
                  color: correctGreen,
                  fontSize: isCompact ? 10 : 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            SizedBox(height: isCompact ? 3 : 6), // Longer space
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                expected,
                textDirection: TextDirection.rtl,
                style: TextStyle(
                  color: c.text,
                  fontSize: isCompact ? 16 : 22,
                  fontWeight: FontWeight.bold,
                  height: 1.2,
                ),
              ),
            ),
          ],
        ),
      ),
    );

    return Container(
      padding: EdgeInsets.all(isCompact ? 6 : 12),
      decoration: BoxDecoration(
        color: isDark
            ? c.surfaceVariant.withValues(alpha: 0.40)
            : c.surfaceHigh.withValues(alpha: 0.65),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isDark
              ? c.border.withValues(alpha: 0.35)
              : c.border.withValues(alpha: 0.60),
          width: 1,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: isAr
            ? [
                // In Arabic RTL: Yours on Right, Arrow pointing Left, Correct on Left
                yoursBox,
                arrowWidget,
                correctBox,
              ]
            : [
                // In English LTR: Yours on Left, Arrow pointing Right, Correct on Right
                yoursBox,
                arrowWidget,
                correctBox,
              ],
      ),
    );
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Phonetic Sanitizer Helper
  // ──────────────────────────────────────────────────────────────────────────
  static String _cleanPhonetic(String input) {
    if (input.isEmpty) return input;

    String cleaned = input
        .replaceAll('\u06e5', 'و')
        .replaceAll('\u06e6', 'ي')
        .replaceAll('\u06ba', 'ن')
        .replaceAll('\u06fe', 'م')
        .replaceAll('\u0687', '')
        .replaceAll('ڇ', '')
        .replaceAll('ۜ', '')
        .replaceAll('۪', '')
        .replaceAll('ؙ', '')
        .replaceAll('ٲ', 'أ')
        .replaceAll('\u0640', '')
        .replaceAll('\u200B', '')
        .replaceAll('\u200C', '')
        .replaceAll('\u200D', '');

    cleaned = cleaned.replaceAllMapped(
      RegExp(r'([\u0621-\u064A])\1+'),
      (match) => match.group(1)!,
    );

    cleaned = cleaned.replaceAllMapped(
      RegExp(r'([\u0621-\u064A][\u064B-\u065F]?)(?:\1)+'),
      (match) => match.group(1)!,
    );

    return cleaned.trim();
  }
}

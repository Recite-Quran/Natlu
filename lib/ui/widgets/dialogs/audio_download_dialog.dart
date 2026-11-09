import 'dart:async';
import 'package:flutter/material.dart';
import '../../../audio/quran_download_service.dart';
import '../../../core/app_state.dart';
import '../../../core/highlighting_controller.dart';
import '../../../core/platform_utils.dart';
import 'dialog_base.dart';

/// Minimal, elegant modal dialog for downloading Quran recitation.
///
/// Fingerprint:
/// - Uses [AppDialog] and [DialogTokens] for 100% unified app design.
/// - Single unified Surah table with instant individual & select-all toggle.
/// - Minimal labels, zero bloat, live remaining download size.
/// - Live progress bar with pause/resume, cancel, and minimize when downloading.
class AudioDownloadDialog extends StatefulWidget {
  const AudioDownloadDialog({super.key});

  /// Displays the download dialog modally.
  static Future<void> show(BuildContext context) {
    QuranDownloadService.instance.setMinimized(false);
    return showDialog<void>(
      context: context,
      barrierColor: DialogTokens.barrierColor,
      barrierDismissible: true,
      builder: (_) => const AudioDownloadDialog(),
    );
  }

  @override
  State<AudioDownloadDialog> createState() => _AudioDownloadDialogState();
}

class _AudioDownloadDialogState extends State<AudioDownloadDialog> {
  final Set<int> _selectedSurahs = {for (int i = 1; i <= 114; i++) i};
  Set<int> _downloadedSurahs = {};
  Map<int, double> _surahRemainingMbMap = {};
  final ScrollController _scrollController = ScrollController();

  double _remainingSizeMb = 0.0;
  bool _isCalculating = true;

  @override
  void initState() {
    super.initState();
    _refreshDiskState();
    QuranDownloadService.instance.isDownloading.addListener(_onDownloadStateChanged);
  }

  @override
  void dispose() {
    QuranDownloadService.instance.isDownloading.removeListener(_onDownloadStateChanged);
    _scrollController.dispose();
    super.dispose();
  }

  void _onDownloadStateChanged() {
    if (!QuranDownloadService.instance.isDownloading.value && mounted) {
      _refreshDiskState();
    }
  }

  Future<void> _refreshDiskState() async {
    if (!mounted) return;
    setState(() => _isCalculating = true);

    final downloaded = await QuranDownloadService.getDownloadedSurahs();
    final Map<int, double> map = {};
    for (int s = 1; s <= 114; s++) {
      if (downloaded.contains(s)) {
        map[s] = 0.0;
      } else {
        final totalAyahs = QuranMetadata.getAyahCount(s);
        final downloadedAyahs = await QuranDownloadService.getDownloadedAyahsCount(s);
        final missing = totalAyahs - downloadedAyahs;
        map[s] = (missing * 95.0) / 1024.0;
      }
    }

    if (mounted) {
      setState(() {
        _downloadedSurahs = downloaded;
        _surahRemainingMbMap = map;
        _remainingSizeMb = _selectedSurahs.fold(
          0.0,
          (sum, s) => sum + (map[s] ?? 0.0),
        );
        _isCalculating = false;
      });
    }
  }

  void _onToggleSurah(int surah) {
    AppHaptics.lightImpact();
    setState(() {
      if (_selectedSurahs.contains(surah)) {
        _selectedSurahs.remove(surah);
      } else {
        _selectedSurahs.add(surah);
      }
      _remainingSizeMb = _selectedSurahs.fold(
        0.0,
        (sum, s) => sum + (_surahRemainingMbMap[s] ?? 0.0),
      );
    });
  }

  void _toggleSelectAll() {
    AppHaptics.lightImpact();
    setState(() {
      if (_selectedSurahs.length == 114) {
        _selectedSurahs.clear();
      } else {
        _selectedSurahs.addAll([for (int i = 1; i <= 114; i++) i]);
      }
      _remainingSizeMb = _selectedSurahs.fold(
        0.0,
        (sum, s) => sum + (_surahRemainingMbMap[s] ?? 0.0),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final app = AppState.instance;
    final c = app.colors;
    final isAr = app.isArabic;
    final isDark = app.isDarkMode;

    return ListenableBuilder(
      listenable: Listenable.merge([
        QuranDownloadService.instance.isDownloading,
        QuranDownloadService.instance.isPaused,
        QuranDownloadService.instance.progress,
        QuranDownloadService.instance.statusMessage,
        QuranDownloadService.instance.downloadedMb,
        QuranDownloadService.instance.totalMb,
        QuranDownloadService.instance.completedAyahs,
        QuranDownloadService.instance.totalAyahs,
        QuranDownloadService.instance.currentSurah,
      ]),
      builder: (context, _) {
        final isDownloading = QuranDownloadService.instance.isDownloading.value;
        final progress = QuranDownloadService.instance.progress.value;

        return Directionality(
          textDirection: isAr ? TextDirection.rtl : TextDirection.ltr,
          child: AppDialog(
            maxWidth: 390,
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 18),
            heroIcon: AppDialogHeroIcon(
              icon: isDownloading
                  ? Icons.downloading_rounded
                  : (progress >= 1.0
                      ? Icons.check_circle_rounded
                      : Icons.cloud_download_rounded),
              color: progress >= 1.0 ? const Color(0xFF10B981) : c.primary,
              iconSize: 26,
              padding: 12,
            ),
            title: isDownloading
                ? (isAr ? 'جاري التحميل' : 'Downloading')
                : (isAr ? 'تحميل التلاوة' : 'Download Recitation'),
            content: isDownloading
                ? _buildDownloadingView(c, isAr, isDark)
                : _buildSelectionView(context, c, isAr, isDark),
          ),
        );
      },
    );
  }

  // ──────────────────────────────────────────────────────────────────────────
  // VIEW 1: MINIMAL SURAH TABLE & SELECTION
  // ──────────────────────────────────────────────────────────────────────────
  Widget _buildSelectionView(
    BuildContext context,
    ThemeColors c,
    bool isAr,
    bool isDark,
  ) {
    final allSelected = _selectedSurahs.length == 114;
    final screenHeight = MediaQuery.sizeOf(context).height;
    final tableHeight = (screenHeight * 0.35).clamp(180.0, 260.0);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 12),

        // ── Toolbar: Select All Checkbox + Surah Counter ──
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: _toggleSelectAll,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      allSelected
                          ? Icons.check_box_rounded
                          : (_selectedSurahs.isEmpty
                              ? Icons.check_box_outline_blank_rounded
                              : Icons.indeterminate_check_box_rounded),
                      size: 20,
                      color: allSelected || _selectedSurahs.isNotEmpty
                          ? c.primary
                          : c.muted,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      allSelected
                          ? (isAr ? 'إلغاء تحديد الكل' : 'Deselect All')
                          : (isAr ? 'تحديد الكل' : 'Select All'),
                      style: TextStyle(
                        fontFamily: 'cairo',
                        color: c.text,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Text(
              isAr
                  ? '${QuranTypography.toArabicDigits(_selectedSurahs.length)} / ١١٤'
                  : '${_selectedSurahs.length} / 114',
              style: TextStyle(
                fontFamily: 'cairo',
                color: c.muted,
                fontSize: 12.5,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),

        const SizedBox(height: 8),

        // ── Surahs Table (Single table, minimal rows) ──
        Container(
          height: tableHeight,
          decoration: BoxDecoration(
            color: isDark
                ? Colors.white.withValues(alpha: 0.03)
                : Colors.black.withValues(alpha: 0.02),
            borderRadius: BorderRadius.circular(DialogTokens.cardRadius),
            border: Border.all(
              color: isDark
                  ? Colors.white.withValues(alpha: 0.08)
                  : Colors.black.withValues(alpha: 0.06),
              width: 1,
            ),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(DialogTokens.cardRadius),
            child: ListView.separated(
              controller: _scrollController,
              physics: const BouncingScrollPhysics(),
              itemCount: 114,
              separatorBuilder: (_, __) => Divider(
                height: 1,
                thickness: 0.6,
                color: isDark
                    ? Colors.white.withValues(alpha: 0.05)
                    : Colors.black.withValues(alpha: 0.04),
              ),
              itemBuilder: (context, idx) {
                final surah = idx + 1;
                final isSelected = _selectedSurahs.contains(surah);
                final isDownloaded = _downloadedSurahs.contains(surah);
                final name = QuranMetadata.getSurahNameArabic(surah);
                final ayahs = QuranMetadata.getAyahCount(surah);
                final sizeMb = (ayahs * 95 / 1024).toStringAsFixed(1);

                return Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: () => _onToggleSurah(surah),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 9.5,
                      ),
                      child: Row(
                        children: [
                          Icon(
                            isSelected
                                ? Icons.check_box_rounded
                                : Icons.check_box_outline_blank_rounded,
                            size: 19,
                            color: isSelected
                                ? c.primary
                                : c.muted.withValues(alpha: 0.45),
                          ),
                          const SizedBox(width: 10),
                          SizedBox(
                            width: 24,
                            child: Text(
                              isAr
                                  ? QuranTypography.toArabicDigits(surah)
                                  : '$surah',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontFamily: 'cairo',
                                color: c.muted,
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              name,
                              style: TextStyle(
                                fontFamily: 'cairo',
                                fontSize: 14,
                                fontWeight: isSelected
                                    ? FontWeight.w600
                                    : FontWeight.w500,
                                color: isSelected ? c.text : c.textSecondary,
                              ),
                            ),
                          ),
                          if (isDownloaded) ...[
                            const Icon(
                              Icons.check_circle_outline_rounded,
                              size: 13,
                              color: Color(0xFF10B981),
                            ),
                            const SizedBox(width: 4),
                          ],
                          Text(
                            isAr
                                ? '${QuranTypography.toArabicDigits(sizeMb)} م.ب'
                                : '$sizeMb MB',
                            style: TextStyle(
                              fontFamily: 'cairo',
                              color: isDownloaded
                                  ? const Color(0xFF10B981)
                                  : c.muted,
                              fontSize: 11.5,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),

        const SizedBox(height: 14),

        // ── Total Download Size ──
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              isAr ? 'حجم التحميل' : 'Download Size',
              style: TextStyle(
                fontFamily: 'cairo',
                color: c.muted,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
            Text(
              _isCalculating
                  ? '...'
                  : (_selectedSurahs.isEmpty
                      ? (isAr ? '٠ م.ب' : '0 MB')
                      : (_remainingSizeMb <= 0
                          ? (isAr ? 'محمّلة بالكامل' : 'Cached')
                          : (isAr
                              ? '${QuranTypography.toArabicDigits(_remainingSizeMb.toStringAsFixed(1))} ميجابايت'
                              : '${_remainingSizeMb.toStringAsFixed(1)} MB'))),
              style: TextStyle(
                fontFamily: 'cairo',
                color: _remainingSizeMb > 0 ? c.primary : const Color(0xFF10B981),
                fontSize: 13.5,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),

        const SizedBox(height: 16),

        // ── Action Buttons: Cancel / Download ──
        Row(
          children: [
            Expanded(
              child: TextButton(
                onPressed: () {
                  AppHaptics.lightImpact();
                  Navigator.of(context).pop();
                },
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(DialogTokens.buttonRadius),
                  ),
                ),
                child: Text(
                  isAr ? 'إلغاء' : 'Cancel',
                  style: TextStyle(
                    fontFamily: 'cairo',
                    color: c.muted,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: ElevatedButton(
                onPressed: _selectedSurahs.isEmpty || _remainingSizeMb <= 0
                    ? null
                    : () {
                        AppHaptics.lightImpact();
                        final list = _selectedSurahs.toList()..sort();
                        QuranDownloadService.instance.startDownload(surahs: list);
                      },
                style: ElevatedButton.styleFrom(
                  backgroundColor: c.primary,
                  foregroundColor: Colors.white,
                  disabledBackgroundColor: c.primary.withValues(alpha: 0.25),
                  disabledForegroundColor: Colors.white.withValues(alpha: 0.5),
                  elevation: 0,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(DialogTokens.buttonRadius),
                  ),
                ),
                child: Text(
                  isAr ? 'تحميل' : 'Download',
                  style: const TextStyle(
                    fontFamily: 'cairo',
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  // ──────────────────────────────────────────────────────────────────────────
  // VIEW 2: DOWNLOADING PROGRESS IN REAL-TIME
  // ──────────────────────────────────────────────────────────────────────────
  Widget _buildDownloadingView(ThemeColors c, bool isAr, bool isDark) {
    final progress = QuranDownloadService.instance.progress.value;
    final isPaused = QuranDownloadService.instance.isPaused.value;
    final downloadedMb = QuranDownloadService.instance.downloadedMb.value;
    final totalMb = QuranDownloadService.instance.totalMb.value;
    final completed = QuranDownloadService.instance.completedAyahs.value;
    final total = QuranDownloadService.instance.totalAyahs.value;
    final msg = QuranDownloadService.instance.statusMessage.value;
    final percent = (progress * 100).clamp(0.0, 100.0).toStringAsFixed(1);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 14),

        // Progress Percent & MB counter
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Row(
              children: [
                Text(
                  isAr
                      ? '${QuranTypography.toArabicDigits(percent)}٪'
                      : '$percent%',
                  style: TextStyle(
                    fontFamily: 'cairo',
                    color: c.primary,
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                    letterSpacing: -0.5,
                  ),
                ),
                if (isPaused) ...[
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF59E0B).withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      isAr ? 'متوقف مؤقتاً' : 'Paused',
                      style: const TextStyle(
                        fontFamily: 'cairo',
                        color: Color(0xFFF59E0B),
                        fontSize: 10.5,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ],
            ),
            Text(
              isAr
                  ? '${QuranTypography.toArabicDigits(downloadedMb.toStringAsFixed(1))} / ${QuranTypography.toArabicDigits(totalMb.toStringAsFixed(1))} م.ب'
                  : '${downloadedMb.toStringAsFixed(1)} / ${totalMb.toStringAsFixed(1)} MB',
              style: TextStyle(
                fontFamily: 'cairo',
                color: c.muted,
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),

        const SizedBox(height: 10),

        // Smooth Progress Bar
        Container(
          height: 8,
          decoration: BoxDecoration(
            color: isDark
                ? Colors.white.withValues(alpha: 0.10)
                : Colors.black.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(8),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: LinearProgressIndicator(
              value: progress.clamp(0.0, 1.0),
              backgroundColor: Colors.transparent,
              valueColor: AlwaysStoppedAnimation<Color>(
                isPaused ? const Color(0xFFF59E0B) : c.primary,
              ),
            ),
          ),
        ),

        const SizedBox(height: 10),

        // Current status message & count
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(
              child: Text(
                msg.isNotEmpty ? msg : (isAr ? 'جاري التحميل...' : 'Downloading...'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontFamily: 'cairo',
                  color: c.textSecondary,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              isAr
                  ? '${QuranTypography.toArabicDigits(completed)} / ${QuranTypography.toArabicDigits(total)}'
                  : '$completed / $total',
              style: TextStyle(
                fontFamily: 'cairo',
                color: c.muted,
                fontSize: 11.5,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),

        const SizedBox(height: 20),

        // Action Buttons: Cancel, Pause/Resume, Minimize
        Row(
          children: [
            TextButton(
              onPressed: () {
                AppHaptics.lightImpact();
                QuranDownloadService.instance.cancelDownload();
                Navigator.of(context).pop();
              },
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(DialogTokens.buttonRadius),
                ),
              ),
              child: Text(
                isAr ? 'إلغاء' : 'Cancel',
                style: TextStyle(
                  fontFamily: 'cairo',
                  color: c.red,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const Spacer(),
            IconButton(
              onPressed: () {
                AppHaptics.lightImpact();
                if (isPaused) {
                  QuranDownloadService.instance.resumeDownload();
                } else {
                  QuranDownloadService.instance.pauseDownload();
                }
              },
              icon: Icon(
                isPaused ? Icons.play_arrow_rounded : Icons.pause_rounded,
                color: c.primary,
                size: 22,
              ),
              tooltip: isPaused
                  ? (isAr ? 'استئناف' : 'Resume')
                  : (isAr ? 'إيقاف مؤقت' : 'Pause'),
            ),
            const SizedBox(width: 4),
            ElevatedButton(
              onPressed: () {
                AppHaptics.lightImpact();
                QuranDownloadService.instance.setMinimized(true);
                Navigator.of(context).pop();
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: c.primary,
                foregroundColor: Colors.white,
                elevation: 0,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(DialogTokens.buttonRadius),
                ),
              ),
              child: Text(
                isAr ? 'تصغير' : 'Minimize',
                style: const TextStyle(
                  fontFamily: 'cairo',
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

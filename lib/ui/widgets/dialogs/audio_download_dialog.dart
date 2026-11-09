import 'package:flutter/material.dart';
import '../../../audio/quran_download_service.dart';
import '../../../core/app_state.dart';
import '../../../core/highlighting_controller.dart';
import '../../../core/platform_utils.dart';
import 'dialog_base.dart';

/// Ultra-lightweight modal dialog for downloading Quran recitation.
///
/// Fingerprint:
/// - Built on [AppDialog] and [DialogTokens] for 100% theme consistency.
/// - Single unified Surah table with 120 FPS fixed-extent list.
/// - Real-time zero-lag size calculation via O(1) in-memory lookup.
class AudioDownloadDialog extends StatefulWidget {
  const AudioDownloadDialog({super.key});

  /// Displays the download dialog modally.
  static Future<void> show(BuildContext context) {
    QuranDownloadService.instance.setMinimized(false);
    return showDialog<void>(
      context: context,
      barrierColor: DialogTokens.barrierColor,
      builder: (_) => const AudioDownloadDialog(),
    );
  }

  @override
  State<AudioDownloadDialog> createState() => _AudioDownloadDialogState();
}

class _AudioDownloadDialogState extends State<AudioDownloadDialog> {
  final Set<int> _selected = {for (int i = 1; i <= 114; i++) i};
  Set<int> _downloaded = {};
  Map<int, double> _remainingMap = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadStatus();
    QuranDownloadService.instance.isDownloading.addListener(_onStateChange);
  }

  @override
  void dispose() {
    QuranDownloadService.instance.isDownloading.removeListener(_onStateChange);
    super.dispose();
  }

  void _onStateChange() {
    if (!QuranDownloadService.instance.isDownloading.value && mounted) {
      _loadStatus();
    }
  }

  Future<void> _loadStatus() async {
    final status = await QuranDownloadService.getCachedStatus();
    if (mounted) {
      setState(() {
        _downloaded = status.downloadedSurahs;
        _remainingMap = status.remainingMb;
        _loading = false;
      });
    }
  }

  double get _totalRemainingMb =>
      _selected.fold(0.0, (sum, s) => sum + (_remainingMap[s] ?? 0.0));

  void _toggleSurah(int s) {
    AppHaptics.lightImpact();
    setState(() => _selected.contains(s) ? _selected.remove(s) : _selected.add(s));
  }

  void _toggleAll() {
    AppHaptics.lightImpact();
    setState(() {
      _selected.length == 114
          ? _selected.clear()
          : _selected.addAll([for (int i = 1; i <= 114; i++) i]);
    });
  }

  void _start() {
    AppHaptics.lightImpact();
    final list = _selected.toList()..sort();
    QuranDownloadService.instance.startDownload(surahs: list);
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
        QuranDownloadService.instance.progress,
        QuranDownloadService.instance.isPaused,
        QuranDownloadService.instance.statusMessage,
        QuranDownloadService.instance.downloadedMb,
        QuranDownloadService.instance.totalMb,
        QuranDownloadService.instance.completedAyahs,
        QuranDownloadService.instance.totalAyahs,
      ]),
      builder: (context, _) {
        final isDownloading = QuranDownloadService.instance.isDownloading.value;

        return Directionality(
          textDirection: isAr ? TextDirection.rtl : TextDirection.ltr,
          child: AppDialog(
            maxWidth: 390,
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 18),
            heroIcon: AppDialogHeroIcon(
              icon: isDownloading
                  ? Icons.downloading_rounded
                  : Icons.cloud_download_rounded,
              iconSize: 26,
              padding: 12,
            ),
            title: isDownloading
                ? (isAr ? 'جاري التحميل' : 'Downloading')
                : (isAr ? 'تحميل التلاوة' : 'Download Recitation'),
            content: isDownloading
                ? _buildDownloading(c, isAr, isDark)
                : _buildSelection(context, c, isAr, isDark),
          ),
        );
      },
    );
  }

  // ── Selection View ──
  Widget _buildSelection(
    BuildContext context,
    ThemeColors c,
    bool isAr,
    bool isDark,
  ) {
    final allSelected = _selected.length == 114;
    final remainingMb = _totalRemainingMb;
    final canDownload = _selected.isNotEmpty && remainingMb > 0;
    final tableHeight =
        (MediaQuery.sizeOf(context).height * 0.35).clamp(180.0, 260.0);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 12),
        // Toolbar: Select All Checkbox + Surah Counter
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _toggleAll,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    allSelected
                        ? Icons.check_box_rounded
                        : (_selected.isEmpty
                            ? Icons.check_box_outline_blank_rounded
                            : Icons.indeterminate_check_box_rounded),
                    size: 20,
                    color: allSelected || _selected.isNotEmpty ? c.primary : c.muted,
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
            Text(
              isAr
                  ? '${QuranTypography.toArabicDigits(_selected.length)} / ١١٤'
                  : '${_selected.length} / 114',
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

        // Surahs Table (120 FPS fixed-extent ListView)
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
            child: ListView.builder(
              physics: const BouncingScrollPhysics(),
              itemCount: 114,
              itemExtent: 42.0,
              itemBuilder: (context, idx) {
                final s = idx + 1;
                final isSel = _selected.contains(s);
                final isDown = _downloaded.contains(s);
                final name = QuranMetadata.getSurahNameArabic(s);
                final sizeMb =
                    ((QuranMetadata.getAyahCount(s) * 95) / 1024).toStringAsFixed(1);

                return Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: () => _toggleSurah(s),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      decoration: BoxDecoration(
                        border: idx < 113
                            ? Border(
                                bottom: BorderSide(
                                  color: isDark
                                      ? Colors.white.withValues(alpha: 0.05)
                                      : Colors.black.withValues(alpha: 0.04),
                                  width: 0.6,
                                ),
                              )
                            : null,
                      ),
                      child: Row(
                        children: [
                          Icon(
                            isSel
                                ? Icons.check_box_rounded
                                : Icons.check_box_outline_blank_rounded,
                            size: 19,
                            color: isSel ? c.primary : c.muted.withValues(alpha: 0.45),
                          ),
                          const SizedBox(width: 10),
                          SizedBox(
                            width: 24,
                            child: Text(
                              isAr ? QuranTypography.toArabicDigits(s) : '$s',
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
                                fontWeight: isSel ? FontWeight.w600 : FontWeight.w500,
                                color: isSel ? c.text : c.textSecondary,
                              ),
                            ),
                          ),
                          if (isDown) ...[
                            const Icon(
                              Icons.check_circle_outline_rounded,
                              size: 13,
                              color: Color(0xFF10B981),
                            ),
                            const SizedBox(width: 4),
                          ],
                          Text(
                            isAr ? '${QuranTypography.toArabicDigits(sizeMb)} م.ب' : '$sizeMb MB',
                            style: TextStyle(
                              fontFamily: 'cairo',
                              color: isDown ? const Color(0xFF10B981) : c.muted,
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

        // Total Download Size
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
              _loading
                  ? '...'
                  : (_selected.isEmpty
                      ? (isAr ? '٠ م.ب' : '0 MB')
                      : (remainingMb <= 0
                          ? (isAr ? 'محمّلة بالكامل' : 'Cached')
                          : (isAr
                              ? '${QuranTypography.toArabicDigits(remainingMb.toStringAsFixed(1))} ميجابايت'
                              : '${remainingMb.toStringAsFixed(1)} MB'))),
              style: TextStyle(
                fontFamily: 'cairo',
                color: remainingMb > 0 ? c.primary : const Color(0xFF10B981),
                fontSize: 13.5,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),

        // Action Buttons: Cancel / Download
        Row(
          children: [
            Expanded(
              child: TextButton(
                onPressed: () {
                  AppHaptics.lightImpact();
                  Navigator.pop(context);
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
                onPressed: canDownload ? _start : null,
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

  // ── Downloading View ──
  Widget _buildDownloading(ThemeColors c, bool isAr, bool isDark) {
    final srv = QuranDownloadService.instance;
    final progress = srv.progress.value;
    final isPaused = srv.isPaused.value;
    final percent = (progress * 100).clamp(0.0, 100.0).toStringAsFixed(1);
    final msg = srv.statusMessage.value;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 14),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(
              isAr ? '${QuranTypography.toArabicDigits(percent)}٪' : '$percent%',
              style: TextStyle(
                fontFamily: 'cairo',
                color: c.primary,
                fontSize: 24,
                fontWeight: FontWeight.bold,
                letterSpacing: -0.5,
              ),
            ),
            Text(
              isAr
                  ? '${QuranTypography.toArabicDigits(srv.downloadedMb.value.toStringAsFixed(1))} / ${QuranTypography.toArabicDigits(srv.totalMb.value.toStringAsFixed(1))} م.ب'
                  : '${srv.downloadedMb.value.toStringAsFixed(1)} / ${srv.totalMb.value.toStringAsFixed(1)} MB',
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
        Container(
          height: 8,
          decoration: BoxDecoration(
            color: isDark ? Colors.white.withValues(alpha: 0.10) : Colors.black.withValues(alpha: 0.08),
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
                  ? '${QuranTypography.toArabicDigits(srv.completedAyahs.value)} / ${QuranTypography.toArabicDigits(srv.totalAyahs.value)}'
                  : '${srv.completedAyahs.value} / ${srv.totalAyahs.value}',
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
        Row(
          children: [
            TextButton(
              onPressed: () {
                AppHaptics.lightImpact();
                srv.cancelDownload();
                Navigator.pop(context);
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
                isPaused ? srv.resumeDownload() : srv.pauseDownload();
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
                srv.setMinimized(true);
                Navigator.pop(context);
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

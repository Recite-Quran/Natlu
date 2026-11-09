import 'dart:async';
import 'package:flutter/material.dart';
import '../../../audio/quran_download_service.dart';
import '../../../core/app_state.dart';
import '../../../core/highlighting_controller.dart';
import 'dialog_base.dart';

/// Modal dialog for downloading and caching Quran recitation and word-timing data.
///
/// Matches the architecture and UI conventions of `alquranalkareem`:
/// - Warns user about data usage and asks for confirmation (OK / Cancel).
/// - Allows choosing "All Surahs" or specific Surahs with real-time MB size calculation.
/// - Live progress bar with current Surah/Ayah tracking and data counter.
/// - "Minimize" button so users can navigate and use the app while download continues.
class AudioDownloadDialog extends StatefulWidget {
  const AudioDownloadDialog({super.key});

  /// Displays the download dialog modally.
  static Future<void> show(BuildContext context) {
    QuranDownloadService.instance.setMinimized(false);
    return showDialog<void>(
      context: context,
      barrierColor: DialogTokens.barrierColor,
      barrierDismissible: false,
      builder: (_) => const AudioDownloadDialog(),
    );
  }

  @override
  State<AudioDownloadDialog> createState() => _AudioDownloadDialogState();
}

class _AudioDownloadDialogState extends State<AudioDownloadDialog> {
  bool _isFullQuran = true;
  late final Set<int> _selectedSurahs;
  Set<int> _downloadedSurahs = {};
  String _searchQuery = '';
  final TextEditingController _searchController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  double _totalSizeMb = 0.0;
  double _remainingSizeMb = 0.0;
  bool _isCalculating = true;

  @override
  void initState() {
    super.initState();
    // Default to all 114 Surahs
    _selectedSurahs = {for (int i = 1; i <= 114; i++) i};
    _refreshDiskState();
  }

  @override
  void dispose() {
    _searchController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _refreshDiskState() async {
    setState(() => _isCalculating = true);
    final downloaded = await QuranDownloadService.getDownloadedSurahs();
    final total = QuranDownloadService.estimateSizeMb(_selectedSurahs);
    final remaining = await QuranDownloadService.calculateRemainingMb(_selectedSurahs);

    if (mounted) {
      setState(() {
        _downloadedSurahs = downloaded;
        _totalSizeMb = total;
        _remainingSizeMb = remaining;
        _isCalculating = false;
      });
    }
  }

  void _onToggleSurah(int surah) {
    setState(() {
      if (_selectedSurahs.contains(surah)) {
        if (_selectedSurahs.length > 1) {
          _selectedSurahs.remove(surah);
        }
      } else {
        _selectedSurahs.add(surah);
      }
      _isFullQuran = _selectedSurahs.length == 114;
    });
    _recalculateSizes();
  }

  void _onSelectAll() {
    setState(() {
      _selectedSurahs.addAll([for (int i = 1; i <= 114; i++) i]);
      _isFullQuran = true;
    });
    _recalculateSizes();
  }

  void _onDeselectAll() {
    setState(() {
      _selectedSurahs.clear();
      _selectedSurahs.add(1); // keep at least 1
      _isFullQuran = false;
    });
    _recalculateSizes();
  }

  void _recalculateSizes() {
    setState(() {
      _totalSizeMb = QuranDownloadService.estimateSizeMb(_selectedSurahs);
    });
    QuranDownloadService.calculateRemainingMb(_selectedSurahs).then((rem) {
      if (mounted) setState(() => _remainingSizeMb = rem);
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
        QuranDownloadService.instance.currentAyah,
      ]),
      builder: (context, _) {
        final isDownloading = QuranDownloadService.instance.isDownloading.value;
        final progress = QuranDownloadService.instance.progress.value;

        return Directionality(
          textDirection: isAr ? TextDirection.rtl : TextDirection.ltr,
          child: AppDialog(
            maxWidth: 420,
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
            heroIcon: Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: c.primary.withValues(alpha: isDark ? 0.20 : 0.12),
                shape: BoxShape.circle,
                border: Border.all(
                  color: c.primary.withValues(alpha: isDark ? 0.40 : 0.25),
                  width: 1.5,
                ),
              ),
              child: Icon(
                isDownloading
                    ? Icons.downloading_rounded
                    : (progress >= 1.0
                        ? Icons.check_circle_rounded
                        : Icons.cloud_download_rounded),
                color: progress >= 1.0 ? const Color(0xFF10B981) : c.primary,
                size: 26,
              ),
            ),
            title: isDownloading
                ? (isAr ? 'جاري تحميل التلاوة والتوقيت' : 'Downloading Quran Audio')
                : (isAr ? 'تحميل التلاوة للاستماع بدون إنترنت' : 'Download Quran Recitation'),
            subtitle: isDownloading
                ? (isAr
                    ? 'يتم حفظ الملفات محلياً مع التوقيت الدقيق للتظليل'
                    : 'Saving files locally with word-by-word timing')
                : (isAr
                    ? 'بصوت الشيخ محمود خليل الحصري مع التظليل المتزامن'
                    : 'Recited by Mahmoud Khalil Al-Husary with word highlighting'),
            content: isDownloading
                ? _buildDownloadingView(c, isAr, isDark)
                : _buildSelectionView(c, isAr, isDark),
          ),
        );
      },
    );
  }

  // ──────────────────────────────────────────────────────────────────────────
  // VIEW 1: SELECTION & CONFIRMATION
  // ──────────────────────────────────────────────────────────────────────────
  Widget _buildSelectionView(ThemeColors c, bool isAr, bool isDark) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 12),

        // ── Warning / Information Banner ──
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: const Color(0xFFF59E0B).withValues(alpha: isDark ? 0.12 : 0.08),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: const Color(0xFFF59E0B).withValues(alpha: isDark ? 0.35 : 0.25),
              width: 1,
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.only(top: 2),
                child: Icon(Icons.wifi_rounded, color: Color(0xFFF59E0B), size: 20),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  isAr
                      ? 'تنبيه: سيتم استخدام بيانات الإنترنت لتحميل التلاوة والتوقيت لتعمل بدون إنترنت بالكامل. يُفضل استخدام شبكة Wi-Fi.'
                      : 'Notice: Internet data will be used to download audio & timings for full offline playback. Wi-Fi is recommended.',
                  style: TextStyle(
                    color: isDark ? const Color(0xFFFCD34D) : const Color(0xFFB45309),
                    fontSize: 12.5,
                    height: 1.4,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
        ),

        const SizedBox(height: 14),

        // ── Scope Selector (Full Quran vs Specific Surahs) ──
        AppSegmentedPillSelector(
          labels: isAr
              ? const ['المصحف كاملاً (١١٤ سورة)', 'اختيار سور محددة']
              : const ['Full Quran (114 Surahs)', 'Select Surahs'],
          selected: _isFullQuran ? 0 : 1,
          c: c,
          onSelected: (i) {
            setState(() {
              _isFullQuran = i == 0;
              if (_isFullQuran) {
                _selectedSurahs.addAll([for (int s = 1; s <= 114; s++) s]);
              }
            });
            _recalculateSizes();
          },
        ),

        // ── Custom Surah List if specific surahs chosen ──
        if (!_isFullQuran) ...[
          const SizedBox(height: 12),
          _buildSurahSelectorList(c, isAr, isDark),
        ],

        const SizedBox(height: 14),

        // ── Size & Summary Card ──
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: isDark
                ? Colors.white.withValues(alpha: 0.05)
                : Colors.black.withValues(alpha: 0.035),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: isDark
                  ? Colors.white.withValues(alpha: 0.08)
                  : Colors.black.withValues(alpha: 0.06),
              width: 1,
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    isAr ? 'السور المختارة' : 'Selected Surahs',
                    style: TextStyle(color: c.muted, fontSize: 12),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    isAr
                        ? '${_selectedSurahs.length} سورة'
                        : '${_selectedSurahs.length} Surahs',
                    style: TextStyle(
                      color: c.text,
                      fontSize: 14.5,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
              Container(width: 1, height: 28, color: c.border.withValues(alpha: 0.5)),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    isAr ? 'الحجم المطلوب تحميله' : 'Download Size',
                    style: TextStyle(color: c.muted, fontSize: 12),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _isCalculating
                        ? '...'
                        : (isAr
                            ? '${QuranTypography.toArabicDigits(_remainingSizeMb.toStringAsFixed(1))} ميجابايت (الإجمالي ${QuranTypography.toArabicDigits(_totalSizeMb.toStringAsFixed(1))})'
                            : '${_remainingSizeMb.toStringAsFixed(1)} MB (${_totalSizeMb.toStringAsFixed(1)} total)'),
                    style: TextStyle(
                      fontFamily: 'cairo',
                      color: c.primary,
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),

        const SizedBox(height: 18),

        // ── Action Buttons (Cancel / Start Download) ──
        Row(
          children: [
            Expanded(
              child: TextButton(
                onPressed: () => Navigator.of(context).pop(),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(DialogTokens.buttonRadius),
                  ),
                ),
                child: Text(
                  isAr ? 'إلغاء' : 'Cancel',
                  style: TextStyle(color: c.muted, fontSize: 15, fontWeight: FontWeight.w600),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              flex: 2,
              child: ElevatedButton.icon(
                onPressed: _selectedSurahs.isEmpty
                    ? null
                    : () {
                        final list = _selectedSurahs.toList()..sort();
                        QuranDownloadService.instance.startDownload(surahs: list);
                      },
                icon: const Icon(Icons.download_rounded, size: 20),
                label: Text(
                  isAr ? 'موافق - بدء التحميل' : 'OK - Download',
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: c.primary,
                  foregroundColor: Colors.white,
                  elevation: 0,
                  padding: const EdgeInsets.symmetric(vertical: 13),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(DialogTokens.buttonRadius),
                  ),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  // ── Specific Surah Selector List ──
  Widget _buildSurahSelectorList(ThemeColors c, bool isAr, bool isDark) {
    final filtered = [for (int i = 1; i <= 114; i++) i].where((s) {
      if (_searchQuery.isEmpty) return true;
      final name = QuranMetadata.getSurahNameArabic(s);
      final numStr = s.toString();
      return name.contains(_searchQuery) || numStr.contains(_searchQuery);
    }).toList();

    return Container(
      height: 220,
      decoration: BoxDecoration(
        color: isDark ? Colors.black.withValues(alpha: 0.25) : Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: c.border.withValues(alpha: isDark ? 0.35 : 0.60),
          width: 1,
        ),
      ),
      child: Column(
        children: [
          // Search & Quick actions bar
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 6),
            child: Row(
              children: [
                Expanded(
                  child: SizedBox(
                    height: 36,
                    child: TextField(
                      controller: _searchController,
                      style: TextStyle(fontFamily: 'cairo', color: c.text, fontSize: 13),
                      decoration: InputDecoration(
                        hintText: isAr ? 'ابحث باسم السورة أو رقمها...' : 'Search surah...',
                        hintStyle: TextStyle(fontFamily: 'cairo', color: c.muted, fontSize: 12),
                        prefixIcon: Icon(Icons.search_rounded, size: 18, color: c.muted),
                        suffixIcon: _searchQuery.isNotEmpty
                            ? IconButton(
                                icon: const Icon(Icons.close_rounded, size: 16),
                                color: c.muted,
                                onPressed: () {
                                  _searchController.clear();
                                  setState(() => _searchQuery = '');
                                },
                              )
                            : null,
                        contentPadding: EdgeInsets.zero,
                        filled: true,
                        fillColor: isDark
                            ? Colors.white.withValues(alpha: 0.06)
                            : Colors.black.withValues(alpha: 0.04),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: BorderSide.none,
                        ),
                      ),
                      onChanged: (v) => setState(() => _searchQuery = v.trim()),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: _onSelectAll,
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: Text(
                    isAr ? 'الكل' : 'All',
                    style: TextStyle(
                      fontFamily: 'cairo',
                      fontSize: 12.5,
                      color: c.primary,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: _onDeselectAll,
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: Text(
                    isAr ? 'إلغاء' : 'None',
                    style: TextStyle(
                      fontFamily: 'cairo',
                      fontSize: 12.5,
                      color: c.muted,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Divider(height: 1, color: c.border.withValues(alpha: 0.3)),
          // Surahs Scroll List
          Expanded(
            child: ListView.builder(
              controller: _scrollController,
              itemCount: filtered.length,
              itemExtent: 46,
              itemBuilder: (context, idx) {
                final surah = filtered[idx];
                final isSelected = _selectedSurahs.contains(surah);
                final isDownloaded = _downloadedSurahs.contains(surah);
                final surahName = QuranMetadata.getSurahNameArabic(surah);
                final ayahs = QuranMetadata.getAyahCount(surah);
                final sizeMb = (ayahs * 95 / 1024).toStringAsFixed(1);

                return Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: () => _onToggleSurah(surah),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      child: Row(
                        children: [
                          Icon(
                            isSelected
                                ? Icons.check_box_rounded
                                : Icons.check_box_outline_blank_rounded,
                            size: 20,
                            color: isSelected ? c.primary : c.muted.withValues(alpha: 0.7),
                          ),
                          const SizedBox(width: 8),
                          // Surah number avatar
                          Container(
                            width: 28,
                            height: 28,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: isSelected
                                  ? c.primary.withValues(alpha: isDark ? 0.22 : 0.12)
                                  : c.surface,
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: isSelected
                                    ? c.primary.withValues(alpha: 0.45)
                                    : c.border.withValues(alpha: 0.4),
                                width: 1,
                              ),
                            ),
                            child: Text(
                              isAr ? QuranTypography.toArabicDigits(surah) : '$surah',
                              style: TextStyle(
                                fontFamily: 'cairo',
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                                color: isSelected ? c.primary : c.textSecondary,
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Row(
                              children: [
                                Text(
                                  'سورة $surahName',
                                  style: TextStyle(
                                    fontFamily: 'cairo',
                                    color: c.text,
                                    fontSize: 13.5,
                                    fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                                  ),
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  '(${isAr ? QuranTypography.toArabicDigits(ayahs) : ayahs} ${isAr ? "آية" : "ayahs"})',
                                  style: TextStyle(
                                    fontFamily: 'cairo',
                                    color: c.muted,
                                    fontSize: 11,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          if (isDownloaded) ...[
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                              decoration: BoxDecoration(
                                color: const Color(0xFF10B981).withValues(alpha: 0.15),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(Icons.check_circle_rounded, size: 12, color: Color(0xFF10B981)),
                                  const SizedBox(width: 3),
                                  Text(
                                    isAr ? 'محمّلة' : 'Cached',
                                    style: const TextStyle(
                                      fontFamily: 'cairo',
                                      color: Color(0xFF10B981),
                                      fontSize: 10,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 6),
                          ],
                          Text(
                            isAr ? '${QuranTypography.toArabicDigits(sizeMb)} م.ب' : '$sizeMb MB',
                            style: TextStyle(
                              fontFamily: 'cairo',
                              color: c.muted,
                              fontSize: 11,
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
        ],
      ),
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
        const SizedBox(height: 12),

        // Progress Percent & MB counter
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Row(
              children: [
                Text(
                  isAr ? '${QuranTypography.toArabicDigits(percent)}٪' : '$percent%',
                  style: TextStyle(
                    fontFamily: 'cairo',
                    color: c.primary,
                    fontSize: 26,
                    fontWeight: FontWeight.bold,
                    letterSpacing: -0.5,
                  ),
                ),
                if (isPaused) ...[
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF59E0B).withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      isAr ? 'متوقف مؤقتاً' : 'Paused',
                      style: const TextStyle(
                        fontFamily: 'cairo',
                        color: Color(0xFFF59E0B),
                        fontSize: 11,
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
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),

        const SizedBox(height: 10),

        // ── Smooth Modern Progress Bar ──
        Container(
          height: 10,
          decoration: BoxDecoration(
            color: isDark
                ? Colors.white.withValues(alpha: 0.10)
                : Colors.black.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(10),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
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

        // Detailed count + status message
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
                  color: c.text,
                  fontSize: 12.5,
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
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),

        const SizedBox(height: 18),

        // ── Action Buttons: Minimize, Pause/Resume, Cancel ──
        Row(
          children: [
            // Cancel button
            OutlinedButton(
              onPressed: () {
                QuranDownloadService.instance.cancelDownload();
                Navigator.of(context).pop();
              },
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
                side: BorderSide(color: c.red.withValues(alpha: 0.5)),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(DialogTokens.buttonRadius),
                ),
              ),
              child: Text(
                isAr ? 'إلغاء' : 'Cancel',
                style: TextStyle(color: c.red, fontSize: 13, fontWeight: FontWeight.bold),
              ),
            ),

            const SizedBox(width: 8),

            // Pause / Resume button
            IconButton(
              onPressed: () {
                if (isPaused) {
                  QuranDownloadService.instance.resumeDownload();
                } else {
                  QuranDownloadService.instance.pauseDownload();
                }
              },
              icon: Icon(
                isPaused ? Icons.play_arrow_rounded : Icons.pause_rounded,
                color: c.primary,
              ),
              tooltip: isPaused
                  ? (isAr ? 'استئناف' : 'Resume')
                  : (isAr ? 'إيقاف مؤقت' : 'Pause'),
            ),

            const Spacer(),

            // Minimize button (User asked for progress bar and minimize button)
            ElevatedButton.icon(
              onPressed: () {
                QuranDownloadService.instance.setMinimized(true);
                Navigator.of(context).pop();
              },
              icon: const Icon(Icons.arrow_downward_rounded, size: 18),
              label: Text(
                isAr ? 'تصغير' : 'Minimize',
                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: c.primary,
                foregroundColor: Colors.white,
                elevation: 0,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(DialogTokens.buttonRadius),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

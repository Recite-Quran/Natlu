import 'package:flutter/material.dart';
import 'package:recite_quran/recite_quran.dart';
import '../../services/app_haptics.dart';
import '../../state/app_state.dart';
import 'surah/surah_list_tile.dart';

/// Ultra-responsive Surah Navigator Sheet with instant Arabic/English search,
/// voice search trigger, and zero-jank 120 FPS scrolling architecture.
class SurahPickerSheet extends StatefulWidget {
  final int current;
  final void Function(int surah, {int? ayah}) onPick;
  final HighlightingController controller;
  final bool isRecording;
  final bool isVoiceSearching;
  final VoidCallback onToggleRecord;
  final VoidCallback onVoiceSearchToggle;

  const SurahPickerSheet({
    super.key,
    required this.current,
    required this.onPick,
    required this.controller,
    required this.isRecording,
    required this.isVoiceSearching,
    required this.onToggleRecord,
    required this.onVoiceSearchToggle,
  });

  @override
  State<SurahPickerSheet> createState() => _SurahPickerSheetState();
}

class _SurahPickerSheetState extends State<SurahPickerSheet> {
  static final List<int> _allIndices =
      List<int>.generate(114, (i) => i, growable: false);

  static final List<String> _arabicDigits = List<String>.generate(114, (i) {
    const digits = ['٠', '١', '٢', '٣', '٤', '٥', '٦', '٧', '٨', '٩'];
    return (i + 1)
        .toString()
        .split('')
        .map((e) => digits[int.parse(e)])
        .join('');
  }, growable: false);

  static List<String>? _cachedNormalizedAr;
  static List<String>? _cachedLowerEn;

  String _query = '';
  final TextEditingController _searchCtrl = TextEditingController();
  late final ScrollController _scrollCtrl;
  late final List<QuranVerse> _surahs;

  @override
  void initState() {
    super.initState();
    _surahs = widget.controller.repository.surahMetadata;
    // Set initial scroll offset immediately so the sheet renders directly at the target position,
    // eliminating any post-frame layout jumps that would stall the opening animation.
    final double initialOffset =
        ((widget.current - 1) * 70.0 - 70.0).clamp(0.0, double.infinity);
    _scrollCtrl = ScrollController(initialScrollOffset: initialOffset);
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  /// Lazy initialize search cache only when the user actually types in search,
  /// keeping initial sheet opening completely instantaneous.
  void _ensureSearchCache() {
    if (_cachedNormalizedAr == null ||
        _cachedNormalizedAr!.length != _surahs.length) {
      final norm = List<String>.filled(_surahs.length, '');
      final lower = List<String>.filled(_surahs.length, '');
      for (int i = 0; i < _surahs.length; i++) {
        norm[i] = _normalizeArabicFast(_surahs[i].surahName);
        lower[i] = _surahs[i].surahNameEn.toLowerCase();
      }
      _cachedNormalizedAr = norm;
      _cachedLowerEn = lower;
    }
  }

  /// High-performance single-pass Arabic text normalizer (zero regex allocations).
  static String _normalizeArabicFast(String text) {
    final sb = StringBuffer();
    for (int i = 0; i < text.length; i++) {
      final code = text.codeUnitAt(i);
      // Skip tashkeel: 0x064B to 0x065F, and 0x0670 (superscript alef)
      if ((code >= 0x064B && code <= 0x065F) || code == 0x0670) {
        continue;
      }
      switch (code) {
        case 0x0622: // آ
        case 0x0623: // أ
        case 0x0625: // إ
        case 0x0671: // ٱ
          sb.write('ا');
          break;
        case 0x0629: // ة
          sb.write('ه');
          break;
        case 0x0649: // ى
        case 0x0626: // ئ
          sb.write('ي');
          break;
        case 0x0624: // ؤ
          sb.write('و');
          break;
        default:
          sb.writeCharCode(code);
      }
    }
    return sb.toString();
  }

  @override
  Widget build(BuildContext context) {
    final app = AppState.instance;
    final ThemeColors c = app.colors;
    final isDark = app.isDarkMode;
    final isAr = app.isArabic;

    final trimmedQuery = _query.trim();
    final List<int> items;
    if (trimmedQuery.isEmpty) {
      items = _allIndices;
    } else {
      _ensureSearchCache();
      final normQuery = _normalizeArabicFast(trimmedQuery);
      final lowerQuery = trimmedQuery.toLowerCase();
      final filtered = <int>[];
      for (int i = 0; i < _surahs.length; i++) {
        final sNum = i + 1;
        if (_cachedNormalizedAr![i].contains(normQuery) ||
            _cachedLowerEn![i].contains(lowerQuery) ||
            '$sNum'.contains(trimmedQuery) ||
            _arabicDigits[i].contains(trimmedQuery)) {
          filtered.add(i);
        }
      }
      items = filtered;
    }

    return RepaintBoundary(
      child: Directionality(
        textDirection: isAr ? TextDirection.rtl : TextDirection.ltr,
        child: Container(
          height: MediaQuery.sizeOf(context).height * 0.70,
          decoration: BoxDecoration(
            color: c.surface,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(32)),
            border: Border(
              top: BorderSide(
                color: Colors.white.withValues(alpha: isDark ? 0.15 : 0.45),
                width: 0.8,
              ),
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: isDark ? 0.35 : 0.08),
                blurRadius: 16,
                offset: const Offset(0, -4),
              ),
            ],
          ),
          child: Column(
            children: [
              const SizedBox(height: 12),

              // ── Drag Handle ──
              Container(
                width: 44,
                height: 4,
                decoration: BoxDecoration(
                  color: c.border.withValues(alpha: 0.6),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 12),

              // ── Search Bar & Voice Search Action ──
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    // 1. Search Bar Field
                    Expanded(
                      child: Container(
                        height: 50,
                        decoration: BoxDecoration(
                          color: c.surfaceHigh,
                          borderRadius: BorderRadius.circular(18),
                          border: Border.all(
                            color: c.border.withValues(alpha: 0.5),
                            width: 0.8,
                          ),
                        ),
                        child: TextField(
                          controller: _searchCtrl,
                          onChanged: (v) => setState(() => _query = v),
                          style: TextStyle(
                            color: c.text,
                            fontSize: 15,
                            fontWeight: FontWeight.w500,
                          ),
                          decoration: InputDecoration(
                            hintText: isAr
                                ? 'ابحث باسم السورة أو رقمها...'
                                : 'Search by name or number...',
                            hintStyle: TextStyle(
                              color: c.textSecondary,
                              fontSize: 13,
                            ),
                            prefixIcon: Icon(
                              Icons.search_rounded,
                              color: c.primary,
                              size: 20,
                            ),
                            suffixIcon: _query.isNotEmpty
                                ? IconButton(
                                    icon: const Icon(Icons.close_rounded,
                                        size: 18),
                                    color: c.textSecondary,
                                    onPressed: () {
                                      _searchCtrl.clear();
                                      setState(() => _query = '');
                                    },
                                  )
                                : null,
                            border: InputBorder.none,
                            contentPadding: const EdgeInsets.symmetric(
                              vertical: 14,
                              horizontal: 14,
                            ),
                          ),
                        ),
                      ),
                    ),

                    const SizedBox(width: 10),

                    // 2. Voice Search Action Button
                    _TactileScaleButton(
                      onTap: () {
                        AppHaptics.mediumImpact();
                        if (Navigator.of(context).canPop()) {
                          Navigator.pop(context);
                        }
                        widget.onVoiceSearchToggle();
                      },
                      child: Container(
                        height: 50,
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [
                              c.primary,
                              c.secondary,
                            ],
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                          ),
                          borderRadius: BorderRadius.circular(18),
                          border: Border.all(
                            color: Colors.white.withValues(alpha: 0.35),
                            width: 0.8,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: c.primary
                                  .withValues(alpha: isDark ? 0.35 : 0.22),
                              blurRadius: 10,
                              offset: const Offset(0, 3),
                            ),
                          ],
                        ),
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(
                                Icons.graphic_eq_rounded,
                                color: Colors.white,
                                size: 19,
                              ),
                              const SizedBox(width: 5),
                              Text(
                                isAr ? 'بحث صوتي' : 'Voice Search',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: isAr ? 13 : 11,
                                  fontWeight: FontWeight.bold,
                                  letterSpacing: 0.2,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 8),

              // ── Surah List ──
              Expanded(
                child: items.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.search_off_rounded,
                              size: 44,
                              color: c.textSecondary.withValues(alpha: 0.5),
                            ),
                            const SizedBox(height: 10),
                            Text(
                              isAr
                                  ? 'لم يتم العثور على سور'
                                  : 'No Surahs found',
                              style: TextStyle(
                                color: c.textSecondary,
                                fontSize: 14,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ),
                      )
                    : ListView.builder(
                        controller: _scrollCtrl,
                        physics: const BouncingScrollPhysics(
                          parent: AlwaysScrollableScrollPhysics(),
                        ),
                        padding: const EdgeInsets.only(bottom: 24, top: 4),
                        itemCount: items.length,
                        itemExtent: 70.0,
                        addRepaintBoundaries: true,
                        itemBuilder: (context, i) {
                          final int idx = items[i];
                          final int sNum = idx + 1;
                          final bool isSel = widget.current == sNum;
                          final QuranVerse surahMeta = _surahs[idx];

                          return SurahListTile(
                            surahNumber: sNum,
                            surahMeta: surahMeta,
                            isSelected: isSel,
                            isArabic: isAr,
                            colors: c,
                            arabicDigits: _arabicDigits[idx],
                            onTap: () => widget.onPick(sNum),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Tactile feedback button wrapper.
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
        scale: _isDown ? 0.94 : 1.0,
        duration: const Duration(milliseconds: 110),
        curve: Curves.easeOutCubic,
        child: widget.child,
      ),
    );
  }
}

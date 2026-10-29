import 'package:flutter/material.dart';
import 'package:recite_quran/recite_quran.dart';
import '../../../services/app_haptics.dart';
import '../../../state/app_state.dart';

/// Single interactive row tile for a Surah in the picker sheet.
/// Upgraded with 2026 tactile spring micro-interactions and specular 0.8px borders.
class SurahListTile extends StatefulWidget {
  final int surahNumber;
  final QuranVerse surahMeta;
  final bool isSelected;
  final VoidCallback onTap;

  const SurahListTile({
    super.key,
    required this.surahNumber,
    required this.surahMeta,
    required this.isSelected,
    required this.onTap,
  });

  @override
  State<SurahListTile> createState() => _SurahListTileState();
}

class _SurahListTileState extends State<SurahListTile> {
  bool _isPressed = false;

  static String _toArabicDigits(int number) {
    const digits = ['٠', '١', '٢', '٣', '٤', '٥', '٦', '٧', '٨', '٩'];
    return number
        .toString()
        .split('')
        .map((e) => digits[int.parse(e)])
        .join('');
  }

  @override
  Widget build(BuildContext context) {
    final app = AppState.instance;
    final c = app.colors;
    final isSel = widget.isSelected;

    return Padding(
      padding: const EdgeInsetsDirectional.symmetric(horizontal: 16, vertical: 4),
      child: GestureDetector(
        onTapDown: (_) => setState(() => _isPressed = true),
        onTapUp: (_) => setState(() => _isPressed = false),
        onTapCancel: () => setState(() => _isPressed = false),
        onTap: () {
          AppHaptics.lightImpact();
          widget.onTap();
        },
        behavior: HitTestBehavior.opaque,
        child: AnimatedScale(
          scale: _isPressed ? 0.97 : 1.0,
          duration: const Duration(milliseconds: 110),
          curve: Curves.easeOutCubic,
          child: Container(
            padding: const EdgeInsetsDirectional.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: isSel
                  ? c.primary.withValues(alpha: 0.10)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                color: isSel
                    ? c.primary.withValues(alpha: 0.35)
                    : c.border.withValues(alpha: 0.35),
                width: 0.8,
              ),
            ),
            child: Row(
              children: [
                // ── Number Badge ──
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: isSel ? c.primary : c.surfaceHigh,
                    borderRadius: BorderRadius.circular(14),
                    border: isSel
                        ? null
                        : Border.all(
                            color: c.border.withValues(alpha: 0.5),
                            width: 0.8,
                          ),
                  ),
                  alignment: Alignment.center,
                  child: isSel
                      ? const Icon(
                          Icons.check_rounded,
                          color: Colors.white,
                          size: 22,
                        )
                      : Text(
                          app.isArabic
                              ? _toArabicDigits(widget.surahNumber)
                              : '${widget.surahNumber}',
                          style: TextStyle(
                            color: c.primary,
                            fontSize: app.isArabic ? 18 : 16,
                            fontWeight: FontWeight.w700,
                            height: 1.0,
                          ),
                        ),
                ),
                const SizedBox(width: 14),

                // ── Surah Names ──
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.surahMeta.surahName,
                        textDirection: TextDirection.rtl,
                        style: TextStyle(
                          color: isSel ? c.primary : c.text,
                          fontSize: 16.5,
                          fontWeight: isSel ? FontWeight.w700 : FontWeight.w600,
                          height: 1.3,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        widget.surahMeta.surahNameEn,
                        style: TextStyle(
                          color: c.textSecondary,
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),

                // ── Directional Arrow (points right) ──
                Icon(
                  Icons.chevron_right_rounded,
                  color: isSel ? c.primary : c.border.withValues(alpha: 0.8),
                  size: 22,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

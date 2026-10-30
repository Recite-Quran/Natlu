import 'package:flutter/material.dart';
import 'package:recite_quran/recite_quran.dart';
import '../../../services/app_haptics.dart';
import '../../../state/app_state.dart';

/// Ultra-lightweight, 120 FPS single interactive row tile for a Surah in the picker sheet.
///
/// Performance Architecture:
/// - Pure [StatelessWidget] architecture: zero per-tile State allocations.
/// - Zero per-tile [Material] / [InkWell] allocations: eliminates FocusNode, ActionMap,
///   MouseRegion, and InkFeature overhead for instant opening and zero-stutter scrolling.
/// - Exact fixed extent (70.0px): 64px container + 6px vertical padding, preventing layout recalculations.
/// - Direct [GestureDetector] with [HitTestBehavior.opaque] and instant tactile haptics.
class SurahListTile extends StatelessWidget {
  final int surahNumber;
  final QuranVerse surahMeta;
  final bool isSelected;
  final VoidCallback onTap;
  final bool isArabic;
  final ThemeColors colors;
  final String arabicDigits;

  const SurahListTile({
    super.key,
    required this.surahNumber,
    required this.surahMeta,
    required this.isSelected,
    required this.onTap,
    required this.isArabic,
    required this.colors,
    required this.arabicDigits,
  });

  @override
  Widget build(BuildContext context) {
    final c = colors;
    final isAr = isArabic;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14.0, vertical: 3.0),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          AppHaptics.lightImpact();
          onTap();
        },
        child: Container(
          height: 64.0,
          padding: const EdgeInsets.symmetric(horizontal: 12.0),
          decoration: BoxDecoration(
            color: isSelected
                ? c.primary.withValues(alpha: 0.12)
                : c.surfaceHigh.withValues(alpha: 0.35),
            borderRadius: const BorderRadius.all(Radius.circular(16.0)),
            border: Border.all(
              color: isSelected
                  ? c.primary.withValues(alpha: 0.40)
                  : c.border.withValues(alpha: 0.30),
              width: 0.8,
            ),
          ),
          child: Row(
            children: [
              // ── Number Badge ──
              Container(
                width: 38.0,
                height: 38.0,
                decoration: BoxDecoration(
                  color: isSelected ? c.primary : c.surfaceHigh,
                  borderRadius: const BorderRadius.all(Radius.circular(12.0)),
                  border: isSelected
                      ? null
                      : Border.all(
                          color: c.border.withValues(alpha: 0.40),
                          width: 0.8,
                        ),
                ),
                alignment: Alignment.center,
                child: isSelected
                    ? const Icon(
                        Icons.check_rounded,
                        color: Colors.white,
                        size: 20.0,
                      )
                    : Text(
                        isAr ? arabicDigits : '$surahNumber',
                        style: TextStyle(
                          color: c.primary,
                          fontSize: isAr ? 16.0 : 14.0,
                          fontWeight: FontWeight.w700,
                          height: 1.0,
                        ),
                      ),
              ),
              const SizedBox(width: 12.0),

              // ── Surah Names ──
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      surahMeta.surahName,
                      textDirection: TextDirection.rtl,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: isSelected ? c.primary : c.text,
                        fontSize: 16.0,
                        fontWeight: isSelected ? FontWeight.w700 : FontWeight.w600,
                        height: 1.25,
                      ),
                    ),
                    const SizedBox(height: 2.0),
                    Text(
                      surahMeta.surahNameEn,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: c.textSecondary,
                        fontSize: 12.0,
                        fontWeight: FontWeight.w500,
                        height: 1.15,
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(width: 8.0),

              // ── Directional Navigation Arrow ──
              Icon(
                isAr ? Icons.chevron_left_rounded : Icons.chevron_right_rounded,
                color: isSelected ? c.primary : c.border.withValues(alpha: 0.8),
                size: 20.0,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

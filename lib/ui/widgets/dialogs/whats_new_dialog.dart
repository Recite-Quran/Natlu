import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../../services/app_haptics.dart';
import '../../../state/app_state.dart';
import 'maglis_entry_dialog.dart';

/// Ultra-modern, eye-comfortable explanation dialog for the Community Maglis feature.
///
/// Features:
/// - Clean, distraction-free layout (zero AI buzzwords, pure everyday human language)
/// - Modern 3-pillar feature breakdown with optical alignment and vectorized micro-badges
/// - Tailored for Warm Linen (Light) and OLED True Black (Dark) modes
class WhatsNewDialog extends StatelessWidget {
  const WhatsNewDialog({super.key});

  /// Displays the WhatsNewDialog modal centered with zero eye strain.
  static Future<void> show(BuildContext context) async {
    await showDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierColor: Colors.black.withValues(alpha: 0.60),
      builder: (_) => const WhatsNewDialog(),
    );
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('has_seen_v1_2_maglis_whats_new', true);
  }

  @override
  Widget build(BuildContext context) {
    final app = AppState.instance;

    return RepaintBoundary(
      child: ListenableBuilder(
        listenable: Listenable.merge([app.themeNotifier, app.languageNotifier]),
        builder: (context, _) {
          final c = app.colors;
          final isAr = app.isArabic;
          final isDark = app.isDarkMode;

          return Directionality(
            textDirection: isAr ? TextDirection.rtl : TextDirection.ltr,
            child: Dialog(
              backgroundColor: Colors.transparent,
              insetPadding: const EdgeInsets.symmetric(horizontal: 22, vertical: 24),
              child: Container(
                constraints: const BoxConstraints(maxWidth: 390),
                decoration: BoxDecoration(
                  color: c.surface,
                  borderRadius: BorderRadius.circular(28),
                  border: Border.all(
                    color: c.border.withValues(alpha: isDark ? 0.35 : 0.45),
                    width: 1,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: isDark ? 0.45 : 0.12),
                      blurRadius: 28,
                      offset: const Offset(0, 10),
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(28),
                  child: SingleChildScrollView(
                    physics: const BouncingScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(22, 18, 22, 20),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // ── Top Header Bar with Badge & Close Button ──
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            // Sleek community capsule badge
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 4.5,
                              ),
                              decoration: BoxDecoration(
                                color: c.primary.withValues(alpha: 0.10),
                                borderRadius: BorderRadius.circular(20),
                                border: Border.all(
                                  color: c.primary.withValues(alpha: 0.22),
                                  width: 0.8,
                                ),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.groups_rounded,
                                    size: 14,
                                    color: c.primary,
                                  ),
                                  const SizedBox(width: 5),
                                  Text(
                                    isAr ? 'ميزة جديدة' : 'NEW FEATURE',
                                    style: TextStyle(
                                      color: c.primary,
                                      fontSize: 11,
                                      fontWeight: FontWeight.w700,
                                      letterSpacing: isAr ? 0.0 : 0.6,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            // Minimal close button
                            IconButton(
                              onPressed: () {
                                AppHaptics.lightImpact();
                                Navigator.of(context).pop();
                              },
                              icon: Icon(
                                Icons.close_rounded,
                                color: c.muted,
                                size: 20,
                              ),
                              visualDensity: VisualDensity.compact,
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(
                                minWidth: 32,
                                minHeight: 32,
                              ),
                              splashRadius: 18,
                            ),
                          ],
                        ),

                        const SizedBox(height: 14),

                        // ── Title & Value Proposition (Clear everyday words) ──
                        Text(
                          isAr ? 'مجلس القرآن' : 'Quran Maglis',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: c.text,
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                            letterSpacing: isAr ? 0.0 : -0.3,
                            height: 1.25,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          isAr
                              ? 'اقرأ وتدارس القرآن مع إخوانك في مكالمة صوتية وتصفح مشترك للمصحف.'
                              : 'Read and practice the Quran together with live voice and shared pages.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: c.textSecondary,
                            fontSize: 13.0,
                            fontWeight: FontWeight.w500,
                            height: 1.40,
                          ),
                        ),

                        const SizedBox(height: 18),

                        // ── 3 Balanced Feature Rows (Eye-Comfort Alignment) ──
                        Container(
                          width: double.infinity,
                          decoration: BoxDecoration(
                            color: c.surfaceHigh.withValues(alpha: isDark ? 0.40 : 0.65),
                            borderRadius: BorderRadius.circular(18),
                            border: Border.all(
                              color: c.border.withValues(alpha: isDark ? 0.25 : 0.35),
                              width: 0.9,
                            ),
                          ),
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                          child: Column(
                            children: [
                              _buildPillarRow(
                                icon: Icons.pin_rounded,
                                iconColor: c.primary,
                                title: isAr ? 'رمز من 5 أرقام' : 'Simple 5-Digit Code',
                                description: isAr
                                    ? 'أنشئ مجلساً أو ادخل برمز من 5 أرقام، بدون حسابات ولا روابط.'
                                    : 'Enter or create a room in seconds. No account or links needed.',
                                c: c,
                                isAr: isAr,
                              ),
                              Padding(
                                padding: const EdgeInsets.symmetric(vertical: 9),
                                child: Divider(
                                  height: 1,
                                  thickness: 0.7,
                                  color: c.border.withValues(alpha: isDark ? 0.20 : 0.35),
                                ),
                              ),
                              _buildPillarRow(
                                icon: Icons.menu_book_rounded,
                                iconColor: c.gold,
                                title: isAr ? 'تزامن المصحف معاً' : 'Follow Along Live',
                                description: isAr
                                    ? 'تتنقل الصفحات والآيات وتظليل التلاوة مع القارئ على شاشات الجميع.'
                                    : 'Pages, verses, and recitation highlights stay in sync for everyone.',
                                c: c,
                                isAr: isAr,
                              ),
                              Padding(
                                padding: const EdgeInsets.symmetric(vertical: 9),
                                child: Divider(
                                  height: 1,
                                  thickness: 0.7,
                                  color: c.border.withValues(alpha: isDark ? 0.20 : 0.35),
                                ),
                              ),
                              _buildPillarRow(
                                icon: Icons.record_voice_over_rounded,
                                iconColor: c.secondary,
                                title: isAr ? 'مكالمة صوتية مباشرة' : 'Live Voice Call',
                                description: isAr
                                    ? 'تحدث واستمع مباشرة (حتى 4 أفراد) للتسميع والمراجعة وتصحيح التلاوة.'
                                    : 'Talk and listen together (up to 4 people) to recite, practice, and correct mistakes.',
                                c: c,
                                isAr: isAr,
                              ),
                            ],
                          ),
                        ),

                        const SizedBox(height: 18),

                        // ── Primary Action: Enter Maglis Now ──
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton(
                            onPressed: () async {
                              AppHaptics.mediumImpact();
                              final prefs = await SharedPreferences.getInstance();
                              await prefs.setBool('has_seen_v1_2_maglis_whats_new', true);
                              if (context.mounted) {
                                Navigator.of(context).pop();
                                await MaglisEntryDialog.show(context);
                              }
                            },
                            style: ElevatedButton.styleFrom(
                              backgroundColor: c.primary,
                              foregroundColor: Colors.white,
                              elevation: 0,
                              padding: const EdgeInsets.symmetric(vertical: 13),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14),
                              ),
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Text(
                                  isAr ? 'جرّب المجلس الآن' : 'Try Maglis Now',
                                  style: const TextStyle(
                                    fontSize: 14.8,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Icon(
                                  isAr ? Icons.arrow_back_rounded : Icons.arrow_forward_rounded,
                                  size: 17,
                                ),
                              ],
                            ),
                          ),
                        ),

                        const SizedBox(height: 4),

                        // ── Secondary Dismiss Action: Simple & Humble ──
                        SizedBox(
                          width: double.infinity,
                          child: TextButton(
                            onPressed: () async {
                              AppHaptics.lightImpact();
                              final prefs = await SharedPreferences.getInstance();
                              await prefs.setBool('has_seen_v1_2_maglis_whats_new', true);
                              if (context.mounted) {
                                Navigator.of(context).pop();
                              }
                            },
                            style: TextButton.styleFrom(
                              foregroundColor: c.muted,
                              padding: const EdgeInsets.symmetric(vertical: 9),
                              visualDensity: VisualDensity.compact,
                            ),
                            child: Text(
                              isAr ? 'لاحقاً' : 'Maybe Later',
                              style: TextStyle(
                                color: c.muted,
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  /// Builds a clean, perfectly aligned feature pillar row.
  Widget _buildPillarRow({
    required IconData icon,
    required Color iconColor,
    required String title,
    required String description,
    required dynamic c,
    required bool isAr,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Vector Badge Container
        Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            color: iconColor.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(11),
            border: Border.all(
              color: iconColor.withValues(alpha: 0.24),
              width: 0.8,
            ),
          ),
          alignment: Alignment.center,
          child: Icon(
            icon,
            size: 20,
            color: iconColor,
          ),
        ),
        const SizedBox(width: 12),
        // Aligned text block
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: TextStyle(
                  color: c.text,
                  fontSize: 13.5,
                  fontWeight: FontWeight.bold,
                  letterSpacing: isAr ? 0.0 : -0.2,
                ),
              ),
              const SizedBox(height: 2.5),
              Text(
                description,
                style: TextStyle(
                  color: c.textSecondary,
                  fontSize: 12.0,
                  fontWeight: FontWeight.w400,
                  height: 1.40,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

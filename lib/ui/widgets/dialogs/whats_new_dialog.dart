import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../../services/app_haptics.dart';
import '../../../state/app_state.dart';

/// "What's New" Dialog built strictly according to Natlu's native dialog architecture.
///
/// Follows the exact design pattern of [permission_dialog.dart] and [theme_selection_dialog.dart]:
/// - Circular icon container in c.primary.withValues(alpha: 0.10)
/// - Authentic c.surface background, rounded corners (24dp), and c.border boundary
/// - Two focused, eye-comfortable cards highlighting the new features
/// - Standard full-width ElevatedButton in c.primary to dismiss cleanly
class WhatsNewDialog extends StatelessWidget {
  const WhatsNewDialog({super.key});

  /// Displays the WhatsNewDialog modal centered with zero eye strain.
  static Future<void> show(BuildContext context) async {
    await showDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierColor: Colors.black.withValues(alpha: 0.55),
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

          final title = isAr ? 'جديد تطبيق نتلو' : "What's New in Natlu";

          return Directionality(
            textDirection: isAr ? TextDirection.rtl : TextDirection.ltr,
            child: Dialog(
              backgroundColor: Colors.transparent,
              insetPadding: const EdgeInsets.symmetric(horizontal: 28),
              child: Container(
                decoration: BoxDecoration(
                  color: c.surface,
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(
                    color: c.border.withValues(alpha: 0.25),
                    width: 1,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color:
                          Colors.black.withValues(alpha: isDark ? 0.35 : 0.10),
                      blurRadius: 16,
                      offset: const Offset(0, 6),
                    ),
                  ],
                ),
                padding: const EdgeInsets.all(22),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // ── 1. Circular Top Icon Badge ──
                    Container(
                      padding: const EdgeInsets.all(15),
                      decoration: BoxDecoration(
                        color: c.primary.withValues(alpha: 0.10),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        Icons.groups_rounded,
                        color: c.primary,
                        size: 32,
                      ),
                    ),
                    const SizedBox(height: 14),

                    // ── 2. Dialog Title ──
                    Text(
                      title,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: c.text,
                        fontSize: 18.5,
                        fontWeight: FontWeight.bold,
                        letterSpacing: isAr ? 0.0 : -0.3,
                        height: isAr ? 1.3 : 1.2,
                      ),
                    ),
                    const SizedBox(height: 16),

                    // ── 3. Feature Card 1: Maglis Study Circle ──
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 13, vertical: 11),
                      decoration: BoxDecoration(
                        color: c.primary.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: c.primary.withValues(alpha: 0.20),
                          width: 1,
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(
                                Icons.groups_rounded,
                                color: c.primary,
                                size: 18,
                              ),
                              const SizedBox(width: 8),
                              Text(
                                isAr ? 'مجلس القرآن المجيد' : 'The Glorious Quran Circle',
                                style: TextStyle(
                                  color: c.primary,
                                  fontSize: 14,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Text(
                            isAr
                                ? 'حلقة مباركة لتلاوة آيات الذكر الحكيم وتدارسها حتى 4 أفراد بمحادثة صوتية وتزامن حي للمصحف'
                                : 'Interactive Quran study circle for up to 4 peers with open voice call and live Mushaf sync using a 5-digit code',
                            style: TextStyle(
                              color: c.text,
                              fontSize: 12.5,
                              fontWeight: FontWeight.w500,
                              height: 1.38,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 10),

                    // ── 4. Feature Card 2: Smart Collapsible Dock ──
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 13, vertical: 11),
                      decoration: BoxDecoration(
                        color: c.gold.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: c.gold.withValues(alpha: 0.25),
                          width: 1,
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(
                                Icons.mic_none_rounded,
                                color: c.gold,
                                size: 18,
                              ),
                              const SizedBox(width: 8),
                              Text(
                                isAr
                                    ? 'شريط التلاوة الذكي'
                                    : 'Smart Action Dock',
                                style: TextStyle(
                                  color: c.gold,
                                  fontSize: 14,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Text(
                            isAr
                                ? 'شريط سفلي انسيابي ينكمش تلقائياً أثناء التلاوة ليوفر لك وصولاً سريعاً ومريحاً لخصائص التجويد والإخفاء'
                                : 'A streamlined bottom bar that collapses dynamically during recitation, giving quick access to Tajweed and Hide tools',
                            style: TextStyle(
                              color: c.text,
                              fontSize: 12.5,
                              fontWeight: FontWeight.w500,
                              height: 1.38,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),

                    // ── 5. Standard Confirmation Button ──
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: () async {
                          AppHaptics.lightImpact();
                          final prefs = await SharedPreferences.getInstance();
                          await prefs.setBool(
                              'has_seen_v1_2_maglis_whats_new', true);
                          if (context.mounted) {
                            Navigator.of(context).pop();
                          }
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: c.primary,
                          foregroundColor: Colors.white,
                          elevation: 0,
                          padding: const EdgeInsets.symmetric(vertical: 13),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        child: Text(
                          isAr ? 'حسناً، فهمت' : 'Got it',
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

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
    await prefs.setBool('has_seen_mushaf_whats_new', true);
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

          final title = isAr ? 'جديد تطبيق نتلو' : "What's New in Natlu";

          return Directionality(
            textDirection: isAr ? TextDirection.rtl : TextDirection.ltr,
            child: Dialog(
              backgroundColor: Colors.transparent,
              insetPadding: const EdgeInsets.symmetric(horizontal: 32),
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
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // ── 1. Circular Top Icon Badge ──
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: c.primary.withValues(alpha: 0.10),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        Icons.auto_stories_rounded,
                        color: c.primary,
                        size: 34,
                      ),
                    ),
                    const SizedBox(height: 16),

                    // ── 2. Dialog Title ──
                    Text(
                      title,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: c.text,
                        fontSize: 19,
                        fontWeight: FontWeight.bold,
                        letterSpacing: isAr ? 0.0 : -0.3,
                        height: isAr ? 1.3 : 1.2,
                      ),
                    ),
                    const SizedBox(height: 16),

                    // ── 3. Feature Card 1: Mushaf Layout ──
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 12),
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
                                Icons.auto_stories_rounded,
                                color: c.primary,
                                size: 18,
                              ),
                              const SizedBox(width: 8),
                              Text(
                                isAr ? 'طريقة عرض المصحف' : 'Mushaf View',
                                style: TextStyle(
                                  color: c.primary,
                                  fontSize: 14.5,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 5),
                          Text(
                            isAr
                                ? 'يمكنك التبديل بين المصحف وقائمة الآيات في أي وقت من أعلى قائمة السور'
                                : 'You can switch between Mushaf and List view anytime from the top of the Surah list',
                            style: TextStyle(
                              color: c.text,
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                              height: 1.4,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 10),

                    // ── 4. Feature Card 2: One-Tap Verse Audio ──
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 12),
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
                                Icons.headphones_rounded,
                                color: c.gold,
                                size: 18,
                              ),
                              const SizedBox(width: 8),
                              Text(
                                isAr
                                    ? 'الاستماع المباشر للآية'
                                    : 'One-Tap Verse Audio',
                                style: TextStyle(
                                  color: c.gold,
                                  fontSize: 14.5,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 5),
                          Text(
                            isAr
                                ? 'في وضع المصحف، المس رقم أي آية للاستماع لتلاوتها مباشرة'
                                : 'In Mushaf mode, tap any verse number to hear instant recitation',
                            style: TextStyle(
                              color: c.text,
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                              height: 1.4,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 22),

                    // ── 5. Standard Confirmation Button ──
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: () async {
                          AppHaptics.lightImpact();
                          final prefs = await SharedPreferences.getInstance();
                          await prefs.setBool(
                              'has_seen_mushaf_whats_new', true);
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

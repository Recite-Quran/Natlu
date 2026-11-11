import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../../core/app_state.dart';
import 'dialog_base.dart';

// ══════════════════════════════════════════════════════════════════════════════
// 1. APP GUIDE & HOW-TO DIALOG
// ══════════════════════════════════════════════════════════════════════════════

/// Ultra-lightweight, zero-duplicate user guide explaining strictly how to use:
/// 1. Word colors (Green: right, Yellow: Tajweed/Tashkeel & tap to see error, Red: skipped/wrong).
/// 2. Tajweed toggle button (with same icon).
/// 3. Audio on Ayah number tap & word tap (no "(1)").
/// 4. Voice search.
/// 5. Maglis live group recitation.
/// 6. Verse list & auto-scroll.
class AppGuideDialog extends StatelessWidget {
  const AppGuideDialog({super.key});

  /// Displays the AppGuideDialog modal centered with zero eye strain.
  static Future<void> show(BuildContext context) async {
    await showDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierColor: DialogTokens.barrierColor,
      builder: (_) => const AppGuideDialog(),
    );
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('has_seen_app_guide_v1', true);
    await prefs.setBool('has_seen_v1_2_maglis_whats_new', true);
  }

  @override
  Widget build(BuildContext context) {
    final app = AppState.instance;
    final c = app.colors;
    final isAr = app.isArabic;
    final isDark = app.isDarkMode;

    return AppDialog(
      maxWidth: 380,
      scrollable: true,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
      topTrailing: IconButton(
        onPressed: () {
          Navigator.of(context).pop();
        },
        icon: Icon(Icons.close_rounded, color: c.muted, size: 20),
        visualDensity: VisualDensity.compact,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
        splashRadius: 16,
      ),
      title: isAr ? 'دليل الاستخدام' : 'How to Use',
      content: Container(
        width: double.infinity,
        decoration: BoxDecoration(
          color: c.surfaceHigh.withValues(alpha: isDark ? 0.35 : 0.55),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: c.border.withValues(alpha: isDark ? 0.22 : 0.30),
            width: 0.8,
          ),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Column(
          children: [
            // 1. Recitation Colors
            _buildRow(
              icon: Icons.check_circle_outline_rounded,
              iconColor: c.green,
              title: isAr ? 'ألوان التسميع' : 'Recitation Colors',
              c: c,
              body: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildBullet(
                    color: c.green,
                    text: isAr ? 'أخضر: كلمة صحيحة' : 'Green: Correct word',
                    c: c,
                  ),
                  const SizedBox(height: 2),
                  _buildBullet(
                    color: c.warning,
                    text: isAr
                        ? 'أصفر: خطأ تجويد/تشكيل (اضغط لمعرفة الخطأ)'
                        : 'Yellow: Mistake (tap to see error)',
                    c: c,
                    highlight: true,
                  ),
                  const SizedBox(height: 2),
                  _buildBullet(
                    color: c.red,
                    text: isAr ? 'أحمر: كلمة متروكة أو خاطئة' : 'Red: Skipped or wrong word',
                    c: c,
                  ),
                ],
              ),
            ),
            _buildDivider(c, isDark),

            // 2. Tajweed Option Button
            _buildRow(
              icon: Icons.record_voice_over_rounded,
              iconColor: c.primary,
              title: isAr ? 'أحكام التجويد' : 'Tajweed Rules',
              text: isAr
                  ? 'زر التجويد لتفعيل أو إيقاف التنبيه على أحكام التجويد والتشكيل.'
                  : 'Button to enable or disable Tajweed and Tashkeel feedback.',
              c: c,
            ),
            _buildDivider(c, isDark),

            // 3. Audio Playback
            _buildRow(
              icon: Icons.play_circle_fill_rounded,
              iconColor: isDark ? c.gold : const Color(0xFFD97706),
              title: isAr ? 'تشغيل الصوت' : 'Audio Playback',
              text: isAr
                  ? 'اضغط على رقم الآية لتشغيل التلاوة، واضغط على أي كلمة لسماع نطقها.'
                  : 'Tap Ayah number to play recitation, or tap any word to hear it.',
              c: c,
            ),
            _buildDivider(c, isDark),

            // 4. Voice Search
            _buildRow(
              icon: Icons.graphic_eq_rounded,
              iconColor: const Color(0xFF10B981),
              title: isAr ? 'بحث صوتي' : 'Voice Search',
              text: isAr
                  ? 'زر داخل قائمة السور للبحث الصوتي عن أي آية بمجرد نطقها.'
                  : 'A button inside the Surah list to jump to any verse by voice.',
              c: c,
            ),
            _buildDivider(c, isDark),

            // 5. Quran Maglis
            _buildRow(
              icon: Icons.groups_rounded,
              iconColor: const Color(0xFF2563EB),
              title: isAr ? 'مجلس القرآن' : 'Quran Maglis',
              text: isAr
                  ? 'تلاوة جماعية مباشرة بمكالمة صوتية وتصفح مشترك عبر رمز (5 أرقام).'
                  : 'Recite together live with voice call & synced pages using a 5-digit code.',
              c: c,
            ),
          ],
        ),
      ),
      primaryAction: AppDialogActionItem(
        label: isAr ? 'فهمت' : 'Got it',
        onPressed: () {
          Navigator.of(context).pop();
        },
      ),
    );
  }

  Widget _buildRow({
    required IconData icon,
    required Color iconColor,
    required String title,
    required ThemeColors c,
    String? text,
    Widget? body,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 30,
          height: 30,
          decoration: BoxDecoration(
            color: iconColor.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(8),
          ),
          alignment: Alignment.center,
          child: Icon(icon, size: 16.5, color: iconColor),
        ),
        const SizedBox(width: 9),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: TextStyle(
                  color: c.text,
                  fontSize: 12.5,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 1.5),
              body ??
                  Text(
                    text!,
                    style: TextStyle(
                      color: c.textSecondary,
                      fontSize: 11.5,
                      height: 1.35,
                    ),
                  ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildBullet({
    required Color color,
    required String text,
    required ThemeColors c,
    bool highlight = false,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Container(
          width: 5.5,
          height: 5.5,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            text,
            style: TextStyle(
              color: highlight ? c.text : c.textSecondary,
              fontSize: 11.2,
              fontWeight: highlight ? FontWeight.w600 : FontWeight.w400,
              height: 1.25,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildDivider(ThemeColors c, bool isDark) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Divider(
        height: 1,
        thickness: 0.7,
        color: c.border.withValues(alpha: isDark ? 0.16 : 0.22),
      ),
    );
  }
}

/// Backward compatibility alias
typedef WhatsNewDialog = AppGuideDialog;

// ══════════════════════════════════════════════════════════════════════════════
// 2. MAGLIS HOW-TO EXPLANATION DIALOG
// ══════════════════════════════════════════════════════════════════════════════

class MaglisExplanationDialog extends StatelessWidget {
  const MaglisExplanationDialog({super.key});

  /// Displays the explanation dialog and persists that the user has seen it.
  static Future<void> show(BuildContext context) async {
    await showDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierColor: DialogTokens.barrierColor,
      builder: (_) => const MaglisExplanationDialog(),
    );
    final prefs = await SharedPreferences.getInstance();
    AppState.instance.hasSeenMaglisExplanation = true;
    await prefs.setBool('has_seen_maglis_explanation', true);
  }

  @override
  Widget build(BuildContext context) {
    final app = AppState.instance;
    final isAr = app.isArabic;
    final c = app.colors;

    final purpose = isAr
        ? 'مجلس قرآني مباشر بالصوت وتزامن المصحف (حتى 4 أفراد) للتسميع والتصحيح بين المعلم والطلاب.'
        : 'A live Quran Maglis with open voice & synced Mushaf (up to 4 peers) to recite and correct together.';

    return AppDialog(
      heroIcon: const AppDialogHeroIcon(
        icon: Icons.groups_rounded,
        iconSize: 30,
        padding: 12,
      ),
      title: isAr ? 'مجلس القرآن المجيد' : 'The Glorious Quran Maglis',
      banner: AppDialogInfoBanner(
        text: purpose,
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildStepRow(
            number: '1',
            title: isAr ? 'الرمز (5 أرقام)' : '5-Digit Maglis Code',
            body: isAr
                ? '• المعلم: يضغط "عقد المجلس" ويشارك الرمز مع الطلاب.\n• الطالب: يضغط "دخول المجلس" ويكتب الرمز للانضمام فوراً.'
                : '• Teacher: Taps "Open Maglis" and shares the code.\n• Student: Taps "Join Maglis", types code, and enters instantly.',
            c: c,
          ),
          const SizedBox(height: 10),
          _buildStepRow(
            number: '2',
            title: isAr ? 'التسميع والتصحيح' : 'Reciting & Guiding',
            body: isAr
                ? '• الصوت مسموع للجميع للمحادثة والتوجيه كمكالمة حية.\n• عند ضغط زر "التسجيل"، يظهر مصحفك وتلاوتك للجميع.'
                : '• Voice call is live for everyone to listen and guide.\n• Tap "Record" to broadcast your recitation and verses live.',
            c: c,
          ),
        ],
      ),
      primaryAction: AppDialogActionItem(
        label: isAr ? 'فهمت، لنبدأ' : "Got it, let's start",
        onPressed: () {
          Navigator.of(context).pop();
        },
      ),
    );
  }

  Widget _buildStepRow({
    required String number,
    required String title,
    required String body,
    required ThemeColors c,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: c.surfaceHigh,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: c.border.withValues(alpha: 0.35),
          width: 0.9,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 22,
            height: 22,
            decoration: BoxDecoration(
              color: c.primary,
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: Text(
              number,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: c.text,
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  body,
                  style: TextStyle(
                    color: c.muted,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w500,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

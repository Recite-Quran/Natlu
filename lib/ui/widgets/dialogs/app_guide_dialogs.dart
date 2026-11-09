import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../../core/platform_utils.dart';
import '../../../core/app_state.dart';
import 'dialog_base.dart';
import 'maglis_entry_dialog.dart';

// ══════════════════════════════════════════════════════════════════════════════
// 1. WHAT'S NEW FEATURE GUIDE DIALOG
// ══════════════════════════════════════════════════════════════════════════════

class WhatsNewDialog extends StatelessWidget {
  const WhatsNewDialog({super.key});

  /// Displays the WhatsNewDialog modal centered with zero eye strain.
  static Future<void> show(BuildContext context) async {
    await showDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierColor: DialogTokens.barrierColor,
      builder: (_) => const WhatsNewDialog(),
    );
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('has_seen_v1_2_maglis_whats_new', true);
  }

  @override
  Widget build(BuildContext context) {
    final app = AppState.instance;
    final c = app.colors;
    final isAr = app.isArabic;
    final isDark = app.isDarkMode;

    return AppDialog(
      maxWidth: 400,
      scrollable: true,
      topTrailing: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4.5),
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
                Icon(Icons.groups_rounded, size: 14, color: c.primary),
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
          IconButton(
            onPressed: () {
              AppHaptics.lightImpact();
              Navigator.of(context).pop();
            },
            icon: Icon(Icons.close_rounded, color: c.muted, size: 20),
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            splashRadius: 18,
          ),
        ],
      ),
      title: isAr ? 'مجلس القرآن' : 'Quran Maglis',
      subtitle: isAr
          ? 'اقرأ وتدارس القرآن مع إخوانك في مكالمة صوتية وتصفح مشترك للمصحف.'
          : 'Read and practice the Quran together with live voice and shared pages.',
      content: Container(
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
              icon: Icons.record_voice_over_rounded,
              iconColor: c.primary,
              title: isAr ? 'تسميع صوتي مباشر' : 'Live Voice Recitation',
              description: isAr
                  ? 'اتصال صوتي فوري عالي النقاء بين أفراد المجلس للتسميع والتصحيح.'
                  : 'Crystal-clear peer audio for listening, guidance, and correction.',
              c: c,
              isAr: isAr,
            ),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Divider(
                height: 1,
                thickness: 0.8,
                color: c.border.withValues(alpha: isDark ? 0.20 : 0.30),
              ),
            ),
            _buildPillarRow(
              icon: Icons.menu_book_rounded,
              iconColor: isDark ? c.gold : c.primary,
              title: isAr ? 'تزامن صفحات المصحف' : 'Synchronized Mushaf',
              description: isAr
                  ? 'يتابع الجميع الصفحة والآية المتلوة تلقائياً لحظة بلحظة.'
                  : 'Page turns sync automatically to the active reader in real-time.',
              c: c,
              isAr: isAr,
            ),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Divider(
                height: 1,
                thickness: 0.8,
                color: c.border.withValues(alpha: isDark ? 0.20 : 0.30),
              ),
            ),
            _buildPillarRow(
              icon: Icons.lock_outline_rounded,
              iconColor: isDark ? Colors.white70 : c.muted,
              title: isAr ? 'مجلس خاص برمز آمن' : 'Private & Simple',
              description: isAr
                  ? 'رمز مكون من 5 أرقام لدخول الطلاب فوراً دون تسجيل أو حسابات.'
                  : 'Instant 5-digit code entry with zero accounts, passwords, or setup.',
              c: c,
              isAr: isAr,
            ),
          ],
        ),
      ),
      customActions: Column(
        children: [
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
                    isAr
                        ? Icons.arrow_back_rounded
                        : Icons.arrow_forward_rounded,
                    size: 17,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 4),
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
    );
  }

  Widget _buildPillarRow({
    required IconData icon,
    required Color iconColor,
    required String title,
    required String description,
    required ThemeColors c,
    required bool isAr,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
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
          child: Icon(icon, size: 20, color: iconColor),
        ),
        const SizedBox(width: 12),
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
          AppHaptics.lightImpact();
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


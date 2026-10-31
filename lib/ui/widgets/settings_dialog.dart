import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../state/app_state.dart';
import 'settings/setting_tile.dart';

/// Settings modal bottom sheet with modern styling.
class SettingsDialog extends StatelessWidget {
  const SettingsDialog({super.key});

  @override
  Widget build(BuildContext context) {
    final app = AppState.instance;

    return RepaintBoundary(
      child: ListenableBuilder(
        listenable: Listenable.merge([app.themeNotifier, app.languageNotifier]),
        builder: (context, _) {
          final c = app.colors;
          final isAr = app.isArabic;

          return Directionality(
            textDirection: isAr ? TextDirection.rtl : TextDirection.ltr,
            child: Container(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(context).height * 0.75,
              ),
              decoration: BoxDecoration(
                color: c.surface,
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(28),
                ),
                border: Border.all(
                  color: c.border.withValues(alpha: app.isDarkMode ? 0.35 : 0.6),
                  width: 1,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: app.isDarkMode ? 0.35 : 0.08),
                    blurRadius: 16,
                    offset: const Offset(0, -4),
                  ),
                ],
              ),
              child: Material(
                color: Colors.transparent,
                child: SafeArea(
                  top: false,
                  child: SingleChildScrollView(
                    physics: const BouncingScrollPhysics(),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const SizedBox(height: 12),

                        // ── Handle ──
                        Container(
                          width: 44,
                          height: 4,
                          decoration: BoxDecoration(
                            color: c.border,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                        const SizedBox(height: 16),

                        // ── Top Dua Banner (Single Line) ──
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 20),
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text(
                              'بفضل الله وبرحمته ربنا تقبل منا إنك أنت السميع العليم',
                              textAlign: TextAlign.center,
                              textDirection: TextDirection.rtl,
                              style: TextStyle(
                                color: c.primary.withValues(alpha: 0.75),
                                fontSize: 13.5,
                                fontWeight: FontWeight.w600,
                                height: 1.3,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 14),

                        // ── Application Preferences Card ──
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 20),
                          child: Container(
                            decoration: BoxDecoration(
                              color: c.surfaceHigh,
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(
                                color: c.border.withValues(alpha: 0.5),
                                width: 1,
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withValues(alpha: app.isDarkMode ? 0.20 : 0.03),
                                  blurRadius: 10,
                                ),
                              ],
                            ),
                            child: Column(
                              children: [
                                // 1. Language
                                SettingTile(
                                  icon: Icons.language_rounded,
                                  title: isAr ? 'اللغة' : 'Language',
                                  c: c,
                                  trailing: PremiumPillSelector(
                                    labels: const ['عربي', 'English'],
                                    selected: isAr ? 0 : 1,
                                    c: c,
                                    onSelected: (i) {
                                      if ((i == 0 && !isAr) || (i == 1 && isAr)) {
                                        app.toggleLanguage();
                                      }
                                    },
                                  ),
                                ),
                                PremiumSettingDivider(c: c),

                                // 2. Theme
                                SettingTile(
                                  icon: Icons.palette_rounded,
                                  title: isAr ? 'المظهر' : 'Theme',
                                  c: c,
                                  trailing: PremiumPillSelector(
                                    labels: isAr
                                        ? ['أبيض', 'أسود']
                                        : ['White', 'Black'],
                                    selected: app.theme.index,
                                    c: c,
                                    onSelected: (i) => app.setTheme(AppTheme.values[i]),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),

                        // ── Telegram Contact Banner ──
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 20),
                          child: Container(
                            decoration: BoxDecoration(
                              color: c.surfaceHigh,
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(
                                color: const Color(0xFF229ED9).withValues(alpha: app.isDarkMode ? 0.35 : 0.25),
                                width: 1,
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withValues(alpha: app.isDarkMode ? 0.20 : 0.03),
                                  blurRadius: 10,
                                ),
                              ],
                            ),
                            child: Material(
                              color: Colors.transparent,
                              child: InkWell(
                                borderRadius: BorderRadius.circular(16),
                                onTap: () async {
                                  final uri = Uri.parse('https://t.me/AlQuranElMageed');
                                  try {
                                    await launchUrl(uri, mode: LaunchMode.externalApplication);
                                  } catch (_) {}
                                },
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
                                  child: Row(
                                    children: [
                                      Container(
                                        width: 36,
                                        height: 36,
                                        decoration: BoxDecoration(
                                          color: const Color(0xFF229ED9).withValues(alpha: 0.15),
                                          borderRadius: BorderRadius.circular(11),
                                        ),
                                        child: const Icon(
                                          Icons.send_rounded,
                                          color: Color(0xFF229ED9),
                                          size: 19,
                                        ),
                                      ),
                                      const SizedBox(width: 12),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Text(
                                              isAr ? 'تواصل معنا عبر تيليجرام' : 'Contact on Telegram',
                                              style: TextStyle(
                                                color: c.text,
                                                fontSize: 13.5,
                                                fontWeight: FontWeight.bold,
                                              ),
                                            ),
                                            const SizedBox(height: 1.5),
                                            Text(
                                              '@AlQuranElMageed',
                                              style: TextStyle(
                                                color: c.textSecondary.withValues(alpha: 0.8),
                                                fontSize: 11.5,
                                                fontWeight: FontWeight.w500,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                        decoration: BoxDecoration(
                                          color: const Color(0xFF229ED9),
                                          borderRadius: BorderRadius.circular(10),
                                        ),
                                        child: Text(
                                          isAr ? 'مراسلة' : 'Open',
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 12,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 16),

                        // ── Bottom Reset Button (Compact Height) ──
                        Material(
                          color: Colors.transparent,
                          child: InkWell(
                            borderRadius: BorderRadius.circular(8),
                            onTap: () async {
                              final prefs = await SharedPreferences.getInstance();
                              final savedSurah = prefs.getInt('last_surah');
                              final savedAyah = prefs.getInt('last_ayah');
                              await prefs.clear();
                              if (savedSurah != null) await prefs.setInt('last_surah', savedSurah);
                              if (savedAyah != null) await prefs.setInt('last_ayah', savedAyah);
                              if (context.mounted) {
                                await app.load();
                                if (context.mounted) {
                                  Navigator.of(context).pop();
                                  app.showSettingsResetBanner();
                                }
                              }
                            },
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.refresh_rounded,
                                    size: 13,
                                    color: c.textSecondary.withValues(alpha: 0.65),
                                  ),
                                  const SizedBox(width: 5),
                                  Text(
                                    isAr ? 'إعادة ضبط الإعدادات الافتراضية' : 'Reset to Default Settings',
                                    style: TextStyle(
                                      color: c.textSecondary.withValues(alpha: 0.70),
                                      fontSize: 12,
                                      fontWeight: FontWeight.w500,
                                      height: 1.1,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
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
}

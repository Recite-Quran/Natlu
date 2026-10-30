import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../state/app_state.dart';
import 'settings/setting_tile.dart';
import 'dialogs/whats_new_dialog.dart';

/// Settings modal bottom sheet with modern styling.
class SettingsDialog extends StatelessWidget {
  const SettingsDialog({super.key});

  @override
  Widget build(BuildContext context) {
    final app = AppState.instance;

    return RepaintBoundary(
      child: ListenableBuilder(
        listenable: app,
        builder: (context, _) {
          final c = app.colors;
          final isAr = app.isArabic;

          return Directionality(
            textDirection: isAr ? TextDirection.rtl : TextDirection.ltr,
            child: Container(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(context).size.height * 0.75,
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
                                  title: isAr ? 'مظهر التطبيق' : 'App Theme',
                                  c: c,
                                  bottom: PremiumPillSelector(
                                    labels: isAr
                                        ? ['أبيض', 'أسود']
                                        : ['White', 'Black'],
                                    selected: app.theme.index,
                                    c: c,
                                    onSelected: (i) => app.setTheme(AppTheme.values[i]),
                                  ),
                                ),
                                PremiumSettingDivider(c: c),

                                // 3. What's New
                                InkWell(
                                  borderRadius: BorderRadius.circular(16),
                                  onTap: () {
                                    Navigator.of(context).pop();
                                    WhatsNewDialog.show(context);
                                  },
                                  child: SettingTile(
                                    icon: Icons.auto_awesome_rounded,
                                    title: isAr ? 'ما الجديد في هذا التحديث' : "What's New in this Update",
                                    c: c,
                                    trailing: Icon(
                                      isAr ? Icons.arrow_back_ios_new_rounded : Icons.arrow_forward_ios_rounded,
                                      size: 13,
                                      color: c.muted,
                                    ),
                                  ),
                                ),
                              ],
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

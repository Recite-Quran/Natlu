import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../../core/app_state.dart';
import 'setting_tile.dart';

/// Settings modal bottom sheet with modern styling.
class SettingsDialog extends StatelessWidget {
  const SettingsDialog({super.key});

  static final Listenable _settingsListenable = Listenable.merge([
    AppState.instance.themeNotifier,
    AppState.instance.languageNotifier,
    AppState.instance.mushafModeNotifier,
  ]);

  @override
  Widget build(BuildContext context) {
    final app = AppState.instance;

    return RepaintBoundary(
      child: ListenableBuilder(
        listenable: _settingsListenable,
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
                  color:
                      c.border.withValues(alpha: app.isDarkMode ? 0.35 : 0.6),
                  width: 1,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black
                        .withValues(alpha: app.isDarkMode ? 0.35 : 0.08),
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
                    physics: const ClampingScrollPhysics(),
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
                                  color: Colors.black.withValues(
                                      alpha: app.isDarkMode ? 0.20 : 0.03),
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
                                      if ((i == 0 && !isAr) ||
                                          (i == 1 && isAr)) {
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
                                    onSelected: (i) =>
                                        app.setTheme(AppTheme.values[i]),
                                  ),
                                ),
                                if (!app.isMushafMode) ...[
                                  PremiumSettingDivider(c: c),
                                  FontSliderTile(c: c, app: app, isAr: isAr),
                                  PremiumSettingDivider(c: c),
                                  AutoScrollSliderTile(c: c, app: app, isAr: isAr),
                                ],
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
                                color: const Color(0xFF229ED9).withValues(
                                    alpha: app.isDarkMode ? 0.35 : 0.25),
                                width: 1,
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withValues(
                                      alpha: app.isDarkMode ? 0.20 : 0.03),
                                  blurRadius: 10,
                                ),
                              ],
                            ),
                            child: Material(
                              color: Colors.transparent,
                              child: InkWell(
                                borderRadius: BorderRadius.circular(16),
                                onTap: () async {
                                  final uri =
                                      Uri.parse('https://t.me/AlQuranElMageed');
                                  try {
                                    await launchUrl(uri,
                                        mode: LaunchMode.externalApplication);
                                  } catch (_) {}
                                },
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 14, vertical: 11),
                                  child: Row(
                                    children: [
                                      Stack(
                                        alignment: Alignment.center,
                                        children: [
                                          Container(
                                            width: 22,
                                            height: 22,
                                            decoration: const BoxDecoration(
                                              color: Colors.white,
                                              shape: BoxShape.circle,
                                            ),
                                          ),
                                          const Icon(
                                            Icons.telegram,
                                            color: Color(0xFF229ED9),
                                            size: 36,
                                          ),
                                        ],
                                      ),
                                      const SizedBox(width: 12),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Text(
                                              isAr
                                                  ? 'وأمرهم شورى بينهم'
                                                  : 'Their affair is mutual consultation',
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
                                                color: c.textSecondary
                                                    .withValues(alpha: 0.8),
                                                fontSize: 11.5,
                                                fontWeight: FontWeight.w500,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 10, vertical: 6),
                                        decoration: BoxDecoration(
                                          color: const Color(0xFF229ED9),
                                          borderRadius:
                                              BorderRadius.circular(10),
                                        ),
                                        child: Text(
                                          isAr ? 'مراسلة' : 'Message',
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
                              final prefs =
                                  await SharedPreferences.getInstance();
                              final savedSurah = prefs.getInt('last_surah');
                              final savedAyah = prefs.getInt('last_ayah');
                              await prefs.clear();
                              if (savedSurah != null)
                                await prefs.setInt('last_surah', savedSurah);
                              if (savedAyah != null)
                                await prefs.setInt('last_ayah', savedAyah);
                              if (context.mounted) {
                                await app.load();
                                if (context.mounted) {
                                  Navigator.of(context).pop();
                                  app.showSettingsResetBanner();
                                }
                              }
                            },
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 10, vertical: 4),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.refresh_rounded,
                                    size: 13,
                                    color:
                                        c.textSecondary.withValues(alpha: 0.65),
                                  ),
                                  const SizedBox(width: 5),
                                  Text(
                                    isAr
                                        ? 'إعادة ضبط الإعدادات الافتراضية'
                                        : 'Reset to Default Settings',
                                    style: TextStyle(
                                      color: c.textSecondary
                                          .withValues(alpha: 0.70),
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

/// Font size slider tile with live Arabic preview markers.
class FontSliderTile extends StatefulWidget {
  final ThemeColors c;
  final AppState app;
  final bool isAr;

  const FontSliderTile({
    super.key,
    required this.c,
    required this.app,
    required this.isAr,
  });

  @override
  State<FontSliderTile> createState() => _FontSliderTileState();
}

class _FontSliderTileState extends State<FontSliderTile> {
  late double _localSize;

  @override
  void initState() {
    super.initState();
    _localSize = widget.app.fontSize;
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.c;
    final app = widget.app;
    final isAr = widget.isAr;

    return SettingTile(
      icon: Icons.format_size_rounded,
      title: isAr ? 'حجم الخط' : 'Font Size',
      c: c,
      trailing: Row(
        children: [
          Text(
            'أ',
            style: TextStyle(
              fontFamily: 'HafsSmart',
              color: c.muted,
              fontSize: 12,
            ),
          ),
          Expanded(
            child: SliderTheme(
              data: SliderThemeData(
                thumbShape: const RoundSliderThumbShape(
                  enabledThumbRadius: 7,
                ),
                overlayShape: const RoundSliderOverlayShape(
                  overlayRadius: 14,
                ),
                trackHeight: 4,
                activeTrackColor: c.primary,
                inactiveTrackColor: c.border.withValues(alpha: 0.5),
                thumbColor: c.primary,
                overlayColor: c.primary.withValues(alpha: 0.15),
              ),
              child: Slider(
                value: _localSize,
                min: 16.0,
                max: 42.0,
                onChanged: (v) {
                  setState(() => _localSize = v);
                  app.setFontSize(v);
                },
                onChangeEnd: (v) {
                  app.setFontSize(v, persistImmediately: true);
                },
              ),
            ),
          ),
          Text(
            'أ',
            style: TextStyle(
              fontFamily: 'HafsSmart',
              color: c.muted,
              fontSize: 22,
            ),
          ),
        ],
      ),
    );
  }
}

/// AutoScroll speed slider tile for Reading mode.
class AutoScrollSliderTile extends StatefulWidget {
  final ThemeColors c;
  final AppState app;
  final bool isAr;

  const AutoScrollSliderTile({
    super.key,
    required this.c,
    required this.app,
    required this.isAr,
  });

  @override
  State<AutoScrollSliderTile> createState() => _AutoScrollSliderTileState();
}

class _AutoScrollSliderTileState extends State<AutoScrollSliderTile> {
  late double _localSpeed;

  @override
  void initState() {
    super.initState();
    _localSpeed = widget.app.autoScrollSpeed.toDouble();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.c;
    final app = widget.app;
    final isAr = widget.isAr;

    final labels = AppState.speedLabels;

    return SettingTile(
      icon: Icons.speed_rounded,
      title: isAr ? 'سرعة التمرير التلقائي' : 'Auto-Scroll Speed',
      c: c,
      trailing: Text(
        labels[_localSpeed.toInt()],
        style: TextStyle(
          color: c.primary,
          fontSize: 14,
          fontWeight: FontWeight.bold,
        ),
      ),
      bottom: SliderTheme(
        data: SliderThemeData(
          thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
          overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
          trackHeight: 4,
          activeTrackColor: c.primary,
          inactiveTrackColor: c.border.withValues(alpha: 0.5),
          thumbColor: c.primary,
          overlayColor: c.primary.withValues(alpha: 0.15),
          tickMarkShape: const RoundSliderTickMarkShape(tickMarkRadius: 2),
          activeTickMarkColor: c.surface,
          inactiveTickMarkColor: c.border,
        ),
        child: Slider(
          value: _localSpeed,
          min: 0,
          max: (labels.length - 1).toDouble(),
          divisions: labels.length - 1,
          label: labels[_localSpeed.toInt()],
          onChanged: (v) {
            setState(() => _localSpeed = v);
          },
          onChangeEnd: (v) {
            app.setAutoScrollSpeed(v.toInt());
          },
        ),
      ),
    );
  }
}

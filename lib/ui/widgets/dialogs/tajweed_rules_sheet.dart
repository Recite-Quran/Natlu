import 'package:flutter/material.dart';
import '../../../core/app_state.dart';
import '../../../core/highlighting_controller.dart';
import 'dialog_base.dart';

// ══════════════════════════════════════════════════════════════════════════════
// TAJWEED VERIFICATION RULES BOTTOM SHEET
// ══════════════════════════════════════════════════════════════════════════════

/// Bottom sheet dialog allowing the reciter to toggle all Tajweed rules,
/// disable Tajweed completely (memorization only), or configure custom rule subsets.
class TajweedRulesSheet extends StatefulWidget {
  final HighlightingController? controller;

  const TajweedRulesSheet({super.key, this.controller});

  static Future<void> show(
    BuildContext context, {
    HighlightingController? controller,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: DialogTokens.barrierColor,
      elevation: 0,
      builder: (_) => TajweedRulesSheet(controller: controller),
    );
  }

  @override
  State<TajweedRulesSheet> createState() => _TajweedRulesSheetState();
}

class _TajweedRulesSheetState extends State<TajweedRulesSheet> {
  late TajweedConfig _config;

  @override
  void initState() {
    super.initState();
    _config = AppState.instance.tajweedConfig;
  }

  void _applyConfig(TajweedConfig newConfig) {
    setState(() => _config = newConfig);
    final app = AppState.instance;
    if (newConfig.isAllDisabled) {
      app.setMode(AppMode.wordChecker);
      widget.controller?.setTajweedMode(false);
    } else {
      if (app.currentMode != AppMode.tajweed) {
        app.setMode(AppMode.tajweed);
        widget.controller?.setTajweedMode(true);
      }
    }
    app.setTajweedConfig(newConfig, widget.controller);
  }

  int _getPresetIndex() {
    final app = AppState.instance;
    if (app.currentMode != AppMode.tajweed || _config.isAllDisabled) {
      return 2; // None
    }
    if (_config.isAllEnabled) return 0; // All
    return 1; // Custom
  }

  void _onPresetSelected(int index) {
    final app = AppState.instance;
    if (index == 0) {
      app.setMode(AppMode.tajweed);
      widget.controller?.setTajweedMode(true);
      _applyConfig(const TajweedConfig.all());
    } else if (index == 2) {
      app.setMode(AppMode.wordChecker);
      widget.controller?.setTajweedMode(false);
      _applyConfig(const TajweedConfig.none());
    } else {
      app.setMode(AppMode.tajweed);
      widget.controller?.setTajweedMode(true);
      if (_config.isAllDisabled) {
        _applyConfig(const TajweedConfig.all());
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = AppState.instance;
    final c = app.colors;
    final isAr = app.isArabic;
    final isDark = app.isDarkMode;

    final presetIndex = _getPresetIndex();

    return AppBottomSheet(
      maxHeightFactor: 0.88,
      child: SingleChildScrollView(
        physics: const ClampingScrollPhysics(),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AppModalHeader(
                title: isAr ? 'أحكام التجويد' : 'Tajweed Rules',
                subtitle: isAr
                    ? 'التحقق الصوتي الدقيق من أحكام التلاوة ومخارج الحروف'
                    : 'Acoustic verification of Tajweed rules and letter points',
                leading: Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: const Color(0xFF10B981)
                        .withValues(alpha: isDark ? 0.16 : 0.10),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: const Color(0xFF10B981)
                          .withValues(alpha: isDark ? 0.30 : 0.20),
                      width: 1,
                    ),
                  ),
                  child: const Icon(
                    Icons.record_voice_over_rounded,
                    color: Color(0xFF10B981),
                    size: 20,
                  ),
                ),
              ),

              const SizedBox(height: 12),

              // ── Preset Segmented Selector (All / Custom / None) ──
              AppSegmentedPillSelector(
                labels: isAr
                    ? const ['الكل', 'مخصص', 'إيقاف']
                    : const ['All', 'Custom', 'None'],
                selected: presetIndex,
                c: c,
                onSelected: _onPresetSelected,
              ),

              const SizedBox(height: 12),

              // ── Active Mode Explanatory Pill ──
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                decoration: BoxDecoration(
                  color: (presetIndex == 2
                          ? c.muted
                          : const Color(0xFF10B981))
                      .withValues(alpha: isDark ? 0.10 : 0.07),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: (presetIndex == 2
                            ? c.muted
                            : const Color(0xFF10B981))
                        .withValues(alpha: isDark ? 0.22 : 0.16),
                    width: 0.8,
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      presetIndex == 0
                          ? Icons.verified_rounded
                          : presetIndex == 1
                              ? Icons.tune_rounded
                              : Icons.visibility_off_rounded,
                      size: 16,
                      color: presetIndex == 2
                          ? c.muted
                          : const Color(0xFF10B981),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        presetIndex == 0
                            ? (isAr
                                ? 'الوضع المعياري: فحص كامل لجميع أحكام التجويد ومخارج الحروف.'
                                : 'Standard mode: full verification of all Tajweed rules and Makharij.')
                            : presetIndex == 1
                                ? (isAr
                                    ? 'وضع مخصص: يمكنك تفعيل أو تعطيل أي حكم تجويدي أدناه.'
                                    : 'Custom mode: selectively toggle specific Tajweed rules below.')
                                : (isAr
                                    ? 'تم إيقاف التجويد: التحقق من الكلمات وصحة الحفظ فقط.'
                                    : 'Tajweed disabled: checks word accuracy and memorization only.'),
                        style: TextStyle(
                          color: presetIndex == 2 ? c.muted : c.text,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w500,
                          height: 1.25,
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 16),

              // ── Rules List Card ──
              Container(
                decoration: BoxDecoration(
                  color: isDark
                      ? Colors.white.withValues(alpha: 0.05)
                      : Colors.black.withValues(alpha: 0.035),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: isDark
                        ? Colors.white.withValues(alpha: 0.08)
                        : Colors.black.withValues(alpha: 0.06),
                    width: 1,
                  ),
                ),
                child: Column(
                  children: [
                    // 1. Madd
                    _RuleToggleTile(
                      title: isAr ? 'المدود' : 'Madd (Elongations)',
                      subtitle: isAr
                          ? 'طبيعي، متصل، منفصل، عارض، لازم، لين'
                          : 'Normal, Monfasel, Mottasel, Aared, Lazem, Leen',
                      icon: Icons.linear_scale_rounded,
                      value: _config.checkMadd,
                      c: c,
                      isDark: isDark,
                      onChanged: (val) =>
                          _applyConfig(_config.copyWith(checkMadd: val)),
                    ),
                    _RuleDivider(c: c, isDark: isDark),

                    // 2. Tashkeel
                    _RuleToggleTile(
                      title: isAr
                          ? 'التشكيل والحركات'
                          : 'Tashkeel (Vowel Diacritics)',
                      subtitle: isAr
                          ? 'الفتحة والكسرة والضمة على الحروف وأواخر الكلمات'
                          : 'Short vowels (Fathah, Kasrah, Dammah)',
                      icon: Icons.format_size_rounded,
                      value: _config.checkTashkeel,
                      c: c,
                      isDark: isDark,
                      onChanged: (val) =>
                          _applyConfig(_config.copyWith(checkTashkeel: val)),
                    ),
                    _RuleDivider(c: c, isDark: isDark),

                    // 3. Ghunnah
                    _RuleToggleTile(
                      title: isAr ? 'الغنة' : 'Ghunnah (Nasalization)',
                      subtitle: isAr
                          ? 'زمن الغنة للنون والميم المشددتين والإدغام'
                          : 'Nasal holding for doubled Noon & Meem',
                      icon: Icons.graphic_eq_rounded,
                      value: _config.checkGhunnah,
                      c: c,
                      isDark: isDark,
                      onChanged: (val) =>
                          _applyConfig(_config.copyWith(checkGhunnah: val)),
                    ),
                    _RuleDivider(c: c, isDark: isDark),

                    // 4. Shaddah
                    _RuleToggleTile(
                      title: isAr ? 'الشدة' : 'Shaddah (Gemination)',
                      subtitle: isAr
                          ? 'النبر والضغط الصوتي على الحروف المشددة'
                          : 'Consonant doubling and acoustic closure',
                      icon: Icons.flash_on_rounded,
                      value: _config.checkShaddah,
                      c: c,
                      isDark: isDark,
                      onChanged: (val) =>
                          _applyConfig(_config.copyWith(checkShaddah: val)),
                    ),
                    _RuleDivider(c: c, isDark: isDark),

                    // 5. Qalqalah
                    _RuleToggleTile(
                      title: isAr ? 'القلقلة' : 'Qalqalah (Echo / Burst)',
                      subtitle: isAr
                          ? 'نبر واضطراب مخرج حروف (ق، ط، ب، ج، د) عند السكون'
                          : 'Acoustic release burst for Qalqalah letters',
                      icon: Icons.waves_rounded,
                      value: _config.checkQalqalah,
                      c: c,
                      isDark: isDark,
                      onChanged: (val) =>
                          _applyConfig(_config.copyWith(checkQalqalah: val)),
                    ),
                    _RuleDivider(c: c, isDark: isDark),

                    // 6. Letter Swap
                    _RuleToggleTile(
                      title: isAr
                          ? 'مخارج وإبدال الحروف'
                          : 'Makharij & Letter Swaps',
                      subtitle: isAr
                          ? 'تنبيه إبدال الحروف المتقاربة (ص/س، ض/د، ذ/ز)'
                          : 'Flagging letter substitutions and close Makharij',
                      icon: Icons.spellcheck_rounded,
                      value: _config.checkLetterSwap,
                      c: c,
                      isDark: isDark,
                      onChanged: (val) =>
                          _applyConfig(_config.copyWith(checkLetterSwap: val)),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }
}

class _RuleToggleTile extends StatelessWidget {
  final String title;
  final String subtitle;
  final IconData icon;
  final bool value;
  final ThemeColors c;
  final bool isDark;
  final ValueChanged<bool> onChanged;

  const _RuleToggleTile({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.value,
    required this.c,
    required this.isDark,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: (value
                      ? const Color(0xFF10B981)
                      : c.muted)
                  .withValues(alpha: isDark ? 0.14 : 0.08),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(
              icon,
              size: 19,
              color: value ? const Color(0xFF10B981) : c.muted,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: c.text,
                    fontSize: 14.5,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: TextStyle(
                    color: c.textSecondary.withValues(alpha: 0.8),
                    fontSize: 11.5,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Switch.adaptive(
            value: value,
            activeThumbColor: const Color(0xFF10B981),
            activeTrackColor: const Color(0xFF10B981).withValues(alpha: 0.35),
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}

class _RuleDivider extends StatelessWidget {
  final ThemeColors c;
  final bool isDark;

  const _RuleDivider({required this.c, required this.isDark});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 1,
      margin: const EdgeInsetsDirectional.only(start: 64, end: 16),
      color: isDark
          ? Colors.white.withValues(alpha: 0.06)
          : Colors.black.withValues(alpha: 0.05),
    );
  }
}

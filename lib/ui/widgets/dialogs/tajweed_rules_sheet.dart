import 'package:flutter/material.dart';
import '../../../core/app_state.dart';
import '../../../core/highlighting_controller.dart';
import 'dialog_base.dart';

// ══════════════════════════════════════════════════════════════════════════════
// TAJWEED VERIFICATION RULES BOTTOM SHEET
// ══════════════════════════════════════════════════════════════════════════════

/// Bottom sheet dialog allowing the reciter to toggle all Tajweed rules,
/// deselect all (memorization only), or selectively toggle individual rules.
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

  int get _selectedCount {
    int count = 0;
    if (_config.checkMadd) count++;
    if (_config.checkTashkeel) count++;
    if (_config.checkGhunnah) count++;
    if (_config.checkShaddah) count++;
    if (_config.checkQalqalah) count++;
    if (_config.checkLetterSwap) count++;
    return count;
  }

  bool get _allSelected => _selectedCount == 6;

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

  void _toggleAll() {
    if (_allSelected) {
      _applyConfig(const TajweedConfig.none());
    } else {
      _applyConfig(const TajweedConfig.all());
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = AppState.instance;
    final c = app.colors;
    final isAr = app.isArabic;
    final isDark = app.isDarkMode;

    final allSelected = _allSelected;
    final selectedCount = _selectedCount;

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

              // ── Toolbar: Select All Checkbox + Counter (same as AudioDownloadDialog) ──
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: _toggleAll,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            allSelected
                                ? Icons.check_box_rounded
                                : (selectedCount == 0
                                    ? Icons.check_box_outline_blank_rounded
                                    : Icons.indeterminate_check_box_rounded),
                            size: 21,
                            color: allSelected || selectedCount > 0
                                ? const Color(0xFF10B981)
                                : c.muted,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            allSelected
                                ? (isAr ? 'إلغاء تحديد الكل' : 'Deselect All')
                                : (isAr ? 'تحديد الكل' : 'Select All'),
                            style: TextStyle(
                              fontFamily: isAr ? 'cairo' : null,
                              color: c.text,
                              fontSize: 13.5,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Text(
                      isAr
                          ? '${QuranTypography.toArabicDigits(selectedCount)} / ٦'
                          : '$selectedCount / 6',
                      style: TextStyle(
                        fontFamily: isAr ? 'cairo' : null,
                        color: c.muted,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 10),

              // ── Single Column Rules List Card ──
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
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(20),
                  child: Column(
                    children: [
                      // 1. Madd
                      _RuleCheckboxTile(
                        title: isAr ? 'المدود' : 'Madd (Elongations)',
                        subtitle: isAr
                            ? 'طبيعي، متصل، منفصل، عارض، لازم، لين'
                            : 'Normal, Monfasel, Mottasel, Aared, Lazem, Leen',
                        icon: Icons.linear_scale_rounded,
                        value: _config.checkMadd,
                        c: c,
                        isDark: isDark,
                        onTap: () => _applyConfig(
                            _config.copyWith(checkMadd: !_config.checkMadd)),
                      ),
                      _RuleDivider(c: c, isDark: isDark),

                      // 2. Tashkeel
                      _RuleCheckboxTile(
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
                        onTap: () => _applyConfig(_config.copyWith(
                            checkTashkeel: !_config.checkTashkeel)),
                      ),
                      _RuleDivider(c: c, isDark: isDark),

                      // 3. Ghunnah
                      _RuleCheckboxTile(
                        title: isAr ? 'الغنة' : 'Ghunnah (Nasalization)',
                        subtitle: isAr
                            ? 'زمن الغنة للنون والميم المشددتين والإدغام'
                            : 'Nasal holding for doubled Noon & Meem',
                        icon: Icons.graphic_eq_rounded,
                        value: _config.checkGhunnah,
                        c: c,
                        isDark: isDark,
                        onTap: () => _applyConfig(_config.copyWith(
                            checkGhunnah: !_config.checkGhunnah)),
                      ),
                      _RuleDivider(c: c, isDark: isDark),

                      // 4. Shaddah
                      _RuleCheckboxTile(
                        title: isAr ? 'الشدة' : 'Shaddah (Gemination)',
                        subtitle: isAr
                            ? 'النبر والضغط الصوتي على الحروف المشددة'
                            : 'Consonant doubling and acoustic closure',
                        icon: Icons.flash_on_rounded,
                        value: _config.checkShaddah,
                        c: c,
                        isDark: isDark,
                        onTap: () => _applyConfig(_config.copyWith(
                            checkShaddah: !_config.checkShaddah)),
                      ),
                      _RuleDivider(c: c, isDark: isDark),

                      // 5. Qalqalah
                      _RuleCheckboxTile(
                        title: isAr ? 'القلقلة' : 'Qalqalah (Echo / Burst)',
                        subtitle: isAr
                            ? 'نبر واضطراب مخرج حروف (ق، ط، ب، ج، د) عند السكون'
                            : 'Acoustic release burst for Qalqalah letters',
                        icon: Icons.waves_rounded,
                        value: _config.checkQalqalah,
                        c: c,
                        isDark: isDark,
                        onTap: () => _applyConfig(_config.copyWith(
                            checkQalqalah: !_config.checkQalqalah)),
                      ),
                      _RuleDivider(c: c, isDark: isDark),

                      // 6. Letter Swap
                      _RuleCheckboxTile(
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
                        onTap: () => _applyConfig(_config.copyWith(
                            checkLetterSwap: !_config.checkLetterSwap)),
                      ),
                    ],
                  ),
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

class _RuleCheckboxTile extends StatelessWidget {
  final String title;
  final String subtitle;
  final IconData icon;
  final bool value;
  final ThemeColors c;
  final bool isDark;
  final VoidCallback onTap;

  const _RuleCheckboxTile({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.value,
    required this.c,
    required this.isDark,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
          child: Row(
            children: [
              Icon(
                value
                    ? Icons.check_box_rounded
                    : Icons.check_box_outline_blank_rounded,
                size: 21,
                color: value ? const Color(0xFF10B981) : c.muted,
              ),
              const SizedBox(width: 13),
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: (value ? const Color(0xFF10B981) : c.muted)
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
            ],
          ),
        ),
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
      margin: const EdgeInsetsDirectional.only(start: 50, end: 16),
      color: isDark
          ? Colors.white.withValues(alpha: 0.06)
          : Colors.black.withValues(alpha: 0.05),
    );
  }
}

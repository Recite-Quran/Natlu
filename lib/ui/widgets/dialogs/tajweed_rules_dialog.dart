import 'package:flutter/material.dart';
import '../../../core/app_state.dart';
import '../../../core/highlighting_controller.dart';
import 'dialog_base.dart';

// ══════════════════════════════════════════════════════════════════════════════
// TAJWEED VERIFICATION RULES MODAL DIALOG
// ══════════════════════════════════════════════════════════════════════════════

/// Ultra-lightweight modal dialog for toggling Tajweed verification rules.
///
/// Fingerprint:
/// - Built on [AppDialog] and [DialogTokens] for 100% theme consistency with [AudioDownloadDialog].
/// - Single unified rule column with instant reactive state persistence.
class TajweedRulesDialog extends StatefulWidget {
  final HighlightingController? controller;

  const TajweedRulesDialog({super.key, this.controller});

  /// Displays the Tajweed rules dialog modally.
  static Future<void> show(
    BuildContext context, {
    HighlightingController? controller,
  }) {
    return showDialog<void>(
      context: context,
      barrierColor: DialogTokens.barrierColor,
      builder: (_) => TajweedRulesDialog(controller: controller),
    );
  }

  @override
  State<TajweedRulesDialog> createState() => _TajweedRulesDialogState();
}

class _TajweedRulesDialogState extends State<TajweedRulesDialog> {
  late TajweedConfig _config;

  static const _rules = [
    (
      'checkMadd',
      'المدود',
      'Madd (Elongations)',
      'طبيعي، متصل، منفصل، عارض، لازم، لين',
      Icons.linear_scale_rounded,
    ),
    (
      'checkTashkeel',
      'التشكيل والحركات',
      'Tashkeel (Diacritics)',
      'الفتحة والكسرة والضمة على الحروف',
      Icons.format_size_rounded,
    ),
    (
      'checkGhunnah',
      'الغنة',
      'Ghunnah (Nasalization)',
      'زمن الغنة للنون والميم المشددتين والإدغام',
      Icons.graphic_eq_rounded,
    ),
    (
      'checkShaddah',
      'الشدة',
      'Shaddah (Gemination)',
      'النبر والضغط الصوتي على الحروف المشددة',
      Icons.flash_on_rounded,
    ),
    (
      'checkQalqalah',
      'القلقلة',
      'Qalqalah (Echo / Burst)',
      'نبر واضطراب مخرج حروف (ق، ط، ب، ج، د)',
      Icons.waves_rounded,
    ),
    (
      'checkLetterSwap',
      'مخارج وإبدال الحروف',
      'Makharij & Letters',
      'تنبيه إبدال الحروف المتقاربة (ص/س، ض/د، ذ/ز)',
      Icons.spellcheck_rounded,
    ),
  ];

  @override
  void initState() {
    super.initState();
    _config = AppState.instance.tajweedConfig;
  }

  bool _isChecked(String key) => switch (key) {
        'checkMadd' => _config.checkMadd,
        'checkTashkeel' => _config.checkTashkeel,
        'checkGhunnah' => _config.checkGhunnah,
        'checkShaddah' => _config.checkShaddah,
        'checkQalqalah' => _config.checkQalqalah,
        _ => _config.checkLetterSwap,
      };

  void _toggle(String key) {
    _applyConfig(switch (key) {
      'checkMadd' => _config.copyWith(checkMadd: !_config.checkMadd),
      'checkTashkeel' =>
        _config.copyWith(checkTashkeel: !_config.checkTashkeel),
      'checkGhunnah' => _config.copyWith(checkGhunnah: !_config.checkGhunnah),
      'checkShaddah' => _config.copyWith(checkShaddah: !_config.checkShaddah),
      'checkQalqalah' =>
        _config.copyWith(checkQalqalah: !_config.checkQalqalah),
      _ => _config.copyWith(checkLetterSwap: !_config.checkLetterSwap),
    });
  }

  bool get _allSelected => _config.isAllEnabled;

  void _applyConfig(TajweedConfig cfg) {
    setState(() => _config = cfg);
    final app = AppState.instance;
    if (cfg.isAllDisabled) {
      app.setMode(AppMode.wordChecker);
      widget.controller?.setTajweedMode(false);
    } else if (app.currentMode != AppMode.tajweed) {
      app.setMode(AppMode.tajweed);
      widget.controller?.setTajweedMode(true);
    }
    app.setTajweedConfig(cfg, widget.controller);
  }

  void _toggleAll() => _applyConfig(
        _allSelected ? const TajweedConfig.none() : const TajweedConfig.all(),
      );

  @override
  Widget build(BuildContext context) {
    final app = AppState.instance;
    final c = app.colors;
    final isAr = app.isArabic;
    final isDark = app.isDarkMode;
    final allSelected = _allSelected;
    final selectedCount = _rules.where((r) => _isChecked(r.$1)).length;

    return Directionality(
      textDirection: isAr ? TextDirection.rtl : TextDirection.ltr,
      child: AppDialog(
        maxWidth: 390,
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 18),
        heroIcon: const AppDialogHeroIcon(
          icon: Icons.record_voice_over_rounded,
          iconSize: 26,
          padding: 12,
        ),
        title: isAr ? 'أحكام التجويد' : 'Tajweed Rules',
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 12),

            // ── Toolbar: Select All Checkbox + Counter ──
            Row(
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
                            : Icons.check_box_outline_blank_rounded,
                        size: 21,
                        color: allSelected ? const Color(0xFF10B981) : c.muted,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        allSelected
                            ? (isAr ? 'إلغاء تحديد الكل' : 'Deselect All')
                            : (isAr ? 'تحديد الكل' : 'Select All'),
                        style: TextStyle(
                          fontFamily: 'cairo',
                          color: c.text,
                          fontSize: 13,
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
                    fontFamily: 'cairo',
                    color: c.muted,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),

            const SizedBox(height: 8),

            // ── Single Column Rules Container ──
            Container(
              decoration: BoxDecoration(
                color: isDark
                    ? Colors.white.withValues(alpha: 0.03)
                    : Colors.black.withValues(alpha: 0.02),
                borderRadius: BorderRadius.circular(DialogTokens.cardRadius),
                border: Border.all(
                  color: isDark
                      ? Colors.white.withValues(alpha: 0.08)
                      : Colors.black.withValues(alpha: 0.06),
                  width: 1,
                ),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(DialogTokens.cardRadius),
                child: Column(
                  children: List.generate(_rules.length, (idx) {
                    final (key, titleAr, titleEn, subAr, icon) = _rules[idx];
                    final isSel = _isChecked(key);

                    return Material(
                      color: Colors.transparent,
                      child: InkWell(
                        onTap: () => _toggle(key),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 10,
                          ),
                          decoration: BoxDecoration(
                            border: idx < _rules.length - 1
                                ? Border(
                                    bottom: BorderSide(
                                      color: isDark
                                          ? Colors.white.withValues(alpha: 0.05)
                                          : Colors.black.withValues(alpha: 0.04),
                                      width: 0.6,
                                    ),
                                  )
                                : null,
                          ),
                          child: Row(
                            children: [
                              Icon(
                                isSel
                                    ? Icons.check_box_rounded
                                    : Icons.check_box_outline_blank_rounded,
                                size: 20,
                                color: isSel
                                    ? const Color(0xFF10B981)
                                    : c.muted,
                              ),
                              const SizedBox(width: 12),
                              Container(
                                width: 32,
                                height: 32,
                                decoration: BoxDecoration(
                                  color: (isSel
                                          ? const Color(0xFF10B981)
                                          : c.muted)
                                      .withValues(alpha: isDark ? 0.14 : 0.08),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Icon(
                                  icon,
                                  size: 17,
                                  color: isSel
                                      ? const Color(0xFF10B981)
                                      : c.muted,
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(
                                      isAr ? titleAr : titleEn,
                                      style: TextStyle(
                                        color: c.text,
                                        fontSize: 14,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                    const SizedBox(height: 1.5),
                                    Text(
                                      subAr,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        color: c.textSecondary
                                            .withValues(alpha: 0.8),
                                        fontSize: 11,
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
                  }),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

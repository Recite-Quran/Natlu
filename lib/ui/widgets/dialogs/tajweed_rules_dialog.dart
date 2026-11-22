import 'package:flutter/material.dart';
import '../../../core/app_state.dart';
import '../../../core/highlighting_controller.dart';
import 'dialog_base.dart';

// ══════════════════════════════════════════════════════════════════════════════
// TAJWEED VERIFICATION RULES MODAL DIALOG
// ══════════════════════════════════════════════════════════════════════════════

class _TajweedRuleItem {
  final String titleAr;
  final String titleEn;
  final String subAr;
  final String subEn;
  final IconData icon;
  final bool Function(TajweedConfig) getter;
  final TajweedConfig Function(TajweedConfig, bool) setter;

  const _TajweedRuleItem(
    this.titleAr,
    this.titleEn,
    this.subAr,
    this.subEn,
    this.icon,
    this.getter,
    this.setter,
  );
}

const List<_TajweedRuleItem> _kRules = [
  _TajweedRuleItem(
    'المدود',
    'Madd (Elongations)',
    'طبيعي، متصل، منفصل، عارض، لازم، لين',
    'Normal, Monfasel, Mottasel, Aared, Lazem, Leen',
    Icons.linear_scale_rounded,
    _getMadd,
    _setMadd,
  ),
  _TajweedRuleItem(
    'التشكيل والحركات',
    'Tashkeel (Vowel Diacritics)',
    'الفتحة والكسرة والضمة على الحروف وأواخر الكلمات',
    'Short vowels (Fathah, Kasrah, Dammah)',
    Icons.format_size_rounded,
    _getTashkeel,
    _setTashkeel,
  ),
  _TajweedRuleItem(
    'الغنة',
    'Ghunnah (Nasalization)',
    'زمن الغنة للنون والميم المشددتين والإدغام',
    'Nasal holding for doubled Noon & Meem',
    Icons.graphic_eq_rounded,
    _getGhunnah,
    _setGhunnah,
  ),
  _TajweedRuleItem(
    'الشدة',
    'Shaddah (Gemination)',
    'النبر والضغط الصوتي على الحروف المشددة',
    'Consonant doubling and acoustic closure',
    Icons.flash_on_rounded,
    _getShaddah,
    _setShaddah,
  ),
  _TajweedRuleItem(
    'القلقلة',
    'Qalqalah (Echo / Burst)',
    'نبر واضطراب مخرج حروف (ق، ط، ب، ج، د)',
    'Acoustic release burst for Qalqalah letters',
    Icons.waves_rounded,
    _getQalqalah,
    _setQalqalah,
  ),
  _TajweedRuleItem(
    'مخارج وإبدال الحروف',
    'Makharij & Letter Swaps',
    'تنبيه إبدال الحروف المتقاربة (ص/س، ض/د، ذ/ز)',
    'Flagging letter substitutions and close Makharij',
    Icons.spellcheck_rounded,
    _getLetterSwap,
    _setLetterSwap,
  ),
];

bool _getMadd(TajweedConfig c) => c.checkMadd;
TajweedConfig _setMadd(TajweedConfig c, bool v) => c.copyWith(checkMadd: v);
bool _getTashkeel(TajweedConfig c) => c.checkTashkeel;
TajweedConfig _setTashkeel(TajweedConfig c, bool v) => c.copyWith(checkTashkeel: v);
bool _getGhunnah(TajweedConfig c) => c.checkGhunnah;
TajweedConfig _setGhunnah(TajweedConfig c, bool v) => c.copyWith(checkGhunnah: v);
bool _getShaddah(TajweedConfig c) => c.checkShaddah;
TajweedConfig _setShaddah(TajweedConfig c, bool v) => c.copyWith(checkShaddah: v);
bool _getQalqalah(TajweedConfig c) => c.checkQalqalah;
TajweedConfig _setQalqalah(TajweedConfig c, bool v) => c.copyWith(checkQalqalah: v);
bool _getLetterSwap(TajweedConfig c) => c.checkLetterSwap;
TajweedConfig _setLetterSwap(TajweedConfig c, bool v) => c.copyWith(checkLetterSwap: v);

/// Modal dialog for granular Tajweed rule verification toggles.
///
/// Built on [AppDialog] and [DialogTokens] for 100% theme consistency with
/// [AudioDownloadDialog] and other application dialogs.
class TajweedRulesDialog extends StatefulWidget {
  final HighlightingController? controller;

  const TajweedRulesDialog({super.key, this.controller});

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

  @override
  void initState() {
    super.initState();
    _config = AppState.instance.tajweedConfig;
  }

  int get _selectedCount =>
      _kRules.where((r) => r.getter(_config)).length;

  bool get _allSelected => _selectedCount == _kRules.length;

  void _applyConfig(TajweedConfig newConfig) {
    setState(() => _config = newConfig);
    final app = AppState.instance;
    if (newConfig.isAllDisabled) {
      app.setMode(AppMode.wordChecker);
      widget.controller?.setTajweedMode(false);
    } else if (app.currentMode != AppMode.tajweed) {
      app.setMode(AppMode.tajweed);
      widget.controller?.setTajweedMode(true);
    }
    app.setTajweedConfig(newConfig, widget.controller);
  }

  void _toggleAll() {
    _applyConfig(
      _allSelected ? const TajweedConfig.none() : const TajweedConfig.all(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final app = AppState.instance;
    final c = app.colors;
    final isAr = app.isArabic;
    final isDark = app.isDarkMode;

    final allSelected = _allSelected;
    final selectedCount = _selectedCount;

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
        subtitle: isAr
            ? 'التحقق الصوتي من أحكام التلاوة ومخارج الحروف'
            : 'Acoustic verification of Tajweed rules and letter points',
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 12),

            // ── Toolbar: Select All Checkbox + Counter (same as AudioDownloadDialog) ──
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
                    fontFamily: isAr ? 'cairo' : null,
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
                  children: List.generate(_kRules.length, (idx) {
                    final item = _kRules[idx];
                    final isSel = item.getter(_config);

                    return Material(
                      color: Colors.transparent,
                      child: InkWell(
                        onTap: () => _applyConfig(item.setter(_config, !isSel)),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 10,
                          ),
                          decoration: BoxDecoration(
                            border: idx < _kRules.length - 1
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
                                  item.icon,
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
                                      isAr ? item.titleAr : item.titleEn,
                                      style: TextStyle(
                                        color: c.text,
                                        fontSize: 14,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                    const SizedBox(height: 1.5),
                                    Text(
                                      isAr ? item.subAr : item.subEn,
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

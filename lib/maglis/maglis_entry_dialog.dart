import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/app_haptics.dart';
import '../state/app_state.dart';
import 'maglis_controller.dart';
import 'maglis_core.dart';
import 'maglis_explanation_dialog.dart';

/// Ultra-modern, tactile modal for creating or joining a Maglis session.
/// Minimal labels, crystal-clear actions, and zero UI-thread blocking.
class MaglisEntryDialog extends StatefulWidget {
  final int initialTab;
  const MaglisEntryDialog({super.key, this.initialTab = 0});

  static Future<void> show(BuildContext context, {int initialTab = 0}) {
    final isWide = MediaQuery.sizeOf(context).width > 600;
    if (isWide) {
      return showDialog(
        context: context,
        builder: (_) => Dialog(
          backgroundColor: Colors.transparent,
          insetPadding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 400),
            child: MaglisEntryDialog(initialTab: initialTab),
          ),
        ),
      );
    }
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => MaglisEntryDialog(initialTab: initialTab),
    );
  }

  @override
  State<MaglisEntryDialog> createState() => _MaglisEntryDialogState();
}

class _MaglisEntryDialogState extends State<MaglisEntryDialog> {
  late int _selectedTab;
  late final String _newCode;
  final TextEditingController _codeCtrl = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  bool _canJoin = false;

  @override
  void initState() {
    super.initState();
    _selectedTab = widget.initialTab;
    _newCode = (10000 + Random().nextInt(90000)).toString();
  }

  @override
  void dispose() {
    _codeCtrl.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _onCodeChanged(String text) {
    final normalized = normalizeArabicDigits(text.trim());
    if (normalized != text) {
      _codeCtrl.value = TextEditingValue(
        text: normalized,
        selection: TextSelection.collapsed(offset: normalized.length),
      );
    }
    final isValid = normalized.length == 5;
    if (_canJoin != isValid) {
      setState(() => _canJoin = isValid);
    } else {
      setState(() {});
    }
  }

  void _submitSession(String code) {
    final trimmed = normalizeArabicDigits(code.trim());
    if (trimmed.length != 5) return;

    AppHaptics.lightImpact();
    Navigator.of(context).pop();

    final app = AppState.instance;
    final codeAr = formatMaglisCode(trimmed, isArabic: true);
    final codeEn = formatMaglisCode(trimmed, isArabic: false);

    app.showBanner(AppBannerInfo(
      id: 'maglis_connecting',
      messageAr: 'جاري الاتصال بالمجلس \u202A$codeAr\u202C...',
      messageEn: 'Connecting to Maglis $codeEn...',
      icon: Icons.wifi_calling_3_rounded,
      customDuration: const Duration(seconds: 2),
    ));

    MaglisController.instance
        .startSession(
      code: trimmed,
      isHost: _selectedTab == 1,
      page: app.currentMushafPage.value,
      surah: app.lastSurah,
      ayah: app.lastAyah,
    )
        .then((success) {
      if (success) {
        app.showBanner(AppBannerInfo(
          id: 'maglis_joined',
          messageAr: 'تم الاتصال بالمجلس \u202A$codeAr\u202C • المحادثة مفتوحة للجميع • اضغط الميكروفون للتلاوة',
          messageEn: 'Connected to Maglis $codeEn • Voice call active for all • Tap mic to recite',
          icon: Icons.groups_rounded,
          customDuration: const Duration(seconds: 4),
        ));
      } else {
        app.showBanner(AppBannerInfo(
          id: 'maglis_error',
          messageAr: 'تعذر الاتصال بالمجلس. تحقق من إذن الميكروفون والاتصال.',
          messageEn: 'Could not connect. Check mic permissions and network.',
          icon: Icons.error_outline_rounded,
          customDuration: const Duration(seconds: 4),
        ));
      }
    }).catchError((e) {
      app.showBanner(AppBannerInfo(
        id: 'maglis_error',
        messageAr: 'تعذر الاتصال بالمجلس. تحقق من إذن الميكروفون والاتصال.',
        messageEn: 'Could not connect. Check mic permissions and network.',
        icon: Icons.error_outline_rounded,
        customDuration: const Duration(seconds: 4),
      ));
    });
  }

  Future<void> _pasteFromClipboard() async {
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final text = data?.text?.trim() ?? '';
      final normalized = normalizeArabicDigits(text);
      final match = RegExp(r'\d{5}').firstMatch(normalized);
      if (match != null) {
        _codeCtrl.text = match.group(0)!;
        _onCodeChanged(_codeCtrl.text);
        AppHaptics.lightImpact();
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final app = AppState.instance;
    final bool isDark = app.isDarkMode;
    final bool isAr = app.isArabic;
    final c = app.colors;
    final isWide = MediaQuery.sizeOf(context).width > 600;

    final Color surfaceColor = isDark ? const Color(0xFF131726) : Colors.white;
    final Color borderColor = isDark
        ? Colors.white.withValues(alpha: 0.12)
        : Colors.black.withValues(alpha: 0.08);

    return RepaintBoundary(
      child: Directionality(
        textDirection: isAr ? TextDirection.rtl : TextDirection.ltr,
        child: Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.viewInsetsOf(context).bottom,
          ),
          child: Container(
            decoration: BoxDecoration(
              color: surfaceColor,
              borderRadius: isWide
                  ? BorderRadius.circular(24)
                  : const BorderRadius.vertical(top: Radius.circular(24)),
              border: Border.all(color: borderColor),
            ),
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 22),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (!isWide)
                  Center(
                    child: Container(
                      width: 36,
                      height: 4,
                      margin: const EdgeInsets.only(bottom: 14),
                      decoration: BoxDecoration(
                        color: isDark ? Colors.white24 : Colors.black12,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),

                // 1. Clean Header
                Row(
                  children: [
                    Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: const Color(0xFF10B981).withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Icon(Icons.groups_rounded,
                          color: Color(0xFF10B981), size: 20),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            isAr ? 'مجلس التلاوة' : 'Maglis Circle',
                            style: TextStyle(
                              color: c.text,
                              fontWeight: FontWeight.bold,
                              fontSize: 15.5,
                            ),
                          ),
                          Text(
                            isAr
                                ? 'حلقة تلاوة وتسميع مباشرة'
                                : 'Live Quran study circle',
                            style: TextStyle(
                              color: c.muted,
                              fontSize: 11.5,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: isAr ? 'كيف يعمل المجلس؟' : 'How it works',
                      visualDensity: VisualDensity.compact,
                      onPressed: () {
                        AppHaptics.lightImpact();
                        MaglisExplanationDialog.show(context);
                      },
                      icon: Icon(Icons.help_outline_rounded, color: c.muted, size: 20),
                    ),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      onPressed: () => Navigator.of(context).pop(),
                      icon: Icon(Icons.close_rounded, color: c.muted, size: 20),
                    ),
                  ],
                ),
                const SizedBox(height: 16),

                // 2. Modern 44dp Segmented Tab Picker
                Container(
                  height: 44,
                  padding: const EdgeInsets.all(3),
                  decoration: BoxDecoration(
                    color: isDark
                        ? Colors.white.withValues(alpha: 0.05)
                        : Colors.black.withValues(alpha: 0.04),
                    borderRadius: BorderRadius.circular(13),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: _tabButton(
                          title: isAr ? 'انضمام لمجلس' : 'Join Circle',
                          icon: Icons.login_rounded,
                          isSelected: _selectedTab == 0,
                          isDark: isDark,
                          c: c,
                          onTap: () {
                            if (_selectedTab != 0) {
                              AppHaptics.selectionClick();
                              setState(() => _selectedTab = 0);
                            }
                          },
                        ),
                      ),
                      Expanded(
                        child: _tabButton(
                          title: isAr ? 'إنشاء مجلس' : 'Create Room',
                          icon: Icons.add_rounded,
                          isSelected: _selectedTab == 1,
                          isDark: isDark,
                          c: c,
                          onTap: () {
                            if (_selectedTab != 1) {
                              AppHaptics.selectionClick();
                              setState(() => _selectedTab = 1);
                            }
                          },
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 18),

                // 3. Tab Body (Fixed 180dp height — ZERO height jumping when switching tabs)
                SizedBox(
                  height: 180,
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 180),
                    child: _selectedTab == 0
                        ? _buildModernJoinBody(isDark, isAr, c, borderColor)
                        : _buildModernCreateBody(isDark, isAr, c, borderColor),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _tabButton({
    required String title,
    required IconData icon,
    required bool isSelected,
    required bool isDark,
    required dynamic c,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        decoration: BoxDecoration(
          color: isSelected
              ? (isDark ? const Color(0xFF22293F) : Colors.white)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          boxShadow: isSelected
              ? [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: isDark ? 0.30 : 0.06),
                    blurRadius: 4,
                    offset: const Offset(0, 1),
                  ),
                ]
              : null,
        ),
        alignment: Alignment.center,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              size: 16,
              color: isSelected ? const Color(0xFF10B981) : c.muted,
            ),
            const SizedBox(width: 6),
            Text(
              title,
              style: TextStyle(
                fontSize: 13,
                fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                color: isSelected ? c.text : c.muted,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Modern, intuitive Join UI with 5 digit slots and instant paste
  Widget _buildModernJoinBody(
      bool isDark, bool isAr, dynamic c, Color borderColor) {
    final text = _codeCtrl.text.trim();

    return SizedBox(
      height: 180,
      child: Column(
        key: const ValueKey('join_tab_body'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          // 5 Interactive Digit Slots — strictly LTR so first digit is always on the left
          GestureDetector(
            onTap: () => _focusNode.requestFocus(),
            behavior: HitTestBehavior.opaque,
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 8),
              decoration: BoxDecoration(
                color: isDark
                    ? Colors.white.withValues(alpha: 0.03)
                    : Colors.black.withValues(alpha: 0.02),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: _canJoin
                      ? const Color(0xFF10B981).withValues(alpha: 0.40)
                      : borderColor,
                ),
              ),
              child: Directionality(
                textDirection: TextDirection.ltr,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: List.generate(5, (index) {
                    final hasChar = index < text.length;
                    final isCurrent = index == text.length;
                    final char = hasChar
                        ? formatMaglisCode(text[index], isArabic: isAr)
                        : '•';

                    return Container(
                      width: 44,
                      height: 48,
                      margin: const EdgeInsets.symmetric(horizontal: 4),
                      decoration: BoxDecoration(
                        color: isDark
                            ? (hasChar ? Colors.white12 : Colors.white.withValues(alpha: 0.04))
                            : (hasChar ? const Color(0xFFF1F5F9) : Colors.black.withValues(alpha: 0.03)),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: isCurrent
                              ? const Color(0xFF10B981)
                              : (hasChar
                                  ? const Color(0xFF10B981).withValues(alpha: 0.5)
                                  : borderColor),
                          width: isCurrent ? 1.8 : 1.0,
                        ),
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        char,
                        style: TextStyle(
                          fontFamily: 'cairo',
                          color: hasChar
                              ? (isDark ? Colors.white : const Color(0xFF0F172A))
                              : c.muted.withValues(alpha: 0.35),
                          fontSize: hasChar ? 21 : 18,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    );
                  }),
                ),
              ),
            ),
          ),

          // Hidden input field supporting both Western digits and Arabic digits
          Offstage(
            offstage: true,
            child: TextField(
              focusNode: _focusNode,
              controller: _codeCtrl,
              keyboardType: TextInputType.number,
              onChanged: _onCodeChanged,
              onSubmitted: _canJoin ? (v) => _submitSession(v) : null,
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[\d\u0660-\u0669]')),
                LengthLimitingTextInputFormatter(5),
              ],
            ),
          ),

          // Quick action: Paste or Clear chip
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: _pasteFromClipboard,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: isDark ? Colors.white10 : Colors.black.withValues(alpha: 0.05),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.paste_rounded, size: 14, color: c.muted),
                      const SizedBox(width: 5),
                      Text(
                        isAr ? 'لصق الرمز من الحافظة' : 'Paste from clipboard',
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                          color: c.muted,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (text.isNotEmpty) ...[
                const SizedBox(width: 8),
                InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: () {
                    _codeCtrl.clear();
                    _onCodeChanged('');
                    AppHaptics.selectionClick();
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: isDark ? Colors.white10 : Colors.black.withValues(alpha: 0.05),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.clear_rounded, size: 14, color: c.muted),
                        const SizedBox(width: 4),
                        Text(
                          isAr ? 'مسح' : 'Clear',
                          style: TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w600,
                            color: c.muted,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ],
          ),

          // Submit Button
          SizedBox(
            height: 46,
            child: FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF10B981),
                foregroundColor: Colors.white,
                disabledBackgroundColor: isDark
                    ? Colors.white.withValues(alpha: 0.08)
                    : Colors.black.withValues(alpha: 0.06),
                disabledForegroundColor: c.muted,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              onPressed: _canJoin ? () => _submitSession(_codeCtrl.text) : null,
              icon: const Icon(Icons.login_rounded, size: 19),
              label: Text(
                isAr ? 'انضمام للمجلس' : 'Join Maglis',
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Modern, intuitive Create UI with glowing room code card and one-tap copy
  Widget _buildModernCreateBody(
      bool isDark, bool isAr, dynamic c, Color borderColor) {
    final displayCode = formatMaglisCode(_newCode, isArabic: isAr);

    return SizedBox(
      height: 180,
      child: Column(
        key: const ValueKey('create_tab_body'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          // Hero Room Code Card
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: const Color(0xFF10B981).withValues(alpha: isDark ? 0.08 : 0.06),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: const Color(0xFF10B981).withValues(alpha: 0.25),
              ),
            ),
            child: Column(
              children: [
                Text(
                  isAr ? 'رمز مجلسك المخصص للمشاركة' : 'Your 5-Digit Room Code',
                  style: TextStyle(
                    color: c.muted,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 5),
                InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: () {
                    Clipboard.setData(ClipboardData(text: _newCode));
                    AppHaptics.lightImpact();
                    AppState.instance.showBanner(AppBannerInfo(
                      id: 'maglis_code_copied',
                      messageAr: 'تم نسخ رمز المجلس: \u202A${formatMaglisCode(_newCode, isArabic: true)}\u202C',
                      messageEn: 'Maglis code copied: $_newCode',
                      icon: Icons.copy_rounded,
                      customDuration: const Duration(seconds: 2),
                    ));
                  },
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Directionality(
                          textDirection: TextDirection.ltr,
                          child: Text(
                            displayCode.split('').join('  '),
                            style: const TextStyle(
                              fontFamily: 'cairo',
                              letterSpacing: 2.0,
                              fontWeight: FontWeight.w900,
                              fontSize: 25,
                              color: Color(0xFF10B981),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        const Icon(Icons.copy_rounded, color: Color(0xFF10B981), size: 18),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  isAr
                      ? 'شارك هذا الرمز مع من تريد انضمامه للمجلس'
                      : 'Share this code with whoever you want to join',
                  style: TextStyle(
                    color: c.muted,
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),

          // Start Room Button
          SizedBox(
            height: 46,
            child: FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF10B981),
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              onPressed: () => _submitSession(_newCode),
              icon: const Icon(Icons.play_arrow_rounded, size: 21),
              label: Text(
                isAr ? 'بدء المجلس الآن' : 'Start Room Now',
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

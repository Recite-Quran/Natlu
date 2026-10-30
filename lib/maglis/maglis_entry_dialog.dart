import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/app_haptics.dart';
import '../state/app_state.dart';
import 'maglis_controller.dart';

/// Ultra-lightweight, high-performance modal for creating or joining a Maglis session.
/// Operates with zero UI-thread blocking: dismisses immediately and connects asynchronously.
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
            constraints: const BoxConstraints(maxWidth: 380),
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
    super.dispose();
  }

  void _onCodeChanged(String text) {
    final isValid = text.trim().length == 5;
    if (_canJoin != isValid) {
      setState(() => _canJoin = isValid);
    }
  }

  void _submitSession(String code) {
    final trimmed = code.trim();
    if (trimmed.length != 5) return;

    AppHaptics.lightImpact();
    // 1. Immediately dismiss modal so animations are fluid at 60/120fps with zero frame drop
    Navigator.of(context).pop();

    final app = AppState.instance;

    // 2. Immediate feedback banner
    app.showBanner(AppBannerInfo(
      id: 'maglis_connecting',
      messageAr: 'جاري الاتصال بالمجلس $trimmed...',
      messageEn: 'Connecting to Maglis $trimmed...',
      icon: Icons.wifi_calling_3_rounded,
      customDuration: const Duration(seconds: 2),
    ));

    // 3. Connect asynchronously in background without blocking UI
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
          messageAr: 'تم الانضمام إلى المجلس $trimmed • اضغط على الميكروفون للتلاوة',
          messageEn: 'Joined Maglis $trimmed • Tap mic to recite',
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
    });
  }

  Future<void> _pasteFromClipboard() async {
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final text = data?.text?.trim() ?? '';
      final match = RegExp(r'\d{5}').firstMatch(text);
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
        ? Colors.white.withValues(alpha: 0.10)
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
                  ? BorderRadius.circular(20)
                  : const BorderRadius.vertical(top: Radius.circular(20)),
              border: Border.all(color: borderColor),
            ),
            padding: const EdgeInsets.fromLTRB(18, 12, 18, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (!isWide)
                  Center(
                    child: Container(
                      width: 32,
                      height: 4,
                      margin: const EdgeInsets.only(bottom: 12),
                      decoration: BoxDecoration(
                        color: isDark ? Colors.white24 : Colors.black12,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),

                // Header
                Row(
                  children: [
                    Container(
                      width: 34,
                      height: 34,
                      decoration: BoxDecoration(
                        color: const Color(0xFF10B981).withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(9),
                      ),
                      child: const Icon(Icons.groups_rounded,
                          color: Color(0xFF10B981), size: 19),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            isAr ? 'مجلس التلاوة التشاركي' : 'Live Maglis P2P',
                            style: TextStyle(
                              color: c.text,
                              fontWeight: FontWeight.w700,
                              fontSize: 14,
                            ),
                          ),
                          Text(
                            isAr
                                ? 'صوت مفتوح للجميع وتزامن شاشة للقارئ فقط'
                                : 'Open mic for all, mushaf sync for active reciter',
                            style: TextStyle(color: c.muted, fontSize: 11),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      onPressed: () => Navigator.of(context).pop(),
                      icon: Icon(Icons.close_rounded, color: c.muted, size: 20),
                    ),
                  ],
                ),
                const SizedBox(height: 12),

                // Segmented Tab Picker
                Container(
                  height: 36,
                  padding: const EdgeInsets.all(2),
                  decoration: BoxDecoration(
                    color: isDark
                        ? Colors.white.withValues(alpha: 0.05)
                        : Colors.black.withValues(alpha: 0.04),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: _tabButton(
                          title: isAr ? 'انضمام' : 'Join',
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
                const SizedBox(height: 14),

                // Tab Body
                if (_selectedTab == 0)
                  _buildJoinBody(isDark, isAr, c, borderColor)
                else
                  _buildCreateBody(isDark, isAr, c, borderColor),
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
      child: Container(
        decoration: BoxDecoration(
          color: isSelected
              ? (isDark ? const Color(0xFF22293F) : Colors.white)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        alignment: Alignment.center,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              size: 15,
              color: isSelected ? const Color(0xFF10B981) : c.muted,
            ),
            const SizedBox(width: 5),
            Text(
              title,
              style: TextStyle(
                fontSize: 12,
                fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                color: isSelected ? c.text : c.muted,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildJoinBody(
      bool isDark, bool isAr, dynamic c, Color borderColor) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        TextField(
          controller: _codeCtrl,
          keyboardType: TextInputType.number,
          autofocus: false,
          onChanged: _onCodeChanged,
          onSubmitted: _canJoin ? (v) => _submitSession(v) : null,
          inputFormatters: [
            FilteringTextInputFormatter.digitsOnly,
            LengthLimitingTextInputFormatter(5),
          ],
          style: TextStyle(
            color: c.text,
            letterSpacing: 8.0,
            fontSize: 22,
            fontWeight: FontWeight.w800,
          ),
          textAlign: TextAlign.center,
          decoration: InputDecoration(
            counterText: '',
            hintText: '• • • • •',
            hintStyle: TextStyle(
              color: c.muted.withValues(alpha: 0.35),
              letterSpacing: 8.0,
              fontSize: 20,
            ),
            filled: true,
            fillColor: isDark
                ? Colors.white.withValues(alpha: 0.04)
                : Colors.black.withValues(alpha: 0.03),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            prefixIcon: IconButton(
              tooltip: isAr ? 'لصق' : 'Paste',
              icon: const Icon(Icons.paste_rounded, size: 18),
              color: c.muted,
              onPressed: _pasteFromClipboard,
            ),
            suffixIcon: _codeCtrl.text.isNotEmpty
                ? IconButton(
                    icon: const Icon(Icons.clear_rounded, size: 16),
                    color: c.muted,
                    onPressed: () {
                      _codeCtrl.clear();
                      _onCodeChanged('');
                      AppHaptics.selectionClick();
                    },
                  )
                : null,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: borderColor),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: borderColor),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: Color(0xFF10B981), width: 1.5),
            ),
          ),
        ),
        const SizedBox(height: 12),
        FilledButton.icon(
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xFF10B981),
            foregroundColor: Colors.white,
            disabledBackgroundColor: isDark
                ? Colors.white.withValues(alpha: 0.07)
                : Colors.black.withValues(alpha: 0.05),
            disabledForegroundColor: c.muted,
            padding: const EdgeInsets.symmetric(vertical: 11),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
          ),
          onPressed: _canJoin ? () => _submitSession(_codeCtrl.text) : null,
          icon: const Icon(Icons.login_rounded, size: 18),
          label: Text(
            isAr ? 'انضمام إلى المجلس' : 'Join Maglis',
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
          ),
        ),
      ],
    );
  }

  Widget _buildCreateBody(
      bool isDark, bool isAr, dynamic c, Color borderColor) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: isDark
                ? Colors.white.withValues(alpha: 0.04)
                : Colors.black.withValues(alpha: 0.03),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: borderColor),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      isAr ? 'رمز المجلس الجديد' : 'New Maglis Code',
                      style: TextStyle(
                        color: c.muted,
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _newCode,
                      style: const TextStyle(
                        letterSpacing: 4.0,
                        fontWeight: FontWeight.w800,
                        fontSize: 21,
                        color: Color(0xFF10B981),
                      ),
                    ),
                  ],
                ),
              ),
              IconButton.filledTonal(
                tooltip: isAr ? 'نسخ الرمز' : 'Copy Code',
                visualDensity: VisualDensity.compact,
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: _newCode));
                  AppHaptics.lightImpact();
                  AppState.instance.showBanner(AppBannerInfo(
                    id: 'maglis_code_copied',
                    messageAr: 'تم نسخ رمز المجلس: $_newCode',
                    messageEn: 'Maglis code copied: $_newCode',
                    icon: Icons.copy_rounded,
                    customDuration: const Duration(seconds: 2),
                  ));
                },
                icon: const Icon(Icons.copy_rounded, size: 17),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        FilledButton.icon(
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xFF10B981),
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(vertical: 11),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
          ),
          onPressed: () => _submitSession(_newCode),
          icon: const Icon(Icons.play_arrow_rounded, size: 19),
          label: Text(
            isAr ? 'بدء هذا المجلس' : 'Start This Maglis',
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
          ),
        ),
      ],
    );
  }
}

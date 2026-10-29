import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/app_haptics.dart';
import '../state/app_state.dart';
import 'maglis_controller.dart';

class MaglisEntryDialog extends StatefulWidget {
  const MaglisEntryDialog({super.key});

  static Future<void> show(BuildContext context) {
    final isWide = MediaQuery.sizeOf(context).width > 600;
    if (isWide) {
      return showDialog(
        context: context,
        builder: (_) => Dialog(
          backgroundColor: Colors.transparent,
          insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: const MaglisEntryDialog(),
          ),
        ),
      );
    }
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const MaglisEntryDialog(),
    );
  }

  @override
  State<MaglisEntryDialog> createState() => _MaglisEntryDialogState();
}

class _MaglisEntryDialogState extends State<MaglisEntryDialog> {
  late final String _newCode;
  final TextEditingController _codeCtrl = TextEditingController();
  bool _isBusy = false;
  String? _errorMsg;

  @override
  void initState() {
    super.initState();
    _newCode = (100000 + Random().nextInt(900000)).toString();
  }

  @override
  void dispose() {
    _codeCtrl.dispose();
    super.dispose();
  }

  Future<void> _startSession(String code) async {
    setState(() {
      _isBusy = true;
      _errorMsg = null;
    });

    final app = AppState.instance;
    final page = app.currentMushafPage.value;
    final surah = app.lastSurah;
    final ayah = app.lastAyah;

    final success = await MaglisController.instance.startSession(
      code: code,
      page: page,
      surah: surah,
      ayah: ayah,
    );

    if (!mounted) return;
    setState(() => _isBusy = false);

    if (success) {
      Navigator.of(context).pop();
      app.showBanner(AppBannerInfo(
        id: 'maglis_joined',
        messageAr: 'تم الانضمام إلى المجلس $code • اضغط على الميكروفون للتلاوة',
        messageEn: 'Joined Maglis $code • Tap mic to recite',
        icon: Icons.groups_rounded,
        customDuration: const Duration(seconds: 4),
      ));
    } else {
      setState(() {
        _errorMsg = app.isArabic
            ? 'تعذر بدء المجلس. يرجى التأكد من إذن الميكروفون والاتصال.'
            : 'Could not connect. Please check mic permissions and connection.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = AppState.instance;
    final bool isDark = app.isDarkMode;
    final bool isAr = app.isArabic;
    final c = app.colors;

    final Color surfaceColor = isDark ? const Color(0xFF131726) : Colors.white;
    final Color borderColor = isDark
        ? Colors.white.withValues(alpha: 0.12)
        : Colors.black.withValues(alpha: 0.08);

    return Directionality(
      textDirection: isAr ? TextDirection.rtl : TextDirection.ltr,
      child: Container(
        padding: EdgeInsets.only(
          left: 20,
          right: 20,
          top: 20,
          bottom: MediaQuery.viewInsetsOf(context).bottom + 24,
        ),
        decoration: BoxDecoration(
          color: surfaceColor,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          border: Border.all(color: borderColor, width: 1),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: isDark ? 0.5 : 0.15),
              blurRadius: 28,
              offset: const Offset(0, -4),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Drag Handle Pill
            Center(
              child: Container(
                width: 38,
                height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: isDark ? Colors.white24 : Colors.black12,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),

            // Header Row
            Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: const Color(0xFF10B981).withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(Icons.groups_rounded,
                      color: Color(0xFF10B981), size: 22),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        isAr ? 'مجلس التلاوة التشاركي' : 'Live Maglis P2P',
                        style: TextStyle(
                          color: c.text,
                          fontWeight: FontWeight.w700,
                          fontSize: 16,
                        ),
                      ),
                      Text(
                        isAr
                            ? 'تلاوة ومتابعة مباشرة عبر P2P بدون أي خادم'
                            : 'Direct P2P audio & vector mushaf sync',
                        style: TextStyle(
                          color: c.muted,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: Icon(Icons.close_rounded, color: c.muted, size: 20),
                ),
              ],
            ),
            const SizedBox(height: 20),

            // Section 1: Create New Maglis
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: isDark
                    ? Colors.white.withValues(alpha: 0.04)
                    : Colors.black.withValues(alpha: 0.03),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: borderColor),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    isAr ? 'رمز المجلس الجديد للمشاركة' : 'New Maglis Invite Code',
                    style: TextStyle(
                      color: c.muted,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 10),
                          decoration: BoxDecoration(
                            color: isDark
                                ? const Color(0xFF1C2237)
                                : const Color(0xFFF1F5F9),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            _newCode,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              letterSpacing: 4.0,
                              fontWeight: FontWeight.w800,
                              fontSize: 20,
                              color: Color(0xFF10B981),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      IconButton.filledTonal(
                        onPressed: () {
                          Clipboard.setData(ClipboardData(text: _newCode));
                          AppHaptics.lightImpact();
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(
                                isAr
                                    ? 'تم نسخ رمز المجلس: $_newCode'
                                    : 'Maglis code copied: $_newCode',
                              ),
                              duration: const Duration(seconds: 2),
                            ),
                          );
                        },
                        icon: const Icon(Icons.copy_rounded, size: 20),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF10B981),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    onPressed: _isBusy ? null : () => _startSession(_newCode),
                    icon: _isBusy
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white),
                          )
                        : const Icon(Icons.play_arrow_rounded),
                    label: Text(
                      isAr ? 'بدء هذا المجلس' : 'Start This Maglis',
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 18),

            // Divider OR
            Row(
              children: [
                Expanded(child: Divider(color: borderColor)),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Text(
                    isAr ? 'أو انضم لمجلس' : 'OR Join Existing',
                    style: TextStyle(color: c.muted, fontSize: 12),
                  ),
                ),
                Expanded(child: Divider(color: borderColor)),
              ],
            ),

            const SizedBox(height: 16),

            // Section 2: Join Existing Code
            TextField(
              controller: _codeCtrl,
              keyboardType: TextInputType.number,
              maxLength: 6,
              style: TextStyle(
                color: c.text,
                letterSpacing: 4.0,
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
              textAlign: TextAlign.center,
              decoration: InputDecoration(
                counterText: '',
                hintText: isAr ? 'أدخل الرمز المكون من 6 أرقام' : 'Enter 6-digit code',
                hintStyle: TextStyle(
                  color: c.muted.withValues(alpha: 0.6),
                  letterSpacing: 0,
                  fontSize: 13,
                ),
                filled: true,
                fillColor: isDark
                    ? Colors.white.withValues(alpha: 0.05)
                    : Colors.black.withValues(alpha: 0.03),
                contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16, vertical: 12),
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
                  borderSide: const BorderSide(color: Color(0xFF10B981)),
                ),
              ),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                foregroundColor: c.text,
                side: BorderSide(
                    color: isDark ? Colors.white24 : Colors.black26),
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              onPressed: _isBusy
                  ? null
                  : () {
                      final input = _codeCtrl.text.trim();
                      if (input.length == 6) {
                        _startSession(input);
                      }
                    },
              icon: const Icon(Icons.login_rounded, size: 18),
              label: Text(
                isAr ? 'انضمام إلى المجلس' : 'Join Maglis',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),

            if (_errorMsg != null)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(
                  _errorMsg!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Color(0xFFF43F5E), fontSize: 12),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

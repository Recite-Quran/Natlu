import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/app_haptics.dart';
import '../state/app_state.dart';
import 'maglis_controller.dart';

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
          insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
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
      useSafeArea: true,
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
  bool _isBusy = false;
  String? _errorMsg;
  String? _clipboardCode;

  @override
  void initState() {
    super.initState();
    _selectedTab = widget.initialTab;
    _newCode = (100000 + Random().nextInt(900000)).toString();
    _checkClipboard();
    _codeCtrl.addListener(() {
      if (mounted) setState(() {});
    });
  }

  Future<void> _checkClipboard() async {
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final text = data?.text?.trim() ?? '';
      if (RegExp(r'^\d{6}$').hasMatch(text) && mounted) {
        setState(() => _clipboardCode = text);
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    _codeCtrl.dispose();
    super.dispose();
  }

  Future<void> _startSession(String code) async {
    final trimmed = code.trim();
    if (trimmed.length != 6) return;

    setState(() {
      _isBusy = true;
      _errorMsg = null;
    });

    final app = AppState.instance;
    final page = app.currentMushafPage.value;
    final surah = app.lastSurah;
    final ayah = app.lastAyah;

    final success = await MaglisController.instance.startSession(
      code: trimmed,
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
        messageAr: 'تم الانضمام إلى المجلس $trimmed • اضغط على الميكروفون للتلاوة',
        messageEn: 'Joined Maglis $trimmed • Tap mic to recite',
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

  void _pasteFromClipboard() async {
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final text = data?.text?.trim() ?? '';
      final match = RegExp(r'\d{6}').firstMatch(text);
      if (match != null) {
        _codeCtrl.text = match.group(0)!;
        AppHaptics.lightImpact();
      } else if (text.isNotEmpty && RegExp(r'^\d+$').hasMatch(text)) {
        _codeCtrl.text = text.substring(0, min(6, text.length));
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

    return Directionality(
      textDirection: isAr ? TextDirection.rtl : TextDirection.ltr,
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: SingleChildScrollView(
          physics: const ClampingScrollPhysics(),
          child: Container(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
            decoration: BoxDecoration(
              color: surfaceColor,
              borderRadius: isWide
                  ? BorderRadius.circular(24)
                  : const BorderRadius.vertical(top: Radius.circular(24)),
              border: Border.all(color: borderColor, width: 1),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: isDark ? 0.35 : 0.08),
                  blurRadius: 18,
                  offset: const Offset(0, -3),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Top Pill for Mobile Drag Handle
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

                // Header Row
                Row(
                  children: [
                    Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: const Color(0xFF10B981).withValues(alpha: 0.14),
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
                            isAr ? 'مجلس التلاوة التشاركي' : 'Live Maglis P2P',
                            style: TextStyle(
                              color: c.text,
                              fontWeight: FontWeight.w700,
                              fontSize: 15,
                            ),
                          ),
                          Text(
                            isAr
                                ? 'تلاوة جماعية متزامنة ومباشرة'
                                : 'Peer-to-peer audio & live mushaf sync',
                            style: TextStyle(
                              color: c.muted,
                              fontSize: 11,
                            ),
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
                const SizedBox(height: 14),

                // Segmented Tab Selector [ Join | Create ]
                Container(
                  padding: const EdgeInsets.all(3),
                  decoration: BoxDecoration(
                    color: isDark
                        ? Colors.white.withValues(alpha: 0.05)
                        : Colors.black.withValues(alpha: 0.04),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: _buildTabButton(
                          title: isAr ? 'انضمام لمجلس' : 'Join Room',
                          icon: Icons.login_rounded,
                          isSelected: _selectedTab == 0,
                          isDark: isDark,
                          c: c,
                          onTap: () {
                            AppHaptics.selectionClick();
                            setState(() {
                              _selectedTab = 0;
                              _errorMsg = null;
                            });
                          },
                        ),
                      ),
                      Expanded(
                        child: _buildTabButton(
                          title: isAr ? 'إنشاء مجلس' : 'Create Room',
                          icon: Icons.add_rounded,
                          isSelected: _selectedTab == 1,
                          isDark: isDark,
                          c: c,
                          onTap: () {
                            AppHaptics.selectionClick();
                            setState(() {
                              _selectedTab = 1;
                              _errorMsg = null;
                            });
                          },
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),

                // Active Tab Content
                if (_selectedTab == 0)
                  _buildJoinView(isDark, isAr, c, borderColor)
                else
                  _buildCreateView(isDark, isAr, c, borderColor),

                // Error Message
                if (_errorMsg != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Text(
                      _errorMsg!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Color(0xFFF43F5E),
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTabButton({
    required String title,
    required IconData icon,
    required bool isSelected,
    required bool isDark,
    required dynamic c,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(9),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(
          color: isSelected
              ? (isDark ? const Color(0xFF22293F) : Colors.white)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(9),
          boxShadow: isSelected
              ? [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: isDark ? 0.25 : 0.05),
                    blurRadius: 4,
                    offset: const Offset(0, 1),
                  ),
                ]
              : null,
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              size: 15,
              color: isSelected ? const Color(0xFF10B981) : c.muted,
            ),
            const SizedBox(width: 6),
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

  /// Compact Join View (6-Digit input with quick paste)
  Widget _buildJoinView(
      bool isDark, bool isAr, dynamic c, Color borderColor) {
    final bool canJoin = _codeCtrl.text.trim().length == 6 && !_isBusy;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Quick clipboard suggestion pill
        if (_clipboardCode != null && _codeCtrl.text.trim() != _clipboardCode)
          InkWell(
            onTap: () {
              _codeCtrl.text = _clipboardCode!;
              AppHaptics.lightImpact();
            },
            borderRadius: BorderRadius.circular(8),
            child: Container(
              margin: const EdgeInsets.only(bottom: 10),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: const Color(0xFF10B981).withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: const Color(0xFF10B981).withValues(alpha: 0.25),
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.content_paste_go_rounded,
                      size: 14, color: Color(0xFF10B981)),
                  const SizedBox(width: 6),
                  Text(
                    isAr
                        ? 'رمز منسوخ: $_clipboardCode (اضغط للصق)'
                        : 'Clipboard code: $_clipboardCode (Tap to paste)',
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF10B981),
                    ),
                  ),
                ],
              ),
            ),
          ),

        // 6-Digit TextField
        TextField(
          controller: _codeCtrl,
          keyboardType: TextInputType.number,
          inputFormatters: [
            FilteringTextInputFormatter.digitsOnly,
            LengthLimitingTextInputFormatter(6),
          ],
          style: TextStyle(
            color: c.text,
            letterSpacing: 6.0,
            fontSize: 20,
            fontWeight: FontWeight.w800,
          ),
          textAlign: TextAlign.center,
          decoration: InputDecoration(
            counterText: '',
            hintText: '• • • • • •',
            hintStyle: TextStyle(
              color: c.muted.withValues(alpha: 0.4),
              letterSpacing: 6.0,
              fontSize: 18,
            ),
            filled: true,
            fillColor: isDark
                ? Colors.white.withValues(alpha: 0.04)
                : Colors.black.withValues(alpha: 0.03),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            prefixIcon: IconButton(
              tooltip: isAr ? 'لصق الرمز' : 'Paste Code',
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

        // Join Action Button
        FilledButton.icon(
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xFF10B981),
            foregroundColor: Colors.white,
            disabledBackgroundColor: isDark
                ? Colors.white.withValues(alpha: 0.08)
                : Colors.black.withValues(alpha: 0.06),
            disabledForegroundColor: c.muted,
            padding: const EdgeInsets.symmetric(vertical: 12),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
          onPressed: canJoin ? () => _startSession(_codeCtrl.text) : null,
          icon: _isBusy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white),
                )
              : const Icon(Icons.login_rounded, size: 18),
          label: Text(
            isAr ? 'انضمام إلى المجلس' : 'Join Maglis',
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
        ),
      ],
    );
  }

  /// Compact Create View (Generate & Start)
  Widget _buildCreateView(
      bool isDark, bool isAr, dynamic c, Color borderColor) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: isDark
                ? Colors.white.withValues(alpha: 0.04)
                : Colors.black.withValues(alpha: 0.03),
            borderRadius: BorderRadius.circular(14),
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
                        fontSize: 22,
                        color: Color(0xFF10B981),
                      ),
                    ),
                  ],
                ),
              ),
              IconButton.filledTonal(
                tooltip: isAr ? 'نسخ الرمز' : 'Copy Code',
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
                icon: const Icon(Icons.copy_rounded, size: 18),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),

        // Start Maglis Button
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
              : const Icon(Icons.play_arrow_rounded, size: 20),
          label: Text(
            isAr ? 'بدء هذا المجلس' : 'Start This Maglis',
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
        ),
      ],
    );
  }
}

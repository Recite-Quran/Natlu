import 'dart:async';
import 'dart:math';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../core/app_state.dart';
import '../../../core/maglis_link_service.dart';
import 'package:share_plus/share_plus.dart';
import '../../../maglis/maglis_controller.dart';
import '../../../maglis/maglis_core.dart';
import 'app_guide_dialogs.dart';
import 'dialog_base.dart';
import '../../../mushaf/mushaf_provider.dart';

/// Ultra-modern, tactile modal for creating or joining a Maglis session.
/// Minimal labels, crystal-clear actions, and zero UI-thread blocking.
class MaglisEntryDialog extends StatefulWidget {
  final int initialTab;
  final String? initialCode;
  const MaglisEntryDialog({super.key, this.initialTab = 1, this.initialCode});

  static Future<void> show(
    BuildContext context, {
    int initialTab = 1,
    String? initialCode,
  }) {
    final isWide = MediaQuery.sizeOf(context).width > 600;
    if (isWide) {
      return showDialog(
        context: context,
        builder: (_) => Dialog(
          backgroundColor: Colors.transparent,
          insetPadding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 400),
            child: MaglisEntryDialog(
              initialTab: initialTab,
              initialCode: initialCode,
            ),
          ),
        ),
      );
    }
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => MaglisEntryDialog(
        initialTab: initialTab,
        initialCode: initialCode,
      ),
    );
  }

  @override
  State<MaglisEntryDialog> createState() => _MaglisEntryDialogState();
}

class _MaglisEntryDialogState extends State<MaglisEntryDialog> {
  late int _selectedTab;
  String _newCode = '';
  final TextEditingController _codeCtrl = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  bool _canJoin = false;
  bool _isJoining = false;
  bool _isCreating = false;

  @override
  void initState() {
    super.initState();
    _selectedTab = widget.initialTab;
    _newCode = (10000 + Random().nextInt(90000)).toString();
    if (widget.initialCode != null && widget.initialCode!.isNotEmpty) {
      final normalized = normalizeArabicDigits(widget.initialCode!.trim());
      _codeCtrl.text = normalized;
      _canJoin = normalized.length == 5;
    }
    _focusNode.addListener(() {
      if (mounted) setState(() {});
    });
  }

  void _openKeyboard() {
    if (!_focusNode.hasFocus) {
      _focusNode.requestFocus();
    }
    SystemChannels.textInput.invokeMethod('TextInput.show');
  }

  @override
  void dispose() {
    _codeCtrl.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _onCodeChanged(String text) {
    final normalized = normalizeArabicDigits(text.trim());
    final isValid = normalized.length == 5;
    if (_canJoin != isValid) {
      setState(() => _canJoin = isValid);
    } else {
      setState(() {});
    }
  }

  Future<void> _submitSession(String code) async {
    final trimmed = normalizeArabicDigits(code.trim());
    if (trimmed.length != 5 || _isJoining || _isCreating) return;

    final app = AppState.instance;
    final codeAr = formatMaglisCode(trimmed, isArabic: true);
    final codeEn = formatMaglisCode(trimmed, isArabic: false);

    // 1. Mandatory Connectivity Pre-flight (noscall / livekit pattern)
    final connectivity = await Connectivity().checkConnectivity();
    final hasConnection = connectivity.isNotEmpty &&
        !connectivity.contains(ConnectivityResult.none);
    if (!hasConnection) {
      app.showBanner(AppBannerInfo(
        id: 'maglis_offline',
        messageAr: 'لا يوجد اتصال بالإنترنت. يرجى الاتصال بالشبكة للمتابعة',
        messageEn: 'No internet connection. Please connect to continue',
        icon: Icons.wifi_off_rounded,
        isWarning: true,
        customDuration: const Duration(seconds: 4),
      ));
      return;
    }

    final int effectivePage =
        MushafProvider.instance.getPageForAyah(app.lastSurah, app.lastAyah) ??
            app.currentMushafPage.value;

    if (_selectedTab == 0) {
      // ── JOINING EXISTING MAGLIS: Verify existence & capacity first! ──
      _focusNode.unfocus();
      setState(() => _isJoining = true);

      try {
        final result = await MaglisController.instance.verifyAndJoinRoom(
          code: trimmed,
          page: effectivePage,
          surah: app.lastSurah,
          ayah: app.lastAyah,
        );
        if (!mounted) return;
        setState(() => _isJoining = false);

        if (result == MaglisJoinResult.success) {
          Navigator.of(context).pop();
          app.showBanner(AppBannerInfo(
            id: 'maglis_joined',
            messageAr:
                'تم الاتصال بمجلس القرآن \u202A$codeAr\u202C • اضغط الميكروفون للتلاوة',
            messageEn: 'Joined Quran Maglis $codeEn • Tap mic to recite',
            icon: Icons.groups_rounded,
            customDuration: const Duration(seconds: 3),
          ));
        } else if (result == MaglisJoinResult.full) {
          app.showBanner(AppBannerInfo(
            id: 'maglis_full',
            messageAr:
                'عذراً، المجلس \u202A$codeAr\u202C ممتلئ (الحد الأقصى 4 أعضاء)',
            messageEn: 'Maglis $codeEn is full (maximum 4 participants)',
            icon: Icons.group_off_rounded,
            isWarning: true,
            customDuration: const Duration(seconds: 4),
          ));
        } else {
          app.showBanner(AppBannerInfo(
            id: 'maglis_not_found',
            messageAr:
                'رمز المجلس \u202A$codeAr\u202C غير موجود أو لم يبدأ بعد',
            messageEn: 'Maglis $codeEn does not exist or has not started',
            icon: Icons.search_off_rounded,
            isWarning: true,
            customDuration: const Duration(seconds: 4),
          ));
        }
      } catch (_) {
        if (mounted) setState(() => _isJoining = false);
        app.showBanner(AppBannerInfo(
          id: 'maglis_not_found',
          messageAr: 'رمز المجلس \u202A$codeAr\u202C غير موجود أو تعذر الاتصال',
          messageEn: 'Maglis $codeEn does not exist or network error',
          icon: Icons.search_off_rounded,
          isWarning: true,
          customDuration: const Duration(seconds: 4),
        ));
      }
    } else {
      // ── MAKING A NEW MAGLIS AS HOST: Verified Relay Start ──
      _focusNode.unfocus();
      setState(() => _isCreating = true);

      try {
        final success = await MaglisController.instance.startSession(
          code: trimmed,
          isHost: true,
          page: effectivePage,
          surah: app.lastSurah,
          ayah: app.lastAyah,
        );

        if (!mounted) return;
        setState(() => _isCreating = false);

        if (success) {
          Navigator.of(context).pop();
          app.showBanner(AppBannerInfo(
            id: 'maglis_created',
            messageAr:
                'تم افتتاح مجلس القرآن \u202A$codeAr\u202C • شارك الرمز مع إخوانك',
            messageEn: 'Started Quran Maglis $codeEn • Share code with peers',
            icon: Icons.meeting_room_rounded,
            customDuration: const Duration(seconds: 3),
          ));
        } else {
          app.showBanner(AppBannerInfo(
            id: 'maglis_error',
            messageAr:
                'تعذر الاتصال بخوادم المجلس. تحقق من الإنترنت وإذن الميكروفون',
            messageEn:
                'Could not connect to Maglis. Check network and mic permissions',
            icon: Icons.error_outline_rounded,
            isWarning: true,
            customDuration: const Duration(seconds: 4),
          ));
        }
      } catch (_) {
        if (mounted) setState(() => _isCreating = false);
        app.showBanner(AppBannerInfo(
          id: 'maglis_error',
          messageAr:
              'تعذر الاتصال بخوادم المجلس. تحقق من الإنترنت وإذن الميكروفون',
          messageEn:
              'Could not connect to Maglis. Check network and mic permissions',
          icon: Icons.error_outline_rounded,
          isWarning: true,
          customDuration: const Duration(seconds: 4),
        ));
      }
    }
  }

  Future<void> _pasteFromClipboard() async {
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final raw = data?.text?.trim() ?? '';
      if (raw.isEmpty) return;
      final uri = Uri.tryParse(raw);
      String? parsedCode;
      if (uri != null) {
        parsedCode = MaglisLinkService.extractRoomCode(uri);
      }
      final normalized = normalizeArabicDigits(raw);
      final digitsOnly = normalized.replaceAll(RegExp(r'\D'), '');
      final code = parsedCode ??
          (digitsOnly.length >= 5 ? digitsOnly.substring(0, 5) : null);

      if (code != null) {
        _codeCtrl.text = code;
        _onCodeChanged(code);
        AppState.instance.showBanner(AppBannerInfo(
          id: 'maglis_pasted',
          messageAr:
              'تم لصق رمز المجلس: \u202A${formatMaglisCode(code, isArabic: true)}\u202C',
          messageEn: 'Pasted Maglis code: $code',
          icon: Icons.paste_rounded,
          customDuration: const Duration(seconds: 2),
        ));
      } else if (digitsOnly.isNotEmpty) {
        _codeCtrl.text = digitsOnly;
        _onCodeChanged(digitsOnly);
        _focusNode.requestFocus();
      }
    } catch (_) {}
  }

  void _copyShareLink() {
    final link = MaglisLinkService.formatUrl(_newCode);
    Clipboard.setData(ClipboardData(text: link));
    AppState.instance.showBanner(AppBannerInfo(
      id: 'maglis_link_copied',
      messageAr: 'تم نسخ رابط المجلس: $link',
      messageEn: 'Maglis link copied: $link',
      icon: Icons.link_rounded,
      customDuration: const Duration(seconds: 2),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final app = AppState.instance;
    final bool isDark = app.isDarkMode;
    final bool isAr = app.isArabic;
    final c = app.colors;
    final isWide = MediaQuery.sizeOf(context).width > 600;

    final Color surfaceColor = c.surface;
    final Color borderColor = isDark
        ? Colors.white.withValues(alpha: 0.12)
        : c.border.withValues(alpha: 0.35);

    return Directionality(
      textDirection: isAr ? TextDirection.rtl : TextDirection.ltr,
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: RepaintBoundary(
          child: Stack(
            alignment: Alignment.topCenter,
            children: [
              Container(
                decoration: BoxDecoration(
                  color: surfaceColor,
                  borderRadius: isWide
                      ? BorderRadius.circular(26)
                      : const BorderRadius.vertical(top: Radius.circular(28)),
                  border: Border.all(color: borderColor),
                ),
                padding: const EdgeInsets.fromLTRB(20, 14, 20, 22),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (!isWide)
                      const AppDragHandle(padding: EdgeInsets.only(bottom: 12)),

                    // Segmented Tab Picker with Hint Button Beside It
                    Row(
                      children: [
                        Expanded(
                          child: Container(
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
                                    title: isAr ? 'عقد المجلس' : 'Open Maglis',
                                    icon: Icons.meeting_room_rounded,
                                    isSelected: _selectedTab == 1,
                                    isDark: isDark,
                                    c: c,
                                    onTap: () {
                                      if (_selectedTab != 1) {
                                        setState(() => _selectedTab = 1);
                                      }
                                    },
                                  ),
                                ),
                                Expanded(
                                  child: _tabButton(
                                    title: isAr ? 'دخول المجلس' : 'Join Maglis',
                                    icon: Icons.login_rounded,
                                    isSelected: _selectedTab == 0,
                                    isDark: isDark,
                                    c: c,
                                    onTap: () {
                                      if (_selectedTab != 0) {
                                        setState(() => _selectedTab = 0);
                                      }
                                    },
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(width: 4),
                        IconButton(
                          tooltip: isAr ? 'إرشادات المجلس' : 'How it works',
                          visualDensity: VisualDensity.compact,
                          onPressed: () {
                            MaglisExplanationDialog.show(context);
                          },
                          icon: Icon(
                            Icons.help_outline_rounded,
                            color: c.muted,
                            size: 20,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 18),

                    // 3. Tab Body (Fixed height — ZERO height jumping when switching tabs)
                    SizedBox(
                      height: 204,
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 180),
                        child: _selectedTab == 0
                            ? _buildModernJoinBody(isDark, isAr, c, borderColor)
                            : _buildModernCreateBody(
                                isDark, isAr, c, borderColor),
                      ),
                    ),
                  ],
                ),
              ),

              // ── Modern Floating Banner positioned right ABOVE the Action Button ──
              Positioned(
                bottom: 76,
                left: 16,
                right: 16,
                child: ValueListenableBuilder<AppBannerInfo?>(
                  valueListenable: app.bannerNotifier,
                  builder: (context, activeBanner, _) {
                    return AnimatedSwitcher(
                      duration: const Duration(milliseconds: 220),
                      transitionBuilder: (child, anim) => FadeTransition(
                        opacity: anim,
                        child: SlideTransition(
                          position: Tween<Offset>(
                            begin: const Offset(0, 0.35),
                            end: Offset.zero,
                          ).animate(CurvedAnimation(
                            parent: anim,
                            curve: Curves.easeOutCubic,
                          )),
                          child: child,
                        ),
                      ),
                      child: activeBanner == null
                          ? const SizedBox.shrink()
                          : _buildDialogBanner(
                              activeBanner, c, isDark, isAr, app),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Modern floating banner pill rendered cleanly inside the dialog
  Widget _buildDialogBanner(
    AppBannerInfo banner,
    dynamic c,
    bool isDark,
    bool isAr,
    AppState app,
  ) {
    final Color accentColor;
    if (banner.customColor != null) {
      accentColor = banner.customColor!(c, isDark);
    } else if (banner.isWarning) {
      accentColor = isDark ? const Color(0xFFF59E0B) : const Color(0xFFD97706);
    } else {
      accentColor = const Color(0xFF10B981);
    }

    final Color iconColor =
        (banner.isWarning && isDark) ? const Color(0xFFFBBF24) : accentColor;
    final String message = isAr ? banner.messageAr : banner.messageEn;

    return Center(
      key: ValueKey(banner.id),
      child: GestureDetector(
        onTap: () => app.dismissBanner(),
        child: Container(
          constraints: const BoxConstraints(maxWidth: 380),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF1E2538) : Colors.white,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: accentColor.withValues(alpha: isDark ? 0.45 : 0.35),
              width: 1.1,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: isDark ? 0.40 : 0.12),
                blurRadius: 12,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 26,
                height: 26,
                decoration: BoxDecoration(
                  color: accentColor.withValues(alpha: isDark ? 0.20 : 0.12),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: accentColor.withValues(alpha: isDark ? 0.45 : 0.35),
                    width: 0.8,
                  ),
                ),
                alignment: Alignment.center,
                child: Icon(banner.icon, color: iconColor, size: 15),
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  message,
                  style: TextStyle(
                    color: isDark ? Colors.white : const Color(0xFF0F172A),
                    height: 1.3,
                    fontWeight: FontWeight.w600,
                    fontSize: 12,
                  ),
                  textAlign: isAr ? TextAlign.right : TextAlign.left,
                  textDirection: isAr ? TextDirection.rtl : TextDirection.ltr,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
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

  /// Modern, intuitive Join UI matching Open Maglis's exact card styling, with interactive slots and smart paste
  Widget _buildModernJoinBody(
      bool isDark, bool isAr, dynamic c, Color borderColor) {
    final text = _codeCtrl.text.trim();

    return SizedBox(
      height: 204,
      child: Column(
        key: const ValueKey('join_tab_body'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          // Hero Maglis Code Card
          GestureDetector(
            onTap: _openKeyboard,
            behavior: HitTestBehavior.opaque,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: const Color(0xFF10B981)
                    .withValues(alpha: isDark ? 0.08 : 0.06),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: _focusNode.hasFocus
                      ? const Color(0xFF10B981).withValues(alpha: 0.50)
                      : const Color(0xFF10B981).withValues(alpha: 0.25),
                  width: _focusNode.hasFocus ? 1.4 : 1.0,
                ),
              ),
              child: Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.touch_app_rounded,
                        size: 14,
                        color: c.muted,
                      ),
                      const SizedBox(width: 5),
                      Text(
                        isAr
                            ? 'اضغط هنا لكتابة الرمز (5 أرقام)'
                            : 'Tap here to type 5-digit Maglis code',
                        style: TextStyle(
                          color: c.muted,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),

                  // 5 Discrete Digit Slots strictly in Left-to-Right order (Clean empty boxes, no dashes/slashes!)
                  Stack(
                    alignment: Alignment.center,
                    children: [
                      IgnorePointer(
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Directionality(
                            textDirection: TextDirection.ltr,
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: List.generate(5, (index) {
                                final hasChar = index < text.length;
                                final isCurrent =
                                    index == text.length && _focusNode.hasFocus;
                                final char = hasChar
                                    ? formatMaglisCode(text[index],
                                        isArabic: isAr)
                                    : '';

                                return Container(
                                  width: 40,
                                  height: 44,
                                  margin: const EdgeInsets.symmetric(
                                      horizontal: 2.5),
                                  decoration: BoxDecoration(
                                    color: isDark
                                        ? (hasChar
                                            ? Colors.white
                                                .withValues(alpha: 0.12)
                                            : Colors.white
                                                .withValues(alpha: 0.05))
                                        : (hasChar
                                            ? Colors.white
                                            : Colors.white
                                                .withValues(alpha: 0.60)),
                                    borderRadius: BorderRadius.circular(10),
                                    border: Border.all(
                                      color: isCurrent
                                          ? const Color(0xFF10B981)
                                          : (hasChar
                                              ? const Color(0xFF10B981)
                                                  .withValues(
                                                      alpha:
                                                          isDark ? 0.45 : 0.35)
                                              : (isDark
                                                  ? Colors.white
                                                      .withValues(alpha: 0.15)
                                                  : Colors.black.withValues(
                                                      alpha: 0.12))),
                                      width: isCurrent ? 1.8 : 1.2,
                                    ),
                                    boxShadow: [
                                      BoxShadow(
                                        color: (isCurrent || hasChar)
                                            ? const Color(0xFF10B981)
                                                .withValues(
                                                    alpha: isDark ? 0.20 : 0.10)
                                            : Colors.transparent,
                                        blurRadius: isCurrent ? 6 : 3,
                                        offset: const Offset(0, 1),
                                      ),
                                    ],
                                  ),
                                  alignment: Alignment.center,
                                  child: hasChar
                                      ? Text(
                                          char,
                                          style: const TextStyle(
                                            fontFamily: 'cairo',
                                            fontWeight: FontWeight.w900,
                                            fontSize: 22,
                                            color: Color(0xFF10B981),
                                          ),
                                        )
                                      : (isCurrent
                                          ? Container(
                                              width: 2,
                                              height: 18,
                                              color: const Color(0xFF10B981),
                                            )
                                          : const SizedBox.shrink()),
                                );
                              }),
                            ),
                          ),
                        ),
                      ),

                      // Transparent Native Input Overlay
                      Positioned.fill(
                        child: Opacity(
                          opacity: 0.0,
                          child: TextField(
                            focusNode: _focusNode,
                            controller: _codeCtrl,
                            keyboardType: TextInputType.number,
                            autofocus: false, // Never open automatically!
                            showCursor: false,
                            cursorWidth: 0,
                            enableInteractiveSelection: false,
                            onChanged: _onCodeChanged,
                            onSubmitted:
                                _canJoin ? (v) => _submitSession(v) : null,
                            inputFormatters: [
                              FilteringTextInputFormatter.allow(
                                  RegExp(r'[\d\u0660-\u0669]')),
                              LengthLimitingTextInputFormatter(5),
                              TextInputFormatter.withFunction(
                                  (oldValue, newValue) {
                                final norm =
                                    normalizeArabicDigits(newValue.text);
                                return newValue.copyWith(
                                  text: norm,
                                  selection: TextSelection.collapsed(
                                      offset: norm.length),
                                );
                              }),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 10),

                  // Dedicated Action Pill: Smart Paste & Clear
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      InkWell(
                        borderRadius: BorderRadius.circular(22),
                        onTap: _pasteFromClipboard,
                        child: Container(
                          height: 38,
                          padding: const EdgeInsets.symmetric(horizontal: 18),
                          decoration: BoxDecoration(
                            color: isDark
                                ? Colors.white.withValues(alpha: 0.07)
                                : Colors.black.withValues(alpha: 0.05),
                            borderRadius: BorderRadius.circular(22),
                            border: Border.all(
                              color: isDark
                                  ? Colors.white.withValues(alpha: 0.14)
                                  : Colors.black.withValues(alpha: 0.10),
                              width: 1.0,
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.paste_rounded,
                                  color: Color(0xFF10B981), size: 17),
                              const SizedBox(width: 7),
                              Text(
                                isAr ? 'لصق الرمز' : 'Paste',
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w700,
                                  color: isDark
                                      ? const Color(0xFFCBD5E1)
                                      : const Color(0xFF334155),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      if (text.isNotEmpty) ...[
                        const SizedBox(width: 8),
                        InkWell(
                          borderRadius: BorderRadius.circular(22),
                          onTap: () {
                            _codeCtrl.clear();
                            _onCodeChanged('');
                          },
                          child: Container(
                            height: 38,
                            padding: const EdgeInsets.symmetric(horizontal: 14),
                            decoration: BoxDecoration(
                              color: isDark
                                  ? Colors.white.withValues(alpha: 0.07)
                                  : Colors.black.withValues(alpha: 0.05),
                              borderRadius: BorderRadius.circular(22),
                              border: Border.all(
                                color: isDark
                                    ? Colors.white.withValues(alpha: 0.14)
                                    : Colors.black.withValues(alpha: 0.10),
                                width: 1.0,
                              ),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.clear_rounded,
                                    size: 16, color: c.muted),
                                const SizedBox(width: 5),
                                Text(
                                  isAr ? 'مسح' : 'Clear',
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w700,
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
                ],
              ),
            ),
          ),

          // Submit Button (matching Open Maglis button)
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
              onPressed: (_canJoin && !_isJoining)
                  ? () => _submitSession(_codeCtrl.text)
                  : null,
              icon: _isJoining
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.login_rounded, size: 20),
              label: Text(
                _isJoining
                    ? (isAr
                        ? 'جاري التحقق من المجلس...'
                        : 'Verifying Maglis...')
                    : (isAr ? 'دخول المجلس الآن' : 'Join Maglis Now'),
                style:
                    const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Modern, intuitive Create UI with strictly LTR Maglis code slots, separate copy button, and human copy
  Widget _buildModernCreateBody(
      bool isDark, bool isAr, dynamic c, Color borderColor) {
    final displayCode = formatMaglisCode(_newCode, isArabic: isAr);
    final displayDigits = displayCode.split('');

    return SizedBox(
      height: 204,
      child: Column(
        key: const ValueKey('create_tab_body'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          // Hero Maglis Code Card
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: const Color(0xFF10B981)
                  .withValues(alpha: isDark ? 0.08 : 0.06),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: const Color(0xFF10B981).withValues(alpha: 0.25),
              ),
            ),
            child: Column(
              children: [
                Text(
                  isAr
                      ? 'رمز المجلس لمشاركته مع إخوانك'
                      : 'Your 5-Digit Maglis Code',
                  style: TextStyle(
                    color: c.muted,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),

                // 5 Discrete Digit Slots strictly in Left-to-Right order (Zero BiDi inversion!)
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Directionality(
                    textDirection: TextDirection.ltr,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: List.generate(displayDigits.length, (index) {
                        return Container(
                          width: 40,
                          height: 44,
                          margin: const EdgeInsets.symmetric(horizontal: 2.5),
                          decoration: BoxDecoration(
                            color: isDark
                                ? Colors.white.withValues(alpha: 0.07)
                                : Colors.white,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: const Color(0xFF10B981)
                                  .withValues(alpha: isDark ? 0.45 : 0.35),
                              width: 1.2,
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: const Color(0xFF10B981)
                                    .withValues(alpha: isDark ? 0.15 : 0.08),
                                blurRadius: 4,
                                offset: const Offset(0, 1),
                              ),
                            ],
                          ),
                          alignment: Alignment.center,
                          child: Text(
                            displayDigits[index],
                            style: const TextStyle(
                              fontFamily: 'cairo',
                              fontWeight: FontWeight.w900,
                              fontSize: 22,
                              color: Color(0xFF10B981),
                            ),
                          ),
                        );
                      }),
                    ),
                  ),
                ),

                const SizedBox(height: 10),

                // Action Buttons: Copy Code & Send Link
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // 1. Copy Code Button
                      InkWell(
                        borderRadius: BorderRadius.circular(18),
                        onTap: () {
                          Clipboard.setData(ClipboardData(text: _newCode));
                          AppState.instance.showBanner(AppBannerInfo(
                            id: 'maglis_code_copied',
                            messageAr:
                                'تم نسخ رمز المجلس: \u202A${formatMaglisCode(_newCode, isArabic: true)}\u202C',
                            messageEn: 'Maglis code copied: $_newCode',
                            icon: Icons.copy_rounded,
                            customDuration: const Duration(seconds: 2),
                          ));
                        },
                        child: Container(
                          height: 34,
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          decoration: BoxDecoration(
                            color: isDark
                                ? Colors.white.withValues(alpha: 0.07)
                                : Colors.black.withValues(alpha: 0.05),
                            borderRadius: BorderRadius.circular(18),
                            border: Border.all(
                              color: isDark
                                  ? Colors.white.withValues(alpha: 0.14)
                                  : Colors.black.withValues(alpha: 0.10),
                              width: 1.0,
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.copy_rounded,
                                  color: Color(0xFF10B981), size: 14),
                              const SizedBox(width: 5),
                              Text(
                                isAr ? 'نسخ الرمز' : 'Copy Code',
                                style: TextStyle(
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.w700,
                                  color: isDark
                                      ? const Color(0xFFCBD5E1)
                                      : const Color(0xFF334155),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),

                      // 2. Share / Send Link Button
                      InkWell(
                        borderRadius: BorderRadius.circular(18),
                        onTap: () async {
                          final text = MaglisLinkService.formatInviteText(
                              _newCode,
                              isArabic: isAr);
                          final subject = isAr
                              ? 'دعوة لمجلس تلاوة القرآن العظيم'
                              : 'Quran Maglis Invitation';
                          Rect? origin;
                          final box = context.findRenderObject() as RenderBox?;
                          if (box != null && box.hasSize) {
                            origin = box.localToGlobal(Offset.zero) & box.size;
                          }
                          origin ??= const Rect.fromLTWH(0, 0, 100, 100);
                          try {
                            await SharePlus.instance.share(ShareParams(
                              text: text,
                              subject: subject,
                              title: subject,
                              sharePositionOrigin: origin,
                            ));
                          } catch (_) {
                            _copyShareLink();
                          }
                        },
                        onLongPress: _copyShareLink,
                        child: Container(
                          height: 34,
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                          decoration: BoxDecoration(
                            color: const Color(0xFF10B981)
                                .withValues(alpha: isDark ? 0.15 : 0.10),
                            borderRadius: BorderRadius.circular(18),
                            border: Border.all(
                              color: const Color(0xFF10B981)
                                  .withValues(alpha: isDark ? 0.35 : 0.25),
                              width: 1.0,
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.share_rounded,
                                  color: Color(0xFF10B981), size: 14),
                              const SizedBox(width: 5),
                              Text(
                                isAr ? 'إرسال' : 'Send',
                                style: const TextStyle(
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.w700,
                                  color: Color(0xFF10B981),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          // Start Maglis Button
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
              onPressed: _isCreating ? null : () => _submitSession(_newCode),
              icon: _isCreating
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.play_arrow_rounded, size: 21),
              label: Text(
                _isCreating
                    ? (isAr ? 'جاري افتتاح المجلس...' : 'Opening Maglis...')
                    : (isAr ? 'افتتاح المجلس الآن' : 'Start Maglis Now'),
                style:
                    const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

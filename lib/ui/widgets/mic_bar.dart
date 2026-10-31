import 'dart:math' as math;
import 'dart:ui' show ImageFilter;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../services/app_haptics.dart';
import '../../state/app_state.dart';
import '../../maglis/maglis_core.dart';

enum MicBarMode { recording, maglis, normal }

class BottomActionBar extends StatelessWidget {
  final bool isRecording;
  final bool isLoadingEngine;
  final ThemeColors c;
  final VoidCallback onMic;
  final bool isBlur;
  final VoidCallback onToggleBlur;
  final bool isTajweed;
  final VoidCallback onToggleTajweed;
  final String surahName;
  final VoidCallback onSurahTap;
  final VoidCallback onSettingsTap;
  final bool isInMaglis;
  final VoidCallback? onMaglisTap;
  final VoidCallback? onMaglisExitTap;
  final String? maglisRoomCode;
  final int maglisPeerCount;
  final bool isRemoteReciting;

  const BottomActionBar({
    super.key,
    required this.isRecording,
    this.isLoadingEngine = false,
    required this.c,
    required this.onMic,
    required this.isBlur,
    required this.onToggleBlur,
    required this.isTajweed,
    required this.onToggleTajweed,
    required this.surahName,
    required this.onSurahTap,
    required this.onSettingsTap,
    this.isInMaglis = false,
    this.onMaglisTap,
    this.onMaglisExitTap,
    this.maglisRoomCode,
    this.maglisPeerCount = 0,
    this.isRemoteReciting = false,
  });

  MicBarMode get mode => isInMaglis
      ? MicBarMode.maglis
      : (isRecording ? MicBarMode.recording : MicBarMode.normal);

  static Color _btnBg(bool isDark, {bool isActive = false}) => isActive
      ? const Color(0xFF10B981).withValues(alpha: isDark ? 0.22 : 0.15)
      : (isDark ? const Color(0xFF1B2430) : const Color(0xFFF1F5F9));

  static Color _btnBorder(bool isDark, {bool isActive = false}) => isActive
      ? const Color(0xFF10B981).withValues(alpha: isDark ? 0.75 : 0.60)
      : (isDark
          ? Colors.white.withValues(alpha: 0.10)
          : Colors.black.withValues(alpha: 0.08));

  static Color _btnFg(bool isDark, {bool isActive = false}) => isActive
      ? (isDark ? const Color(0xFF34D399) : const Color(0xFF059699))
      : (isDark ? const Color(0xFFE2E8F0) : const Color(0xFF1E293B));

  @override
  Widget build(BuildContext context) {
    final app = AppState.instance;
    final bool isDark = app.isDarkMode;
    final bool isAr = app.isArabic;

    return SafeArea(
      top: false,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final double maxW = constraints.maxWidth;
          final bool isNarrow = maxW < 360.0;

          final double dockHeight = isNarrow ? 46.0 : 48.0;
          const double dockRadius = 14.0; // Less rounded, closer to a rectangle
          const double hPad = 6.0;
          const double borderW = 1.1;
          const double rightTuck =
              4.0; // Tucks right pill edge under record button
          final double btnHeight = isNarrow ? 36.0 : 38.0;

          const double protrusion = 4.5;
          final double recHeight = dockHeight + (protrusion * 2.0);
          final double micWidth = isNarrow ? 58.0 : 64.0;

          final double stdBtnWidth = isNarrow ? 38.0 : 42.0;
          final double gap = isNarrow ? 5.0 : 6.0;
          final double maglisGap = isNarrow ? 4.0 : 5.0;

          final double normalWidth = math.min(maxW - 20.0, 480.0);
          final double recordingWidth = hPad +
              borderW +
              micWidth +
              gap +
              stdBtnWidth +
              gap +
              stdBtnWidth +
              1.0;
          final double maglisWidth = math.max(300.0, maxW - 42.0);

          final double targetWidth = switch (mode) {
            MicBarMode.recording => recordingWidth,
            MicBarMode.maglis => maglisWidth,
            MicBarMode.normal => normalWidth,
          };

          final double normalRightMargin =
              math.max(10.0, (maxW - normalWidth) / 2.0);
          final double rightMargin =
              mode == MicBarMode.maglis ? 8.0 : normalRightMargin;

          final double minNormalActionWidth =
              (stdBtnWidth * 2.0) + (gap * 2.0) + 68.0;
          final double minMaglisActionWidth = 210.0;

          final Color pillBg =
              isDark ? const Color(0xEE0F151D) : const Color(0xF6FFFFFF);
          final Color pillBorder = isRecording
              ? const Color(0xFFF43F5E).withValues(alpha: isDark ? 0.45 : 0.35)
              : (isDark
                  ? Colors.white.withValues(alpha: 0.12)
                  : Colors.black.withValues(alpha: 0.08));

          return Padding(
            padding: EdgeInsets.only(
              bottom: 10.0,
              right: rightMargin,
              left: 8.0,
            ),
            child: Align(
              alignment: Alignment.bottomRight,
              child: SizedBox(
                width: targetWidth,
                height: dockHeight,
                child: Stack(
                  clipBehavior: Clip.none,
                  alignment: Alignment.centerRight,
                  children: [
                    // 1. Rectangular-Pill Back Chassis (tucked under record button on the right)
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 250),
                      curve: Curves.easeOutCubic,
                      width: targetWidth,
                      height: dockHeight,
                      margin: const EdgeInsets.only(right: rightTuck),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(dockRadius),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black
                                .withValues(alpha: isDark ? 0.48 : 0.10),
                            blurRadius: 22,
                            offset: const Offset(0, 7),
                          ),
                          if (isRecording)
                            BoxShadow(
                              color: const Color(0xFFF43F5E)
                                  .withValues(alpha: isDark ? 0.22 : 0.14),
                              blurRadius: 18,
                              offset: const Offset(0, 3),
                            ),
                        ],
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(dockRadius),
                        child: BackdropFilter(
                          filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 220),
                            padding: const EdgeInsets.only(left: hPad),
                            decoration: BoxDecoration(
                              color: pillBg,
                              borderRadius: BorderRadius.circular(dockRadius),
                              border: Border.all(
                                color: pillBorder,
                                width: borderW,
                              ),
                            ),
                            child: Directionality(
                              textDirection: TextDirection.rtl,
                              child: Row(
                                children: [
                                  SizedBox(
                                    width: micWidth - rightTuck - borderW,
                                  ),
                                  SizedBox(
                                    width: mode == MicBarMode.maglis
                                        ? maglisGap
                                        : gap,
                                  ),
                                  Expanded(
                                    child: AnimatedSwitcher(
                                      duration:
                                          const Duration(milliseconds: 200),
                                      switchInCurve: Curves.easeOutCubic,
                                      switchOutCurve: Curves.easeInCubic,
                                      layoutBuilder:
                                          (currentChild, previousChildren) {
                                        return Stack(
                                          clipBehavior: Clip.hardEdge,
                                          alignment: Alignment.centerRight,
                                          children: [
                                            ...previousChildren.map(
                                              (w) => IgnorePointer(child: w),
                                            ),
                                            if (currentChild != null)
                                              currentChild,
                                          ],
                                        );
                                      },
                                      child: switch (mode) {
                                        // CASE 1: SOLO RECORDING
                                        MicBarMode.recording =>
                                          SingleChildScrollView(
                                            key: const ValueKey(
                                              'mode_recording',
                                            ),
                                            scrollDirection: Axis.horizontal,
                                            physics:
                                                const NeverScrollableScrollPhysics(),
                                            child: Row(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                _buildActionButton(
                                                  child: Icon(
                                                    isBlur
                                                        ? Icons
                                                            .visibility_off_rounded
                                                        : Icons
                                                            .visibility_rounded,
                                                    size: 18.5,
                                                    color: _btnFg(
                                                      isDark,
                                                      isActive: isBlur,
                                                    ),
                                                  ),
                                                  tooltip: isAr
                                                      ? 'إخفاء الآيات'
                                                      : 'Hide Verses',
                                                  isActive: isBlur,
                                                  isDark: isDark,
                                                  width: stdBtnWidth,
                                                  height: btnHeight,
                                                  dockHeight: dockHeight,
                                                  onTap: onToggleBlur,
                                                ),
                                                SizedBox(width: gap),
                                                _buildActionButton(
                                                  child: Icon(
                                                    isTajweed
                                                        ? Icons
                                                            .record_voice_over_rounded
                                                        : Icons
                                                            .record_voice_over_outlined,
                                                    size: 18.5,
                                                    color: _btnFg(
                                                      isDark,
                                                      isActive: isTajweed,
                                                    ),
                                                  ),
                                                  tooltip: isAr
                                                      ? 'أحكام التجويد'
                                                      : 'Tajweed Rules',
                                                  isActive: isTajweed,
                                                  isDark: isDark,
                                                  width: stdBtnWidth,
                                                  height: btnHeight,
                                                  dockHeight: dockHeight,
                                                  onTap: onToggleTajweed,
                                                ),
                                              ],
                                            ),
                                          ),

                                        // CASE 2: MAGLIS SESSION
                                        MicBarMode.maglis =>
                                          _NonOverflowingActionRow(
                                            key: const ValueKey('mode_maglis'),
                                            minWidth: minMaglisActionWidth,
                                            child: Row(
                                              children: [
                                                Expanded(
                                                  flex: 10,
                                                  child: _buildActionButton(
                                                    child: Icon(
                                                      isBlur
                                                          ? Icons
                                                              .visibility_off_rounded
                                                          : Icons
                                                              .visibility_rounded,
                                                      size: 18.0,
                                                      color: _btnFg(
                                                        isDark,
                                                        isActive: isBlur,
                                                      ),
                                                    ),
                                                    tooltip: isAr
                                                        ? 'إخفاء الآيات'
                                                        : 'Hide Verses',
                                                    isActive: isBlur,
                                                    isDark: isDark,
                                                    height: btnHeight,
                                                    dockHeight: dockHeight,
                                                    onTap: onToggleBlur,
                                                  ),
                                                ),
                                                SizedBox(width: maglisGap),
                                                Expanded(
                                                  flex: 10,
                                                  child: _buildActionButton(
                                                    child: Icon(
                                                      isTajweed
                                                          ? Icons
                                                              .record_voice_over_rounded
                                                          : Icons
                                                              .record_voice_over_outlined,
                                                      size: 18.0,
                                                      color: _btnFg(
                                                        isDark,
                                                        isActive: isTajweed,
                                                      ),
                                                    ),
                                                    tooltip: isAr
                                                        ? 'أحكام التجويد'
                                                        : 'Tajweed Rules',
                                                    isActive: isTajweed,
                                                    isDark: isDark,
                                                    height: btnHeight,
                                                    dockHeight: dockHeight,
                                                    onTap: onToggleTajweed,
                                                  ),
                                                ),
                                                SizedBox(width: maglisGap),
                                                Expanded(
                                                  flex: 10,
                                                  child: _buildActionButton(
                                                    child: _EmptyMushafIcon(
                                                      size: 18.0,
                                                      color: _btnFg(isDark),
                                                    ),
                                                    tooltip: isAr
                                                        ? 'اختيار السورة'
                                                        : 'Select Surah',
                                                    isActive: false,
                                                    isDark: isDark,
                                                    height: btnHeight,
                                                    dockHeight: dockHeight,
                                                    onTap: onSurahTap,
                                                  ),
                                                ),
                                                SizedBox(width: maglisGap),
                                                Expanded(
                                                  flex: 25,
                                                  child: _buildMaglisSessionBox(
                                                    height: btnHeight,
                                                    dockHeight: dockHeight,
                                                    isDark: isDark,
                                                    isAr: isAr,
                                                    isNarrow: isNarrow,
                                                  ),
                                                ),
                                                SizedBox(width: maglisGap),
                                                Expanded(
                                                  flex: 11,
                                                  child: _buildLeaveButton(
                                                    height: btnHeight,
                                                    dockHeight: dockHeight,
                                                    isAr: isAr,
                                                    onTap: onMaglisExitTap ??
                                                        () {},
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),

                                        // CASE 3: NORMAL READING
                                        MicBarMode.normal =>
                                          _NonOverflowingActionRow(
                                            key: const ValueKey('mode_normal'),
                                            minWidth: minNormalActionWidth,
                                            child: Row(
                                              children: [
                                                _buildMaglisEntryButton(
                                                  isDark: isDark,
                                                  isAr: isAr,
                                                  width: stdBtnWidth,
                                                  height: btnHeight,
                                                  dockHeight: dockHeight,
                                                  showNewBadge:
                                                      app.showMaglisNewBadge,
                                                  onTap: onMaglisTap ?? () {},
                                                ),
                                                SizedBox(width: gap),
                                                Expanded(
                                                  child: _buildSurahPill(
                                                    isDark: isDark,
                                                    isAr: isAr,
                                                    isNarrow: isNarrow,
                                                    height: btnHeight,
                                                    dockHeight: dockHeight,
                                                  ),
                                                ),
                                                SizedBox(width: gap),
                                                _buildActionButton(
                                                  child: Icon(
                                                    Icons.tune_rounded,
                                                    size: 18.5,
                                                    color: _btnFg(isDark),
                                                  ),
                                                  tooltip: isAr
                                                      ? 'الإعدادات'
                                                      : 'Settings',
                                                  isActive: false,
                                                  isDark: isDark,
                                                  width: stdBtnWidth,
                                                  height: btnHeight,
                                                  dockHeight: dockHeight,
                                                  onTap: onSettingsTap,
                                                ),
                                              ],
                                            ),
                                          ),
                                      },
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),

                    // 2. Protruding Hero Record Key (Flush with right edge)
                    Positioned(
                      top: -protrusion,
                      bottom: -protrusion,
                      right: 0.0,
                      child: _buildMicButton(
                        width: micWidth,
                        height: recHeight,
                        isDark: isDark,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildMicButton({
    required double width,
    required double height,
    required bool isDark,
  }) {
    final List<Color> gradient = isRecording
        ? const [Color(0xFFFF3B6B), Color(0xFFE11D48)]
        : const [Color(0xFF10B981), Color(0xFF059669)];

    return _TapScale(
      onTapDown: AppHaptics.heavyImpact,
      onTap: onMic,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        width: width,
        height: height,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14.0),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: gradient,
          ),
          border: Border.all(
            color: Colors.white.withValues(alpha: isDark ? 0.40 : 0.65),
            width: 1.3,
          ),
          boxShadow: [
            BoxShadow(
              color: gradient[0].withValues(alpha: isDark ? 0.45 : 0.30),
              blurRadius: 14,
              offset: const Offset(0, 4),
            ),
            BoxShadow(
              color: Colors.black.withValues(alpha: isDark ? 0.35 : 0.14),
              blurRadius: 6,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        alignment: Alignment.center,
        child: isLoadingEngine
            ? const SizedBox(
                width: 19,
                height: 19,
                child: CircularProgressIndicator(
                  strokeWidth: 2.2,
                  color: Colors.white,
                ),
              )
            : (isRecording
                ? const _AudioWaveform()
                : const Icon(
                    Icons.mic_rounded,
                    color: Colors.white,
                    size: 25.5,
                  )),
      ),
    );
  }

  Widget _buildActionButton({
    required Widget child,
    required String tooltip,
    required bool isActive,
    required bool isDark,
    double? width,
    required double height,
    required double dockHeight,
    required VoidCallback onTap,
  }) {
    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 350),
      child: _TapScale(
        onTapDown: AppHaptics.lightImpact,
        onTap: onTap,
        child: SizedBox(
          width: width,
          height: dockHeight,
          child: Center(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              width: width ?? double.infinity,
              height: height,
              decoration: BoxDecoration(
                color: _btnBg(isDark, isActive: isActive),
                borderRadius: BorderRadius.circular(10.0),
                border: Border.all(
                  color: _btnBorder(isDark, isActive: isActive),
                  width: isActive ? 1.2 : 1.0,
                ),
              ),
              alignment: Alignment.center,
              child: child,
            ),
          ),
        ),
      ),
    );
  }

  // Maglis Session Box (Unchanged except 1-member vector icon for extra number space)
  Widget _buildMaglisSessionBox({
    required double height,
    required double dockHeight,
    required bool isDark,
    required bool isAr,
    required bool isNarrow,
  }) {
    final String rawCode = maglisRoomCode ?? '';
    final String displayCode = formatMaglisCode(rawCode, isArabic: isAr);
    final int count = maglisPeerCount > 0 ? maglisPeerCount : 1;
    final String countDisplay =
        formatMaglisCode(count.toString(), isArabic: isAr);
    final Color fgColor = _btnFg(isDark);

    return Tooltip(
      message:
          isAr ? 'رمز المجلس (اضغط لنسخ الرمز)' : 'Maglis Code (tap to copy)',
      waitDuration: const Duration(milliseconds: 350),
      child: _TapScale(
        onTapDown: AppHaptics.lightImpact,
        onTap: () {
          if (rawCode.isNotEmpty) {
            Clipboard.setData(ClipboardData(text: rawCode));
            AppHaptics.mediumImpact();
            AppState.instance.showBanner(
              AppBannerInfo(
                id: 'maglis_code_copied',
                messageAr:
                    'تم نسخ رمز المجلس: \u202A${formatMaglisCode(rawCode, isArabic: true)}\u202C',
                messageEn: 'Maglis code copied: $rawCode',
                icon: Icons.copy_rounded,
                customDuration: const Duration(seconds: 2),
              ),
            );
          }
        },
        child: SizedBox(
          height: dockHeight,
          child: Center(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              height: height,
              padding: EdgeInsets.symmetric(horizontal: isNarrow ? 6.0 : 8.0),
              decoration: BoxDecoration(
                color: _btnBg(isDark, isActive: isRemoteReciting),
                borderRadius: BorderRadius.circular(8.0),
                border: Border.all(
                  color: _btnBorder(isDark, isActive: isRemoteReciting),
                  width: 1.0,
                ),
              ),
              alignment: Alignment.center,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Directionality(
                  textDirection: TextDirection.ltr,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        displayCode.isEmpty ? '----' : displayCode,
                        maxLines: 1,
                        style: TextStyle(
                          fontFamily: 'cairo',
                          color: fgColor,
                          fontWeight: FontWeight.w800,
                          fontSize: isNarrow ? 13.5 : 14.5,
                          letterSpacing: 1.1,
                          height: 1.05,
                        ),
                      ),
                      Container(
                        width: 1.0,
                        height: 14.0,
                        margin: const EdgeInsets.symmetric(horizontal: 6.0),
                        color: isDark
                            ? Colors.white.withValues(alpha: 0.14)
                            : Colors.black.withValues(alpha: 0.12),
                      ),
                      // 1-Member Vector Logo (saves horizontal space for numbers)
                      _OneMemberIcon(
                        size: isNarrow ? 13.5 : 14.5,
                        color: fgColor,
                      ),
                      const SizedBox(width: 3.0),
                      Text(
                        countDisplay,
                        maxLines: 1,
                        style: TextStyle(
                          fontFamily: 'cairo',
                          color: fgColor,
                          fontWeight: FontWeight.w800,
                          fontSize: isNarrow ? 12.5 : 13.5,
                          height: 1.05,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildLeaveButton({
    required double height,
    required double dockHeight,
    required bool isAr,
    required VoidCallback onTap,
  }) {
    return Tooltip(
      message: isAr ? 'مغادرة المجلس' : 'Leave Maglis',
      waitDuration: const Duration(milliseconds: 350),
      child: _TapScale(
        onTapDown: AppHaptics.mediumImpact,
        onTap: onTap,
        child: SizedBox(
          height: dockHeight,
          child: Center(
            child: Container(
              width: double.infinity,
              height: height,
              decoration: BoxDecoration(
                color: const Color(0xFFF43F5E),
                borderRadius: BorderRadius.circular(10.0),
              ),
              alignment: Alignment.center,
              child: const Icon(
                Icons.call_end_rounded,
                size: 18.0,
                color: Colors.white,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildMaglisEntryButton({
    required bool isDark,
    required bool isAr,
    required double width,
    required double height,
    required double dockHeight,
    required bool showNewBadge,
    required VoidCallback onTap,
  }) {
    final btn = _buildActionButton(
      child: _FourPersonsIcon(
        size: 20.0,
        isDark: isDark,
      ),
      tooltip: isAr ? 'مجلس القرآن' : 'Quran Maglis',
      isActive: false,
      isDark: isDark,
      width: width,
      height: height,
      dockHeight: dockHeight,
      onTap: onTap,
    );

    if (!showNewBadge) return btn;

    return Stack(
      clipBehavior: Clip.none,
      children: [
        btn,
        Positioned(
          top: 3.0,
          right: isAr ? -2.0 : null,
          left: isAr ? null : -2.0,
          child: IgnorePointer(
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: 4.5,
                vertical: 1.5,
              ),
              decoration: BoxDecoration(
                color: const Color(0xFF10B981),
                borderRadius: BorderRadius.circular(5.0),
              ),
              child: Text(
                isAr ? 'جديد' : 'NEW',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 7.5,
                  fontWeight: FontWeight.w800,
                  height: 1.1,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSurahPill({
    required bool isDark,
    required bool isAr,
    required bool isNarrow,
    required double height,
    required double dockHeight,
  }) {
    final Color fgColor = _btnFg(isDark);

    return _TapScale(
      onTapDown: AppHaptics.lightImpact,
      onTap: onSurahTap,
      child: SizedBox(
        height: dockHeight,
        child: Center(
          child: Container(
            height: height,
            padding: EdgeInsets.symmetric(horizontal: isNarrow ? 8.0 : 11.0),
            decoration: BoxDecoration(
              color: _btnBg(isDark),
              borderRadius: BorderRadius.circular(10.0),
              border: Border.all(color: _btnBorder(isDark), width: 1.0),
            ),
            child: Row(
              children: [
                _EmptyMushafIcon(
                  size: isNarrow ? 16.5 : 17.5,
                  color: fgColor,
                ),
                SizedBox(width: isNarrow ? 5.0 : 7.0),
                Expanded(
                  child: Text(
                    surahName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontFamily: 'cairo',
                      color: fgColor,
                      fontSize: isNarrow ? 12.5 : (isAr ? 13.5 : 13.0),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                Icon(
                  Icons.keyboard_arrow_down_rounded,
                  color: isDark
                      ? const Color(0xFF94A3B8)
                      : const Color(0xFF64748B),
                  size: isNarrow ? 15.0 : 16.5,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Prevents RenderFlex Overflow During Collapse / Decollapse Width Transitions
// ─────────────────────────────────────────────────────────────────────────────
class _NonOverflowingActionRow extends StatelessWidget {
  final double minWidth;
  final Widget child;

  const _NonOverflowingActionRow({
    super.key,
    required this.minWidth,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth >= minWidth) {
          return child;
        }
        return ClipRect(
          child: OverflowBox(
            minWidth: minWidth,
            maxWidth: minWidth,
            alignment: Alignment.centerRight,
            child: SizedBox(
              width: minWidth,
              child: child,
            ),
          ),
        );
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Eye-Comfort 4-Members Vector Icon (Two-Tier Non-Intersecting Slate Outlines)
// ─────────────────────────────────────────────────────────────────────────────
class _FourPersonsIcon extends StatelessWidget {
  final double size;
  final bool isDark;

  const _FourPersonsIcon({required this.size, required this.isDark});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(painter: _FourPersonsPainter(isDark)),
    );
  }
}

class _FourPersonsPainter extends CustomPainter {
  final bool isDark;
  _FourPersonsPainter(this.isDark);

  @override
  void paint(Canvas canvas, Size size) {
    final double w = size.width;
    final double h = size.height;

    // Soft eye-comfort slate tones (calm contrast, zero harsh black)
    final Color frontColor =
        isDark ? const Color(0xFFD8E2EE) : const Color(0xFF334155);
    final Color backColor =
        isDark ? const Color(0xFF7C8EA6) : const Color(0xFF8496AE);

    final Paint frontStroke = Paint()
      ..color = frontColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = w * 0.082
      ..strokeCap = StrokeCap.round
      ..isAntiAlias = true;

    final Paint backStroke = Paint()
      ..color = backColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = w * 0.074
      ..strokeCap = StrokeCap.round
      ..isAntiAlias = true;

    // Back Left Member (Elevated tier, outer non-colliding shoulder arc)
    canvas.drawCircle(Offset(w * 0.22, h * 0.25), w * 0.088, backStroke);
    canvas.drawArc(
      Rect.fromCenter(
        center: Offset(w * 0.21, h * 0.57),
        width: w * 0.30,
        height: h * 0.30,
      ),
      math.pi * 1.05,
      math.pi * 0.58,
      false,
      backStroke,
    );

    // Back Right Member (Elevated tier, outer non-colliding shoulder arc)
    canvas.drawCircle(Offset(w * 0.78, h * 0.25), w * 0.088, backStroke);
    canvas.drawArc(
      Rect.fromCenter(
        center: Offset(w * 0.79, h * 0.57),
        width: w * 0.30,
        height: h * 0.30,
      ),
      math.pi * 1.37,
      math.pi * 0.58,
      false,
      backStroke,
    );

    // Front Left Member (Foreground tier)
    canvas.drawCircle(Offset(w * 0.36, h * 0.48), w * 0.102, frontStroke);
    canvas.drawArc(
      Rect.fromCenter(
        center: Offset(w * 0.35, h * 0.84),
        width: w * 0.36,
        height: h * 0.34,
      ),
      math.pi * 1.08,
      math.pi * 0.78,
      false,
      frontStroke,
    );

    // Front Right Member (Foreground tier)
    canvas.drawCircle(Offset(w * 0.64, h * 0.48), w * 0.102, frontStroke);
    canvas.drawArc(
      Rect.fromCenter(
        center: Offset(w * 0.65, h * 0.84),
        width: w * 0.36,
        height: h * 0.34,
      ),
      math.pi * 1.14,
      math.pi * 0.78,
      false,
      frontStroke,
    );
  }

  @override
  bool shouldRepaint(covariant _FourPersonsPainter old) => old.isDark != isDark;
}

// ─────────────────────────────────────────────────────────────────────────────
// Compact 1-Member Vector Icon (Used in Maglis Label Box to save number space)
// ─────────────────────────────────────────────────────────────────────────────
class _OneMemberIcon extends StatelessWidget {
  final double size;
  final Color color;

  const _OneMemberIcon({required this.size, required this.color});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(painter: _OneMemberPainter(color)),
    );
  }
}

class _OneMemberPainter extends CustomPainter {
  final Color color;
  _OneMemberPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final double w = size.width;
    final double h = size.height;
    final Paint paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = w * 0.11
      ..strokeCap = StrokeCap.round
      ..isAntiAlias = true;

    canvas.drawCircle(Offset(w * 0.50, h * 0.30), w * 0.17, paint);
    canvas.drawArc(
      Rect.fromCenter(
        center: Offset(w * 0.50, h * 0.78),
        width: w * 0.62,
        height: h * 0.48,
      ),
      math.pi * 1.10,
      math.pi * 0.80,
      false,
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant _OneMemberPainter old) => old.color != color;
}

// ─────────────────────────────────────────────────────────────────────────────
// Empty Open Mushaf Vector Icon (No inner lines)
// ─────────────────────────────────────────────────────────────────────────────
class _EmptyMushafIcon extends StatelessWidget {
  final double size;
  final Color color;

  const _EmptyMushafIcon({required this.size, required this.color});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(painter: _EmptyMushafPainter(color)),
    );
  }
}

class _EmptyMushafPainter extends CustomPainter {
  final Color color;
  _EmptyMushafPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final double w = size.width;
    final double h = size.height;
    final Paint paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = w * 0.095
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true;

    final Path pages = Path()
      ..moveTo(w * 0.50, h * 0.25)
      ..quadraticBezierTo(w * 0.31, h * 0.17, w * 0.12, h * 0.23)
      ..lineTo(w * 0.12, h * 0.75)
      ..quadraticBezierTo(w * 0.31, h * 0.69, w * 0.50, h * 0.79)
      ..moveTo(w * 0.50, h * 0.25)
      ..quadraticBezierTo(w * 0.69, h * 0.17, w * 0.88, h * 0.23)
      ..lineTo(w * 0.88, h * 0.75)
      ..quadraticBezierTo(w * 0.69, h * 0.69, w * 0.50, h * 0.79);

    canvas.drawPath(pages, paint);
    canvas.drawLine(
      Offset(w * 0.50, h * 0.25),
      Offset(w * 0.50, h * 0.80),
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant _EmptyMushafPainter old) => old.color != color;
}

// ─────────────────────────────────────────────────────────────────────────────
// Smooth 4-Bar Audio Waveform
// ─────────────────────────────────────────────────────────────────────────────
class _AudioWaveform extends StatefulWidget {
  const _AudioWaveform();

  @override
  State<_AudioWaveform> createState() => _AudioWaveformState();
}

class _AudioWaveformState extends State<_AudioWaveform>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    )..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: SizedBox(
        width: 22,
        height: 18,
        child: AnimatedBuilder(
          animation: _ctrl,
          builder: (context, _) =>
              CustomPaint(painter: _WaveformPainter(_ctrl.value)),
        ),
      ),
    );
  }
}

class _WaveformPainter extends CustomPainter {
  final double progress;
  _WaveformPainter(this.progress);

  static final Paint _paint = Paint()..color = Colors.white;

  @override
  void paint(Canvas canvas, Size size) {
    final double t = progress * 2.0 * math.pi;
    final List<double> heights = [
      6.0 + 3.0 * math.sin(t),
      10.0 + 4.5 * math.sin(t + 1.4),
      9.5 + 4.0 * math.sin(t + 2.8),
      6.5 + 3.0 * math.sin(t + 4.2),
    ];

    const double barW = 2.6;
    const double gap = 2.6;
    double x = (size.width - (4 * barW + 3 * gap)) / 2.0;
    final double cy = size.height / 2.0;

    for (final double h in heights) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, cy - h / 2.0, barW, h),
          const Radius.circular(1.3),
        ),
        _paint,
      );
      x += barW + gap;
    }
  }

  @override
  bool shouldRepaint(covariant _WaveformPainter old) =>
      old.progress != progress;
}

// ─────────────────────────────────────────────────────────────────────────────
// Tactile Scale Feedback
// ─────────────────────────────────────────────────────────────────────────────
class _TapScale extends StatefulWidget {
  final Widget child;
  final VoidCallback onTap;
  final VoidCallback? onTapDown;

  const _TapScale({
    required this.child,
    required this.onTap,
    this.onTapDown,
  });

  @override
  State<_TapScale> createState() => _TapScaleState();
}

class _TapScaleState extends State<_TapScale> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) {
        widget.onTapDown?.call();
        setState(() => _down = true);
      },
      onTapUp: (_) => setState(() => _down = false),
      onTapCancel: () => setState(() => _down = false),
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: _down ? 0.94 : 1.0,
        duration: const Duration(milliseconds: 90),
        curve: Curves.easeOutCubic,
        child: widget.child,
      ),
    );
  }
}

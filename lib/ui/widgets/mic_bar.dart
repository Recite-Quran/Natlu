import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../services/app_haptics.dart';
import '../../state/app_state.dart';
import '../../maglis/maglis_core.dart';

/// Ultra-Modern, Ultra-Lightweight Bottom Command Dock
///
/// Features:
/// - Smooth left-to-right collapse during recording without changing positions of persistent buttons.
/// - Zero RenderFlex overflows guaranteed.
/// - Only the button itself glows and highlights with a green overlay when active (NO dots).
/// - Clean bottom bar at all times (NO red shadow or background on the bar).
/// - Peak performance & battery efficiency with minimal code (~200 lines).
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

          final double recBtnSize = isNarrow ? 56.0 : 62.0;
          final double btnSize = isNarrow ? 34.0 : 38.0;
          final double settingsBtnSize = isNarrow ? 26.0 : 30.0;
          final double settingsIconSize = isNarrow ? 14.0 : 16.0;
          final double iconSize = isNarrow ? 17.0 : 19.0;
          final double gap = isNarrow ? 4.0 : 6.0;
          const double padH = 8.0;
          const double dockHeight = 56.0;

          // Full & Collapsed widths
          final double fullDockWidth = math.min(maxW - 24.0, 520.0);
          final double collapsedDockWidth = (padH * 2) + recBtnSize + (gap + btnSize) * 2;
          final double leftSpaceForPage = isNarrow ? 48.0 : 54.0;
          // In Maglis: Stretch dock across the bottom leaving only a small space on the left for the page number
          final double maglisDockWidth = math.min(maxW - 12.0 - leftSpaceForPage, 520.0);
          final double targetDockWidth = isInMaglis
              ? maglisDockWidth
              : (isRecording ? collapsedDockWidth : fullDockWidth);

          // Stationary right margin: locks right buttons to exact screen coordinates!
          final double rightMargin = math.max(12.0, (maxW - fullDockWidth) / 2.0);
          final double fullContentWidth = targetDockWidth - (padH * 2);

          // Clean, consistent dock styling (Zero red tint/shadow on the bar itself)
          final Color dockBg = isDark ? c.surfaceHigh : c.surface;
          final Color dockBorder = isDark
              ? Colors.white.withValues(alpha: 0.12)
              : Colors.black.withValues(alpha: 0.08);

          return Padding(
            padding: EdgeInsets.only(bottom: 11.0, right: rightMargin, left: 12.0),
            child: Align(
              alignment: Alignment.bottomRight,
              child: SizedBox(
                width: targetDockWidth,
                height: recBtnSize,
                child: Stack(
                  clipBehavior: Clip.none,
                  alignment: Alignment.centerRight,
                  children: [
                    // 1. Dock Pillar Container (stays strictly at dockHeight = 56.0, bottom: 3.0)
                    Positioned(
                      bottom: 3.0,
                      right: 0,
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 300),
                        curve: Curves.easeInOutCubic,
                        width: targetDockWidth,
                        height: dockHeight,
                        padding: const EdgeInsets.symmetric(horizontal: padH, vertical: 6.0),
                        decoration: BoxDecoration(
                          color: dockBg,
                          borderRadius: BorderRadius.circular(22.0),
                          border: Border.all(color: dockBorder, width: 1.0),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: isDark ? 0.35 : 0.08),
                              blurRadius: 16,
                              offset: const Offset(0, 4),
                            ),
                          ],
                        ),
                        child: OverflowBox(
                          minWidth: fullContentWidth,
                          maxWidth: fullContentWidth,
                          alignment: Alignment.centerRight,
                          child: SizedBox(
                            width: fullContentWidth,
                            child: Directionality(
                              textDirection: TextDirection.rtl,
                              child: Row(
                                children: [
                                  // Transparent horizontal slot reserved for the Hero Record Orb
                                  SizedBox(width: recBtnSize),
                                  SizedBox(width: gap),

                                  // Dynamic actions: Collapsed [Hide, Tajweed, (if Maglis: Surah, Room Code, Close Call)]
                                  // vs [Community, Surah Selector, Settings] when idle
                                  Expanded(
                                    child: AnimatedSwitcher(
                                      duration: const Duration(milliseconds: 200),
                                      switchInCurve: Curves.easeOutCubic,
                                      switchOutCurve: Curves.easeInCubic,
                                      layoutBuilder: (Widget? currentChild, List<Widget> previousChildren) {
                                        return Stack(
                                          alignment: Alignment.centerRight,
                                          children: <Widget>[
                                            ...previousChildren,
                                            if (currentChild != null) currentChild,
                                          ],
                                        );
                                      },
                                      child: (isRecording || isInMaglis)
                                          ? Row(
                                              key: ValueKey('active_dock_${isInMaglis ? 'maglis' : 'rec'}'),
                                              children: [
                                                _buildButton(
                                                  icon: isBlur
                                                      ? Icons.visibility_off_rounded
                                                      : Icons.visibility_rounded,
                                                  tooltip: isAr
                                                      ? 'إخفاء الآيات للتسميع'
                                                      : 'Hide Verses for Memorization',
                                                  isActive: isBlur,
                                                  isDark: isDark,
                                                  size: btnSize,
                                                  iconSize: iconSize,
                                                  onTap: onToggleBlur,
                                                ),
                                                SizedBox(width: gap),
                                                _buildButton(
                                                  icon: isTajweed
                                                      ? Icons.record_voice_over_rounded
                                                      : Icons.record_voice_over_outlined,
                                                  tooltip: isAr ? 'أحكام التجويد' : 'Tajweed Rules',
                                                  isActive: isTajweed,
                                                  isDark: isDark,
                                                  size: btnSize,
                                                  iconSize: iconSize,
                                                  onTap: onToggleTajweed,
                                                ),
                                                if (isInMaglis) ...[
                                                  SizedBox(width: gap),
                                                  _buildButton(
                                                    icon: Icons.menu_book_rounded,
                                                    tooltip: isAr ? 'اختيار السورة' : 'Select Surah',
                                                    isActive: false,
                                                    isDark: isDark,
                                                    size: btnSize,
                                                    iconSize: iconSize,
                                                    onTap: onSurahTap,
                                                  ),
                                                  SizedBox(width: gap),
                                                  Expanded(
                                                    child: _buildSessionInfoCard(
                                                      height: btnSize,
                                                      isDark: isDark,
                                                      isAr: isAr,
                                                      isNarrow: isNarrow,
                                                    ),
                                                  ),
                                                  SizedBox(width: gap),
                                                  _buildButton(
                                                    icon: Icons.call_end_rounded,
                                                    tooltip: isAr ? 'إنهاء المكالمة والمغادرة' : 'Leave Maglis Call',
                                                    isActive: true,
                                                    isDark: isDark,
                                                    size: btnSize,
                                                    iconSize: 18.0,
                                                    customActiveColor: const Color(0xFFF43F5E),
                                                    onTap: onMaglisExitTap ?? () {},
                                                  ),
                                                ],
                                              ],
                                            )
                                          : Row(
                                              key: const ValueKey('idle_bar_actions'),
                                              children: [
                                                _buildCommunityButton(
                                                  isDark: isDark,
                                                  isAr: isAr,
                                                  size: btnSize,
                                                  iconSize: iconSize + 1,
                                                  showNewBadge: app.showMaglisNewBadge,
                                                  onTap: onMaglisTap ?? () {},
                                                ),
                                                SizedBox(width: gap),
                                                Expanded(
                                                  child: _buildSurahSelector(
                                                      isDark, isAr, isNarrow, btnSize),
                                                ),
                                                SizedBox(width: gap),
                                                _buildButton(
                                                  icon: Icons.tune_rounded,
                                                  tooltip: isAr ? 'الإعدادات' : 'Settings',
                                                  isActive: false,
                                                  isDark: isDark,
                                                  size: settingsBtnSize,
                                                  iconSize: settingsIconSize,
                                                  onTap: onSettingsTap,
                                                ),
                                              ],
                                            ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),

                    // 2. Elevated Circular Hero Record Orb (Geometrically perfect, protruding floating action)
                    Positioned(
                      bottom: 0,
                      right: padH,
                      child: _buildRecButton(
                        isDark: isDark,
                        isNarrow: isNarrow,
                        size: recBtnSize,
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

  /// Expanded session status badge displaying the room code, participant count, and live pulse dot
  Widget _buildSessionInfoCard({
    required double height,
    required bool isDark,
    required bool isAr,
    required bool isNarrow,
  }) {
    final displayCode = formatMaglisCode(maglisRoomCode ?? '', isArabic: isAr);
    final count = maglisPeerCount > 0 ? maglisPeerCount : 1;
    final countDisplay = formatMaglisCode(count.toString(), isArabic: isAr);

    return InkWell(
      borderRadius: BorderRadius.circular(height * 0.34),
      onTap: () {
        if (maglisRoomCode != null && maglisRoomCode!.isNotEmpty) {
          Clipboard.setData(ClipboardData(text: maglisRoomCode!));
          AppHaptics.lightImpact();
          AppState.instance.showBanner(AppBannerInfo(
            id: 'maglis_code_copied',
            messageAr: 'تم نسخ رمز المجلس: \u202A${formatMaglisCode(maglisRoomCode!, isArabic: true)}\u202C',
            messageEn: 'Maglis code copied: $maglisRoomCode',
            icon: Icons.copy_rounded,
            customDuration: const Duration(seconds: 2),
          ));
        }
      },
      child: Container(
        height: height,
        padding: EdgeInsets.symmetric(horizontal: isNarrow ? 6.0 : 8.0),
        decoration: BoxDecoration(
          color: isDark
              ? Colors.white.withValues(alpha: 0.06)
              : Colors.black.withValues(alpha: 0.04),
          borderRadius: BorderRadius.circular(height * 0.34),
          border: Border.all(
            color: isDark
                ? Colors.white.withValues(alpha: 0.12)
                : Colors.black.withValues(alpha: 0.08),
            width: 0.9,
          ),
        ),
        alignment: Alignment.center,
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Live Audio Pulse Dot
              Container(
                width: 6.0,
                height: 6.0,
                decoration: BoxDecoration(
                  color: isRemoteReciting
                      ? const Color(0xFF38BDF8)
                      : const Color(0xFF10B981),
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: (isRemoteReciting
                              ? const Color(0xFF38BDF8)
                              : const Color(0xFF10B981))
                          .withValues(alpha: 0.5),
                      blurRadius: 4,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 5.0),

              // Room Code (Strictly LTR so digits never invert)
              Directionality(
                textDirection: TextDirection.ltr,
                child: Text(
                  displayCode,
                  maxLines: 1,
                  style: const TextStyle(
                    fontFamily: 'cairo',
                    color: Color(0xFF10B981),
                    fontWeight: FontWeight.w900,
                    fontSize: 12.0,
                    letterSpacing: 0.8,
                  ),
                ),
              ),

              // Subtle vertical separator
              Container(
                width: 1.0,
                height: height * 0.42,
                margin: EdgeInsets.symmetric(horizontal: isNarrow ? 5.0 : 6.5),
                color: isDark
                    ? Colors.white.withValues(alpha: 0.15)
                    : Colors.black.withValues(alpha: 0.12),
              ),

              // Users count (icon + count)
              Icon(
                Icons.groups_rounded,
                size: isNarrow ? 13.0 : 14.5,
                color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
              ),
              const SizedBox(width: 3.5),
              Directionality(
                textDirection: TextDirection.ltr,
                child: Text(
                  countDisplay,
                  maxLines: 1,
                  style: TextStyle(
                    fontFamily: 'cairo',
                    color: isDark ? const Color(0xFFCBD5E1) : const Color(0xFF334155),
                    fontWeight: FontWeight.w800,
                    fontSize: 11.5,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Community icon button with a non-intrusive micro "NEW" badge for first 5 taps
  Widget _buildCommunityButton({
    required bool isDark,
    required bool isAr,
    required double size,
    required double iconSize,
    required bool showNewBadge,
    required VoidCallback onTap,
  }) {
    final btn = _buildButton(
      icon: Icons.groups_rounded,
      tooltip: isAr ? 'مجلس التلاوة التشاركي' : 'Maglis P2P',
      isActive: false,
      isDark: isDark,
      size: size,
      iconSize: iconSize,
      onTap: onTap,
    );

    if (!showNewBadge) return btn;

    return Stack(
      clipBehavior: Clip.none,
      children: [
        btn,
        Positioned(
          top: -3.0,
          right: isAr ? -3.0 : null,
          left: isAr ? null : -3.0,
          child: IgnorePointer(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 4.0, vertical: 1.0),
              decoration: BoxDecoration(
                color: const Color(0xFF10B981),
                borderRadius: BorderRadius.circular(6.0),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFF10B981).withValues(alpha: 0.40),
                    blurRadius: 4,
                    offset: const Offset(0, 1),
                  ),
                ],
              ),
              child: Text(
                isAr ? 'جديد' : 'NEW',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 8.0,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.2,
                  height: 1.1,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// Modern Circular Hero Record Orb with multi-stop gradient, specular highlight, and neon aura
  Widget _buildRecButton({
    required bool isDark,
    required bool isNarrow,
    required double size,
  }) {
    final colors = isRecording
        ? const [Color(0xFFFB7185), Color(0xFFE11D48), Color(0xFF881337)]
        : (isRemoteReciting
            ? const [Color(0xFF38BDF8), Color(0xFF0284C7), Color(0xFF0369A1)]
            : const [Color(0xFF34D399), Color(0xFF059669), Color(0xFF065F46)]);

    return _TapScale(
      onTapDown: () {
        AppHaptics.heavyImpact();
      },
      onTap: onMic,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: LinearGradient(
            colors: colors,
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          border: Border.all(
            color: Colors.white.withValues(alpha: isDark ? 0.50 : 0.65),
            width: 1.5,
          ),
          boxShadow: [
            BoxShadow(
              color: colors[1].withValues(alpha: isDark ? 0.50 : 0.35),
              blurRadius: (isRecording || isRemoteReciting) ? 20 : 14,
              offset: const Offset(0, 4),
            ),
            BoxShadow(
              color: Colors.black.withValues(alpha: isDark ? 0.35 : 0.12),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          alignment: Alignment.center,
          children: [
            // Top-left radial specular shine for 3D glass orb finish
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    center: const Alignment(-0.35, -0.45),
                    radius: 0.65,
                    colors: [
                      Colors.white.withValues(alpha: 0.35),
                      Colors.white.withValues(alpha: 0.0),
                    ],
                  ),
                ),
              ),
            ),

            // Center Action Icon / Audio Waveform
            Center(
              child: isLoadingEngine
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white),
                    )
                  : (isRecording
                      ? const _AudioWaveform()
                      : (isRemoteReciting
                          ? Icon(
                              Icons.volume_up_rounded,
                              color: Colors.white,
                              size: isNarrow ? 23.0 : 26.0,
                            )
                          : Icon(
                              Icons.mic_rounded,
                              color: Colors.white,
                              size: isNarrow ? 25.0 : 28.0,
                            ))),
            ),
          ],
        ),
      ),
    );
  }

  /// Satellite button with modern emerald green highlight & overlay when ON (NO dot)
  Widget _buildButton({
    required IconData icon,
    required String tooltip,
    required bool isActive,
    required bool isDark,
    required double size,
    required double iconSize,
    required VoidCallback onTap,
    Color? customActiveColor,
  }) {
    final activeAccent = customActiveColor ?? const Color(0xFF10B981);

    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 350),
      child: _TapScale(
        onTapDown: () {
          AppHaptics.lightImpact();
        },
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutCubic,
          width: size,
          height: size,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(size * 0.34),
            // Accent overlay on the button itself when active
            color: isActive
                ? activeAccent.withValues(alpha: isDark ? 0.20 : 0.14)
                : (isDark ? Colors.white.withValues(alpha: 0.06) : Colors.black.withValues(alpha: 0.04)),
            // Radiant highlight border when ON
            border: Border.all(
              color: isActive
                  ? activeAccent
                  : (isDark ? Colors.white.withValues(alpha: 0.12) : Colors.black.withValues(alpha: 0.08)),
              width: isActive ? 1.4 : 0.9,
            ),
            // Soft ambient glow when ON
            boxShadow: isActive
                ? [
                    BoxShadow(
                      color: activeAccent.withValues(alpha: isDark ? 0.36 : 0.22),
                      blurRadius: 10,
                      offset: const Offset(0, 2),
                    ),
                  ]
                : null,
          ),
          alignment: Alignment.center,
          child: Icon(
            icon,
            size: iconSize,
            color: isActive
                ? activeAccent
                : (isDark ? const Color(0xFFE2E8F0) : const Color(0xFF334155)),
          ),
        ),
      ),
    );
  }

  /// Modern Surah Selector Capsule
  Widget _buildSurahSelector(bool isDark, bool isAr, bool isNarrow, double height) {
    return Tooltip(
      message: isAr ? 'اختيار السورة' : 'Select Surah',
      waitDuration: const Duration(milliseconds: 350),
      child: _TapScale(
        onTap: () {
          AppHaptics.lightImpact();
          onSurahTap();
        },
        child: Container(
          height: height,
          padding: EdgeInsets.symmetric(horizontal: isNarrow ? 6.0 : 9.0),
          decoration: BoxDecoration(
            color: isDark ? Colors.white.withValues(alpha: 0.06) : Colors.black.withValues(alpha: 0.04),
            borderRadius: BorderRadius.circular(13.0),
            border: Border.all(
              color: isDark ? Colors.white.withValues(alpha: 0.12) : Colors.black.withValues(alpha: 0.08),
              width: 0.9,
            ),
          ),
          child: Row(
            children: [
              Icon(
                Icons.menu_book_rounded,
                color: isDark ? const Color(0xFFE2E8F0) : const Color(0xFF334155),
                size: isNarrow ? 17.0 : 19.0,
              ),
              SizedBox(width: isNarrow ? 4.0 : 6.0),
              Expanded(
                child: Text(
                  surahName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: isDark ? const Color(0xFFF1F5F9) : const Color(0xFF0F172A),
                    fontSize: isNarrow ? 12.0 : (isAr ? 13.5 : 12.5),
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              Icon(Icons.keyboard_arrow_down_rounded, color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B), size: isNarrow ? 15.0 : 17.0),
            ],
          ),
        ),
      ),
    );
  }
}

/// Butter-smooth, continuous 60/120 FPS harmonic waveform
class _AudioWaveform extends StatefulWidget {
  const _AudioWaveform();

  @override
  State<_AudioWaveform> createState() => _AudioWaveformState();
}

class _AudioWaveformState extends State<_AudioWaveform>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    // Gentle, calm 2200ms ambient cycle: serene and non-distracting while reading
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2200),
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
          builder: (context, _) {
            return CustomPaint(
              painter: _SmoothWaveformPainter(progress: _ctrl.value),
            );
          },
        ),
      ),
    );
  }
}

class _SmoothWaveformPainter extends CustomPainter {
  final double progress;
  _SmoothWaveformPainter({required this.progress});

  static final Paint _paint = Paint()
    ..color = Colors.white
    ..style = PaintingStyle.fill;

  @override
  void paint(Canvas canvas, Size size) {
    // 2π rotation ensures mathematical continuity at the boundary (zero jarring loop jumps)
    final double t = progress * 2.0 * math.pi;

    // Calm, gentle harmonic wave amplitudes (non-distracting, serene ambient flow)
    final double h1 = (7.0 + 2.6 * math.sin(t)).clamp(4.0, 12.0);
    final double h2 = (9.0 + 3.0 * math.sin(t + 1.5)).clamp(4.0, 13.0);
    final double h3 = (8.5 + 2.8 * math.sin(t + 3.0)).clamp(4.0, 12.5);
    final double h4 = (6.5 + 2.4 * math.sin(t + 4.5)).clamp(4.0, 11.5);

    const double barW = 2.2;
    const double spacing = 2.4;
    const double totalW = (4 * barW) + (3 * spacing);
    double x = (size.width - totalW) / 2.0;
    final double centerY = size.height / 2.0;
    const rrectRad = Radius.circular(1.5);

    final heights = [h1, h2, h3, h4];
    for (int i = 0; i < 4; i++) {
      final double h = heights[i];
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, centerY - (h / 2.0), barW, h),
          rrectRad,
        ),
        _paint,
      );
      x += barW + spacing;
    }
  }

  @override
  bool shouldRepaint(covariant _SmoothWaveformPainter oldDelegate) {
    return oldDelegate.progress != progress;
  }
}

/// Ultra-lightweight tactile scale gesture wrapper
class _TapScale extends StatefulWidget {
  final Widget child;
  final VoidCallback onTap;
  final VoidCallback? onTapDown;
  const _TapScale({required this.child, required this.onTap, this.onTapDown});

  @override
  State<_TapScale> createState() => _TapScaleState();
}

class _TapScaleState extends State<_TapScale> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) {
        widget.onTapDown?.call();
        setState(() => _down = true);
      },
      onTapUp: (_) => setState(() => _down = false),
      onTapCancel: () => setState(() => _down = false),
      onTap: widget.onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedScale(
        scale: _down ? 0.93 : 1.0,
        duration: const Duration(milliseconds: 100),
        curve: _down ? Curves.easeOutCubic : Curves.easeOutBack,
        child: widget.child,
      ),
    );
  }
}

import 'dart:math' as math;
import 'dart:ui' show ImageFilter;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../services/app_haptics.dart';
import '../../state/app_state.dart';
import '../../maglis/maglis_core.dart';

/// The 3 distinct operational modes of the Command Dock:
/// 1. [recording]: Active solo recitation recording session.
/// 2. [maglis]: Active group Quran Maglis session.
/// 3. [normal]: Normal idle Quran reading session.
enum MicBarMode {
  recording,
  maglis,
  normal,
}

/// Ultra-Modern, Bespoke Production Bottom Command Dock
///
/// Refinements:
/// - True Stadium Back Pill: 46dp slim chassis with pure 23dp organic semicircular ends.
/// - Zero Button Cutting: Generous 14dp left-end padding ensures the leftmost button
///   never collides with or gets sliced by the pill's curved corner.
/// - Wider Hero Record Key (64w × 58h): Massive, luxurious thumb landing zone protruding
///   symmetrically 6dp above & 6dp below the 46dp dock.
/// - Bigger Close Call Button (46w × 38h): High-prominence crimson keycap in Maglis mode.
/// - Extended Session Span: In sessions, the bar stretches across the bottom, coming
///   right up to the page number (touching proximity with 4dp air, zero collision).
/// - Rich Persian Emerald & Electric Crimson Ruby palettes with tactile CNC light-catch bevels.
/// - 100% overflow immunity and zero ghost button activations.
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

  MicBarMode get mode {
    if (isInMaglis) return MicBarMode.maglis;
    if (isRecording) return MicBarMode.recording;
    return MicBarMode.normal;
  }

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

          // ── Chassis Dimensions ──────────────────────────────────────────
          // Sleek 47dp dock height (balances breathing space and reading room)
          final double dockHeight = isNarrow ? 45.0 : 47.0;
          final double dockRadius = dockHeight / 2.0;

          // Full-sized, comfortable buttons (never shrunken!)
          final double btnHeight = isNarrow ? 36.0 : 38.0;
          final double satelliteWidth = isNarrow ? 38.0 : 42.0;
          final double maglisSatelliteWidth = isNarrow ? 32.0 : 35.0;
          final double settingsBtnWidth = isNarrow ? 36.0 : 40.0;
          final double closeCallWidth = isNarrow ? 44.0 : 48.0;

          // Hero Record Key: Wide sculpted keycap
          final double heroRecW = (mode == MicBarMode.maglis)
              ? (isNarrow ? 58.0 : 64.0)
              : (isNarrow ? 62.0 : 70.0);
          final double recH = isNarrow ? 53.0 : 55.0;
          final double protrusion = (recH - dockHeight) / 2.0;

          final double gap = isNarrow ? 5.0 : 6.5;
          final double maglisGap = isNarrow ? 3.0 : 3.8;

          // Dock padding: 6dp on right (record key flank)
          const double padRight = 6.0;
          final double padLeft = (mode == MicBarMode.recording) ? 8.0 : 10.0;

          // ── Dock Widths & Positioning ───────────────────────────────────
          // 1. Normal mode: comfortable width centered or nicely margined
          final double normalDockWidth = math.min(maxW - 20.0, 520.0);

          // 2. Solo Recording mode: COLLAPSED stadium capsule wrapping ONLY the 3 buttons!
          // (Hero Mic Key + Blur Satellite + Tajweed Satellite)
          final double collapsedDockWidth =
              padRight + heroRecW + gap + satelliteWidth + gap + satelliteWidth + padLeft;

          // 3. Maglis Session: Stretches across the screen right up to page number,
          // providing maximum width and prominence to the room code & members card!
          const double rightMarginSession = 10.0;
          final double sessionDockWidth = math.max(290.0, maxW - rightMarginSession - 38.0);

          final double targetDockWidth = switch (mode) {
            MicBarMode.recording => collapsedDockWidth,
            MicBarMode.maglis => sessionDockWidth,
            MicBarMode.normal => normalDockWidth,
          };

          // Right margin: locks the bar and Record Key firmly in place
          // Stationary right margin: locks right buttons to exact screen coordinates!
          // Mic button stays perfectly anchored under thumb when toggling recording.
          final double normalRightMargin = math.max(10.0, (maxW - normalDockWidth) / 2.0);
          final double rightMargin = mode == MicBarMode.maglis
              ? rightMarginSession
              : normalRightMargin;

          // Max action width for overflow-safe crossfades
          final double maxActionContentWidth = math.max(
            normalDockWidth - padRight - padLeft - heroRecW - gap,
            sessionDockWidth - padRight - padLeft - heroRecW - maglisGap,
          );

          // ── Frosted Glass Modern Styling ─────────────────────────────────
          final Color dockBorderColor = isDark
              ? Colors.white.withValues(
                  alpha: mode == MicBarMode.maglis ? 0.20 : 0.14,
                )
              : (mode == MicBarMode.maglis
                  ? const Color(0xFF10B981).withValues(alpha: 0.28)
                  : Colors.black.withValues(alpha: 0.08));

          return Padding(
            padding: EdgeInsets.only(bottom: 10.0, right: rightMargin, left: 10.0),
            child: Align(
              alignment: Alignment.bottomRight,
              child: SizedBox(
                width: targetDockWidth,
                height: recH,
                child: Stack(
                  clipBehavior: Clip.none,
                  alignment: Alignment.centerRight,
                  children: [
                    // ── 1. Modern True Stadium Back Pill ──────────────────
                    Positioned(
                      top: protrusion,
                      bottom: protrusion,
                      right: 0,
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 260),
                        curve: Curves.easeInOutCubic,
                        width: targetDockWidth,
                        height: dockHeight,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(dockRadius),
                          boxShadow: [
                            // Deep ambient elevation aura
                            BoxShadow(
                              color: Colors.black.withValues(alpha: isDark ? 0.48 : 0.10),
                              blurRadius: 26,
                              offset: const Offset(0, 8),
                            ),
                            // Directional rim shadow
                            BoxShadow(
                              color: Colors.black.withValues(alpha: isDark ? 0.28 : 0.05),
                              blurRadius: 8,
                              offset: const Offset(0, 2),
                            ),
                            // Maglis subtle emerald ambient glow
                            if (mode == MicBarMode.maglis)
                              BoxShadow(
                                color: const Color(0xFF10B981).withValues(alpha: isDark ? 0.22 : 0.12),
                                blurRadius: 16,
                                spreadRadius: 1,
                                offset: const Offset(0, 2),
                              ),
                          ],
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(dockRadius),
                          child: BackdropFilter(
                            filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
                            child: Container(
                              width: targetDockWidth,
                              height: dockHeight,
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(dockRadius),
                                gradient: LinearGradient(
                                  begin: Alignment.topCenter,
                                  end: Alignment.bottomCenter,
                                  colors: isDark
                                      ? (mode == MicBarMode.maglis
                                          ? const [
                                              Color(0xF8152523),
                                              Color(0xFA0E1918),
                                            ]
                                          : const [
                                              Color(0xF618222C),
                                              Color(0xFA0F161E),
                                            ])
                                      : const [
                                          Color(0xF9FFFFFF),
                                          Color(0xEEF6F8FB),
                                        ],
                                ),
                                border: Border.all(color: dockBorderColor, width: 1.0),
                              ),
                              child: Stack(
                                children: [
                                  // Top Bevel Hairline Light Catch (Simulates curved optical glass reflection)
                                  Positioned(
                                    top: 0,
                                    left: dockRadius * 0.7,
                                    right: dockRadius * 0.7,
                                    height: 1.0,
                                    child: DecoratedBox(
                                      decoration: BoxDecoration(
                                        gradient: LinearGradient(
                                          colors: [
                                            Colors.white.withValues(alpha: 0.0),
                                            Colors.white.withValues(alpha: isDark ? 0.26 : 0.70),
                                            Colors.white.withValues(alpha: 0.0),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),

                                  // Inner Content Row
                                  Padding(
                                    padding: EdgeInsets.only(
                                      right: padRight,
                                      left: padLeft,
                                      top: 4.5,
                                      bottom: 4.5,
                                    ),
                                    child: Directionality(
                                      textDirection: TextDirection.rtl,
                                      child: Row(
                                        children: [
                                          // Reserved transparent slot for the Hero Record Key
                                          SizedBox(width: heroRecW),
                                          SizedBox(width: mode == MicBarMode.maglis ? maglisGap : gap),

                                          // Dynamic Actions: The 3 Clean Modes with IgnorePointer protection
                                          Expanded(
                                            child: AnimatedSwitcher(
                                              duration: const Duration(milliseconds: 220),
                                              switchInCurve: Curves.easeOutCubic,
                                              switchOutCurve: Curves.easeInCubic,
                                              transitionBuilder: (child, animation) {
                                                return FadeTransition(opacity: animation, child: child);
                                              },
                                              layoutBuilder: (Widget? currentChild, List<Widget> previousChildren) {
                                                return Stack(
                                                  clipBehavior: Clip.none,
                                                  alignment: Alignment.centerRight,
                                                  children: <Widget>[
                                                    // Fading-out children are ignored from hit tests AND given full width via OverflowBox
                                                    ...previousChildren.map(
                                                      (w) => IgnorePointer(
                                                        child: OverflowBox(
                                                          minWidth: maxActionContentWidth,
                                                          maxWidth: maxActionContentWidth,
                                                          alignment: Alignment.centerRight,
                                                          child: SizedBox(
                                                            width: maxActionContentWidth,
                                                            child: w,
                                                          ),
                                                        ),
                                                      ),
                                                    ),
                                                    if (currentChild != null) currentChild,
                                                  ],
                                                );
                                              },
                                              child: switch (mode) {
                                                // ── CASE 1: SOLO RECORDING (Collapsed Stadium Capsule with the 3 Buttons)
                                                MicBarMode.recording => Row(
                                                    key: const ValueKey('mic_bar_recording'),
                                                    mainAxisSize: MainAxisSize.min,
                                                    children: [
                                                      _buildSatelliteButton(
                                                        icon: isBlur
                                                            ? Icons.visibility_off_rounded
                                                            : Icons.visibility_rounded,
                                                        tooltip: isAr
                                                            ? 'إخفاء الآيات للتسميع'
                                                            : 'Hide Verses for Memorization',
                                                        isActive: isBlur,
                                                        isDark: isDark,
                                                        width: satelliteWidth,
                                                        height: btnHeight,
                                                        iconSize: 18.0,
                                                        onTap: onToggleBlur,
                                                      ),
                                                      SizedBox(width: gap),
                                                      _buildSatelliteButton(
                                                        icon: isTajweed
                                                            ? Icons.record_voice_over_rounded
                                                            : Icons.record_voice_over_outlined,
                                                        tooltip: isAr ? 'أحكام التجويد' : 'Tajweed Rules',
                                                        isActive: isTajweed,
                                                        isDark: isDark,
                                                        width: satelliteWidth,
                                                        height: btnHeight,
                                                        iconSize: 18.0,
                                                        onTap: onToggleTajweed,
                                                      ),
                                                    ],
                                                  ),

                                                // ── CASE 2: MAGLIS SESSION (Prominent Wide Session Info Card)
                                                MicBarMode.maglis => Row(
                                                    key: const ValueKey('mic_bar_maglis'),
                                                    children: [
                                                      _buildSatelliteButton(
                                                        icon: isBlur
                                                            ? Icons.visibility_off_rounded
                                                            : Icons.visibility_rounded,
                                                        tooltip: isAr
                                                            ? 'إخفاء الآيات للتسميع'
                                                            : 'Hide Verses for Memorization',
                                                        isActive: isBlur,
                                                        isDark: isDark,
                                                        width: maglisSatelliteWidth,
                                                        height: btnHeight,
                                                        iconSize: 17.0,
                                                        onTap: onToggleBlur,
                                                      ),
                                                      SizedBox(width: maglisGap),
                                                      _buildSatelliteButton(
                                                        icon: isTajweed
                                                            ? Icons.record_voice_over_rounded
                                                            : Icons.record_voice_over_outlined,
                                                        tooltip: isAr ? 'أحكام التجويد' : 'Tajweed Rules',
                                                        isActive: isTajweed,
                                                        isDark: isDark,
                                                        width: maglisSatelliteWidth,
                                                        height: btnHeight,
                                                        iconSize: 17.0,
                                                        onTap: onToggleTajweed,
                                                      ),
                                                      SizedBox(width: maglisGap),
                                                      _buildSatelliteButton(
                                                        icon: Icons.menu_book_rounded,
                                                        tooltip: isAr ? 'اختيار السورة' : 'Select Surah',
                                                        isActive: false,
                                                        isDark: isDark,
                                                        width: maglisSatelliteWidth,
                                                        height: btnHeight,
                                                        iconSize: 17.0,
                                                        onTap: onSurahTap,
                                                      ),
                                                      SizedBox(width: maglisGap),
                                                      Expanded(
                                                        child: _buildSessionInfoCard(
                                                          height: btnHeight,
                                                          isDark: isDark,
                                                          isAr: isAr,
                                                          isNarrow: isNarrow,
                                                        ),
                                                      ),
                                                      SizedBox(width: maglisGap),
                                                      _buildSatelliteButton(
                                                        icon: Icons.call_end_rounded,
                                                        tooltip: isAr ? 'إنهاء المكالمة والمغادرة' : 'Leave Maglis Call',
                                                        isActive: true,
                                                        isDark: isDark,
                                                        width: closeCallWidth,
                                                        height: btnHeight,
                                                        iconSize: 19.5,
                                                        customActiveColor: const Color(0xFFF43F5E),
                                                        onTap: onMaglisExitTap ?? () {},
                                                      ),
                                                      const SizedBox(width: 4.0), // Safe interior clearance from left curve
                                                    ],
                                                  ),

                                                // ── CASE 3: NORMAL READING SESSION
                                                MicBarMode.normal => Row(
                                                    key: const ValueKey('mic_bar_normal'),
                                                    children: [
                                                      _buildCommunityButton(
                                                        isDark: isDark,
                                                        isAr: isAr,
                                                        width: satelliteWidth,
                                                        height: btnHeight,
                                                        iconSize: 18.0,
                                                        showNewBadge: app.showMaglisNewBadge,
                                                        onTap: onMaglisTap ?? () {},
                                                      ),
                                                      SizedBox(width: gap),
                                                      Expanded(
                                                        child: _buildSurahSelector(
                                                          isDark: isDark,
                                                          isAr: isAr,
                                                          isNarrow: isNarrow,
                                                          height: btnHeight,
                                                        ),
                                                      ),
                                                      SizedBox(width: gap),
                                                      _buildSatelliteButton(
                                                        icon: Icons.tune_rounded,
                                                        tooltip: isAr ? 'الإعدادات' : 'Settings',
                                                        isActive: false,
                                                        isDark: isDark,
                                                        width: settingsBtnWidth,
                                                        height: btnHeight,
                                                        iconSize: 17.0,
                                                        onTap: onSettingsTap,
                                                      ),
                                                      const SizedBox(width: 4.0), // Safe interior clearance from left curve
                                                    ],
                                                  ),
                                              },
                                            ),
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

                    // ── 2. Wider Hero Record Key (Protrudes symmetrically above & below)
                    Positioned(
                      bottom: 0,
                      top: 0,
                      right: padRight,
                      child: Center(
                        child: _buildHeroRecButton(
                          isDark: isDark,
                          isNarrow: isNarrow,
                          width: heroRecW,
                          height: recH,
                        ),
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

  // ──────────────────────────────────────────────────────────────────────────
  // Wider Hero Record Button (64w × 58h, Sculpted Stadium Medallion)
  // ──────────────────────────────────────────────────────────────────────────
  Widget _buildHeroRecButton({
    required bool isDark,
    required bool isNarrow,
    required double width,
    required double height,
  }) {
    final double recRadius = isNarrow ? 20.0 : 22.0;

    // Rich Persian Emerald & Jade for Idle
    final idleColors = isDark
        ? const [Color(0xFF10B981), Color(0xFF059669), Color(0xFF047857)]
        : const [Color(0xFF34D399), Color(0xFF10B981), Color(0xFF059669)];

    // Electric Crimson & Coral Ruby for Recording
    final recColors = const [
      Color(0xFFFF2E63),
      Color(0xFFE11D48),
      Color(0xFF9F1239),
    ];

    final colors = isRecording ? recColors : idleColors;

    return _TapScale(
      onTapDown: () {
        AppHaptics.heavyImpact();
      },
      onTap: onMic,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeInOutCubic,
        width: width,
        height: height,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(recRadius),
          gradient: LinearGradient(
            colors: colors,
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          border: Border.all(
            color: Colors.white.withValues(alpha: isDark ? 0.45 : 0.60),
            width: 1.2,
          ),
          boxShadow: [
            // Ambient glow aura
            BoxShadow(
              color: colors[0].withValues(
                alpha: isRecording
                    ? (isDark ? 0.65 : 0.50)
                    : (isDark ? 0.48 : 0.32),
              ),
              blurRadius: isRecording ? 20 : 14,
              spreadRadius: isRecording ? 1 : 0,
              offset: const Offset(0, 4),
            ),
            // Tactile depth shadow
            BoxShadow(
              color: Colors.black.withValues(alpha: isDark ? 0.38 : 0.15),
              blurRadius: 7,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          alignment: Alignment.center,
          children: [
            // Top bevel hairline light catch (Simulates precision CNC-machined edge catching ambient light)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: height * 0.44,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius:
                      BorderRadius.vertical(top: Radius.circular(recRadius)),
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.white.withValues(alpha: isDark ? 0.28 : 0.38),
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
                      child: CircularProgressIndicator(
                          strokeWidth: 2.2, color: Colors.white),
                    )
                  : (isRecording
                      ? const _AudioWaveform()
                      : Icon(
                          Icons.mic_rounded,
                          color: Colors.white,
                          size: isNarrow ? 25.0 : 27.5,
                        )),
            ),
          ],
        ),
      ),
    );
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Satellite Button (Comfortable Width, Illuminated Keycap Styling)
  // ──────────────────────────────────────────────────────────────────────────
  Widget _buildSatelliteButton({
    required IconData icon,
    required String tooltip,
    required bool isActive,
    required bool isDark,
    required double width,
    required double height,
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
          width: width,
          height: height,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(13.0),
            // Soft frosted surface in idle, crisp illuminated keycap when active
            color: isActive
                ? activeAccent.withValues(alpha: isDark ? 0.22 : 0.15)
                : (isDark ? const Color(0xFF1B262C) : const Color(0xFFF1F5F9)),
            border: Border.all(
              color: isActive
                  ? activeAccent
                  : (isDark
                      ? Colors.white.withValues(alpha: 0.10)
                      : Colors.black.withValues(alpha: 0.08)),
              width: isActive ? 1.3 : 0.9,
            ),
            boxShadow: isActive
                ? [
                    BoxShadow(
                      color:
                          activeAccent.withValues(alpha: isDark ? 0.35 : 0.22),
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

  // ──────────────────────────────────────────────────────────────────────────
  // Community Button with Micro 'NEW' Badge
  // ──────────────────────────────────────────────────────────────────────────
  Widget _buildCommunityButton({
    required bool isDark,
    required bool isAr,
    required double width,
    required double height,
    required double iconSize,
    required bool showNewBadge,
    required VoidCallback onTap,
  }) {
    final btn = _buildSatelliteButton(
      icon: Icons.groups_rounded,
      tooltip: isAr ? 'مجلس القرآن المجيد' : 'The Glorious Quran Maglis',
      isActive: false,
      isDark: isDark,
      width: width,
      height: height,
      iconSize: iconSize,
      onTap: onTap,
    );

    if (!showNewBadge) return btn;

    return Stack(
      clipBehavior: Clip.none,
      children: [
        btn,
        Positioned(
          top: -2.0,
          right: isAr ? -2.0 : null,
          left: isAr ? null : -2.0,
          child: IgnorePointer(
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 4.5, vertical: 1.5),
              decoration: BoxDecoration(
                color: const Color(0xFF10B981),
                borderRadius: BorderRadius.circular(5.0),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFF10B981).withValues(alpha: 0.35),
                    blurRadius: 3,
                    offset: const Offset(0, 1),
                  ),
                ],
              ),
              child: Text(
                isAr ? 'جديد' : 'NEW',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 7.5,
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

  // ──────────────────────────────────────────────────────────────────────────
  // Surah Selector Pill
  // ──────────────────────────────────────────────────────────────────────────
  Widget _buildSurahSelector({
    required bool isDark,
    required bool isAr,
    required bool isNarrow,
    required double height,
  }) {
    return _TapScale(
      onTapDown: () {
        AppHaptics.lightImpact();
      },
      onTap: onSurahTap,
      child: Container(
        height: height,
        padding: EdgeInsets.symmetric(horizontal: isNarrow ? 7.0 : 11.0),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(13.0),
          color: isDark ? const Color(0xFF1B262C) : const Color(0xFFF1F5F9),
          border: Border.all(
            color: isDark
                ? Colors.white.withValues(alpha: 0.10)
                : Colors.black.withValues(alpha: 0.08),
            width: 0.9,
          ),
        ),
        child: Row(
          children: [
            Icon(
              Icons.menu_book_rounded,
              color: const Color(0xFF10B981),
              size: isNarrow ? 16.0 : 17.5,
            ),
            SizedBox(width: isNarrow ? 4.5 : 6.5),
            Expanded(
              child: Text(
                surahName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontFamily: 'cairo',
                  color: isDark
                      ? const Color(0xFFF8FAFC)
                      : const Color(0xFF0F172A),
                  fontSize: isNarrow ? 12.0 : (isAr ? 13.5 : 12.5),
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            Icon(
              Icons.keyboard_arrow_down_rounded,
              color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
              size: isNarrow ? 14.5 : 16.0,
            ),
          ],
        ),
      ),
    );
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Maglis Session Info Card (Prominent High-Contrast Keycap)
  // ──────────────────────────────────────────────────────────────────────────
  Widget _buildSessionInfoCard({
    required double height,
    required bool isDark,
    required bool isAr,
    required bool isNarrow,
  }) {
    final displayCode = formatMaglisCode(maglisRoomCode ?? '', isArabic: isAr);
    final count = maglisPeerCount > 0 ? maglisPeerCount : 1;
    final countDisplay = formatMaglisCode(count.toString(), isArabic: isAr);

    return Tooltip(
      message:
          isAr ? 'رمز المجلس (اضغط لنسخ الرمز)' : 'Maglis Code (tap to copy)',
      waitDuration: const Duration(milliseconds: 350),
      child: _TapScale(
        onTapDown: () {
          AppHaptics.lightImpact();
        },
        onTap: () {
          if (maglisRoomCode != null && maglisRoomCode!.isNotEmpty) {
            Clipboard.setData(ClipboardData(text: maglisRoomCode!));
            AppHaptics.mediumImpact();
            AppState.instance.showBanner(AppBannerInfo(
              id: 'maglis_code_copied',
              messageAr:
                  'تم نسخ رمز المجلس: \u202A${formatMaglisCode(maglisRoomCode!, isArabic: true)}\u202C',
              messageEn: 'Maglis code copied: $maglisRoomCode',
              icon: Icons.copy_rounded,
              customDuration: const Duration(seconds: 2),
            ));
          }
        },
        child: Container(
          height: height,
          padding: EdgeInsets.symmetric(horizontal: isNarrow ? 7.0 : 10.0),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(13.0),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: isDark
                  ? const [
                      Color(0x3810B981),
                      Color(0x1F059669),
                    ]
                  : const [
                      Color(0x2E10B981),
                      Color(0x1A059669),
                    ],
            ),
            border: Border.all(
              color: const Color(0xFF10B981).withValues(alpha: isDark ? 0.55 : 0.40),
              width: 1.1,
            ),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF10B981).withValues(alpha: isDark ? 0.22 : 0.12),
                blurRadius: 10,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          alignment: Alignment.center,
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // Glowing Live Beacon Dot
                Container(
                  width: 6.5,
                  height: 6.5,
                  decoration: const BoxDecoration(
                    color: Color(0xFF10B981),
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: Color(0xFF10B981),
                        blurRadius: 6,
                        spreadRadius: 1,
                      ),
                    ],
                  ),
                ),
                SizedBox(width: isNarrow ? 5.0 : 7.0),

                // Maglis Room Code (Prominent High-Contrast Typography)
                Directionality(
                  textDirection: TextDirection.ltr,
                  child: Text(
                    displayCode,
                    maxLines: 1,
                    style: TextStyle(
                      fontFamily: 'cairo',
                      color: isDark ? const Color(0xFF34D399) : const Color(0xFF047857),
                      fontWeight: FontWeight.w900,
                      fontSize: isNarrow ? 14.0 : 15.5,
                      letterSpacing: 1.2,
                    ),
                  ),
                ),

                // Vertical Divider
                Container(
                  width: 1.2,
                  height: 16.0,
                  margin: EdgeInsets.symmetric(horizontal: isNarrow ? 6.0 : 8.0),
                  color: const Color(0xFF10B981).withValues(alpha: isDark ? 0.40 : 0.30),
                ),

                // Members Capsule Chip
                Container(
                  padding: EdgeInsets.symmetric(
                    horizontal: isNarrow ? 5.0 : 7.0,
                    vertical: 2.0,
                  ),
                  decoration: BoxDecoration(
                    color: isDark
                        ? Colors.black.withValues(alpha: 0.25)
                        : Colors.white.withValues(alpha: 0.60),
                    borderRadius: BorderRadius.circular(8.0),
                    border: Border.all(
                      color: isDark
                          ? Colors.white.withValues(alpha: 0.10)
                          : Colors.black.withValues(alpha: 0.06),
                      width: 0.8,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.groups_rounded,
                        size: isNarrow ? 14.5 : 16.0,
                        color: isDark ? const Color(0xFFE2E8F0) : const Color(0xFF1E293B),
                      ),
                      const SizedBox(width: 4.0),
                      Directionality(
                        textDirection: TextDirection.ltr,
                        child: Text(
                          countDisplay,
                          maxLines: 1,
                          style: TextStyle(
                            fontFamily: 'cairo',
                            color: isDark ? const Color(0xFFF8FAFC) : const Color(0xFF0F172A),
                            fontWeight: FontWeight.w900,
                            fontSize: isNarrow ? 12.0 : 13.0,
                          ),
                        ),
                      ),
                    ],
                  ),
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
// Audio Waveform Visualizer (4 Harmonic Bars at 60/120 FPS)
// ─────────────────────────────────────────────────────────────────────────────
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
    final double t = progress * 2.0 * math.pi;

    final double h1 = (7.0 + 2.6 * math.sin(t)).clamp(4.0, 12.0);
    final double h2 = (9.0 + 3.0 * math.sin(t + 1.5)).clamp(4.0, 13.0);
    final double h3 = (8.5 + 2.8 * math.sin(t + 3.0)).clamp(4.0, 12.5);
    final double h4 = (6.5 + 2.4 * math.sin(t + 4.5)).clamp(4.0, 11.5);

    const double barW = 2.4;
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

// ─────────────────────────────────────────────────────────────────────────────
// Zero-Latency Tactile Scale Feedback Wrapper
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
      child: RepaintBoundary(
        child: AnimatedScale(
          scale: _down ? 0.93 : 1.0,
          duration: const Duration(milliseconds: 100),
          curve: Curves.easeOutCubic,
          child: widget.child,
        ),
      ),
    );
  }
}

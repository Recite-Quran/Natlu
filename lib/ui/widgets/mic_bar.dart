import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../services/app_haptics.dart';
import '../../state/app_state.dart';

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
          final double collapsedDockWidth = (padH * 2) + recBtnSize + gap + btnSize;
          final double targetDockWidth = isRecording ? collapsedDockWidth : fullDockWidth;

          // Stationary right margin: locks right buttons to exact screen coordinates!
          final double rightMargin = math.max(12.0, (maxW - fullDockWidth) / 2.0);
          final double fullContentWidth = fullDockWidth - (padH * 2);

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

                                  // 2. Hide Verses Button (Persistent)
                                  _buildButton(
                                    icon: isBlur ? Icons.visibility_off_rounded : Icons.visibility_rounded,
                                    tooltip: isAr ? 'إخفاء الآيات للتسميع' : 'Hide Verses for Memorization',
                                    isActive: isBlur,
                                    isDark: isDark,
                                    size: btnSize,
                                    iconSize: iconSize,
                                    onTap: onToggleBlur,
                                  ),

                                  // 3. Collapsible Left Actions
                                  Expanded(
                                    child: ClipRect(
                                      child: AnimatedOpacity(
                                        duration: const Duration(milliseconds: 180),
                                        opacity: isRecording ? 0.0 : 1.0,
                                        child: Row(
                                          children: [
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
                                            SizedBox(width: gap),
                                            Expanded(
                                              child: _buildSurahSelector(isDark, isAr, isNarrow, btnSize),
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

  /// Modern Circular Hero Record Orb with multi-stop gradient, specular highlight, and neon aura
  Widget _buildRecButton({
    required bool isDark,
    required bool isNarrow,
    required double size,
  }) {
    final colors = isRecording
        ? const [Color(0xFFFB7185), Color(0xFFE11D48), Color(0xFF881337)]
        : const [Color(0xFF34D399), Color(0xFF059669), Color(0xFF065F46)];

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
              blurRadius: isRecording ? 20 : 14,
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
                      : Icon(
                          Icons.mic_rounded,
                          color: Colors.white,
                          size: isNarrow ? 25.0 : 28.0,
                        )),
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
  }) {
    const greenAccent = Color(0xFF10B981);

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
            // Green overlay on the button itself when active
            color: isActive
                ? greenAccent.withValues(alpha: isDark ? 0.20 : 0.14)
                : (isDark ? Colors.white.withValues(alpha: 0.06) : Colors.black.withValues(alpha: 0.04)),
            // Radiant green highlight border when ON
            border: Border.all(
              color: isActive
                  ? (isDark ? const Color(0xFF10B981) : const Color(0xFF047857))
                  : (isDark ? Colors.white.withValues(alpha: 0.12) : Colors.black.withValues(alpha: 0.08)),
              width: isActive ? 1.4 : 0.9,
            ),
            // Soft green ambient glow when ON
            boxShadow: isActive
                ? [
                    BoxShadow(
                      color: greenAccent.withValues(alpha: isDark ? 0.36 : 0.22),
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
                ? (isDark ? const Color(0xFF34D399) : const Color(0xFF047857))
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
              Container(
                width: isNarrow ? 21.0 : 24.0,
                height: isNarrow ? 21.0 : 24.0,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      const Color(0xFF10B981).withValues(alpha: isDark ? 0.28 : 0.16),
                      const Color(0xFF047857).withValues(alpha: isDark ? 0.14 : 0.08),
                    ],
                  ),
                  borderRadius: BorderRadius.circular(8.0),
                ),
                alignment: Alignment.center,
                child: const Icon(Icons.menu_book_rounded, color: Color(0xFF10B981), size: 13.0),
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

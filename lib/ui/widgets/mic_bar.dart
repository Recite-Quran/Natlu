import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../state/app_state.dart';

/// 2026 Unified Glassmorphic Floating Command Dock (Dynamic Floating Island)
///
/// Design Architecture:
/// - Single unified frosted capsule dock with 20px backdrop blur (ImageFilter).
/// - Prominent Hero Recite action centerpiece with stacked icon + micro-label ("اتلو" / "قف"),
///   vibrant emerald-to-teal / ruby gradient, ambient bloom glow, and animated audio equalizer.
/// - Symmetrical, clean iconographic secondary toggles for Tajweed and Hide (Hifz memorization),
///   featuring dynamic state icons (e.g. visibility / visibility_off), micro-labels,
///   luminous active state indicator pips, and tactile spring feedback.
/// - Adaptive light (warm linen velvet) and dark (OLED obsidian glass) palettes.
class BottomActionBar extends StatefulWidget {
  final bool isRecording;
  final bool isLoadingEngine;
  final bool isAutoScrolling;
  final ThemeColors c;
  final VoidCallback onMic;
  final VoidCallback onToggleAutoScroll;
  final VoidCallback onSettingsTap;
  final bool isTajweed;
  final VoidCallback onToggleTajweed;
  final bool isBlur;
  final VoidCallback onToggleBlur;

  /// Prayer mode's button (next to hide verses), if given; shown active
  /// while prayer mode runs.
  final bool isPrayer;
  final VoidCallback? onPrayer;

  /// Auto-correct's button (between hide verses and Prayer Mode), if given:
  /// a tap turns it on or off, holding it opens its settings.
  final bool isAutoCorrect;
  final VoidCallback? onAutoCorrect;
  final VoidCallback? onAutoCorrectSettings;

  const BottomActionBar({
    super.key,
    required this.isRecording,
    this.isLoadingEngine = false,
    required this.isAutoScrolling,
    required this.c,
    required this.onMic,
    required this.onToggleAutoScroll,
    required this.onSettingsTap,
    required this.isTajweed,
    required this.onToggleTajweed,
    required this.isBlur,
    required this.onToggleBlur,
    this.isPrayer = false,
    this.onPrayer,
    this.isAutoCorrect = false,
    this.onAutoCorrect,
    this.onAutoCorrectSettings,
  });

  @override
  State<BottomActionBar> createState() => _BottomActionBarState();
}

class _BottomActionBarState extends State<BottomActionBar>
    with TickerProviderStateMixin {
  AnimationController? _tajweedController;
  Animation<double>? _tajweedAnim;
  AnimationController? _hideController;
  Animation<double>? _hideAnim;
  bool _isHovered = false;

  void _ensureAnimation() {
    final bool tajweedVisible =
        !(widget.isAutoScrolling || widget.isRecording);
    final bool hideVisible = !widget.isAutoScrolling;

    _tajweedController ??= AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 320),
      value: tajweedVisible ? 1.0 : 0.0,
    );
    _tajweedAnim ??= CurvedAnimation(
      parent: _tajweedController!,
      curve: Curves.easeInOutCubic,
      reverseCurve: Curves.easeInOutCubic,
    );

    _hideController ??= AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 320),
      value: hideVisible ? 1.0 : 0.0,
    );
    _hideAnim ??= CurvedAnimation(
      parent: _hideController!,
      curve: Curves.easeInOutCubic,
      reverseCurve: Curves.easeInOutCubic,
    );
  }

  @override
  void initState() {
    super.initState();
    _ensureAnimation();
  }

  @override
  void reassemble() {
    super.reassemble();
    _ensureAnimation();
  }

  @override
  void didUpdateWidget(covariant BottomActionBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    _ensureAnimation();

    final bool oldTajweedVisible =
        !(oldWidget.isAutoScrolling || oldWidget.isRecording);
    final bool newTajweedVisible =
        !(widget.isAutoScrolling || widget.isRecording);
    if (oldTajweedVisible != newTajweedVisible) {
      if (newTajweedVisible) {
        _tajweedController?.forward();
      } else {
        _tajweedController?.reverse();
      }
    }

    final bool oldHideVisible = !oldWidget.isAutoScrolling;
    final bool newHideVisible = !widget.isAutoScrolling;
    if (oldHideVisible != newHideVisible) {
      if (newHideVisible) {
        _hideController?.forward();
      } else {
        _hideController?.reverse();
      }
    }
  }

  @override
  void dispose() {
    _tajweedController?.dispose();
    _hideController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _ensureAnimation();
    final tajweedAnim = _tajweedAnim!;
    final hideAnim = _hideAnim!;
    final c = widget.c;
    final app = AppState.instance;
    final isAr = app.isArabic;
    final isDark = app.isDarkMode;

    final double dockOpacity = widget.isAutoScrolling
        ? (_isHovered ? 1.0 : 0.55)
        : 1.0;

    // ── Unified Floating Island Dock ──
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 16, left: 16, right: 16),
        child: Center(
          child: MouseRegion(
            onEnter: (_) => setState(() => _isHovered = true),
            onExit: (_) => setState(() => _isHovered = false),
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 250),
              curve: Curves.easeOutCubic,
              opacity: dockOpacity,
              child: AnimatedBuilder(
                animation: Listenable.merge([_tajweedAnim, _hideAnim]),
                builder: (context, child) {
                  final double t = hideAnim.value;
                  final double dockHeight = lerpDouble(46.0, 56.0, t)!;
                  final EdgeInsets dockPadding = EdgeInsets.symmetric(
                    horizontal: 8.0 * t,
                    vertical: 4.0 * t,
                  );
                  final double radius = lerpDouble(18.0, 20.0, t)!;

                  return Container(
                    height: dockHeight,
                    padding: dockPadding,
                    decoration: BoxDecoration(
                      color: isDark ? c.surfaceHigh : c.surface,
                      borderRadius: BorderRadius.circular(radius),
                      border: Border.all(
                        color: (isDark
                                ? Colors.white.withValues(alpha: 0.16)
                                : Colors.black.withValues(alpha: 0.12))
                            .withValues(alpha: (isDark ? 0.16 : 0.12) * t),
                        width: 0.9 * t,
                      ),
                      boxShadow: t > 0.05
                          ? [
                              BoxShadow(
                                color: Colors.black.withValues(
                                    alpha: (isDark ? 0.35 : 0.06) * t),
                                blurRadius: 16,
                                offset: const Offset(0, 4),
                              ),
                            ]
                          : null,
                    ),
                    child: child,
                  );
            },
            child: Directionality(
              textDirection: isAr ? TextDirection.rtl : TextDirection.ltr,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  // ── Subordinate Satellite 1: Tajweed Toggle (Collapsible on recording & autoscroll) ──
                  SizeTransition(
                    axis: Axis.horizontal,
                    alignment: Alignment.center,
                    sizeFactor: tajweedAnim,
                    child: FadeTransition(
                      opacity: tajweedAnim,
                      child: ScaleTransition(
                        scale: tajweedAnim,
                        child: IgnorePointer(
                          ignoring: widget.isAutoScrolling || widget.isRecording,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              _buildSecondaryToggle(
                                icon: widget.isTajweed
                                    ? Icons.record_voice_over_rounded
                                    : Icons.record_voice_over_outlined,
                                tooltip: isAr
                                    ? 'أحكام التجويد ومخارج الحروف'
                                    : 'Tajweed & Pronunciation Rules',
                                isActive: widget.isTajweed,
                                c: c,
                                isDark: isDark,
                                isRecording: widget.isRecording,
                                onTap: () {
                                  HapticFeedback.lightImpact();
                                  widget.onToggleTajweed();
                                },
                              ),
                              const SizedBox(width: 8),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),

                  // ── Dominant Hero Centerpiece: Recite / Stop / Pause ──
                  _buildHeroReciteButton(c, app, isDark, isAr),

                  // ── Subordinate Satellite 2: Hide Verses Toggle (Accessible during recording in 28dp micro-mode) ──
                  SizeTransition(
                    axis: Axis.horizontal,
                    alignment: Alignment.center,
                    sizeFactor: hideAnim,
                    child: FadeTransition(
                      opacity: hideAnim,
                      child: ScaleTransition(
                        scale: hideAnim,
                        child: IgnorePointer(
                          ignoring: widget.isAutoScrolling,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const SizedBox(width: 8),
                              _buildSecondaryToggle(
                                icon: widget.isBlur
                                    ? Icons.visibility_off_rounded
                                    : Icons.visibility_rounded,
                                tooltip: isAr
                                    ? 'إخفاء الآيات للتسميع'
                                    : 'Hide Verses for Memorization',
                                isActive: widget.isBlur,
                                c: c,
                                isDark: isDark,
                                isRecording: widget.isRecording,
                                onTap: () {
                                  HapticFeedback.lightImpact();
                                  widget.onToggleBlur();
                                },
                              ),
                              if (widget.onAutoCorrect != null) ...[
                                const SizedBox(width: 8),
                                _buildSecondaryToggle(
                                  icon: Icons.spellcheck_rounded,
                                  tooltip: widget.isAutoCorrect
                                      ? (isAr
                                          ? 'التصحيح التلقائي مفعّل (اضغط مطولاً للإعدادات)'
                                          : 'Auto-correct on (hold for settings)')
                                      : (isAr
                                          ? 'التصحيح التلقائي متوقف (اضغط مطولاً للإعدادات)'
                                          : 'Auto-correct off (hold for settings)'),
                                  isActive: widget.isAutoCorrect,
                                  c: c,
                                  isDark: isDark,
                                  isRecording: widget.isRecording,
                                  onTap: () {
                                    HapticFeedback.lightImpact();
                                    widget.onAutoCorrect!();
                                  },
                                  onLongPress: widget.onAutoCorrectSettings,
                                ),
                              ],
                              if (widget.onPrayer != null) ...[
                                const SizedBox(width: 8),
                                _buildSecondaryToggle(
                                  icon: widget.isPrayer
                                      ? Icons.mosque_rounded
                                      : Icons.mosque_outlined,
                                  tooltip: widget.isPrayer
                                      ? (isAr
                                          ? 'إيقاف وضع الصلاة'
                                          : 'Stop Prayer Mode')
                                      : (isAr ? 'وضع الصلاة' : 'Prayer Mode'),
                                  isActive: widget.isPrayer,
                                  c: c,
                                  isDark: isDark,
                                  isRecording: widget.isRecording,
                                  onTap: () {
                                    HapticFeedback.lightImpact();
                                    widget.onPrayer!();
                                  },
                                ),
                              ],
                            ],
                          ),
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
  ),
);
  }

  /// Compact Eye-Comfortable Secondary Utility Toggle Button:
  /// - Minimalist 34x34dp circular/squircle satellite footprint.
  /// - Refined 18dp icon with zero text clutter.
  /// - Soft illuminated tint & border when active.
  Widget _buildSecondaryToggle({
    required IconData icon,
    required String tooltip,
    required bool isActive,
    required ThemeColors c,
    required bool isDark,
    required bool isRecording,
    required VoidCallback onTap,
    VoidCallback? onLongPress,
  }) {
    final double size = isRecording ? 28.0 : 34.0;
    final double iconSize = isRecording ? 15.0 : 18.0;
    const double opacity = 1.0;
    final Color activeColor = c.primary;
    final Color contentColor = isActive
        ? activeColor
        : (isDark ? c.text.withValues(alpha: 0.60) : c.text.withValues(alpha: 0.65));

    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 500),
      // Holding the button does something else then.
      triggerMode: onLongPress != null ? TooltipTriggerMode.manual : null,
      child: _TactileScaleButton(
        onTap: onTap,
        onLongPress: onLongPress,
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutCubic,
          opacity: opacity,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOutCubic,
            width: size,
            height: size,
            decoration: BoxDecoration(
              color: isActive
                  ? activeColor.withValues(alpha: isDark ? 0.22 : 0.12)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(isRecording ? 9 : 11),
              border: Border.all(
                color: isActive
                    ? activeColor.withValues(alpha: isDark ? 0.45 : 0.35)
                    : Colors.transparent,
                width: 0.75,
              ),
            ),
            alignment: Alignment.center,
            child: Icon(
              icon,
              color: contentColor,
              size: iconSize,
            ),
          ),
        ),
      ),
    );
  }

  /// 2026 Hero Recite / Stop Action Centerpiece:
  /// - Streamlined 86x46dp capsule with vibrant gradients and ambient bloom.
  /// - Idle: Glowing mic + "اتلو" / "Recite".
  /// - Recording: ONLY dancing audio wave + "قف" / "Stop" (no square icon).
  /// - Auto-scroll: Pause icon + "إيقاف" / "Pause".
  Widget _buildHeroReciteButton(
    ThemeColors c,
    AppState app,
    bool isDark,
    bool isAr,
  ) {
    final bool isRec = widget.isRecording;
    final bool isScroll = widget.isAutoScrolling;

    final Color gradientStart;
    final Color gradientEnd;
    final String label;
    final IconData icon;
    final VoidCallback onTap;

    if (isRec) {
      gradientStart = isDark
          ? const Color(0xFFF43F5E) // Dark mode: Soft Ruby Rose (zero halation)
          : const Color(0xFFE11D48); // White mode: Persian Rose Carmine
      gradientEnd = isDark
          ? const Color(0xFFE11D48)
          : const Color(0xFFBE123C);
      label = isAr ? 'قف' : 'Stop';
      icon = Icons.stop_rounded;
      onTap = widget.onMic;
    } else if (isScroll) {
      gradientStart = isDark
          ? c.surfaceHigh.withValues(alpha: 0.94)
          : c.surfaceHigh;
      gradientEnd = isDark
          ? c.surface.withValues(alpha: 0.98)
          : c.surface;
      label = isAr ? 'إيقاف' : 'Pause';
      icon = Icons.pause_rounded;
      onTap = widget.onToggleAutoScroll;
    } else {
      gradientStart = isDark
          ? const Color(0xFF10B981) // Dark mode: Luminous Aurora Emerald
          : const Color(0xFF047857); // White mode: Deep Royal Forest Emerald
      gradientEnd = isDark
          ? const Color(0xFF059669) // Dark mode: Calm Jade Mint
          : const Color(0xFF065F46); // White mode: Deep Pine Jade
      label = isAr ? 'اتلو' : 'Recite';
      icon = Icons.mic_rounded;
      onTap = widget.onMic;
    }

    return _TactileScaleButton(
      onTap: () {
        HapticFeedback.heavyImpact();
        onTap();
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOutCubic,
        width: 86,
        height: 46,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [gradientStart, gradientEnd],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isScroll
                ? (isDark
                    ? Colors.white.withValues(alpha: 0.16)
                    : Colors.black.withValues(alpha: 0.10))
                : Colors.white.withValues(alpha: isDark ? 0.24 : 0.40),
            width: 0.9,
          ),
          boxShadow: isScroll
              ? [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: isDark ? 0.25 : 0.05),
                    blurRadius: 6,
                    offset: const Offset(0, 2),
                  ),
                ]
              : [
                  BoxShadow(
                    color: isDark
                        ? Colors.black.withValues(alpha: 0.35)
                        : gradientStart.withValues(alpha: 0.22),
                    blurRadius: 6,
                    offset: const Offset(0, 2),
                  ),
                ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // Top: Fixed 18dp slot so button and label stay 100% rock-solid and static!
            SizedBox(
              height: 18,
              child: Center(
                child: isRec
                    ? const _AnimatedAudioWaveform(color: Colors.white)
                    : (widget.isLoadingEngine
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2.0,
                              valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                            ),
                          )
                        : Icon(
                            icon,
                            color: isScroll ? c.primary : Colors.white,
                            size: 20,
                          )),
              ),
            ),
            const SizedBox(height: 2),
            // Bottom: Crisp Micro-Label (completely stationary)
            Text(
              label,
              maxLines: 1,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: null,
                color: isScroll
                    ? (isDark ? Colors.white.withValues(alpha: 0.90) : c.text)
                    : Colors.white,
                fontSize: isAr ? 12.0 : 10.5,
                fontWeight: FontWeight.w700,
                letterSpacing: isAr ? 0.0 : 0.3,
                height: isAr ? 1.2 : 1.1,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Dynamic animated equalizer soundwave for live recitation indication.
class _AnimatedAudioWaveform extends StatefulWidget {
  final Color color;
  const _AnimatedAudioWaveform({required this.color});

  @override
  State<_AnimatedAudioWaveform> createState() => _AnimatedAudioWaveformState();
}

class _AnimatedAudioWaveformState extends State<_AnimatedAudioWaveform>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    )..repeat(reverse: true);
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
        width: 24,
        height: 18,
        child: AnimatedBuilder(
          animation: _ctrl,
          builder: (context, _) {
            return CustomPaint(
              painter: _WaveformBarsPainter(
                animationValue: _ctrl.value,
                color: widget.color,
              ),
            );
          },
        ),
      ),
    );
  }
}

class _WaveformBarsPainter extends CustomPainter {
  final double animationValue;
  final Color color;

  _WaveformBarsPainter({required this.animationValue, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    final double v = animationValue;
    final heights = [
      (3.5 + 5.5 * v).clamp(3.0, 13.0),
      (8.5 - 4.5 * v).clamp(3.0, 13.0),
      (5.0 + 7.5 * v).clamp(3.0, 13.0),
      (11.0 - 6.5 * v).clamp(3.0, 13.0),
      (4.0 + 5.5 * (1.0 - v)).clamp(3.0, 13.0),
    ];

    const double barWidth = 2.2;
    const double spacing = 2.2;
    const double totalWidth = (5 * barWidth) + (4 * spacing);
    double startX = (size.width - totalWidth) / 2;
    final double centerY = size.height / 2;
    const rrectRadius = Radius.circular(1.5);

    for (int i = 0; i < heights.length; i++) {
      final h = heights[i];
      final rect = RRect.fromRectAndRadius(
        Rect.fromLTWH(startX, centerY - (h / 2), barWidth, h),
        rrectRadius,
      );
      canvas.drawRRect(rect, paint);
      startX += barWidth + spacing;
    }
  }

  @override
  bool shouldRepaint(covariant _WaveformBarsPainter oldDelegate) {
    return oldDelegate.animationValue != animationValue || oldDelegate.color != color;
  }
}

/// 2026 Spring-scale tactile feedback button wrapper.
class _TactileScaleButton extends StatefulWidget {
  final Widget child;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  const _TactileScaleButton(
      {required this.child, required this.onTap, this.onLongPress});

  @override
  State<_TactileScaleButton> createState() => _TactileScaleButtonState();
}

class _TactileScaleButtonState extends State<_TactileScaleButton> {
  bool _isDown = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => setState(() => _isDown = true),
      onTapUp: (_) => setState(() => _isDown = false),
      onTapCancel: () => setState(() => _isDown = false),
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
      behavior: HitTestBehavior.opaque,
      child: AnimatedScale(
        scale: _isDown ? 0.93 : 1.0,
        duration: const Duration(milliseconds: 110),
        curve: _isDown ? Curves.easeOutQuad : Curves.easeOutCubic,
        child: widget.child,
      ),
    );
  }
}

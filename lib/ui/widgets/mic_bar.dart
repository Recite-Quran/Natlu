import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../state/app_state.dart';

/// 2026 Unified Glassmorphic Floating Command Dock
///
/// Responsive single-toolbar design (Right-to-Left):
/// [Record (Tarteel-AI Squircle)] -> [Hide Verses] -> [Tajweed] -> [Auto Search] -> [Surah Selector] -> [Settings]
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
  final bool isVoiceSearching;
  final VoidCallback onVoiceSearchToggle;
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
    required this.isVoiceSearching,
    required this.onVoiceSearchToggle,
    required this.onSettingsTap,
  });

  @override
  Widget build(BuildContext context) {
    final app = AppState.instance;
    final bool isDark = app.isDarkMode;
    final bool isAr = app.isArabic;

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 14.0, left: 12.0, right: 12.0),
        child: Center(
          child: Container(
            constraints: const BoxConstraints(maxWidth: 520.0),
            height: 56.0,
            padding: const EdgeInsets.symmetric(horizontal: 7.0, vertical: 5.0),
            decoration: BoxDecoration(
              color: isDark ? c.surfaceHigh : c.surface,
              borderRadius: BorderRadius.circular(20.0),
              border: Border.all(
                color: isDark
                    ? Colors.white.withValues(alpha: 0.15)
                    : Colors.black.withValues(alpha: 0.12),
                width: 0.9,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: isDark ? 0.35 : 0.07),
                  blurRadius: 16,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final bool isNarrow = constraints.maxWidth < 345.0;
                final double btnSize = isNarrow ? 32.0 : 36.0;
                final double iconSize = isNarrow ? 16.0 : 18.0;
                final double gap = isNarrow ? 3.0 : 5.0;

                return Directionality(
                  // Enforce RTL: Record on the right, Settings on the left
                  textDirection: TextDirection.rtl,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      // 1. Squared rounded Tarteel AI like Record Button (Rightmost)
                      _buildTarteelRecordButton(isDark, isNarrow),
                      SizedBox(width: gap),

                      // 2. Hide Verses Button
                      _buildDockButton(
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

                      // 3. Tajweed Button
                      _buildDockButton(
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

                      // 4. Auto Search Button (Voice Search - beside Tajweed at its left)
                      _buildDockButton(
                        icon: Icons.graphic_eq_rounded,
                        tooltip: isAr ? 'بحث صوتي' : 'Voice Search',
                        isActive: isVoiceSearching,
                        isDark: isDark,
                        size: btnSize,
                        iconSize: iconSize,
                        onTap: onVoiceSearchToggle,
                      ),
                      SizedBox(width: gap),

                      // 5. Surah Selector Button (Expanded Center Pill)
                      Expanded(
                        child: _buildSurahSelector(
                          isDark,
                          isAr,
                          isNarrow,
                        ),
                      ),
                      SizedBox(width: gap),

                      // 6. Settings Button (Leftmost)
                      _buildDockButton(
                        icon: Icons.settings_rounded,
                        tooltip: isAr ? 'الإعدادات' : 'Settings',
                        isActive: false,
                        isDark: isDark,
                        size: btnSize,
                        iconSize: iconSize,
                        onTap: onSettingsTap,
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  /// Squared rounded Tarteel AI like Record Button:
  /// - Squircle shape with vibrant Emerald (idle) or Ruby (recording) gradient
  /// - Integrated animated soundwave / stop equalizer while recording
  Widget _buildTarteelRecordButton(bool isDark, bool isNarrow) {
    final double size = isNarrow ? 40.0 : 44.0;
    final List<Color> colors = isRecording
        ? (isDark
            ? const [Color(0xFFF43F5E), Color(0xFFE11D48)]
            : const [Color(0xFFE11D48), Color(0xFFBE123C)])
        : (isDark
            ? const [Color(0xFF10B981), Color(0xFF059669)]
            : const [Color(0xFF059669), Color(0xFF047857)]);

    return _TactileScaleButton(
      onTap: () {
        HapticFeedback.heavyImpact();
        onMic();
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        width: size,
        height: size,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: colors,
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(isNarrow ? 12.0 : 14.0),
          border: Border.all(
            color: Colors.white.withValues(alpha: isDark ? 0.28 : 0.40),
            width: 0.9,
          ),
          boxShadow: [
            BoxShadow(
              color: colors.first.withValues(alpha: isDark ? 0.35 : 0.25),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        alignment: Alignment.center,
        child: isLoadingEngine
            ? const SizedBox(
                width: 17,
                height: 17,
                child: CircularProgressIndicator(
                  strokeWidth: 2.2,
                  valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                ),
              )
            : (isRecording
                ? const _AnimatedAudioWaveform(color: Colors.white)
                : Icon(
                    Icons.mic_rounded,
                    color: Colors.white,
                    size: isNarrow ? 20.0 : 22.0,
                  )),
      ),
    );
  }

  /// Standardized satellite button for Hide, Tajweed, Auto-Search, and Settings.
  Widget _buildDockButton({
    required IconData icon,
    required String tooltip,
    required bool isActive,
    required bool isDark,
    required double size,
    required double iconSize,
    required VoidCallback onTap,
  }) {
    final Color activeColor = c.primary;
    final Color iconColor = isActive
        ? activeColor
        : (isDark
            ? c.text.withValues(alpha: 0.65)
            : c.text.withValues(alpha: 0.70));

    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 400),
      child: _TactileScaleButton(
        onTap: () {
          HapticFeedback.lightImpact();
          onTap();
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutCubic,
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: isActive
                ? activeColor.withValues(alpha: isDark ? 0.22 : 0.12)
                : (isDark
                    ? Colors.white.withValues(alpha: 0.05)
                    : Colors.black.withValues(alpha: 0.03)),
            borderRadius: BorderRadius.circular(isDark ? 10.0 : 11.0),
            border: Border.all(
              color: isActive
                  ? activeColor.withValues(alpha: isDark ? 0.50 : 0.38)
                  : (isDark
                      ? Colors.white.withValues(alpha: 0.08)
                      : Colors.black.withValues(alpha: 0.05)),
              width: 0.8,
            ),
            boxShadow: isActive
                ? [
                    BoxShadow(
                      color: activeColor.withValues(alpha: isDark ? 0.28 : 0.15),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    ),
                  ]
                : null,
          ),
          alignment: Alignment.center,
          child: Icon(
            icon,
            color: iconColor,
            size: iconSize,
          ),
        ),
      ),
    );
  }

  /// Surah Selector Capsule placed in the middle.
  Widget _buildSurahSelector(
    bool isDark,
    bool isAr,
    bool isNarrow,
  ) {
    return Tooltip(
      message: isAr ? 'اختيار السورة' : 'Select Surah',
      waitDuration: const Duration(milliseconds: 400),
      child: _TactileScaleButton(
        onTap: () {
          HapticFeedback.lightImpact();
          onSurahTap();
        },
        child: Container(
          height: isNarrow ? 34.0 : 38.0,
          padding: EdgeInsets.symmetric(horizontal: isNarrow ? 5.0 : 7.0),
          decoration: BoxDecoration(
            color: isDark
                ? Colors.white.withValues(alpha: 0.06)
                : c.surfaceHigh.withValues(alpha: 0.90),
            borderRadius: BorderRadius.circular(11.0),
            border: Border.all(
              color: isDark
                  ? Colors.white.withValues(alpha: 0.10)
                  : c.border.withValues(alpha: 0.55),
              width: 0.8,
            ),
          ),
          child: Row(
            children: [
              // Mini Quran Icon Badge
              Container(
                width: isNarrow ? 20.0 : 23.0,
                height: isNarrow ? 20.0 : 23.0,
                decoration: BoxDecoration(
                  color: c.primary.withValues(alpha: isDark ? 0.18 : 0.10),
                  borderRadius: BorderRadius.circular(7.0),
                ),
                alignment: Alignment.center,
                child: Icon(
                  Icons.menu_book_rounded,
                  color: c.primary,
                  size: isNarrow ? 11.0 : 13.0,
                ),
              ),
              SizedBox(width: isNarrow ? 4.0 : 6.0),
              // Surah Name
              Expanded(
                child: Text(
                  surahName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: c.text,
                    fontSize: isNarrow ? 12.0 : (isAr ? 14.0 : 12.5),
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              SizedBox(width: isNarrow ? 2.0 : 4.0),
              Icon(
                Icons.keyboard_arrow_down_rounded,
                color: c.textSecondary.withValues(alpha: 0.65),
                size: isNarrow ? 14.0 : 16.0,
              ),
            ],
          ),
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
        width: 22,
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

    const double barWidth = 2.0;
    const double spacing = 2.0;
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
    return oldDelegate.animationValue != animationValue ||
        oldDelegate.color != color;
  }
}

/// Spring-scale tactile feedback button wrapper.
class _TactileScaleButton extends StatefulWidget {
  final Widget child;
  final VoidCallback onTap;
  const _TactileScaleButton({required this.child, required this.onTap});

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
      behavior: HitTestBehavior.opaque,
      child: AnimatedScale(
        scale: _isDown ? 0.92 : 1.0,
        duration: const Duration(milliseconds: 100),
        curve: _isDown ? Curves.easeOutQuad : Curves.easeOutCubic,
        child: widget.child,
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../state/app_state.dart';

/// 2026 Modern Auto-Scroll Speed Dialog matching the app's frosted glassmorphism & tactile design system.
class SpeedSelectionDialog extends StatefulWidget {
  final VoidCallback onSpeedSelected;

  const SpeedSelectionDialog({super.key, required this.onSpeedSelected});

  @override
  State<SpeedSelectionDialog> createState() => _SpeedSelectionDialogState();
}

class _SpeedSelectionDialogState extends State<SpeedSelectionDialog> {
  int? _selectedIndex;

  void _selectSpeed(AppState app, int speedIndex) {
    HapticFeedback.lightImpact();
    setState(() => _selectedIndex = speedIndex);
    app.setAutoScrollSpeed(speedIndex);
    Future.delayed(const Duration(milliseconds: 100), widget.onSpeedSelected);
  }

  @override
  Widget build(BuildContext context) {
    final app = AppState.instance;
    return RepaintBoundary(
      child: ListenableBuilder(
        listenable: app,
        builder: (context, _) {
          final c = app.colors;
          final isAr = app.isArabic;
          final isDark = app.isDarkMode;

          return Directionality(
            textDirection: isAr ? TextDirection.rtl : TextDirection.ltr,
            child: Dialog(
              backgroundColor: Colors.transparent,
              elevation: 0,
              insetPadding: const EdgeInsets.symmetric(horizontal: 24),
              child: Container(
                constraints: const BoxConstraints(maxWidth: 340),
                decoration: BoxDecoration(
                  color: c.surface,
                  borderRadius: BorderRadius.circular(26),
                  border: Border.all(
                    color: isDark
                        ? Colors.white.withValues(alpha: 0.12)
                        : c.border.withValues(alpha: 0.50),
                    width: 1,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: isDark ? 0.35 : 0.08),
                      blurRadius: 16,
                      offset: const Offset(0, 6),
                    ),
                  ],
                ),
                padding: const EdgeInsets.symmetric(vertical: 22, horizontal: 18),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // ── Top Icon Badge ──
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: c.primary.withValues(alpha: isDark ? 0.18 : 0.10),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: c.primary.withValues(alpha: 0.25),
                        width: 1,
                      ),
                    ),
                    alignment: Alignment.center,
                    child: Icon(
                      Icons.speed_rounded,
                      color: c.primary,
                      size: 24,
                    ),
                  ),
                  const SizedBox(height: 12),

                  // ── Dialog Title ──
                  Text(
                    isAr ? 'سرعة التمرير التلقائي' : 'Auto-Scroll Speed',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: c.text,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      letterSpacing: isAr ? 0.0 : -0.3,
                      height: isAr ? 1.3 : 1.2,
                    ),
                  ),
                  const SizedBox(height: 10),

                  // ── Settings Reminder Banner ──
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                    decoration: BoxDecoration(
                      color: isDark
                          ? Colors.white.withValues(alpha: 0.05)
                          : c.surfaceHigh.withValues(alpha: 0.85),
                      borderRadius: BorderRadius.circular(13),
                      border: Border.all(
                        color: c.primary.withValues(alpha: 0.20),
                        width: 0.8,
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.tune_rounded,
                          color: c.primary,
                          size: 16,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            isAr
                                ? 'يمكنك ضبط وتغيير السرعة لاحقاً من الإعدادات'
                                : 'You can adjust speed anytime in settings',
                            style: TextStyle(
                              color: c.primary,
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600,
                              height: 1.3,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),

                  // ── Speed Options (Slow, Normal, Fast) ──
                  _ModernSpeedTile(
                    title: isAr ? 'بطيء' : 'Slow',
                    speedBadge: '0.5x',
                    isSelected: _selectedIndex == 1 || (_selectedIndex == null && app.autoScrollSpeed == 1),
                    c: c,
                    isDark: isDark,
                    onTap: () => _selectSpeed(app, 1),
                  ),
                  const SizedBox(height: 8),

                  _ModernSpeedTile(
                    title: isAr ? 'عادي' : 'Normal',
                    speedBadge: '1.0x',
                    isSelected: _selectedIndex == 2 || (_selectedIndex == null && app.autoScrollSpeed == 2),
                    c: c,
                    isDark: isDark,
                    onTap: () => _selectSpeed(app, 2),
                  ),
                  const SizedBox(height: 8),

                  _ModernSpeedTile(
                    title: isAr ? 'سريع' : 'Fast',
                    speedBadge: '2.0x',
                    isSelected: _selectedIndex == 4 || (_selectedIndex == null && app.autoScrollSpeed == 4),
                    c: c,
                    isDark: isDark,
                    onTap: () => _selectSpeed(app, 4),
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
}

/// Modern interactive speed option tile with speed pill and spring press feedback.
class _ModernSpeedTile extends StatelessWidget {
  final String title;
  final String speedBadge;
  final bool isSelected;
  final ThemeColors c;
  final bool isDark;
  final VoidCallback onTap;

  const _ModernSpeedTile({
    required this.title,
    required this.speedBadge,
    required this.isSelected,
    required this.c,
    required this.isDark,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return _TactileScaleWrapper(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        height: 48,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          color: isSelected
              ? c.primary.withValues(alpha: isDark ? 0.16 : 0.08)
              : (isDark ? Colors.white.withValues(alpha: 0.04) : c.surfaceHigh),
          borderRadius: BorderRadius.circular(15),
          border: Border.all(
            color: isSelected
                ? c.primary
                : (isDark ? Colors.white.withValues(alpha: 0.08) : c.border.withValues(alpha: 0.55)),
            width: isSelected ? 1.5 : 0.9,
          ),
          boxShadow: isSelected
              ? [
                  BoxShadow(
                    color: c.primary.withValues(alpha: 0.16),
                    blurRadius: 10,
                    offset: const Offset(0, 3),
                  ),
                ]
              : [],
        ),
        child: Row(
          children: [

            // Speed Title
            Expanded(
              child: Text(
                title,
                style: TextStyle(
                  color: isSelected ? c.primary : c.text,
                  fontSize: 15,
                  fontWeight: isSelected ? FontWeight.bold : FontWeight.w600,
                ),
              ),
            ),

            // Speed Multiplier Pill
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: isSelected
                    ? c.primary.withValues(alpha: 0.18)
                    : (isDark ? Colors.white.withValues(alpha: 0.06) : c.border.withValues(alpha: 0.35)),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                speedBadge,
                style: TextStyle(
                  color: isSelected ? c.primary : c.textSecondary,
                  fontSize: 11.5,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),

            if (isSelected) ...[
              const SizedBox(width: 8),
              Icon(
                Icons.check_circle_rounded,
                color: c.primary,
                size: 18,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 2026 Spring-scale tactile feedback button wrapper matching the app's interaction physics.
class _TactileScaleWrapper extends StatefulWidget {
  final Widget child;
  final VoidCallback onTap;

  const _TactileScaleWrapper({required this.child, required this.onTap});

  @override
  State<_TactileScaleWrapper> createState() => _TactileScaleWrapperState();
}

class _TactileScaleWrapperState extends State<_TactileScaleWrapper> {
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
        scale: _isDown ? 0.96 : 1.0,
        duration: const Duration(milliseconds: 120),
        curve: _isDown ? Curves.easeOutQuad : Curves.easeOutBack,
        child: widget.child,
      ),
    );
  }
}

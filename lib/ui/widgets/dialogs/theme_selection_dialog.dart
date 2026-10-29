import 'package:flutter/material.dart';
import '../../../state/app_state.dart';

class ThemeSelectionDialog extends StatefulWidget {
  final VoidCallback onThemeSelected;

  const ThemeSelectionDialog({super.key, required this.onThemeSelected});

  @override
  State<ThemeSelectionDialog> createState() => _ThemeSelectionDialogState();
}

class _ThemeSelectionDialogState extends State<ThemeSelectionDialog> {
  int? _selectedIndex;

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

          return Dialog(
            backgroundColor: Colors.transparent,
            insetPadding: const EdgeInsets.symmetric(horizontal: 32),
            child: Container(
              decoration: BoxDecoration(
                color: c.surface,
                borderRadius: BorderRadius.circular(24),
                border: Border.all(
                  color: c.border.withValues(alpha: 0.25),
                  width: 1,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: isDark ? 0.35 : 0.10),
                    blurRadius: 16,
                    offset: const Offset(0, 6),
                  ),
                ],
              ),
              padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    isAr ? 'اختر مظهر التطبيق' : 'Choose App Theme',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: c.text,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      letterSpacing: isAr ? 0.0 : -0.3,
                      height: isAr ? 1.3 : 1.2,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: c.primary.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      isAr
                          ? 'يمكنك تغيير المظهر لاحقاً من الإعدادات'
                          : 'You can change this later in settings',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: c.primary,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        height: 1.4,
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  Wrap(
                    alignment: WrapAlignment.center,
                    spacing: 36,
                    runSpacing: 18,
                    children: [
                      _ThemeSwatch(
                        title: isAr ? 'أبيض' : 'White',
                        color: const Color(0xFFFAF8F5),
                        isSelected: _selectedIndex == 0 || (_selectedIndex == null && app.theme == AppTheme.white),
                        c: c,
                        onTap: () {
                          setState(() => _selectedIndex = 0);
                          app.setTheme(AppTheme.white);
                          Future.delayed(const Duration(milliseconds: 150), widget.onThemeSelected);
                        },
                      ),
                      _ThemeSwatch(
                        title: isAr ? 'أسود' : 'Black',
                        color: const Color(0xFF000000),
                        isSelected: _selectedIndex == 1 || (_selectedIndex == null && app.theme == AppTheme.black),
                        c: c,
                        onTap: () {
                          setState(() => _selectedIndex = 1);
                          app.setTheme(AppTheme.black);
                          Future.delayed(const Duration(milliseconds: 150), widget.onThemeSelected);
                        },
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _ThemeSwatch extends StatefulWidget {
  final String title;
  final Color color;
  final bool isSelected;
  final ThemeColors c;
  final VoidCallback onTap;

  const _ThemeSwatch({
    required this.title,
    required this.color,
    required this.isSelected,
    required this.c,
    required this.onTap,
  });

  @override
  State<_ThemeSwatch> createState() => _ThemeSwatchState();
}

class _ThemeSwatchState extends State<_ThemeSwatch> with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _scaleAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 150),
    );
    _scaleAnimation = Tween<double>(begin: 1.0, end: 0.9).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => _controller.forward(),
      onTapUp: (_) {
        _controller.reverse();
        widget.onTap();
      },
      onTapCancel: () => _controller.reverse(),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ScaleTransition(
            scale: _scaleAnimation,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeOut,
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: widget.color,
                shape: BoxShape.circle,
                border: Border.all(
                  color: widget.isSelected ? widget.c.primary : widget.c.border,
                  width: widget.isSelected ? 3 : 1.5,
                ),
                boxShadow: widget.isSelected
                    ? [
                        BoxShadow(
                          color: widget.c.primary.withValues(alpha: 0.3),
                          blurRadius: 15,
                          offset: const Offset(0, 4),
                        )
                      ]
                    : [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.1),
                          blurRadius: 8,
                          offset: const Offset(0, 4),
                        )
                      ],
              ),
              child: widget.isSelected
                  ? Center(
                      child: Container(
                        padding: const EdgeInsets.all(4),
                        decoration: BoxDecoration(
                          color: widget.c.primary,
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.check_rounded,
                          color: Colors.white,
                          size: 18,
                        ),
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            widget.title,
            style: TextStyle(
              color: widget.isSelected ? widget.c.primary : widget.c.muted,
              fontSize: 15,
              fontWeight: widget.isSelected ? FontWeight.bold : FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

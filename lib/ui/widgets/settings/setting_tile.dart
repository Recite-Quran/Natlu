import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../state/app_state.dart';

/// Thin flush separator line for grouped lists.
class PremiumSettingDivider extends StatelessWidget {
  final ThemeColors c;
  const PremiumSettingDivider({super.key, required this.c});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 1,
      margin: const EdgeInsetsDirectional.only(start: 56, end: 16), // Flush with text, not icon
      color: c.border.withValues(alpha: 0.25),
    );
  }
}

/// A unified minimalist setting tile that handles both row-based and column-based layouts.
class SettingTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final ThemeColors c;
  final Widget? trailing;
  final Widget? bottom;
  final Widget? badge;

  final double? trailingWidth;

  const SettingTile({
    super.key,
    required this.icon,
    required this.title,
    required this.c,
    this.trailing,
    this.bottom,
    this.badge,
    this.trailingWidth,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsetsDirectional.symmetric(horizontal: 16, vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: c.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: c.primary.withValues(alpha: 0.20),
                    width: 1,
                  ),
                ),
                child: Icon(icon, color: c.primary, size: 20),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: AlignmentDirectional.centerStart,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        style: TextStyle(
                          color: c.text,
                          fontSize: 16.5,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 0.1,
                        ),
                      ),
                      if (badge != null) ...[
                        const SizedBox(width: 6),
                        badge!,
                      ],
                    ],
                  ),
                ),
              ),
              if (trailing != null) ...[
                const SizedBox(width: 12),
                if (trailingWidth != null)
                  SizedBox(width: trailingWidth, child: trailing!)
                else if (trailing is PremiumPillSelector)
                  SizedBox(width: 122, child: trailing!)
                else if (trailing is Row)
                  SizedBox(width: 130, child: trailing!)
                else
                  trailing!,
              ],
            ],
          ),
          if (bottom != null) ...[
            const SizedBox(height: 14),
            bottom!,
          ],
        ],
      ),
    );
  }
}

/// Ultra-smooth premium segmented selector with drop shadows.
class PremiumPillSelector extends StatelessWidget {
  final List<String> labels;
  final List<IconData>? icons;
  final int selected;
  final ThemeColors c;
  final ValueChanged<int> onSelected;

  final double height;

  const PremiumPillSelector({
    super.key,
    required this.labels,
    this.icons,
    required this.selected,
    required this.c,
    required this.onSelected,
    this.height = 38.0,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: height,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: c.surfaceHigh,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: c.border.withValues(alpha: 0.4),
          width: 1,
        ),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final pillWidth = constraints.maxWidth / labels.length;
          
          return Stack(
            children: [
              // Animated Background Pill
              AnimatedPositioned(
                duration: const Duration(milliseconds: 250),
                curve: Curves.easeOutCubic,
                left: Directionality.of(context) == TextDirection.ltr
                    ? selected * pillWidth
                    : (labels.length - 1 - selected) * pillWidth,
                top: 0,
                bottom: 0,
                width: pillWidth,
                child: Container(
                  decoration: BoxDecoration(
                    color: c.surface,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: c.border.withValues(alpha: 0.6),
                      width: 1,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.08),
                        blurRadius: 6,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                ),
              ),
              // Content (Icons + Text Labels)
              Row(
                children: List.generate(labels.length, (i) {
                  final isSel = i == selected;
                  return Expanded(
                    child: GestureDetector(
                      onTap: () {
                        HapticFeedback.lightImpact();
                        onSelected(i);
                      },
                      behavior: HitTestBehavior.opaque,
                      child: Center(
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            if (icons != null && i < icons!.length) ...[
                              Icon(
                                icons![i],
                                size: 16,
                                color: isSel ? c.primary : c.textSecondary,
                              ),
                              const SizedBox(width: 6),
                            ],
                            AnimatedDefaultTextStyle(
                              duration: const Duration(milliseconds: 200),
                              style: TextStyle(
                                color: isSel ? c.primary : c.textSecondary,
                                fontSize: 13,
                                fontWeight: isSel ? FontWeight.w700 : FontWeight.w500,
                              ),
                              child: Text(labels[i]),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                }),
              ),
            ],
          );
        }
      ),
    );
  }
}

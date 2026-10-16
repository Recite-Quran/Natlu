import 'package:flutter/material.dart';

import '../../state/app_state.dart';

/// A bottom sheet's frame: rounded top, drag handle, scrolling content.
class SheetFrame extends StatelessWidget {
  const SheetFrame({super.key, required this.c, required this.children});

  final ThemeColors c;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.9,
      ),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 44,
                  height: 4,
                  decoration: BoxDecoration(
                    color: c.border.withValues(alpha: 0.6),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              ...children,
            ],
          ),
        ),
      ),
    );
  }
}

/// A sheet's title with its icon.
class SheetTitle extends StatelessWidget {
  const SheetTitle(
      {super.key, required this.icon, required this.title, required this.c});

  final IconData icon;
  final String title;
  final ThemeColors c;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, color: c.primary),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            title,
            style: TextStyle(
              color: c.text,
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ],
    );
  }
}

/// A labelled switch.
class SheetToggle extends StatelessWidget {
  const SheetToggle({
    super.key,
    required this.label,
    this.subtitle,
    required this.value,
    required this.c,
    required this.onChanged,
  });

  final String label;
  final String? subtitle;
  final bool value;
  final ThemeColors c;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: TextStyle(color: c.text, fontSize: 14)),
                if (subtitle != null)
                  Text(subtitle!,
                      style: TextStyle(color: c.textSecondary, fontSize: 12)),
              ],
            ),
          ),
          Switch(
            value: value,
            activeThumbColor: Colors.white,
            activeTrackColor: c.primary,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}

/// A labelled value with − and + buttons.
class SheetStepper extends StatelessWidget {
  const SheetStepper({
    super.key,
    required this.label,
    required this.value,
    required this.c,
    required this.onMinus,
    required this.onPlus,
  });

  final String label;
  final String value;
  final ThemeColors c;
  final VoidCallback? onMinus;
  final VoidCallback? onPlus;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(
            child: Text(label, style: TextStyle(color: c.text, fontSize: 14)),
          ),
          IconButton(
            onPressed: onMinus,
            icon: const Icon(Icons.remove_circle_outline_rounded),
            color: c.primary,
            tooltip: '−',
          ),
          SizedBox(
            width: 64,
            child: Text(
              value,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: c.text,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          IconButton(
            onPressed: onPlus,
            icon: const Icon(Icons.add_circle_outline_rounded),
            color: c.primary,
            tooltip: '+',
          ),
        ],
      ),
    );
  }
}

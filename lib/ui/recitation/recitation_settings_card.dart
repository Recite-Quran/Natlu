import 'package:flutter/material.dart';

import '../../services/recitation/auto_correct_settings.dart';
import '../../state/app_state.dart';
import '../widgets/settings/setting_tile.dart';
import 'auto_correct_sheet.dart';

/// The settings dialog's card for recitation features: auto-correct.
class RecitationSettingsCard extends StatelessWidget {
  const RecitationSettingsCard({super.key});

  @override
  Widget build(BuildContext context) {
    final app = AppState.instance;
    final settings = AutoCorrectSettings.instance;
    settings.load();
    return ListenableBuilder(
      listenable: Listenable.merge([app, settings]),
      builder: (context, _) {
        final c = app.colors;
        final ar = app.isArabic;
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Container(
            decoration: BoxDecoration(
              color: c.surfaceHigh,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: c.border.withValues(alpha: 0.5)),
              boxShadow: [
                BoxShadow(
                  color: Colors.black
                      .withValues(alpha: app.isDarkMode ? 0.20 : 0.03),
                  blurRadius: 10,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(20),
                onTap: () => showAutoCorrectSheet(context),
                child: SettingTile(
                  icon: autoCorrectIcon,
                  title: ar ? 'التصحيح التلقائي' : 'Auto-correct',
                  c: c,
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        settings.enabled
                            ? (ar ? 'مفعّل' : 'On')
                            : (ar ? 'متوقف' : 'Off'),
                        style: TextStyle(color: c.textSecondary, fontSize: 13),
                      ),
                      Icon(
                        ar
                            ? Icons.chevron_left_rounded
                            : Icons.chevron_right_rounded,
                        color: c.textSecondary,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

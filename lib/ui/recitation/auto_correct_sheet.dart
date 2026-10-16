import 'package:flutter/material.dart';

import '../../services/recitation/auto_correct_settings.dart';
import '../../state/app_state.dart';
import '../prayer/prayer_event_text.dart' show localizedNumber;
import 'sheet_controls.dart';

/// Auto-correct's icon, on and off.
const IconData autoCorrectIcon = Icons.spellcheck_rounded;

/// Shows the auto-correct sheet.
Future<void> showAutoCorrectSheet(BuildContext context) => showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const AutoCorrectSheet(),
    );

/// Explains auto-correct, turns it on or off, and tunes it: its timings and
/// how many words it reads.
class AutoCorrectSheet extends StatefulWidget {
  const AutoCorrectSheet({super.key});

  @override
  State<AutoCorrectSheet> createState() => _AutoCorrectSheetState();
}

class _AutoCorrectSheetState extends State<AutoCorrectSheet> {
  final AutoCorrectSettings _settings = AutoCorrectSettings.instance;

  @override
  void initState() {
    super.initState();
    _settings.load();
  }

  String _label(AutoCorrectSetting s, bool ar) => switch (s.key) {
        'prayer_pause_mid_ayah' =>
          ar ? 'تذكير بعد توقف وسط الآية' : 'Prompt after a pause mid-ayah',
        'prayer_pause_between_ayahs' => ar
            ? 'تذكير بعد توقف بين آيتين'
            : 'Prompt after a pause between ayahs',
        'prayer_correction_time' =>
          ar ? 'مهلة التصحيح بعد الخطأ' : 'Time to correct a mistake',
        _ => ar ? 'عدد الكلمات المقروءة' : 'Words read in a prompt',
      };

  String _value(AutoCorrectSetting s, int v, bool ar) {
    final n = localizedNumber(v, ar);
    if (s.key == AutoCorrectSettings.promptWords.key) {
      return ar ? n : (v == 1 ? '1 word' : '$v words');
    }
    return ar ? '$n ث' : '$v s';
  }

  @override
  Widget build(BuildContext context) {
    final app = AppState.instance;
    return ListenableBuilder(
      listenable: Listenable.merge([app, _settings]),
      builder: (context, _) {
        final c = app.colors;
        final ar = app.isArabic;
        return Directionality(
          textDirection: ar ? TextDirection.rtl : TextDirection.ltr,
          child: SheetFrame(
            c: c,
            children: [
              SheetTitle(
                icon: autoCorrectIcon,
                title: ar ? 'التصحيح التلقائي' : 'Auto-correct',
                c: c,
              ),
              const SizedBox(height: 10),
              Text(
                ar
                    ? 'أثناء تلاوتك يُصدر تنبيهاً عند الخطأ، وإن لم تصحّحه، أو توقفت طويلاً، يقرأ الكلمة الصحيحة بصوت الحصري. يتابعك حيثما تتابعك القراءة.'
                    : 'While you recite, it beeps at a mistake and, if you don\'t correct it or you pause too long, reads the right words aloud (al-Ḥuṣarī). It follows you wherever the tracker does.',
                style: TextStyle(
                    color: c.textSecondary, fontSize: 13.5, height: 1.5),
              ),
              const SizedBox(height: 8),
              SheetToggle(
                label: ar ? 'التصحيح التلقائي' : 'Auto-correct',
                value: _settings.enabled,
                c: c,
                onChanged: _settings.setEnabled,
              ),
              for (final s in AutoCorrectSettings.all)
                SheetStepper(
                  label: _label(s, ar),
                  value: _value(s, _settings[s], ar),
                  c: c,
                  onMinus: _settings[s] > s.min
                      ? () => _settings.set(s, _settings[s] - 1)
                      : null,
                  onPlus: _settings[s] < s.max
                      ? () => _settings.set(s, _settings[s] + 1)
                      : null,
                ),
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: TextButton(
                  onPressed: _settings.resetTimings,
                  child: Text(
                    ar ? 'القيم الافتراضية' : 'Defaults',
                    style: TextStyle(color: c.textSecondary),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

import 'package:flutter/material.dart';

import '../../services/recitation/auto_correct_settings.dart';
import '../../state/app_state.dart';
import '../recitation/auto_correct_sheet.dart';
import '../recitation/sheet_controls.dart';

/// Explains prayer mode, shows where it will start, lets auto-correct be
/// turned on or off for it, and starts it.
class PrayerStartSheet extends StatefulWidget {
  const PrayerStartSheet({
    super.key,
    required this.startText,
    required this.onStart,
  });

  /// Where the plan starts, e.g. "Al-Baqarah 6".
  final String startText;
  final VoidCallback onStart;

  @override
  State<PrayerStartSheet> createState() => _PrayerStartSheetState();
}

class _PrayerStartSheetState extends State<PrayerStartSheet> {
  final AutoCorrectSettings _settings = AutoCorrectSettings.instance;

  @override
  void initState() {
    super.initState();
    _settings.load();
  }

  @override
  Widget build(BuildContext context) {
    final app = AppState.instance;
    return ListenableBuilder(
      listenable: Listenable.merge([app, _settings]),
      builder: (context, _) {
        final c = app.colors;
        final ar = app.isArabic;
        final corrects = _settings.enabled;
        return Directionality(
          textDirection: ar ? TextDirection.rtl : TextDirection.ltr,
          child: SheetFrame(
            c: c,
            children: [
              SheetTitle(
                icon: Icons.mosque_rounded,
                title: ar ? 'وضع الصلاة' : 'Prayer Mode',
                c: c,
              ),
              const SizedBox(height: 10),
              Text(
                ar
                    ? 'يتابع تلاوتك في الصلاة تلاوةً متصلة: يبدأ المتابعة بعد سماع نهاية الفاتحة، ويتوقف عند «الله أكبر»، ثم يكمل من حيث توقف بعد الفاتحة التالية.'
                    : 'Follows your recitation through the prayer as one continuous plan: it starts following once it hears the end of al-Fātiḥa, stops at "Allāhu akbar", and carries on from where it stopped after the next al-Fātiḥa.',
                style: TextStyle(
                    color: c.textSecondary, fontSize: 13.5, height: 1.5),
              ),
              const SizedBox(height: 6),
              Text(
                corrects
                    ? (ar
                        ? 'التصحيح التلقائي مفعّل: يُنبّهك عند الخطأ ويقرأ الكلمة الصحيحة بصوت مسموع.'
                        : 'Auto-correct is on: it alerts you to mistakes and reads the right words aloud.')
                    : (ar
                        ? 'التصحيح التلقائي متوقف: يعرض على الشاشة ما كان سيفعله، دون أن يُصدر أي صوت.'
                        : 'Auto-correct is off: what it would do is only shown on screen, without a sound.'),
                style: TextStyle(
                    color: c.textSecondary, fontSize: 13.5, height: 1.5),
              ),
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: c.primary.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      ar
                          ? 'يبدأ من: ${widget.startText}'
                          : 'Starts at: ${widget.startText}',
                      style: TextStyle(
                        color: c.text,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      ar
                          ? 'لتغييره اختر الآية أولاً من قائمة السور أو بالنقر عليها.'
                          : 'To change it, choose the ayah first (surah list, or tap it).',
                      style: TextStyle(color: c.textSecondary, fontSize: 12),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 6),
              SheetToggle(
                label: ar ? 'التصحيح التلقائي' : 'Auto-correct',
                value: corrects,
                c: c,
                onChanged: _settings.setEnabled,
              ),
              Wrap(
                spacing: 4,
                children: [
                  TextButton.icon(
                    onPressed: () => showAutoCorrectSheet(context),
                    icon: const Icon(autoCorrectIcon, size: 18),
                    label: Text(ar
                        ? 'إعدادات التصحيح التلقائي'
                        : 'Auto-correct settings'),
                    style: TextButton.styleFrom(foregroundColor: c.primary),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              ElevatedButton.icon(
                onPressed: widget.onStart,
                icon: const Icon(Icons.mic_rounded, size: 19),
                label: Text(ar ? 'ابدأ' : 'Start'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: c.primary,
                  foregroundColor: Colors.white,
                  elevation: 0,
                  padding: const EdgeInsets.symmetric(vertical: 13),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
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

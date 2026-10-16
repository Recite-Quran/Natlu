import 'package:flutter/material.dart';

import '../../services/prayer/prayer_settings.dart';
import '../../state/app_state.dart';
import 'prayer_event_text.dart' show localizedNumber;
import '../widgets/settings/setting_tile.dart' show PremiumPillSelector;

/// Explains prayer mode, shows where it will start, lets it be made silent
/// (rehearsal) and its timings tuned, and starts it.
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
  final PrayerSettings _settings = PrayerSettings.instance;

  @override
  void initState() {
    super.initState();
    _settings.load();
  }

  String _label(PrayerSetting s, bool ar) => switch (s.key) {
        'prayer_pause_mid_ayah' =>
          ar ? 'تذكير بعد توقف وسط الآية' : 'Prompt after a pause mid-ayah',
        'prayer_pause_between_ayahs' => ar
            ? 'تذكير بعد توقف بين آيتين'
            : 'Prompt after a pause between ayahs',
        'prayer_correction_time' =>
          ar ? 'مهلة التصحيح بعد الخطأ' : 'Time to correct a mistake',
        _ => ar ? 'عدد الكلمات المقروءة' : 'Words read in a prompt',
      };

  String _value(PrayerSetting s, int v, bool ar) {
    final n = localizedNumber(v, ar);
    if (s.key == PrayerSettings.promptWords.key) {
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
        final silent = _settings.silent;
        return Directionality(
          textDirection: ar ? TextDirection.rtl : TextDirection.ltr,
          child: Container(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height * 0.9,
            ),
            decoration: BoxDecoration(
              color: c.surface,
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(24)),
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
                    Row(
                      children: [
                        Icon(Icons.mosque_rounded, color: c.primary),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            ar ? 'وضع الصلاة' : 'Prayer Mode',
                            style: TextStyle(
                              color: c.text,
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    PremiumPillSelector(
                      labels: [
                        ar ? 'بصوت' : 'Aloud',
                        ar ? 'صامت (تجربة)' : 'Silent (rehearsal)',
                      ],
                      icons: const [
                        Icons.volume_up_rounded,
                        Icons.volume_off_rounded,
                      ],
                      selected: silent ? 1 : 0,
                      c: c,
                      onSelected: (i) => _settings.setSilent(i == 1),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      silent
                          ? (ar
                              ? 'يتابع تلاوتك في الصلاة تلاوةً متصلة، ويعرض على الشاشة ما كان سيفعله — تنبيه عند الخطأ، وقراءة الكلمة الصحيحة بصوت مسموع — دون أن يُصدر أي صوت. مناسب للتجربة وضبط الإعدادات.'
                              : 'Follows your recitation through the prayer as one continuous plan, and shows on screen what it would do — beep at a mistake, read the right words aloud — without making a sound. For trying it out and tuning the settings.')
                          : (ar
                              ? 'يتابع تلاوتك في الصلاة تلاوةً متصلة. يُصدر تنبيهاً عند الخطأ، وإن لم تصحّحه، أو توقفت طويلاً، يقرأ الكلمة الصحيحة بصوت الحصري.'
                              : 'Follows your recitation through the prayer as one continuous plan. It beeps at a mistake and, if you don\'t correct it or you pause too long, reads the right words aloud (al-Ḥuṣarī).'),
                      style: TextStyle(
                          color: c.textSecondary, fontSize: 13.5, height: 1.5),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      ar
                          ? 'يبدأ المتابعة بعد سماع نهاية الفاتحة، ويتوقف عند «الله أكبر»، ثم يكمل من حيث توقف بعد الفاتحة التالية.'
                          : 'It starts following once it hears the end of al-Fātiḥa, stops at "Allāhu akbar", and carries on from where it stopped after the next al-Fātiḥa.',
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
                            style:
                                TextStyle(color: c.textSecondary, fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 14),
                    for (final s in PrayerSettings.all)
                      _Stepper(
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
              ),
            ),
          ),
        );
      },
    );
  }
}

class _Stepper extends StatelessWidget {
  const _Stepper({
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

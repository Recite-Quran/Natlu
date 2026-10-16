import 'package:flutter/material.dart';

import '../../services/prayer/prayer_mode.dart';
import '../../services/recitation/recitation_event.dart';
import '../../services/recitation/recited_word.dart';

/// [n] in Arabic-Indic digits when [arabic].
String localizedNumber(int n, bool arabic) {
  if (!arabic) return '$n';
  const digits = ['٠', '١', '٢', '٣', '٤', '٥', '٦', '٧', '٨', '٩'];
  return '$n'.split('').map((d) => digits[int.parse(d)]).join();
}

/// How a prayer-mode event is shown.
class RecitationEventText {
  const RecitationEventText(this.icon, this.color, this.title, {this.words});
  final IconData icon;
  final Color color;
  final String title;

  /// Quran words (in the Quran data's own encoding: show with the verse
  /// font), if the event has any.
  final String? words;
}

/// "Al-Baqarah 6" / "البقرة ٦".
String prayerPositionText(
    MushafWord? where, bool ar, String Function(int surah) surahName) {
  if (where == null) return '';
  return '${surahName(where.surah)} ${localizedNumber(where.ayah, ar)}';
}

String prayerPhaseText(PrayerPhase phase, bool ar) => switch (phase) {
      PrayerPhase.idle => ar ? 'متوقف' : 'Stopped',
      PrayerPhase.waitingForFatiha =>
        ar ? 'في انتظار الفاتحة' : 'Waiting for al-Fātiḥa',
      PrayerPhase.following => ar ? 'يتابع التلاوة' : 'Following',
    };

/// [silent]: auto-correct only shows what it would do (prayer mode without
/// auto-correct).
RecitationEventText describeRecitationEvent(RecitationEvent e, bool ar,
    String Function(int surah) surahName, Color accent, Color warning,
    {bool silent = false}) {
  final at = prayerPositionText(e.where, ar, surahName);
  const red = Color(0xFFE24B4A);
  switch (e.kind) {
    case RecitationEventKind.started:
      return RecitationEventText(
          Icons.play_arrow_rounded,
          accent,
          ar
              ? 'بدأ من $at — في انتظار الفاتحة'
              : 'Started at $at — waiting for al-Fātiḥa');
    case RecitationEventKind.fatihaEnded:
      return RecitationEventText(
          Icons.hearing_rounded,
          accent,
          ar
              ? 'سُمعت الفاتحة — المتابعة من $at'
              : 'Al-Fātiḥa heard — following from $at');
    case RecitationEventKind.takbir:
      return RecitationEventText(
          Icons.pause_circle_outline_rounded,
          accent,
          ar
              ? 'سُمع التكبير — الاستئناف من $at بعد الفاتحة'
              : 'Allāhu akbar heard — resuming at $at after al-Fātiḥa');
    case RecitationEventKind.nextSurah:
      return RecitationEventText(
          Icons.arrow_forward_rounded,
          accent,
          ar
              ? 'المتابعة بسورة ${surahName(e.where?.surah ?? 0)}'
              : 'Continuing with ${surahName(e.where?.surah ?? 0)}');
    case RecitationEventKind.mistake:
      return RecitationEventText(
        Icons.notifications_active_outlined,
        red,
        e.reason == RecitationReason.skipped
            ? (ar
                ? 'تنبيه: كلمة ناقصة ($at)'
                : '${silent ? 'Would beep' : 'Beeped'}: word left out ($at)')
            : (ar
                ? 'تنبيه: كلمة خاطئة، المتوقع ($at)'
                : '${silent ? 'Would beep' : 'Beeped'}: wrong word, '
                    'expected ($at)'),
        words: e.words,
      );
    case RecitationEventKind.corrected:
      return RecitationEventText(Icons.check_circle_outline_rounded, accent,
          ar ? 'صحّح القارئ ($at)' : 'Corrected by the reciter ($at)');
    case RecitationEventKind.prompt:
      final why = switch (e.reason) {
        RecitationReason.pauseMidAyah => ar ? 'بعد توقف' : 'after a pause',
        RecitationReason.pauseBetweenAyahs =>
          ar ? 'بعد توقف بين آيتين' : 'after a pause between ayahs',
        _ => ar ? 'بعد خطأ' : 'after a mistake',
      };
      return RecitationEventText(
          Icons.record_voice_over_outlined,
          warning,
          ar
              ? '${silent ? 'سيقرأ' : 'قرأ'} ($why، $at)'
              : '${silent ? 'Would read' : 'Read'} ($why, $at)',
          words: e.words);
    case RecitationEventKind.stopped:
      return RecitationEventText(
          Icons.stop_circle_outlined, accent, ar ? 'توقف' : 'Stopped');
  }
}

/// "21:04:17".
String prayerClockText(DateTime t, bool ar) {
  String two(int v) => localizedNumber(v, ar).padLeft(2, ar ? '٠' : '0');
  return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
}

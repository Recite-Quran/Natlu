import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:the_great_quran/services/prayer/prayer_settings.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('starts with the defaults', () async {
    final s = PrayerSettings.forTest();
    await s.load();
    expect(s.pauseMidAyahDuration, const Duration(seconds: 4));
    expect(s.pauseBetweenAyahsDuration, const Duration(seconds: 8));
    expect(s.correctionDuration, const Duration(seconds: 3));
    expect(s.promptWordCount, 1);
  });

  test('saves changes, kept within each setting\'s range', () async {
    final s = PrayerSettings.forTest();
    await s.set(PrayerSettings.pauseMidAyah, 6);
    await s.set(PrayerSettings.promptWords, 9);
    await s.set(PrayerSettings.correctionTime, 0);
    expect(s[PrayerSettings.pauseMidAyah], 6);
    expect(s[PrayerSettings.promptWords], 3);
    expect(s[PrayerSettings.correctionTime], 1);

    final reloaded = PrayerSettings.forTest();
    await reloaded.load();
    expect(reloaded.pauseMidAyahDuration, const Duration(seconds: 6));
    expect(reloaded.promptWordCount, 3);
  });

  test('reset puts everything back', () async {
    final s = PrayerSettings.forTest();
    await s.set(PrayerSettings.pauseBetweenAyahs, 20);
    await s.reset();
    expect(s[PrayerSettings.pauseBetweenAyahs], 8);
    final reloaded = PrayerSettings.forTest();
    await reloaded.load();
    expect(reloaded[PrayerSettings.pauseBetweenAyahs], 8);
  });

  test('ignores saved values it cannot read', () async {
    SharedPreferences.setMockInitialValues(
        {'prayer_pause_mid_ayah': 'four', 'prayer_prompt_words': 99});
    final s = PrayerSettings.forTest();
    await s.load();
    expect(s[PrayerSettings.pauseMidAyah], 4);
    expect(s[PrayerSettings.promptWords], 3, reason: 'clamped');
  });

  test('tells listeners about changes', () async {
    final s = PrayerSettings.forTest();
    await s.load();
    int calls = 0;
    s.addListener(() => calls++);
    await s.set(PrayerSettings.pauseMidAyah, 5);
    await s.set(PrayerSettings.pauseMidAyah, 5); // unchanged
    expect(calls, 1);
  });
}

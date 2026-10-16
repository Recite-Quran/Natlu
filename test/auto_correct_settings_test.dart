import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:the_great_quran/services/recitation/auto_correct_settings.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('starts with the defaults', () async {
    final s = AutoCorrectSettings.forTest();
    await s.load();
    expect(s.pauseMidAyahDuration, const Duration(seconds: 4));
    expect(s.pauseBetweenAyahsDuration, const Duration(seconds: 8));
    expect(s.correctionDuration, const Duration(seconds: 3));
    expect(s.promptWordCount, 1);
  });

  test('saves changes, kept within each setting\'s range', () async {
    final s = AutoCorrectSettings.forTest();
    await s.set(AutoCorrectSettings.pauseMidAyah, 6);
    await s.set(AutoCorrectSettings.promptWords, 9);
    await s.set(AutoCorrectSettings.correctionTime, 0);
    expect(s[AutoCorrectSettings.pauseMidAyah], 6);
    expect(s[AutoCorrectSettings.promptWords], 3);
    expect(s[AutoCorrectSettings.correctionTime], 1);

    final reloaded = AutoCorrectSettings.forTest();
    await reloaded.load();
    expect(reloaded.pauseMidAyahDuration, const Duration(seconds: 6));
    expect(reloaded.promptWordCount, 3);
  });

  test('reset puts everything back', () async {
    final s = AutoCorrectSettings.forTest();
    await s.set(AutoCorrectSettings.pauseBetweenAyahs, 20);
    await s.reset();
    expect(s[AutoCorrectSettings.pauseBetweenAyahs], 8);
    final reloaded = AutoCorrectSettings.forTest();
    await reloaded.load();
    expect(reloaded[AutoCorrectSettings.pauseBetweenAyahs], 8);
  });

  test('ignores saved values it cannot read', () async {
    SharedPreferences.setMockInitialValues(
        {'prayer_pause_mid_ayah': 'four', 'prayer_prompt_words': 99});
    final s = AutoCorrectSettings.forTest();
    await s.load();
    expect(s[AutoCorrectSettings.pauseMidAyah], 4);
    expect(s[AutoCorrectSettings.promptWords], 3, reason: 'clamped');
  });

  test('tells listeners about changes', () async {
    final s = AutoCorrectSettings.forTest();
    await s.load();
    int calls = 0;
    s.addListener(() => calls++);
    await s.set(AutoCorrectSettings.pauseMidAyah, 5);
    await s.set(AutoCorrectSettings.pauseMidAyah, 5); // unchanged
    expect(calls, 1);
  });

  test('auto-correct: off by default, saved, and reset by reset()', () async {
    final s = AutoCorrectSettings.forTest();
    await s.load();
    expect(s.enabled, isFalse);
    await s.setEnabled(true);
    await s.set(AutoCorrectSettings.pauseMidAyah, 7);

    final reloaded = AutoCorrectSettings.forTest();
    await reloaded.load();
    expect(reloaded.enabled, isTrue);

    await reloaded.resetTimings();
    expect(reloaded.enabled, isTrue, reason: 'only the timings');
    expect(reloaded[AutoCorrectSettings.pauseMidAyah], 4);

    await reloaded.reset();
    expect(reloaded.enabled, isFalse);
    final again = AutoCorrectSettings.forTest();
    await again.load();
    expect(again.enabled, isFalse);
  });

  test('an unreadable setting means its default', () async {
    SharedPreferences.setMockInitialValues({'auto_correct': 'yes'});
    final s = AutoCorrectSettings.forTest();
    await s.load();
    expect(s.enabled, isFalse);
  });
}

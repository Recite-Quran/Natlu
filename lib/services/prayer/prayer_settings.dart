import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// One adjustable prayer-mode setting: its range, default and saved key.
class PrayerSetting {
  const PrayerSetting(this.key, this.defaultValue, this.min, this.max);
  final String key;
  final int defaultValue;
  final int min;
  final int max;
}

/// The values a user can tune in prayer mode, saved on the device.
class PrayerSettings extends ChangeNotifier {
  PrayerSettings._();
  static final PrayerSettings instance = PrayerSettings._();

  /// A fresh, unloaded instance for tests.
  @visibleForTesting
  factory PrayerSettings.forTest() => PrayerSettings._();

  /// Seconds of silence part way through an ayah before the next words are
  /// prompted.
  static const pauseMidAyah = PrayerSetting('prayer_pause_mid_ayah', 4, 2, 15);

  /// Seconds of silence at the end of an ayah before the next ayah's first
  /// words are prompted (unless "Allāhu akbar" ended the recitation).
  static const pauseBetweenAyahs =
      PrayerSetting('prayer_pause_between_ayahs', 8, 3, 30);

  /// Seconds the reciter has to correct a mistake before the right words
  /// are prompted.
  static const correctionTime =
      PrayerSetting('prayer_correction_time', 3, 1, 10);

  /// How many words a prompt reads out.
  static const promptWords = PrayerSetting('prayer_prompt_words', 1, 1, 3);

  static const List<PrayerSetting> all = [
    pauseMidAyah,
    pauseBetweenAyahs,
    correctionTime,
    promptWords,
  ];

  final Map<String, int> _values = {};
  Future<void>? _loading;

  int operator [](PrayerSetting s) => _values[s.key] ?? s.defaultValue;

  Duration get pauseMidAyahDuration => Duration(seconds: this[pauseMidAyah]);
  Duration get pauseBetweenAyahsDuration =>
      Duration(seconds: this[pauseBetweenAyahs]);
  Duration get correctionDuration => Duration(seconds: this[correctionTime]);
  int get promptWordCount => this[promptWords];

  /// Loads the saved values (once). Unreadable values fall back to defaults.
  Future<void> load() => _loading ??= () async {
        final prefs = await SharedPreferences.getInstance();
        for (final s in all) {
          try {
            final v = prefs.getInt(s.key);
            if (v != null) _values[s.key] = v.clamp(s.min, s.max);
          } catch (e) {
            debugPrint('PrayerSettings: could not read ${s.key}: $e');
          }
        }
        notifyListeners();
      }();

  /// Sets [s] (clamped to its range) and saves it.
  Future<void> set(PrayerSetting s, int value) async {
    await load();
    final v = value.clamp(s.min, s.max);
    if (this[s] == v) return;
    _values[s.key] = v;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(s.key, v);
  }

  /// Puts every setting back to its default.
  Future<void> reset() async {
    await load();
    _values.clear();
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    for (final s in all) {
      await prefs.remove(s.key);
    }
  }
}

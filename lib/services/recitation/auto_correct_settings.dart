import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// One adjustable auto-correct setting: its range, default and saved key.
class AutoCorrectSetting {
  const AutoCorrectSetting(this.key, this.defaultValue, this.min, this.max);
  final String key;
  final int defaultValue;
  final int min;
  final int max;
}

/// Whether auto-correct is on, and the values a user can tune in it, saved
/// on the device. (The timings keep the keys they had under prayer mode.)
class AutoCorrectSettings extends ChangeNotifier {
  AutoCorrectSettings._();
  static final AutoCorrectSettings instance = AutoCorrectSettings._();

  /// A fresh, unloaded instance for tests.
  @visibleForTesting
  factory AutoCorrectSettings.forTest() => AutoCorrectSettings._();

  /// Seconds of silence part way through an ayah before the next words are
  /// prompted.
  static const pauseMidAyah =
      AutoCorrectSetting('prayer_pause_mid_ayah', 4, 2, 15);

  /// Seconds of silence at the end of an ayah before the next ayah's first
  /// words are prompted (unless "Allāhu akbar" ended the recitation).
  static const pauseBetweenAyahs =
      AutoCorrectSetting('prayer_pause_between_ayahs', 8, 3, 30);

  /// Seconds the reciter has to correct a mistake before the right words
  /// are prompted.
  static const correctionTime =
      AutoCorrectSetting('prayer_correction_time', 3, 1, 10);

  /// How many words a prompt reads out.
  static const promptWords = AutoCorrectSetting('prayer_prompt_words', 1, 1, 3);

  static const List<AutoCorrectSetting> all = [
    pauseMidAyah,
    pauseBetweenAyahs,
    correctionTime,
    promptWords,
  ];

  /// Saved key of [enabled].
  static const String enabledKey = 'auto_correct';

  final Map<String, int> _values = {};
  bool _enabled = false;
  Future<void>? _loading;

  int operator [](AutoCorrectSetting s) => _values[s.key] ?? s.defaultValue;

  /// Whether auto-correct is on: it beeps at mistakes and reads the right
  /// words aloud. Off by default.
  bool get enabled => _enabled;

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
            debugPrint('AutoCorrectSettings: could not read ${s.key}: $e');
          }
        }
        _enabled = _readBool(prefs, enabledKey) ?? false;
        notifyListeners();
      }();

  static bool? _readBool(SharedPreferences prefs, String key) {
    try {
      return prefs.getBool(key);
    } catch (e) {
      debugPrint('AutoCorrectSettings: could not read $key: $e');
      return null;
    }
  }

  /// Sets [s] (clamped to its range) and saves it.
  Future<void> set(AutoCorrectSetting s, int value) async {
    await load();
    final v = value.clamp(s.min, s.max);
    if (this[s] == v) return;
    _values[s.key] = v;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(s.key, v);
  }

  /// Turns auto-correct on or off, and saves it.
  Future<void> setEnabled(bool value) async {
    await load();
    if (_enabled == value) return;
    _enabled = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(enabledKey, value);
  }

  /// Puts the timings and word counts ([all]) back to their defaults.
  Future<void> resetTimings() async {
    await load();
    _values.clear();
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    for (final s in all) {
      await prefs.remove(s.key);
    }
  }

  /// Puts every setting back to its default: auto-correct off.
  Future<void> reset() async {
    await resetTimings();
    await setEnabled(false);
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(enabledKey);
  }
}

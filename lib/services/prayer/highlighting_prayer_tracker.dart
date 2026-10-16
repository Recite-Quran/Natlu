import 'package:flutter/foundation.dart';
import 'package:recite_quran/recite_quran.dart';

import '../recitation/recited_word.dart';
import 'prayer_session.dart';

/// [PrayerTracker] backed by the app's [HighlightingController].
///
/// While prayer mode runs, the controller works in plain word-checking
/// mode (no tajweed) with its automatic re-anchoring off: prayer mode
/// follows one continuous plan, so the tracker should wait at the expected
/// word rather than search the surah for wherever the reciter might be.
/// [restore] puts both back.
class HighlightingPrayerTracker implements PrayerTracker {
  HighlightingPrayerTracker(this.controller)
      : _savedConfig = controller.config,
        _savedTajweed = controller.isTajweed {
    controller.updateConfig(TrackerConfig(
      recitationSpeed: _savedConfig.recitationSpeed,
      matchingStrictness: _savedConfig.matchingStrictness,
      enableEarlyMatching: _savedConfig.enableEarlyMatching,
      enableAutoReanchor: false,
      reanchorStallThreshold: _savedConfig.reanchorStallThreshold,
    ));
    controller.setTajweedMode(false);
  }

  final HighlightingController controller;
  final TrackerConfig _savedConfig;
  final bool _savedTajweed;

  @override
  RecitedWordState stateOf(MushafWord w) {
    if (controller.isWordRed(w.ayah, w.wordIndex0, surah: w.surah)) {
      return RecitedWordState.mistake;
    }
    if (controller.isWordGreen(w.ayah, w.wordIndex0, surah: w.surah) ||
        controller.isWordYellow(w.ayah, w.wordIndex0, surah: w.surah) ||
        controller.isWordNeutral(w.ayah, w.wordIndex0, surah: w.surah)) {
      return RecitedWordState.recited;
    }
    return RecitedWordState.unspoken;
  }

  @override
  void pause() => controller.finalize();

  @override
  Future<void> resumeAt(int surah, int ayah) async {
    if (controller.targetSurah != surah) {
      await controller.setTargetSurah(surah);
    }
    controller.setManualAyah(surah, ayah);
    controller.resumeTracking();
  }

  /// Gives the controller back its own settings.
  void restore() {
    controller.updateConfig(_savedConfig);
    controller.setTajweedMode(_savedTajweed);
  }

  @override
  void addListener(VoidCallback listener) => controller.addListener(listener);

  @override
  void removeListener(VoidCallback listener) =>
      controller.removeListener(listener);
}

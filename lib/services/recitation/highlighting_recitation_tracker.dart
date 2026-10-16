import 'package:flutter/foundation.dart';
import 'package:recite_quran/recite_quran.dart';

import 'recitation_tracker.dart';
import 'recited_word.dart';

/// [RecitationTracker] backed by the app's [HighlightingController].
///
/// For prayer mode ([followPlan]), the controller works in plain
/// word-checking mode (no tajweed) with its automatic re-anchoring off:
/// prayer mode follows one continuous plan, so the tracker should wait at
/// the expected word rather than search the surah for wherever the reciter
/// might be. [restore] puts both back.
class HighlightingRecitationTracker implements RecitationTracker {
  HighlightingRecitationTracker(this.controller, {this.followPlan = false})
      : _savedConfig = controller.config,
        _savedTajweed = controller.isTajweed {
    if (!followPlan) return;
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
  final bool followPlan;
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
  bool get following => controller.state == TrackerState.tracking;

  @override
  int get surah => controller.targetSurah;

  @override
  int? get activeAyah => controller.activeAyah.value;

  @override
  int get revision => controller.globalRevision.value;

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
    if (!followPlan) return;
    controller.updateConfig(_savedConfig);
    controller.setTajweedMode(_savedTajweed);
  }

  @override
  void addListener(VoidCallback listener) => controller.addListener(listener);

  @override
  void removeListener(VoidCallback listener) =>
      controller.removeListener(listener);
}

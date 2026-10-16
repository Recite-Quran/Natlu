import 'package:flutter/foundation.dart';

import 'recited_word.dart';

/// What prayer mode and auto-correct need from the word tracker.
abstract class RecitationTracker implements Listenable {
  /// What the tracker says about [word] (notifies after every word).
  RecitedWordState stateOf(MushafWord word);

  /// Whether it is following the recitation now (it stops at the end of a
  /// surah, and when [pause]d).
  bool get following;

  /// The surah it follows, and the ayah it expects words of (the next one
  /// once an ayah has been finished).
  int get surah;
  int? get activeAyah;

  /// Stops following the recitation.
  void pause();

  /// Follows the recitation again, expecting [ayah] of [surah] from its
  /// first word.
  Future<void> resumeAt(int surah, int ayah);
}

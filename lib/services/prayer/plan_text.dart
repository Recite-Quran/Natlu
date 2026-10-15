import 'package:recite_quran/recite_quran.dart';

import 'recited_word.dart';
import 'phrase_spotter.dart';

/// One word of the text prayer mode follows.
class PlanWord {
  const PlanWord(this.ref, this.uthmani, this.skeleton);

  /// Where it is (word index as the tracker counts words).
  final MushafWord ref;

  /// The word as written, for prompts.
  final String uthmani;

  /// Its pronunciation as a [phonemeSkeleton]; empty when it is pronounced
  /// together with the word before it (one phoneme word for two written
  /// words), so that sound is counted once.
  final String skeleton;

  bool get startsAyah => ref.wordIndex0 == 0;
}

/// The words of each surah, in order, for prayer mode.
abstract class PlanText {
  Future<List<PlanWord>> wordsOf(int surah);
}

/// [PlanText] from the app's Quran data.
class QuranPlanText implements PlanText {
  QuranPlanText(this.repository);
  final QuranRepository repository;
  final Map<int, List<PlanWord>> _cache = {};

  @override
  Future<List<PlanWord>> wordsOf(int surah) async {
    final cached = _cache[surah];
    if (cached != null) return cached;
    await repository.loadSurahAsync(surah);
    final words = <PlanWord>[];
    for (final verse in repository.getSurah(surah)) {
      int lastPhoneme = -1;
      for (int i = 0; i < verse.uthmaniWords.length; i++) {
        final p = i < verse.wordMap.length ? verse.wordMap[i] : i;
        final skeleton = p != lastPhoneme && p < verse.phonemeWords.length
            ? phonemeSkeleton(verse.phonemeWords[p])
            : '';
        lastPhoneme = p;
        words.add(PlanWord(
          MushafWord(surah, verse.ayah, i),
          verse.uthmaniWords[i],
          skeleton,
        ));
      }
    }
    return _cache[surah] = words;
  }
}

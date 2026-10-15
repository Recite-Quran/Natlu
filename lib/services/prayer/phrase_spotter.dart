import 'dart:typed_data';

import 'package:recite_quran/recite_quran.dart';

/// [phonemes] with spaces removed and every run of one repeated character
/// reduced to a single character.
///
/// The recognizer writes long vowels and doubled letters as repeated
/// characters, and how many it writes depends on how long the sound was held.
/// Comparing skeletons stops a longer or shorter madd from counting as a
/// difference.
String phonemeSkeleton(String phonemes) {
  final out = StringBuffer();
  int? previous;
  for (final c in phonemes.runes) {
    if (c == 0x20) continue;
    if (c != previous) out.writeCharCode(c);
    previous = c;
  }
  return out.toString();
}

/// Where a query was found in a text, and with how many edits.
class NearMatch {
  const NearMatch(this.start, this.end, this.distance);

  /// The matched part is `text.substring(start, end)`.
  final int start;
  final int end;
  final int distance;

  @override
  String toString() => 'NearMatch($start-$end, distance $distance)';
}

/// The occurrence of [query] in [text] with the fewest edits (insertions,
/// deletions, substitutions), if it has at most [maxDistance]; [accept] can
/// rule candidates out.
///
/// Plain dynamic programming (Sellers' algorithm) in 32-bit integers. The
/// engine's own `findNearMatches` uses 64-bit integers (`Uint64List`), which
/// Dart doesn't support when compiled for the web.
NearMatch? nearestMatch(
  String query,
  String text,
  int maxDistance, {
  bool Function(int start, int end)? accept,
}) {
  final n = query.length;
  final m = text.length;
  if (n == 0 || m == 0 || maxDistance < 0) return null;
  final q = query.codeUnits;
  final t = text.codeUnits;
  var prev = Int32List(n + 1);
  var cur = Int32List(n + 1);
  var prevStart = Int32List(n + 1);
  var curStart = Int32List(n + 1);
  for (int i = 0; i <= n; i++) {
    prev[i] = i;
  }
  NearMatch? best;
  for (int j = 1; j <= m; j++) {
    cur[0] = 0;
    curStart[0] = j;
    final c = t[j - 1];
    for (int i = 1; i <= n; i++) {
      int d = prev[i - 1] + (q[i - 1] == c ? 0 : 1);
      int s = prevStart[i - 1];
      if (prev[i] + 1 < d) {
        d = prev[i] + 1;
        s = prevStart[i];
      }
      if (cur[i - 1] + 1 < d) {
        d = cur[i - 1] + 1;
        s = curStart[i - 1];
      }
      cur[i] = d;
      curStart[i] = s;
    }
    final d = cur[n];
    if (d <= maxDistance &&
        (best == null || d < best.distance) &&
        (accept == null || accept(curStart[n], j))) {
      best = NearMatch(curStart[n], j, d);
      if (d == 0) break;
    }
    final swap = prev;
    prev = cur;
    cur = swap;
    final swapStart = prevStart;
    prevStart = curStart;
    curStart = swapStart;
  }
  return best;
}

/// Finds a fixed phrase in recognized speech, allowing a few differences.
class PhraseSpotter {
  PhraseSpotter(
    String phonemes, {
    required this.maxDistance,
    this.mustContain = const [],
  }) : skeleton = phonemeSkeleton(phonemes);

  /// The phrase, as a [phonemeSkeleton].
  final String skeleton;

  /// Most edits (insertions, deletions, substitutions) a match may have.
  final int maxDistance;

  /// Strings the matched speech must contain, to rule out look-alikes.
  final List<String> mustContain;

  /// Whether the phrase occurs in [heard] (phonemes).
  bool foundIn(String heard) => find(heard) != null;

  /// The closest occurrence of the phrase in the skeleton of [heard], or null.
  NearMatch? find(String heard) {
    final text = phonemeSkeleton(heard);
    if (text.isEmpty) return null;
    return nearestMatch(
      skeleton,
      text,
      maxDistance,
      accept: mustContain.isEmpty
          ? null
          : (start, end) {
              final matched = text.substring(start, end);
              return mustContain.every(matched.contains);
            },
    );
  }
}

/// The phrases prayer mode listens for.
class PrayerPhrases {
  /// "Allāhu akbar", stopping on the last letter as it is said in prayer.
  static const String takbirPhonemes = 'ءَللَااهُءَكبَر';

  /// Spots "Allāhu akbar". Two edits allow for a dropped opening hamza or a
  /// final vowel; "Allāhu aʿlam" is three away. In the whole Quran the only
  /// match is "مِنَ اللَّهِ أَكْبَرُ" in 9:72 (and a few more at three
  /// edits), so prayer mode ignores a match while the text being recited
  /// contains the phrase.
  static PhraseSpotter takbir() =>
      PhraseSpotter(takbirPhonemes, maxDistance: 2, mustContain: const ['ك']);

  /// Spots the end of al-Fātiḥa: "غَيْرِ الْمَغْضُوبِ عَلَيْهِمْ وَلَا
  /// الضَّالِّينَ" (the last five words of 1:7), within a quarter of its
  /// length. [fatihaLastAyah] is 1:7 from the Quran data (surah 1 loaded).
  static PhraseSpotter fatihaEnd(QuranVerse fatihaLastAyah) {
    final words = fatihaLastAyah.phonemeWords;
    final ending = words.sublist(words.length - 5).join();
    final length = phonemeSkeleton(ending).length;
    return PhraseSpotter(ending, maxDistance: (length * 0.25).round());
  }
}

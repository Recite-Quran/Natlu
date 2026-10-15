import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:recite_quran/recite_quran.dart';
import 'package:the_great_quran/services/prayer/phrase_spotter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late QuranRepository repo;

  setUpAll(() async {
    repo = QuranRepository(QuranMetadataService());
    for (int s = 1; s <= 114; s++) {
      await repo.loadSurahAsync(s);
    }
  });

  group('nearestMatch', () {
    test('finds exact and approximate occurrences', () {
      expect(nearestMatch('abc', 'xxabcxx', 0).toString(),
          'NearMatch(2-5, distance 0)');
      expect(nearestMatch('abcd', 'xxabxdxx', 1)!.distance, 1);
      expect(nearestMatch('abcd', 'xxabxdxx', 0), isNull);
      expect(nearestMatch('', 'abc', 1), isNull);
    });

    test('can rule candidates out', () {
      final m =
          nearestMatch('ab', 'axbab', 1, accept: (start, end) => start >= 2);
      expect(m!.start, greaterThanOrEqualTo(2));
    });

    test('agrees with the engine\'s search on the best distance', () {
      // findNearMatches only works off the web; nearestMatch must give the
      // same answers everywhere.
      final rng = Random(7);
      final text = repo.getSurahWords(2).take(400).map((w) => w.phoneme).join();
      const letters = 'ابتثجحخدذرزسشصضطظعغفقكلمنهوي';
      for (int k = 0; k < 300; k++) {
        final len = 8 + rng.nextInt(40);
        final at = rng.nextInt(text.length - len);
        final chars = text.substring(at, at + len).split('');
        for (int e = rng.nextInt(5); e > 0; e--) {
          final i = rng.nextInt(chars.length);
          switch (rng.nextInt(3)) {
            case 0:
              chars[i] = letters[rng.nextInt(letters.length)];
            case 1:
              chars.removeAt(i);
            default:
              chars.insert(i, letters[rng.nextInt(letters.length)]);
          }
        }
        final query = chars.join();
        const maxDist = 6;
        final theirs = findNearMatches(query, text, maxDist);
        final ours = nearestMatch(query, text, maxDist);
        final best =
            theirs.isEmpty ? null : theirs.map((m) => m.dist).reduce(min);
        expect(ours?.distance, best, reason: query);
      }
    });
  });

  test('skeleton drops spaces and collapses held sounds', () {
    expect(phonemeSkeleton('ءَللَااااهُ ءَكبَر'), 'ءَلَاهُءَكبَر');
    expect(phonemeSkeleton(''), '');
  });

  group('Allāhu akbar', () {
    final takbir = PrayerPhrases.takbir();

    test('is heard however long its vowels are held', () {
      expect(takbir.foundIn('ءَللَااهُءَكبَر'), isTrue);
      expect(takbir.foundIn('ءَللَاااااااهُ ءَكبَرُ'), isTrue);
      expect(takbir.foundIn('للَااهُءَكبَر'), isTrue, reason: 'no hamza');
      expect(takbir.foundIn('وَلَضضَاالِۦۦن ءَامِۦۦن ءَللَااهُءَكبَر'), isTrue);
    });

    test('is not confused with the other phrases of the prayer', () {
      for (final phrase in [
        'ءَللَااهُءَعلَمُ', // Allāhu aʿlam
        'سَمِعَللَااهُلِمَنحَمِدَه',
        'رَببَنَاوَلَكَلحَمد',
        'سُبحَاانَرَببِيَلعَظِۦۦم',
        'سُبحَاانَرَببِيَلءَعلَاا',
        'ءَامِۦۦن',
      ]) {
        expect(takbir.foundIn(phrase), isFalse, reason: phrase);
      }
    });

    test('matches only 9:72 in the whole Quran', () {
      final hits = <String>[];
      for (int s = 1; s <= 114; s++) {
        final text = repo.getSurahWords(s).map((w) => w.phoneme).join();
        if (takbir.foundIn(text)) {
          for (final verse in repo.getSurah(s)) {
            if (takbir.foundIn(verse.phonemeWords.join())) {
              hits.add('${verse.surah}:${verse.ayah}');
            }
          }
        }
      }
      expect(hits, ['9:72']);
    });
  });

  group('end of al-Fātiḥa', () {
    late PhraseSpotter fatihaEnd;
    setUpAll(() => fatihaEnd = PrayerPhrases.fatihaEnd(repo.getVerse(1, 7)!));

    test('is heard at the end of al-Fātiḥa, also with a few differences', () {
      final fatiha = repo.getSurah(1).map((v) => v.phonemeWords.join()).join();
      expect(fatihaEnd.foundIn(fatiha), isTrue);
      expect(fatihaEnd.foundIn('غَيرِلمَغضُوبِعَلَيهِموَلَضضَاللِين'), isTrue);
    });

    test('is not heard part way through al-Fātiḥa', () {
      final upTo6 = repo
          .getSurah(1)
          .where((v) => v.ayah <= 6)
          .map((v) => v.phonemeWords.join())
          .join();
      expect(fatihaEnd.foundIn(upTo6), isFalse);
    });

    test('matches nowhere else in the Quran', () {
      for (int s = 2; s <= 114; s++) {
        final text = repo.getSurahWords(s).map((w) => w.phoneme).join();
        expect(fatihaEnd.foundIn(text), isFalse, reason: 'surah $s');
      }
    });
  });
}

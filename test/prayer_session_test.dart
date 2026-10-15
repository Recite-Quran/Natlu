import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recite_quran/recite_quran.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:the_great_quran/services/prayer/plan_text.dart';
import 'package:the_great_quran/services/prayer/phrase_spotter.dart';
import 'package:the_great_quran/services/prayer/prayer_session.dart';
import 'package:the_great_quran/services/prayer/prayer_settings.dart';
import 'package:the_great_quran/services/prayer/recited_word.dart';

/// Behaves like the app's tracker: words get states as the reciter reaches
/// them, resuming at an ayah clears it and what follows, listeners hear
/// about every word.
class FakeTracker extends ChangeNotifier implements PrayerTracker {
  final Map<MushafWord, RecitedWordState> states = {};
  bool following = false;
  final List<(int, int)> resumes = [];
  int pauses = 0;

  @override
  RecitedWordState stateOf(MushafWord word) =>
      states[word] ?? RecitedWordState.unspoken;

  @override
  void pause() {
    following = false;
    pauses++;
  }

  @override
  Future<void> resumeAt(int surah, int ayah) async {
    states.removeWhere(
        (w, _) => w.surah == surah && w.ayah >= ayah || w.surah > surah);
    following = true;
    resumes.add((surah, ayah));
  }

  void mark(MushafWord w, RecitedWordState s) {
    states[w] = s;
    notifyListeners();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late QuranRepository repo;
  late QuranPlanText text;
  late List<PlanWord> fatiha;
  late FakeTracker tracker;
  late PrayerSettings settings;
  late PrayerSession session;
  late DateTime clock;
  int epoch = 0;

  setUpAll(() async {
    repo = QuranRepository(QuranMetadataService());
    text = QuranPlanText(repo);
    fatiha = await text.wordsOf(1);
    for (final s in [2, 9, 112, 113]) {
      await text.wordsOf(s);
    }
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    clock = DateTime(2026, 10, 15, 20);
    tracker = FakeTracker();
    settings = PrayerSettings.forTest();
    await settings.load();
    session = PrayerSession(
      tracker: tracker,
      text: text,
      settings: settings,
      fatihaEnd: PrayerPhrases.fatihaEnd(repo.getVerse(1, 7)!),
      extraPhrases: [
        PrayerSession.istiadhaPhonemes,
        fatiha.where((w) => w.ref.ayah == 1).map((w) => w.skeleton).join(),
        PrayerSession.aminPhonemes,
      ],
      now: () => clock,
      autoTick: false,
    );
  });

  tearDown(() => session.dispose());

  void wait(int seconds) {
    clock = clock.add(Duration(seconds: seconds));
    session.tick();
  }

  /// The recognizer hears [phonemes] (one segment).
  void say(String phonemes) {
    clock = clock.add(const Duration(milliseconds: 300));
    session.addTranscription(tokens: [phonemes], isFinal: true, epoch: epoch);
  }

  Future<void> reciteFatiha() async {
    for (final w in fatiha) {
      say(w.skeleton);
    }
    await pumpEventQueue();
  }

  Future<List<PlanWord>> words(int surah) => text.wordsOf(surah);

  /// Recites [list] word by word: heard, then matched by the tracker.
  Future<void> recite(Iterable<PlanWord> list,
      {Map<MushafWord, RecitedWordState> marks = const {}}) async {
    for (final w in list) {
      if (marks[w.ref] != RecitedWordState.mistake) say(w.skeleton);
      tracker.mark(w.ref, marks[w.ref] ?? RecitedWordState.recited);
    }
    await pumpEventQueue();
  }

  Iterable<PlanWord> ayah(List<PlanWord> ws, int a) =>
      ws.where((w) => w.ref.ayah == a);

  List<String> log() => session.events.map((e) => e.toString()).toList();

  Iterable<PrayerEvent> of(PrayerEventKind k) =>
      session.events.where((e) => e.kind == k);

  test('waits for al-Fātiḥa, then follows the plan from its start', () async {
    await session.start(2, 6);
    expect(session.phase, PrayerPhase.waitingForFatiha);
    expect(tracker.pauses, 1);

    say(PrayerPhrases.takbirPhonemes); // takbīrat al-iḥrām
    await reciteFatiha();
    expect(session.phase, PrayerPhase.following);
    expect(tracker.resumes, [(2, 6)]);
    expect(of(PrayerEventKind.fatihaEnded).single.where,
        const MushafWord(2, 6, 0));
    expect(session.position, const MushafWord(2, 6, 0));
  });

  test('"Allāhu akbar" stops following; the next al-Fātiḥa resumes it',
      () async {
    final b = await words(2);
    await session.start(2, 6);
    await reciteFatiha();
    say(PrayerSession.aminPhonemes);
    for (int a = 6; a <= 8; a++) {
      await recite(ayah(b, a));
    }
    say(PrayerPhrases.takbirPhonemes);
    expect(session.phase, PrayerPhase.waitingForFatiha);
    expect(tracker.pauses, 2);
    expect(of(PrayerEventKind.takbir).single.where, const MushafWord(2, 9, 0));

    // Rukūʿ, sujūd... nothing is followed or prompted.
    say('سُبحَاانَرَببِيَلعَظِۦۦم');
    wait(30);
    expect(of(PrayerEventKind.prompt), isEmpty);

    await reciteFatiha();
    expect(tracker.resumes, [(2, 6), (2, 9)]);
    await recite(ayah(b, 9));
    expect(of(PrayerEventKind.mistake), isEmpty);
    expect(session.position, const MushafWord(2, 10, 0));
  });

  test('"Allāhu" taken as the next ayah\'s first word resumes that ayah',
      () async {
    // 2:255 starts with "اللَّهُ".
    final b = await words(2);
    await session.start(2, 254);
    await reciteFatiha();
    await recite(ayah(b, 254));
    say('ءَللَااهُ');
    tracker.mark(const MushafWord(2, 255, 0), RecitedWordState.recited);
    say('ءَكبَر');
    expect(
        of(PrayerEventKind.takbir).single.where, const MushafWord(2, 255, 0));
  });

  test('reciting "مِنَ اللَّهِ أَكْبَرُ" (9:72) is not the takbīr', () async {
    final t = await words(9);
    await session.start(9, 72);
    await reciteFatiha();
    await recite(ayah(t, 72));
    expect(session.phase, PrayerPhase.following);
    expect(of(PrayerEventKind.takbir), isEmpty);
  });

  test('a left-out word: beep, then prompted if not corrected', () async {
    final b = await words(2);
    await session.start(2, 7);
    await reciteFatiha();
    // عَلَىٰ: the same word comes again later in the ayah (وَعَلَىٰ), which
    // isn't going back to it.
    final missing = ayah(b, 7).elementAt(2);
    await recite(ayah(b, 7).take(4),
        marks: {missing.ref: RecitedWordState.mistake});

    final mistake = of(PrayerEventKind.mistake).single;
    expect(mistake.reason, PrayerReason.skipped);
    expect(mistake.words, missing.uthmani);
    wait(2);
    expect(of(PrayerEventKind.prompt), isEmpty);
    wait(1);
    final prompt = of(PrayerEventKind.prompt).single;
    expect(prompt.words, missing.uthmani);
    expect(prompt.where, missing.ref);
  });

  test('a left-out word said again in time is corrected, not prompted',
      () async {
    final b = await words(2);
    await session.start(2, 7);
    await reciteFatiha();
    final missing = ayah(b, 7).elementAt(3); // عَلَىٰ قُلُوبِهِمْ ...
    await recite(ayah(b, 7).take(5),
        marks: {missing.ref: RecitedWordState.mistake});
    say(missing.skeleton + ayah(b, 7).elementAt(4).skeleton);
    wait(1);
    expect(of(PrayerEventKind.corrected), hasLength(1));
    await recite(ayah(b, 7).skip(5));
    wait(5);
    expect(of(PrayerEventKind.prompt), isEmpty);
  });

  test('the same word further on is not a correction', () async {
    final b = await words(2);
    await session.start(2, 7);
    await reciteFatiha();
    final missing = ayah(b, 7).elementAt(2); // عَلَىٰ
    await recite(ayah(b, 7), marks: {missing.ref: RecitedWordState.mistake});
    wait(3);
    expect(of(PrayerEventKind.corrected), isEmpty);
    expect(of(PrayerEventKind.prompt).single.words, missing.uthmani);
  });

  test('a wrong word: beep; moving on again corrects it', () async {
    final b = await words(2);
    await session.start(2, 6);
    await reciteFatiha();
    await recite(ayah(b, 6));
    say('فَبِءَييِءَاالَااءِرَببِكُمَاتُكَذذِبَاان'); // 55:13, not 2:7
    expect(of(PrayerEventKind.mistake).single.reason, PrayerReason.wrongWord);
    expect(of(PrayerEventKind.mistake).single.where, const MushafWord(2, 7, 0));
    await recite(ayah(b, 7).take(2));
    expect(of(PrayerEventKind.corrected), hasLength(1));
    await recite(ayah(b, 7).skip(2));
    wait(5);
    expect(of(PrayerEventKind.prompt), isEmpty);
  });

  test('a wrong word not corrected prompts the expected words', () async {
    await settings.set(PrayerSettings.promptWords, 2);
    final b = await words(2);
    await session.start(2, 6);
    await reciteFatiha();
    await recite(ayah(b, 6));
    say('فَبِءَييِءَاالَااءِرَببِكُمَاتُكَذذِبَاان');
    wait(3);
    final prompt = of(PrayerEventKind.prompt).single;
    expect(prompt.reason, PrayerReason.wrongWord);
    expect(prompt.words, ayah(b, 7).take(2).map((w) => w.uthmani).join(' '));
  });

  test('going back over the last ayah is not a mistake', () async {
    final b = await words(2);
    await session.start(2, 6);
    await reciteFatiha();
    await recite(ayah(b, 6));
    await recite(ayah(b, 7));
    for (final w in ayah(b, 7)) {
      say(w.skeleton); // repeated: heard, nothing new matched
    }
    wait(1);
    expect(of(PrayerEventKind.mistake), isEmpty);
  });

  test('āmīn, taʿawwudh and basmala before the plan are not mistakes',
      () async {
    final b = await words(2);
    await session.start(2, 6);
    await reciteFatiha();
    say(PrayerSession.aminPhonemes);
    say(PrayerSession.istiadhaPhonemes);
    say(fatiha.where((w) => w.ref.ayah == 1).map((w) => w.skeleton).join());
    wait(1);
    await recite(ayah(b, 6));
    expect(of(PrayerEventKind.mistake), isEmpty);
  });

  test('a long pause part way through an ayah prompts the next word once',
      () async {
    final b = await words(2);
    await session.start(2, 6);
    await reciteFatiha();
    await recite(ayah(b, 6).take(3));
    wait(3);
    expect(of(PrayerEventKind.prompt), isEmpty);
    wait(1);
    final prompt = of(PrayerEventKind.prompt).single;
    expect(prompt.reason, PrayerReason.pauseMidAyah);
    expect(prompt.words, ayah(b, 6).elementAt(3).uthmani);
    wait(20);
    expect(of(PrayerEventKind.prompt), hasLength(1));

    // Carrying on and stopping again prompts again.
    await recite(ayah(b, 6).skip(3).take(1));
    wait(4);
    expect(of(PrayerEventKind.prompt), hasLength(2));
  });

  test('a pause at the end of an ayah waits longer', () async {
    final b = await words(2);
    await session.start(2, 6);
    await reciteFatiha();
    await recite(ayah(b, 6));
    wait(7);
    expect(of(PrayerEventKind.prompt), isEmpty);
    wait(1);
    final prompt = of(PrayerEventKind.prompt).single;
    expect(prompt.reason, PrayerReason.pauseBetweenAyahs);
    expect(prompt.where, const MushafWord(2, 7, 0));
  });

  test('no pause prompt before anything of the plan is recited', () async {
    // The last rakʿahs: al-Fātiḥa, then straight to rukūʿ.
    await session.start(2, 6);
    await reciteFatiha();
    wait(60);
    expect(of(PrayerEventKind.prompt), isEmpty);
  });

  test('the plan carries on into the next surah', () async {
    final ikhlas = await words(112);
    final falaq = await words(113);
    await session.start(112, 4);
    await reciteFatiha();
    await recite(ayah(ikhlas, 4));
    expect(of(PrayerEventKind.nextSurah).single.where,
        const MushafWord(113, 1, 0));
    expect(tracker.resumes.last, (113, 1));
    say(fatiha.where((w) => w.ref.ayah == 1).map((w) => w.skeleton).join());
    wait(1);
    await recite(ayah(falaq, 1));
    expect(of(PrayerEventKind.mistake), isEmpty);
  });

  test('stop ends the session', () async {
    await session.start(2, 6);
    session.stop();
    expect(session.phase, PrayerPhase.idle);
    expect(of(PrayerEventKind.stopped), hasLength(1));
    await reciteFatiha();
    expect(tracker.resumes, isEmpty);
    expect(log().first, startsWith('started'));
  });
}

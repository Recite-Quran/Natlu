import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recite_quran/recite_quran.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:the_great_quran/services/prayer/prayer_mode.dart';
import 'package:the_great_quran/services/recitation/auto_correct.dart';
import 'package:the_great_quran/services/recitation/auto_correct_settings.dart';
import 'package:the_great_quran/services/recitation/phrase_spotter.dart';
import 'package:the_great_quran/services/recitation/plan_text.dart';
import 'package:the_great_quran/services/recitation/recitation_event.dart';
import 'package:the_great_quran/services/recitation/recitation_session.dart';
import 'package:the_great_quran/services/recitation/recitation_tracker.dart';
import 'package:the_great_quran/services/recitation/recitation_voice.dart';
import 'package:the_great_quran/services/recitation/recited_word.dart';

/// Behaves like the app's tracker: words get states as the reciter reaches
/// them, the ayah expected moves on at the end of each ayah, it stops at
/// the end of the surah, resuming at an ayah clears it and what follows,
/// listeners hear about every word.
class FakeTracker extends ChangeNotifier implements RecitationTracker {
  FakeTracker(this.surahs);

  /// The words of the surahs it may follow.
  final Map<int, List<PlanWord>> surahs;
  final Map<MushafWord, RecitedWordState> states = {};
  final List<(int, int)> resumes = [];
  int pauses = 0;

  @override
  bool following = false;
  @override
  int surah = 1;
  @override
  int? activeAyah = 1;
  @override
  int revision = 0;

  @override
  RecitedWordState stateOf(MushafWord word) =>
      states[word] ?? RecitedWordState.unspoken;

  @override
  void pause() {
    following = false;
    pauses++;
    notifyListeners();
  }

  @override
  Future<void> resumeAt(int surah, int ayah) async {
    if (surah != this.surah) {
      states.clear();
    } else {
      states.removeWhere((w, _) => w.surah == surah && w.ayah >= ayah);
    }
    this.surah = surah;
    activeAyah = ayah;
    following = true;
    revision++;
    resumes.add((surah, ayah));
    notifyListeners();
  }

  /// The ayah is tapped: the tracker expects it next (from its first word
  /// not yet recited), keeping what it shows.
  void tap(int ayah) {
    activeAyah = ayah;
    notifyListeners();
  }

  /// Clears every highlight (the reciter starts over).
  void clear() {
    states.clear();
    revision++;
    notifyListeners();
  }

  void mark(MushafWord w, RecitedWordState s) {
    states[w] = s;
    final words = surahs[w.surah];
    if (w.surah == surah && words != null) {
      activeAyah = w.ayah;
      if (words.last.ref == w) {
        following = false; // the end of the surah
      } else if (words.lastWhere((x) => x.ref.ayah == w.ayah).ref == w) {
        activeAyah = w.ayah + 1;
      }
    }
    notifyListeners();
  }
}

/// Records what auto-correct plays; each sound lasts until [finish].
class FakeOutput implements PromptAudioOutput {
  final List<String> played = [];
  final List<(int, int)> prepared = [];
  bool canRead = true;
  int stops = 0;

  /// While set, words being read are still loading.
  Completer<void>? loading;
  Completer<void>? _current;

  Future<void> _sound(String name) {
    played.add(name);
    return (_current = Completer<void>()).future;
  }

  /// The sound playing now ends.
  Future<void> finish() async {
    _current?.complete();
    _current = null;
    await pumpEventQueue();
  }

  @override
  Future<void> beep() => _sound('beep');

  @override
  Future<bool> playWords(int surah, int ayah, int firstWord, int lastWord,
      {void Function()? onAudible}) async {
    if (!canRead) return false;
    await loading?.future;
    onAudible?.call();
    await _sound('$surah:$ayah words $firstWord-$lastWord');
    return true;
  }

  @override
  Future<void> stop() async {
    stops++;
    _current?.complete();
    _current = null;
  }

  @override
  void prepare(int surah, int ayah) => prepared.add((surah, ayah));

  @override
  void dispose() {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late QuranRepository repo;
  late QuranPlanText text;
  late List<PlanWord> fatiha;
  late FakeTracker tracker;
  final surahs = <int, List<PlanWord>>{};
  late AutoCorrectSettings settings;
  late RecitationSession session;
  late DateTime clock;
  int epoch = 0;

  /// Auto-correct alone, as in an ordinary recitation.
  RecitationSession buildAlone() {
    final log = RecitationLog();
    return RecitationSession(
      log: log,
      autoCorrect: AutoCorrect(
        tracker: tracker,
        text: text,
        settings: settings,
        log: log,
        extraPhrases: [
          AutoCorrect.istiadhaPhonemes,
          fatiha.where((w) => w.ref.ayah == 1).map((w) => w.skeleton).join(),
        ],
        now: () => clock,
      ),
      autoTick: false,
    );
  }

  /// Prayer mode with auto-correct.
  RecitationSession build({bool extras = true}) {
    final log = RecitationLog();
    return RecitationSession(
      log: log,
      prayer: PrayerMode(
        tracker: tracker,
        text: text,
        log: log,
        fatihaEnd: PrayerPhrases.fatihaEnd(repo.getVerse(1, 7)!),
        now: () => clock,
      ),
      autoCorrect: AutoCorrect(
        tracker: tracker,
        text: text,
        settings: settings,
        log: log,
        extraPhrases: extras
            ? [
                AutoCorrect.istiadhaPhonemes,
                fatiha
                    .where((w) => w.ref.ayah == 1)
                    .map((w) => w.skeleton)
                    .join(),
                AutoCorrect.aminPhonemes,
              ]
            : const [],
        now: () => clock,
      ),
      autoTick: false,
    );
  }

  setUpAll(() async {
    repo = QuranRepository(QuranMetadataService());
    text = QuranPlanText(repo);
    fatiha = await text.wordsOf(1);
    for (final s in [2, 9, 112, 113]) {
      surahs[s] = await text.wordsOf(s);
    }
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    clock = DateTime(2026, 10, 15, 20);
    tracker = FakeTracker(surahs);
    settings = AutoCorrectSettings.forTest();
    await settings.load();
    session = build();
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

  Iterable<RecitationEvent> of(RecitationEventKind k) =>
      session.events.where((e) => e.kind == k);

  test('waits for al-Fātiḥa, then follows the plan from its start', () async {
    await session.start(surah: 2, ayah: 6);
    expect(session.prayer!.phase, PrayerPhase.waitingForFatiha);
    expect(tracker.pauses, 1);

    say(PrayerPhrases.takbirPhonemes); // takbīrat al-iḥrām
    await reciteFatiha();
    expect(session.prayer!.phase, PrayerPhase.following);
    expect(tracker.resumes, [(2, 6)]);
    expect(of(RecitationEventKind.fatihaEnded).single.where,
        const MushafWord(2, 6, 0));
    expect(session.position, const MushafWord(2, 6, 0));
  });

  test('"Allāhu akbar" stops following; the next al-Fātiḥa resumes it',
      () async {
    final b = await words(2);
    await session.start(surah: 2, ayah: 6);
    await reciteFatiha();
    say(AutoCorrect.aminPhonemes);
    for (int a = 6; a <= 8; a++) {
      await recite(ayah(b, a));
    }
    say(PrayerPhrases.takbirPhonemes);
    expect(session.prayer!.phase, PrayerPhase.waitingForFatiha);
    expect(tracker.pauses, 2);
    expect(
        of(RecitationEventKind.takbir).single.where, const MushafWord(2, 9, 0));

    // Rukūʿ, sujūd... nothing is followed or prompted.
    say('سُبحَاانَرَببِيَلعَظِۦۦم');
    wait(30);
    expect(of(RecitationEventKind.prompt), isEmpty);

    await reciteFatiha();
    expect(tracker.resumes, [(2, 6), (2, 9)]);
    await recite(ayah(b, 9));
    expect(of(RecitationEventKind.mistake), isEmpty);
    expect(session.position, const MushafWord(2, 10, 0));
  });

  test('"Allāhu" taken as the next ayah\'s first word resumes that ayah',
      () async {
    // 2:255 starts with "اللَّهُ".
    final b = await words(2);
    await session.start(surah: 2, ayah: 254);
    await reciteFatiha();
    await recite(ayah(b, 254));
    say('ءَللَااهُ');
    tracker.mark(const MushafWord(2, 255, 0), RecitedWordState.recited);
    say('ءَكبَر');
    expect(of(RecitationEventKind.takbir).single.where,
        const MushafWord(2, 255, 0));
  });

  test('reciting "مِنَ اللَّهِ أَكْبَرُ" (9:72) is not the takbīr', () async {
    final t = await words(9);
    await session.start(surah: 9, ayah: 72);
    await reciteFatiha();
    await recite(ayah(t, 72));
    expect(session.prayer!.phase, PrayerPhase.following);
    expect(of(RecitationEventKind.takbir), isEmpty);
  });

  test('a left-out word: beep, then prompted if not corrected', () async {
    final b = await words(2);
    await session.start(surah: 2, ayah: 7);
    await reciteFatiha();
    // عَلَىٰ: the same word comes again later in the ayah (وَعَلَىٰ), which
    // isn't going back to it.
    final missing = ayah(b, 7).elementAt(2);
    await recite(ayah(b, 7).take(4),
        marks: {missing.ref: RecitedWordState.mistake});

    final mistake = of(RecitationEventKind.mistake).single;
    expect(mistake.reason, RecitationReason.skipped);
    expect(mistake.words, missing.uthmani);
    wait(2);
    expect(of(RecitationEventKind.prompt), isEmpty);
    wait(1);
    final prompt = of(RecitationEventKind.prompt).single;
    expect(prompt.words, missing.uthmani);
    expect(prompt.where, missing.ref);
  });

  test('a left-out word said again in time is corrected, not prompted',
      () async {
    final b = await words(2);
    await session.start(surah: 2, ayah: 7);
    await reciteFatiha();
    final missing = ayah(b, 7).elementAt(3); // عَلَىٰ قُلُوبِهِمْ ...
    await recite(ayah(b, 7).take(5),
        marks: {missing.ref: RecitedWordState.mistake});
    say(missing.skeleton + ayah(b, 7).elementAt(4).skeleton);
    wait(1);
    expect(of(RecitationEventKind.corrected), hasLength(1));
    await recite(ayah(b, 7).skip(5));
    wait(5);
    expect(of(RecitationEventKind.prompt), isEmpty);
  });

  test('the same word further on is not a correction', () async {
    final b = await words(2);
    await session.start(surah: 2, ayah: 7);
    await reciteFatiha();
    final missing = ayah(b, 7).elementAt(2); // عَلَىٰ
    await recite(ayah(b, 7), marks: {missing.ref: RecitedWordState.mistake});
    wait(3);
    expect(of(RecitationEventKind.corrected), isEmpty);
    expect(of(RecitationEventKind.prompt).single.words, missing.uthmani);
  });

  test('a wrong word: beep; moving on again corrects it', () async {
    final b = await words(2);
    await session.start(surah: 2, ayah: 6);
    await reciteFatiha();
    await recite(ayah(b, 6));
    say('فَبِءَييِءَاالَااءِرَببِكُمَاتُكَذذِبَاان'); // 55:13, not 2:7
    expect(of(RecitationEventKind.mistake).single.reason,
        RecitationReason.wrongWord);
    expect(of(RecitationEventKind.mistake).single.where,
        const MushafWord(2, 7, 0));
    await recite(ayah(b, 7).take(2));
    expect(of(RecitationEventKind.corrected), hasLength(1));
    await recite(ayah(b, 7).skip(2));
    wait(5);
    expect(of(RecitationEventKind.prompt), isEmpty);
  });

  test('a wrong word not corrected prompts the expected words', () async {
    await settings.set(AutoCorrectSettings.promptWords, 2);
    final b = await words(2);
    await session.start(surah: 2, ayah: 6);
    await reciteFatiha();
    await recite(ayah(b, 6));
    say('فَبِءَييِءَاالَااءِرَببِكُمَاتُكَذذِبَاان');
    wait(3);
    final prompt = of(RecitationEventKind.prompt).single;
    expect(prompt.reason, RecitationReason.wrongWord);
    expect(prompt.words, ayah(b, 7).take(2).map((w) => w.uthmani).join(' '));
    expect(prompt.wordRefs, ayah(b, 7).take(2).map((w) => w.ref).toList());
  });

  test('going back over the last ayah is not a mistake', () async {
    final b = await words(2);
    await session.start(surah: 2, ayah: 6);
    await reciteFatiha();
    await recite(ayah(b, 6));
    await recite(ayah(b, 7));
    for (final w in ayah(b, 7)) {
      say(w.skeleton); // repeated: heard, nothing new matched
    }
    wait(1);
    expect(of(RecitationEventKind.mistake), isEmpty);
  });

  test('āmīn, taʿawwudh and basmala before the plan are not mistakes',
      () async {
    final b = await words(2);
    await session.start(surah: 2, ayah: 6);
    await reciteFatiha();
    say(AutoCorrect.aminPhonemes);
    say(AutoCorrect.istiadhaPhonemes);
    say(fatiha.where((w) => w.ref.ayah == 1).map((w) => w.skeleton).join());
    wait(1);
    await recite(ayah(b, 6));
    expect(of(RecitationEventKind.mistake), isEmpty);
  });

  test('a long pause part way through an ayah prompts the next word once',
      () async {
    final b = await words(2);
    await session.start(surah: 2, ayah: 6);
    await reciteFatiha();
    await recite(ayah(b, 6).take(3));
    wait(3);
    expect(of(RecitationEventKind.prompt), isEmpty);
    wait(1);
    final prompt = of(RecitationEventKind.prompt).single;
    expect(prompt.reason, RecitationReason.pauseMidAyah);
    expect(prompt.words, ayah(b, 6).elementAt(3).uthmani);
    wait(20);
    expect(of(RecitationEventKind.prompt), hasLength(1));

    // Carrying on and stopping again prompts again.
    await recite(ayah(b, 6).skip(3).take(1));
    wait(4);
    expect(of(RecitationEventKind.prompt), hasLength(2));
  });

  test('a pause at the end of an ayah waits longer', () async {
    final b = await words(2);
    await session.start(surah: 2, ayah: 6);
    await reciteFatiha();
    await recite(ayah(b, 6));
    wait(7);
    expect(of(RecitationEventKind.prompt), isEmpty);
    wait(1);
    final prompt = of(RecitationEventKind.prompt).single;
    expect(prompt.reason, RecitationReason.pauseBetweenAyahs);
    expect(prompt.where, const MushafWord(2, 7, 0));
  });

  test('no pause prompt before anything of the plan is recited', () async {
    // The last rakʿahs: al-Fātiḥa, then straight to rukūʿ.
    await session.start(surah: 2, ayah: 6);
    await reciteFatiha();
    wait(60);
    expect(of(RecitationEventKind.prompt), isEmpty);
  });

  test('the plan carries on into the next surah', () async {
    final ikhlas = await words(112);
    final falaq = await words(113);
    await session.start(surah: 112, ayah: 4);
    await reciteFatiha();
    await recite(ayah(ikhlas, 4));
    expect(of(RecitationEventKind.nextSurah).single.where,
        const MushafWord(113, 1, 0));
    expect(tracker.resumes.last, (113, 1));
    say(fatiha.where((w) => w.ref.ayah == 1).map((w) => w.skeleton).join());
    wait(1);
    await recite(ayah(falaq, 1));
    expect(of(RecitationEventKind.mistake), isEmpty);
  });

  test('stop ends the session', () async {
    await session.start(surah: 2, ayah: 6);
    session.stop();
    expect(session.prayer!.phase, PrayerPhase.idle);
    expect(of(RecitationEventKind.stopped), hasLength(1));
    await reciteFatiha();
    expect(tracker.resumes, isEmpty);
    expect(log().first, startsWith('started'));
  });

  test('auto-correct turned off during the prayer: silent from the tracker on',
      () async {
    final b = await words(2);
    await session.start(surah: 2, ayah: 6);
    await reciteFatiha();
    await recite(ayah(b, 6));
    session.replaceAutoCorrect(AutoCorrect(
      tracker: tracker,
      text: text,
      settings: settings,
      log: session.log,
      extraPhrases: const [],
      now: () => clock,
      silent: true,
    ));
    await pumpEventQueue();
    expect(session.autoCorrect!.silent, isTrue);
    expect(session.position, const MushafWord(2, 7, 0));
    final missing = ayah(b, 7).elementAt(2);
    await recite(ayah(b, 7).take(4),
        marks: {missing.ref: RecitedWordState.mistake});
    expect(of(RecitationEventKind.mistake).single.where, missing.ref);
    expect(log().first, startsWith('started'), reason: 'the same log');
  });

  group('auto-correct alone', () {
    late List<PlanWord> b;

    setUp(() async {
      b = await words(2);
      session.dispose();
      session = buildAlone();
    });

    /// The microphone is turned on with the tracker at [ayah] of [surah].
    Future<void> startAt(int ayah, {int surah = 2}) async {
      await tracker.resumeAt(surah, ayah);
      await session.start();
      await pumpEventQueue();
    }

    test('follows from where the tracker is, without al-Fātiḥa', () async {
      await startAt(7);
      expect(session.position, const MushafWord(2, 7, 0));
      final missing = ayah(b, 7).elementAt(2);
      await recite(ayah(b, 7).take(4),
          marks: {missing.ref: RecitedWordState.mistake});
      expect(of(RecitationEventKind.mistake).single.where, missing.ref);
      wait(3);
      expect(of(RecitationEventKind.prompt).single.where, missing.ref);
      expect(of(RecitationEventKind.started), isEmpty);
    });

    test('an ayah tapped: it follows from there, with no mistake', () async {
      await startAt(6);
      await recite(ayah(b, 6).take(3));
      tracker.tap(20);
      await pumpEventQueue();
      expect(session.position, const MushafWord(2, 20, 0));
      await recite(ayah(b, 20));
      expect(of(RecitationEventKind.mistake), isEmpty);
      expect(session.position, const MushafWord(2, 21, 0));
    });

    test('the tracker going on from further on is no mistake', () async {
      // As when it finds the reciter elsewhere in the surah.
      await startAt(6);
      await recite(ayah(b, 6).take(2));
      await recite(ayah(b, 10).take(2));
      expect(of(RecitationEventKind.mistake), isEmpty);
      expect(session.position, ayah(b, 10).elementAt(2).ref);
      await recite(ayah(b, 10).skip(2));
      expect(of(RecitationEventKind.mistake), isEmpty);
    });

    test('an ayah recited again, over what is shown, is followed quietly',
        () async {
      await startAt(6);
      final w7 = ayah(b, 7).toList();
      await recite(ayah(b, 6));
      await recite(w7, marks: {w7[2].ref: RecitedWordState.mistake});
      wait(3);
      await recite(ayah(b, 8));
      final mistakes = of(RecitationEventKind.mistake).length;
      final prompts = of(RecitationEventKind.prompt).length;
      expect(mistakes, 1);

      // Back to 2:7, and recites it again: the tracker matches the words
      // it already shows (the word left out turns green).
      tracker.tap(7);
      await pumpEventQueue();
      expect(session.position, const MushafWord(2, 7, 0));
      for (final w in w7) {
        say(w.skeleton);
        wait(1);
        tracker.mark(w.ref, RecitedWordState.recited);
      }
      await pumpEventQueue();
      expect(of(RecitationEventKind.mistake), hasLength(mistakes));
      expect(of(RecitationEventKind.prompt), hasLength(prompts));
      expect(session.position, const MushafWord(2, 8, 0));
    });

    test('highlights cleared: it follows from the start again', () async {
      await startAt(6);
      await recite(ayah(b, 6));
      await recite(ayah(b, 7).take(3));
      tracker.clear();
      tracker.tap(6);
      await pumpEventQueue();
      expect(session.position, const MushafWord(2, 6, 0));
      await recite(ayah(b, 6));
      expect(of(RecitationEventKind.mistake), isEmpty);
    });

    test('stopped and following again: no pause prompt before reciting',
        () async {
      await startAt(6);
      await recite(ayah(b, 6));
      tracker.pause();
      await tracker.resumeAt(2, 7);
      await pumpEventQueue();
      wait(20);
      expect(of(RecitationEventKind.prompt), isEmpty);
      await recite(ayah(b, 7).take(2));
      wait(4);
      expect(of(RecitationEventKind.prompt).single.reason,
          RecitationReason.pauseMidAyah);
    });

    test('at the end of the surah the tracker stops, and so does it', () async {
      await startAt(4, surah: 112);
      await recite(ayah(await words(112), 4));
      wait(30);
      expect(of(RecitationEventKind.prompt), isEmpty);
      expect(tracker.resumes, [(112, 4)]);
    });
  });

  group('sounds', () {
    late FakeOutput out;
    late RecitationVoice voice;

    Future<void> startVoice(int surah, int ayah) async {
      await session.start(surah: surah, ayah: ayah);
      out = FakeOutput();
      voice = RecitationVoice(session: session, output: out);
      addTearDown(voice.dispose);
    }

    Future<PlanWord> leaveOutAWord() async {
      final b = await words(2);
      await reciteFatiha();
      final missing = ayah(b, 7).elementAt(2);
      await recite(ayah(b, 7).take(4),
          marks: {missing.ref: RecitedWordState.mistake});
      await pumpEventQueue();
      return missing;
    }

    test('a mistake beeps; the prompt reads the words', () async {
      await startVoice(2, 7);
      expect(out.prepared, containsAll([(2, 7), (2, 8)]));
      final missing = await leaveOutAWord();
      expect(out.played, ['beep']);
      expect(voice.playing.value, PromptSound.beep);
      await out.finish();
      expect(voice.playing.value, isNull);

      wait(3);
      await pumpEventQueue();
      expect(
          out.played.last,
          '2:7 words ${missing.ref.wordIndex0}-'
          '${missing.ref.wordIndex0}');
      expect(voice.playing.value, PromptSound.leftOutWords);
      await out.finish();
      expect(voice.playing.value, isNull);
    });

    test('only words being heard count as playing, not while loading',
        () async {
      await startVoice(2, 7);
      out.loading = Completer<void>();
      await leaveOutAWord();
      expect(voice.playing.value, PromptSound.beep);
      await out.finish();
      wait(3);
      await pumpEventQueue();
      expect(voice.playing.value, isNull, reason: 'still loading');
      out.loading!.complete();
      await pumpEventQueue();
      expect(voice.playing.value, PromptSound.leftOutWords);
      await out.finish();
      expect(voice.playing.value, isNull);
    });

    test('a prompt of several words reads them, within the ayah', () async {
      await settings.set(AutoCorrectSettings.promptWords, 3);
      final b = await words(2);
      await startVoice(2, 6);
      await reciteFatiha();
      await recite(ayah(b, 6));
      wait(8);
      await pumpEventQueue();
      expect(out.played, ['2:7 words 0-2']);
      expect(voice.playing.value, PromptSound.words,
          reason: 'the next words: the microphone is muted for them');

      // Near the end of the ayah the prompt stops at the ayah's end.
      await out.finish();
      final n = ayah(b, 7).length;
      await recite(ayah(b, 7).take(n - 1));
      wait(4);
      await pumpEventQueue();
      expect(out.played.last, '2:7 words ${n - 1}-${n - 1}');
    });

    test('a prompt cuts a beep short; a beep waits for nothing', () async {
      await startVoice(2, 7);
      await leaveOutAWord();
      expect(out.played, ['beep']);
      wait(3); // not corrected: prompted while still beeping
      await pumpEventQueue();
      expect(out.stops, 1);
      expect(out.played.last, startsWith('2:7 words'));
      expect(voice.playing.value, PromptSound.leftOutWords);
    });

    test('words that cannot be played are replaced by a double beep', () async {
      await startVoice(2, 7);
      out.canRead = false;
      await leaveOutAWord();
      await out.finish();
      wait(3);
      await pumpEventQueue();
      expect(out.played, ['beep', 'beep']);
      await out.finish();
      expect(out.played, ['beep', 'beep', 'beep']);
      expect(voice.playing.value, PromptSound.beep);
      await out.finish();
      expect(voice.playing.value, isNull);
    });

    test('the takbīr and stopping silence it', () async {
      await startVoice(2, 7);
      await leaveOutAWord();
      say(PrayerPhrases.takbirPhonemes);
      await pumpEventQueue();
      expect(out.stops, 1);
      expect(voice.playing.value, isNull);
      session.stop();
      await pumpEventQueue();
      expect(out.stops, 2);
    });

    test('keeps the ayahs ahead ready', () async {
      final b = await words(2);
      await startVoice(2, 6);
      await reciteFatiha();
      await recite(ayah(b, 6));
      await recite(ayah(b, 7).take(1));
      expect(out.prepared, containsAll([(2, 6), (2, 7), (2, 8)]));
    });
  });
}

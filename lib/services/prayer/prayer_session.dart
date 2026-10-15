import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:recite_quran/recite_quran.dart' show QuranRepository;

import 'recited_word.dart';
import 'phoneme_transcript.dart';
import 'phrase_spotter.dart';
import 'plan_text.dart';
import 'prayer_settings.dart';

/// What prayer mode needs from the word tracker.
abstract class PrayerTracker implements Listenable {
  /// What the tracker says about [word] (notifies after every word).
  RecitedWordState stateOf(MushafWord word);

  /// Stops following the recitation.
  void pause();

  /// Follows the recitation again, expecting [ayah] of [surah] from its
  /// first word.
  Future<void> resumeAt(int surah, int ayah);
}

enum PrayerPhase {
  /// Not started, or stopped.
  idle,

  /// Not following: waiting for the end of al-Fātiḥa.
  waitingForFatiha,

  /// Following the plan.
  following,
}

enum PrayerEventKind {
  /// Prayer mode started; [PrayerEvent.where] is where the plan starts.
  started,

  /// The end of al-Fātiḥa was heard; following from [PrayerEvent.where].
  fatihaEnded,

  /// "Allāhu akbar" was heard; the plan will resume at [PrayerEvent.where].
  takbir,

  /// The plan moved on to the next surah.
  nextSurah,

  /// A mistake: prayer mode would beep.
  mistake,

  /// The reciter corrected the mistake in time.
  corrected,

  /// Prayer mode would read [PrayerEvent.words] aloud.
  prompt,

  /// Prayer mode was stopped.
  stopped,
}

enum PrayerReason {
  /// Word(s) left out (the tracker marked them as mistakes).
  skipped,

  /// Speech that doesn't match the expected word.
  wrongWord,

  /// A long pause part way through an ayah.
  pauseMidAyah,

  /// A long pause at the end of an ayah.
  pauseBetweenAyahs,
}

/// Something prayer mode noticed or would have done.
@immutable
class PrayerEvent {
  const PrayerEvent(this.kind, this.at, {this.where, this.words, this.reason});

  final PrayerEventKind kind;
  final DateTime at;

  /// The plan position the event is about.
  final MushafWord? where;

  /// The words of a mistake or a prompt, as written.
  final String? words;
  final PrayerReason? reason;

  @override
  String toString() => '${kind.name}'
      '${reason == null ? '' : ' (${reason!.name})'}'
      '${where == null ? '' : ' at $where'}'
      '${words == null ? '' : ': $words'}';
}

class _Mistake {
  _Mistake(this.reason, this.first, this.count, this.at, this.mark);
  final PrayerReason reason;

  /// Index in the surah's words of the first word to prompt, and how many
  /// words were left out (for [PrayerReason.skipped]).
  final int first;
  final int count;
  final DateTime at;

  /// [PhonemeTranscript.length] when it happened.
  final int mark;
}

/// Prayer mode, rehearsal version: follows a continuous recitation plan
/// through the prayer and records what it would do (beep at a mistake, read
/// the right words aloud) without making a sound.
///
/// - It starts waiting for al-Fātiḥa. When the end of al-Fātiḥa is heard it
///   follows the plan from where it left off; "Allāhu akbar" stops it until
///   the next al-Fātiḥa ends. The plan carries on into the next surah.
/// - A word the tracker marks as a mistake (left out, or wrong enough to be
///   skipped over), or speech that doesn't move the tracker on, is a
///   mistake. If the reciter doesn't correct it within the correction time,
///   the right words are prompted.
/// - A long pause (separate limits part way through an ayah and at its end)
///   prompts the next words, once the reciter has recited something of the
///   plan in this rakʿah.
class PrayerSession extends ChangeNotifier {
  PrayerSession({
    required this.tracker,
    required this.text,
    required this.settings,
    required PhraseSpotter fatihaEnd,
    required List<String> extraPhrases,
    DateTime Function()? now,
    this.log,
    this.autoTick = true,
  })  : _fatihaEnd = fatihaEnd,
        _extras = extraPhrases.map(phonemeSkeleton).join(),
        _now = now ?? DateTime.now {
    transcript = PhonemeTranscript(now: _now);
  }

  /// Creates a session for the app's Quran data.
  static Future<PrayerSession> create({
    required PrayerTracker tracker,
    required QuranRepository repository,
    void Function(String message)? log,
  }) async {
    final text = QuranPlanText(repository);
    final fatiha = await text.wordsOf(1);
    await PrayerSettings.instance.load();
    return PrayerSession(
      tracker: tracker,
      text: text,
      settings: PrayerSettings.instance,
      fatihaEnd: PrayerPhrases.fatihaEnd(repository.getVerse(1, 7)!),
      extraPhrases: [
        istiadhaPhonemes,
        // The basmala as recited at the start of a surah (al-Fātiḥa 1:1).
        fatiha.where((w) => w.ref.ayah == 1).map((w) => w.skeleton).join(),
        aminPhonemes,
      ],
      log: log,
    );
  }

  /// "أعوذ بالله من الشيطان الرجيم".
  static const istiadhaPhonemes = 'ءَعُۥۥذُبِللَااهِمِنَششَيطَاانِررَجِۦۦم';

  /// "آمين".
  static const aminPhonemes = 'ءَاامِۦۦن';

  final PrayerTracker tracker;
  final PlanText text;
  final PrayerSettings settings;
  final void Function(String message)? log;

  /// Whether the session runs its own timer; tests call [tick] instead.
  final bool autoTick;

  final PhraseSpotter _fatihaEnd;
  final PhraseSpotter _takbir = PrayerPhrases.takbir();
  final PhraseSpotter _takbirLookalike = PhraseSpotter(
      PrayerPhrases.takbirPhonemes,
      maxDistance: 3,
      mustContain: const ['ك']);

  /// Skeleton of what may be said before the plan in a rakʿah
  /// (taʿawwudh, basmala, āmīn).
  final String _extras;
  final DateTime Function() _now;

  late final PhonemeTranscript transcript;

  PrayerPhase _phase = PrayerPhase.idle;
  final List<PrayerEvent> _events = [];
  Timer? _timer;

  int _surah = 0;
  List<PlanWord> _words = const [];
  int _cursor = 0;
  MushafWord? _resume;

  int _phaseMark = 0;
  int _progressMark = 0;
  DateTime _lastProgressAt = DateTime(0);
  DateTime _lastPromptAt = DateTime(0);
  int _wordsThisRakah = 0;
  bool _pausePrompted = false;
  _Mistake? _mistake;
  bool _busy = false;

  PrayerPhase get phase => _phase;
  List<PrayerEvent> get events => List.unmodifiable(_events);

  /// Where the plan resumes after the next al-Fātiḥa (while waiting), or
  /// the next expected word (while following).
  MushafWord? get position =>
      _phase == PrayerPhase.following && _cursor < _words.length
          ? _words[_cursor].ref
          : _resume;

  /// Starts prayer mode with the plan beginning at [ayah] of [surah].
  Future<void> start(int surah, int ayah) async {
    if (_phase != PrayerPhase.idle) return;
    await _loadSurah(surah);
    _resume = MushafWord(surah, ayah, 0);
    tracker.addListener(_onTrackerChanged);
    tracker.pause();
    transcript.clear();
    _enterWaiting();
    _emit(PrayerEvent(PrayerEventKind.started, _now(), where: _resume));
    if (autoTick) {
      _timer = Timer.periodic(const Duration(milliseconds: 250), (_) => tick());
    }
  }

  /// Stops prayer mode.
  void stop() {
    if (_phase == PrayerPhase.idle) return;
    _timer?.cancel();
    _timer = null;
    tracker.removeListener(_onTrackerChanged);
    _phase = PrayerPhase.idle;
    _emit(PrayerEvent(PrayerEventKind.stopped, _now(), where: position));
  }

  @override
  void dispose() {
    stop();
    super.dispose();
  }

  /// Feeds one speech recognizer result.
  void addTranscription({
    required List<String> tokens,
    bool isFinal = false,
    int epoch = 0,
  }) {
    if (_phase == PrayerPhase.idle) return;
    transcript.addResult(tokens: tokens, isFinal: isFinal, epoch: epoch);
    tick();
  }

  /// Re-checks everything time-based. Called every 250 ms while running.
  void tick() {
    if (_busy) return;
    switch (_phase) {
      case PrayerPhase.idle:
        return;
      case PrayerPhase.waitingForFatiha:
        if (_fatihaEnd.foundIn(transcript.since(_phaseMark))) {
          unawaited(_startFollowing());
        }
      case PrayerPhase.following:
        if (_takbirHeard()) {
          _stopFollowing();
          return;
        }
        _checkMistake();
        _checkWrongWord();
        _checkPause();
    }
  }

  // ── Phases ────────────────────────────────────────────────────────────

  void _enterWaiting() {
    _phase = PrayerPhase.waitingForFatiha;
    _phaseMark = transcript.length;
    _mistake = null;
    notifyListeners();
  }

  Future<void> _startFollowing() async {
    _busy = true;
    try {
      final resume = _resume!;
      if (resume.surah != _surah) await _loadSurah(resume.surah);
      _cursor = _words.indexWhere((w) => w.ref.ayah == resume.ayah);
      if (_cursor < 0) _cursor = 0;
      await tracker.resumeAt(resume.surah, resume.ayah);
      _phase = PrayerPhase.following;
      _wordsThisRakah = 0;
      _markProgress();
      _phaseMark = transcript.length;
      _mistake = null;
      _emit(PrayerEvent(PrayerEventKind.fatihaEnded, _now(),
          where: _words[_cursor].ref));
    } finally {
      _busy = false;
    }
  }

  void _stopFollowing() {
    tracker.pause();
    // Resume from the start of the ayah the reciter was in: normally the
    // next ayah, as recitation ends at the end of an ayah.
    final next = _cursor < _words.length ? _words[_cursor].ref : null;
    _resume = next == null
        ? MushafWord(math.min(_surah + 1, 114), 1, 0)
        : MushafWord(next.surah, next.ayah, 0);
    _enterWaiting();
    _emit(PrayerEvent(PrayerEventKind.takbir, _now(), where: _resume));
  }

  bool _takbirHeard() {
    final from = math.max(_phaseMark, transcript.length - 60);
    if (!_takbir.foundIn(transcript.since(from))) return false;
    // A few ayahs contain "اللَّهِ أَكْبَرُ" (9:72, 29:45, 40:10): reciting
    // them isn't the takbīr of the prayer.
    final lo = math.max(0, _cursor - 8);
    final hi = math.min(_words.length, _cursor + 8);
    final nearby = _words.sublist(lo, hi).map((w) => w.skeleton).join();
    return !_takbirLookalike.foundIn(nearby);
  }

  // ── Following the words ───────────────────────────────────────────────

  void _onTrackerChanged() {
    if (_phase != PrayerPhase.following || _busy) return;
    final skipped = <int>[];
    int advanced = 0;
    while (_cursor < _words.length) {
      final state = tracker.stateOf(_words[_cursor].ref);
      if (state == RecitedWordState.unspoken) break;
      if (state == RecitedWordState.mistake) skipped.add(_cursor);
      _cursor++;
      advanced++;
    }
    if (advanced == 0) return;
    _wordsThisRakah += advanced;
    _markProgress();

    final open = _mistake;
    if (skipped.isNotEmpty) {
      // Words left out. A wrong word that the tracker then skipped over
      // becomes this mistake, keeping its start time.
      final first = skipped.first;
      final count = skipped.last - first + 1;
      if (open == null) {
        _mistake = _Mistake(
            PrayerReason.skipped, first, count, _now(), transcript.length);
        _emit(PrayerEvent(PrayerEventKind.mistake, _now(),
            reason: PrayerReason.skipped,
            where: _words[first].ref,
            words: _wordsText(first, count)));
      } else {
        _mistake =
            _Mistake(PrayerReason.skipped, first, count, open.at, open.mark);
      }
    } else if (open != null && open.reason == PrayerReason.wrongWord) {
      _mistake = null;
      _emit(PrayerEvent(PrayerEventKind.corrected, _now(),
          where: _words[open.first].ref));
    }

    if (_cursor >= _words.length) unawaited(_nextSurah());
    notifyListeners();
  }

  Future<void> _nextSurah() async {
    if (_surah >= 114) return;
    _busy = true;
    try {
      await _loadSurah(_surah + 1);
      _cursor = 0;
      await tracker.resumeAt(_surah, 1);
      _markProgress();
      _emit(PrayerEvent(PrayerEventKind.nextSurah, _now(),
          where: _words.first.ref));
    } finally {
      _busy = false;
    }
  }

  void _markProgress() {
    _progressMark = transcript.length;
    _lastProgressAt = _now();
    _pausePrompted = false;
  }

  // ── Mistakes ──────────────────────────────────────────────────────────

  void _checkMistake() {
    final m = _mistake;
    if (m == null) return;
    if (m.reason == PrayerReason.skipped && _skippedCorrected(m)) {
      _mistake = null;
      _emit(PrayerEvent(PrayerEventKind.corrected, _now(),
          where: _words[m.first].ref));
      return;
    }
    if (_now().difference(m.at) >= settings.correctionDuration) {
      _mistake = null;
      _prompt(m.reason, m.first);
    }
  }

  /// The left-out words were recited after all: matched by the tracker, or
  /// heard since the mistake together with the word after them (going back
  /// over a missed word repeats what follows it; the word alone could just
  /// be the same word further on).
  bool _skippedCorrected(_Mistake m) {
    bool allMatched = true;
    for (int i = m.first; i < m.first + m.count; i++) {
      if (tracker.stateOf(_words[i].ref) != RecitedWordState.recited) {
        allMatched = false;
        break;
      }
    }
    if (allMatched) return true;
    final end = math.min(_words.length, m.first + m.count + 1);
    final phrase = [
      for (int i = m.first; i < end; i++) _words[i].skeleton,
    ].join();
    if (phrase.length < 6) return false; // too short to recognize reliably
    final heard = phonemeSkeleton(transcript.since(m.mark));
    return nearestMatch(phrase, heard, (phrase.length * 0.25).floor()) != null;
  }

  /// Speech that doesn't move the tracker on, and isn't the reciter going
  /// back over recent words or saying the taʿawwudh, basmala or āmīn.
  void _checkWrongWord() {
    if (_mistake != null || _cursor >= _words.length) return;
    final unmatched = phonemeSkeleton(transcript.since(_progressMark));
    final next =
        _cursor + 1 < _words.length ? _words[_cursor + 1].skeleton : '';
    final needed =
        math.max(18, _words[_cursor].skeleton.length + next.length + 6);
    if (unmatched.length < needed) return;

    final query = unmatched.substring(math.max(0, unmatched.length - 40));
    final lo = math.max(0, _cursor - 40);
    final reference = [
      if (_wordsThisRakah == 0 || _words[_cursor].ref.ayah == 1) _extras,
      _words
          .sublist(lo, math.min(_words.length, _cursor + 2))
          .map((w) => w.skeleton)
          .join(),
    ].join();
    final explained =
        nearestMatch(query, reference, (query.length * 0.25).floor()) != null;
    if (explained) {
      // Going back over earlier words is fine; measure from here.
      _progressMark = transcript.length;
      return;
    }
    _mistake =
        _Mistake(PrayerReason.wrongWord, _cursor, 0, _now(), transcript.length);
    _emit(PrayerEvent(PrayerEventKind.mistake, _now(),
        reason: PrayerReason.wrongWord,
        where: _words[_cursor].ref,
        words: _wordsText(_cursor, 1)));
  }

  void _checkPause() {
    if (_mistake != null || _pausePrompted || _wordsThisRakah == 0) return;
    if (_cursor >= _words.length) return;
    final lastSound = transcript.lastGrowth;
    DateTime quietSince = _lastProgressAt;
    if (lastSound != null && lastSound.isAfter(quietSince)) {
      quietSince = lastSound;
    }
    if (_lastPromptAt.isAfter(quietSince)) quietSince = _lastPromptAt;
    final atAyahStart = _words[_cursor].startsAyah;
    final limit = atAyahStart
        ? settings.pauseBetweenAyahsDuration
        : settings.pauseMidAyahDuration;
    if (_now().difference(quietSince) < limit) return;
    _pausePrompted = true;
    _prompt(
      atAyahStart ? PrayerReason.pauseBetweenAyahs : PrayerReason.pauseMidAyah,
      _cursor,
    );
  }

  void _prompt(PrayerReason reason, int first) {
    _lastPromptAt = _now();
    _emit(PrayerEvent(PrayerEventKind.prompt, _now(),
        reason: reason,
        where: _words[first].ref,
        words: _wordsText(first, settings.promptWordCount)));
  }

  // ── Helpers ───────────────────────────────────────────────────────────

  Future<void> _loadSurah(int surah) async {
    _words = await text.wordsOf(surah);
    _surah = surah;
  }

  String _wordsText(int first, int count) => _words
      .sublist(first, math.min(_words.length, first + count))
      .map((w) => w.uthmani)
      .join(' ');

  void _emit(PrayerEvent e) {
    _events.add(e);
    log?.call(e.toString());
    notifyListeners();
  }
}

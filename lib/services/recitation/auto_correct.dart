import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:recite_quran/recite_quran.dart' show QuranRepository;

import 'auto_correct_settings.dart';
import 'phoneme_transcript.dart';
import 'phrase_spotter.dart';
import 'plan_text.dart';
import 'recitation_event.dart';
import 'recitation_tracker.dart';
import 'recited_word.dart';

class _Mistake {
  _Mistake(this.reason, this.first, this.count, this.at, this.mark);
  final RecitationReason reason;

  /// Index in the surah's words of the first word to prompt, and how many
  /// words were left out (for [RecitationReason.skipped]).
  final int first;
  final int count;
  final DateTime at;

  /// [PhonemeTranscript.length] when it happened.
  final int mark;
}

/// Auto-correct: while the tracker follows the recitation, it notices
/// mistakes and long pauses, and adds what it does about them to [log]
/// (beep at a mistake, read the right words aloud). The sounds themselves
/// are made by a RecitationVoice, unless it is [silent] (prayer mode
/// without auto-correct: what it would do is only shown).
///
/// - A word the tracker marks as a mistake (left out, or wrong enough to be
///   skipped over), or speech that doesn't move the tracker on, is a
///   mistake. If the reciter doesn't correct it within the correction time,
///   the right words are prompted.
/// - A long pause (separate limits part way through an ayah and at its end)
///   prompts the next words, once the reciter has recited something since
///   the tracker started following (in prayer mode: in this rakʿah).
///
/// It follows wherever the tracker goes: from the ayah the tracker expects
/// when it starts following, to another ayah when the tracker is moved
/// there (tapped, or it finds the reciter elsewhere), from the start again
/// when highlights are cleared, and on into the next surah.
class AutoCorrect extends ChangeNotifier {
  AutoCorrect({
    required this.tracker,
    required this.text,
    required this.settings,
    required this.log,
    required List<String> extraPhrases,
    DateTime Function()? now,
    this.debugLog,
    this.silent = false,
  })  : _extras = extraPhrases.map(phonemeSkeleton).join(),
        _now = now ?? DateTime.now {
    transcript = PhonemeTranscript(now: _now);
  }

  /// Creates auto-correct for the app's Quran data and saved settings.
  static Future<AutoCorrect> create({
    required RecitationTracker tracker,
    required QuranRepository repository,
    required RecitationLog log,
    bool silent = false,
    void Function(String message)? debugLog,
  }) async {
    final text = QuranPlanText(repository);
    final fatiha = await text.wordsOf(1);
    await AutoCorrectSettings.instance.load();
    return AutoCorrect(
      tracker: tracker,
      text: text,
      settings: AutoCorrectSettings.instance,
      log: log,
      extraPhrases: [
        istiadhaPhonemes,
        // The basmala as recited at the start of a surah (al-Fātiḥa 1:1).
        fatiha.where((w) => w.ref.ayah == 1).map((w) => w.skeleton).join(),
        aminPhonemes,
      ],
      debugLog: debugLog,
      silent: silent,
    );
  }

  /// "أعوذ بالله من الشيطان الرجيم".
  static const istiadhaPhonemes = 'ءَعُۥۥذُبِللَااهِمِنَششَيطَاانِررَجِۦۦم';

  /// "آمين".
  static const aminPhonemes = 'ءَاامِۦۦن';

  final RecitationTracker tracker;
  final PlanText text;
  final AutoCorrectSettings settings;
  final RecitationLog log;
  final void Function(String message)? debugLog;

  /// What it does is only shown, not heard (prayer mode without
  /// auto-correct).
  final bool silent;

  /// Skeleton of what may be said before the Quran words (taʿawwudh,
  /// basmala, āmīn).
  final String _extras;
  final DateTime Function() _now;

  late final PhonemeTranscript transcript;

  bool _started = false;
  bool _following = false;
  bool _busy = false;

  int _surah = 0;
  List<PlanWord> _words = const [];
  int _cursor = 0;

  /// Where each ayah starts in [_words] (ayah 1 first).
  List<int> _ayahStarts = const [];

  /// What the tracker said about each word last time, and its
  /// [RecitationTracker.revision] then.
  List<RecitedWordState> _known = const [];
  int _revision = 0;

  int _progressMark = 0;
  DateTime _lastProgressAt = DateTime(0);
  DateTime _lastPromptAt = DateTime(0);

  /// Words recited since the tracker started following (in prayer mode,
  /// in this rakʿah: it carries on into the next surah).
  int _wordsThisRun = 0;
  bool _pausePrompted = false;
  _Mistake? _mistake;

  /// Whether it is following the recitation (the tracker is).
  bool get following => _following;

  /// The next word expected.
  MushafWord? get position =>
      _cursor < _words.length ? _words[_cursor].ref : null;

  /// Starts following the tracker.
  void start() {
    if (_started) return;
    _started = true;
    tracker.addListener(_onTrackerChanged);
    _onTrackerChanged();
  }

  /// Stops following the tracker.
  void stop() {
    if (!_started) return;
    _started = false;
    tracker.removeListener(_onTrackerChanged);
    _following = false;
    _mistake = null;
    notifyListeners();
  }

  @override
  void dispose() {
    stop();
    super.dispose();
  }

  /// Feeds one speech recognizer result (then [tick]).
  void addTranscription({
    required List<String> tokens,
    bool isFinal = false,
    int epoch = 0,
  }) {
    if (!_started) return;
    transcript.addResult(tokens: tokens, isFinal: isFinal, epoch: epoch);
  }

  /// Re-checks everything time-based. Called every 250 ms while running.
  void tick() {
    if (!_started || !_following || _busy || _cursor >= _words.length) {
      return;
    }
    _checkMistake();
    _checkWrongWord();
    _checkPause();
  }

  // ── Following the tracker ─────────────────────────────────────────────

  void _onTrackerChanged() {
    if (!_started || _busy) return;
    final following = tracker.following;
    if (following != _following) {
      _following = following;
      if (!following) {
        _mistake = null;
        notifyListeners();
        return;
      }
      unawaited(_resync());
      return;
    }
    if (!following) return;
    if (tracker.surah != _surah || tracker.revision != _revision) {
      // Highlights cleared (recitation started over) or another surah.
      unawaited(_resync());
      return;
    }
    _advance();
    // The tracker was moved to another ayah: tapped, or it found the
    // reciter somewhere else.
    final ayah = tracker.activeAyah;
    if (ayah != null &&
        ayah <= _ayahStarts.length &&
        _cursor < _words.length &&
        _words[_cursor].ref.ayah != ayah) {
      debugLog?.call('the tracker moved to ${tracker.surah}:$ayah');
      unawaited(_resync());
    }
  }

  /// Takes up the recitation where the tracker expects it: the first word
  /// not yet recited in its ayah. Words recited start counting again,
  /// unless the tracker has moved on to the start of the next surah.
  Future<void> _resync() async {
    _busy = true;
    try {
      final surah = tracker.surah;
      final ayah = tracker.activeAyah ?? 1;
      final continues = surah == _surah + 1 && ayah == 1;
      if (surah != _surah) {
        _words = await text.wordsOf(surah);
        _surah = surah;
        _ayahStarts = [
          for (int i = 0; i < _words.length; i++)
            if (_words[i].startsAyah) i,
        ];
      }
      _revision = tracker.revision;
      _known = [for (final w in _words) tracker.stateOf(w.ref)];
      int start = _words.indexWhere((w) => w.ref.ayah == ayah);
      if (start < 0) start = 0;
      int i = start;
      while (i < _words.length &&
          _words[i].ref.ayah == ayah &&
          tracker.stateOf(_words[i].ref) != RecitedWordState.unspoken) {
        i++;
      }
      _cursor = i < _words.length && _words[i].ref.ayah == ayah ? i : start;
      _mistake = null;
      if (!continues) _wordsThisRun = 0;
      _markProgress();
    } finally {
      _busy = false;
    }
    notifyListeners();
    // What the tracker did meanwhile.
    _onTrackerChanged();
  }

  /// Moves the cursor on over the words the tracker has just dealt with.
  void _advance() {
    final changed = _newlyDealtWith();
    if (changed.isEmpty || changed.last < _cursor) return;
    final last = changed.last;
    final first = changed.firstWhere((i) => i >= _cursor);
    for (int i = _cursor; i < first; i++) {
      if (tracker.stateOf(_words[i].ref) == RecitedWordState.unspoken) {
        // Not a word after the expected one: the tracker went on from
        // somewhere further on.
        debugLog?.call('the tracker went on to ${_words[first].ref}');
        _cursor = last + 1;
        _mistake = null;
        _wordsThisRun += changed.length;
        _markProgress();
        notifyListeners();
        return;
      }
    }
    final skipped = [
      for (final i in changed)
        if (i >= _cursor &&
            tracker.stateOf(_words[i].ref) == RecitedWordState.mistake)
          i,
    ];
    _wordsThisRun += last + 1 - _cursor;
    _cursor = last + 1;
    _markProgress();

    final open = _mistake;
    if (skipped.isNotEmpty) {
      // Words left out. A wrong word that the tracker then skipped over
      // becomes this mistake, keeping its start time.
      final first = skipped.first;
      final count = skipped.last - first + 1;
      if (open == null) {
        _mistake = _Mistake(
            RecitationReason.skipped, first, count, _now(), transcript.length);
        _emit(RecitationEvent(RecitationEventKind.mistake, _now(),
            reason: RecitationReason.skipped,
            where: _words[first].ref,
            words: _wordsText(first, count)));
      } else {
        _mistake = _Mistake(
            RecitationReason.skipped, first, count, open.at, open.mark);
      }
    } else if (open != null && open.reason == RecitationReason.wrongWord) {
      _mistake = null;
      _emit(RecitationEvent(RecitationEventKind.corrected, _now(),
          where: _words[open.first].ref));
    }
    notifyListeners();
  }

  /// The words around the cursor and the tracker's ayah that the tracker
  /// has dealt with (recited, or marked as mistakes) since last time.
  List<int> _newlyDealtWith() {
    if (_words.isEmpty) return const [];
    final at = math.min(_cursor, _words.length - 1);
    final cursorAyah = _words[at].ref.ayah;
    final ayah = tracker.activeAyah ?? cursorAyah;
    final lo = _ayahStart(math.min(ayah, cursorAyah) - 1);
    final hi = _ayahStart(math.max(ayah, cursorAyah) + 2);
    final out = <int>[];
    for (int i = lo; i < hi; i++) {
      final state = tracker.stateOf(_words[i].ref);
      if (_known[i] == RecitedWordState.unspoken &&
          state != RecitedWordState.unspoken) {
        out.add(i);
      }
      _known[i] = state;
    }
    return out;
  }

  /// Index of the first word of [ayah] (the end, past the last ayah).
  int _ayahStart(int ayah) {
    if (ayah <= 1) return 0;
    if (ayah > _ayahStarts.length) return _words.length;
    return _ayahStarts[ayah - 1];
  }

  /// Whether the tracker shows every word from [from] to [to] as recited
  /// already.
  bool _alreadyDealtWith(int from, int to) {
    for (int i = from; i <= to; i++) {
      if (tracker.stateOf(_words[i].ref) == RecitedWordState.unspoken) {
        return false;
      }
    }
    return true;
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
    if (m.reason == RecitationReason.skipped && _skippedCorrected(m)) {
      _mistake = null;
      _emit(RecitationEvent(RecitationEventKind.corrected, _now(),
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
    // Up to the words the tracker can still reach.
    final reference = [
      if (_wordsThisRun == 0 || _words[_cursor].ref.ayah == 1) _extras,
      _words
          .sublist(lo, math.min(_words.length, _cursor + _trackerReach + 1))
          .map((w) => w.skeleton)
          .join(),
    ].join();
    final maxDistance = (query.length * 0.25).floor();
    final explained = nearestMatch(query, reference, maxDistance) != null;
    if (explained) {
      // Going back over earlier words is fine; measure from here.
      _progressMark = transcript.length;
      return;
    }
    final ahead = _wordAhead(query, maxDistance);
    if (ahead != null && _alreadyDealtWith(_cursor, ahead)) {
      // Reciting again words the tracker already shows (going back to an
      // ayah recited before): it follows them without showing it.
      _wordsThisRun += ahead + 1 - _cursor;
      _cursor = ahead + 1;
      _markProgress();
      notifyListeners();
      return;
    }
    _mistake = _Mistake(
        RecitationReason.wrongWord, _cursor, 0, _now(), transcript.length);
    _emit(RecitationEvent(RecitationEventKind.mistake, _now(),
        reason: RecitationReason.wrongWord,
        where: _words[_cursor].ref,
        words: _wordsText(_cursor, 1)));
  }

  /// How many words past the expected one the tracker can still match (it
  /// marks the ones in between as left out).
  static const int _trackerReach = 2;

  /// Where in the next stretch of the surah (up to the end of the next
  /// ayah) [query] was recited, as the index of the word it ends in, if
  /// that is beyond the tracker's reach.
  int? _wordAhead(String query, int maxDistance) {
    final from = _cursor;
    int to = from + 1;
    int ayahsStarted = 0;
    while (to < _words.length && to < from + 60) {
      if (_words[to].startsAyah && ++ayahsStarted == 2) break;
      to++;
    }
    final ends = <int>[];
    final text = StringBuffer();
    for (int i = from; i < math.min(to, _words.length); i++) {
      text.write(_words[i].skeleton);
      ends.add(text.length);
    }
    final match = nearestMatch(query, text.toString(), maxDistance);
    if (match == null) return null;
    final k = ends.indexWhere((end) => end >= match.end);
    final word = from + (k < 0 ? ends.length - 1 : k);
    return word > _cursor + _trackerReach ? word : null;
  }

  void _checkPause() {
    if (_mistake != null || _pausePrompted || _wordsThisRun == 0) return;
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
      atAyahStart
          ? RecitationReason.pauseBetweenAyahs
          : RecitationReason.pauseMidAyah,
      _cursor,
    );
  }

  void _prompt(RecitationReason reason, int first) {
    _lastPromptAt = _now();
    final end = math.min(_words.length, first + settings.promptWordCount);
    _emit(RecitationEvent(RecitationEventKind.prompt, _now(),
        reason: reason,
        where: _words[first].ref,
        words: _wordsText(first, settings.promptWordCount),
        wordRefs: [for (int i = first; i < end; i++) _words[i].ref]));
  }

  // ── Helpers ───────────────────────────────────────────────────────────

  String _wordsText(int first, int count) => _words
      .sublist(first, math.min(_words.length, first + count))
      .map((w) => w.uthmani)
      .join(' ');

  void _emit(RecitationEvent e) => log.add(e);
}

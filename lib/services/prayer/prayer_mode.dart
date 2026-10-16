import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:recite_quran/recite_quran.dart' show QuranRepository;

import '../recitation/phoneme_transcript.dart';
import '../recitation/phrase_spotter.dart';
import '../recitation/plan_text.dart';
import '../recitation/recitation_event.dart';
import '../recitation/recitation_tracker.dart';
import '../recitation/recited_word.dart';

enum PrayerPhase {
  /// Not started, or stopped.
  idle,

  /// Not following: waiting for the end of al-Fātiḥa.
  waitingForFatiha,

  /// Following the plan.
  following,
}

/// Prayer mode: follows a continuous recitation plan through the prayer,
/// adding to [log] how the prayer goes.
///
/// It starts waiting for al-Fātiḥa. When the end of al-Fātiḥa is heard the
/// tracker follows the plan from where it left off; "Allāhu akbar" stops it
/// until the next al-Fātiḥa ends. The plan carries on into the next surah.
/// (Mistakes and pauses are auto-correct's.)
class PrayerMode extends ChangeNotifier {
  PrayerMode({
    required this.tracker,
    required this.text,
    required this.log,
    required PhraseSpotter fatihaEnd,
    DateTime Function()? now,
  })  : _fatihaEnd = fatihaEnd,
        _now = now ?? DateTime.now {
    transcript = PhonemeTranscript(now: _now);
  }

  /// Creates prayer mode for the app's Quran data.
  static PrayerMode create({
    required RecitationTracker tracker,
    required QuranRepository repository,
    required RecitationLog log,
  }) =>
      PrayerMode(
        tracker: tracker,
        text: QuranPlanText(repository),
        log: log,
        fatihaEnd: PrayerPhrases.fatihaEnd(repository.getVerse(1, 7)!),
      );

  final RecitationTracker tracker;
  final PlanText text;
  final RecitationLog log;

  final PhraseSpotter _fatihaEnd;
  final PhraseSpotter _takbir = PrayerPhrases.takbir();
  final PhraseSpotter _takbirLookalike = PhraseSpotter(
      PrayerPhrases.takbirPhonemes,
      maxDistance: 3,
      mustContain: const ['ك']);
  final DateTime Function() _now;

  late final PhonemeTranscript transcript;

  PrayerPhase _phase = PrayerPhase.idle;
  int _surah = 0;
  List<PlanWord> _words = const [];
  MushafWord? _resume;
  int _phaseMark = 0;
  bool _busy = false;

  PrayerPhase get phase => _phase;

  /// Where the plan resumes after the next al-Fātiḥa (while waiting), or
  /// the next expected word (while following).
  MushafWord? get position =>
      _phase == PrayerPhase.following ? _trackerPosition() : _resume;

  /// Starts prayer mode with the plan beginning at [ayah] of [surah].
  Future<void> start(int surah, int ayah) async {
    if (_phase != PrayerPhase.idle) return;
    await _loadSurah(surah);
    _resume = MushafWord(surah, ayah, 0);
    tracker.addListener(_onTrackerChanged);
    tracker.pause();
    transcript.clear();
    _enterWaiting();
    _emit(RecitationEvent(RecitationEventKind.started, _now(), where: _resume));
  }

  /// Stops prayer mode.
  void stop() {
    if (_phase == PrayerPhase.idle) return;
    tracker.removeListener(_onTrackerChanged);
    final at = position;
    _phase = PrayerPhase.idle;
    _emit(RecitationEvent(RecitationEventKind.stopped, _now(), where: at));
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
    if (_phase == PrayerPhase.idle) return;
    transcript.addResult(tokens: tokens, isFinal: isFinal, epoch: epoch);
  }

  /// Listens for the end of al-Fātiḥa, or for "Allāhu akbar".
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
        if (_takbirHeard()) _stopFollowing();
    }
  }

  // ── Phases ────────────────────────────────────────────────────────────

  void _enterWaiting() {
    _phase = PrayerPhase.waitingForFatiha;
    _phaseMark = transcript.length;
    notifyListeners();
  }

  Future<void> _startFollowing() async {
    _busy = true;
    try {
      final resume = _resume!;
      if (resume.surah != _surah) await _loadSurah(resume.surah);
      await tracker.resumeAt(resume.surah, resume.ayah);
      _phase = PrayerPhase.following;
      _phaseMark = transcript.length;
      _emit(RecitationEvent(RecitationEventKind.fatihaEnded, _now(),
          where: MushafWord(resume.surah, resume.ayah, 0)));
    } finally {
      _busy = false;
    }
  }

  void _stopFollowing() {
    // Resume from the start of the ayah the reciter was in: normally the
    // next ayah, as recitation ends at the end of an ayah.
    final at = _trackerPosition();
    tracker.pause();
    _resume = MushafWord(at.surah, at.ayah, 0);
    _enterWaiting();
    _emit(RecitationEvent(RecitationEventKind.takbir, _now(), where: _resume));
  }

  bool _takbirHeard() {
    final from = math.max(_phaseMark, transcript.length - 60);
    if (!_takbir.foundIn(transcript.since(from))) return false;
    // A few ayahs contain "اللَّهِ أَكْبَرُ" (9:72, 29:45, 40:10): reciting
    // them isn't the takbīr of the prayer.
    final at = _trackerPosition();
    final i = _words.indexWhere((w) => w.ref == at);
    if (i < 0) return true;
    final lo = math.max(0, i - 8);
    final hi = math.min(_words.length, i + 8);
    final nearby = _words.sublist(lo, hi).map((w) => w.skeleton).join();
    return !_takbirLookalike.foundIn(nearby);
  }

  // ── Following the plan ────────────────────────────────────────────────

  void _onTrackerChanged() {
    if (_phase != PrayerPhase.following || _busy) return;
    if (_words.isNotEmpty &&
        tracker.stateOf(_words.last.ref) != RecitedWordState.unspoken) {
      unawaited(_nextSurah());
    }
  }

  /// The end of the surah: the plan carries on with the next one.
  Future<void> _nextSurah() async {
    if (_surah >= 114) return;
    _busy = true;
    try {
      await _loadSurah(_surah + 1);
      await tracker.resumeAt(_surah, 1);
      _emit(RecitationEvent(RecitationEventKind.nextSurah, _now(),
          where: _words.first.ref));
    } finally {
      _busy = false;
    }
  }

  /// Where the tracker expects the next word: the first word of its ayah
  /// not yet recited.
  MushafWord _trackerPosition() {
    final surah = tracker.surah;
    final ayah = tracker.activeAyah ?? 1;
    if (surah == _surah) {
      for (final w in _words) {
        if (w.ref.ayah < ayah) continue;
        if (w.ref.ayah > ayah) break;
        if (tracker.stateOf(w.ref) == RecitedWordState.unspoken) return w.ref;
      }
    }
    return MushafWord(surah, ayah, 0);
  }

  // ── Helpers ───────────────────────────────────────────────────────────

  Future<void> _loadSurah(int surah) async {
    _words = await text.wordsOf(surah);
    _surah = surah;
  }

  void _emit(RecitationEvent e) {
    log.add(e);
    notifyListeners();
  }
}

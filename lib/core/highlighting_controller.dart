import 'dart:async';
import 'package:flutter/material.dart';
import 'package:recite_quran/recite_quran.dart' as rq;
export 'package:recite_quran/recite_quran.dart' hide HighlightingController;

import 'app_state.dart';
import '../audio/quran_audio_service.dart';
import '../ui/widgets/dialogs/dialog_service.dart';

/// Recitation & Audio playback source.
enum RecitationSource {
  none,
  localAsr,
  maglisRemote,
  audioPlayback,
}

// ─────────────────────────────────────────────────────────────────────────────
// Quran Coordinate Packing & Arithmetic
// ─────────────────────────────────────────────────────────────────────────────

/// Centralized Quran Coordinate Arithmetic & Packing.
/// Replaces ad-hoc bit shifting and frees Mushaf and UI layers from importing networking controllers.
abstract final class QuranCoordinate {
  /// Packs (surah, ayah, word0) into a single compact 32-bit integer:
  /// ((surah & 0xFF) << 20) | ((ayah & 0xFFF) << 8) | (word0 & 0xFF)
  static int packWordKey(int surah, int ayah, int word0) =>
      ((surah & 0xFF) << 20) | ((ayah & 0xFFF) << 8) | (word0 & 0xFF);

  /// Unpacks a 32-bit packed word key into (surah, ayah, word0).
  static (int surah, int ayah, int word0) unpackWordKey(int key) => (
        (key >> 20) & 0xFF,
        (key >> 8) & 0xFFF,
        key & 0xFF,
      );

  /// Packs (surah, ayah) into a 32-bit integer: (surah << 16) | (ayah & 0xFFFF)
  static int packAyahKey(int surah, int ayah) =>
      ((surah & 0xFFFF) << 16) | (ayah & 0xFFFF);

  /// Unpacks a 32-bit packed ayah key into (surah, ayah).
  static (int surah, int ayah) unpackAyahKey(int key) => (
        (key >> 16) & 0xFFFF,
        key & 0xFFFF,
      );
}

/// HighlightStore
///
/// High-performance flat O(1) bit-packed key store for Quran word highlight states
/// (1: Green, 2: Yellow, 3: Red, 4: Neutral) and Tajweed recitation errors.
/// Serves as the single source of truth for all producers (Local ASR, Remote Maglis, and Audio Playback).
class HighlightStore {
  // Key: QuranCoordinate.packWordKey(surah, ayah, word0) -> status (1..4)
  final Map<int, int> _states = {};

  // Key: QuranCoordinate.packWordKey(surah, ayah, word0) -> errors
  final Map<int, List<rq.ReciterError>> _errors = {};

  // Completed ayahs per surah: surah -> Set of ayah numbers (1-based)
  final Map<int, Set<int>> _completedAyahs = {};

  // Fast count of highlights per (surah, ayah)
  final Map<int, int> _ayahHighlightCounts = {};

  // ── Writes ──

  void setWordStatus(
    int surah,
    int ayah,
    int wordIndex,
    int status, [
    List<rq.ReciterError>? errors,
  ]) {
    final key = QuranCoordinate.packWordKey(surah, ayah, wordIndex);
    final ayahKey = QuranCoordinate.packAyahKey(surah, ayah);
    final prev = _states[key];
    if (prev == null || prev == 0) {
      _ayahHighlightCounts[ayahKey] = (_ayahHighlightCounts[ayahKey] ?? 0) + 1;
    }
    _states[key] = status;
    if (errors != null && errors.isNotEmpty && status == 2) {
      _errors[key] = errors;
    } else {
      _errors.remove(key);
    }
  }

  void markGreen(int surah, int ayah, int wordIndex) =>
      setWordStatus(surah, ayah, wordIndex, 1);

  void markYellow(
    int surah,
    int ayah,
    int wordIndex, [
    List<rq.ReciterError>? errors,
  ]) =>
      setWordStatus(surah, ayah, wordIndex, 2, errors);

  void markRed(int surah, int ayah, int wordIndex) =>
      setWordStatus(surah, ayah, wordIndex, 3);

  void markNeutral(int surah, int ayah, int wordIndex) =>
      setWordStatus(surah, ayah, wordIndex, 4);

  void markAyahCompleted(int surah, int ayah) {
    (_completedAyahs[surah] ??= {}).add(ayah);
  }

  // ── Reads ──

  int getWordStatus(int surah, int ayah, int wordIndex) =>
      _states[QuranCoordinate.packWordKey(surah, ayah, wordIndex)] ?? 0;

  bool isGreen(int surah, int ayah, int wordIndex) =>
      getWordStatus(surah, ayah, wordIndex) == 1;

  bool isYellow(int surah, int ayah, int wordIndex) =>
      getWordStatus(surah, ayah, wordIndex) == 2;

  bool isRed(int surah, int ayah, int wordIndex) =>
      getWordStatus(surah, ayah, wordIndex) == 3;

  bool isNeutral(int surah, int ayah, int wordIndex) =>
      getWordStatus(surah, ayah, wordIndex) == 4;

  bool isRead(int surah, int ayah, int wordIndex) =>
      getWordStatus(surah, ayah, wordIndex) > 0;

  List<rq.ReciterError>? errorsFor(int surah, int ayah, int wordIndex) {
    if (!isYellow(surah, ayah, wordIndex)) return null;
    return _errors[QuranCoordinate.packWordKey(surah, ayah, wordIndex)];
  }

  Set<int> completedAyahsFor(int surah) =>
      _completedAyahs[surah] ?? const <int>{};

  /// High-speed O(1) check if a specific ayah has any stored highlights.
  bool hasAyahHighlights(int surah, int ayah) =>
      (_ayahHighlightCounts[QuranCoordinate.packAyahKey(surah, ayah)] ?? 0) > 0;

  bool get hasHighlights => _states.isNotEmpty;

  /// Builds radix-16 snapshot map for network synchronization.
  Map<String, int> buildSnapshotMap() {
    final map = <String, int>{};
    for (final e in _states.entries) {
      map[e.key.toRadixString(16)] = e.value;
    }
    return map;
  }

  // ── Clearing ──

  void clearAll() {
    _states.clear();
    _errors.clear();
    _completedAyahs.clear();
    _ayahHighlightCounts.clear();
  }

  void clearSurah(int surah) {
    _states.removeWhere((key, _) => QuranCoordinate.unpackWordKey(key).$1 == surah);
    _errors.removeWhere((key, _) => QuranCoordinate.unpackWordKey(key).$1 == surah);
    _completedAyahs.remove(surah);
    _ayahHighlightCounts.removeWhere((key, _) => QuranCoordinate.unpackAyahKey(key).$1 == surah);
  }

  void clearAllExceptSurah(int keepSurah) {
    _states.removeWhere((key, _) => QuranCoordinate.unpackWordKey(key).$1 != keepSurah);
    _errors.removeWhere((key, _) => QuranCoordinate.unpackWordKey(key).$1 != keepSurah);
    _completedAyahs.removeWhere((s, _) => s != keepSurah);
    _ayahHighlightCounts.removeWhere((key, _) => QuranCoordinate.unpackAyahKey(key).$1 != keepSurah);
  }

  void clearSurahFromAyah(int surah, int startAyah) {
    _completedAyahs[surah]?.removeWhere((ayah) => ayah >= startAyah);
    _completedAyahs.removeWhere((s, _) => s > surah);
    _states.removeWhere((key, _) {
      final (s, a, _) = QuranCoordinate.unpackWordKey(key);
      return s > surah || (s == surah && a >= startAyah);
    });
    _errors.removeWhere((key, _) {
      final (s, a, _) = QuranCoordinate.unpackWordKey(key);
      return s > surah || (s == surah && a >= startAyah);
    });
    _ayahHighlightCounts.removeWhere((key, _) {
      final (s, a) = QuranCoordinate.unpackAyahKey(key);
      return s > surah || (s == surah && a >= startAyah);
    });
  }
}

/// HighlightingController
///
/// Decoupled, single-source-of-truth recitation and playback controller.
/// Extends [rq.HighlightingController] to serve local ASR dictation, collaborative
/// Maglis WebRTC sessions, and audio playback tracking through a unified API.
///
/// Presentation layers (Mushaf, VerseList, dialogs, overlays) observe this single
/// controller. They never need separate branches or conditional code per mode.
class HighlightingController extends rq.HighlightingController {
  final HighlightStore _store = HighlightStore();

  // Remote Maglis state
  int _remoteTargetSurah = 0;
  int _remoteAyah = 0;
  int? _remoteActiveWord;
  bool _isRemoteReciting = false;

  /// Arbitration: when the local reader manually selects an ayah or plays
  /// audio while a remote reciter is active, coordinate claims from remote
  /// packets are paused (verdicts still merge). Follow resumes when audio
  /// ends, the reciter stops, or the reader turns back to the reciter's
  /// page ([resumeRemoteFollow]).
  bool _remoteFollowPaused = false;

  // Manual selection state
  int _manualTargetSurah = 0;

  // ── Retarget window ──
  //
  // A cross-surah merge (setTargetSurah / setManualAyah retargeting the
  // engine) makes the package write transient coordinates through the shared
  // activeAyah notifier: first a null wipe, then reset() hard-codes ayah 1
  // and notifies mid-merge. Those writes are merge noise, not coordinate
  // truth — a view that follows the coordinate would chase them (flip to the
  // surah's first page, then flip back). [isCoordinateSettled] reports the
  // window; the merge's final write re-broadcasts the settled coordinate,
  // which is what the view follows.
  bool _isRetargeting = false;
  bool get isCoordinateSettled => !_isRetargeting;

  // Last (surah, ayah) the ingestion ran for — drives the coordinate-advance
  // catch-up in [_ingestEngineState].
  ({int surah, int ayah})? _lastIngestedCoordinate;

  void _beginRetarget() => _isRetargeting = true;

  void _endRetarget() {
    if (!_isRetargeting) return;
    _isRetargeting = false;
    // The coordinate may have been re-pointed during the window (rapid
    // re-selection wins over the stale merge). Re-broadcast once so the view
    // re-follows whatever coordinate is settled now.
    notifyListeners();
  }

  // Audio Playback state
  int? _audioSurah;
  int? _audioAyah;
  int? _audioWordIndex;
  bool _isAudioPlaying = false;
  bool _isAudioBuffering = false;
  bool _isAudioPaused = false;

  HighlightingController({
    required super.repository,
    required super.engine,
    super.onAyahChanged,
    super.isTajweed = true,
    super.config = const rq.TrackerConfig(),
  });

  // ── Package → Controller ingestion (the only read boundary) ──

  /// The package reports; the controller saves. Every package event ends in
  /// [notifyListeners], so the engine's verdicts are pulled into the flat
  /// store HERE — before any listener sees the notification. Afterwards all
  /// queries, the paint path included, are pure O(1) store reads:
  /// package → controller → view, one direction, no fallback reads.
  @override
  void notifyListeners() {
    _ingestEngineState();
    super.notifyListeners();
  }

  /// Receives the package's latest verdicts (word states + completed ayahs)
  /// into the store. Idempotent and cheap: a word already saved is never
  /// re-read from the engine or overwritten, and the gate bails instantly
  /// whenever no package session is live.
  void _ingestEngineState() {
    // Gate on the package's own session state: verdicts only exist between
    // startRecordingSession() and finalize(). Everything else (audio ticks,
    // packets, selection changes) pays one enum compare.
    if (super.state != rq.TrackerState.tracking) return;
    final int? ayah = activeAyah.value;
    if (ayah == null) return;
    final int surah = targetSurah;
    if (surah == 0) return;

    // Coordinate-advance catch-up. The package writes the next ayah into the
    // coordinate BEFORE notifying: an ayah's last-word event both commits the
    // word and advances the coordinate in the same synchronous block, so
    // reading only the coordinate's ayah would lose the finished ayah's final
    // verdicts. One general rule, reanchor jumps included: on a forward move
    // within the same surah, ingest every ayah the coordinate passed. The
    // store-first skip keeps verdicts already saved (e.g. by Maglis packets)
    // untouched, and only words the package actually gave a verdict for are
    // received — bulk-completed-but-unspoken ayahs stay unsaved.
    final last = _lastIngestedCoordinate;
    if (last != null && last.surah == surah && ayah > last.ayah) {
      for (int a = last.ayah; a < ayah; a++) {
        _ingestAyah(surah, a);
      }
    }
    _lastIngestedCoordinate = (surah: surah, ayah: ayah);
    _ingestAyah(surah, ayah);

    // Receive completed-ayah marks too — including the package's bulk
    // completion of skipped ayahs.
    final mine = _store.completedAyahsFor(surah);
    for (final a in super.completedAyahsFor(surah)) {
      if (!mine.contains(a)) {
        _store.markAyahCompleted(surah, a);
      }
    }
  }

  /// Receives one ayah's word verdicts from the package into the store.
  void _ingestAyah(int surah, int ayah) {
    final verse = repository.getVerse(surah, ayah);
    if (verse == null) return;
    extractAyahWordClassification(surah, ayah, verse.uthmaniWords.length);
  }

  /// The active source driving highlighting/progress.
  RecitationSource get activeSource {
    if (_isRemoteReciting) return RecitationSource.maglisRemote;
    if (isAudioActive) return RecitationSource.audioPlayback;
    if (activeAyah.value != null && !isAudioActive && !_isRemoteReciting) {
      return RecitationSource.localAsr;
    }
    return RecitationSource.none;
  }

  // ── Remote Maglis Recitation State ──

  /// Whether a remote peer in a Maglis session is currently reciting.
  bool get isRemoteReciting => _isRemoteReciting;

  /// Whether the local reader paused following the remote reciter (by manual
  /// selection or audio playback). While paused, remote packets keep merging
  /// word verdicts into the store but stop claiming the coordinate.
  bool get isRemoteFollowPaused => _remoteFollowPaused;

  /// The (surah, ayah) the remote reciter is currently at — packet truth
  /// only, independent of the local coordinate. The view consults this on
  /// page turns to rejoin the reciter, which keeps the controller free of
  /// any page/provider imports.
  (int, int)? get remoteCoordinate =>
      _isRemoteReciting && _remoteTargetSurah != 0 && _remoteAyah != 0
          ? (_remoteTargetSurah, _remoteAyah)
          : null;

  /// Resumes following the remote recitation after [setManualAyah] or
  /// [applyAudioProgress] paused it. The next remote packet reclaims the
  /// coordinate; no forced jump happens here.
  void resumeRemoteFollow() {
    if (!_remoteFollowPaused) return;
    _remoteFollowPaused = false;
  }

  // ── Audio Playback State ──

  /// Whether Quran verse/word audio playback or buffering is currently active.
  bool get isAudioActive =>
      (_isAudioPlaying || _isAudioBuffering) &&
      _audioSurah != null &&
      _audioAyah != null;

  bool get isAudioPlaying => _isAudioPlaying;
  bool get isAudioBuffering => _isAudioBuffering;
  bool get isAudioPaused =>
      _isAudioPaused &&
      _audioSurah != null &&
      _audioAyah != null;
  int? get audioSurah => _audioSurah;
  int? get audioAyah => _audioAyah;
  int? get audioWordIndex => _audioWordIndex;

  /// Checks if audio playback or buffering is currently active for [surah, ayah].
  bool isAyahAudioActive(int surah, int ayah) =>
      isAudioActive && _audioSurah == surah && _audioAyah == ayah;

  /// Checks if audio playback is currently playing for [surah, ayah].
  bool isAyahAudioPlaying(int surah, int ayah) =>
      _isAudioPlaying && _audioSurah == surah && _audioAyah == ayah;

  /// Checks if audio playback is currently buffering for [surah, ayah].
  bool isAyahAudioBuffering(int surah, int ayah) =>
      _isAudioBuffering && _audioSurah == surah && _audioAyah == ayah;

  /// The active recitation or audio lead word index (0-based in active ayah).
  int? get activeWordIndex {
    if (_isRemoteReciting) return _remoteActiveWord;
    if (isAudioActive) return _audioWordIndex;
    return null;
  }

  /// The active coordinate (surah, ayah) driving playback or recitation.
  ///
  /// Pure controller truth: the mirrored coordinate, nothing else. Audio has
  /// no separate branch — applyAudioProgress mirrors the playing verse into
  /// targetSurah/activeAyah in the same event that makes isAudioActive true.
  (int surah, int ayah)? get activeAyahCoordinate {
    if (activeAyah.value != null && targetSurah != 0) {
      return (targetSurah, activeAyah.value!);
    }
    return null;
  }

  /// Direct access to the highlight store.
  HighlightStore get highlightStore => _store;

  @override
  int get targetSurah {
    // Single coordinate: every source (manual selection, ASR, audio playback,
    // Maglis packets) mirrors into _manualTargetSurah at its merge point, so
    // there is nothing to disambiguate here.
    if (_manualTargetSurah != 0) {
      return _manualTargetSurah;
    }
    return super.targetSurah;
  }

  /// Optional hook for reactive reading position persistence without circular state imports.
  static void Function(int surah, int ayah)? onAutoSavePosition;

  @override
  Future<void> setTargetSurah(
    int surah, {
    bool preserveOtherSurahStates = false,
    bool clearTargetSurah = true,
  }) async {
    _manualTargetSurah = surah;
    if (!preserveOtherSurahStates) {
      _store.clearAllExceptSurah(surah);
    }
    if (clearTargetSurah) {
      _store.clearSurah(surah);
    }
    // Merge window: the package writes transient coordinates mid-merge;
    // views must not follow until the merge's final write lands.
    _beginRetarget();
    try {
      await super.setTargetSurah(
        surah,
        preserveOtherSurahStates: preserveOtherSurahStates,
        clearTargetSurah: clearTargetSurah,
      );
    } finally {
      _endRetarget();
    }
  }

  static final Map<int, ({int ayah, int wordInAyah})> _surahLastWordCache = {};

  /// Checks whether all words in [surah] have been completed or read.
  bool isSurahFinished(int surah) {
    if (!QuranMetadata.isValidSurah(surah)) return false;
    final lastWord = _surahLastWordCache.putIfAbsent(surah, () {
      final surahWords = repository.getSurahWords(surah);
      if (surahWords.isEmpty) return (ayah: -1, wordInAyah: -1);
      final last = surahWords.last;
      return (ayah: last.ayah, wordInAyah: last.wordInAyah);
    });
    if (lastWord.ayah < 0) return false;
    return completedAyahsFor(surah).contains(lastWord.ayah) ||
        isWordRead(lastWord.ayah, lastWord.wordInAyah, surah: surah);
  }

  /// Hook called when a continuous recitation boundary transitions to the next Surah.
  void Function(int nextSurah, int nextAyah)? onSurahAutoAdvanced;

  /// Advances to next Surah in sequence, preserving previous Surah highlights for continuous reading.
  Future<bool> advanceToNextSurah({int? nextSurah, bool isRecording = false}) async {
    final int next = nextSurah ?? (targetSurah + 1);
    if (!QuranMetadata.isValidSurah(next)) return false;

    await setTargetSurah(
      next,
      preserveOtherSurahStates: true,
      clearTargetSurah: false,
    );
    setManualAyah(next, 1);
    if (isRecording) {
      startRecordingSession();
    }
    onSurahAutoAdvanced?.call(next, 1);
    return true;
  }

  /// Receives the package's verdicts for one ayah and saves them into the
  /// flat store. This is the single boundary where package state is read —
  /// the package reports, the controller saves; a word already saved (e.g.
  /// by a Maglis packet) is never overwritten. The returned classification is
  /// read back from the store, so callers broadcast exactly what the UI renders.
  ({
    List<int> greenWords,
    List<int> yellowWords,
    List<int> redWords,
    Map<int, List<rq.ReciterError>>? wordErrors,
  }) extractAyahWordClassification(int surah, int ayah, int wordCount) {
    for (int w0 = 0; w0 < wordCount; w0++) {
      if (_store.getWordStatus(surah, ayah, w0) != 0) continue;
      // Package verdict? Receive it once.
      int status = 0;
      List<rq.ReciterError>? errors;
      if (super.isWordRed(ayah, w0, surah: surah)) {
        status = 3;
      } else if (super.isWordYellow(ayah, w0, surah: surah)) {
        status = 2;
        errors = super.getWordErrors(ayah, w0, surah: surah);
      } else if (super.isWordGreen(ayah, w0, surah: surah)) {
        status = 1;
      } else if (super.isWordNeutral(ayah, w0, surah: surah)) {
        status = 4;
      }
      if (status == 1) {
        _store.markGreen(surah, ayah, w0);
      } else if (status == 2) {
        _store.markYellow(surah, ayah, w0, errors);
      } else if (status == 3) {
        _store.markRed(surah, ayah, w0);
      } else if (status == 4) {
        _store.markNeutral(surah, ayah, w0);
      }
    }

    final greenWords = <int>[];
    final yellowWords = <int>[];
    final redWords = <int>[];
    Map<int, List<rq.ReciterError>>? wordErrors;
    for (int w0 = 0; w0 < wordCount; w0++) {
      final st = _store.getWordStatus(surah, ayah, w0);
      if (st == 1) {
        greenWords.add(w0);
      } else if (st == 2) {
        yellowWords.add(w0);
        final errs = _store.errorsFor(surah, ayah, w0);
        if (errs != null && errs.isNotEmpty) {
          (wordErrors ??= {})[w0] = errs;
        }
      } else if (st == 3) {
        redWords.add(w0);
      }
    }

    return (
      greenWords: greenWords,
      yellowWords: yellowWords,
      redWords: redWords,
      wordErrors: wordErrors,
    );
  }

  @override
  void setManualAyah(int surah, int ayah) {
    // Local fields are the authoritative coordinate for every reader from
    // this moment on; a manual selection also takes the coordinate away from
    // any running audio playback.
    _manualTargetSurah = surah;
    activeAyah.value = ayah;
    _audioSurah = null;
    _audioAyah = null;
    _audioWordIndex = null;
    _isAudioPlaying = false;
    _isAudioBuffering = false;
    _isAudioPaused = false;
    // The reader just took the coordinate by hand while a remote reciter is
    // active: pause coordinate claims from remote packets (verdicts keep
    // merging). Follow resumes via resumeRemoteFollow or an isReciting:false
    // packet — never by force here.
    if (_isRemoteReciting) {
      _remoteFollowPaused = true;
    }
    onAutoSavePosition?.call(surah, ayah);
    AppState.instance.saveLastPosition(surah, ayah);

    if (super.targetSurah == surah) {
      super.setManualAyah(surah, ayah);
    } else {
      // The engine needs its target surah loaded before it can accept the
      // ayah. Only apply if this selection is still the newest event — a
      // rapid re-selection must never let a stale engine write land.
      // Merge window open until the merge's final write lands (or a newer
      // selection replaces it): the view must not follow the package's
      // transient coordinate writes in between.
      _beginRetarget();
      super
          .setTargetSurah(
            surah,
            preserveOtherSurahStates: true,
            clearTargetSurah: false,
          )
          .then((_) {
            if (_manualTargetSurah == surah) {
              super.setManualAyah(surah, ayah);
            }
          })
          .catchError((_) {})
          .whenComplete(_endRetarget);
    }

    globalRevision.value++;
    notifyListeners();
  }

  @override
  rq.VerseMatch? get currentMatchedVerse {
    // The mirrored coordinate IS the matched verse for every source (manual
    // selection, ASR anchor, audio playback, Maglis packets). Pure coordinate
    // read — no fallback into the package.
    if (_manualTargetSurah != 0 && activeAyah.value != null) {
      final v = repository.getVerse(_manualTargetSurah, activeAyah.value!);
      if (v != null) {
        return rq.VerseMatch(verse: v, score: 1.0);
      }
    }
    return null;
  }

  // ── Word Status Queries (pure store reads) ──
  //
  // The package's verdicts arrive through _ingestEngineState and live in the
  // store from then on; audio playback and Maglis packets write the same
  // store at their ingestion points. Every query below — the paint path
  // included — is a single O(1) lookup. No source is ever consulted at read
  // time: package → controller → view, one direction.

  @override
  bool isWordGreen(int ayah, int wordIndex, {int? surah}) =>
      _store.isGreen(surah ?? targetSurah, ayah, wordIndex);

  @override
  bool isWordYellow(int ayah, int wordIndex, {int? surah}) =>
      _store.isYellow(surah ?? targetSurah, ayah, wordIndex);

  @override
  bool isWordRed(int ayah, int wordIndex, {int? surah}) =>
      _store.isRed(surah ?? targetSurah, ayah, wordIndex);

  @override
  bool isWordNeutral(int ayah, int wordIndex, {int? surah}) =>
      _store.isNeutral(surah ?? targetSurah, ayah, wordIndex);

  /// Whether the word carries any recitation state (green/yellow/red/neutral).
  bool isWordRead(int ayah, int wordIndex, {int? surah}) =>
      _store.isRead(surah ?? targetSurah, ayah, wordIndex);

  /// Numeric status representation for high-speed rendering:
  /// 1: Green (Correct)
  /// 2: Yellow (Tajweed Rule / Warning)
  /// 3: Red (Mispronounced)
  /// 4: Neutral (Spoken/Passed)
  /// null: Unread
  int? getWordStatus(int ayah, int wordIndex, {int? surah}) {
    final st = _store.getWordStatus(surah ?? targetSurah, ayah, wordIndex);
    return st > 0 ? st : null;
  }

  @override
  List<rq.ReciterError>? getWordErrors(int ayah, int wordIndex, {int? surah}) {
    final s = surah ?? targetSurah;
    final list = _store.errorsFor(s, ayah, wordIndex);
    if (list == null || list.isEmpty) return null;
    return list.map((e) => hydrateRemoteError(s, ayah, wordIndex, e)).toList();
  }

  @override
  Set<int> completedAyahsFor(int surah) => _store.completedAyahsFor(surah);

  /// O(1) check: the store's per-ayah highlight count. All verdicts are
  /// saved at their ingestion point, so there is nothing to scan.
  bool hasAyahHighlights(int surah, int ayah) =>
      _store.hasAyahHighlights(surah, ayah);

  // ── Remote Maglis Recitation Ingestion ──

  /// Ingests remote recitation updates received over WebRTC/relay,
  /// seamlessly updating the highlight store and notifying UI listeners.
  void applyRemoteRecitation({
    required int surah,
    required int ayah,
    int? activeWord,
    List<int> greenWords = const [],
    List<int> yellowWords = const [],
    List<int> redWords = const [],
    Map<int, List<rq.ReciterError>>? errors,
    Map<String, int>? cumulative,
    bool isReciting = true,
    bool isFlush = false,
  }) {
    bool changed = false;

    // A flush packet is a store-only merge of the ayah that just finished:
    // word verdicts land in the store, but the coordinate, the remote lead
    // state and follow arbitration are untouched. The next normal packet
    // carries the true (advanced) coordinate — merging the flush's previous-
    // ayah coordinate used to bounce the highlight backward then forward on
    // every ayah advance (the peer flicker at the start of each ayah).
    if (isFlush) {
      if (_mergeRemoteVerdicts(
        surah: surah,
        ayah: ayah,
        greenWords: greenWords,
        yellowWords: yellowWords,
        redWords: redWords,
        errors: errors,
        cumulative: cumulative,
      )) {
        changed = true;
      }
    } else {
      final bool recitingChanged = _isRemoteReciting != isReciting;
      final bool surahChanged = _remoteTargetSurah != surah;
      final bool wordChanged = _remoteActiveWord != activeWord;

      _isRemoteReciting = isReciting;
      _remoteTargetSurah = surah;
      _remoteAyah = ayah;
      _remoteActiveWord = activeWord;
      changed = recitingChanged || surahChanged || wordChanged;

      if (!isReciting) {
        // Reciter stopped / floor released: never claim the coordinate (a
        // session-leave packet carries placeholder (1,1)), and clear the
        // follow pause so the next recitation is followed again.
        if (_remoteFollowPaused) {
          _remoteFollowPaused = false;
          changed = true;
        }
      } else if (!_remoteFollowPaused) {
        // Mirror the remote verse into the base coordinate exactly like audio
        // progress does (applyAudioProgress): every recitation source ends up
        // in targetSurah + activeAyah, so all readers follow one coordinate.
        // There is no maglis-specific page or highlight handling anywhere
        // downstream. While follow is paused the reader owns the coordinate;
        // verdicts still merge below.
        if (_manualTargetSurah != surah) {
          _manualTargetSurah = surah;
          changed = true;
        }
        if (activeAyah.value != ayah) {
          activeAyah.value = ayah;
          changed = true;
        }
      }
      if (_mergeRemoteVerdicts(
        surah: surah,
        ayah: ayah,
        greenWords: greenWords,
        yellowWords: yellowWords,
        redWords: redWords,
        errors: errors,
        cumulative: cumulative,
      )) {
        changed = true;
      }
    }

    if (changed) {
      if (_isAudioPlaying && _audioSurah != null && _audioAyah != null) {
        onAutoSavePosition?.call(_audioSurah!, _audioAyah!);
      }
      globalRevision.value++;
      notifyListeners();
    }
  }

  /// Merges remote word verdicts (cumulative history + live words of the
  /// current verse) into the highlight store. Pure store work — no coordinate
  /// or state writes — shared by flush and normal remote packets.
  bool _mergeRemoteVerdicts({
    required int surah,
    required int ayah,
    required List<int> greenWords,
    required List<int> yellowWords,
    required List<int> redWords,
    required Map<int, List<rq.ReciterError>>? errors,
    required Map<String, int>? cumulative,
  }) {
    bool changed = false;

    if (cumulative != null && cumulative.isNotEmpty) {
      cumulative.forEach((k, v) {
        if (v < 1 || v > 3) return;
        final parsed = int.tryParse(k, radix: 16);
        if (parsed != null) {
          final (s, a, w) = QuranCoordinate.unpackWordKey(parsed);
          if (v == 1) {
            _store.markGreen(s, a, w);
          } else if (v == 2) {
            _store.markYellow(s, a, w);
          } else if (v == 3) {
            _store.markRed(s, a, w);
          }
          changed = true;
        } else if (k.contains('_')) {
          final parts = k.split('_');
          if (parts.length == 3) {
            final s = int.tryParse(parts[0]);
            final a = int.tryParse(parts[1]);
            final w = int.tryParse(parts[2]);
            if (s != null && a != null && w != null) {
              if (v == 1) {
                _store.markGreen(s, a, w);
              } else if (v == 2) {
                _store.markYellow(s, a, w);
              } else if (v == 3) {
                _store.markRed(s, a, w);
              }
              changed = true;
            }
          }
        }
      });
    }

    for (final w in greenWords) {
      _store.markGreen(surah, ayah, w);
      changed = true;
    }
    for (final w in yellowWords) {
      final errList = errors?[w];
      final hydratedList = errList != null
          ? errList.map((e) => hydrateRemoteError(surah, ayah, w, e)).toList()
          : null;
      _store.markYellow(surah, ayah, w, hydratedList);
      changed = true;
    }
    for (final w in redWords) {
      _store.markRed(surah, ayah, w);
      changed = true;
    }

    return changed;
  }

  /// Hydrates a lightweight [rq.ReciterError] into a complete model with
  /// canonical Tajweed rule metadata and guidance derived locally from [repository].
  /// canonical Tajweed rule metadata and guidance derived locally from [repository].
  rq.ReciterError hydrateRemoteError(
    int surah,
    int ayah,
    int wordIndex,
    rq.ReciterError e,
  ) {
    if (e.expectedRule != null && e.durationStatus != null) return e;

    rq.TajweedRule? rule = e.expectedRule;
    rq.TajweedDurationStatus? durStatus = e.durationStatus;

    if (e.errorType == rq.ErrorCategory.tajweed) {
      if (rule == null) {
        final verse = repository.getVerse(surah, ayah);
        if (verse != null &&
            wordIndex >= 0 &&
            wordIndex < verse.wordRules.length) {
          final rules = verse.wordRules[wordIndex];
          if (rules.isNotEmpty) {
            final rq.WordTajweedRule matchedRule = rules.firstWhere(
              (r) => r.goldenLen == e.expectedPh.length,
              orElse: () => rules.first,
            );
            rule = instantiateTajweedRule(matchedRule, config);
          }
        }
      }

      if (durStatus == null) {
        if (e.expectedPh.length > e.predictedPh.length ||
            e.predictedPh.isEmpty) {
          durStatus = rq.TajweedDurationStatus.underheld;
        } else if (e.predictedPh.length > e.expectedPh.length) {
          durStatus = rq.TajweedDurationStatus.overheld;
        } else {
          durStatus = rq.TajweedDurationStatus.underheld;
        }
      }
    }

    return rq.ReciterError(
      errorType: e.errorType,
      speechErrorType: e.speechErrorType,
      durationStatus: durStatus,
      expectedPh: e.expectedPh,
      predictedPh: e.predictedPh,
      expectedRule: rule,
    );
  }

  /// Instantiates a canonical [rq.TajweedRule] from a dataset [rq.WordTajweedRule]
  /// matching the exact rule mapping used inside the `recite_quran` engine.
  static rq.TajweedRule instantiateTajweedRule(
    rq.WordTajweedRule wRule, [
    rq.TrackerConfig config = const rq.TrackerConfig(),
  ]) {
    final speed = config.recitationSpeed;
    switch (wRule.ruleId) {
      case 1:
        return const rq.NormalMaddRule();
      case 2:
        return rq.MonfaselMaddRule(speed.monfaselMaddHarakat);
      case 3:
        return rq.MottaselMaddRule(speed.mottaselMaddHarakat);
      case 4:
        return rq.MottaselMaddPauseRule(speed.mottaselMaddPauseHarakat);
      case 5:
        return rq.AaredMaddRule(speed.aaredMaddHarakat);
      case 6:
        return const rq.LazemMaddRule();
      case 7:
        return rq.LeenMaddRule(speed.leenMaddHarakat);
      case 9:
        return const rq.ShaddahRule();
      case 10:
        return rq.MushaddadGhunnahRule.withNames(
          nameAr: wRule.nameAr,
          nameEn: wRule.nameEn,
        );
      default:
        return rq.MaddRule(
          name: rq.LangName(ar: wRule.nameAr, en: wRule.nameEn),
          goldenLen: wRule.goldenLen,
        );
    }
  }

  /// Sets whether remote recitation is active (e.g. on floor release or peer leave).
  void setRemoteReciting(bool isReciting) {
    if (_isRemoteReciting != isReciting) {
      _isRemoteReciting = isReciting;
      if (!isReciting) {
        _remoteActiveWord = null;
      }
      globalRevision.value++;
      notifyListeners();
    }
  }

  // ── Audio Playback Ingestion ──

  /// Ingests audio playback state updates from the audio player.
  void applyAudioProgress({
    int? surah,
    int? ayah,
    int? wordIndex,
    bool? isPlaying,
    bool? isBuffering,
    bool? isPaused,
  }) {
    // If playback completely stopped or was reset to idle:
    if (isPlaying == false &&
        isBuffering == false &&
        isPaused != true &&
        surah == null &&
        ayah == null) {
      clearAudio();
      return;
    }

    bool changed = false;

    if (_audioSurah != surah) {
      _audioSurah = surah;
      changed = true;
    }
    if (_audioAyah != ayah) {
      _audioAyah = ayah;
      changed = true;
    }
    if (_audioWordIndex != wordIndex) {
      _audioWordIndex = wordIndex;
      changed = true;
    }
    if (isPlaying != null && _isAudioPlaying != isPlaying) {
      _isAudioPlaying = isPlaying;
      changed = true;
    }
    if (isBuffering != null && _isAudioBuffering != isBuffering) {
      _isAudioBuffering = isBuffering;
      changed = true;
    }
    if (isPaused != null && _isAudioPaused != isPaused) {
      _isAudioPaused = isPaused;
      changed = true;
    }

    // Align base controller targetSurah and activeAyah with audio playback verse only when actively playing/buffering
    if ((_isAudioPlaying || _isAudioBuffering) && surah != null && surah != 0) {
      // Audio claimed the coordinate while a remote reciter is active: pause
      // remote coordinate claims so the two sources don't yank the page back
      // and forth (verdicts keep merging either way).
      if (_isRemoteReciting) {
        _remoteFollowPaused = true;
      }
      if (_manualTargetSurah != surah) {
        _manualTargetSurah = surah;
        changed = true;
      }
      if (ayah != null && ayah != 0 && activeAyah.value != ayah) {
        activeAyah.value = ayah;
        changed = true;
      }
    }

    if (changed) {
      if ((_isAudioPlaying || _isAudioBuffering) &&
          _audioSurah != null &&
          _audioAyah != null) {
        onAutoSavePosition?.call(_audioSurah!, _audioAyah!);
        AppState.instance.saveLastPosition(_audioSurah!, _audioAyah!);
      }
      globalRevision.value++;
      notifyListeners();
    }
  }

  /// Clears audio playback state when audio stops.
  void clearAudio() {
    if (_audioSurah != null ||
        _audioAyah != null ||
        _audioWordIndex != null ||
        _isAudioPlaying ||
        _isAudioBuffering ||
        _isAudioPaused) {
      _audioSurah = null;
      _audioAyah = null;
      _audioWordIndex = null;
      _isAudioPlaying = false;
      _isAudioBuffering = false;
      _isAudioPaused = false;
      globalRevision.value++;
      notifyListeners();
    }
  }

  // ── Clearing & Synchronization ──

  @override
  void clearHighlightsFromAyah(int startAyah, {int? surah}) {
    final s = surah ?? targetSurah;
    _store.clearSurahFromAyah(s, startAyah);
    super.clearHighlightsFromAyah(startAyah);
    globalRevision.value++;
    notifyListeners();
  }

  @override
  void clearHighlightsForSurah(int surah) {
    _store.clearSurah(surah);
    super.clearHighlightsForSurah(surah);
    globalRevision.value++;
    notifyListeners();
  }

  /// Clears highlights from [startAyah] onwards in [surah], and clears all highlights
  /// in subsequent Surahs ([surah] + 1 .. 114). Prior verses and Surahs are strictly preserved.
  void clearHighlightsForwardFrom(int surah, int startAyah) {
    clearHighlightsFromAyah(startAyah, surah: surah);
    for (int s = surah + 1; s <= QuranMetadata.maxSurah; s++) {
      clearHighlightsForSurah(s);
    }
  }

  // ── Quran Presentation Queries ──

  /// Returns the 0-based lead ("waited") word index — the one word the
  /// reciter is about to say, rendered as the anticipatory cursor:
  /// - audio playback: the player's word cursor
  /// - remote Maglis session: the peer's active word (plain source priority,
  ///   not special handling — packets merge through the same store)
  /// - live local ASR while recording: the first not-yet-read word
  ///
  /// The lead word only exists inside the live coordinate; everything outside
  /// it renders from the store's green/red/yellow states alone.
  int? getLeadWordIndex({
    required int surah,
    required int ayah,
    required int totalWords,
    bool isRecording = false,
  }) {
    if (activeAyah.value != ayah || (targetSurah != 0 && targetSurah != surah)) {
      return null;
    }
    if (isAudioActive) return audioWordIndex;
    if (isRemoteReciting) return activeWordIndex;
    if (isRecording) {
      for (int i = 0; i < totalWords; i++) {
        if (!isWordRead(ayah, i, surah: surah)) {
          return i;
        }
      }
    }
    return null;
  }

  /// Determines if an Ayah is actively selected, reciting, or playing audio.
  /// Pure coordinate check: every source mirrors into the coordinate, so
  /// there is nothing else to consult.
  bool isAyahActive(int surah, int ayah) =>
      activeAyah.value == ayah && targetSurah == surah;

  /// The single coordinate every recitation source currently drives.
  ///
  /// Audio progress and Maglis packets are mirrored into
  /// [targetSurah]/[activeAyah] by their merge points — the same fields live
  /// local ASR writes — so any host that renders pages follows this one pair
  /// to stay in sync through ayahs, pages and surahs. Surah 0 means no
  /// coordinate exists yet (fresh app, nothing selected or recited).
  (int surah, int? ayah) get recitationCoordinate {
    if (targetSurah != 0) return (targetSurah, activeAyah.value);
    return (AppState.instance.lastSurah, activeAyah.value);
  }

  @override
  void clearHighlights() {
    _store.clearAll();
    _remoteActiveWord = null;
    _manualTargetSurah = 0;
    super.clearHighlights();
    globalRevision.value++;
    notifyListeners();
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Quran Highlight Palette & Styling
// ─────────────────────────────────────────────────────────────────────────────

/// Unified Quran Highlight Palette.
/// Centralizes all recitation highlight and cursor shades, borders, and opacities
/// ensuring identical visual fidelity across Mushaf Vector Canvas and Verse List Row viewports.
class QuranHighlightPalette {
  final Color greenBand;
  final Color yellowBand;
  final Color redBand;
  final Color leadWordBand;
  final Color activeAyahBorder;
  final Color activeAyahBand;

  const QuranHighlightPalette({
    required this.greenBand,
    required this.yellowBand,
    required this.redBand,
    required this.leadWordBand,
    required this.activeAyahBorder,
    required this.activeAyahBand,
  });

  /// Derives consistent, serene highlight shades from the active app theme.
  ///
  /// Memoized: this is called from the paint path, which can run at animation
  /// frequency (e.g. the audio-buffering spinner ticks repaint the page). Colors
  /// are immutable values, so a change in theme always produces a changed value
  /// in the signature — only a real theme change allocates a new palette.
  factory QuranHighlightPalette.fromTheme({
    required ThemeColors colors,
    required bool isDark,
  }) {
    final sig = Object.hash(colors.green, colors.warning, colors.red,
        colors.wordHighlight, colors.gold, isDark);
    if (_memoSig == sig) return _memoPalette!;
    final palette = QuranHighlightPalette(
      greenBand: colors.green.withValues(alpha: isDark ? 0.26 : 0.20),
      yellowBand: colors.warning.withValues(alpha: isDark ? 0.26 : 0.22),
      redBand: colors.red.withValues(alpha: isDark ? 0.26 : 0.20),
      leadWordBand: colors.wordHighlight.withValues(alpha: isDark ? 0.32 : 0.28),
      activeAyahBorder: colors.gold.withValues(alpha: isDark ? 0.70 : 0.60),
      activeAyahBand: isDark
          ? const Color(0xFF64748B).withValues(alpha: 0.20)
          : const Color(0xFF64748B).withValues(alpha: 0.11),
    );
    _memoSig = sig;
    return _memoPalette = palette;
  }

  /// Identity of the theme the memoized palette was built from.
  static int? _memoSig;
  static QuranHighlightPalette? _memoPalette;

  /// Resolves the band color for a numeric word highlight state:
  /// 1: Green (Correct)
  /// 2: Yellow (Tajweed Warning)
  /// 3: Red (Mispronounced/Skipped)
  /// isLead: Active anticipatory cursor (Word N+1)
  Color bandForState(int state, {bool isLead = false}) {
    if (isLead) return leadWordBand;
    if (state == 1) return greenBand;
    if (state == 2) return yellowBand;
    if (state == 3) return redBand;
    return Colors.transparent;
  }
}

/// Contiguous word highlight span model.
/// Standardizes ribbon and pill grouping across both Mushaf Vector and Verse List views.
class WordHighlightSpan {
  final int state;
  final int startWord;
  final int endWord;
  final bool isLead;

  const WordHighlightSpan({
    required this.state,
    required this.startWord,
    required this.endWord,
    this.isLead = false,
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// Quran Domain Metadata & Arithmetic (Consolidated from quran_metadata.dart)
// ─────────────────────────────────────────────────────────────────────────────

/// Canonical Quran Metadata & Navigation arithmetic.
abstract final class QuranMetadata {
  static const int minSurah = 1;
  static const int maxSurah = 114;
  static const int minPage = 1;
  static const int maxPage = 604;

  /// Checks if [surah] is in the valid 1..114 range.
  static bool isValidSurah(int surah) => surah >= minSurah && surah <= maxSurah;

  /// Checks if [page] is in the valid 1..604 Mushaf page range.
  static bool isValidPage(int page) => page >= minPage && page <= maxPage;

  /// Clamps [surah] to the valid 1..114 range.
  static int clampSurah(int surah) => surah.clamp(minSurah, maxSurah);

  /// Clamps [page] to the valid 1..604 range.
  static int clampPage(int page) => page.clamp(minPage, maxPage);

  /// Formats the canonical 3-digit QVP page asset filename (e.g. '001.qvp').
  static String formatPageKey(int page) => '${page.toString().padLeft(3, '0')}.qvp';

  /// Canonical Ayah count for Surahs 1 to 114.
  static const List<int> surahAyahCounts = [
    7, 286, 200, 176, 120, 165, 206, 75, 129, 109,
    123, 111, 43, 52, 99, 128, 111, 110, 98, 135,
    112, 78, 118, 64, 77, 227, 93, 88, 69, 60,
    34, 30, 73, 54, 45, 83, 182, 88, 75, 85,
    54, 53, 89, 59, 37, 35, 38, 29, 18, 45,
    60, 49, 62, 55, 78, 96, 29, 22, 24, 13,
    14, 11, 11, 18, 12, 12, 30, 52, 52, 44,
    28, 28, 20, 56, 40, 31, 50, 40, 46, 42,
    29, 19, 36, 25, 22, 17, 19, 26, 30, 20,
    15, 21, 11, 8, 8, 19, 5, 8, 8, 11,
    11, 8, 3, 9, 5, 4, 7, 3, 6, 3,
    5, 4, 5, 6
  ];

  /// Returns total Ayahs for [surah], or 0 if out of range.
  static int getAyahCount(int surah) {
    if (surah >= 1 && surah <= 114) {
      return surahAyahCounts[surah - 1];
    }
    return 0;
  }

  /// Checks if [surah] and [ayah] constitute a valid Quranic coordinate.
  static bool isValidAyah(int surah, int ayah) {
    if (!isValidSurah(surah)) return false;
    final max = surahAyahCounts[surah - 1];
    return ayah >= 1 && ayah <= max;
  }

  /// Checks if [ayah] is the final Ayah in [surah].
  static bool isLastAyahInSurah(int surah, int ayah) {
    if (!isValidSurah(surah)) return false;
    return ayah == surahAyahCounts[surah - 1];
  }

  /// Computes the subsequent Ayah across Surah boundaries, or null if end of Quran.
  static (int surah, int ayah)? getNextAyah(int surah, int ayah) {
    if (!isValidSurah(surah)) return null;
    final max = surahAyahCounts[surah - 1];
    if (ayah < max) {
      return (surah, ayah + 1);
    } else if (surah < 114) {
      return (surah + 1, 1);
    }
    return null;
  }

  /// Computes the previous Ayah across Surah boundaries, or null if beginning of Quran.
  static (int surah, int ayah)? getPreviousAyah(int surah, int ayah) {
    if (!isValidSurah(surah)) return null;
    if (ayah > 1) {
      return (surah, ayah - 1);
    } else if (surah > 1) {
      final prevSurah = surah - 1;
      return (prevSurah, surahAyahCounts[prevSurah - 1]);
    }
    return null;
  }

  /// Canonical 114 Surah names in Arabic.
  static const List<String> surahNamesAr = [
    'الفاتحة', 'البقرة', 'آل عمران', 'النساء', 'المائدة', 'الأنعام', 'الأعراف', 'الأنفال', 'التوبة', 'يونس',
    'هود', 'يوسف', 'الرعد', 'إبراهيم', 'الحجر', 'النحل', 'الإسراء', 'الكهف', 'مريم', 'طه',
    'الأنبياء', 'الحج', 'المؤمنون', 'النور', 'الفرقان', 'الشعراء', 'النمل', 'القصص', 'العنكبوت', 'الروم',
    'لقمان', 'السجدة', 'الأحزاب', 'سبأ', 'فاطر', 'يس', 'الصافات', 'ص', 'الزمر', 'غافر',
    'فصلت', 'الشورى', 'الزخرف', 'الدخان', 'الجاثية', 'الأحقاف', 'محمد', 'الفتح', 'الحجرات', 'ق',
    'الذاريات', 'الطور', 'النجم', 'القمر', 'الرحمن', 'الواقعة', 'الحديد', 'المجادلة', 'الحشر', 'الممتحنة',
    'الصف', 'الجمعة', 'المنافقون', 'التغابن', 'الطلاق', 'التحريم', 'الملك', 'القلم', 'الحاقة', 'المعارج',
    'نوح', 'الجن', 'المزمل', 'المدثر', 'القيامة', 'الإنسان', 'المرسلات', 'النبأ', 'النازعات', 'عبس',
    'التكوير', 'الانفطار', 'المطففين', 'الانشقاق', 'البروج', 'الطارق', 'الأعلى', 'الغاشية', 'الفجر', 'البلد',
    'الشمس', 'الليل', 'الضحى', 'الشرح', 'التين', 'العلق', 'القدر', 'البينة', 'الزلزلة', 'العاديات',
    'القارعة', 'التكاثر', 'العصر', 'الهمزة', 'الفيل', 'قريش', 'الماعون', 'الكوثر', 'الكافرون', 'النصر',
    'المسد', 'الإخلاص', 'الفلق', 'الناس'
  ];

  /// Returns canonical Arabic Surah name (e.g. 'الفاتحة').
  static String getSurahNameArabic(int surah) {
    if (surah >= 1 && surah <= 114) {
      return surahNamesAr[surah - 1];
    }
    return '';
  }
}

/// Dedicated high-performance typography formatter for Eastern Arabic numbers and Quran text.
abstract final class QuranTypography {
  /// Canonical Uthmani Hafs Smart Quranic font family for Quran words.
  static const String quranWordsFont = 'HafsSmart';

  /// Aliases for backward compatibility and naming flexibility.
  static const String Quranwordsfont = quranWordsFont;
  static const String quranFontFamily = quranWordsFont;

  /// Standard app UI font family.
  static const String uiFontFamily = 'cairo';

  static final List<String> _arabicDigitsCache =
      List<String>.generate(650, (i) {
    const digits = ['٠', '١', '٢', '٣', '٤', '٥', '٦', '٧', '٨', '٩'];
    return i.toString().split('').map((e) => digits[int.parse(e)]).join('');
  });

  /// Converts an integer, double, or numeric string to Eastern Arabic numeral glyphs (e.g. 1 -> '١', '1.5' -> '١.٥').
  static String toArabicDigits(Object value) {
    if (value is int && value >= 0 && value < _arabicDigitsCache.length) {
      return _arabicDigitsCache[value];
    }
    const digits = ['٠', '١', '٢', '٣', '٤', '٥', '٦', '٧', '٨', '٩'];
    final s = value.toString();
    final buffer = StringBuffer();
    for (int i = 0; i < s.length; i++) {
      final code = s.codeUnitAt(i);
      if (code >= 48 && code <= 57) {
        buffer.write(digits[code - 48]);
      } else {
        buffer.writeCharCode(code);
      }
    }
    return buffer.toString();
  }

  /// Converts any Eastern Arabic numeral glyphs (٠-٩) in [input] to standard ASCII digits (0-9).
  static String toWesternDigits(String input) {
    const eastern = ['٠', '١', '٢', '٣', '٤', '٥', '٦', '٧', '٨', '٩'];
    String result = input;
    for (int i = 0; i < 10; i++) {
      result = result.replaceAll(eastern[i], i.toString());
    }
    return result;
  }

  /// Formats an input digit string according to locale:
  /// converts to Eastern Arabic digits (٠-٩) if [isArabic] is true, otherwise standard ASCII.
  static String formatDigits(String input, {required bool isArabic}) {
    if (input.isEmpty) return input;
    final normalized = toWesternDigits(input);
    if (!isArabic) return normalized;
    const digits = ['٠', '١', '٢', '٣', '٤', '٥', '٦', '٧', '٨', '٩'];
    return normalized.split('').map((char) {
      final n = int.tryParse(char);
      return n != null ? digits[n] : char;
    }).join('');
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Quran Interaction Service (Consolidated from quran_interaction_service.dart)
// ─────────────────────────────────────────────────────────────────────────────

/// Centralized Quran User Interaction Service.
///
/// Handles Ayah selection, word clicks (Tajweed error dialog vs word audio audition),
/// and continuous Ayah audio playback across both Mushaf Vector and Verse List views.
abstract final class QuranInteractionService {
  /// Handles selecting/tapping an Ayah: manual selection, and persisting last position.
  static Future<void> selectAyah({
    required int surah,
    required int ayah,
    required HighlightingController controller,
    VoidCallback? onTap,
  }) async {
    if (controller.isAudioActive) {
      QuranAudioService.instance.stop();
      controller.clearAudio();
    }
    controller.setManualAyah(surah, ayah);
    onTap?.call();
  }

  /// Handles tapping a Quranic word:
  /// - Selects the Ayah.
  /// - If yellow word -> opens Tajweed error dialog.
  /// - If non-yellow word and (already selected or [playWordDirectly]) -> plays word audio.
  static void handleWordTap({
    required BuildContext context,
    required int surah,
    required int ayah,
    required int wordIndex,
    required String wordText,
    required HighlightingController controller,
    VoidCallback? onWordErrorTap,
    VoidCallback? onAyahTap,
    bool playWordDirectly = false,
    List<rq.ReciterError>? overrideErrors,
  }) {
    final bool isYellow =
        controller.isWordYellow(ayah, wordIndex, surah: surah);
    final errors = overrideErrors ??
        (isYellow
            ? controller.getWordErrors(ayah, wordIndex, surah: surah)
            : null);

    // Tajweed warning words ALWAYS show the error detail dialog directly
    // without requiring the verse to be active or mutated.
    if (errors != null && errors.isNotEmpty) {
      AppState.instance.markTajweedWordClicked();
      DialogService.showTajweedError(
        context,
        word: wordText,
        errors: errors,
        surah: surah,
        ayah: ayah,
        wordIndex: wordIndex,
      );
      onWordErrorTap?.call();
      return;
    }

    final bool isAlreadySelected =
        controller.targetSurah == surah && controller.activeAyah.value == ayah;

    // A word cannot be auditioned or selected unless the ayah itself is selected first.
    if (!isAlreadySelected && !playWordDirectly) {
      selectAyah(
        surah: surah,
        ayah: ayah,
        controller: controller,
        onTap: onAyahTap,
      );
      return;
    }

    QuranAudioService.instance.playWord(
      surah: surah,
      ayah: ayah,
      wordIndex: wordIndex,
    );
  }

  /// Toggles Ayah audio playback.
  static Future<void> toggleAyahAudio({
    required int surah,
    required int ayah,
    required HighlightingController controller,
    required bool isRecording,
    VoidCallback? onTap,
    VoidCallback? onExplicitToggle,
  }) async {
    if (onExplicitToggle != null) {
      onTap?.call();
      onExplicitToggle();
    } else {
      await QuranAudioService.instance.toggleAyah(
        surah: surah,
        ayah: ayah,
        controller: controller,
        continuous: !isRecording,
        onTap: onTap,
      );
    }
  }

  /// Resolves the word display color, handling zero-GPU blur hiding for unrecited words.
  static Color resolveWordDisplayColor({
    required int ayah,
    required int wordIndex,
    required HighlightingController controller,
    required AppState app,
    required ThemeColors colors,
    int? surah,
    bool isBlurEffective = false,
  }) {
    if (wordIndex < 0) return colors.text;
    final int s = surah ??
        (controller.targetSurah != 0
            ? controller.targetSurah
            : AppState.instance.lastSurah);

    if (controller.isWordGreen(ayah, wordIndex, surah: s)) {
      return colors.green;
    }
    if (controller.isWordYellow(ayah, wordIndex, surah: s)) {
      return colors.warning;
    }
    if (controller.isWordRed(ayah, wordIndex, surah: s)) {
      return colors.red;
    }

    final bool isNeutral = controller.isWordNeutral(ayah, wordIndex, surah: s);
    if (isBlurEffective) {
      if (isNeutral) return colors.text;
      return Colors.transparent;
    }

    return colors.text;
  }
}


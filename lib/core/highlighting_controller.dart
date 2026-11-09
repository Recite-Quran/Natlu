import 'dart:async';
import 'package:flutter/material.dart';
import 'package:recite_quran/recite_quran.dart' as rq;
export 'package:recite_quran/recite_quran.dart' hide HighlightingController;

import 'platform_utils.dart';
import 'app_state.dart';
import '../audio/quran_audio_service.dart';
import '../maglis/maglis_controller.dart';
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
  int? _remoteActiveWord;
  bool _isRemoteReciting = false;

  // Audio Playback state
  int? _audioSurah;
  int? _audioAyah;
  int? _audioWordIndex;
  bool _isAudioPlaying = false;
  bool _isAudioBuffering = false;

  HighlightingController({
    required super.repository,
    required super.engine,
    super.onAyahChanged,
    super.isTajweed = true,
    super.config = const rq.TrackerConfig(),
  });

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

  // ── Audio Playback State ──

  /// Whether Quran verse/word audio playback or buffering is currently active.
  bool get isAudioActive =>
      (_isAudioPlaying || _isAudioBuffering) &&
      _audioSurah != null &&
      _audioAyah != null;

  bool get isAudioPlaying => _isAudioPlaying;
  bool get isAudioBuffering => _isAudioBuffering;
  bool get isAudioPaused =>
      !_isAudioPlaying &&
      !_isAudioBuffering &&
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
  (int surah, int ayah)? get activeAyahCoordinate {
    if (isAudioActive && _audioSurah != null && _audioAyah != null) {
      return (_audioSurah!, _audioAyah!);
    }
    final activeMatch = currentMatchedVerse;
    if (activeMatch != null) {
      return (activeMatch.verse.surah, activeMatch.verse.ayah);
    }
    if (activeAyah.value != null && targetSurah != 0) {
      return (targetSurah, activeAyah.value!);
    }
    return null;
  }

  /// Direct access to the highlight store.
  HighlightStore get highlightStore => _store;

  @override
  int get targetSurah {
    if (_isRemoteReciting && _remoteTargetSurah != 0) {
      return _remoteTargetSurah;
    }
    if (isAudioActive && _audioSurah != null && _audioSurah != 0) {
      return _audioSurah!;
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
    if (!preserveOtherSurahStates) {
      _store.clearAllExceptSurah(surah);
    }
    if (clearTargetSurah) {
      _store.clearSurah(surah);
    }
    await super.setTargetSurah(
      surah,
      preserveOtherSurahStates: preserveOtherSurahStates,
      clearTargetSurah: clearTargetSurah,
    );
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
  Future<bool> advanceToNextSurah({bool isRecording = false}) async {
    final int nextSurah = targetSurah + 1;
    if (!QuranMetadata.isValidSurah(nextSurah)) return false;

    await setTargetSurah(
      nextSurah,
      preserveOtherSurahStates: true,
      clearTargetSurah: false,
    );
    setManualAyah(nextSurah, 1);
    if (isRecording) {
      startRecordingSession();
    }
    onSurahAutoAdvanced?.call(nextSurah, 1);
    return true;
  }

  /// Extracts classified word indices (green, yellow, red) and errors for an ayah,
  /// while seamlessly recording local ASR matches into the flat [_store] for O(1) snapshots.
  ({
    List<int> greenWords,
    List<int> yellowWords,
    List<int> redWords,
    Map<int, List<rq.ReciterError>>? wordErrors,
  }) extractAyahWordClassification(int surah, int ayah, int wordCount) {
    final greenWords = <int>[];
    final yellowWords = <int>[];
    final redWords = <int>[];
    Map<int, List<rq.ReciterError>>? wordErrors;

    for (int w0 = 0; w0 < wordCount; w0++) {
      if (isWordRed(ayah, w0, surah: surah)) {
        redWords.add(w0);
        _store.markRed(surah, ayah, w0);
      } else if (isWordYellow(ayah, w0, surah: surah)) {
        yellowWords.add(w0);
        final errs = getWordErrors(ayah, w0, surah: surah);
        if (errs != null && errs.isNotEmpty) {
          (wordErrors ??= {})[w0] = errs;
        }
        _store.markYellow(surah, ayah, w0, errs);
      } else if (isWordGreen(ayah, w0, surah: surah)) {
        greenWords.add(w0);
        _store.markGreen(surah, ayah, w0);
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
    super.setManualAyah(surah, ayah);
    onAutoSavePosition?.call(surah, ayah);
  }

  @override
  rq.VerseMatch? get currentMatchedVerse {
    if (_isRemoteReciting && _remoteTargetSurah != 0 && activeAyah.value != null) {
      final v = repository.getVerse(_remoteTargetSurah, activeAyah.value!);
      if (v != null) {
        return rq.VerseMatch(verse: v, score: 1.0);
      }
    }
    return super.currentMatchedVerse;
  }

  // ── Word Status Queries (Local ASR + Remote Maglis + Audio) ──

  @override
  bool isWordGreen(int ayah, int wordIndex, {int? surah}) {
    final s = surah ?? targetSurah;
    if (_store.isGreen(s, ayah, wordIndex)) return true;
    return super.isWordGreen(ayah, wordIndex, surah: s);
  }

  @override
  bool isWordYellow(int ayah, int wordIndex, {int? surah}) {
    final s = surah ?? targetSurah;
    if (_store.isYellow(s, ayah, wordIndex)) return true;
    return super.isWordYellow(ayah, wordIndex, surah: s);
  }

  @override
  bool isWordRed(int ayah, int wordIndex, {int? surah}) {
    final s = surah ?? targetSurah;
    if (_store.isRed(s, ayah, wordIndex)) return true;
    return super.isWordRed(ayah, wordIndex, surah: s);
  }

  @override
  bool isWordNeutral(int ayah, int wordIndex, {int? surah}) {
    final s = surah ?? targetSurah;
    if (_store.isNeutral(s, ayah, wordIndex)) return true;
    return super.isWordNeutral(ayah, wordIndex, surah: s);
  }

  /// Checks whether a word has any recognized recitation status (green, yellow, red, or neutral).
  bool isWordRead(int ayah, int wordIndex, {int? surah}) {
    final s = surah ?? targetSurah;
    return isWordGreen(ayah, wordIndex, surah: s) ||
        isWordYellow(ayah, wordIndex, surah: s) ||
        isWordRed(ayah, wordIndex, surah: s) ||
        isWordNeutral(ayah, wordIndex, surah: s);
  }

  /// Returns numeric status representation for high-speed rendering:
  /// 1: Green (Correct)
  /// 2: Yellow (Tajweed Rule / Warning)
  /// 3: Red (Mispronounced)
  /// 4: Neutral (Spoken/Passed)
  /// null: Unread
  int? getWordStatus(int ayah, int wordIndex, {int? surah}) {
    final s = surah ?? targetSurah;
    if (isWordGreen(ayah, wordIndex, surah: s)) return 1;
    if (isWordYellow(ayah, wordIndex, surah: s)) return 2;
    if (isWordRed(ayah, wordIndex, surah: s)) return 3;
    if (isWordNeutral(ayah, wordIndex, surah: s)) return 4;
    return null;
  }

  @override
  List<rq.ReciterError>? getWordErrors(int ayah, int wordIndex, {int? surah}) {
    final s = surah ?? targetSurah;
    return _store.errorsFor(s, ayah, wordIndex) ??
        super.getWordErrors(ayah, wordIndex, surah: s);
  }

  @override
  Set<int> completedAyahsFor(int surah) {
    final remoteSet = _store.completedAyahsFor(surah);
    final localSet = super.completedAyahsFor(surah);
    if (remoteSet.isEmpty) return localSet;
    if (localSet.isEmpty) return remoteSet;
    return {...localSet, ...remoteSet};
  }

  /// High-speed O(1) check if a specific ayah has any stored highlights across local or remote store.
  bool hasAyahHighlights(int surah, int ayah) {
    return _store.hasAyahHighlights(surah, ayah);
  }

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
  }) {
    _isRemoteReciting = isReciting;
    _remoteTargetSurah = surah;
    _remoteActiveWord = activeWord;

    bool changed = false;

    // 1. Merge snapshot or catch-up cumulative history
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

    // 2. Merge active live words for current verse
    for (final w in greenWords) {
      _store.markGreen(surah, ayah, w);
      changed = true;
    }
    for (final w in yellowWords) {
      final errList = errors?[w];
      _store.markYellow(surah, ayah, w, errList);
      changed = true;
    }
    for (final w in redWords) {
      _store.markRed(surah, ayah, w);
      changed = true;
    }

    // 3. Complete ayahs prior to the current active ayah in the same surah
    if (ayah > 1) {
      for (int a = 1; a < ayah; a++) {
        _store.markAyahCompleted(surah, a);
      }
    }

    if (activeAyah.value != ayah) {
      activeAyah.value = ayah;
      changed = true;
    }

    if (changed) {
      if (_isAudioPlaying && _audioSurah != null && _audioAyah != null) {
        onAutoSavePosition?.call(_audioSurah!, _audioAyah!);
      }
      globalRevision.value++;
      notifyListeners();
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
  }) {
    bool changed = false;

    if (surah != null && _audioSurah != surah) {
      _audioSurah = surah;
      changed = true;
    }
    if (ayah != null && _audioAyah != ayah) {
      _audioAyah = ayah;
      changed = true;
    }
    if (wordIndex != null && _audioWordIndex != wordIndex) {
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

    if (changed) {
      if (_isAudioPlaying && _audioSurah != null && _audioAyah != null) {
        onAutoSavePosition?.call(_audioSurah!, _audioAyah!);
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
        _isAudioBuffering) {
      _audioSurah = null;
      _audioAyah = null;
      _audioWordIndex = null;
      _isAudioPlaying = false;
      _isAudioBuffering = false;
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

  /// Returns the 0-based lead target word index:
  /// - Audio mode: audioWordIndex
  /// - Remote Maglis mode: activeWord
  /// - Live ASR mode: first unread word (+1 anticipatory cursor)
  int? getLeadWordIndex({
    required int surah,
    required int ayah,
    required int totalWords,
    bool isRecording = false,
  }) {
    if (isAudioActive && audioSurah == surah && audioAyah == ayah) {
      return audioWordIndex;
    }
    if (isRemoteReciting && targetSurah == surah && activeAyah.value == ayah) {
      return activeWordIndex;
    }
    if (isRecording && targetSurah == surah && activeAyah.value == ayah) {
      for (int i = 0; i < totalWords; i++) {
        if (!isWordRead(ayah, i, surah: surah)) {
          return i;
        }
      }
    }
    return null;
  }

  /// Determines if an Ayah is actively selected, reciting, or playing audio.
  bool isAyahActive(int surah, int ayah) {
    if (isAudioActive && audioSurah == surah && audioAyah == ayah) return true;
    final activeMatch = currentMatchedVerse;
    if (activeMatch != null &&
        activeMatch.verse.surah == surah &&
        activeMatch.verse.ayah == ayah) {
      return true;
    }
    return activeAyah.value == ayah && targetSurah == surah;
  }

  @override
  void clearHighlights() {
    _store.clearAll();
    _remoteActiveWord = null;
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
  factory QuranHighlightPalette.fromTheme({
    required ThemeColors colors,
    required bool isDark,
  }) {
    return QuranHighlightPalette(
      greenBand: colors.green.withValues(alpha: isDark ? 0.22 : 0.15),
      yellowBand: colors.warning.withValues(alpha: isDark ? 0.24 : 0.18),
      redBand: colors.red.withValues(alpha: isDark ? 0.22 : 0.14),
      leadWordBand: colors.wordHighlight.withValues(alpha: isDark ? 0.24 : 0.16),
      activeAyahBorder: colors.gold.withValues(alpha: isDark ? 0.70 : 0.60),
      activeAyahBand: isDark
          ? Colors.white.withValues(alpha: 0.10)
          : const Color(0xFF64748B).withValues(alpha: 0.09),
    );
  }

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

  /// Converts an integer to Eastern Arabic numeral glyphs (e.g. 1 -> '١').
  static String toArabicDigits(int number) {
    if (number >= 0 && number < _arabicDigitsCache.length) {
      return _arabicDigitsCache[number];
    }
    const digits = ['٠', '١', '٢', '٣', '٤', '٥', '٦', '٧', '٨', '٩'];
    return number
        .toString()
        .split('')
        .map((e) => digits[int.parse(e)])
        .join('');
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
  /// Handles selecting/tapping an Ayah: haptic feedback, manual selection, and persisting last position.
  static Future<void> selectAyah({
    required int surah,
    required int ayah,
    required HighlightingController controller,
    VoidCallback? onTap,
  }) async {
    AppHaptics.lightImpact();
    if (controller.targetSurah != surah) {
      await controller.setTargetSurah(
        surah,
        preserveOtherSurahStates: true,
        clearTargetSurah: false,
      );
    }
    controller.setManualAyah(surah, ayah);
    AppState.instance.saveLastPosition(surah, ayah);
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
    final bool isAlreadySelected =
        controller.targetSurah == surah && controller.activeAyah.value == ayah;

    selectAyah(
      surah: surah,
      ayah: ayah,
      controller: controller,
      onTap: onAyahTap,
    );

    final errors = overrideErrors ??
        (controller.isWordYellow(ayah, wordIndex, surah: surah)
            ? controller.getWordErrors(ayah, wordIndex, surah: surah)
            : null);

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
    } else if (isAlreadySelected || playWordDirectly) {
      if (MaglisController.instance.inSession) {
        return;
      }
      QuranAudioService.instance.playWord(
        surah: surah,
        ayah: ayah,
        wordIndex: wordIndex,
      );
    }
  }

  /// Toggles Ayah audio playback with buffering debounce and haptic feedback.
  static Future<void> toggleAyahAudio({
    required int surah,
    required int ayah,
    required HighlightingController controller,
    required bool isRecording,
    VoidCallback? onTap,
    VoidCallback? onExplicitToggle,
  }) async {
    if (MaglisController.instance.inSession) return;
    if (controller.isAudioBuffering &&
        controller.audioSurah == surah &&
        controller.audioAyah == ayah) {
      return;
    }
    AppHaptics.selectionClick();
    if (controller.targetSurah != surah) {
      await controller.setTargetSurah(
        surah,
        preserveOtherSurahStates: true,
        clearTargetSurah: false,
      );
    }
    controller.setManualAyah(surah, ayah);
    AppState.instance.saveLastPosition(surah, ayah);
    onTap?.call();
    if (onExplicitToggle != null) {
      onExplicitToggle();
    } else {
      await QuranAudioService.instance.toggleAyah(
        surah: surah,
        ayah: ayah,
        controller: controller,
        continuous: !isRecording,
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


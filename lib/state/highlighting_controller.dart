import 'package:recite_quran/recite_quran.dart' as rq;
export 'package:recite_quran/recite_quran.dart' hide HighlightingController;

/// Recitation & Audio playback source.
enum RecitationSource {
  none,
  localAsr,
  maglisRemote,
  audioPlayback,
}

/// HighlightStore
///
/// High-performance O(1) set-based store for Quran word highlight states
/// and Tajweed recitation errors. Serves as the single source of truth for all
/// producers (Local ASR, Remote Maglis, and Audio Playback).
class HighlightStore {
  // Key: surah -> (ayah -> Set of 0-based word indices)
  final Map<int, Map<int, Set<int>>> _green = {};
  final Map<int, Map<int, Set<int>>> _yellow = {};
  final Map<int, Map<int, Set<int>>> _red = {};
  final Map<int, Map<int, Set<int>>> _neutral = {};

  // Tajweed errors per word: surah -> (ayah -> (wordIndex -> List<ReciterError>))
  final Map<int, Map<int, Map<int, List<rq.ReciterError>>>> _errors = {};

  // Completed ayahs per surah: surah -> Set of ayah numbers (1-based)
  final Map<int, Set<int>> _completedAyahs = {};

  // ── Writes ──

  void markGreen(int surah, int ayah, int wordIndex) {
    _red[surah]?[ayah]?.remove(wordIndex);
    _yellow[surah]?[ayah]?.remove(wordIndex);
    _neutral[surah]?[ayah]?.remove(wordIndex);
    _errors[surah]?[ayah]?.remove(wordIndex);
    ((_green[surah] ??= {})[ayah] ??= {}).add(wordIndex);
  }

  void markYellow(
    int surah,
    int ayah,
    int wordIndex, [
    List<rq.ReciterError>? errors,
  ]) {
    _green[surah]?[ayah]?.remove(wordIndex);
    _red[surah]?[ayah]?.remove(wordIndex);
    _neutral[surah]?[ayah]?.remove(wordIndex);
    ((_yellow[surah] ??= {})[ayah] ??= {}).add(wordIndex);
    if (errors != null && errors.isNotEmpty) {
      ((_errors[surah] ??= {})[ayah] ??= {})[wordIndex] = errors;
    } else {
      _errors[surah]?[ayah]?.remove(wordIndex);
    }
  }

  void markRed(int surah, int ayah, int wordIndex) {
    _green[surah]?[ayah]?.remove(wordIndex);
    _yellow[surah]?[ayah]?.remove(wordIndex);
    _neutral[surah]?[ayah]?.remove(wordIndex);
    _errors[surah]?[ayah]?.remove(wordIndex);
    ((_red[surah] ??= {})[ayah] ??= {}).add(wordIndex);
  }

  void markNeutral(int surah, int ayah, int wordIndex) {
    _green[surah]?[ayah]?.remove(wordIndex);
    _yellow[surah]?[ayah]?.remove(wordIndex);
    _red[surah]?[ayah]?.remove(wordIndex);
    _errors[surah]?[ayah]?.remove(wordIndex);
    ((_neutral[surah] ??= {})[ayah] ??= {}).add(wordIndex);
  }

  void markAyahCompleted(int surah, int ayah) {
    (_completedAyahs[surah] ??= {}).add(ayah);
  }

  // ── Reads ──

  bool isGreen(int surah, int ayah, int wordIndex) =>
      _green[surah]?[ayah]?.contains(wordIndex) ?? false;

  bool isYellow(int surah, int ayah, int wordIndex) =>
      _yellow[surah]?[ayah]?.contains(wordIndex) ?? false;

  bool isRed(int surah, int ayah, int wordIndex) =>
      _red[surah]?[ayah]?.contains(wordIndex) ?? false;

  bool isNeutral(int surah, int ayah, int wordIndex) =>
      _neutral[surah]?[ayah]?.contains(wordIndex) ?? false;

  List<rq.ReciterError>? errorsFor(int surah, int ayah, int wordIndex) {
    if (!isYellow(surah, ayah, wordIndex)) return null;
    return _errors[surah]?[ayah]?[wordIndex];
  }

  Set<int> completedAyahsFor(int surah) =>
      _completedAyahs[surah] ?? const <int>{};

  bool get hasHighlights =>
      _green.isNotEmpty ||
      _yellow.isNotEmpty ||
      _red.isNotEmpty ||
      _neutral.isNotEmpty;

  // ── Clearing ──

  void clearAll() {
    _green.clear();
    _yellow.clear();
    _red.clear();
    _neutral.clear();
    _errors.clear();
    _completedAyahs.clear();
  }

  void clearSurah(int surah) {
    _green.remove(surah);
    _yellow.remove(surah);
    _red.remove(surah);
    _neutral.remove(surah);
    _errors.remove(surah);
    _completedAyahs.remove(surah);
  }

  void clearSurahFromAyah(int surah, int startAyah) {
    _completedAyahs[surah]?.removeWhere((ayah) => ayah >= startAyah);
    _green[surah]?.removeWhere((ayah, _) => ayah >= startAyah);
    _yellow[surah]?.removeWhere((ayah, _) => ayah >= startAyah);
    _red[surah]?.removeWhere((ayah, _) => ayah >= startAyah);
    _neutral[surah]?.removeWhere((ayah, _) => ayah >= startAyah);
    _errors[surah]?.removeWhere((ayah, _) => ayah >= startAyah);
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

  /// The active recitation or audio lead word index (0-based in active ayah).
  int? get activeWordIndex {
    if (_isRemoteReciting) return _remoteActiveWord;
    if (isAudioActive) return _audioWordIndex;
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
          final s = (parsed >> 20) & 0xFF;
          final a = (parsed >> 8) & 0xFFF;
          final w = parsed & 0xFF;
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

  @override
  void clearHighlights() {
    _store.clearAll();
    _remoteActiveWord = null;
    super.clearHighlights();
    globalRevision.value++;
    notifyListeners();
  }
}

// lib/scoring.dart
// ═══════════════════════════════════════════════════════════════════════════════
// QURAN RECITATION SCORING & TAJWEED EVALUATION SYSTEM
// ═══════════════════════════════════════════════════════════════════════════════
// Pure recitation scoring, phoneme alignment, and deterministic Tajweed
// verification layer. Takes speech recognition transcriptions from any ASR
// engine, aligns phonemes using Dynamic Time Warping (DTW) against canonical
// Quranic text, verifies acoustic Tajweed rules, and emits per-word scores.
// ═══════════════════════════════════════════════════════════════════════════════

import 'dart:async';

import 'data/quran_data.dart';
import 'engine/core/transcription_result.dart';
import 'tracking/asr_token_processor.dart';
import 'tracking/word/phoneme_alignment_isolate.dart';

export 'data/quran_data.dart';
export 'data/reference_reader.dart';
export 'tracking/asr_token_processor.dart';
export 'tracking/ayah_search/fuzzy_search.dart';
export 'tracking/ayah_search/phonetic_search.dart';
export 'tracking/tajweed/error_explainer.dart';
export 'tracking/tajweed/tajweed_checkers.dart';
export 'tracking/tajweed/tajweed_config.dart';
export 'tracking/tajweed/tajweed_engine.dart';
export 'tracking/tajweed/tajweed_rule.dart';
export 'tracking/tracker_config.dart';
export 'tracking/word/dictation_matcher.dart';
export 'tracking/word/dictation_sequencer.dart';
export 'tracking/word/phoneme_alignment_isolate.dart';

/// A standalone Quran recitation evaluator and scoring system.
///
/// Takes transcription results from any speech recognition engine, aligns
/// phonemes using a background Dynamic Time Warping (DTW) isolate, and
/// evaluates deterministic acoustic Tajweed rules.
class QuranScorer {
  final QuranRepository repository;
  final PhonemeAlignmentIsolate _isolate = PhonemeAlignmentIsolate();
  late final AsrTokenProcessor _tokenProcessor;

  TrackerConfig _config;
  bool _isTajweed;
  bool _isInitialized = false;
  bool _isDisposed = false;
  int _targetSurah = 0;

  int? _pendingTargetSurah;
  int _pendingStartGlobalWord = 0;
  bool _pendingForceClear = true;

  StreamSubscription<WordMatchedEvent>? _wordSub;
  StreamSubscription<AutoReanchorEvent>? _reanchorSub;

  final StreamController<WordMatchedEvent> _wordEventController =
      StreamController<WordMatchedEvent>.broadcast();
  final StreamController<AutoReanchorEvent> _autoReanchorController =
      StreamController<AutoReanchorEvent>.broadcast();

  /// Stream of evaluated word events (correct, tajweedWarning, mispronounced, skipped).
  Stream<WordMatchedEvent> get onWordEvaluated => _wordEventController.stream;

  /// Stream of Auto-Reanchor events emitted when tracking synchronizes to a new verse.
  Stream<AutoReanchorEvent> get onAutoReanchored =>
      _autoReanchorController.stream;

  /// Current active tracker configuration.
  TrackerConfig get config => _config;

  /// Current target Surah number.
  int get targetSurah => _targetSurah;

  /// Indicates if Tajweed duration and closure evaluation is enabled.
  bool get isTajweed => _isTajweed;

  /// Whether the background alignment isolate has been initialized.
  bool get isInitialized => _isInitialized;

  /// Whether this instance has been disposed.
  bool get isDisposed => _isDisposed;

  QuranScorer({
    QuranRepository? repository,
    TrackerConfig config = const TrackerConfig(),
    bool isTajweed = true,
  })  : repository = repository ?? QuranRepository(QuranMetadataService()),
        _config = config,
        _isTajweed = (repository?.isTajweedSupported ?? true) && isTajweed {
    _tokenProcessor = AsrTokenProcessor(config: _config);
  }

  /// Initializes the background phoneme alignment isolate and ensures Quran reference data is loaded.
  Future<void> initialize() async {
    if (_isDisposed) {
      throw StateError('Cannot initialize a disposed QuranScorer instance.');
    }
    if (_isInitialized) return;

    if (!repository.isLoaded) {
      await repository.service.loadData();
    }

    await _isolate.start();
    _isolate.updateConfig(_config);
    _isolate.setTajweedMode(_isTajweed);

    _wordSub = _isolate.wordStream.listen(_wordEventController.add);
    _reanchorSub =
        _isolate.autoReanchorStream.listen(_autoReanchorController.add);

    _isInitialized = true;

    if (_pendingTargetSurah != null) {
      final int s = _pendingTargetSurah!;
      final int sg = _pendingStartGlobalWord;
      final bool fc = _pendingForceClear;
      _pendingTargetSurah = null;
      setTargetSurah(s, startGlobalWord: sg, forceClear: fc);
    }
  }

  /// Unified target setter for recitation scoring.
  /// Sets target by [surah], optionally focusing on [ayah] and [wordIndex].
  void setTarget({
    required int surah,
    int? ayah,
    int? wordIndex,
    bool forceClear = true,
  }) {
    if (_isDisposed) return;
    if (ayah == null && wordIndex == null) {
      setTargetSurah(surah, forceClear: forceClear);
    } else if (wordIndex == null) {
      setTargetAyah(surah, ayah!);
    } else {
      setTargetWord(surah: surah, ayah: ayah ?? 1, wordIndex: wordIndex);
    }
  }

  /// Sets the active Surah reference for recitation scoring.
  void setTargetSurah(
    int surahNumber, {
    int startGlobalWord = 0,
    bool forceClear = true,
  }) {
    if (_isDisposed) return;
    _targetSurah = surahNumber;

    final words = repository.getSurahWords(surahNumber);
    if (words.isEmpty) {
      _pendingTargetSurah = surahNumber;
      _pendingStartGlobalWord = startGlobalWord;
      _pendingForceClear = forceClear;
      return;
    }
    _pendingTargetSurah = null;

    final List<String> phonemeWords = words.map((w) => w.phoneme).toList();
    final List<List<WordTajweedRule>> wordRules =
        words.map((w) => w.rules).toList();
    final List<int> charRuleClasses =
        words.expand((w) => w.charRuleClasses).toList();
    final List<int> boundaries = _calculateBoundaries(phonemeWords);
    final String fullPhonemes = phonemeWords.join('');
    final List<int> ayahs = words.map((w) => w.ayah).toList();
    final List<int> wordsInAyah = words.map((w) => w.wordInAyah).toList();

    _isolate.setSurahReference(
      fullPhonemes,
      boundaries,
      isTajweed: _isTajweed,
      forceClear: forceClear,
      startGlobalWord: startGlobalWord,
      surahNumber: surahNumber,
      ayahs: ayahs,
      wordsInAyah: wordsInAyah,
      wordRules: wordRules,
      charRuleClasses: charRuleClasses,
    );
  }

  /// Sets the tracking target to a specific Ayah within a Surah.
  void setTargetAyah(int surahNumber, int ayahNumber) {
    if (_isDisposed) return;
    if (_targetSurah != surahNumber) {
      setTargetSurah(surahNumber);
    }
    final int startWord =
        repository.getAyahStartGlobalIndex(surahNumber, ayahNumber);
    jumpToWord(startWord);
  }

  /// Sets tracking target to a specific word within a Surah and Ayah.
  void setTargetWord({
    required int surah,
    required int ayah,
    required int wordIndex,
  }) {
    if (_isDisposed) return;
    if (_targetSurah != surah) {
      setTargetSurah(surah);
    }
    final int globalWord =
        repository.getWordGlobalIndex(surah, ayah, wordIndex);
    jumpToWord(globalWord);
  }

  /// Jumps the tracking cursor to a specific global word index.
  void jumpToWord(int globalWordIndex) {
    if (_isDisposed) return;
    _isolate.jumpToWord(globalWordIndex);
  }

  /// Feeds a speech recognition result (from QuranRecognizer, Sherpa-ONNX, etc.)
  /// into the scoring system.
  void feedTranscript(TranscriptionResult result) {
    if (_isDisposed || !_isInitialized) return;

    final processed = _tokenProcessor.process(result);
    if (processed.isEmpty) return;

    _isolate.syncStream(
      processed.text,
      processed.charDurations,
      false,
      0,
      processed.charNeuralAcoustics,
    );
  }

  /// Resets the internal token processing buffer.
  void resetBuffer() {
    if (_isDisposed) return;
    _tokenProcessor.reset();
  }

  /// Toggles Tajweed evaluation on/off.
  void setTajweedMode(bool active) {
    if (_isDisposed) return;
    final effective = repository.isTajweedSupported && active;
    _isTajweed = effective;
    _isolate.setTajweedMode(effective);
  }

  /// Updates difficulty and alignment thresholds at runtime.
  void updateConfig(TrackerConfig newConfig) {
    if (_isDisposed) return;
    _config = newConfig;
    _tokenProcessor.config = newConfig;
    _isolate.updateConfig(newConfig);
  }

  /// Current active Tajweed rule verification toggles.
  TajweedConfig get tajweedConfig => _config.tajweed;

  /// Updates specific Tajweed check toggles dynamically at runtime.
  void updateTajweedConfig(TajweedConfig newTajweedConfig) {
    if (_isDisposed) return;
    _config = _config.copyWith(tajweed: newTajweedConfig);
    _isolate.updateTajweedConfig(newTajweedConfig);
  }

  List<int> _calculateBoundaries(List<String> phonemeWords) {
    final List<int> boundaries = [0];
    int currentOffset = 0;
    for (final w in phonemeWords) {
      currentOffset += w.length;
      boundaries.add(currentOffset);
    }
    return boundaries;
  }

  /// Disposes of isolate ports and event streams.
  void dispose() {
    if (_isDisposed) return;
    _isDisposed = true;
    _isInitialized = false;

    _wordSub?.cancel();
    _wordSub = null;
    _reanchorSub?.cancel();
    _reanchorSub = null;

    _isolate.stop();

    if (!_wordEventController.isClosed) {
      _wordEventController.close();
    }
    if (!_autoReanchorController.isClosed) {
      _autoReanchorController.close();
    }
  }
}

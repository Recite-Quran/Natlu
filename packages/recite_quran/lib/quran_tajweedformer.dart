// lib/quran_tajweedformer.dart
import 'dart:async';
import 'dart:typed_data';

import 'data/quran_data.dart';
import 'engine/asr_token_processor.dart';
import 'engine/core/recite_engine.dart';
import 'engine/core/tajweed_diagnostics.dart';
import 'engine/core/transcription_result.dart';
import 'engine/tajweedformer_v4/tajweedformer_engine.dart';
import 'tracking/word/phoneme_alignment_isolate.dart';

export 'engine.dart';
export 'scoring.dart';
export 'utils/debug_logger.dart';

// ═══════════════════════════════════════════════════════════════════════════════
// QURAN TAJWEEDFORMER SDK (MAIN PUBLIC FACADE)
// ═══════════════════════════════════════════════════════════════════════════════

/// The primary entry point for integrating real-time Quran recitation tracking
/// and deterministic Tajweed verification into any Flutter application using
/// TajweedFormer V4.
///
/// **Scholarly & Pedagogical Note (تنبيه وأمانة شرعية):**
/// This engine is an assistive tool to aid individual revision and practice.
/// It is never a substitute for direct Talaqqi and Musyafahah (reciting face-to-face
/// to a qualified, certified Sheikh/Muqri' with Ijaza) to verify sound Hifdh,
/// Tajweed precision, and letter articulation points (Makharij).
class QuranTajweedFormer {
  final QuranRepository repository;
  final ReciteEngine _engine;
  final PhonemeAlignmentIsolate _isolate = PhonemeAlignmentIsolate();
  late final AsrTokenProcessor _tokenProcessor;

  TrackerConfig _config;
  bool _isTajweed;
  bool _isInitialized = false;
  bool _isDisposed = false;
  int _targetSurah = 0;

  StreamSubscription? _engineSub;
  StreamSubscription<WordMatchedEvent>? _wordSub;
  StreamSubscription<AyahCompletedEvent>? _ayahSub;

  final StreamController<WordMatchedEvent> _wordEventController =
      StreamController<WordMatchedEvent>.broadcast();
  final StreamController<AyahCompletedEvent> _ayahCompletedController =
      StreamController<AyahCompletedEvent>.broadcast();
  final StreamController<String> _transcriptController =
      StreamController<String>.broadcast();

  // ── Public Streams & State ──

  /// Stream of evaluated word events (correct, tajweedWarning, mispronounced, skipped).
  Stream<WordMatchedEvent> get onWordEvaluated => _wordEventController.stream;

  /// Stream of Ayah completed events emitted immediately upon finishing all words in an Ayah.
  Stream<AyahCompletedEvent> get onAyahCompleted =>
      _ayahCompletedController.stream;

  /// Real-time live speech-to-text phonetic transcript from the ASR model.
  Stream<String> get onTranscript => _transcriptController.stream;

  /// Optional stream of real-time neural Tajweed diagnostics (Qalqalah, Ghunnah, Tafkheem, Shaddah)
  /// emitted directly by TajweedFormer V4's multi-head neural network.
  Stream<TajweedDiagnostics>? get onTajweedDiagnostics =>
      _engine.diagnosticsStream;

  /// Current active configuration.
  TrackerConfig get config => _config;

  /// Current target Surah number.
  int get targetSurah => _targetSurah;

  /// Indicates if Tajweed duration and closure evaluation is enabled.
  bool get isTajweed => _isTajweed;

  /// Whether the engine and background isolate have been initialized.
  bool get isInitialized => _isInitialized;

  /// Whether the instance has been disposed.
  bool get isDisposed => _isDisposed;

  QuranTajweedFormer({
    QuranRepository? repository,
    ReciteEngine? engine,
    TrackerConfig config = const TrackerConfig(),
    bool isTajweed = true,
    String? modelDirOverride,
    String? customLibPath,
  })  : repository = repository ?? QuranRepository(QuranMetadataService()),
        _engine = engine ??
            TajweedFormerEngine(
              modelDirOverride: modelDirOverride,
              customLibPath: customLibPath,
            ),
        _config = config,
        _isTajweed = (repository?.isTajweedSupported ?? true) && isTajweed {
    _tokenProcessor = AsrTokenProcessor(config: _config);
  }

  // ── 1. Initialization ──

  /// Initializes the on-device TajweedFormer ASR engine and background phoneme alignment isolate.
  Future<void> initialize() async {
    if (_isDisposed) {
      throw StateError(
          'Cannot initialize a disposed QuranTajweedFormer instance.');
    }
    if (_isInitialized) return;

    // 0. Ensure Quran reference dataset is loaded
    if (!repository.isLoaded) {
      await repository.service.loadData();
    }

    // 1. Initialize TajweedFormer Engine
    await _engine.initialize();

    // 2. Start Background Alignment Isolate
    await _isolate.start();
    _isolate.updateConfig(_config);
    _isolate.setTajweedMode(_isTajweed);

    // 3. Subscribe to Streams
    _wordSub = _isolate.wordStream.listen(_wordEventController.add);
    _ayahSub =
        _isolate.ayahCompletedStream.listen(_ayahCompletedController.add);
    _engineSub = _engine.transcriptionStream.listen(_onTranscriptionResult);

    _isInitialized = true;
  }

  // ── 2. Surah & Ayah Target Setup ──

  /// Sets the active Surah reference for recitation tracking.
  void setTargetSurah(
    int surahNumber, {
    int startGlobalWord = 0,
    bool forceClear = true,
  }) {
    if (_isDisposed) return;
    _targetSurah = surahNumber;
    final words = repository.getSurahWords(surahNumber);
    if (words.isEmpty) return;

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

  /// Sets tracking target to a specific Ayah within a Surah.
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

  /// Jumps the tracking cursor to a specific word index.
  void jumpToWord(int globalWordIndex) {
    if (_isDisposed) return;
    _isolate.jumpToWord(globalWordIndex);
  }

  // ── 3. Audio & Tracking Control ──

  /// Feeds a normalized float audio chunk [-1.0, 1.0] (16 kHz mono) into the ASR recognizer.
  bool feedAudio(Float32List chunk, {bool isFinal = false}) {
    if (_isDisposed) return false;
    return _engine.transcribe(chunk, isFinal: isFinal);
  }

  /// Feeds a normalized float audio chunk [-1.0, 1.0] (16 kHz mono) into the ASR recognizer.
  bool feedAudioChunk(Float32List chunk, {bool isFinal = false}) =>
      feedAudio(chunk, isFinal: isFinal);

  /// Resets the internal recognition buffer.
  void resetBuffer() {
    if (_isDisposed) return;
    _engine.resetBuffer();
    _tokenProcessor.reset();
  }

  /// Toggles Tajweed evaluation on/off.
  void setTajweedMode(bool active) {
    if (_isDisposed) return;
    final effective = repository.isTajweedSupported && active;
    _isTajweed = effective;
    _isolate.setTajweedMode(effective);
  }

  /// Updates difficulty and math thresholds dynamically at runtime.
  void updateConfig(TrackerConfig newConfig) {
    if (_isDisposed) return;
    _config = newConfig;
    _tokenProcessor.config = newConfig;
    _isolate.updateConfig(newConfig);
  }

  // ── 4. Internal Message Pump ──

  void _onTranscriptionResult(TranscriptionResult result) {
    if (_isDisposed) return;
    if (result.streamEpoch != _engine.currentStreamEpoch) return;

    if (result.text.isNotEmpty) {
      _transcriptController.add(result.text);
    }

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

  List<int> _calculateBoundaries(List<String> phonemeWords) {
    final List<int> boundaries = [0];
    int currentOffset = 0;
    for (final w in phonemeWords) {
      currentOffset += w.length;
      boundaries.add(currentOffset);
    }
    return boundaries;
  }

  // ── 5. Cleanup ──

  void dispose() {
    if (_isDisposed) return;
    _isDisposed = true;
    _isInitialized = false;

    _engineSub?.cancel();
    _engineSub = null;
    _wordSub?.cancel();
    _wordSub = null;
    _ayahSub?.cancel();
    _ayahSub = null;

    _engine.destroy();
    _isolate.stop();

    if (!_wordEventController.isClosed) {
      _wordEventController.close();
    }
    if (!_ayahCompletedController.isClosed) {
      _ayahCompletedController.close();
    }
    if (!_transcriptController.isClosed) {
      _transcriptController.close();
    }
  }
}

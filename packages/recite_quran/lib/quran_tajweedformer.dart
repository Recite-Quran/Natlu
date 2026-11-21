// lib/quran_tajweedformer.dart
import 'dart:async';
import 'dart:typed_data';

import 'engine/core/recite_engine.dart';
import 'engine/core/tajweed_diagnostics.dart';
import 'engine/core/transcription_result.dart';
import 'engine/tajweedformer_v4/tajweedformer_engine.dart';
import 'scoring.dart';

export 'engine.dart';
export 'scoring.dart';
export 'tracking/ayah_search/voice_search_controller.dart';
export 'utils/debug_logger.dart';

// ═══════════════════════════════════════════════════════════════════════════════
// QURAN TAJWEEDFORMER SDK (MAIN PUBLIC FACADE)
// ═══════════════════════════════════════════════════════════════════════════════

/// The primary entry point for integrating real-time Quran recitation tracking
/// and deterministic Tajweed verification into any Flutter application using
/// TajweedFormer V4.
///
/// Composes [QuranRecognizer] / [ReciteEngine] (acoustic ASR inference) with
/// [QuranScorer] (phoneme alignment, DTW, Tajweed rule evaluation).
///
/// **Scholarly & Pedagogical Note (تنبيه وأمانة شرعية):**
/// This engine is an assistive tool to aid individual revision and practice.
/// It is never a substitute for direct Talaqqi and Musyafahah (reciting face-to-face
/// to a qualified, certified Sheikh/Muqri' with Ijaza) to verify sound Hifdh,
/// Tajweed precision, and letter articulation points (Makharij).
class QuranTajweedFormer {
  final QuranRepository repository;
  final ReciteEngine _engine;
  late final QuranScorer _scorer;

  bool _isInitialized = false;
  bool _isDisposed = false;

  StreamSubscription? _engineSub;
  final StreamController<String> _transcriptController =
      StreamController<String>.broadcast();

  // ── Public Streams & State ──

  /// Access to the underlying acoustic speech recognition engine.
  ReciteEngine get engine => _engine;

  /// Access to the underlying recitation scoring and DTW alignment system.
  QuranScorer get scorer => _scorer;

  /// Stream of evaluated word events (correct, tajweedWarning, mispronounced, skipped).
  Stream<WordMatchedEvent> get onWordEvaluated => _scorer.onWordEvaluated;

  /// Stream of Ayah completed events emitted immediately upon finishing all words in an Ayah.
  Stream<AyahCompletedEvent> get onAyahCompleted => _scorer.onAyahCompleted;

  /// Real-time live speech-to-text phonetic transcript from the ASR model.
  Stream<String> get onTranscript => _transcriptController.stream;

  /// Optional stream of real-time neural Tajweed diagnostics (Qalqalah, Ghunnah, Tafkheem, Shaddah)
  /// emitted directly by TajweedFormer V4's multi-head neural network.
  Stream<TajweedDiagnostics>? get onTajweedDiagnostics =>
      _engine.diagnosticsStream;

  /// Current active configuration.
  TrackerConfig get config => _scorer.config;

  /// Current target Surah number.
  int get targetSurah => _scorer.targetSurah;

  /// Indicates if Tajweed duration and closure evaluation is enabled.
  bool get isTajweed => _scorer.isTajweed;

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
            ) {
    _scorer = QuranScorer(
      repository: this.repository,
      config: config,
      isTajweed: isTajweed,
    );
  }

  // ── 1. Initialization ──

  /// Initializes the on-device TajweedFormer ASR engine and background phoneme alignment isolate.
  Future<void> initialize() async {
    if (_isDisposed) {
      throw StateError(
          'Cannot initialize a disposed QuranTajweedFormer instance.');
    }
    if (_isInitialized) return;

    // 1. Initialize TajweedFormer Engine
    await _engine.initialize();

    // 2. Initialize QuranScorer (loads repository data & starts isolate)
    await _scorer.initialize();

    // 3. Subscribe to Engine Stream and pipe to Scorer
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
    _scorer.setTargetSurah(
      surahNumber,
      startGlobalWord: startGlobalWord,
      forceClear: forceClear,
    );
  }

  /// Sets tracking target to a specific Ayah within a Surah.
  void setTargetAyah(int surahNumber, int ayahNumber) {
    if (_isDisposed) return;
    _scorer.setTargetAyah(surahNumber, ayahNumber);
  }

  /// Sets tracking target to a specific word within a Surah and Ayah.
  void setTargetWord({
    required int surah,
    required int ayah,
    required int wordIndex,
  }) {
    if (_isDisposed) return;
    _scorer.setTargetWord(
      surah: surah,
      ayah: ayah,
      wordIndex: wordIndex,
    );
  }

  /// Jumps the tracking cursor to a specific word index.
  void jumpToWord(int globalWordIndex) {
    if (_isDisposed) return;
    _scorer.jumpToWord(globalWordIndex);
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

  /// Resets internal recognition and scoring buffers.
  void resetBuffer() {
    if (_isDisposed) return;
    _engine.resetBuffer();
    _scorer.resetBuffer();
  }

  /// Toggles Tajweed evaluation on/off.
  void setTajweedMode(bool active) {
    if (_isDisposed) return;
    _scorer.setTajweedMode(active);
  }

  /// Updates difficulty and math thresholds dynamically at runtime.
  void updateConfig(TrackerConfig newConfig) {
    if (_isDisposed) return;
    _scorer.updateConfig(newConfig);
  }

  // ── 4. Internal Message Pump ──

  void _onTranscriptionResult(TranscriptionResult result) {
    if (_isDisposed) return;
    if (result.streamEpoch != _engine.currentStreamEpoch) return;

    if (result.text.isNotEmpty) {
      _transcriptController.add(result.text);
    }

    _scorer.feedTranscript(result);
  }

  // ── 5. Cleanup ──

  void dispose() {
    if (_isDisposed) return;
    _isDisposed = true;
    _isInitialized = false;

    _engineSub?.cancel();
    _engineSub = null;

    _engine.destroy();
    _scorer.dispose();

    if (!_transcriptController.isClosed) {
      _transcriptController.close();
    }
  }
}

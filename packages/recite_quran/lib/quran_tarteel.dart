// lib/quran_tarteel.dart
// Real-time Quran Recitation Tracking, Dynamic DTW Alignment & Deterministic Tajweed Matrix
// Powered by TajweedFormer V4 / Quran Lab SDK 4.0

import 'dart:async';
import 'dart:typed_data';

import 'engine/core/recite_engine.dart';
import 'engine/core/tajweed_diagnostics.dart';
import 'engine/core/transcription_result.dart';
import 'engine/quranlab_sdk/quranlab_sdk_engine.dart';
import 'scoring.dart';
import 'tracking/ayah_search/voice_search_controller.dart';

export 'engine.dart';
export 'engine/quranlab_sdk/quranlab_sdk_engine.dart';
export 'scoring.dart';
export 'tracking/ayah_search/voice_search_controller.dart';
export 'utils/debug_logger.dart';

// ═══════════════════════════════════════════════════════════════════════════════
// QURAN TARTEEL SDK (MAIN PUBLIC FACADE)
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
typedef QuranTajweedFormer = QuranTarteel;
typedef ReciteQuran = QuranTarteel;

class QuranTarteel {
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

  /// Stream of Auto-Reanchor events emitted when tracking synchronizes to a new verse.
  Stream<AutoReanchorEvent> get onAutoReanchored => _scorer.onAutoReanchored;

  VoiceSearchController? _voiceSearch;

  /// Access to the voice search ("Recite to Navigate") controller across all 6,236 Ayahs.
  VoiceSearchController get voiceSearch =>
      _voiceSearch ??= VoiceSearchController(
        engine: _engine,
        repository: repository,
      );

  /// Preloads the 6,236-Ayah phonetic search index for instant voice navigation.
  Future<void> preloadVoiceSearch() => voiceSearch.preloadIndex();

  /// Starts voice search mode across all 6,236 Ayahs.
  Future<void> startVoiceSearch() => voiceSearch.startSearch();

  /// Stream of real-time voice search candidate matches.
  Stream<VoiceSearchResult> get onSearchResult => voiceSearch.onSearchResult;

  /// Real-time stream of low-level transcription results (tokens, durations, timings, neural acoustics).
  Stream<TranscriptionResult> get onTranscription =>
      _engine.transcriptionStream;

  /// Real-time live speech-to-text phonetic transcript from the ASR model.
  Stream<String> get onTranscript => _transcriptController.stream;

  /// Optional stream of real-time neural Tajweed diagnostics (Qalqalah, Ghunnah, Tafkheem, Shaddah)
  /// emitted directly by TajweedFormer V4's multi-head neural network.
  Stream<TajweedDiagnostics>? get onTajweedDiagnostics =>
      _engine.diagnosticsStream;

  /// Current active configuration.
  TrackerConfig get config => _scorer.config;

  /// Current active Tajweed rule verification toggles.
  TajweedConfig get tajweedConfig => _scorer.tajweedConfig;

  /// Current target Surah number.
  int get targetSurah => _scorer.targetSurah;

  /// Indicates if Tajweed duration and closure evaluation is enabled.
  bool get isTajweed => _scorer.isTajweed;

  /// Whether the engine and background isolate have been initialized.
  bool get isInitialized => _isInitialized;

  /// Whether the instance has been disposed.
  bool get isDisposed => _isDisposed;

  QuranTarteel({
    required ReciteEngine engine,
    QuranRepository? repository,
    TrackerConfig config = const TrackerConfig(),
    bool isTajweed = true,
  })  : repository = repository ?? QuranRepository(QuranMetadataService()),
        _engine = engine {
    _scorer = QuranScorer(
      repository: this.repository,
      config: config,
      isTajweed: isTajweed,
    );
  }

  /// Official Quran Lab SDK 4.0 constructor (recommended for public releases).
  ///
  /// Connects to sdk.quranlab.ai using your [apiKey] (`qlk_v1_...`), downloads
  /// the encrypted model on first launch, manages offline leases, and streams
  /// neural acoustic chunks into the scoring engine.
  factory QuranTarteel.sdk({
    String? apiKey,
    QuranRepository? repository,
    String contextProfile = 'c16_l64',
    int? endOnSilenceMs,
    TrackerConfig config = const TrackerConfig(),
    bool isTajweed = true,
  }) {
    final String resolvedKey =
        apiKey ?? const String.fromEnvironment('QURANLAB_KEY');
    if (resolvedKey.isEmpty) {
      throw ArgumentError(
        'QuranTarteel: An API key is required to use the Quran Lab SDK. '
        'Pass apiKey: "qlk_v1_..." or compile with --dart-define=QURANLAB_KEY=qlk_v1_... '
        'Obtain your free key at https://sdk.quranlab.ai',
      );
    }

    return QuranTarteel(
      repository: repository,
      engine: QuranLabSdkEngine(
        apiKey: resolvedKey,
        contextProfile: contextProfile,
        endOnSilenceMs: endOnSilenceMs,
      ),
      config: config,
      isTajweed: isTajweed,
    );
  }

  // ── 1. Initialization ──

  /// Initializes the on-device TajweedFormer ASR engine and background phoneme alignment isolate.
  Future<void> initialize() async {
    if (_isDisposed) {
      throw StateError('Cannot initialize a disposed QuranTarteel instance.');
    }
    if (_isInitialized) return;

    await _engine.initialize();
    await _scorer.initialize();

    _engineSub = _engine.transcriptionStream.listen(_onTranscriptionResult);
    _isInitialized = true;
  }

  // ── 2. Surah & Ayah Target Setup ──

  /// Unified target setter for recitation tracking.
  void setTarget({
    required int surah,
    int? ayah,
    int? wordIndex,
    bool forceClear = true,
  }) {
    if (_isDisposed) return;
    _scorer.setTarget(
      surah: surah,
      ayah: ayah,
      wordIndex: wordIndex,
      forceClear: forceClear,
    );
  }

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

  /// Updates active tracker configuration.
  void updateConfig(TrackerConfig newConfig) {
    if (_isDisposed) return;
    _scorer.updateConfig(newConfig);
  }

  /// Updates active Tajweed rule checks.
  void updateTajweedConfig(TajweedConfig newTajweedConfig) {
    if (_isDisposed) return;
    _scorer.updateTajweedConfig(newTajweedConfig);
  }

  // ── 4. Internal Handlers ──

  void _onTranscriptionResult(TranscriptionResult result) {
    if (_isDisposed) return;

    if (!result.isFinal && result.streamEpoch != _engine.currentStreamEpoch) {
      return;
    }

    if (result.text.isNotEmpty) {
      _transcriptController.add(result.text);
    }

    _scorer.feedTranscript(result);
  }

  // ── 5. Lifecycle ──

  /// Disposes background isolates, audio listeners, and controllers.
  void dispose() {
    if (_isDisposed) return;
    _isDisposed = true;

    _engineSub?.cancel();
    _engineSub = null;

    _voiceSearch?.dispose();
    _voiceSearch = null;

    if (!_transcriptController.isClosed) {
      _transcriptController.close();
    }

    _scorer.dispose();
    _engine.destroy();
  }
}

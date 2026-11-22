// lib/engine.dart
// ═══════════════════════════════════════════════════════════════════════════════
// QURAN SPEECH RECOGNITION ENGINE (SHERPA-ONNX STYLE ASR LAYER)
// ═══════════════════════════════════════════════════════════════════════════════
// Pure acoustic streaming ASR interface. Takes raw 16 kHz Float32 PCM audio,
// executes on-device neural network inference (via FFI on native and WebAssembly
// on Web), and emits real-time phonetic transcriptions and acoustic diagnostics.
// Has zero dependency on Quranic verse scoring or DTW alignment.
// ═══════════════════════════════════════════════════════════════════════════════

import 'dart:async';
import 'dart:typed_data';

import 'audio/audio_processor.dart';
import 'engine/core/recite_engine.dart';
import 'engine/core/tajweed_diagnostics.dart';
import 'engine/core/transcription_result.dart';
import 'engine/quranlab_sdk/quranlab_sdk_engine.dart';

export 'audio/audio_processor.dart';
export 'engine/core/recite_engine.dart';
export 'engine/core/tajweed_diagnostics.dart';
export 'engine/core/transcription_result.dart';
export 'engine/quranlab_sdk/quranlab_sdk_engine.dart';

/// A high-level, streaming Quran speech recognizer modelled after modern ASR
/// interfaces (such as sherpa-onnx).
///
/// Feeds raw PCM audio chunks into the on-device neural ASR engine and emits
/// real-time phonetic transcriptions.
class QuranRecognizer {
  final ReciteEngine _engine;
  AudioProcessor? _audioProcessor;

  QuranRecognizer({
    ReciteEngine? engine,
    String? apiKey,
    String contextProfile = 'c16_l64',
  }) : _engine = engine ??
            QuranLabSdkEngine(
              apiKey: apiKey ?? const String.fromEnvironment('QURANLAB_KEY'),
              contextProfile: contextProfile,
            );

  /// Access to the underlying low-level [ReciteEngine].
  ReciteEngine get engine => _engine;

  /// Optional audio processor for microphone capture. Lazily instantiated.
  AudioProcessor get audioProcessor => _audioProcessor ??= AudioProcessor();

  /// Whether the neural engine has finished loading weights into memory.
  bool get isInitialized => _engine.isInitialized;

  /// Current audio stream epoch identifier.
  int get currentStreamEpoch => _engine.currentStreamEpoch;

  /// Real-time stream of transcription results.
  Stream<TranscriptionResult> get transcriptionStream =>
      _engine.transcriptionStream;

  /// Optional stream of real-time multi-head neural Tajweed diagnostics.
  Stream<TajweedDiagnostics>? get diagnosticsStream =>
      _engine.diagnosticsStream;

  /// Initializes the on-device neural engine (FFI on native, WebAssembly on Web).
  Future<void> initialize() => _engine.initialize();

  /// Feeds a normalized float chunk [-1.0, 1.0] (16 kHz mono) into the recognizer.
  /// Follows the standard Sherpa-ONNX streaming naming convention.
  bool acceptWaveform(Float32List samples, {bool isFinal = false}) =>
      _engine.transcribe(samples, isFinal: isFinal);

  /// Alias for [acceptWaveform] matching the ReciteEngine protocol.
  bool transcribe(Float32List samples, {bool isFinal = false}) =>
      acceptWaveform(samples, isFinal: isFinal);

  /// Resets the internal recognition buffer and primes with silence.
  void reset() => _engine.resetBuffer();

  /// Starts live microphone capture at 16 kHz mono and streams chunks to [onChunk].
  /// When [autoFeed] is true, chunks are automatically fed into [acceptWaveform].
  Future<void> startMicrophoneCapture({
    bool autoFeed = true,
    void Function(Float32List chunk, bool isFinal)? onChunk,
  }) async {
    await audioProcessor.start(
      onChunk: (chunk, isFinal) {
        if (autoFeed) {
          acceptWaveform(chunk, isFinal: isFinal);
        }
        onChunk?.call(chunk, isFinal);
      },
    );
  }

  /// Stops microphone capture.
  Future<void> stopMicrophoneCapture() =>
      _audioProcessor?.stop() ?? Future.value();

  /// Destroys the recognizer and frees native FFI / WASM resources.
  void destroy() {
    _audioProcessor?.stop();
    _engine.destroy();
  }
}

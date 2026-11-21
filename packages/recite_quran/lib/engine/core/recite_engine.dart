// lib/engine/core/recite_engine.dart

import 'dart:typed_data';
import 'tajweed_diagnostics.dart';
import 'transcription_result.dart';

/// Abstract contract implemented by Quran recitation engines (TajweedFormer, etc.).
abstract class ReciteEngine {
  /// Whether the engine has finished loading model assets into memory.
  bool get isInitialized;

  /// Current stream epoch to identify audio segment lifecycles.
  int get currentStreamEpoch;

  /// Stream of real-time speech transcription results.
  Stream<TranscriptionResult> get transcriptionStream;

  /// Optional stream of real-time neural Tajweed diagnostics (available on TajweedFormer v4).
  Stream<TajweedDiagnostics>? get diagnosticsStream => null;

  /// Initializes native libraries, loads neural weights, and prepares the audio stream.
  Future<void> initialize();

  /// Feeds a normalized float chunk [-1.0, 1.0] (16 kHz mono) into the recognizer.
  bool transcribe(Float32List audioChunk, {bool isFinal = false});

  /// Hard reset: wipes the streaming buffer and primes with silence.
  void resetBuffer();

  /// Flushes current stream and resets across an Ayah boundary.
  void flushThenReset();

  /// Checks whether model assets are cached locally.
  Future<bool> isModelCached() async => true;

  /// Destroys the recognizer and releases native memory resources.
  void destroy();
}

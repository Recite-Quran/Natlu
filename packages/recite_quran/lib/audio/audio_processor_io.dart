// lib/audio/audio_processor_io.dart
// لا اله الا الله

import 'dart:async';
import 'dart:typed_data';
import 'package:record/record.dart';

class AudioProcessor {
  // ── Audio format constants ─────────────────────────────────────────────────
  /// The sample rate that the ASR model and VAD expect.

  static const int recordSampleRate = 16000;
  static const int numChannels = 1;
  static const int bytesPerSample = 2; // 16-bit PCM

  int? _carryByte;

  // ── Continuous Streaming ──────────────────────────────────────────────────
  // We stream audio directly to the neural ASR engine as hardware packets arrive.
  // This matches the official author pumpPcm16 architecture, eliminating the
  // 320ms artificial delay and avoiding truncation of end-of-ayah syllables.

  AudioRecorder? _recorder;
  StreamSubscription<Uint8List>? _subscription;

  Future<bool> hasPermission() async {
    final recorder = AudioRecorder();
    try {
      return await recorder.hasPermission();
    } finally {
      await recorder.dispose();
    }
  }

  Future<void> start({
    required void Function(Float32List chunk, bool isFinal) onChunk,
  }) async {
    await stop();

    _recorder = AudioRecorder();
    _carryByte = null;

    final recordStream = await _recorder!.startStream(
      // Keep natural microphone preamp sensitivity while explicitly disabling
      // aggressive software noise-gating that erases breathy "ه" or subtle Tajweed.
      const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: recordSampleRate, // 16000
        numChannels: numChannels,
        autoGain: false,
        echoCancel: false,
        noiseSuppress: false,
      ),
    );

    _subscription = recordStream.listen((Uint8List rawData) {
      if (rawData.isEmpty) return;

      // Handle odd-byte carry across chunk boundaries (exact parity with official pumpPcm16)
      final Uint8List bytes;
      if (_carryByte != null) {
        bytes = Uint8List(rawData.length + 1)
          ..[0] = _carryByte!
          ..setRange(1, rawData.length + 1, rawData);
        _carryByte = null;
      } else {
        bytes = rawData;
      }

      final int evenBytes = bytes.length & ~1;
      if (bytes.length.isOdd) {
        _carryByte = bytes[bytes.length - 1];
      }
      if (evenBytes == 0) return;

      final byteData = ByteData.sublistView(bytes, 0, evenBytes);
      final int sampleCount = evenBytes ~/ bytesPerSample;
      final float32Samples = Float32List(sampleCount);

      // ── Direct Linear Conversion ──
      // int16 / 32768.0 matches the official TajweedFormer training & C engine pipeline
      for (int i = 0; i < sampleCount; i++) {
        float32Samples[i] = byteData.getInt16(i * 2, Endian.little) / 32768.0;
      }

      // Stream immediately to the neural ASR engine without artificial batch delay!
      onChunk(float32Samples, false);
    });
  }

  void clearBuffer() {
    _carryByte = null;
  }

  Future<void> stop() async {
    await _subscription?.cancel();
    _subscription = null;

    try {
      if (_recorder != null && await _recorder!.isRecording()) {
        await _recorder!.stop();
      }
    } catch (_) {}

    await _recorder?.dispose();
    _recorder = null;

    _carryByte = null;
  }
}

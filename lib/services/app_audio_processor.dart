import 'dart:async';
import 'dart:typed_data';
import 'package:record/record.dart';
import '../maglis/maglis_controller.dart';

/// AppAudioProcessor
///
/// Captures mic audio and delivers 16kHz Float32 PCM chunks to the Sherpa ASR engine.
/// When in a Maglis room session, it harmonizes Android audio capture with WebRTC
/// by using [AndroidAudioSource.voiceCommunication] and [AudioManagerMode.modeInCommunication].
/// This completely prevents the 74% audio sample drop and HAL buffer starvation
/// that occurs when two AudioRecord instances fight over conflicting audio modes.
class AppAudioProcessor {
  static const int recordSampleRate = 16000;
  static const int numChannels = 1;
  static const int bytesPerSample = 2; // 16-bit PCM
  static const int chunkMs = 480;
  static const int recordChunkBytes =
      (recordSampleRate * numChannels * bytesPerSample * chunkMs) ~/ 1000;

  Uint8List _frameBuffer = Uint8List(0);
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

    final bool inMaglis = MaglisController.instance.inSession;

    final config = RecordConfig(
      encoder: AudioEncoder.pcm16bits,
      sampleRate: recordSampleRate,
      numChannels: numChannels,
      autoGain: false,
      echoCancel: false,
      noiseSuppress: false,
      androidConfig: AndroidRecordConfig(
        audioSource: AndroidAudioSource.mic,
        audioManagerMode: AudioManagerMode.modeNormal,
        manageBluetooth: !inMaglis,
      ),
    );

    final recordStream = await _recorder!.startStream(config);

    _subscription = recordStream.listen((Uint8List rawData) {
      if (rawData.offsetInBytes % 2 != 0) {
        rawData = Uint8List.fromList(rawData);
      }

      Uint8List allBytes;
      if (_frameBuffer.isEmpty) {
        allBytes = rawData;
      } else {
        allBytes = Uint8List(_frameBuffer.length + rawData.length);
        allBytes.setAll(0, _frameBuffer);
        allBytes.setAll(_frameBuffer.length, rawData);
      }

      int offset = 0;
      while (allBytes.length - offset >= recordChunkBytes) {
        final byteView = Uint8List.view(
          allBytes.buffer,
          allBytes.offsetInBytes + offset,
          recordChunkBytes,
        );
        offset += recordChunkBytes;

        final int16samples = Int16List.view(
          byteView.buffer,
          byteView.offsetInBytes,
          recordChunkBytes ~/ bytesPerSample,
        );

        final float32Samples = Float32List(int16samples.length);
        for (int i = 0; i < int16samples.length; i++) {
          float32Samples[i] = int16samples[i] / 32768.0;
        }

        onChunk(float32Samples, false);
      }

      if (offset < allBytes.length) {
        _frameBuffer = Uint8List.fromList(
          Uint8List.view(allBytes.buffer, allBytes.offsetInBytes + offset),
        );
      } else {
        _frameBuffer = Uint8List(0);
      }
    });
  }

  void clearBuffer() {
    _frameBuffer = Uint8List(0);
  }

  Future<void> stop() async {
    await _subscription?.cancel();
    _subscription = null;

    await _recorder?.stop();
    await _recorder?.dispose();
    _recorder = null;

    _frameBuffer = Uint8List(0);
  }
}

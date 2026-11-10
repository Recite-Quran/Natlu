import 'dart:async';
import 'dart:typed_data';
import 'package:record/record.dart';
import '../maglis/maglis_controller.dart';
import '../maglis/maglis_core.dart';

/// AppAudioProcessor
///
/// Captures mic audio and delivers 16kHz Float32 PCM chunks to the Sherpa ASR engine.
/// When in a Maglis room session, it harmonizes Android audio capture with WebRTC
/// by using [AudioManagerMode.modeInCommunication] while preserving [AndroidAudioSource.mic]
/// and disabling hardware AEC ([echoCancel: false]).
/// This completely prevents the 74% audio sample drop and HAL buffer starvation
/// while avoiding aggressive hardware AEC ducking and distorted Arabic phonemes.
class AppAudioProcessor {
  static const int recordSampleRate = 16000;
  static const int numChannels = 1;
  static const int bytesPerSample = 2; // 16-bit PCM
  static const int chunkMs = 480;
  static const int recordChunkBytes =
      (recordSampleRate * numChannels * bytesPerSample * chunkMs) ~/ 1000;
  static const int _samplesPerChunk = recordChunkBytes ~/ bytesPerSample;
  static const double _inv32768 = 1.0 / 32768.0;
  static const int _bufferCapacity = recordChunkBytes * 4;

  Uint8List _fixedBuffer = Uint8List(_bufferCapacity);
  int _bufferedBytes = 0;
  final AudioRecorder _recorder = AudioRecorder();
  StreamSubscription<Uint8List>? _subscription;
  bool _isRecording = false;
  Future<void>? _activeOp;

  Future<bool> hasPermission() async {
    try {
      return await _recorder.hasPermission();
    } catch (_) {
      return false;
    }
  }

  Future<void> start({
    required void Function(Float32List chunk, bool isFinal) onChunk,
  }) async {
    while (_activeOp != null) {
      await _activeOp;
    }
    final completer = Completer<void>();
    _activeOp = completer.future;

    try {
      await _stopInternal();

      final bool inMaglis = MaglisController.instance.inSession;

      final config = RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: recordSampleRate,
        numChannels: numChannels,
        autoGain: false,
        echoCancel: false,
        noiseSuppress: false,
        audioInterruption: inMaglis
            ? AudioInterruptionMode.none
            : AudioInterruptionMode.pause,
        androidConfig: AndroidRecordConfig(
          audioSource: AndroidAudioSource.mic,
          audioManagerMode: inMaglis
              ? AudioManagerMode.modeInCommunication
              : AudioManagerMode.modeNormal,
          manageBluetooth: !inMaglis,
        ),
        iosConfig: const IosRecordConfig(
          categoryOptions: [
            IosAudioCategoryOption.defaultToSpeaker,
            IosAudioCategoryOption.allowBluetooth,
            IosAudioCategoryOption.allowBluetoothA2DP,
            IosAudioCategoryOption.allowAirPlay,
          ],
        ),
      );

      final recordStream = await _recorder.startStream(config);
      _isRecording = true;

      _subscription = recordStream.listen(
        (Uint8List rawData) {
          final int validBytes = rawData.length - (rawData.length % 2);
          if (validBytes == 0) return;

          // Zero-allocation ring buffer ingestion
          if (_bufferedBytes + validBytes > _fixedBuffer.length) {
            final newCap = (_bufferedBytes + validBytes) * 2;
            final newBuf = Uint8List(newCap);
            newBuf.setRange(0, _bufferedBytes, _fixedBuffer);
            _fixedBuffer = newBuf;
          }
          _fixedBuffer.setRange(
            _bufferedBytes,
            _bufferedBytes + validBytes,
            rawData,
            0,
          );
          _bufferedBytes += validBytes;

          int offset = 0;
          while (_bufferedBytes - offset >= recordChunkBytes) {
            final byteView = Uint8List.view(
              _fixedBuffer.buffer,
              _fixedBuffer.offsetInBytes + offset,
              recordChunkBytes,
            );
            offset += recordChunkBytes;

            final int16samples = Int16List.view(
              byteView.buffer,
              byteView.offsetInBytes,
              _samplesPerChunk,
            );

            final float32Samples = Float32List(_samplesPerChunk);
            for (int i = 0; i < _samplesPerChunk; i++) {
              float32Samples[i] = int16samples[i] * _inv32768;
            }

            onChunk(float32Samples, false);
          }

          if (offset > 0) {
            final remaining = _bufferedBytes - offset;
            if (remaining > 0) {
              _fixedBuffer.setRange(0, remaining, _fixedBuffer, offset);
            }
            _bufferedBytes = remaining;
          }
        },
        onError: (err) {
          _isRecording = false;
        },
        onDone: () {
          _isRecording = false;
        },
        cancelOnError: true,
      );
    } finally {
      completer.complete();
      _activeOp = null;
    }
  }

  void clearBuffer() {
    _bufferedBytes = 0;
  }

  Future<void> stop() async {
    while (_activeOp != null) {
      await _activeOp;
    }
    final completer = Completer<void>();
    _activeOp = completer.future;

    try {
      await _stopInternal();
    } finally {
      completer.complete();
      _activeOp = null;
    }
  }

  Future<void> _stopInternal() async {
    await _subscription?.cancel();
    _subscription = null;

    if (_isRecording) {
      _isRecording = false;
      try {
        await _recorder.stop();
      } catch (_) {}
    } else {
      try {
        if (await _recorder.isRecording()) {
          await _recorder.stop();
        }
      } catch (_) {}
    }

    _bufferedBytes = 0;

    // If still in Maglis room session, preserve WebRTC voice communication mode & loud speakerphone
    if (MaglisController.instance.inSession) {
      MaglisPlatform.setSpeaker(true);
    }
  }

  Future<void> dispose() async {
    await stop();
    try {
      await _recorder.dispose();
    } catch (_) {}
  }
}

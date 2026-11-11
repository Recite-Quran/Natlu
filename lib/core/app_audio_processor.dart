import 'dart:async';
import 'dart:typed_data';
import 'package:record/record.dart';
import 'package:recite_quran/recite_quran.dart' as rq;
import '../maglis/maglis_controller.dart';
import '../maglis/maglis_core.dart';

/// AppAudioProcessor
///
/// Delivers 16kHz Float32 PCM chunks to the Sherpa ASR engine.
/// - In Solo Recording Mode: Directly delegates to [rq.AudioProcessor] from the
///   recite_quran package with zero modifications, raw unadulterated audio, and no telephony profiles.
/// - In Maglis Mode: Harmonizes with active WebRTC room using [AndroidAudioSource.mic] and [AudioManagerMode.modeInCommunication]
///   without hardware AEC ([echoCancel: false]) to prevent buffer starvation while avoiding ducking.
class AppAudioProcessor {
  static const int recordSampleRate = 16000;
  static const int numChannels = 1;
  static const int bytesPerSample = 2; // 16-bit PCM
  static const int chunkMs = 480;
  static const int recordChunkBytes =
      (recordSampleRate * numChannels * bytesPerSample * chunkMs) ~/ 1000;

  final rq.AudioProcessor _soloAudio = rq.AudioProcessor();

  // Maglis-specific recorder state
  AudioRecorder? _maglisRecorder;
  StreamSubscription<Uint8List>? _maglisSubscription;
  Uint8List _maglisBuffer = Uint8List(0);
  bool _isMaglisRecording = false;
  Future<void>? _activeOp;

  Future<bool> hasPermission() async {
    return _soloAudio.hasPermission();
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

      if (!inMaglis) {
        // Pure recite_quran package audio processor in Solo Mode!
        await _soloAudio.start(onChunk: onChunk);
        return;
      }

      // Harmonized WebRTC config in Maglis mode:
      const config = RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: recordSampleRate,
        numChannels: numChannels,
        autoGain: false,
        echoCancel: false,
        noiseSuppress: false,
        audioInterruption: AudioInterruptionMode.none,
        androidConfig: AndroidRecordConfig(
          audioSource: AndroidAudioSource.mic,
          audioManagerMode: AudioManagerMode.modeInCommunication,
          manageBluetooth: false,
        ),
        iosConfig: IosRecordConfig(
          categoryOptions: [
            IosAudioCategoryOption.defaultToSpeaker,
            IosAudioCategoryOption.allowBluetooth,
            IosAudioCategoryOption.allowBluetoothA2DP,
            IosAudioCategoryOption.allowAirPlay,
          ],
        ),
      );

      _maglisRecorder = AudioRecorder();
      final recordStream = await _maglisRecorder!.startStream(config);
      _isMaglisRecording = true;

      _maglisSubscription = recordStream.listen(
        (Uint8List rawData) {
          if (rawData.offsetInBytes % 2 != 0) {
            rawData = Uint8List.fromList(rawData);
          }

          Uint8List allBytes;
          if (_maglisBuffer.isEmpty) {
            allBytes = rawData;
          } else {
            allBytes = Uint8List(_maglisBuffer.length + rawData.length);
            allBytes.setAll(0, _maglisBuffer);
            allBytes.setAll(_maglisBuffer.length, rawData);
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
            _maglisBuffer = Uint8List.fromList(
              Uint8List.view(allBytes.buffer, allBytes.offsetInBytes + offset),
            );
          } else {
            _maglisBuffer = Uint8List(0);
          }
        },
        onError: (err) {
          _isMaglisRecording = false;
        },
        onDone: () {
          _isMaglisRecording = false;
        },
        cancelOnError: true,
      );
    } finally {
      completer.complete();
      _activeOp = null;
    }
  }

  void clearBuffer() {
    _soloAudio.clearBuffer();
    _maglisBuffer = Uint8List(0);
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
    // 1. Stop solo audio processor
    try {
      await _soloAudio.stop();
    } catch (_) {}

    // 2. Stop Maglis recorder if active
    await _maglisSubscription?.cancel();
    _maglisSubscription = null;

    if (_isMaglisRecording) {
      _isMaglisRecording = false;
      try {
        await _maglisRecorder?.stop();
      } catch (_) {}
    } else {
      try {
        if (_maglisRecorder != null && await _maglisRecorder!.isRecording()) {
          await _maglisRecorder!.stop();
        }
      } catch (_) {}
    }

    try {
      await _maglisRecorder?.dispose();
    } catch (_) {}
    _maglisRecorder = null;
    _maglisBuffer = Uint8List(0);

    // If still in Maglis room session, preserve WebRTC voice communication mode & loud speakerphone
    if (MaglisController.instance.inSession) {
      MaglisPlatform.setSpeaker(true);
      unawaited(MaglisPlatform.startBackgroundCallService());
    }
  }

  Future<void> dispose() async {
    await stop();
  }
}

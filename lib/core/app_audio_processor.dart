import 'dart:async';
import 'dart:typed_data';
import 'package:record/record.dart';
import 'package:quran_tarteel/quran_tarteel.dart' as rq;
import '../maglis/maglis_controller.dart';
import '../maglis/maglis_core.dart';

/// AppAudioProcessor
///
/// Delivers 16kHz Float32 PCM chunks to the TajweedFormer V4 ASR engine.
/// - In Solo Recording Mode: Directly delegates to [rq.AudioProcessor] from the
///   quran_tajweedformer package with zero modifications, raw unadulterated audio, and no telephony profiles.
/// - In Maglis Mode: Harmonizes with active WebRTC room using [AndroidAudioSource.mic] and [AudioManagerMode.modeInCommunication]
///   without hardware AEC ([echoCancel: false]) to prevent buffer starvation while avoiding ducking.
class AppAudioProcessor {
  static const int recordSampleRate = 16000;
  static const int numChannels = 1;
  static const int bytesPerSample = 2; // 16-bit PCM
  static const int chunkMs =
      320; // 320ms matches TajweedFormer c16_l64 context native chunk size (5120 samples @ 16kHz)
  static const int recordChunkBytes =
      (recordSampleRate * numChannels * bytesPerSample * chunkMs) ~/ 1000;

  static const RecordConfig _maglisRecordConfig = RecordConfig(
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

  final rq.AudioProcessor _audio = rq.AudioProcessor();
  Future<void>? _activeOp;

  Future<bool> hasPermission() async {
    return _audio.hasPermission();
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
      await _audio.start(
        onChunk: onChunk,
        config: inMaglis ? _maglisRecordConfig : null,
      );
    } finally {
      completer.complete();
      _activeOp = null;
    }
  }

  void clearBuffer() {
    _audio.clearBuffer();
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
    try {
      await _audio.stop();
    } catch (_) {}

    // If still in active Maglis session (and not tearing down), preserve WebRTC call speakerphone
    if (MaglisController.instance.inSession &&
        !MaglisController.instance.isLeaving) {
      MaglisPlatform.setSpeaker(true);
      unawaited(MaglisPlatform.startBackgroundCallService());
    }
  }

  Future<void> dispose() async {
    await stop();
  }
}

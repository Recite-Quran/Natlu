import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:record/record.dart';
import 'package:recite_quran/recite_quran.dart' as rq;
import '../maglis/maglis_controller.dart';
import '../maglis/maglis_core.dart';

/// AppAudioProcessor
///
/// Delivers 16kHz Float32 PCM chunks to the Sherpa ASR engine across all modes:
/// - Solo Mode: Directly delegates to [rq.AudioProcessor] from `recite_quran`.
/// - Maglis Mode (Android): Reads Channel-0 16kHz PCM from a single shared
///   native WebRTC capture tap (`com.recitequran.app/maglis_audio_tap`), avoiding
///   dual AudioRecord contention without altering Maglis call audio.
/// - Maglis Mode (Other platforms fallback): Uses [AudioRecorder].
class AppAudioProcessor {
  static const int recordSampleRate = 16000;
  static const int numChannels = 1;
  static const int bytesPerSample = 2; // 16-bit PCM
  static const int chunkMs = 480;
  static const int recordChunkBytes =
      (recordSampleRate * numChannels * bytesPerSample * chunkMs) ~/ 1000;

  static const MethodChannel _tapMethodChannel =
      MethodChannel('com.recitequran.app/maglis_audio_tap');
  static const EventChannel _tapStreamChannel =
      EventChannel('com.recitequran.app/maglis_audio_tap_stream');

  final rq.AudioProcessor _soloAudio = rq.AudioProcessor();

  // Maglis-specific recorder / tap state
  AudioRecorder? _maglisRecorder;
  StreamSubscription<dynamic>? _maglisSubscription;
  Uint8List _maglisBuffer = Uint8List(0);
  bool _isMaglisRecording = false;
  bool _isMaglisTapActive = false;
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
        // Pure recite_quran package audio processor in Solo Mode
        await _soloAudio.start(onChunk: onChunk);
        return;
      }

      final bool useAndroidTap =
          !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

      if (useAndroidTap) {
        final tapStarted = await _startAndroidWebRtcTap(onChunk: onChunk);
        if (tapStarted) {
          return;
        }
      }

      await _startFallbackMaglisRecorder(onChunk: onChunk);
    } finally {
      completer.complete();
      _activeOp = null;
    }
  }

  Future<bool> _startAndroidWebRtcTap({
    required void Function(Float32List chunk, bool isFinal) onChunk,
  }) async {
    final trackId = MaglisController.instance.localAudioTrackId;
    if (trackId == null || trackId.isEmpty) {
      return false;
    }

    try {
      _maglisSubscription = _tapStreamChannel.receiveBroadcastStream().listen(
        (dynamic event) {
          if (event is Uint8List) {
            _emitPcmBytes(event, onChunk);
          }
        },
        onError: (_) {
          _isMaglisTapActive = false;
        },
        onDone: () {
          _isMaglisTapActive = false;
        },
        cancelOnError: true,
      );

      await _tapMethodChannel.invokeMethod<bool>(
        'startTap',
        {'trackId': trackId},
      );
      _isMaglisTapActive = true;
      return true;
    } catch (_) {
      await _maglisSubscription?.cancel();
      _maglisSubscription = null;
      _isMaglisTapActive = false;
      return false;
    }
  }

  Future<void> _startFallbackMaglisRecorder({
    required void Function(Float32List chunk, bool isFinal) onChunk,
  }) async {
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
      (Uint8List rawData) => _emitPcmBytes(rawData, onChunk),
      onError: (_) {
        _isMaglisRecording = false;
      },
      onDone: () {
        _isMaglisRecording = false;
      },
      cancelOnError: true,
    );
  }

  void _emitPcmBytes(
    Uint8List rawData,
    void Function(Float32List chunk, bool isFinal) onChunk,
  ) {
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

    // 2. Detach stream subscription (shared by mobile WebRTC tap & desktop/web recorder)
    await _maglisSubscription?.cancel();
    _maglisSubscription = null;

    // 3. Stop Android WebRTC tap if active
    if (_isMaglisTapActive) {
      _isMaglisTapActive = false;
      try {
        await _tapMethodChannel.invokeMethod('stopTap');
      } catch (_) {}
    }

    // 4. Stop desktop/web fallback Maglis recorder if active
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

    // If still in an active Maglis session (and not tearing down), preserve call speakerphone
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

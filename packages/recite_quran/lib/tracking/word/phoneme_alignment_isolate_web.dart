// lib/tracking/word/phoneme_alignment_isolate_web.dart
import 'dart:async';

import '../../engine/core/transcription_result.dart';

import '../../data/quran_data.dart';
import '../../utils/debug_logger.dart';
import 'dictation_sequencer.dart';
import 'phoneme_alignment_isolate_protocol.dart';

export 'phoneme_alignment_isolate_protocol.dart';

// ═══════════════════════════════════════════════════════════════════════════════
// UI-SIDE WORKER MANAGER (Web Async Pipeline)
// ═══════════════════════════════════════════════════════════════════════════════

/// Web asynchronous message loop manager for alignment without dart:isolate.
class PhonemeAlignmentIsolate {
  StreamController<Map<String, dynamic>>? _commandPort;
  StreamController<Map<String, dynamic>>? _receivePort;

  final StreamController<WordMatchedEvent> _wordStreamController =
      StreamController<WordMatchedEvent>.broadcast();
  final StreamController<AyahCompletedEvent> _ayahCompletedStreamController =
      StreamController<AyahCompletedEvent>.broadcast();

  Stream<WordMatchedEvent> get wordStream => _wordStreamController.stream;
  Stream<AyahCompletedEvent> get ayahCompletedStream =>
      _ayahCompletedStreamController.stream;

  Future<void> start() async {
    _commandPort = StreamController<Map<String, dynamic>>();
    _receivePort = StreamController<Map<String, dynamic>>();

    final sequencer = DictationSequencer((eventMap) {
      _receivePort?.add(eventMap);
    });

    _commandPort!.stream.listen((rawMessage) {
      final IsolateCommand command;
      try {
        command = IsolateCommand.fromMap(rawMessage);
      } catch (_) {
        return;
      }

      try {
        switch (command) {
          case SetSurahReferenceCommand():
            sequencer.setSurahReference(command);

          case SyncStreamCommand():
            sequencer.syncStream(command);

          case JumpToWordCommand():
            sequencer.jumpToWord(command);

          case SetTajweedModeCommand(:final isTajweed):
            sequencer.isTajweed = isTajweed;

          case UpdateTrackerConfigCommand(:final config):
            sequencer.updateConfig(config);

          case StopIsolateCommand():
            break;
        }
      } catch (e, stack) {
        _receivePort?.add(
          DebugLogEvent(
            message: '⚠️ [WEB WORKER ERROR] Handled exception: $e\n$stack',
            asrBuffer: sequencer.currentSegmentAsrText,
          ).toMap(),
        );
      }
    });

    _receivePort!.stream.listen((message) {
      try {
        final event = IsolateEvent.fromMap(message);
        switch (event) {
          case WordMatchedEvent():
            _wordStreamController.add(event);
          case AyahCompletedEvent():
            _ayahCompletedStreamController.add(event);
          case DebugLogEvent(:final message, :final asrBuffer):
            DebugLogger.updateAsrBuffer(asrBuffer);
            DebugLogger.log('DP', message);
        }
      } catch (_) {
        // Ignore malformed event
      }
    });
  }

  void send(IsolateCommand command) {
    _commandPort?.add(command.toMap());
  }

  void setSurahReference(
    String expectedPhonemes,
    List<int> wordBoundaries, {
    bool isTajweed = false,
    bool forceClear = false,
    int startGlobalWord = 0,
    int surahNumber = 0,
    List<int> ayahs = const [],
    List<int> wordsInAyah = const [],
    List<List<WordTajweedRule>>? wordRules,
    List<int>? charRuleClasses,
  }) {
    send(
      SetSurahReferenceCommand(
        fullPhonemes: expectedPhonemes,
        boundaries: wordBoundaries,
        surahNumber: surahNumber,
        ayahs: ayahs,
        wordsInAyah: wordsInAyah,
        isTajweed: isTajweed,
        forceClear: forceClear,
        startGlobalWord: startGlobalWord,
        wordRules: wordRules,
        charRuleClasses: charRuleClasses,
      ),
    );
  }

  void jumpToWord(int globalWordIndex) {
    send(JumpToWordCommand(globalWordIndex: globalWordIndex));
  }

  void syncStream(
    String segmentText,
    List<double>? segmentTimestamps, [
    bool isNewSegment = false,
    int? ayahNumber,
    List<TokenNeuralAcoustics>? neuralAcoustics,
  ]) {
    send(
      SyncStreamCommand(
        asrText: segmentText,
        timestamps: segmentTimestamps ?? const [],
        isNewSegment: isNewSegment,
        ayahNumber: ayahNumber ?? 0,
        neuralAcoustics: neuralAcoustics ?? const [],
      ),
    );
  }

  void setTajweedMode(bool isTajweed) {
    send(SetTajweedModeCommand(isTajweed: isTajweed));
  }

  void updateConfig(TrackerConfig config) {
    send(UpdateTrackerConfigCommand(config: config));
  }

  void stop() {
    send(const StopIsolateCommand());
    _wordStreamController.close();
    _ayahCompletedStreamController.close();
    _commandPort?.close();
    _receivePort?.close();
    _commandPort = null;
    _receivePort = null;
  }
}

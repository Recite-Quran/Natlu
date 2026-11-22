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
  StreamController<IsolateCommand>? _commandPort;
  final List<IsolateCommand> _pendingCommands = [];

  final StreamController<WordMatchedEvent> _wordStreamController =
      StreamController<WordMatchedEvent>.broadcast();
  final StreamController<AutoReanchorEvent> _autoReanchorStreamController =
      StreamController<AutoReanchorEvent>.broadcast();

  Stream<WordMatchedEvent> get wordStream => _wordStreamController.stream;
  Stream<AutoReanchorEvent> get autoReanchorStream =>
      _autoReanchorStreamController.stream;

  Future<void> start() async {
    _commandPort = StreamController<IsolateCommand>();

    final sequencer = DictationSequencer(_routeEvent);

    _commandPort!.stream.listen((command) {
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

          case UpdateTajweedConfigCommand(:final tajweed):
            sequencer.updateTajweedConfig(tajweed);

          case StopIsolateCommand():
            break;
        }
      } catch (e, stack) {
        _routeEvent(
          DebugLogEvent(
            message: '⚠️ [WEB WORKER ERROR] Handled exception: $e\n$stack',
            asrBuffer: sequencer.currentSegmentAsrText,
          ),
        );
      }
    });

    for (final cmd in _pendingCommands) {
      _commandPort!.add(cmd);
    }
    _pendingCommands.clear();
  }

  void _routeEvent(IsolateEvent event) {
    switch (event) {
      case WordMatchedEvent():
        _wordStreamController.add(event);
      case AutoReanchorEvent():
        _autoReanchorStreamController.add(event);
      case DebugLogEvent(:final message, :final asrBuffer):
        DebugLogger.log('DP', message, asrBuffer: asrBuffer);
    }
  }

  void send(IsolateCommand command) {
    if (_commandPort != null) {
      _commandPort!.add(command);
    } else {
      _pendingCommands.add(command);
    }
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
    List<int>? charTokenIndices,
    List<double>? tokenDurations,
    List<double>? tokenStarts,
    List<double>? tokenEnds,
  ]) {
    send(
      SyncStreamCommand(
        asrText: segmentText,
        timestamps: segmentTimestamps ?? const [],
        isNewSegment: isNewSegment,
        ayahNumber: ayahNumber ?? 0,
        neuralAcoustics: neuralAcoustics ?? const [],
        charTokenIndices: charTokenIndices,
        tokenDurations: tokenDurations,
        tokenStarts: tokenStarts,
        tokenEnds: tokenEnds,
      ),
    );
  }

  void setTajweedMode(bool isTajweed) {
    send(SetTajweedModeCommand(isTajweed: isTajweed));
  }

  void updateConfig(TrackerConfig config) {
    send(UpdateTrackerConfigCommand(config: config));
  }

  void updateTajweedConfig(TajweedConfig tajweedConfig) {
    send(UpdateTajweedConfigCommand(tajweed: tajweedConfig));
  }

  void stop() {
    send(const StopIsolateCommand());
    _pendingCommands.clear();
    _wordStreamController.close();
    _autoReanchorStreamController.close();
    _commandPort?.close();
    _commandPort = null;
  }
}

// lib/tracking/word/phoneme_alignment_isolate_io.dart
import 'dart:async';
import 'dart:isolate';

import '../../data/quran_data.dart';
import '../../engine/core/transcription_result.dart';
import '../../utils/debug_logger.dart';
import 'dictation_sequencer.dart';
import 'phoneme_alignment_isolate_protocol.dart';

export 'phoneme_alignment_isolate_protocol.dart';

// ═══════════════════════════════════════════════════════════════════════════════
// BACKGROUND ISOLATE WORKER ENTRYPOINT
// ═══════════════════════════════════════════════════════════════════════════════

void alignmentWorkerEntrypoint(SendPort mainSendPort) {
  final commandPort = ReceivePort();
  mainSendPort.send(commandPort.sendPort);

  final sequencer = DictationSequencer(mainSendPort.send);

  commandPort.listen((rawMessage) {
    final IsolateCommand command;
    if (rawMessage is IsolateCommand) {
      command = rawMessage;
    } else if (rawMessage is Map) {
      try {
        command = IsolateCommand.fromMap(rawMessage);
      } catch (_) {
        return;
      }
    } else {
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

        case UpdateTajweedConfigCommand(:final tajweed):
          sequencer.updateTajweedConfig(tajweed);

        case StopIsolateCommand():
          Isolate.current.kill();
      }
    } catch (e, stack) {
      mainSendPort.send(
        DebugLogEvent(
          message: '⚠️ [ISOLATE ERROR] Handled exception: $e\n$stack',
          asrBuffer: sequencer.currentSegmentAsrText,
        ),
      );
    }
  });
}

// ═══════════════════════════════════════════════════════════════════════════════
// UI-SIDE ISOLATE MANAGER (Native / IO)
// ═══════════════════════════════════════════════════════════════════════════════

/// Main UI thread manager for the background alignment isolate.
class PhonemeAlignmentIsolate {
  SendPort? _sendPort;
  Isolate? _isolate;
  final List<IsolateCommand> _pendingCommands = [];

  final StreamController<WordMatchedEvent> _wordStreamController =
      StreamController<WordMatchedEvent>.broadcast();
  final StreamController<AutoReanchorEvent> _autoReanchorStreamController =
      StreamController<AutoReanchorEvent>.broadcast();

  Stream<WordMatchedEvent> get wordStream => _wordStreamController.stream;
  Stream<AutoReanchorEvent> get autoReanchorStream =>
      _autoReanchorStreamController.stream;

  Future<void> start() async {
    final receivePort = ReceivePort();
    final completer = Completer<void>();

    _isolate = await Isolate.spawn(
      alignmentWorkerEntrypoint,
      receivePort.sendPort,
    );

    receivePort.listen((message) {
      if (message is SendPort) {
        _sendPort = message;
        for (final cmd in _pendingCommands) {
          _sendPort!.send(cmd);
        }
        _pendingCommands.clear();
        if (!completer.isCompleted) completer.complete();
      } else if (message is IsolateEvent) {
        _routeEvent(message);
      } else if (message is Map) {
        try {
          final event = IsolateEvent.fromMap(message);
          _routeEvent(event);
        } catch (_) {
          // Ignore malformed event
        }
      }
    });

    return completer.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () {
        DebugLogger.log(
          'PhonemeAlignmentIsolate',
          '⚠️ Alignment isolate failed to handshake within 10s — isolate likely OOM-killed. Proceeding without alignment.',
        );
      },
    );
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
    if (_sendPort != null) {
      _sendPort!.send(command);
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

  void updateTajweedConfig(TajweedConfig tajweedConfig) {
    send(UpdateTajweedConfigCommand(tajweed: tajweedConfig));
  }

  void stop() {
    send(const StopIsolateCommand());
    _pendingCommands.clear();
    _wordStreamController.close();
    _autoReanchorStreamController.close();
    _isolate?.kill();
    _isolate = null;
    _sendPort = null;
  }
}

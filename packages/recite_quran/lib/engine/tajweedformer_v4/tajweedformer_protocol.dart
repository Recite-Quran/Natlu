// lib/engine/tajweedformer_v4/tajweedformer_protocol.dart
import 'dart:isolate';

import '../core/transcription_result.dart';

/// Sealed Dart 3 command protocol sent from main UI thread to the TajweedFormer isolate.
sealed class TajweedFormerCommand {
  const TajweedFormerCommand();
}

final class TajweedFormerInitCommand extends TajweedFormerCommand {
  final String modelDir;
  final String? context;
  final String? customLibPath;

  const TajweedFormerInitCommand({
    required this.modelDir,
    this.context = 'c16_l64',
    this.customLibPath,
  });
}

final class TajweedFormerRecognizeCommand extends TajweedFormerCommand {
  final TransferableTypedData chunk;
  final bool isFinal;
  final int startTime;

  const TajweedFormerRecognizeCommand({
    required this.chunk,
    required this.isFinal,
    required this.startTime,
  });
}

final class TajweedFormerResetCommand extends TajweedFormerCommand {
  const TajweedFormerResetCommand();
}

final class TajweedFormerFlushCommand extends TajweedFormerCommand {
  const TajweedFormerFlushCommand();
}

final class TajweedFormerDestroyCommand extends TajweedFormerCommand {
  const TajweedFormerDestroyCommand();
}

// ─────────────────────────────────────────────────────────────────────────────
// Sealed Events (Isolate ➔ Main UI Thread)
// ─────────────────────────────────────────────────────────────────────────────

sealed class TajweedFormerEvent {
  const TajweedFormerEvent();
}

final class TajweedFormerInitSuccessEvent extends TajweedFormerEvent {
  const TajweedFormerInitSuccessEvent();
}

final class TajweedFormerInitErrorEvent extends TajweedFormerEvent {
  final String error;
  const TajweedFormerInitErrorEvent(this.error);
}

final class TajweedFormerTranscriptionEvent extends TajweedFormerEvent {
  final String text;
  final List<String> tokens;
  final List<double> timestamps;
  final List<double> durations;
  final List<TokenNeuralAcoustics> neuralAcoustics;
  final bool isFinal;
  final int startTime;
  final int streamEpoch;

  const TajweedFormerTranscriptionEvent({
    required this.text,
    required this.tokens,
    required this.timestamps,
    this.durations = const [],
    this.neuralAcoustics = const [],
    required this.isFinal,
    required this.startTime,
    required this.streamEpoch,
  });
}

final class TajweedFormerDiagnosticsEvent extends TajweedFormerEvent {
  final double timestamp;
  final double geminationProb;
  final List<double> qalqalahProbs;
  final List<double> ghunnaProbs;
  final List<double> tafkheemProbs;
  final List<double> faceProbs;
  final double boundary;
  final double confidence;

  const TajweedFormerDiagnosticsEvent({
    required this.timestamp,
    required this.geminationProb,
    required this.qalqalahProbs,
    required this.ghunnaProbs,
    required this.tafkheemProbs,
    required this.faceProbs,
    this.boundary = 0.0,
    this.confidence = 1.0,
  });
}

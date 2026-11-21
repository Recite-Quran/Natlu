// lib/engine/core/transcription_result.dart

/// Exact frame-averaged neural diagnostic metrics for a recognized token from
/// TajweedFormer V4's multi-head neural network.
class TokenNeuralAcoustics {
  /// Confidence of consonant gemination / Shaddah holding [0.0 - 1.0].
  final double gemScore;

  /// Acoustic energy/probability of Qalqalah release [0.0 - 1.0].
  final double qalqalahScore;

  /// Probability of nasal Ghunnah presence [0.0 - 1.0].
  final double ghunnaScore;

  /// Probability of heavy Tafkheem resonance [0.0 - 1.0].
  final double tafkheemScore;

  /// Model frame confidence / truthfulness logit mapped to [0.0 - 1.0].
  final double confScore;

  const TokenNeuralAcoustics({
    this.gemScore = 0.0,
    this.qalqalahScore = 0.0,
    this.ghunnaScore = 0.0,
    this.tafkheemScore = 0.0,
    this.confScore = 1.0,
  });

  Map<String, dynamic> toMap() => {
        'gem': gemScore,
        'qalqalah': qalqalahScore,
        'ghunna': ghunnaScore,
        'tafkheem': tafkheemScore,
        'conf': confScore,
      };

  factory TokenNeuralAcoustics.fromMap(Map map) => TokenNeuralAcoustics(
        gemScore: (map['gem'] as num?)?.toDouble() ?? 0.0,
        qalqalahScore: (map['qalqalah'] as num?)?.toDouble() ?? 0.0,
        ghunnaScore: (map['ghunna'] as num?)?.toDouble() ?? 0.0,
        tafkheemScore: (map['tafkheem'] as num?)?.toDouble() ?? 0.0,
        confScore: (map['conf'] as num?)?.toDouble() ?? 1.0,
      );
}

/// Unified transcription result emitted by any recitation engine.
class TranscriptionResult {
  final String text;
  final bool isFinal;
  final int startTime;
  final List<String> tokens;
  final List<double> timestamps;
  final List<double> durations;
  final List<TokenNeuralAcoustics> neuralAcoustics;
  final int streamEpoch;

  TranscriptionResult({
    required this.text,
    this.isFinal = false,
    this.startTime = 0,
    this.tokens = const [],
    this.timestamps = const [],
    this.durations = const [],
    this.neuralAcoustics = const [],
    this.streamEpoch = 0,
  });
}


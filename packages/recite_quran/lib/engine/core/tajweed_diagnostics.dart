// lib/engine/core/tajweed_diagnostics.dart
// Multi-head neural diagnostics emitted by TajweedFormer V4.

class TajweedDiagnostics {
  /// Frame timestamp in seconds.
  final double timestamp;

  /// Gemination (Shaddah) probability in [0.0, 1.0].
  final double geminationProb;

  /// Qalqalah probabilities: `[0: none, 1: sughra, 2: kubra]`.
  final List<double> qalqalahProbs;

  /// Ghunnah probabilities: `[0: none, 1: plain, 2: geminate, 3: ikhfa, 4: idgham]`.
  final List<double> ghunnaProbs;

  /// Tafkheem (heavy/thin) probabilities: `[0: thin, 1: heavy, 2: low_heavy]`.
  final List<double> tafkheemProbs;

  /// Facial/secondary rule probabilities: `[0: none, 1: imala, 2: tasheel, 3: sakt]`.
  final List<double> faceProbs;

  /// Word/syllable boundary probability in [0.0, 1.0].
  final double boundary;

  /// Overall acoustic confidence metric in [0.0, 1.0].
  final double confidence;

  /// Elongation / Madd duration log probabilities, if available.
  final List<double>? timingLogProbs;

  const TajweedDiagnostics({
    required this.timestamp,
    required this.geminationProb,
    required this.qalqalahProbs,
    required this.ghunnaProbs,
    required this.tafkheemProbs,
    required this.faceProbs,
    this.boundary = 0.0,
    this.confidence = 1.0,
    this.timingLogProbs,
  });

  /// True if strong Qalqalah (sughra or kubra) was detected acoustically.
  bool get hasQalqalah =>
      qalqalahProbs.length >= 3 && (qalqalahProbs[1] > 0.5 || qalqalahProbs[2] > 0.5);

  /// True if strong Ghunnah was detected acoustically.
  bool get hasGhunnah =>
      ghunnaProbs.length >= 5 &&
      (ghunnaProbs[1] > 0.5 ||
          ghunnaProbs[2] > 0.5 ||
          ghunnaProbs[3] > 0.5 ||
          ghunnaProbs[4] > 0.5);

  /// True if consonant is heavily articulated (Tafkheem).
  bool get isMufakhkham =>
      tafkheemProbs.length >= 2 && tafkheemProbs[1] > 0.5;

  /// True if consonant is geminated (Shaddah).
  bool get isGeminated => geminationProb > 0.5;

  Map<String, dynamic> toMap() => {
        'timestamp': timestamp,
        'geminationProb': geminationProb,
        'qalqalahProbs': qalqalahProbs,
        'ghunnaProbs': ghunnaProbs,
        'tafkheemProbs': tafkheemProbs,
        'faceProbs': faceProbs,
        'boundary': boundary,
        'confidence': confidence,
        'timingLogProbs': timingLogProbs,
      };
}

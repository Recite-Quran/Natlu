// lib/tracking/asr_token_processor.dart
import 'dart:math';

import '../engine/core/transcription_result.dart';
import 'tracker_config.dart';

// ═══════════════════════════════════════════════════════════════════════════════
// ASR ACOUSTIC TOKEN PROCESSOR & AUDIO STREAM
// ═══════════════════════════════════════════════════════════════════════════════

/// Represents the filtered speech tokens and their acoustic durations.
class ProcessedAudioStream {
  final List<String> tokens;
  final List<double> durations;
  final List<double> starts;
  final List<double> ends;
  final List<double> spikeTimes;
  final List<TokenNeuralAcoustics> neuralAcoustics;

  ProcessedAudioStream({
    required this.tokens,
    required this.durations,
    this.starts = const [],
    this.ends = const [],
    this.spikeTimes = const [],
    this.neuralAcoustics = const [],
  });

  bool get isEmpty => tokens.isEmpty;
  bool get isNotEmpty => tokens.isNotEmpty;

  /// Returns the continuous phoneme text without CTC blanks.
  String get text => tokens.join('');

  /// Maps every character in [text] to its source token index in [tokens].
  List<int> get charTokenIndices {
    final List<int> result = [];
    for (int i = 0; i < tokens.length; i++) {
      final int len = tokens[i].length;
      for (int c = 0; c < len; c++) {
        result.add(i);
      }
    }
    return result;
  }

  /// Returns durations distributed across characters.
  /// Guarantees that `text.length == charDurations.length` for DTW alignment.
  List<double> get charDurations {
    final List<double> result = [];
    for (int i = 0; i < tokens.length; i++) {
      final tok = tokens[i];
      final dur = durations[i] / max(1, tok.length);
      for (int c = 0; c < tok.length; c++) {
        result.add(dur);
      }
    }
    return result;
  }

  /// Returns neural acoustics distributed across characters.
  /// Guarantees that `text.length == charNeuralAcoustics.length` for DTW trace evaluation.
  List<TokenNeuralAcoustics> get charNeuralAcoustics {
    final List<TokenNeuralAcoustics> result = [];
    for (int i = 0; i < tokens.length; i++) {
      final tok = tokens[i];
      final acoustics = i < neuralAcoustics.length
          ? neuralAcoustics[i]
          : const TokenNeuralAcoustics();
      for (int c = 0; c < tok.length; c++) {
        result.add(acoustics);
      }
    }
    return result;
  }
}

/// Ingests raw CTC tokens and timestamps from neural ASR, filters special/blank tokens,
/// and computes accurate acoustic phoneme durations reflecting real recitation articulation.
class AsrTokenProcessor {
  TrackerConfig config;

  AsrTokenProcessor({this.config = const TrackerConfig()});

  double get maxTokenDuration => config.maxTokenDurationAllowed;

  final List<String> _filteredTokens = [];
  final List<double> _filteredSpikeTimes = [];
  final List<double> _rawDurations = [];
  final List<TokenNeuralAcoustics> _filteredAcoustics = [];
  final List<double> _tokenDurations = [];
  final List<double> _tokenStarts = [];
  final List<double> _tokenEnds = [];

  void reset() {
    _filteredTokens.clear();
    _filteredSpikeTimes.clear();
    _rawDurations.clear();
    _filteredAcoustics.clear();
    _tokenDurations.clear();
    _tokenStarts.clear();
    _tokenEnds.clear();
  }

  /// Determines if a token is a prolonged vocalic Madd sound (tj3: 'aa', 'ii', 'uu').
  static bool isMaddToken(String tok) {
    return tok == 'aa' || tok == 'ii' || tok == 'uu';
  }

  /// Determines if a token represents an acoustic Ghunnah (held nasal sound):
  /// tj3 encodes the nasal as the dedicated dotless noon 'ں'.
  static bool isGhunnahToken(String tok) {
    return tok == 'ں';
  }

  /// Identifies sounds that can absorb acoustic prolongation (Madd vowels, Ghunnah).
  /// Shaddah is a per-token flag in the zfx reference, not a token pattern.
  static bool isElasticContinuant(String tok) {
    return isMaddToken(tok) || isGhunnahToken(tok);
  }

  /// Ingests a new [TranscriptionResult] from the ASR recognizer,
  /// updates filtered tokens and recomputes continuous acoustic durations.
  ProcessedAudioStream process(TranscriptionResult result) {
    final int maxCount = min(result.tokens.length, result.timestamps.length);

    // The engine emits the whole take on every push. Rebuild from that
    // cumulative result so a correction to an earlier token's timing or
    // acoustics is never left stale by an incremental append.
    _filteredTokens.clear();
    _filteredSpikeTimes.clear();
    _rawDurations.clear();
    _filteredAcoustics.clear();

    for (int i = 0; i < maxCount; i++) {
      final String tok = result.tokens[i];
      final double rawTs = result.timestamps[i];

      // Defensively filter empty or special CTC blank / epsilon / foreign tokens, and word bar '|'.
      if (tok.isEmpty ||
          tok == '<blank>' ||
          tok == '<blk>' ||
          tok == '|' ||
          tok == '<eps>' ||
          tok == 'eps' ||
          tok == '<foreign>') {
        continue;
      }

      _filteredTokens.add(tok);
      _filteredSpikeTimes.add(rawTs);
      _rawDurations.add(
        i < result.durations.length ? result.durations[i] : 0.0,
      );
      _filteredAcoustics.add(
        i < result.neuralAcoustics.length
            ? result.neuralAcoustics[i]
            : const TokenNeuralAcoustics(),
      );
    }

    // Recompute accurate acoustic durations across all filtered tokens
    _recomputeDurations();

    return ProcessedAudioStream(
      tokens: _filteredTokens,
      durations: _tokenDurations,
      starts: _tokenStarts,
      ends: _tokenEnds,
      spikeTimes: _filteredSpikeTimes,
      neuralAcoustics: _filteredAcoustics,
    );
  }

  /// Recomputes acoustic durations from the token end times.
  ///
  /// **`timestamps[k]` marks the END of token k's acoustic presence.**
  ///
  /// Therefore:
  ///   end[k]      = timestamp[k]
  ///   start[k]    = timestamp[k-1]  (= end[k-1], contiguous)
  ///   duration[k] = timestamp[k] - timestamp[k-1]
  ///
  /// When the engine supplies an exact frame-span duration, that duration is
  /// used instead and the start is derived from it. After an inter-ayah pause
  /// (silence gap), start[k] is decoupled from the previous token and
  /// estimated from the current end.
  void _recomputeDurations() {
    final int count = _filteredTokens.length;
    _tokenDurations.clear();
    _tokenStarts.clear();
    _tokenEnds.clear();
    if (count == 0) return;

    final List<double> starts = List.filled(count, 0.0);
    final List<double> ends = List.filled(count, 0.0);
    final List<double> durs = List.filled(count, 0.0);

    for (int k = 0; k < count; k++) {
      final double end = _filteredSpikeTimes[k];

      // The timestamp IS the end boundary of token k.
      ends[k] = end;

      if (k == 0) {
        // First token: no previous end. Estimate start from end minus a small window.
        starts[k] = max(0.0, end - 0.16);
      } else {
        final double endPrev = _filteredSpikeTimes[k - 1];
        final double gap = end - endPrev;

        // Accurate acoustic pause detection:
        // Prolonged vocalic sounds (Madd vowels), geminated consonants (Shaddah),
        // and held nasals (Ghunnah) naturally span up to 3.5s without pausing.
        // Sounds following a prolonged continuant span up to 2.0s.
        // A true inter-ayah breath pause is a substantial silence gap (> 1.25s).
        final double pauseThreshold;
        if (isElasticContinuant(_filteredTokens[k])) {
          pauseThreshold = 3.50;
        } else if (isElasticContinuant(_filteredTokens[k - 1]) ||
            _filteredTokens[k - 1].length >= 2) {
          pauseThreshold = 2.00;
        } else {
          pauseThreshold = 1.25;
        }

        if (gap > pauseThreshold) {
          // After a genuine breath pause: start is decoupled. Estimate onset before the end.
          final double onsetWindow =
              isElasticContinuant(_filteredTokens[k]) ? 0.35 : 0.16;
          starts[k] = max(endPrev + 0.04, end - onsetWindow);
        } else {
          // Continuous articulation: start[k] = end[k-1]
          starts[k] = endPrev;
        }
      }

      // Duration from exact acoustic frame span when available, else end - start.
      // High-precision neural duration from timing_log_probs (>= 0.12s) takes priority.
      if (k < _rawDurations.length && _rawDurations[k] >= 0.12) {
        durs[k] = _rawDurations[k].clamp(0.04, maxTokenDuration);
        starts[k] = max(0.0, ends[k] - durs[k]);
      } else if (isElasticContinuant(_filteredTokens[k]) && k + 1 < count) {
        // Holding window for Madd / Ghunnah continuants held until the next token:
        final double nextSpike = _filteredSpikeTimes[k + 1];
        final double elapsedHold = nextSpike - starts[k];
        durs[k] = (elapsedHold - 0.04).clamp(0.12, maxTokenDuration);
        ends[k] = starts[k] + durs[k];
      } else {
        durs[k] = (ends[k] - starts[k]).clamp(0.04, maxTokenDuration);
      }
    }

    _tokenStarts.addAll(starts);
    _tokenEnds.addAll(ends);
    _tokenDurations.addAll(durs);
  }
}

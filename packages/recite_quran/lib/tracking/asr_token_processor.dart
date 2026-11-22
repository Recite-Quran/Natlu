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

  /// Returns continuous timestamps distributed across characters for audio timeline alignment.
  List<double> get charTimestamps {
    final List<double> result = [];
    for (int i = 0; i < tokens.length; i++) {
      final tok = tokens[i];
      final double s = starts.isNotEmpty && i < starts.length ? starts[i] : 0.0;
      final double durPerChar = durations[i] / max(1, tok.length);
      for (int c = 0; c < tok.length; c++) {
        result.add(s + (c + 1) * durPerChar);
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
  final List<TokenNeuralAcoustics> _filteredAcoustics = [];
  final List<double> _tokenDurations = [];
  final List<double> _tokenStarts = [];
  final List<double> _tokenEnds = [];

  void reset() {
    _filteredTokens.clear();
    _filteredSpikeTimes.clear();
    _filteredAcoustics.clear();
    _tokenDurations.clear();
    _tokenStarts.clear();
    _tokenEnds.clear();
  }

  /// Determines if a token is a vocalic Madd sound (tj3: 'aa', 'ii', 'uu' or vowels 'a', 'i', 'u').
  static bool isMaddToken(String tok) {
    return tok == 'aa' ||
        tok == 'ii' ||
        tok == 'uu' ||
        tok == 'a' ||
        tok == 'i' ||
        tok == 'u';
  }

  /// Determines if a token represents an acoustic Ghunnah (nasal sound):
  /// tj3 encodes the nasal as dotless noon 'ں', standard noon 'ن', or meem 'م'.
  static bool isGhunnahToken(String tok) {
    return tok == 'ں' || tok == 'ن' || tok == 'م';
  }

  /// Ingests a new [TranscriptionResult] from the ASR recognizer,
  /// updates filtered tokens and retains exact acoustic frame boundaries.
  ProcessedAudioStream process(TranscriptionResult result) {
    final int maxCount = min(result.tokens.length, result.timestamps.length);

    _filteredTokens.clear();
    _filteredSpikeTimes.clear();
    _filteredAcoustics.clear();
    _tokenDurations.clear();
    _tokenStarts.clear();
    _tokenEnds.clear();

    for (int i = 0; i < maxCount; i++) {
      final String tok = result.tokens[i];
      final double endTs = result.timestamps[i];
      final double dur =
          i < result.durations.length ? result.durations[i] : 0.040;
      final double startTs = max(0.0, endTs - dur);

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
      _filteredSpikeTimes.add(endTs);
      _tokenEnds.add(endTs);
      _tokenStarts.add(startTs);
      _tokenDurations.add(dur.clamp(0.020, maxTokenDuration));
      _filteredAcoustics.add(
        i < result.neuralAcoustics.length
            ? result.neuralAcoustics[i]
            : const TokenNeuralAcoustics(),
      );
    }

    return ProcessedAudioStream(
      tokens: _filteredTokens,
      durations: _tokenDurations,
      starts: _tokenStarts,
      ends: _tokenEnds,
      spikeTimes: _filteredSpikeTimes,
      neuralAcoustics: _filteredAcoustics,
    );
  }
}

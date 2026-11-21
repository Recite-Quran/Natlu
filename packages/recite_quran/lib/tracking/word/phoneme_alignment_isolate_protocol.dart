// lib/tracking/word/phoneme_alignment_isolate_protocol.dart
import '../../data/quran_data.dart';
import '../../engine/core/transcription_result.dart';
import '../tracker_config.dart';

export '../tracker_config.dart';

// ═══════════════════════════════════════════════════════════════════════════════
// ISOLATE PROTOCOL (Commands: Main UI ➔ Isolate | Events: Isolate ➔ Main UI)
// ═══════════════════════════════════════════════════════════════════════════════

/// Verdict for a single word evaluation during recitation.
enum WordEvaluationVerdict {
  /// Word was recited correctly matching the phonetic reference (Green).
  correct,

  /// Word was phonetically recited, but triggered Tajweed warnings (Yellow).
  tajweedWarning,

  /// Word was mispronounced or phonetic distance exceeded threshold (Red).
  mispronounced,

  /// Word was skipped / omitted by the reciter (Neutral or Red).
  skipped,
}

/// Sealed base class for all commands sent from Main UI Thread ➔ Alignment Worker.
sealed class IsolateCommand {
  const IsolateCommand();

  Map<String, dynamic> toMap();

  static IsolateCommand fromMap(Map map) {
    final command = map['command'] as String?;
    switch (command) {
      case 'set_surah_reference':
        final rawRules = map['wordRules'] as List?;
        final List<List<WordTajweedRule>>? wordRules = rawRules?.map((l) {
          return (l as List)
              .map((r) => WordTajweedRule.fromMap(r as Map))
              .toList();
        }).toList();

        return SetSurahReferenceCommand(
          fullPhonemes: map['phonemes'] as String,
          boundaries: (map['boundaries'] as List).cast<int>(),
          surahNumber: map['surahNumber'] as int? ?? 0,
          ayahs: (map['ayahs'] as List?)?.cast<int>() ?? const [],
          wordsInAyah: (map['wordsInAyah'] as List?)?.cast<int>() ?? const [],
          isTajweed: map['isTajweed'] as bool? ?? false,
          forceClear: map['forceClear'] as bool? ?? false,
          startGlobalWord: map['startGlobalWord'] as int? ?? 0,
          wordRules: wordRules,
          charRuleClasses: (map['charRuleClasses'] as List?)?.cast<int>(),
        );

      case 'sync_stream':
        final rawAcoustics = map['neural_acoustics'] as List?;
        final List<TokenNeuralAcoustics> neuralAcoustics = rawAcoustics != null
            ? rawAcoustics
                .map((e) => e is TokenNeuralAcoustics
                    ? e
                    : (e is Map
                        ? TokenNeuralAcoustics.fromMap(e)
                        : const TokenNeuralAcoustics()))
                .toList()
            : const [];

        return SyncStreamCommand(
          asrText:
              map['text'] as String? ??
              (map['tokens'] as List?)?.join('') ??
              '',
          timestamps: (map['timestamps'] as List?)
                  ?.map((e) => (e as num?)?.toDouble() ?? 0.0)
                  .toList() ??
              const [],
          isNewSegment: map['is_new_segment'] as bool? ?? false,
          ayahNumber: map['ayah_number'] as int? ?? 0,
          neuralAcoustics: neuralAcoustics,
        );

      case 'jump_to_word':
        return JumpToWordCommand(
          globalWordIndex: map['global_word_index'] as int? ?? 0,
        );

      case 'set_tajweed_mode':
        return SetTajweedModeCommand(
          isTajweed: map['is_tajweed'] as bool? ?? false,
        );

      case 'update_config':
        return UpdateTrackerConfigCommand(
          config: TrackerConfig(
            recitationSpeed:
                RecitationSpeed.fromName(map['recitationSpeed'] as String?),
            matchingStrictness:
                MatchingStrictness.fromName(map['matchingStrictness'] as String?),
            enableEarlyMatching: map['enableEarlyMatching'] as bool? ?? true,
            enableAutoReanchor: map['enableAutoReanchor'] as bool? ?? false,
            reanchorStallThreshold: map['reanchorStallThreshold'] as int? ?? 24,
          ),
        );

      case 'stop':
        return const StopIsolateCommand();

      default:
        throw ArgumentError('Unknown IsolateCommand: $command');
    }
  }
}

class SetSurahReferenceCommand extends IsolateCommand {
  final String fullPhonemes;
  final List<int> boundaries;
  final int surahNumber;
  final List<int> ayahs;
  final List<int> wordsInAyah;
  final bool isTajweed;
  final bool forceClear;
  final int startGlobalWord;
  final List<List<WordTajweedRule>>? wordRules;

  /// Rule-class code per character of [fullPhonemes]: 0 = plain, 1-based
  /// index into the word's rule list otherwise. Sourced from the zfx rule
  /// sites; drives deterministic span grading in the isolate.
  final List<int>? charRuleClasses;

  const SetSurahReferenceCommand({
    required this.fullPhonemes,
    required this.boundaries,
    required this.surahNumber,
    this.ayahs = const [],
    this.wordsInAyah = const [],
    this.isTajweed = false,
    this.forceClear = false,
    this.startGlobalWord = 0,
    this.wordRules,
    this.charRuleClasses,
  });

  @override
  Map<String, dynamic> toMap() => {
    'command': 'set_surah_reference',
    'phonemes': fullPhonemes,
    'boundaries': boundaries,
    'surahNumber': surahNumber,
    'ayahs': ayahs,
    'wordsInAyah': wordsInAyah,
    'isTajweed': isTajweed,
    'forceClear': forceClear,
    'startGlobalWord': startGlobalWord,
    'wordRules': wordRules
        ?.map((list) => list.map((r) => r.toMap()).toList())
        .toList(),
    'charRuleClasses': charRuleClasses,
  };
}

class SyncStreamCommand extends IsolateCommand {
  final String asrText;
  final List<double> timestamps;
  final bool isNewSegment;
  final int ayahNumber;
  final List<TokenNeuralAcoustics> neuralAcoustics;

  const SyncStreamCommand({
    required this.asrText,
    required this.timestamps,
    this.isNewSegment = false,
    this.ayahNumber = 0,
    this.neuralAcoustics = const [],
  });

  @override
  Map<String, dynamic> toMap() => {
    'command': 'sync_stream',
    'text': asrText,
    'timestamps': timestamps,
    'is_new_segment': isNewSegment,
    'ayah_number': ayahNumber,
    'neural_acoustics': neuralAcoustics,
  };
}

class JumpToWordCommand extends IsolateCommand {
  final int globalWordIndex;
  const JumpToWordCommand({required this.globalWordIndex});

  @override
  Map<String, dynamic> toMap() => {
    'command': 'jump_to_word',
    'global_word_index': globalWordIndex,
  };
}

class SetTajweedModeCommand extends IsolateCommand {
  final bool isTajweed;
  const SetTajweedModeCommand({required this.isTajweed});

  @override
  Map<String, dynamic> toMap() => {
    'command': 'set_tajweed_mode',
    'is_tajweed': isTajweed,
  };
}

class UpdateTrackerConfigCommand extends IsolateCommand {
  final TrackerConfig config;
  const UpdateTrackerConfigCommand({required this.config});

  @override
  Map<String, dynamic> toMap() => {
    'command': 'update_config',
    'recitationSpeed': config.recitationSpeed.name,
    'matchingStrictness': config.matchingStrictness.name,
    'enableEarlyMatching': config.enableEarlyMatching,
    'enableAutoReanchor': config.enableAutoReanchor,
    'reanchorStallThreshold': config.reanchorStallThreshold,
  };
}

class StopIsolateCommand extends IsolateCommand {
  const StopIsolateCommand();

  @override
  Map<String, dynamic> toMap() => {'command': 'stop'};
}

/// Sealed base class for all events emitted from Alignment Worker ➔ Main UI Thread.
sealed class IsolateEvent {
  const IsolateEvent();

  Map<String, dynamic> toMap();

  static IsolateEvent fromMap(Map map) {
    final event = map['event'] as String?;
    switch (event) {
      case 'highlight':
        final verdictName = map['verdict'] as String?;
        final WordEvaluationVerdict verdict;
        if (verdictName != null) {
          verdict = WordEvaluationVerdict.values.firstWhere(
            (v) => v.name == verdictName,
            orElse: () => WordEvaluationVerdict.correct,
          );
        } else if (map['is_red'] == true) {
          verdict = WordEvaluationVerdict.mispronounced;
        } else if (map['is_neutral'] == true) {
          verdict = WordEvaluationVerdict.skipped;
        } else if (map['tajweed_errors'] != null &&
            (map['tajweed_errors'] as List).isNotEmpty) {
          verdict = WordEvaluationVerdict.tajweedWarning;
        } else {
          verdict = WordEvaluationVerdict.correct;
        }

        return WordMatchedEvent(
          wordId: map['word_id'] as int,
          surah: map['surah'] as int? ?? 0,
          ayah: map['ayah'] as int? ?? 0,
          wordInAyah: map['word_in_ayah'] as int? ?? 0,
          verdict: verdict,
          score: (map['score'] as num?)?.toDouble() ?? 0.0,
          cleanAsr: map['clean_asr'] as String? ?? '',
          expectedPhonemes: map['expected_phonemes'] as String? ?? '',
          tajweedErrors: (map['tajweed_errors'] as List?)
              ?.map((e) => (e as Map).cast<String, dynamic>())
              .toList(),
          isAyahCompleted: map['is_ayah_completed'] as bool? ?? false,
        );

      case 'ayah_completed':
        return AyahCompletedEvent(
          surah: map['surah'] as int? ?? 0,
          ayah: map['ayah'] as int? ?? 0,
          totalWords: map['total_words'] as int? ?? 0,
        );

      case 'debug':
        return DebugLogEvent(
          message: map['message'] as String? ?? '',
          asrBuffer: map['asr_buffer'] as String? ?? '',
        );

      default:
        throw ArgumentError('Unknown IsolateEvent: $event');
    }
  }
}

class WordMatchedEvent extends IsolateEvent {
  final int wordId;
  final int surah;
  final int ayah;
  final int wordInAyah;
  final WordEvaluationVerdict verdict;
  final double score;
  final String cleanAsr;
  final String expectedPhonemes;
  final List<Map<String, dynamic>>? tajweedErrors;
  final bool isAyahCompleted;

  const WordMatchedEvent({
    required this.wordId,
    this.surah = 0,
    this.ayah = 0,
    this.wordInAyah = 0,
    this.verdict = WordEvaluationVerdict.correct,
    this.score = 0.0,
    required this.cleanAsr,
    this.expectedPhonemes = '',
    this.tajweedErrors,
    this.isAyahCompleted = false,
    bool? isRed,
    bool? isNeutral,
  });

  /// Whether the word was recited correctly (Right).
  bool get isRight =>
      verdict == WordEvaluationVerdict.correct ||
      verdict == WordEvaluationVerdict.tajweedWarning;

  /// Whether the word was mispronounced, wrong, or skipped (Wrong).
  bool get isWrong => !isRight;

  /// Word index within the Ayah (0-indexed: 0..wordCount - 1).
  int get wordIndex => wordInAyah;

  /// Word number within the Ayah (1-indexed convenience: 1..wordCount).
  int get wordNumber => wordInAyah + 1;

  /// Actual transcribed phonemes uttered by the reciter for this word.
  String get recognizedPhonemes => cleanAsr;

  /// Whether this is the last word of the targeted Ayah.
  bool get isLastWordOfAyah => isAyahCompleted;

  bool get isRed =>
      verdict == WordEvaluationVerdict.mispronounced ||
      verdict == WordEvaluationVerdict.skipped;

  bool get isNeutral => verdict == WordEvaluationVerdict.skipped;

  bool get isGreen => verdict == WordEvaluationVerdict.correct;

  bool get isYellow => verdict == WordEvaluationVerdict.tajweedWarning;

  @override
  Map<String, dynamic> toMap() => {
    'event': 'highlight',
    'word_id': wordId,
    'surah': surah,
    'ayah': ayah,
    'word_in_ayah': wordInAyah,
    'verdict': verdict.name,
    'score': score,
    'clean_asr': cleanAsr,
    'expected_phonemes': expectedPhonemes,
    'tajweed_errors': tajweedErrors,
    'is_ayah_completed': isAyahCompleted,
    'is_red': isRed,
    'is_neutral': isNeutral,
  };
}

class AyahCompletedEvent extends IsolateEvent {
  final int surah;
  final int ayah;
  final int totalWords;

  const AyahCompletedEvent({
    required this.surah,
    required this.ayah,
    this.totalWords = 0,
  });

  @override
  Map<String, dynamic> toMap() => {
    'event': 'ayah_completed',
    'surah': surah,
    'ayah': ayah,
    'total_words': totalWords,
  };
}

class DebugLogEvent extends IsolateEvent {
  final String message;
  final String asrBuffer;

  const DebugLogEvent({required this.message, required this.asrBuffer});

  @override
  Map<String, dynamic> toMap() => {
    'event': 'debug',
    'message': message,
    'asr_buffer': asrBuffer,
  };
}

import 'package:flutter/foundation.dart';

import 'recited_word.dart';

enum RecitationEventKind {
  /// Prayer mode started; [RecitationEvent.where] is where the plan starts.
  started,

  /// The end of al-Fātiḥa was heard; following from [RecitationEvent.where].
  fatihaEnded,

  /// "Allāhu akbar" was heard; the plan will resume at
  /// [RecitationEvent.where].
  takbir,

  /// The plan moved on to the next surah.
  nextSurah,

  /// A mistake: auto-correct beeps (when silent, would beep).
  mistake,

  /// The reciter corrected the mistake in time.
  corrected,

  /// Auto-correct reads [RecitationEvent.words] aloud (when silent, would).
  prompt,

  /// Stopped.
  stopped,
}

enum RecitationReason {
  /// Word(s) left out (the tracker marked them as mistakes).
  skipped,

  /// Speech that doesn't match the expected word.
  wrongWord,

  /// A long pause part way through an ayah.
  pauseMidAyah,

  /// A long pause at the end of an ayah.
  pauseBetweenAyahs,
}

/// Something prayer mode or auto-correct noticed or did (or, silent, would
/// have done).
@immutable
class RecitationEvent {
  const RecitationEvent(
    this.kind,
    this.at, {
    this.where,
    this.words,
    this.wordRefs = const [],
    this.reason,
  });

  final RecitationEventKind kind;
  final DateTime at;

  /// The position in the Quran the event is about.
  final MushafWord? where;

  /// The words of a mistake or a prompt, as written.
  final String? words;

  /// Where each of a prompt's words is, in order.
  final List<MushafWord> wordRefs;
  final RecitationReason? reason;

  @override
  String toString() => '${kind.name}'
      '${reason == null ? '' : ' (${reason!.name})'}'
      '${where == null ? '' : ' at $where'}'
      '${words == null ? '' : ': $words'}';
}

/// The events of one recitation, in order, as prayer mode and auto-correct
/// add them: shown on screen and heard (see RecitationVoice).
class RecitationLog extends ChangeNotifier {
  RecitationLog({this.debugLog});

  final void Function(String message)? debugLog;
  final List<RecitationEvent> _events = [];

  List<RecitationEvent> get events => List.unmodifiable(_events);

  void add(RecitationEvent e) {
    _events.add(e);
    debugLog?.call(e.toString());
    notifyListeners();
  }
}

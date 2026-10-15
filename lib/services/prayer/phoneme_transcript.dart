/// A rolling record of the phonemes the speech recognizer has heard, kept
/// independently of the word tracker so prayer mode can listen for phrases
/// that aren't part of the text being followed ("Allāhu akbar", the end of
/// al-Fātiḥa) and measure how much has been said since a given moment.
///
/// The recognizer reports each speech segment as a growing list of tokens and
/// starts a new list after an endpoint (a pause) or a reset; [addResult]
/// turns that into one continuous stream of phoneme characters.
class PhonemeTranscript {
  PhonemeTranscript({this.capacity = 800, DateTime Function()? now})
      : _now = now ?? DateTime.now;

  /// How many of the most recent characters are kept.
  final int capacity;
  final DateTime Function() _now;

  final StringBuffer _buffer = StringBuffer();
  String _text = '';
  int _dropped = 0;
  List<String> _segmentTokens = const [];
  bool _newSegment = true;
  int? _epoch;
  DateTime? _lastGrowth;

  /// The most recent characters heard (up to [capacity]).
  String get text => _text;

  /// Total characters heard since the transcript was created or cleared.
  /// Only grows, except when the recognizer revises the end of a segment.
  int get length => _dropped + _text.length;

  /// When characters were last added, or null if nothing was heard yet.
  DateTime? get lastGrowth => _lastGrowth;

  /// What was heard after [mark] (an earlier [length]), as far as it is
  /// still kept.
  String since(int mark) {
    final start = mark - _dropped;
    if (start >= _text.length) return '';
    return _text.substring(start < 0 ? 0 : start);
  }

  /// Adds one recognizer result: the tokens of the current segment so far.
  /// Set [isFinal] for the last result of a segment.
  void addResult({
    required List<String> tokens,
    bool isFinal = false,
    int epoch = 0,
  }) {
    if (_epoch != epoch) {
      _epoch = epoch;
      _newSegment = true;
    }
    final clean = [
      for (final t in tokens)
        if (!_isBlank(t)) t,
    ];

    if (_newSegment) {
      _segmentTokens = const [];
      _newSegment = false;
    }

    int common = 0;
    while (common < _segmentTokens.length &&
        common < clean.length &&
        _segmentTokens[common] == clean[common]) {
      common++;
    }
    if (common < _segmentTokens.length) {
      // The recognizer revised the end of the segment: take back what it
      // changed its mind about.
      int revised = 0;
      for (int i = common; i < _segmentTokens.length; i++) {
        revised += _segmentTokens[i].length;
      }
      _removeLast(revised);
    }

    final added = clean.skip(common).join();
    if (added.isNotEmpty) {
      _append(added);
      _lastGrowth = _now();
    }
    _segmentTokens = clean;
    if (isFinal) _newSegment = true;
  }

  /// Forgets everything heard.
  void clear() {
    _text = '';
    _dropped = 0;
    _segmentTokens = const [];
    _newSegment = true;
    _lastGrowth = null;
  }

  void _append(String s) {
    _buffer
      ..clear()
      ..write(_text)
      ..write(s);
    _text = _buffer.toString();
    if (_text.length > capacity) {
      final drop = _text.length - capacity;
      _text = _text.substring(drop);
      _dropped += drop;
    }
  }

  void _removeLast(int n) {
    if (n <= 0) return;
    final keep = _text.length - n;
    _text = keep > 0 ? _text.substring(0, keep) : '';
  }

  static bool _isBlank(String t) =>
      t.isEmpty || t == '<blank>' || t == '<blk>' || t == '<eps>' || t == 'eps';
}

/// One word of the Mushaf: surah, ayah and its index in the ayah.
class MushafWord {
  final int surah;
  final int ayah;

  /// Zero-based index of the word within its ayah (the index
  /// `HighlightingController.isWordGreen` and friends take).
  final int wordIndex0;

  const MushafWord(this.surah, this.ayah, this.wordIndex0);

  @override
  bool operator ==(Object other) =>
      other is MushafWord &&
      other.surah == surah &&
      other.ayah == ayah &&
      other.wordIndex0 == wordIndex0;

  @override
  int get hashCode => Object.hash(surah, ayah, wordIndex0);

  @override
  String toString() => '$surah:$ayah:${wordIndex0 + 1}';
}

/// What the recitation engine currently says about one word.
enum RecitedWordState {
  /// Not recited (or cleared for a fresh attempt).
  unspoken,

  /// Recited, without a word mistake (tajweed notes don't count).
  recited,

  /// Marked as a mistake: wrong or missing letters, or skipped.
  mistake,
}

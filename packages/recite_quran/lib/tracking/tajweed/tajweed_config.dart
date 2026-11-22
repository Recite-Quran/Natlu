import 'package:flutter/foundation.dart';

// ═══════════════════════════════════════════════════════════════════════════════
// TAJWEED VERIFICATION CONFIGURATION (MODULAR RULE TOGGLES)
// ═══════════════════════════════════════════════════════════════════════════════

/// Granular configuration for deterministic Tajweed rule verification.
///
/// Allows application developers to selectively enable or disable specific
/// Tajweed and phonetic checks (Madd elongation, Tashkeel diacritics,
/// Ghunnah nasalization, Shaddah gemination, Qalqalah release burst, and Letter swap).
@immutable
class TajweedConfig {
  /// Whether to verify acoustic holding durations for Madd (المدود: طبيعي، منفصل، متصل، عارض، لازم، لين).
  final bool checkMadd;

  /// Whether to verify short vowel diacritics / Harakat on consonants (التشكيل: فتحة، كسرة، ضمة).
  final bool checkTashkeel;

  /// Whether to verify nasal holding duration for doubled Noon and Meem (غنة المشددتين: نّ، مّ، ں).
  final bool checkGhunnah;

  /// Whether to verify consonant doubling / geminate closure holding (الشدة والضغط الصوتي).
  final bool checkShaddah;

  /// Whether to verify acoustic release burst / neural echo score for Qalqalah letters (ق، ط، ب، ج، د).
  final bool checkQalqalah;

  /// Whether to flag letter substitution / Makhraj swaps (إبدال وتبديل الحروف والمخارج) as errors.
  /// When disabled, close phonetic variations/confusions are tolerated.
  final bool checkLetterSwap;

  const TajweedConfig({
    this.checkMadd = true,
    this.checkTashkeel = true,
    this.checkGhunnah = true,
    this.checkShaddah = true,
    this.checkQalqalah = true,
    this.checkLetterSwap = true,
  });

  /// All Tajweed and phonetic checks enabled (full verification / certification mode).
  const TajweedConfig.all() : this();

  /// All Tajweed and phonetic checks disabled (pure pronunciation / memorization tracking only).
  const TajweedConfig.none()
      : this(
          checkMadd: false,
          checkTashkeel: false,
          checkGhunnah: false,
          checkShaddah: false,
          checkQalqalah: false,
          checkLetterSwap: false,
        );

  /// Custom combination of Tajweed and phonetic checks.
  const TajweedConfig.custom({
    bool checkMadd = true,
    bool checkTashkeel = true,
    bool checkGhunnah = true,
    bool checkShaddah = true,
    bool checkQalqalah = true,
    bool checkLetterSwap = true,
  }) : this(
          checkMadd: checkMadd,
          checkTashkeel: checkTashkeel,
          checkGhunnah: checkGhunnah,
          checkShaddah: checkShaddah,
          checkQalqalah: checkQalqalah,
          checkLetterSwap: checkLetterSwap,
        );

  /// Whether all Tajweed and phonetic checks are active (standard Quran mode).
  bool get isAllEnabled =>
      checkMadd &&
      checkTashkeel &&
      checkGhunnah &&
      checkShaddah &&
      checkQalqalah &&
      checkLetterSwap;

  /// Whether all Tajweed checks are disabled (pure memorization / word tracking only).
  bool get isAllDisabled => !isAnyCheckEnabled;

  /// Whether a custom subset of checks is active.
  bool get isCustom => !isAllEnabled && !isAllDisabled;

  /// Whether at least one check is active.
  bool get isAnyCheckEnabled =>
      checkMadd ||
      checkTashkeel ||
      checkGhunnah ||
      checkShaddah ||
      checkQalqalah ||
      checkLetterSwap;

  TajweedConfig copyWith({
    bool? checkMadd,
    bool? checkTashkeel,
    bool? checkGhunnah,
    bool? checkShaddah,
    bool? checkQalqalah,
    bool? checkLetterSwap,
  }) {
    return TajweedConfig(
      checkMadd: checkMadd ?? this.checkMadd,
      checkTashkeel: checkTashkeel ?? this.checkTashkeel,
      checkGhunnah: checkGhunnah ?? this.checkGhunnah,
      checkShaddah: checkShaddah ?? this.checkShaddah,
      checkQalqalah: checkQalqalah ?? this.checkQalqalah,
      checkLetterSwap: checkLetterSwap ?? this.checkLetterSwap,
    );
  }

  Map<String, dynamic> toMap() => {
        'checkMadd': checkMadd,
        'checkTashkeel': checkTashkeel,
        'checkGhunnah': checkGhunnah,
        'checkShaddah': checkShaddah,
        'checkQalqalah': checkQalqalah,
        'checkLetterSwap': checkLetterSwap,
      };

  factory TajweedConfig.fromMap(Map map) => TajweedConfig(
        checkMadd: map['checkMadd'] as bool? ?? true,
        checkTashkeel: map['checkTashkeel'] as bool? ?? true,
        checkGhunnah: map['checkGhunnah'] as bool? ?? true,
        checkShaddah: map['checkShaddah'] as bool? ?? true,
        checkQalqalah: map['checkQalqalah'] as bool? ?? true,
        checkLetterSwap: map['checkLetterSwap'] as bool? ?? true,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TajweedConfig &&
          runtimeType == other.runtimeType &&
          checkMadd == other.checkMadd &&
          checkTashkeel == other.checkTashkeel &&
          checkGhunnah == other.checkGhunnah &&
          checkShaddah == other.checkShaddah &&
          checkQalqalah == other.checkQalqalah &&
          checkLetterSwap == other.checkLetterSwap;

  @override
  int get hashCode => Object.hash(
        checkMadd,
        checkTashkeel,
        checkGhunnah,
        checkShaddah,
        checkQalqalah,
        checkLetterSwap,
      );
}

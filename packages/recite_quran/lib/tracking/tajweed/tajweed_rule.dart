// lib/tracking/tajweed/tajweed_rule.dart
// ═══════════════════════════════════════════════════════════════════════════════
// TAJWEED RULE SPECIFICATION & ACOUSTIC PROFILE MATRIX (HEADLESS ENGINE)
//
// Defines deterministic acoustic duration boundaries and entity rules for Tajweed.
// Every rule specifies an explicit [AcousticThreshold] (min, target, max)
// for each [RecitationSpeed] tier (Fast / Hadr, Normal / Tarteel, Slow / Tahqeeq).
//
// NOTE: This package is a pure acoustic matching engine. It contains ZERO UI
// labels, ZERO presentation strings, and ZERO language couplings. Consuming UI
// applications identify rules via [TajweedRuleType] and [ruleId].
// ═══════════════════════════════════════════════════════════════════════════════

import '../../data/quran_data.dart';
import '../tracker_config.dart';

// ─────────────────────────────────────────────────────────────────────────────
// 1. Core Data Structures & Enums
// ─────────────────────────────────────────────────────────────────────────────

/// Canonical Tajweed rule classification matching the Quranic metadata taxonomy.
enum TajweedRuleType {
  /// Normal 2-harakat natural elongation (المد الطبيعي).
  maddNormal(1),

  /// Separated elongation across word boundaries (المد المنفصل).
  maddMonfasel(2),

  /// Connected elongation with Hamza in same word (المد المتصل).
  maddMottasel(3),

  /// Connected elongation stopped upon at end of Ayah (المد المتصل وقفا).
  maddMottaselPause(4),

  /// Elongation presented due to pause (المد العارض للسكون).
  maddAared(5),

  /// Obligatory 6-harakat elongation (المد اللازم).
  maddLazem(6),

  /// Soft elongation on Ya/Waw Sakinah before pause (مد اللين).
  maddLeen(7),

  /// Release burst echo on consonant closure (قلقلة).
  qalqalah(8),

  /// Consonant closure and geminate doubling (الشدة).
  shaddah(9),

  /// Nasal resonance on doubled Noon / Meem (غنة المشددتين).
  ghunnah(10),

  /// Other or unclassified acoustic rule site.
  other(0);

  /// Classical database rule identifier (1-10).
  final int ruleId;

  const TajweedRuleType(this.ruleId);

  /// Resolves a [TajweedRuleType] from its canonical database [ruleId].
  static TajweedRuleType fromId(int id) {
    for (final t in TajweedRuleType.values) {
      if (t.ruleId == id) return t;
    }
    return TajweedRuleType.other;
  }

  /// Resolves a [TajweedRuleType] from its enum name string safely.
  static TajweedRuleType fromString(String? name) {
    if (name == null) return TajweedRuleType.other;
    for (final t in TajweedRuleType.values) {
      if (t.name == name) return t;
    }
    return TajweedRuleType.other;
  }
}

/// Represents the exact diagnosis of an acoustic duration check (`valid`, `underheld`, or `overheld`).
enum TajweedDurationStatus {
  /// The acoustic holding time matches the required duration within tolerance (`PASS`).
  valid,

  /// The reciter held the sound for less than the required duration (`FAIL - underheld / نقص`).
  underheld,

  /// The reciter held the sound longer than the allowed maximum duration (`FAIL - overheld / زيادة`).
  overheld;
}

/// Represents deterministic acoustic duration boundaries (in seconds) for a rule.
class AcousticThreshold {
  /// The minimum acoustic duration in seconds before flagging [TajweedDurationStatus.underheld].
  final double minSeconds;

  /// The nominal target duration in seconds for pedagogical reference.
  final double targetSeconds;

  /// The maximum acoustic duration in seconds before flagging [TajweedDurationStatus.overheld].
  final double maxSeconds;

  const AcousticThreshold({
    required this.minSeconds,
    required this.targetSeconds,
    required this.maxSeconds,
  });

  /// Evaluates an actual acoustic duration against these boundaries.
  TajweedDurationStatus evaluate(double measuredSeconds) {
    if (measuredSeconds < 0.0 ||
        measuredSeconds.isNaN ||
        measuredSeconds.isInfinite) {
      return TajweedDurationStatus.valid;
    }
    if (measuredSeconds < minSeconds) {
      return TajweedDurationStatus.underheld;
    }
    if (measuredSeconds > maxSeconds) {
      return TajweedDurationStatus.overheld;
    }
    return TajweedDurationStatus.valid;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 2. Base Tajweed Rule
// ─────────────────────────────────────────────────────────────────────────────

/// Abstract base class representing a duration-evaluated Tajweed rule entity.
abstract class TajweedRule {
  /// Machine-readable rule classification.
  final TajweedRuleType ruleType;

  /// Numeric rule identifier matching the Quran reference database.
  final int ruleId;

  /// Classical Harakat count (1, 1.5, 2, 4, 6) for duration scaling.
  final num goldenLen;

  const TajweedRule({
    required this.ruleType,
    required this.ruleId,
    required this.goldenLen,
  });

  /// Returns explicit acoustic threshold boundaries for the given recitation speed.
  AcousticThreshold getThreshold(RecitationSpeed speed);

  /// Verifies whether the actual acoustic duration is valid, too short, or too long.
  TajweedDurationStatus checkDurationStatus(
    double durationSeconds, [
    RecitationSpeed speed = RecitationSpeed.normal,
  ]) =>
      getThreshold(speed).evaluate(durationSeconds);

  /// Verifies if the actual acoustic duration meets the required duration within tolerance.
  bool checkDuration(
    double durationSeconds, [
    RecitationSpeed speed = RecitationSpeed.normal,
  ]) =>
      checkDurationStatus(durationSeconds, speed) ==
      TajweedDurationStatus.valid;

  /// Target acoustic duration in seconds for pedagogical reference.
  double getRequiredDuration(
          [RecitationSpeed speed = RecitationSpeed.normal]) =>
      getThreshold(speed).targetSeconds;

  /// Minimum allowed acoustic duration in seconds before [underheld] error.
  double getMinAllowedDuration(
          [RecitationSpeed speed = RecitationSpeed.normal]) =>
      getThreshold(speed).minSeconds;

  /// Maximum allowed acoustic duration in seconds before [overheld] error.
  double getMaxAllowedDuration(
          [RecitationSpeed speed = RecitationSpeed.normal]) =>
      getThreshold(speed).maxSeconds;
}

// ─────────────────────────────────────────────────────────────────────────────
// 3. Madd Rules (أحكام المدود)
// ─────────────────────────────────────────────────────────────────────────────

/// Base class for general Madd rules.
class MaddRule extends TajweedRule {
  const MaddRule({
    super.ruleType = TajweedRuleType.maddNormal,
    super.ruleId = 1,
    required super.goldenLen,
  });

  @override
  AcousticThreshold getThreshold(RecitationSpeed speed) {
    if (goldenLen <= 2) {
      return const NormalMaddRule().getThreshold(speed);
    }
    if (goldenLen >= 6) {
      return const LazemMaddRule().getThreshold(speed);
    }
    return const MottaselMaddRule().getThreshold(speed);
  }
}

/// Normal Madd (المد الطبيعي) — 2 Harakat
class NormalMaddRule extends MaddRule {
  const NormalMaddRule()
      : super(
          ruleType: TajweedRuleType.maddNormal,
          ruleId: 1,
          goldenLen: 2,
        );

  @override
  AcousticThreshold getThreshold(RecitationSpeed speed) => switch (speed) {
        RecitationSpeed.fast => const AcousticThreshold(
            minSeconds: 0.075,
            targetSeconds: 0.240,
            maxSeconds: 0.600,
          ),
        RecitationSpeed.normal => const AcousticThreshold(
            minSeconds: 0.150,
            targetSeconds: 0.300,
            maxSeconds: 0.700,
          ),
        RecitationSpeed.slow => const AcousticThreshold(
            minSeconds: 0.180,
            targetSeconds: 0.360,
            maxSeconds: 0.850,
          ),
      };
}

/// Monfasel Madd (المد المنفصل) — 4 Harakat
class MonfaselMaddRule extends MaddRule {
  const MonfaselMaddRule([int harakat = 4])
      : super(
          ruleType: TajweedRuleType.maddMonfasel,
          ruleId: 2,
          goldenLen: harakat,
        );

  @override
  AcousticThreshold getThreshold(RecitationSpeed speed) => switch (speed) {
        RecitationSpeed.fast => const AcousticThreshold(
            minSeconds: 0.075,
            targetSeconds: 0.240,
            maxSeconds: 0.800,
          ),
        RecitationSpeed.normal => const AcousticThreshold(
            minSeconds: 0.450,
            targetSeconds: 0.600,
            maxSeconds: 1.400,
          ),
        RecitationSpeed.slow => const AcousticThreshold(
            minSeconds: 0.650,
            targetSeconds: 0.900,
            maxSeconds: 1.800,
          ),
      };
}

/// Mottasel Madd (المد المتصل) — 4-5 Harakat
class MottaselMaddRule extends MaddRule {
  const MottaselMaddRule([int harakat = 4])
      : super(
          ruleType: TajweedRuleType.maddMottasel,
          ruleId: 3,
          goldenLen: harakat,
        );

  @override
  AcousticThreshold getThreshold(RecitationSpeed speed) => switch (speed) {
        RecitationSpeed.fast => const AcousticThreshold(
            minSeconds: 0.350,
            targetSeconds: 0.480,
            maxSeconds: 1.200,
          ),
        RecitationSpeed.normal => const AcousticThreshold(
            minSeconds: 0.450,
            targetSeconds: 0.600,
            maxSeconds: 1.500,
          ),
        RecitationSpeed.slow => const AcousticThreshold(
            minSeconds: 0.650,
            targetSeconds: 0.900,
            maxSeconds: 1.800,
          ),
      };
}

/// Mottasel Madd at Pause (المد المتصل وقفا)
class MottaselMaddPauseRule extends MaddRule {
  const MottaselMaddPauseRule([int harakat = 4])
      : super(
          ruleType: TajweedRuleType.maddMottaselPause,
          ruleId: 4,
          goldenLen: harakat,
        );

  @override
  AcousticThreshold getThreshold(RecitationSpeed speed) => switch (speed) {
        RecitationSpeed.fast => const AcousticThreshold(
            minSeconds: 0.350,
            targetSeconds: 0.480,
            maxSeconds: 1.800,
          ),
        RecitationSpeed.normal => const AcousticThreshold(
            minSeconds: 0.450,
            targetSeconds: 0.600,
            maxSeconds: 2.000,
          ),
        RecitationSpeed.slow => const AcousticThreshold(
            minSeconds: 0.800,
            targetSeconds: 1.080,
            maxSeconds: 2.500,
          ),
      };
}

/// Base class for Madds at Waqf with variable faces (2, 4, 6 Harakat).
class VariableWaqfMaddRule extends MaddRule {
  const VariableWaqfMaddRule({
    required super.ruleType,
    required super.ruleId,
    required super.goldenLen,
  });

  @override
  AcousticThreshold getThreshold(RecitationSpeed speed) => switch (speed) {
        RecitationSpeed.fast => const AcousticThreshold(
            minSeconds: 0.120,
            targetSeconds: 0.240,
            maxSeconds: 1.800,
          ),
        RecitationSpeed.normal => const AcousticThreshold(
            minSeconds: 0.300,
            targetSeconds: 0.600,
            maxSeconds: 2.200,
          ),
        RecitationSpeed.slow => const AcousticThreshold(
            minSeconds: 0.500,
            targetSeconds: 1.080,
            maxSeconds: 2.500,
          ),
      };
}

/// Aared Madd (المد العارض للسكون)
class AaredMaddRule extends VariableWaqfMaddRule {
  const AaredMaddRule([int harakat = 4])
      : super(
          ruleType: TajweedRuleType.maddAared,
          ruleId: 5,
          goldenLen: harakat,
        );
}

/// Leen Madd (مد اللين)
class LeenMaddRule extends VariableWaqfMaddRule {
  const LeenMaddRule([int harakat = 4])
      : super(
          ruleType: TajweedRuleType.maddLeen,
          ruleId: 7,
          goldenLen: harakat,
        );
}

/// Lazem Madd (المد اللازم) — 6 Harakat
class LazemMaddRule extends MaddRule {
  const LazemMaddRule()
      : super(
          ruleType: TajweedRuleType.maddLazem,
          ruleId: 6,
          goldenLen: 6,
        );

  @override
  AcousticThreshold getThreshold(RecitationSpeed speed) => switch (speed) {
        RecitationSpeed.fast => const AcousticThreshold(
            minSeconds: 0.540,
            targetSeconds: 0.720,
            maxSeconds: 4.000,
          ),
        RecitationSpeed.normal => const AcousticThreshold(
            minSeconds: 0.680,
            targetSeconds: 0.900,
            maxSeconds: 4.000,
          ),
        RecitationSpeed.slow => const AcousticThreshold(
            minSeconds: 0.850,
            targetSeconds: 1.080,
            maxSeconds: 4.500,
          ),
      };
}

// ─────────────────────────────────────────────────────────────────────────────
// 4. Ghunnah, Shaddah, and Qalqalah Rules
// ─────────────────────────────────────────────────────────────────────────────

/// Ghunnah Rule (غنة النون والميم المشددتين) — 2 Harakat
class MushaddadGhunnahRule extends TajweedRule {
  const MushaddadGhunnahRule()
      : super(
          ruleType: TajweedRuleType.ghunnah,
          ruleId: 10,
          goldenLen: 2,
        );

  @override
  AcousticThreshold getThreshold(RecitationSpeed speed) => switch (speed) {
        RecitationSpeed.fast => const AcousticThreshold(
            minSeconds: 0.180,
            targetSeconds: 0.240,
            maxSeconds: 0.850,
          ),
        RecitationSpeed.normal => const AcousticThreshold(
            minSeconds: 0.225,
            targetSeconds: 0.300,
            maxSeconds: 0.850,
          ),
        RecitationSpeed.slow => const AcousticThreshold(
            minSeconds: 0.270,
            targetSeconds: 0.360,
            maxSeconds: 1.600,
          ),
      };
}

/// Shaddah Rule (الشدة / Consonant Closure) — ~1.5 Harakat
class ShaddahRule extends TajweedRule {
  const ShaddahRule()
      : super(
          ruleType: TajweedRuleType.shaddah,
          ruleId: 9,
          goldenLen: 1.5,
        );

  @override
  AcousticThreshold getThreshold(RecitationSpeed speed) => switch (speed) {
        RecitationSpeed.fast => const AcousticThreshold(
            minSeconds: 0.190,
            targetSeconds: 0.240,
            maxSeconds: 0.650,
          ),
        RecitationSpeed.normal => const AcousticThreshold(
            minSeconds: 0.200,
            targetSeconds: 0.250,
            maxSeconds: 0.850,
          ),
        RecitationSpeed.slow => const AcousticThreshold(
            minSeconds: 0.240,
            targetSeconds: 0.300,
            maxSeconds: 1.000,
          ),
      };
}

/// Qalqalah Rule (قلقلة) — Evaluated via neural release burst
class QalqalahRule extends TajweedRule {
  final int level; // 1: sughra, 2: kubra
  const QalqalahRule([this.level = 1])
      : super(
          ruleType: TajweedRuleType.qalqalah,
          ruleId: 8,
          goldenLen: 1,
        );

  @override
  AcousticThreshold getThreshold(RecitationSpeed speed) =>
      const AcousticThreshold(
        minSeconds: 0.040,
        targetSeconds: 0.120,
        maxSeconds: 0.350,
      );
}

// ─────────────────────────────────────────────────────────────────────────────
// 5. Tajweed Rule Factory
// ─────────────────────────────────────────────────────────────────────────────

/// Factory for instantiating and serializing TajweedRule entities deterministically.
class TajweedRuleFactory {
  /// Instantiates a typed TajweedRule from a canonical WordTajweedRule reference entry.
  static TajweedRule instantiate(
    WordTajweedRule wRule, [
    TrackerConfig config = const TrackerConfig(),
  ]) {
    return instantiateFromId(wRule.ruleId, wRule.goldenLen, config);
  }

  /// Instantiates a typed TajweedRule from its numeric ruleId and goldenLen.
  static TajweedRule instantiateFromId(
    int ruleId, [
    num goldenLen = 2,
    TrackerConfig config = const TrackerConfig(),
  ]) {
    final speed = config.recitationSpeed;
    switch (ruleId) {
      case 1:
        return const NormalMaddRule();
      case 2:
        return MonfaselMaddRule(speed.monfaselMaddHarakat);
      case 3:
        return MottaselMaddRule(speed.mottaselMaddHarakat);
      case 4:
        return MottaselMaddPauseRule(speed.mottaselMaddPauseHarakat);
      case 5:
        return AaredMaddRule(speed.aaredMaddHarakat);
      case 6:
        return const LazemMaddRule();
      case 7:
        return LeenMaddRule(speed.leenMaddHarakat);
      case 8:
        return const QalqalahRule();
      case 9:
        return const ShaddahRule();
      case 10:
        return const MushaddadGhunnahRule();
      default:
        return MaddRule(
          ruleType: TajweedRuleType.fromId(ruleId),
          ruleId: ruleId,
          goldenLen: goldenLen,
        );
    }
  }

  /// Serializes a TajweedRule to a pure machine-readable JSON-compatible map.
  static Map<String, dynamic>? toMap(TajweedRule? rule) {
    if (rule == null) return null;
    return {
      'ruleType': rule.ruleType.name,
      'ruleId': rule.ruleId,
      'goldenLen': rule.goldenLen,
    };
  }

  /// Deserializes a TajweedRule from a JSON map.
  static TajweedRule? fromMap(
    Map<String, dynamic>? map, [
    TrackerConfig config = const TrackerConfig(),
  ]) {
    if (map == null) return null;
    final String? rawType = map['ruleType'] as String?;
    final int ruleId = (map['ruleId'] as num?)?.toInt() ??
        TajweedRuleType.fromString(rawType).ruleId;
    final num goldenLen = (map['goldenLen'] as num?) ?? 2;
    return instantiateFromId(ruleId, goldenLen, config);
  }
}

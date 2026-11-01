import 'package:recite_quran/recite_quran.dart';

/// MaglisHighlightStore
///
/// Encapsulates cumulative verse word highlighting, Tajweed error tracking,
/// fast 32-bit bit-packed coordinate keys, and bounded memory pruning for Maglis.
class MaglisHighlightStore {
  // Compact 32-bit integer key: ((surah & 0xFF) << 20) | ((ayah & 0xFFF) << 8) | (word0 & 0xFF)
  static int wordKey(int surah, int ayah, int word0) =>
      ((surah & 0xFF) << 20) | ((ayah & 0xFFF) << 8) | (word0 & 0xFF);

  /// Ultra-compact structured error map for minimum bandwidth over WebRTC.
  /// Pre-rendered human strings are omitted because ReciterError dynamically computes them.
  static Map<String, dynamic> compactErrorMap(ReciterError e) {
    final m = <String, dynamic>{
      'errorType': e.errorType.index,
      'speechErrorType': e.speechErrorType.index,
      'expectedPh': e.expectedPh,
      'predictedPh': e.predictedPh,
    };
    if (e.durationStatus != null) {
      m['durationStatus'] = e.durationStatus!.index;
    }
    if (e.expectedRule != null) {
      m['expectedRule'] = {
        'type': e.expectedRule.runtimeType.toString(),
        'nameAr': e.expectedRule!.name.ar,
        'nameEn': e.expectedRule!.name.en,
        'goldenLen': e.expectedRule!.goldenLen,
      };
    }
    if (e.expectedDuration != null) {
      m['expectedDuration'] =
          double.parse(e.expectedDuration!.toStringAsFixed(2));
    }
    if (e.actualDuration != null) {
      m['actualDuration'] =
          double.parse(e.actualDuration!.toStringAsFixed(2));
    }
    return m;
  }

  // Cumulative session word highlights: key = wordKey(surah, ayah, word0), value = 1 (green), 2 (yellow), 3 (red)
  final Map<int, int> cumulativeHighlights = {};
  int cumulativeVersion = 0;

  // Remote word errors received from peers: key = wordKey(surah, ayah, word0)
  final Map<int, List<ReciterError>> remoteWordErrors = {};

  // Error deduplication: strictly ensure each Tajweed error map is serialized once per verse
  final Set<int> sentErrorWords = <int>{};

  List<ReciterError>? getWordErrors(int surah, int ayah, int word0) =>
      remoteWordErrors[wordKey(surah, ayah, word0)];

  int? getWordHighlight(int surah, int ayah, int word0) =>
      cumulativeHighlights[wordKey(surah, ayah, word0)];

  int? getCumulativeHighlightByKey(int key) => cumulativeHighlights[key];

  bool get hasCumulativeHighlights => cumulativeHighlights.isNotEmpty;

  void recordWordHighlight(int surah, int ayah, int word0, int color) {
    final key = wordKey(surah, ayah, word0);
    if (cumulativeHighlights[key] != color) {
      cumulativeHighlights[key] = color;
      cumulativeVersion++;
    }
  }

  /// Clears cumulative session highlights from [startSurah, startAyah] onwards when recording starts.
  /// Any verse coming before [startSurah, startAyah] strictly keeps its highlights.
  void clearHighlightsFrom(int startSurah, int startAyah) {
    cumulativeHighlights.removeWhere((key, _) {
      final s = (key >> 20) & 0xFF;
      final a = (key >> 8) & 0xFFF;
      return s > startSurah || (s == startSurah && a >= startAyah);
    });
    remoteWordErrors.removeWhere((key, _) {
      final s = (key >> 20) & 0xFF;
      final a = (key >> 8) & 0xFFF;
      return s > startSurah || (s == startSurah && a >= startAyah);
    });
    sentErrorWords.clear();
    cumulativeVersion++;
  }

  /// Merges incoming cumulative map (hex or string-formatted) from remote peer packets.
  bool mergeCumulative(Map<String, int> cumulative) {
    bool changed = false;
    cumulative.forEach((k, v) {
      final parsed = int.tryParse(k, radix: 16);
      if (parsed != null) {
        if (cumulativeHighlights[parsed] != v) {
          cumulativeHighlights[parsed] = v;
          changed = true;
        }
      } else if (k.contains('_')) {
        final parts = k.split('_');
        if (parts.length == 3) {
          final s = int.tryParse(parts[0]);
          final a = int.tryParse(parts[1]);
          final w = int.tryParse(parts[2]);
          if (s != null && a != null && w != null) {
            final key = wordKey(s, a, w);
            if (cumulativeHighlights[key] != v) {
              cumulativeHighlights[key] = v;
              changed = true;
            }
          }
        }
      }
    });
    if (changed) {
      cumulativeVersion++;
    }
    return changed;
  }

  /// Merges incoming live word colors from packet.
  bool mergeWords(
    int surah,
    int ayah, {
    required List<int> greenWords,
    required List<int> yellowWords,
    required List<int> redWords,
  }) {
    bool changed = false;
    for (final w in greenWords) {
      final key = wordKey(surah, ayah, w);
      if (cumulativeHighlights[key] != 1) {
        cumulativeHighlights[key] = 1;
        changed = true;
      }
      remoteWordErrors.remove(key);
    }
    for (final w in yellowWords) {
      final key = wordKey(surah, ayah, w);
      if (cumulativeHighlights[key] != 2) {
        cumulativeHighlights[key] = 2;
        changed = true;
      }
    }
    for (final w in redWords) {
      final key = wordKey(surah, ayah, w);
      if (cumulativeHighlights[key] != 3) {
        cumulativeHighlights[key] = 3;
        changed = true;
      }
    }
    if (changed) {
      cumulativeVersion++;
    }
    return changed;
  }

  /// Merges incoming errors and applies memory-bounding protection.
  void mergeErrors(
    int surah,
    int ayah,
    Map<String, List<Map<String, dynamic>>> errors,
  ) {
    errors.forEach((k, list) {
      int? key = int.tryParse(k, radix: 16);
      if (key == null) {
        final w0 = int.tryParse(k);
        if (w0 != null) key = wordKey(surah, ayah, w0);
      }
      if (key != null) {
        remoteWordErrors[key] = list
            .map((m) => ReciterError.fromMap(m))
            .toList();
      }
    });

    // Memory protection: prune oldest errors if session spans many pages (>250 verses)
    if (remoteWordErrors.length > 250) {
      final removeCount = remoteWordErrors.length - 200;
      final keysToRemove = remoteWordErrors.keys.take(removeCount).toList();
      for (final k in keysToRemove) {
        remoteWordErrors.remove(k);
      }
    }
  }

  /// Records local recitation errors into word error map for symmetrical lookup.
  void recordLocalErrors(
    int surah,
    int ayah,
    Map<int, List<ReciterError>> errors,
  ) {
    errors.forEach((w0, errList) {
      final key = wordKey(surah, ayah, w0);
      remoteWordErrors[key] = errList;
    });
  }

  /// Serializes active errors strictly once per word to achieve minimum packet size.
  Map<String, List<Map<String, dynamic>>>? serializeNewErrors(
    int surah,
    int ayah,
    Map<int, List<ReciterError>>? errors,
  ) {
    if (errors == null || errors.isEmpty) return null;
    Map<String, List<Map<String, dynamic>>>? serializedErrors;
    for (final entry in errors.entries) {
      if (sentErrorWords.add(entry.key)) {
        final key = wordKey(surah, ayah, entry.key);
        (serializedErrors ??= {})[key.toRadixString(16)] =
            entry.value.map((e) => compactErrorMap(e)).toList();
      }
    }
    return serializedErrors;
  }

  /// Builds radix-16 string snapshot of cumulative highlights.
  Map<String, int> buildSnapshotCumulativeMap() {
    final stringMap = <String, int>{};
    cumulativeHighlights.forEach((k, v) {
      stringMap[k.toRadixString(16)] = v;
    });
    return stringMap;
  }

  /// Builds radix-16 serialized snapshot of remote word errors.
  Map<String, List<Map<String, dynamic>>>? buildSnapshotErrorsMap() {
    if (remoteWordErrors.isEmpty) return null;
    final snapshotErrors = <String, List<Map<String, dynamic>>>{};
    remoteWordErrors.forEach((key, list) {
      snapshotErrors[key.toRadixString(16)] =
          list.map((e) => compactErrorMap(e)).toList();
    });
    return snapshotErrors;
  }

  /// Builds error map for a specific verse during recitation update.
  Map<String, List<Map<String, dynamic>>>? buildVerseErrorsMap(
    int surah,
    int ayah,
  ) {
    if (remoteWordErrors.isEmpty) return null;
    Map<String, List<Map<String, dynamic>>>? currentVerseErrors;
    remoteWordErrors.forEach((key, list) {
      final s = (key >> 20) & 0xFF;
      final a = (key >> 8) & 0xFFF;
      if (s == surah && a == ayah) {
        (currentVerseErrors ??= {})[key.toRadixString(16)] =
            list.map((e) => compactErrorMap(e)).toList();
      }
    });
    return currentVerseErrors;
  }

  /// Resets all highlights, errors, and versions on session termination.
  void clearAll() {
    cumulativeHighlights.clear();
    cumulativeVersion = 0;
    remoteWordErrors.clear();
    sentErrorWords.clear();
  }
}

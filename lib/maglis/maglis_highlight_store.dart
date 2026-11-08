import 'dart:typed_data';
import '../state/highlighting_controller.dart';
import '../mushaf/mushaf_provider.dart';

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

  // Page-scoped cumulative versions to prevent offscreen Mushaf pages from re-evaluating
  final Map<int, int> _pageCumulativeVersions = <int, int>{};

  int getPageCumulativeVersion(int page) =>
      _pageCumulativeVersions[page] ?? 0;

  void _bumpPageVersion(int surah, int ayah) {
    final page = MushafProvider.instance.getPageForAyah(surah, ayah);
    if (page != null) {
      _pageCumulativeVersions[page] = (_pageCumulativeVersions[page] ?? 0) + 1;
    }
  }

  // Remote word errors received from peers: key = wordKey(surah, ayah, word0)
  final Map<int, List<ReciterError>> remoteWordErrors = {};

  // Error deduplication: strictly ensure each Tajweed error map is serialized once per unique (surah, ayah, word0) key
  // Value stores a lightweight signature (error count + first error type) so if a word's error list is updated, it re-transmits.
  final Set<int> sentErrorWords = <int>{};
  final Map<int, int> _sentErrorSignatures = <int, int>{};

  List<ReciterError>? getWordErrors(int surah, int ayah, int word0) =>
      remoteWordErrors[wordKey(surah, ayah, word0)];

  int? getWordHighlight(int surah, int ayah, int word0) =>
      cumulativeHighlights[wordKey(surah, ayah, word0)];

  int? getCumulativeHighlightByKey(int key) => cumulativeHighlights[key];

  bool get hasCumulativeHighlights => cumulativeHighlights.isNotEmpty;


  /// Clears cumulative session highlights from [startSurah, startAyah] onwards when recording starts.
  /// Any verse coming before [startSurah, startAyah] strictly keeps its highlights.
  void clearHighlightsFrom(int startSurah, int startAyah) {
    final affectedPages = <int>{};
    cumulativeHighlights.removeWhere((key, _) {
      final s = (key >> 20) & 0xFF;
      final a = (key >> 8) & 0xFFF;
      final matches = s > startSurah || (s == startSurah && a >= startAyah);
      if (matches) {
        final p = MushafProvider.instance.getPageForAyah(s, a);
        if (p != null) affectedPages.add(p);
      }
      return matches;
    });
    remoteWordErrors.removeWhere((key, _) {
      final s = (key >> 20) & 0xFF;
      final a = (key >> 8) & 0xFFF;
      final matches = s > startSurah || (s == startSurah && a >= startAyah);
      if (matches) {
        final p = MushafProvider.instance.getPageForAyah(s, a);
        if (p != null) affectedPages.add(p);
      }
      return matches;
    });
    sentErrorWords.clear();
    _sentErrorSignatures.clear();
    for (final p in affectedPages) {
      _pageCumulativeVersions[p] = (_pageCumulativeVersions[p] ?? 0) + 1;
    }
    cumulativeVersion++;
  }

  /// Merges incoming cumulative map (hex or string-formatted) from remote peer packets.
  bool mergeCumulative(Map<String, int> cumulative) {
    bool changed = false;
    cumulative.forEach((k, v) {
      if (v < 1 || v > 3) return;
      final parsed = int.tryParse(k, radix: 16);
      if (parsed != null) {
        if (cumulativeHighlights[parsed] != v) {
          cumulativeHighlights[parsed] = v;
          changed = true;
          final s = (parsed >> 20) & 0xFF;
          final a = (parsed >> 8) & 0xFFF;
          _bumpPageVersion(s, a);
        }
        if (v == 1) {
          remoteWordErrors.remove(parsed);
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
              _bumpPageVersion(s, a);
            }
            if (v == 1) {
              remoteWordErrors.remove(key);
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
      sentErrorWords.remove(key);
      _sentErrorSignatures.remove(key);
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
      _bumpPageVersion(surah, ayah);
    }
    return changed;
  }

  void _pruneErrorsIfNeeded() {
    // Memory protection: prune oldest errors if session spans many pages (>250 word entries)
    if (remoteWordErrors.length > 250) {
      final removeCount = remoteWordErrors.length - 200;
      final keysToRemove = remoteWordErrors.keys.take(removeCount).toList();
      for (final k in keysToRemove) {
        remoteWordErrors.remove(k);
        sentErrorWords.remove(k);
        _sentErrorSignatures.remove(k);
      }
    }
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
        remoteWordErrors[key] =
            list.map((m) => ReciterError.fromMap(m)).toList();
      }
    });

    _pruneErrorsIfNeeded();
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

    _pruneErrorsIfNeeded();
  }

  static int _computeErrorListSignature(List<ReciterError> list) {
    int hash = list.length;
    for (final e in list) {
      hash = ((hash * 31) ^
              e.errorType.index ^
              (e.speechErrorType.index << 4) ^
              (e.durationStatus?.index ?? 0)) &
          0x3FFFFFFF;
    }
    return hash;
  }

  /// Serializes active errors strictly once per unique (surah, ayah, word0) state
  /// to achieve minimum packet size while still propagating updated error details.
  Map<String, List<Map<String, dynamic>>>? serializeNewErrors(
    int surah,
    int ayah,
    Map<int, List<ReciterError>>? errors,
  ) {
    if (errors == null || errors.isEmpty) return null;
    Map<String, List<Map<String, dynamic>>>? serializedErrors;
    for (final entry
        in List<MapEntry<int, List<ReciterError>>>.from(errors.entries)) {
      if (entry.value.isEmpty) continue;
      final key = wordKey(surah, ayah, entry.key);
      final sig = _computeErrorListSignature(entry.value);
      final isFirstSend = sentErrorWords.add(key);
      final prevSig = _sentErrorSignatures[key];
      if (isFirstSend || (prevSig != null && prevSig != sig)) {
        _sentErrorSignatures[key] = sig;
        (serializedErrors ??= {})[key.toRadixString(16)] =
            entry.value.map((e) => compactErrorMap(e)).toList();
      }
    }
    return serializedErrors;
  }

  /// Builds radix-16 string snapshot of cumulative highlights.
  Map<String, int> buildSnapshotCumulativeMap() {
    final stringMap = <String, int>{};
    for (final entry
        in List<MapEntry<int, int>>.from(cumulativeHighlights.entries)) {
      stringMap[entry.key.toRadixString(16)] = entry.value;
    }
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

  /// Encodes word highlight states (0=none, 1=green, 2=yellow, 3=red) for [surah, ayah]
  /// into a compact byte vector (4 words per byte, 2 bits per word).
  /// Slashes transmission bandwidth by ~85% compared to JSON/Radix maps.
  Uint8List encodeAyahHighlightVector(int surah, int ayah, int totalWords) {
    if (totalWords <= 0) return Uint8List(0);
    final byteLen = (totalWords + 3) >> 2;
    final bytes = Uint8List(byteLen);

    for (int w = 0; w < totalWords; w++) {
      final color = getWordHighlight(surah, ayah, w) ?? 0;
      if (color > 0 && color <= 3) {
        final byteIndex = w >> 2;
        final bitOffset = (w & 3) << 1;
        bytes[byteIndex] |= (color << bitOffset);
      }
    }
    return bytes;
  }

  /// Decodes a compact 2-bit-per-word byte vector and merges highlights into the store.
  bool decodeAndMergeAyahHighlightVector(
    int surah,
    int ayah,
    Uint8List vector,
    int totalWords,
  ) {
    bool changed = false;
    for (int w = 0; w < totalWords; w++) {
      final byteIndex = w >> 2;
      if (byteIndex >= vector.length) break;
      final bitOffset = (w & 3) << 1;
      final color = (vector[byteIndex] >> bitOffset) & 0x03;
      if (color > 0) {
        final key = wordKey(surah, ayah, w);
        if (cumulativeHighlights[key] != color) {
          cumulativeHighlights[key] = color;
          changed = true;
        }
        if (color == 1) {
          remoteWordErrors.remove(key);
        }
      }
    }
    if (changed) {
      cumulativeVersion++;
      _bumpPageVersion(surah, ayah);
    }
    return changed;
  }

  /// Resets all highlights, errors, and versions on session termination.
  void clearAll() {
    cumulativeHighlights.clear();
    cumulativeVersion = 0;
    _pageCumulativeVersions.clear();
    remoteWordErrors.clear();
    sentErrorWords.clear();
    _sentErrorSignatures.clear();
  }
}
import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../../data/reference_reader.dart';
import 'fuzzy_search.dart';

class _SearchArgs {
  final String normQuery;
  final String refPhNorm;
  final int maxEdits;
  _SearchArgs(this.normQuery, this.refPhNorm, this.maxEdits);
}

List<FuzzyMatch> _runSearchIsolated(_SearchArgs args) {
  return findNearMatches(args.normQuery, args.refPhNorm, args.maxEdits);
}

/// Long-lived background Isolate worker for zero-serialization fuzzy phonetic searches.
/// Holds the 623k reference string in isolate memory once at startup, eliminating
/// high GC and SendPort string copying on every real-time ASR chunk.
class _PhoneticIsolateWorker {
  Isolate? _isolate;
  SendPort? _sendPort;
  ReceivePort? _responsePort;
  int _requestId = 0;
  final Map<int, Completer<List<FuzzyMatch>>> _pendingRequests = {};
  bool _isReady = false;

  bool get isReady => _isReady;

  Future<void> start(String refPhNorm) async {
    if (_isReady) return;
    if (kIsWeb) return;

    try {
      final initPort = ReceivePort();
      _responsePort = ReceivePort();

      _isolate = await Isolate.spawn(
        _phoneticWorkerEntrypoint,
        [initPort.sendPort, _responsePort!.sendPort, refPhNorm],
      );

      _sendPort = await initPort.first as SendPort;
      initPort.close();

      _responsePort!.listen((message) {
        if (message is List && message.length == 2) {
          final int reqId = message[0] as int;
          final List<FuzzyMatch> matches = message[1] as List<FuzzyMatch>;
          final completer = _pendingRequests.remove(reqId);
          completer?.complete(matches);
        }
      });

      _isReady = true;
    } catch (_) {
      _isReady = false;
    }
  }

  Future<List<FuzzyMatch>> search(String query, int maxEdits) {
    if (!_isReady || _sendPort == null) {
      return Future.value(const []);
    }
    final int reqId = ++_requestId;
    final completer = Completer<List<FuzzyMatch>>();
    _pendingRequests[reqId] = completer;
    _sendPort!.send([reqId, query, maxEdits]);
    return completer.future.timeout(
      const Duration(milliseconds: 1500),
      onTimeout: () => const [],
    );
  }

  void dispose() {
    _isReady = false;
    for (final c in _pendingRequests.values) {
      if (!c.isCompleted) c.complete(const []);
    }
    _pendingRequests.clear();
    _responsePort?.close();
    _responsePort = null;
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _sendPort = null;
  }
}

void _phoneticWorkerEntrypoint(List<dynamic> args) {
  final SendPort initSendPort = args[0] as SendPort;
  final SendPort responseSendPort = args[1] as SendPort;
  final String refPhNorm = args[2] as String;

  final commandPort = ReceivePort();
  initSendPort.send(commandPort.sendPort);

  commandPort.listen((message) {
    if (message is List && message.length == 3) {
      final int reqId = message[0] as int;
      final String normQuery = message[1] as String;
      final int maxEdits = message[2] as int;

      try {
        final List<FuzzyMatch> matches =
            findNearMatches(normQuery, refPhNorm, maxEdits);
        responseSendPort.send([reqId, matches]);
      } catch (_) {
        responseSendPort.send([reqId, <FuzzyMatch>[]]);
      }
    }
  });
}

class PhonemesSearchSpan {
  final int surahIdx;
  final int ayahIdx;
  final int uthmaniWordIdx;
  final int uthmaniCharIdx;
  final int phonemesIdx;

  PhonemesSearchSpan({
    required this.surahIdx,
    required this.ayahIdx,
    required this.uthmaniWordIdx,
    required this.uthmaniCharIdx,
    required this.phonemesIdx,
  });

  @override
  String toString() {
    return 'PhonemesSearchSpan(surah: $surahIdx, ayah: $ayahIdx, word: $uthmaniWordIdx, char: $uthmaniCharIdx, ph: $phonemesIdx)';
  }
}

class PhonemesSearchResult {
  final PhonemesSearchSpan start;
  final PhonemesSearchSpan end;
  final PhonemesSearchSpan mid;
  final int distance;

  PhonemesSearchResult({
    required this.start,
    required this.end,
    required this.mid,
    required this.distance,
  });

  @override
  String toString() {
    return 'PhonemesSearchResult(start: $start, mid: $mid, end: $end)';
  }
}

class PhoneticSearch {
  late Uint16List _indexArray;
  late String _refPhNorm;
  bool _isLoaded = false;
  final _PhoneticIsolateWorker _worker = _PhoneticIsolateWorker();

  /// Whether a reference dataset has been loaded into this instance.
  bool get isLoaded => _isLoaded;

  /// Loads the index and reference string directly from the TajweedFormer V4 engine reference table (expected_tj3.zfx).
  ///
  /// Zero external NPY or TXT assets: derives the continuous phoneme reference
  /// and coordinate index dynamically from [referenceReader] (if provided) or
  /// loads expected_tj3.zfx from disk / bundled assets.
  Future<void> load({
    TajweedFormerReferenceReader? referenceReader,
    String? zfxFilePath,
  }) async {
    if (_isLoaded) return;

    final TajweedFormerReferenceReader reader;
    if (referenceReader != null) {
      reader = referenceReader;
    } else {
      final Uint8List bytes;
      if (zfxFilePath != null) {
        final file = File(zfxFilePath);
        if (!kIsWeb && file.existsSync()) {
          bytes = await file.readAsBytes();
        } else {
          final data = await rootBundle.load(zfxFilePath);
          bytes = data.buffer.asUint8List(
            data.offsetInBytes,
            data.lengthInBytes,
          );
        }
      } else {
        File? localFile;
        if (!kIsWeb) {
          try {
            final appDir = await getApplicationDocumentsDirectory();
            final f = File('${appDir.path}/model/expected_tj3.zfx');
            if (f.existsSync()) localFile = f;
          } catch (_) {}
        }

        if (localFile != null) {
          bytes = await localFile.readAsBytes();
        } else {
          final data = await rootBundle.load('assets/model/expected_tj3.zfx');
          bytes = data.buffer.asUint8List(
            data.offsetInBytes,
            data.lengthInBytes,
          );
        }
      }
      reader = TajweedFormerReferenceReader.fromBytes(bytes);
    }

    final index = reader.getGlobalPhoneticSearchIndex();
    _refPhNorm = index.refPhNorm;
    _indexArray = index.indexArray;
    _isLoaded = true;

    _worker.start(_refPhNorm);
  }

  /// Synchronously initializes from in-memory phoneme string and coordinate array.
  void loadSync({required String refPhNorm, required Uint16List indexArray}) {
    if (_isLoaded) return;
    _refPhNorm = refPhNorm.trim();
    _indexArray = indexArray;
    _isLoaded = true;
    _worker.start(_refPhNorm);
  }

  static const String _coreChars = "ءبتثجحخدذرزسشصضطظعغفقكلمنهويںaiu";

  static final Uint8List _isCoreCode = () {
    final arr = Uint8List(2048);
    for (int i = 0; i < _coreChars.length; i++) {
      final code = _coreChars.codeUnitAt(i);
      if (code < 2048) arr[code] = 1;
    }
    return arr;
  }();

  static bool _isVowel(int code) =>
      code == 0x61 || code == 0x69 || code == 0x75; // 'a', 'i', 'u'

  /// Normalizes a phoneme string for fast Myers bit-parallel search (identical to detector.py).
  /// Preserves vowels ('a', 'i', 'u') and Madd doubles ('aa', 'ii', 'uu'),
  /// while collapsing adjacent identical consonants.
  static String normalizeQuery(String query) {
    if (query.isEmpty) return '';
    final StringBuffer parts = StringBuffer();
    int prevCode = -1;
    int prevPrevCode = -1;

    for (int i = 0; i < query.length; i++) {
      final int code = query.codeUnitAt(i);
      if (code < 2048 && _isCoreCode[code] == 1) {
        if (_isVowel(code)) {
          // Allow up to double vowels for Madd ('aa', 'ii', 'uu')
          if (prevCode == code && prevPrevCode == code) {
            continue;
          }
          parts.writeCharCode(code);
          prevPrevCode = prevCode;
          prevCode = code;
        } else {
          // Collapse repeated consonants
          if (code != prevCode) {
            parts.writeCharCode(code);
            prevPrevCode = prevCode;
            prevCode = code;
          }
        }
      }
    }
    return parts.toString();
  }

  PhonemesSearchSpan _refIdxToSpan(int refIdx, {bool isEnd = false}) {
    if (refIdx < 0 || refIdx >= _refPhNorm.length) {
      throw RangeError("Reference index $refIdx out of range");
    }

    // Each row in _indexArray has 3 elements:
    // 0: surah
    // 1: ayah
    // 2: word_in_ayah
    final int rowOffset = refIdx * 3;

    return PhonemesSearchSpan(
      surahIdx: _indexArray[rowOffset + 0],
      ayahIdx: _indexArray[rowOffset + 1],
      uthmaniWordIdx: _indexArray[rowOffset + 2],
      uthmaniCharIdx: 0,
      phonemesIdx: refIdx,
    );
  }

  /// Searches for the query with a max allowed error ratio (e.g., 0.1 for 10% errors).
  List<PhonemesSearchResult> search(String query, {double errorRatio = 0.1}) {
    if (!_isLoaded) {
      throw Exception("PhoneticSearch must be loaded before searching");
    }

    String normQuery = normalizeQuery(query);
    if (normQuery.isEmpty) return [];

    int maxEdits = (normQuery.length * errorRatio).toInt();

    // Use our fuzzy_search algorithm
    List<FuzzyMatch> outs = findNearMatches(normQuery, _refPhNorm, maxEdits);

    if (outs.isEmpty) {
      return [];
    }

    List<PhonemesSearchResult> results = [];
    for (var out in outs) {
      results.add(
        PhonemesSearchResult(
          start: _refIdxToSpan(out.start, isEnd: false),
          end: _refIdxToSpan(out.end - 1, isEnd: true),
          mid: _refIdxToSpan((out.start + out.end - 1) ~/ 2, isEnd: false),
          distance: out.dist,
        ),
      );
    }

    // Sort by distance (best matches first) to align with python reference implementation
    results.sort((a, b) => a.distance.compareTo(b.distance));

    return results;
  }

  /// Searches for the query asynchronously on a background isolate to prevent UI freezes.
  Future<List<PhonemesSearchResult>> searchIsolated(String query,
      {double errorRatio = 0.1}) async {
    if (!_isLoaded) {
      throw Exception("PhoneticSearch must be loaded before searching");
    }

    String normQuery = normalizeQuery(query);
    if (normQuery.isEmpty) return [];

    int maxEdits = (normQuery.length * errorRatio).toInt();

    // Use persistent background isolate worker; fallback gracefully to compute if not yet ready
    List<FuzzyMatch> outs;
    if (_worker.isReady) {
      outs = await _worker.search(normQuery, maxEdits);
    } else {
      outs = await compute(
        _runSearchIsolated,
        _SearchArgs(normQuery, _refPhNorm, maxEdits),
      );
    }

    if (outs.isEmpty) {
      return [];
    }

    List<PhonemesSearchResult> results = [];
    for (var out in outs) {
      results.add(
        PhonemesSearchResult(
          start: _refIdxToSpan(out.start, isEnd: false),
          end: _refIdxToSpan(out.end - 1, isEnd: true),
          mid: _refIdxToSpan((out.start + out.end - 1) ~/ 2, isEnd: false),
          distance: out.dist,
        ),
      );
    }

    // Sort by distance (best matches first) to align with python reference implementation
    results.sort((a, b) => a.distance.compareTo(b.distance));

    return results;
  }

  /// Disposes background worker isolate resources.
  void dispose() {
    _worker.dispose();
  }
}

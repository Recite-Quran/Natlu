// lib/engine/tajweedformer_v4/tajweedformer_engine_io.dart
// Native IO implementation of TajweedFormerEngine using Dart FFI in a background Isolate.

import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../../utils/debug_logger.dart';
import '../core/recite_engine.dart';
import '../core/tajweed_diagnostics.dart';
import '../core/transcription_result.dart';
import 'tajweedformer_protocol.dart';
import 'zf_tajweed_bindings.dart';

class TajweedFormerEngine implements ReciteEngine {
  TajweedFormerEngine({
    this.modelDirOverride,
    this.contextProfile = 'c16_l64',
    this.customLibPath,
    this.webApiKey,
  });

  final String? modelDirOverride;
  final String contextProfile;
  final String? customLibPath;
  final String? webApiKey;

  Isolate? _isolate;
  SendPort? _sendPort;
  ReceivePort? _receivePort;

  final StreamController<TranscriptionResult> _outputController =
      StreamController<TranscriptionResult>.broadcast();
  final StreamController<TajweedDiagnostics> _diagnosticsController =
      StreamController<TajweedDiagnostics>.broadcast();

  bool _isInitialized = false;
  Future<void>? _initFuture;
  final List<TajweedFormerCommand> _pendingChunks = [];
  int _currentStreamEpoch = 0;

  @override
  bool get isInitialized => _isInitialized;

  @override
  int get currentStreamEpoch => _currentStreamEpoch;

  @override
  Stream<TranscriptionResult> get transcriptionStream =>
      _outputController.stream;

  @override
  Stream<TajweedDiagnostics>? get diagnosticsStream =>
      _diagnosticsController.stream;

  @override
  Future<bool> isModelCached() async {
    try {
      final String dirPath =
          modelDirOverride ?? await _resolveDefaultModelDir();
      final dir = Directory(dirPath);
      final layersFile = File('${dir.path}/layers.zfw');
      if (layersFile.existsSync() && layersFile.lengthSync() > 1000000) {
        return true;
      }
      try {
        final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
        return manifest.listAssets().any((k) => k.startsWith('assets/model/'));
      } catch (_) {
        return false;
      }
    } catch (_) {
      return false;
    }
  }

  Future<void> _ensureBundledAssetsExtracted(String targetDir) async {
    final layersFile = File('$targetDir/layers.zfw');
    if (layersFile.existsSync() && layersFile.lengthSync() > 1000000) {
      return;
    }

    try {
      final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
      final modelAssets = manifest
          .listAssets()
          .where((k) => k.startsWith('assets/model/'))
          .toList();

      if (modelAssets.isEmpty) {
        throw StateError(
          'TajweedFormer: No assets found under assets/model/ in asset manifest!',
        );
      }

      final dir = Directory(targetDir);
      if (!dir.existsSync()) dir.createSync(recursive: true);

      for (final assetKey in modelAssets) {
        final relativePath = assetKey.substring('assets/model/'.length);
        if (relativePath.isEmpty) continue;
        final targetFile = File('$targetDir/$relativePath');
        final targetParent = targetFile.parent;
        if (!targetParent.existsSync()) {
          targetParent.createSync(recursive: true);
        }
        final byteData = await rootBundle.load(assetKey);
        final bytes = byteData.buffer.asUint8List(
          byteData.offsetInBytes,
          byteData.lengthInBytes,
        );
        await targetFile.writeAsBytes(bytes, flush: true);
      }
    } catch (e) {
      DebugLogger.logSimple('TajweedFormer', '❌ Extraction error: $e');
      rethrow;
    }
  }

  @override
  Future<void> initialize() {
    if (_isInitialized) return Future.value();
    if (_initFuture != null) return _initFuture!;
    _initFuture = _doInitialize();
    return _initFuture!;
  }

  Future<void> _doInitialize() async {
    _currentStreamEpoch = 0;
    if (_isolate != null) {
      if (_sendPort != null) {
        _sendPort!.send(const TajweedFormerDestroyCommand());
        await Future.delayed(const Duration(milliseconds: 100));
      }
      _isolate?.kill(priority: Isolate.immediate);
    }
    _receivePort?.close();
    _receivePort = null;
    _sendPort = null;

    final String resolvedModelDir =
        modelDirOverride ?? await _resolveDefaultModelDir();
    await _ensureBundledAssetsExtracted(resolvedModelDir);

    final completer = Completer<void>();
    _receivePort = ReceivePort();

    _receivePort!.listen((message) {
      if (message is SendPort) {
        _sendPort = message;
        _sendPort!.send(
          TajweedFormerInitCommand(
            modelDir: resolvedModelDir,
            context: contextProfile,
            customLibPath: customLibPath,
          ),
        );
      } else if (message is TajweedFormerInitSuccessEvent) {
        _isInitialized = true;
        _initFuture = null;
        completer.complete();
        for (final pending in _pendingChunks) {
          _sendPort?.send(pending);
        }
        _pendingChunks.clear();
      } else if (message is TajweedFormerInitErrorEvent) {
        _initFuture = null;
        completer.completeError(Exception(message.error));
      } else if (message is TajweedFormerTranscriptionEvent) {
        _outputController.add(
          TranscriptionResult(
            text: message.text,
            isFinal: message.isFinal,
            startTime: message.startTime,
            tokens: message.tokens,
            timestamps: message.timestamps,
            durations: message.durations,
            neuralAcoustics: message.neuralAcoustics,
            streamEpoch: message.streamEpoch,
          ),
        );
      } else if (message is TajweedFormerDiagnosticsEvent) {
        _diagnosticsController.add(
          TajweedDiagnostics(
            timestamp: message.timestamp,
            geminationProb: message.geminationProb,
            qalqalahProbs: message.qalqalahProbs,
            ghunnaProbs: message.ghunnaProbs,
            tafkheemProbs: message.tafkheemProbs,
            faceProbs: message.faceProbs,
          ),
        );
      }
    });

    _isolate = await Isolate.spawn(_isolateEntry, _receivePort!.sendPort);
    await completer.future;
  }

  Future<String> _resolveDefaultModelDir() async {
    if (!kIsWeb &&
        (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
      try {
        final exeDir = File(Platform.resolvedExecutable).parent.path;
        final bundledDir =
            Directory('$exeDir/data/flutter_assets/assets/model');
        if (bundledDir.existsSync() &&
            File('${bundledDir.path}/layers.zfw').existsSync()) {
          return bundledDir.path;
        }
      } catch (_) {}
    }

    final appDir = await getApplicationDocumentsDirectory();
    final dir = Directory('${appDir.path}/model');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir.path;
  }

  @override
  bool transcribe(Float32List audioChunk, {bool isFinal = false}) {
    final transferable = TransferableTypedData.fromList([audioChunk]);
    final cmd = TajweedFormerRecognizeCommand(
      chunk: transferable,
      isFinal: isFinal,
      startTime: DateTime.now().millisecondsSinceEpoch,
    );

    if (!_isInitialized) {
      if (_initFuture != null) {
        _pendingChunks.add(cmd);
      }
      return true;
    }

    _sendPort?.send(cmd);
    return true;
  }

  @override
  void resetBuffer() {
    if (!_isInitialized) return;
    _currentStreamEpoch++;
    _pendingChunks.clear();
    _sendPort?.send(const TajweedFormerResetCommand());
  }

  @override
  void flushThenReset() {
    if (!_isInitialized) return;
    _currentStreamEpoch++;
    _pendingChunks.clear();
    _sendPort?.send(const TajweedFormerFlushCommand());
  }

  @override
  void destroy() {
    if (!_isInitialized && _isolate == null) return;
    _isInitialized = false;
    _initFuture = null;
    _pendingChunks.clear();
    _sendPort?.send(const TajweedFormerDestroyCommand());
    Future.delayed(const Duration(milliseconds: 200), () {
      _isolate?.kill(priority: Isolate.immediate);
      _receivePort?.close();
      _isolate = null;
      _sendPort = null;
      _receivePort = null;
      if (!_outputController.isClosed) {
        _outputController.close();
      }
      if (!_diagnosticsController.isClosed) {
        _diagnosticsController.close();
      }
    });
  }

  // ─── Isolate Worker ────────────────────────────────────────────────────────
  static void _isolateEntry(SendPort mainSendPort) {
    final ReceivePort port = ReceivePort();
    mainSendPort.send(port.sendPort);

    ZfTajweedBindings? bindings;
    Pointer<Void>? model;
    Pointer<Void>? stream;
    int isolateStreamEpoch = 0;

    const int maxTokens = 512;
    final Pointer<Int32> idsBuf = calloc<Int32>(maxTokens);
    final Pointer<ZfTajweedHeads> headsPtr = calloc<ZfTajweedHeads>();
    final Pointer<Pointer<ZfTajweedTop2>> top2OutPtr =
        calloc<Pointer<ZfTajweedTop2>>();
    final List<String> tokenCache = [];

    // Reusable audio sample buffer to prevent memory churn during continuous streaming
    int audioBufCap = 4096;
    Pointer<Float> audioBuf = calloc<Float>(audioBufCap);

    /// The heads the app actually reads: CTC log-probs for normal tokens,
    /// 20 ms timing and identity heads for held tokens (Madd, Ghunnah, Shaddah),
    /// neural release burst for Qalqalah, and token confidence.
    const int appHeads = ZfTajweedHeadsFlags.logProbs |
        ZfTajweedHeadsFlags.timing |
        ZfTajweedHeadsFlags.id |
        ZfTajweedHeadsFlags.inter4 |
        ZfTajweedHeadsFlags.qalqalah |
        ZfTajweedHeadsFlags.conf;

    /// Decodes the whole take so far exactly as the author's decoder does:
    /// a token is one run of equal top-1 40 ms frames `[t, e]`, covering the
    /// 20 ms head frames `[2t, 2e + 2)`. The token end is `(e + 1) * 40 ms`,
    /// confidence is the mean sigmoid(conf) over that span, gemination is the
    /// mean `gem[:, 1]` over that span, and qalqalah is the mean
    /// `attr_qalqalah[:, 1] + attr_qalqalah[:, 2]` over the 12 frames after
    /// the letter's end.
    TajweedFormerTranscriptionEvent? decodeTake({
      required bool isFinal,
      required int startTime,
      required int epoch,
    }) {
      final ZfTajweedBindings? b = bindings;
      final Pointer<Void>? s = stream;
      if (b == null || s == null || s == nullptr) return null;

      final int headsRet = b.streamHeads(s, headsPtr);
      final int nFrames = b.streamTop2(s, top2OutPtr);

      final List<String> tokenStrings = [];
      final List<double> timestamps = [];
      final List<double> tokenDurations = [];
      final List<TokenNeuralAcoustics> tokenAcoustics = [];

      if (nFrames > 0 && top2OutPtr.value != nullptr) {
        final Pointer<ZfTajweedTop2> top2 = top2OutPtr.value;
        final int n20 = headsRet >= 0 ? headsPtr.ref.n20 : 0;
        final Pointer<Float> timing = headsPtr.ref.timingLogProbs;
        final Pointer<Float> idProbs = headsPtr.ref.idLogProbs;
        final Pointer<Float> inter4Probs = headsPtr.ref.inter4LogProbs;
        final Pointer<Float> qalqalah = headsPtr.ref.attrQalqalah;
        final Pointer<Float> conf = headsPtr.ref.conf;

        for (int t = 0; t < nFrames;) {
          final int a = top2[t].token;
          if (a == zfTajweedBlank) {
            t++;
            continue;
          }
          int e = t;
          while (e + 1 < nFrames && top2[e + 1].token == a) {
            e++;
          }

          final int start20 = 2 * t;
          int end20 = 2 * (e + 1);

          // Held tokens (Madd, Ghunnah, Shaddah) depend on timing_log_probs and id_log_probs
          // (plus inter4_log_probs) to measure the true acoustic holding span across 20 ms frames:
          if (timing != nullptr && n20 > 0) {
            int holdLimit = end20;
            int gapCount = 0;
            const int gapTolerance = 4; // tolerate up to 4 frames (80 ms) for vocal tract closure/transition

            for (int f = start20; f < n20; f++) {
              final int offset = f * zfTajweedVocab;

              // Argmax from timing_log_probs (20 ms H-time chain)
              int timingTok = 0;
              double maxTimingLp = timing[offset];
              for (int v = 1; v < zfTajweedVocab; v++) {
                final double lp = timing[offset + v];
                if (lp > maxTimingLp) {
                  maxTimingLp = lp;
                  timingTok = v;
                }
              }

              // Argmax from id_log_probs (20 ms identity CTC) if available
              int idTok = 0;
              if (idProbs != nullptr) {
                double maxIdLp = idProbs[offset];
                for (int v = 1; v < zfTajweedVocab; v++) {
                  final double lp = idProbs[offset + v];
                  if (lp > maxIdLp) {
                    maxIdLp = lp;
                    idTok = v;
                  }
                }
              }

              // Inter4 check at 40 ms frame grid
              bool inter4Match = false;
              if (inter4Probs != nullptr && (f ~/ 2) < headsPtr.ref.n40) {
                final int off40 = (f ~/ 2) * zfTajweedVocab;
                int inter4Tok = 0;
                double maxInter4 = inter4Probs[off40];
                for (int v = 1; v < zfTajweedVocab; v++) {
                  final double lp = inter4Probs[off40 + v];
                  if (lp > maxInter4) {
                    maxInter4 = lp;
                    inter4Tok = v;
                  }
                }
                inter4Match = inter4Tok == a;
              }

              final double aTimingLp = timing[offset + a];
              final double aIdLp = idProbs != nullptr ? idProbs[offset + a] : -999.0;
              final bool neuralDirectMatch = timingTok == a ||
                  idTok == a ||
                  inter4Match ||
                  aTimingLp > -2.3 ||
                  aIdLp > -2.3 ||
                  aTimingLp > timing[offset]; // higher than blank/pause

              final bool matchesSound;
              if (neuralDirectMatch) {
                matchesSound = true;
              } else if (a == 34 || a == 35 || a == 36) {
                // Madd continuations ('aa': 34, 'ii': 35, 'uu': 36, or vowels 'a': 31, 'i': 32, 'u': 33)
                matchesSound = (timingTok == 34 || timingTok == 35 || timingTok == 36 ||
                    timingTok == 31 || timingTok == 32 || timingTok == 33 ||
                    idTok == 34 || idTok == 35 || idTok == 36 ||
                    idTok == 31 || idTok == 32 || idTok == 33);
              } else if (a == 30 || a == 26 || a == 25) {
                // Ghunnah continuations (nasal nun 'ں': 30, nun 'ن': 26, meem 'م': 25)
                matchesSound = (timingTok == 30 || timingTok == 26 || timingTok == 25 ||
                    idTok == 30 || idTok == 26 || idTok == 25);
              } else {
                matchesSound = false;
              }

              if (matchesSound) {
                holdLimit = f + 1;
                gapCount = 0;
              } else if (timingTok == zfTajweedBlank) {
                gapCount++;
                if (gapCount > gapTolerance) break;
              } else {
                // A different distinct sound has started -> holding ended
                break;
              }
            }
            if (holdLimit > end20) {
              end20 = holdLimit;
            }
          }

          final String name =
              (a >= 0 && a < tokenCache.length) ? tokenCache[a] : '';
          tokenStrings.add(name);
          timestamps.add(end20 * 0.020);
          tokenDurations.add((end20 - start20) * 0.020);

          // Qalqalah: mean attr_qalqalah[:, 1] + [:, 2] over the 12 frames
          // after the letter's end. Only attr_qalqalah is used for Qalqalah.
          double qalqalahSum = 0.0;
          int qalqalahCount = 0;
          if (qalqalah != nullptr && n20 > 0) {
            final int from = math.min(end20, n20);
            final int to = math.min(end20 + 12, n20);
            for (int f = from; f < to; f++) {
              qalqalahSum += qalqalah[f * 3 + 1] + qalqalah[f * 3 + 2];
              qalqalahCount++;
            }
          }

          // Confidence: mean sigmoid(conf) over the letter's span.
          double confSum = 0.0;
          int confCount = 0;
          if (conf != nullptr && n20 > 0) {
            final int from = math.min(start20, n20);
            final int to = math.min(end20, n20);
            for (int f = from; f < to; f++) {
              confSum += 1.0 / (1.0 + math.exp(-conf[f]));
              confCount++;
            }
          }

          tokenAcoustics.add(
            TokenNeuralAcoustics(
              qalqalahScore:
                  qalqalahCount > 0 ? qalqalahSum / qalqalahCount : 0.0,
              confScore: confCount > 0 ? confSum / confCount : 1.0,
            ),
          );

          t = e + 1;
        }
      } else {
        // Fallback when the engine's decoded layer is unavailable: the
        // engine's own greedy transcript, at its 40 ms frame grid.
        final int nTokens = b.streamGreedy(s, idsBuf, maxTokens);
        final int count = math.min(nTokens, maxTokens);
        for (int i = 0; i < count; i++) {
          final int tokenId = idsBuf[i];
          final String name = (tokenId >= 0 && tokenId < tokenCache.length)
              ? tokenCache[tokenId]
              : '';
          tokenStrings.add(name);
          timestamps.add((i + 1) * 0.040);
          tokenDurations.add(0.040);
          tokenAcoustics.add(const TokenNeuralAcoustics());
        }
      }

      final StringBuffer textBuf = StringBuffer();
      for (final String tok in tokenStrings) {
        if (tok == '|') {
          if (textBuf.isNotEmpty && !textBuf.toString().endsWith(' ')) {
            textBuf.write(' ');
          }
        } else if (tok != '<blk>' && tok != '<foreign>') {
          textBuf.write(tok);
        }
      }

      return TajweedFormerTranscriptionEvent(
        text: textBuf.toString(),
        tokens: tokenStrings,
        timestamps: timestamps,
        durations: tokenDurations,
        neuralAcoustics: tokenAcoustics,
        isFinal: isFinal,
        startTime: startTime,
        streamEpoch: epoch,
      );
    }

    /// Emits the last frame of each enabled head as a diagnostic sample.
    /// Heads that are not enabled are reported as empty, never fabricated.
    void emitDiagnostics() {
      final ZfTajweedBindings? b = bindings;
      final Pointer<Void>? s = stream;
      if (b == null || s == null || s == nullptr) return;

      final int headsRet = b.streamHeads(s, headsPtr);
      if (headsRet < 0 || headsPtr.ref.n20 <= 0) return;

      final int lastF = headsPtr.ref.n20 - 1;
      final double gemProb =
          headsPtr.ref.gem != nullptr ? headsPtr.ref.gem[lastF * 2 + 1] : 0.0;
      final List<double> qalqalahProbs = headsPtr.ref.attrQalqalah != nullptr
          ? [
              headsPtr.ref.attrQalqalah[lastF * 3 + 0],
              headsPtr.ref.attrQalqalah[lastF * 3 + 1],
              headsPtr.ref.attrQalqalah[lastF * 3 + 2],
            ]
          : const [];
      final double confProb = headsPtr.ref.conf != nullptr
          ? 1.0 / (1.0 + math.exp(-headsPtr.ref.conf[lastF]))
          : 1.0;

      mainSendPort.send(
        TajweedFormerDiagnosticsEvent(
          timestamp: lastF * 0.020,
          geminationProb: gemProb,
          qalqalahProbs: qalqalahProbs,
          ghunnaProbs: const [],
          tafkheemProbs: const [],
          faceProbs: const [],
          confidence: confProb,
        ),
      );
    }

    String describeStreamError() {
      final ZfTajweedBindings? b = bindings;
      final Pointer<Void>? s = stream;
      if (b == null || s == null || s == nullptr) return 'stream unavailable';
      final Pointer<Utf8> p = b.streamLastError(s);
      return p == nullptr ? 'unknown stream error' : p.toDartString();
    }

    port.listen((msg) {
      if (msg is! TajweedFormerCommand) return;

      switch (msg) {
        case TajweedFormerInitCommand(
            :final modelDir,
            :final context,
            :final customLibPath
          ):
          try {
            bindings = ZfTajweedBindings.load(customLibPath: customLibPath);

            final optionsPtr = calloc<ZfTajweedOpenOptions>();
            optionsPtr.ref = bindings!.openDefaultOptions();

            Pointer<Utf8>? contextPtr;
            Pointer<Utf8>? modelDirPtr;
            final errPtr = calloc<Pointer<Utf8>>();

            try {
              if (context != null) {
                contextPtr = context.toNativeUtf8();
                optionsPtr.ref.context = contextPtr;
              }
              modelDirPtr = modelDir.toNativeUtf8();
              model = bindings!.modelOpen(modelDirPtr, optionsPtr, errPtr);
            } finally {
              if (contextPtr != null) calloc.free(contextPtr);
              if (modelDirPtr != null) calloc.free(modelDirPtr);
              calloc.free(optionsPtr);
            }

            if (model == null || model == nullptr) {
              final errMsg = errPtr.value != nullptr
                  ? errPtr.value.toDartString()
                  : 'Unknown error opening model';
              calloc.free(errPtr);
              throw Exception('TajweedFormer: $errMsg');
            }

            stream = bindings!.streamCreate(model!, errPtr);
            if (stream == null || stream == nullptr) {
              final errMsg = errPtr.value != nullptr
                  ? errPtr.value.toDartString()
                  : 'Unknown error creating stream';
              calloc.free(errPtr);
              throw Exception('TajweedFormer: $errMsg');
            }
            calloc.free(errPtr);

            // Only the heads this app reads. `stream_set_heads` adds
            // log_probs itself and refuses to run once audio has arrived.
            final int headsResult = bindings!.streamSetHeads(stream!, appHeads);
            if (headsResult != 0) {
              throw Exception(
                'TajweedFormer: the engine graph lacks one of the requested heads '
                '(zf_tajweed_stream_set_heads returned $headsResult)',
              );
            }

            // Pre-cache the vocabulary tokens to eliminate repeated FFI calls per frame
            tokenCache.clear();
            for (int i = 0; i < zfTajweedVocab; i++) {
              final namePtr = bindings!.tokenName(model!, i);
              tokenCache.add(namePtr != nullptr ? namePtr.toDartString() : '');
            }

            mainSendPort.send(const TajweedFormerInitSuccessEvent());
          } catch (e) {
            mainSendPort.send(TajweedFormerInitErrorEvent(e.toString()));
          }

        case TajweedFormerRecognizeCommand(
            :final chunk,
            :final isFinal,
            :final startTime
          ):
          if (bindings == null || stream == null || stream == nullptr) return;

          try {
            final Float32List samples = chunk.materialize().asFloat32List();
            final int sampleCount = samples.length;

            if (sampleCount > audioBufCap) {
              calloc.free(audioBuf);
              audioBufCap = sampleCount * 2;
              audioBuf = calloc<Float>(audioBufCap);
            }
            audioBuf.asTypedList(sampleCount).setAll(0, samples);

            final int pushed =
                bindings!.streamPushAudio(stream!, audioBuf, sampleCount);
            if (pushed < 0) {
              if (kDebugMode) {
                debugPrint(
                    'TajweedFormer push_audio error: ${describeStreamError()}');
              }
              return;
            }

            if (isFinal) {
              final int finished = bindings!.streamFinish(stream!);
              if (finished < 0 && kDebugMode) {
                debugPrint(
                    'TajweedFormer finish error: ${describeStreamError()}');
              }
            }

            emitDiagnostics();

            final event = decodeTake(
              isFinal: isFinal,
              startTime: startTime,
              epoch: isolateStreamEpoch,
            );
            if (event != null) {
              mainSendPort.send(event);
            }
          } catch (e) {
            if (kDebugMode) {
              debugPrint('TajweedFormer inference error: $e');
            }
          }

        case TajweedFormerResetCommand():
          if (bindings != null && stream != null && stream != nullptr) {
            bindings!.streamReset(stream!);
          }
          isolateStreamEpoch++;

        case TajweedFormerFlushCommand():
          if (bindings != null && stream != null && stream != nullptr) {
            final int finished = bindings!.streamFinish(stream!);
            if (finished < 0 && kDebugMode) {
              debugPrint('TajweedFormer flush error: ${describeStreamError()}');
            }

            // The take's tail is now in the stream. Emit it as the final
            // transcription before the buffer is wiped.
            final event = decodeTake(
              isFinal: true,
              startTime: DateTime.now().millisecondsSinceEpoch,
              epoch: isolateStreamEpoch,
            );
            if (event != null) {
              mainSendPort.send(event);
            }

            bindings!.streamReset(stream!);
          }
          isolateStreamEpoch++;

        case TajweedFormerDestroyCommand():
          calloc.free(idsBuf);
          calloc.free(headsPtr);
          calloc.free(top2OutPtr);
          calloc.free(audioBuf);
          if (bindings != null) {
            if (stream != null && stream != nullptr) {
              bindings!.streamDestroy(stream!);
              stream = null;
            }
            if (model != null && model != nullptr) {
              bindings!.modelClose(model!);
              model = null;
            }
          }
          port.close();
      }
    });
  }
}

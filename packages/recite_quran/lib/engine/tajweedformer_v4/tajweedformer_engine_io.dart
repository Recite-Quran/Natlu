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

      if (modelAssets.isEmpty) return;

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
    } catch (_) {}
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

    final String resolvedModelDir = modelDirOverride ?? await _resolveDefaultModelDir();
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

    port.listen((msg) {
      if (msg is! TajweedFormerCommand) return;

      switch (msg) {
        case TajweedFormerInitCommand(:final modelDir, :final context, :final customLibPath):
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
              final errMsg = errPtr.value != nullptr ? errPtr.value.toDartString() : 'Unknown error opening model';
              calloc.free(errPtr);
              throw Exception('TajweedFormer: $errMsg');
            }

            stream = bindings!.streamCreate(model!, errPtr);
            if (stream == null || stream == nullptr) {
              final errMsg = errPtr.value != nullptr ? errPtr.value.toDartString() : 'Unknown error creating stream';
              calloc.free(errPtr);
              throw Exception('TajweedFormer: $errMsg');
            }
            calloc.free(errPtr);

            // Enable all 12 neural diagnostic heads (ZF_TAJWEED_HEADS_ALL)
            bindings!.streamSetHeads(stream!, (1 << 12) - 1);

            // Pre-cache the 38 vocabulary tokens to eliminate repeated FFI calls per frame
            tokenCache.clear();
            for (int i = 0; i < 38; i++) {
              final namePtr = bindings!.tokenName(model!, i);
              tokenCache.add(namePtr != nullptr ? namePtr.toDartString() : '');
            }

            mainSendPort.send(const TajweedFormerInitSuccessEvent());
          } catch (e) {
            mainSendPort.send(TajweedFormerInitErrorEvent(e.toString()));
          }

        case TajweedFormerRecognizeCommand(:final chunk, :final isFinal, :final startTime):
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

            bindings!.streamPushAudio(stream!, audioBuf, sampleCount);

            if (isFinal) {
              bindings!.streamFinish(stream!);
            }

            // Query multi-head neural diagnostics
            final int headsRet = bindings!.streamHeads(stream!, headsPtr);
            if (headsRet >= 0 && headsPtr.ref.n20 > 0) {
              final int lastF = headsPtr.ref.n20 - 1;
              final double gemProb = (headsPtr.ref.gem != nullptr)
                  ? headsPtr.ref.gem[lastF * 2 + 1]
                  : 0.0;

              final List<double> qalqalahProbs = (headsPtr.ref.attrQalqalah != nullptr)
                  ? [
                      headsPtr.ref.attrQalqalah[lastF * 3 + 0],
                      headsPtr.ref.attrQalqalah[lastF * 3 + 1],
                      headsPtr.ref.attrQalqalah[lastF * 3 + 2],
                    ]
                  : const [1.0, 0.0, 0.0];

              mainSendPort.send(
                TajweedFormerDiagnosticsEvent(
                  timestamp: lastF * 0.020,
                  geminationProb: gemProb,
                  qalqalahProbs: qalqalahProbs,
                  ghunnaProbs: const [1.0, 0.0, 0.0, 0.0, 0.0],
                  tafkheemProbs: const [1.0, 0.0, 0.0],
                  faceProbs: const [1.0, 0.0, 0.0, 0.0],
                ),
              );
            }

            final int nFrames = bindings!.streamTop2(stream!, top2OutPtr);
            final List<String> tokenStrings = [];
            final List<double> timestamps = [];
            final List<double> tokenDurations = [];
            final List<TokenNeuralAcoustics> tokenAcoustics = [];

            // Pre-group continuous 20ms acoustic runs from timingLogProbs (H-time chain)
            final List<_TimingRun> timingRuns = [];
            final int n20 = headsPtr.ref.n20;
            final int vocab = headsPtr.ref.vocab;
            final Pointer<Float> tlp = headsPtr.ref.timingLogProbs;

            if (headsRet >= 0 && tlp != nullptr && n20 > 0 && vocab > 0) {
              int? currRunTok;
              int runStart = 0;
              for (int f = 0; f < n20; f++) {
                int maxTok = 0;
                double maxVal = tlp[f * vocab + 0];
                for (int v = 1; v < vocab; v++) {
                  final double val = tlp[f * vocab + v];
                  if (val > maxVal) {
                    maxVal = val;
                    maxTok = v;
                  }
                }
                if (maxTok != currRunTok) {
                  if (currRunTok != null &&
                      currRunTok != 0 &&
                      currRunTok < tokenCache.length) {
                    timingRuns.add(_TimingRun(currRunTok, runStart, f));
                  }
                  currRunTok = maxTok;
                  runStart = f;
                }
              }
              if (currRunTok != null &&
                  currRunTok != 0 &&
                  currRunTok < tokenCache.length) {
                timingRuns.add(_TimingRun(currRunTok, runStart, n20));
              }
            }

            if (nFrames > 0 && top2OutPtr.value != nullptr) {
              final Pointer<ZfTajweedTop2> top2 = top2OutPtr.value;
              int prevEnd20 = 0;
              int trCursor = 0;

              for (int t = 0; t < nFrames;) {
                final int a = top2[t].token;
                if (a == 0) { // BLANK = 0
                  t++;
                  continue;
                }
                int e = t;
                while (e + 1 < nFrames && top2[e + 1].token == a) {
                  e++;
                }
                int pk = t;
                for (int k = t + 1; k <= e; k++) {
                  if (top2[k].logProb > top2[pk].logProb) {
                    pk = k;
                  }
                }

                final int baseSf = 2 * t;
                final int baseEf = 2 * (e + 1);

                // Monotonic alignment to physical 20ms timingLogProbs run
                int fineSf = math.max(baseSf, prevEnd20);
                int fineEf = math.max(baseEf, fineSf + 1);

                if (timingRuns.isNotEmpty) {
                  int bestIdx = -1;
                  int bestOverlap = -1;
                  for (int idx = trCursor; idx < timingRuns.length; idx++) {
                    final tr = timingRuns[idx];
                    if (tr.start > baseEf + 10) break;
                    if (tr.token == a) {
                      final int overlap = math.max(
                        0,
                        math.min(tr.end, baseEf) - math.max(tr.start, baseSf),
                      );
                      if (overlap > bestOverlap) {
                        bestOverlap = overlap;
                        bestIdx = idx;
                      }
                    }
                  }

                  if (bestIdx != -1 && bestOverlap > 0) {
                    fineSf = math.max(prevEnd20, timingRuns[bestIdx].start);
                    fineEf = timingRuns[bestIdx].end;
                    trCursor = bestIdx + 1;
                  } else {
                    for (int idx = trCursor; idx < timingRuns.length; idx++) {
                      final tr = timingRuns[idx];
                      if (tr.token == a && tr.start <= baseEf) {
                        fineSf = math.max(prevEnd20, tr.start);
                        fineEf = tr.end;
                        trCursor = idx + 1;
                        break;
                      }
                    }
                  }
                }

                fineSf = math.max(prevEnd20, fineSf);
                fineEf = math.max(fineSf + 1, fineEf);
                prevEnd20 = fineEf;

                final int finePk = math.max(fineSf, math.min(2 * pk, fineEf));

                final String name =
                    (a >= 0 && a < tokenCache.length) ? tokenCache[a] : '';
                tokenStrings.add(name);
                timestamps.add((finePk + 1) * 0.020); // Peak timestamp in seconds
                tokenDurations.add((fineEf - fineSf) * 0.020); // Stretched physical acoustic span in seconds

                // Qalqalah release evaluation: author calibrated window [fineEf + 2, fineEf + 14)
                double qalqalahSum = 0.0;
                int qalqalahCount = 0;
                if (headsRet >= 0 &&
                    headsPtr.ref.attrQalqalah != nullptr &&
                    headsPtr.ref.n20 > 0 &&
                    fineEf >= 0) {
                  final int relStart = math.min(headsPtr.ref.n20, fineEf + 2);
                  final int relEnd = math.min(headsPtr.ref.n20, fineEf + 14);
                  for (int f = relStart; f < relEnd; f++) {
                    qalqalahSum += (headsPtr.ref.attrQalqalah[f * 3 + 1] +
                        headsPtr.ref.attrQalqalah[f * 3 + 2]);
                    qalqalahCount++;
                  }
                }

                // Token confidence over physical 20ms span [fineSf, fineEf)
                double confSum = 0.0;
                int confCount = 0;
                if (headsRet >= 0 &&
                    headsPtr.ref.conf != nullptr &&
                    headsPtr.ref.n20 > 0) {
                  final int cEnd = math.min(headsPtr.ref.n20, fineEf);
                  for (int f = fineSf; f < cEnd; f++) {
                    final double logit = headsPtr.ref.conf[f];
                    confSum += 1.0 / (1.0 + math.exp(-logit));
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
              final int nTokens =
                  bindings!.streamGreedy(stream!, idsBuf, maxTokens);
              for (int i = 0; i < nTokens && i < maxTokens; i++) {
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
            for (int i = 0; i < tokenStrings.length; i++) {
              final tok = tokenStrings[i];
              if (tok == '|') {
                if (textBuf.isNotEmpty && !textBuf.toString().endsWith(' ')) {
                  textBuf.write(' ');
                }
              } else if (tok != '<blk>' && tok != '<foreign>') {
                textBuf.write(tok);
              }
            }
            final String recognizedText = textBuf.toString();

            mainSendPort.send(
              TajweedFormerTranscriptionEvent(
                text: recognizedText,
                tokens: tokenStrings,
                timestamps: timestamps,
                durations: tokenDurations,
                neuralAcoustics: tokenAcoustics,
                isFinal: isFinal,
                startTime: startTime,
                streamEpoch: isolateStreamEpoch,
              ),
            );
          } catch (e) {
            if (kDebugMode) {
              print('TajweedFormer inference error: $e');
            }
          }

        case TajweedFormerResetCommand():
          if (bindings != null && stream != null && stream != nullptr) {
            bindings!.streamReset(stream!);
          }
          isolateStreamEpoch++;

        case TajweedFormerFlushCommand():
          if (bindings != null && stream != null && stream != nullptr) {
            bindings!.streamFinish(stream!);
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

class _TimingRun {
  final int token;
  final int start;
  final int end;
  const _TimingRun(this.token, this.start, this.end);
}


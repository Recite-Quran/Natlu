// lib/engine/quranlab_sdk/quranlab_sdk_engine.dart
// Integration adapter for the official Quran Lab TajweedFormer SDK 4.0.

import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:quranlab_tajweedformer/quranlab_tajweedformer.dart';

import '../core/recite_engine.dart';
import '../core/tajweed_diagnostics.dart';
import '../core/transcription_result.dart';

/// Recitation acoustic engine powered by the official Quran Lab SDK (SDK 4.0).
///
/// Connects to sdk.quranlab.ai using an application key (`qlk_v1_...`),
/// automatically downloads and verifies the encrypted on-device model,
/// manages cryptographic leases, and streams chunks and neural heads directly
/// into the recitation scoring and alignment pipeline.
class QuranLabSdkEngine implements ReciteEngine {
  QuranLabSdkEngine({
    required this.apiKey,
    this.contextProfile = 'c16_l64',
    this.endOnSilenceMs,
  });

  /// The Quran Lab application developer key (`qlk_v1_...`).
  final String apiKey;

  /// Model context profile: 'c8_l64' (160ms), 'c16_l64' (320ms, default), or 'c24_l72' (480ms).
  final String contextProfile;

  /// Optional auto-end duration upon silence in milliseconds.
  final int? endOnSilenceMs;

  TajweedClient? _client;
  TajweedModel? _model;
  TajweedSession? _session;
  StreamSubscription<TajweedChunk>? _chunkSub;

  final StreamController<TranscriptionResult> _outputController =
      StreamController<TranscriptionResult>.broadcast();
  final StreamController<TajweedDiagnostics> _diagnosticsController =
      StreamController<TajweedDiagnostics>.broadcast();

  bool _isInitialized = false;
  Future<void>? _initFuture;
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

  /// Exposes the underlying [TajweedClient] for diagnostics, sharing, or lease checks.
  TajweedClient? get client => _client;

  /// Exposes the active [TajweedSession] for reporting recited ranges.
  TajweedSession? get session => _session;

  @override
  Future<bool> isModelCached() async => _isInitialized;

  @override
  Future<void> initialize() {
    if (_isInitialized) return Future.value();
    if (_initFuture != null) return _initFuture!;
    _initFuture = _doInitialize();
    return _initFuture!;
  }

  Future<void> _doInitialize() async {
    try {
      // 1. Initialize client with application key (registers app and validates identity)
      _client = await TajweedClient.create(apiKey);

      // 2. Load model (downloads encrypted model on 1st run, fetches/renews lease)
      _model = await _client!.model();

      // 3. Open initial push-based audio session
      await _openNewSession();

      _isInitialized = true;
      _initFuture = null;
    } catch (e) {
      _initFuture = null;
      if (kDebugMode) {
        debugPrint('QuranLabSdkEngine initialization failed: $e');
      }
      rethrow;
    }
  }

  Future<void> _openNewSession() async {
    _chunkSub?.cancel();
    _chunkSub = null;

    if (_model == null) return;

    _session = await _model!.session(
      options: TajweedSessionOptions(
        heads: TajweedSessionOptions.allHeads,
        sampleRate: 16000,
        context: contextProfile,
        endOnSilenceMs: endOnSilenceMs,
      ),
    );

    _chunkSub = _session!.chunks.listen(
      _handleChunk,
      onError: (e) {
        if (kDebugMode) {
          debugPrint('QuranLabSdkEngine chunk stream error: $e');
        }
      },
    );
  }

  void _handleChunk(TajweedChunk chunk) {
    final decoded = chunk.decoded;
    final List<String> tokenStrings = [];
    final List<double> timestamps = [];
    final List<double> tokenDurations = [];
    final List<TokenNeuralAcoustics> tokenAcoustics = [];

    final qalqalahHead = chunk.heads['attr_qalqalah'];
    final gemHead = chunk.heads['gem'];
    final confHead = chunk.heads['conf'];

    for (final token in decoded.tokens) {
      tokenStrings.add(token.name);
      timestamps.add(token.lastMs / 1000.0);
      tokenDurations.add((token.lastMs - token.firstMs) / 1000.0);

      // Extract Qalqalah score from attr_qalqalah head if present
      double qalScore = 0.0;
      if (qalqalahHead != null && qalqalahHead.frames > 0) {
        final lastF = qalqalahHead.frames - 1;
        qalScore = qalqalahHead.at(lastF, 1) + qalqalahHead.at(lastF, 2);
      }

      tokenAcoustics.add(
        TokenNeuralAcoustics(
          qalqalahScore: qalScore,
          confScore: token.confidence ?? 1.0,
        ),
      );
    }

    // Diagnostics emission
    if (gemHead != null && gemHead.frames > 0) {
      final lastF = gemHead.frames - 1;
      final gemProb = gemHead.at(lastF, 1);
      final qalProbs = qalqalahHead != null && qalqalahHead.frames > lastF
          ? [
              qalqalahHead.at(lastF, 0),
              qalqalahHead.at(lastF, 1),
              qalqalahHead.at(lastF, 2),
            ]
          : const <double>[];
      final confProb = confHead != null && confHead.frames > lastF
          ? confHead.at(lastF, 0)
          : 1.0;

      _diagnosticsController.add(
        TajweedDiagnostics(
          timestamp: lastF * 0.020,
          geminationProb: gemProb,
          qalqalahProbs: qalProbs,
          ghunnaProbs: const [],
          tafkheemProbs: const [],
          faceProbs: const [],
          confidence: confProb,
        ),
      );
    }

    _outputController.add(
      TranscriptionResult(
        text: decoded.text,
        isFinal: decoded.isFinal,
        startTime: chunk.startMs,
        tokens: tokenStrings,
        timestamps: timestamps,
        durations: tokenDurations,
        neuralAcoustics: tokenAcoustics,
        streamEpoch: _currentStreamEpoch,
      ),
    );
  }

  @override
  bool transcribe(Float32List audioChunk, {bool isFinal = false}) {
    if (!_isInitialized || _session == null) return false;

    _session!.push(audioChunk);
    if (isFinal) {
      _session!.finish();
    }
    return true;
  }

  @override
  void resetBuffer() {
    _currentStreamEpoch++;
    _session?.finish();
    _openNewSession();
  }

  @override
  void flushThenReset() => resetBuffer();

  @override
  void destroy() {
    _chunkSub?.cancel();
    _chunkSub = null;
    _session?.cancel();
    _session = null;
    _client?.close();
    _client = null;
    _model = null;

    if (!_outputController.isClosed) {
      _outputController.close();
    }
    if (!_diagnosticsController.isClosed) {
      _diagnosticsController.close();
    }
    _isInitialized = false;
  }
}

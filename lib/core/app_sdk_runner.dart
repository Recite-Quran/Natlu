import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:quran_tarteel/quran_tarteel.dart';

/// Direct owner of [TajweedClient], [TajweedModel], and [TajweedSession] from
/// `quranlab_tajweedformer`, decoding live chunks with [TajweedTakeDecoder].
class AppSdkRunner {
  final String apiKey;
  final String? contextProfile;
  final int sampleRate;
  final int topK;
  final double minKeepProb;
  bool _includeTajweedHeads;

  TajweedClient? _client;
  TajweedModel? _model;
  TajweedSession? _session;
  TajweedTakeDecoder? _decoder;
  StreamSubscription<TajweedChunk>? _chunkSub;
  StreamSubscription<TajweedEvent>? _eventSub;

  Future<TajweedClient>? _clientFuture;
  Future<void>? _initFuture;
  Future<void> _sessionOp = Future<void>.value();

  bool _isInitialized = false;
  bool _isDisposed = false;
  int _currentStreamEpoch = 0;
  int _lastFinalEpoch = -1;

  final StreamController<TranscriptionResult> _outputController =
      StreamController<TranscriptionResult>.broadcast();

  AppSdkRunner({
    required this.apiKey,
    this.contextProfile,
    this.sampleRate = 16000,
    this.topK = TajweedTakeDecoder.defaultTopK,
    this.minKeepProb = TajweedTakeDecoder.defaultMinKeepProb,
    bool includeTajweedHeads = true,
  }) : _includeTajweedHeads = includeTajweedHeads;

  bool get isInitialized => _isInitialized;
  int get currentStreamEpoch => _currentStreamEpoch;
  TajweedClient? get client => _client;
  TajweedModel? get model => _model;
  TajweedTokens? get tokens => _model?.tokens;
  TajweedSharing? get sharing => _client?.sharing;
  Stream<TranscriptionResult> get transcriptionStream =>
      _outputController.stream;

  double? get validatedQalqalahTau {
    final m = _model;
    if (m == null) return null;
    return TajweedTakeDecoder.resolveValidatedQalqalahTau(
      m,
      context: contextProfile,
    );
  }

  void setIncludeTajweedHeads(bool enabled) {
    if (_includeTajweedHeads == enabled) return;
    _includeTajweedHeads = enabled;
    if (_isInitialized) {
      resetBuffer();
    }
  }

  Future<TajweedClient> _ensureClient() async {
    if (_client != null) return _client!;
    return _clientFuture ??= TajweedClient.create(apiKey).then((c) {
      _client = c;
      return c;
    }).whenComplete(() {
      _clientFuture = null;
    });
  }

  Future<bool> isModelCached() async {
    if (_isInitialized && _model != null) return true;
    final client = await _ensureClient();
    final storage = await client.storage();
    return storage.models.isNotEmpty;
  }

  Future<void> initialize({
    void Function(int done, int total)? onDownloadProgress,
  }) {
    if (_isDisposed) {
      return Future.error(StateError('AppSdkRunner is disposed.'));
    }
    if (_isInitialized) return Future.value();
    if (_initFuture != null) return _initFuture!;
    _initFuture = _doInitialize(onDownloadProgress: onDownloadProgress);
    return _initFuture!;
  }

  Future<void> _doInitialize({
    void Function(int done, int total)? onDownloadProgress,
  }) async {
    try {
      final client = await _ensureClient();
      final model = await client.model(onProgress: onDownloadProgress);
      _model = model;
      _decoder = TajweedTakeDecoder(
        vocab: model.tokens,
        requireQalqalahHead: _includeTajweedHeads,
        minKeepProb: minKeepProb,
      );
      _isInitialized = true;
      _initFuture = null;
    } catch (_) {
      _initFuture = null;
      rethrow;
    }
  }

  Future<void> _enqueueSessionOp(Future<void> Function() op) {
    final next = _sessionOp.then((_) => op(), onError: (_) => op());
    _sessionOp = next.then<void>(
      (_) {},
      onError: (Object error, StackTrace stackTrace) {
        if (!_outputController.isClosed) {
          _outputController.addError(error, stackTrace);
        }
        if (kDebugMode) {
          debugPrint('AppSdkRunner session op error: $error');
        }
      },
    );
    return next;
  }

  Future<void> _openNewSessionLocked() async {
    await _chunkSub?.cancel();
    _chunkSub = null;
    await _eventSub?.cancel();
    _eventSub = null;
    _decoder?.resetTake();

    if (_isDisposed || _model == null) return;

    final int sessionEpoch = _currentStreamEpoch;
    final heads = _includeTajweedHeads
        ? TajweedTakeDecoder.activeHeads
        : TajweedTakeDecoder.wordOnlyHeads;
    _decoder = TajweedTakeDecoder(
      vocab: _model!.tokens,
      requireQalqalahHead: _includeTajweedHeads,
      minKeepProb: minKeepProb,
    );

    final session = await _model!.session(
      options: TajweedSessionOptions(
        heads: heads,
        sampleRate: sampleRate,
        context: contextProfile,
        topK: topK,
      ),
    );
    if (_isDisposed) {
      unawaited(session.cancel().catchError((_) {}));
      return;
    }
    _session = session;

    _chunkSub = session.chunks.listen(
      (chunk) {
        if (_isDisposed || _outputController.isClosed) return;
        final result = _decoder!.decodeChunk(chunk, streamEpoch: sessionEpoch);
        if (result.isFinal) {
          _lastFinalEpoch = sessionEpoch;
        }
        _outputController.add(result);
      },
      onError: (Object error, StackTrace stackTrace) {
        if (!_outputController.isClosed) {
          _outputController.addError(error, stackTrace);
        }
      },
    );

    _eventSub = session.events.listen(
      (event) {
        if (_isDisposed) return;
        if (event is TajweedBackendChanged && event.fromChunk == 0) {
          _decoder?.resetTake();
        } else if (event is TajweedEnded && identical(_session, session)) {
          _session = null;
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        if (!_outputController.isClosed) {
          _outputController.addError(error, stackTrace);
        }
      },
    );
  }

  Future<void> _closeCurrentSessionLocked({
    required bool flush,
    int? flushEpoch,
  }) async {
    final session = _session;
    if (session == null) {
      await _chunkSub?.cancel();
      _chunkSub = null;
      await _eventSub?.cancel();
      _eventSub = null;
      return;
    }

    if (flush) {
      try {
        final heads = await session.finish();
        if (!_isDisposed &&
            flushEpoch != null &&
            _lastFinalEpoch != flushEpoch &&
            _decoder != null &&
            !_outputController.isClosed) {
          final result = _decoder!.decodeFinishedHeads(
            heads,
            streamEpoch: flushEpoch,
          );
          _lastFinalEpoch = flushEpoch;
          _outputController.add(result);
        }
      } finally {
        if (identical(_session, session)) {
          _session = null;
        }
        await _chunkSub?.cancel();
        _chunkSub = null;
        await _eventSub?.cancel();
        _eventSub = null;
      }
      return;
    }

    if (identical(_session, session)) {
      _session = null;
    }
    await _chunkSub?.cancel();
    _chunkSub = null;
    await _eventSub?.cancel();
    _eventSub = null;
    try {
      await session.cancel();
    } on TajweedError catch (e) {
      if (e.code != TajweedErrorCode.sessionClosed &&
          e.code != TajweedErrorCode.cancelled) {
        rethrow;
      }
    }
  }

  bool transcribe(Float32List audioChunk, {bool isFinal = false}) {
    if (!_isInitialized || _isDisposed) return false;
    final copy = Float32List.fromList(audioChunk);
    final int pushEpoch = _currentStreamEpoch;

    _enqueueSessionOp(() async {
      if (_isDisposed ||
          !_isInitialized ||
          pushEpoch != _currentStreamEpoch) {
        return;
      }
      if (_session == null) {
        await _openNewSessionLocked();
      }
      final s = _session;
      if (s == null) return;
      await s.push(copy);
    });

    if (isFinal) {
      flushThenReset();
    }
    return true;
  }

  void resetBuffer() {
    if (_isDisposed) return;
    _currentStreamEpoch++;
    _decoder?.resetTake();
    if (!_isInitialized) return;
    _enqueueSessionOp(() async {
      await _closeCurrentSessionLocked(flush: false);
    });
  }

  void flushThenReset() {
    if (_isDisposed) return;
    final int flushEpoch = _currentStreamEpoch;
    _currentStreamEpoch++;
    if (!_isInitialized) return;
    _enqueueSessionOp(() async {
      await _closeCurrentSessionLocked(flush: true, flushEpoch: flushEpoch);
    });
  }

  void destroy() {
    if (_isDisposed) return;
    _isDisposed = true;
    _isInitialized = false;

    final chunkSub = _chunkSub;
    _chunkSub = null;
    if (chunkSub != null) unawaited(chunkSub.cancel());

    final eventSub = _eventSub;
    _eventSub = null;
    if (eventSub != null) unawaited(eventSub.cancel());

    final session = _session;
    _session = null;
    if (session != null) {
      unawaited(session.cancel().catchError((_) {}));
    }

    final client = _client;
    _client = null;
    _model = null;
    _decoder = null;
    if (client != null) {
      unawaited(client.close().catchError((_) {}));
    }

    if (!_outputController.isClosed) {
      _outputController.close();
    }
  }
}

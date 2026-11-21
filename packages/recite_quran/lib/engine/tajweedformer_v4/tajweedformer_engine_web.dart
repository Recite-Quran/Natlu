// lib/engine/tajweedformer_v4/tajweedformer_engine_web.dart
// Web implementation for TajweedFormerEngine using QuranLab Web SDK.

import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import '../core/recite_engine.dart';
import '../core/tajweed_diagnostics.dart';
import '../core/transcription_result.dart';

@JS('window.TajweedWebBridge')
external TajweedWebBridgeJs? get tajweedWebBridge;

@JS('eval')
external JSAny? _jsEval(JSString code);

extension type TajweedWebBridgeJs(JSObject _) implements JSObject {
  external JSPromise<JSBoolean> init(JSString? key);
  external JSBoolean startSession(JSFunction callback);
  external JSBoolean pushAudio(JSFloat32Array float32);
  external JSBoolean finish();
  external void reset();
  external void destroy();
}

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

  final StreamController<TranscriptionResult> _outputController =
      StreamController<TranscriptionResult>.broadcast();

  bool _isInitialized = false;
  int _currentStreamEpoch = 0;

  @override
  bool get isInitialized => _isInitialized;

  @override
  int get currentStreamEpoch => _currentStreamEpoch;

  @override
  Stream<TranscriptionResult> get transcriptionStream =>
      _outputController.stream;

  @override
  Stream<TajweedDiagnostics>? get diagnosticsStream => null;

  @override
  Future<bool> isModelCached() async => true;

  Future<void> _ensureWebBridgeLoaded() async {
    if (tajweedWebBridge != null) return;
    const jsSnippet = '''
      new Promise(function(resolve) {
        if (window.TajweedWebBridge) return resolve(true);
        var s = document.createElement('script');
        s.src = 'assets/packages/quran_tajweedformer/assets/web/tajweedformer_web.js';
        s.onload = function() { resolve(true); };
        s.onerror = function() {
          var s2 = document.createElement('script');
          s2.src = 'js/tajweedformer_web.js';
          s2.onload = function() { resolve(true); };
          s2.onerror = function() { resolve(false); };
          document.head.appendChild(s2);
        };
        document.head.appendChild(s);
      })
    ''';
    try {
      final promise = _jsEval(jsSnippet.toJS) as JSPromise?;
      if (promise != null) {
        await promise.toDart;
      }
    } catch (_) {}
  }

  @override
  Future<void> initialize() async {
    if (_isInitialized) return;
    await _ensureWebBridgeLoaded();
    final bridge = tajweedWebBridge;
    if (bridge != null) {
      try {
        final keyStr = webApiKey ??
            const String.fromEnvironment('QURANLAB_WEB_KEY', defaultValue: '');
        final key = keyStr.isNotEmpty ? keyStr.toJS : null;
        final res = await bridge.init(key).toDart;
        if (res.toDart) {
          _isInitialized = true;
          _startSession();
        }
      } catch (_) {}
    }
  }

  void _startSession() {
    final bridge = tajweedWebBridge;
    if (bridge == null) return;

    void onChunk(JSString text, JSBoolean isFinal) {
      _outputController.add(
        TranscriptionResult(
          text: text.toDart,
          isFinal: isFinal.toDart,
          startTime: DateTime.now().millisecondsSinceEpoch,
          streamEpoch: _currentStreamEpoch,
        ),
      );
    }

    bridge.startSession(onChunk.toJS);
  }

  @override
  bool transcribe(Float32List audioChunk, {bool isFinal = false}) {
    final bridge = tajweedWebBridge;
    if (bridge != null && _isInitialized) {
      final pushed = bridge.pushAudio(audioChunk.toJS).toDart;
      if (!pushed) return false;
      if (isFinal) {
        // The take is complete: let the engine append its tail and emit the
        // final transcription.
        bridge.finish();
      }
      return true;
    }
    return false;
  }

  @override
  void resetBuffer() {
    _currentStreamEpoch++;
    tajweedWebBridge?.reset();
  }

  @override
  void flushThenReset() {
    _currentStreamEpoch++;
    // finish() appends the engine's tail, emits the final transcription, and
    // resets the stream for the next take.
    tajweedWebBridge?.finish();
  }

  @override
  void destroy() {
    tajweedWebBridge?.destroy();
    _isInitialized = false;
  }
}

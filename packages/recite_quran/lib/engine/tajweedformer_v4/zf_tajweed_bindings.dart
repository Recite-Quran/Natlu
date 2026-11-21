// lib/engine/tajweedformer_v4/zf_tajweed_bindings.dart
// Low-level Dart FFI bindings for zf_tajweed.h (TajweedFormer V4 C Engine).

import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';

// ═══════════════════════════════════════════════════════════════════════════════
// CONSTANTS & ENUMS
// ═══════════════════════════════════════════════════════════════════════════════

const int zfTajweedApiVersion = 4;
const int zfTajweedVocab = 38;
const int zfTajweedBlank = 0;

abstract class ZfTajweedHeadsFlags {
  static const int logProbs = 1 << 0;
  static const int inter1 = 1 << 1;
  static const int inter4 = 1 << 2;
  static const int id = 1 << 3;
  static const int timing = 1 << 4;
  static const int gem = 1 << 5;
  static const int tafkheem = 1 << 6;
  static const int ghunna = 1 << 7;
  static const int qalqalah = 1 << 8;
  static const int face = 1 << 9;
  static const int boundary = 1 << 10;
  static const int conf = 1 << 11;
  static const int defaults = logProbs | inter1 | timing | gem | qalqalah;
  static const int all = (1 << 12) - 1;
}

// ═══════════════════════════════════════════════════════════════════════════════
// STRUCTS
// ═══════════════════════════════════════════════════════════════════════════════

final class ZfTajweedOpenOptions extends Struct {
  @Size()
  external int structSize;

  external Pointer<Utf8> context;

  @Int32()
  external int loadEngine;

  @Int32()
  external int threads;

  @Int32()
  external int sampleRate;

  @Int32()
  external int batch;

  @Int32()
  external int noPin;
}

final class ZfTajweedHeads extends Struct {
  @Int32()
  external int n40;

  @Int32()
  external int n20;

  @Int32()
  external int vocab;

  external Pointer<Float> logProbs;
  external Pointer<Float> inter1LogProbs;
  external Pointer<Float> inter4LogProbs;
  external Pointer<Float> idLogProbs;
  external Pointer<Float> timingLogProbs;
  external Pointer<Float> gem;
  external Pointer<Float> attrTafkheem;
  external Pointer<Float> attrGhunna;
  external Pointer<Float> attrQalqalah;
  external Pointer<Float> attrFace;
  external Pointer<Float> boundary;
  external Pointer<Float> conf;
}

final class ZfTajweedTop2 extends Struct {
  @Int32()
  external int token;

  @Int32()
  external int runnerUp;

  @Float()
  external double logProb;

  @Float()
  external double runnerUpLogProb;

  @Float()
  external double margin;
}

// ═══════════════════════════════════════════════════════════════════════════════
// NATIVE FUNCTION SIGNATURES
// ═══════════════════════════════════════════════════════════════════════════════

typedef ZfTajweedVersionC = Pointer<Utf8> Function();
typedef ZfTajweedVersionDart = Pointer<Utf8> Function();

typedef ZfTajweedApiVersionC = Int32 Function();
typedef ZfTajweedApiVersionDart = int Function();

typedef ZfTajweedOpenDefaultOptionsC = ZfTajweedOpenOptions Function();
typedef ZfTajweedOpenDefaultOptionsDart = ZfTajweedOpenOptions Function();

typedef ZfTajweedModelOpenC = Pointer<Void> Function(
  Pointer<Utf8> modelDir,
  Pointer<ZfTajweedOpenOptions> options,
  Pointer<Pointer<Utf8>> error,
);
typedef ZfTajweedModelOpenDart = Pointer<Void> Function(
  Pointer<Utf8> modelDir,
  Pointer<ZfTajweedOpenOptions> options,
  Pointer<Pointer<Utf8>> error,
);

typedef ZfTajweedModelCloseC = Void Function(Pointer<Void> model);
typedef ZfTajweedModelCloseDart = void Function(Pointer<Void> model);

typedef ZfTajweedModelChunkMsC = Int32 Function(Pointer<Void> model);
typedef ZfTajweedModelChunkMsDart = int Function(Pointer<Void> model);

typedef ZfTajweedTokenNameC = Pointer<Utf8> Function(
    Pointer<Void> model, Int32 id);
typedef ZfTajweedTokenNameDart = Pointer<Utf8> Function(
    Pointer<Void> model, int id);

typedef ZfTajweedStreamCreateC = Pointer<Void> Function(
  Pointer<Void> model,
  Pointer<Pointer<Utf8>> error,
);
typedef ZfTajweedStreamCreateDart = Pointer<Void> Function(
  Pointer<Void> model,
  Pointer<Pointer<Utf8>> error,
);

typedef ZfTajweedStreamDestroyC = Void Function(Pointer<Void> stream);
typedef ZfTajweedStreamDestroyDart = void Function(Pointer<Void> stream);

typedef ZfTajweedStreamResetC = Void Function(Pointer<Void> stream);
typedef ZfTajweedStreamResetDart = void Function(Pointer<Void> stream);

typedef ZfTajweedStreamPushAudioC = Int32 Function(
  Pointer<Void> stream,
  Pointer<Float> samples,
  Int32 n,
);
typedef ZfTajweedStreamPushAudioDart = int Function(
  Pointer<Void> stream,
  Pointer<Float> samples,
  int n,
);

typedef ZfTajweedStreamFinishC = Int32 Function(Pointer<Void> stream);
typedef ZfTajweedStreamFinishDart = int Function(Pointer<Void> stream);

typedef ZfTajweedStreamLastErrorC = Pointer<Utf8> Function(
    Pointer<Void> stream);
typedef ZfTajweedStreamLastErrorDart = Pointer<Utf8> Function(
    Pointer<Void> stream);

typedef ZfTajweedStreamHeadsC = Int32 Function(
  Pointer<Void> stream,
  Pointer<ZfTajweedHeads> out,
);
typedef ZfTajweedStreamHeadsDart = int Function(
  Pointer<Void> stream,
  Pointer<ZfTajweedHeads> out,
);

typedef ZfTajweedStreamGreedyC = Int32 Function(
  Pointer<Void> stream,
  Pointer<Int32> ids,
  Int32 max,
);
typedef ZfTajweedStreamGreedyDart = int Function(
  Pointer<Void> stream,
  Pointer<Int32> ids,
  int max,
);

typedef ZfTajweedStreamTop2C = Int32 Function(
  Pointer<Void> stream,
  Pointer<Pointer<ZfTajweedTop2>> out,
);
typedef ZfTajweedStreamTop2Dart = int Function(
  Pointer<Void> stream,
  Pointer<Pointer<ZfTajweedTop2>> out,
);

typedef ZfTajweedStreamSetHeadsC = Int32 Function(
    Pointer<Void> stream, Uint32 heads);
typedef ZfTajweedStreamSetHeadsDart = int Function(
    Pointer<Void> stream, int heads);

typedef ZfTajweedReferenceOpenC = Pointer<Void> Function(
  Pointer<Utf8> path,
  Pointer<Pointer<Utf8>> error,
);
typedef ZfTajweedReferenceOpenDart = Pointer<Void> Function(
  Pointer<Utf8> path,
  Pointer<Pointer<Utf8>> error,
);

typedef ZfTajweedReferenceCloseC = Void Function(Pointer<Void> ref);
typedef ZfTajweedReferenceCloseDart = void Function(Pointer<Void> ref);

typedef ZfTajweedReferenceUnitsC = Int32 Function(
  Pointer<Void> ref,
  Int32 surah,
  Int32 ayah,
  Pointer<Pointer<Int32>> units,
  Pointer<Pointer<Int32>> wordOfUnit,
  Pointer<Int32> nWords,
);
typedef ZfTajweedReferenceUnitsDart = int Function(
  Pointer<Void> ref,
  int surah,
  int ayah,
  Pointer<Pointer<Int32>> units,
  Pointer<Pointer<Int32>> wordOfUnit,
  Pointer<Int32> nWords,
);

// ═══════════════════════════════════════════════════════════════════════════════
// HIGH-LEVEL FFI BINDINGS LOADER
// ═══════════════════════════════════════════════════════════════════════════════

class ZfTajweedBindings {
  final DynamicLibrary lib;

  late final ZfTajweedVersionDart version;
  late final ZfTajweedApiVersionDart apiVersion;
  late final ZfTajweedOpenDefaultOptionsDart openDefaultOptions;
  late final ZfTajweedModelOpenDart modelOpen;
  late final ZfTajweedModelCloseDart modelClose;
  late final ZfTajweedModelChunkMsDart modelChunkMs;
  late final ZfTajweedTokenNameDart tokenName;
  late final ZfTajweedStreamCreateDart streamCreate;
  late final ZfTajweedStreamDestroyDart streamDestroy;
  late final ZfTajweedStreamResetDart streamReset;
  late final ZfTajweedStreamPushAudioDart streamPushAudio;
  late final ZfTajweedStreamFinishDart streamFinish;
  late final ZfTajweedStreamLastErrorDart streamLastError;
  late final ZfTajweedStreamHeadsDart streamHeads;
  late final ZfTajweedStreamGreedyDart streamGreedy;
  late final ZfTajweedStreamTop2Dart streamTop2;
  late final ZfTajweedStreamSetHeadsDart streamSetHeads;
  late final ZfTajweedReferenceOpenDart referenceOpen;
  late final ZfTajweedReferenceCloseDart referenceClose;
  late final ZfTajweedReferenceUnitsDart referenceUnits;

  ZfTajweedBindings(this.lib) {
    version = lib.lookupFunction<ZfTajweedVersionC, ZfTajweedVersionDart>(
        'zf_tajweed_version');
    apiVersion =
        lib.lookupFunction<ZfTajweedApiVersionC, ZfTajweedApiVersionDart>(
            'zf_tajweed_api_version');
    openDefaultOptions = lib.lookupFunction<ZfTajweedOpenDefaultOptionsC,
        ZfTajweedOpenDefaultOptionsDart>('zf_tajweed_open_default_options');
    modelOpen = lib.lookupFunction<ZfTajweedModelOpenC, ZfTajweedModelOpenDart>(
        'zf_tajweed_model_open');
    modelClose =
        lib.lookupFunction<ZfTajweedModelCloseC, ZfTajweedModelCloseDart>(
            'zf_tajweed_model_close');
    modelChunkMs =
        lib.lookupFunction<ZfTajweedModelChunkMsC, ZfTajweedModelChunkMsDart>(
            'zf_tajweed_model_chunk_ms');
    tokenName = lib.lookupFunction<ZfTajweedTokenNameC, ZfTajweedTokenNameDart>(
        'zf_tajweed_token_name');
    streamCreate =
        lib.lookupFunction<ZfTajweedStreamCreateC, ZfTajweedStreamCreateDart>(
            'zf_tajweed_stream_create');
    streamDestroy =
        lib.lookupFunction<ZfTajweedStreamDestroyC, ZfTajweedStreamDestroyDart>(
            'zf_tajweed_stream_destroy');
    streamReset =
        lib.lookupFunction<ZfTajweedStreamResetC, ZfTajweedStreamResetDart>(
            'zf_tajweed_stream_reset');
    streamPushAudio = lib.lookupFunction<ZfTajweedStreamPushAudioC,
        ZfTajweedStreamPushAudioDart>('zf_tajweed_stream_push_audio');
    streamFinish =
        lib.lookupFunction<ZfTajweedStreamFinishC, ZfTajweedStreamFinishDart>(
            'zf_tajweed_stream_finish');
    streamLastError = lib.lookupFunction<ZfTajweedStreamLastErrorC,
        ZfTajweedStreamLastErrorDart>('zf_tajweed_stream_last_error');
    streamHeads =
        lib.lookupFunction<ZfTajweedStreamHeadsC, ZfTajweedStreamHeadsDart>(
            'zf_tajweed_stream_heads');
    streamGreedy =
        lib.lookupFunction<ZfTajweedStreamGreedyC, ZfTajweedStreamGreedyDart>(
            'zf_tajweed_stream_greedy');
    streamTop2 =
        lib.lookupFunction<ZfTajweedStreamTop2C, ZfTajweedStreamTop2Dart>(
            'zf_tajweed_stream_top2');
    streamSetHeads = lib.lookupFunction<ZfTajweedStreamSetHeadsC,
        ZfTajweedStreamSetHeadsDart>('zf_tajweed_stream_set_heads');
    referenceOpen =
        lib.lookupFunction<ZfTajweedReferenceOpenC, ZfTajweedReferenceOpenDart>(
            'zf_tajweed_reference_open');
    referenceClose = lib.lookupFunction<ZfTajweedReferenceCloseC,
        ZfTajweedReferenceCloseDart>('zf_tajweed_reference_close');
    referenceUnits = lib.lookupFunction<ZfTajweedReferenceUnitsC,
        ZfTajweedReferenceUnitsDart>('zf_tajweed_reference_units');
  }

  /// Automatically resolves and loads the native dynamic library based on platform.
  factory ZfTajweedBindings.load({String? customLibPath}) {
    if (customLibPath != null) {
      return ZfTajweedBindings(DynamicLibrary.open(customLibPath));
    }

    if (Platform.isAndroid) {
      return ZfTajweedBindings(DynamicLibrary.open('libzf_tajweed.so'));
    } else if (Platform.isIOS || Platform.isMacOS) {
      try {
        return ZfTajweedBindings(DynamicLibrary.process());
      } catch (_) {
        return ZfTajweedBindings(
            DynamicLibrary.open('zf_tajweed.framework/zf_tajweed'));
      }
    } else if (Platform.isWindows) {
      try {
        return ZfTajweedBindings(DynamicLibrary.open('zf_tajweed.dll'));
      } catch (_) {
        final exeDir = File(Platform.resolvedExecutable).parent.path;
        final candidate = '$exeDir/zf_tajweed.dll';
        if (File(candidate).existsSync()) {
          return ZfTajweedBindings(DynamicLibrary.open(candidate));
        }
        rethrow;
      }
    } else if (Platform.isLinux) {
      return ZfTajweedBindings(DynamicLibrary.open('libzf_tajweed.so'));
    }
    throw UnsupportedError('Unsupported platform for TajweedFormer C engine');
  }
}

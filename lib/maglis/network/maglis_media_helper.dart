import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

/// MaglisMediaHelper
///
/// Handles audio constraints, SDP Opus munging, candidate validation,
/// and hardware device preflighting for Maglis P2P sessions.
class MaglisMediaHelper {
  static final Random _rng = Random();

  // Jittered exponential backoff retry delays (LiveKit production standard)
  static const List<int> defaultRetryDelaysInMs = [
    0,
    300,
    1200,
    2700,
    4800,
    7000,
  ];

  static int reconnectDelayInMs(int retryCount) {
    final delay = defaultRetryDelaysInMs[
        retryCount.clamp(0, defaultRetryDelaysInMs.length - 1)];
    if (delay == 0) {
      return (_rng.nextDouble() * 150).round();
    }
    return (delay * (0.5 + _rng.nextDouble())).round();
  }

  static final RegExp _ipv6LoopbackTokenRegex =
      RegExp(r'(?:^|\s)::1(?:\s|$)');

  /// Filters out private/loopback/bogus ICE candidates to conserve bandwidth
  /// while preserving valid public IPv6 candidates ending in `::1` (e.g. `2001:4860:4860::1`).
  static bool isValidCandidate(String? cand) {
    if (cand == null || cand.isEmpty) return false;
    final lower = cand.toLowerCase();
    if (lower.contains('fe80:') ||
        lower.contains(' 169.254.') ||
        lower.contains('127.0.0.') ||
        _ipv6LoopbackTokenRegex.hasMatch(lower) ||
        lower.contains('localhost') ||
        lower.contains(' 0.0.0.0 ')) {
      return false;
    }
    return true;
  }

  /// High-definition audio constraints with Auto Gain Control for loud output on all platforms.
  static Map<String, dynamic> buildAudioConstraints({String? inputDeviceId}) {
    return {
      'audio': {
        'echoCancellation': true,
        'autoGainControl':
            true, // Essential for full volume on Windows, desktop & mobile
        'noiseSuppression':
            false, // Preserve natural Tajweed recitation without clipping
        'highpassFilter':
            false, // Disable telephony bass cutoff to preserve natural vocal warmth
        'sampleRate': 48000,
        'sampleSize': 16,
        'channelCount': 1,
        if (inputDeviceId != null) 'deviceId': inputDeviceId,

        // Standard WebRTC constraints parsed into native RTCMediaConstraints
        'optional': [
          {'echoCancellation': true},
          {'googEchoCancellation': true},
          {'googEchoCancellation2': true},
          {'googDAEchoCancellation': true},
          {'autoGainControl': true},
          {'googAutoGainControl': true},
          {'noiseSuppression': false},
          {'googNoiseSuppression': false},
          {'googNoiseSuppression2': false},
          {'highpassFilter': false},
          {'googHighpassFilter': false},
          {'googTypingNoiseDetection': false},
          if (inputDeviceId != null) {'sourceId': inputDeviceId},
        ],
      },
      'video': false,
    };
  }

  /// Munges Opus SDP to inject production Tajweed audio profile and RFC 4566 bandwidth limits.
  static String mungeOpusSdp(
    String sdp, {
    int maxAverageBitrate = 48000,
    bool enableDtx = false,
  }) {
    final rtpmapRegex =
        RegExp(r'a=rtpmap:(\d+)\s+opus/48000/2', caseSensitive: false);
    final match = rtpmapRegex.firstMatch(sdp);
    if (match == null) return sdp;
    final pt = match.group(1)!;

    // Production Tajweed Voice Profile for High Packet-Loss & Slow Network Resilience:
    // - useinbandfec=1: In-Band Forward Error Correction seamless loss repair
    // - usedtx=0 (or 1): Continuous natural Tajweed audio preserving quiet Madd & breath pauses
    // - maxaveragebitrate=48000: Studio-grade full-band audio matching LiveKit standard, cuts bandwidth by 50%
    // - maxplaybackrate=48000: Full-band 48 kHz
    // - sprop-maxcapturerate=48000: 48 kHz capture
    // - ptime=20: Optimal frame duration for audio fidelity
    // - minptime=10: Low-latency dynamic adaptation
    // - maxptime=20: Consistent packet pacing
    // - cbr=0: Dynamic Opus allocation
    final opusParams = [
      'useinbandfec=1',
      if (enableDtx) 'usedtx=1' else 'usedtx=0',
      'cbr=0',
      'ptime=20',
      'minptime=10',
      'maxptime=20',
      'stereo=0',
      'sprop-stereo=0',
      'maxaveragebitrate=$maxAverageBitrate',
      'maxplaybackrate=48000',
      'sprop-maxcapturerate=48000',
    ].join(';');

    String result = sdp;
    final lineEnd = result.contains('\r\n') ? '\r\n' : '\n';
    final fmtpRegex = RegExp('a=fmtp:$pt[^\r\n]*');
    if (fmtpRegex.hasMatch(result)) {
      result = result.replaceFirst(fmtpRegex, 'a=fmtp:$pt $opusParams');
    } else {
      result = result.replaceFirst(
        match.group(0)!,
        '${match.group(0)!}${lineEnd}a=fmtp:$pt $opusParams',
      );
    }

    // RFC 4566 compliant bandwidth caps (b=AS / b=TIAS):
    // Must be placed before any 'a=' attribute lines in the audio media section.
    final int asKbps = maxAverageBitrate <= 48000 ? 64 : 128;
    final int tiasBps = maxAverageBitrate <= 48000 ? 64000 : 128000;

    final basRegex = RegExp(r'b=AS:\d+');
    final btiasRegex = RegExp(r'b=TIAS:\d+');

    final hasBas = result.contains(basRegex);
    final hasBtias = result.contains(btiasRegex);

    if (hasBas) {
      result = result.replaceAll(basRegex, 'b=AS:$asKbps');
    }
    if (hasBtias) {
      result = result.replaceAll(btiasRegex, 'b=TIAS:$tiasBps');
    }

    if (!hasBas && !hasBtias) {
      final audioMlineIdx =
          result.indexOf(RegExp(r'm=audio\s+', caseSensitive: false));
      if (audioMlineIdx != -1) {
        final firstAttrAfterAudio =
            result.indexOf(RegExp(r'\r?\na='), audioMlineIdx);
        if (firstAttrAfterAudio != -1) {
          result = result.replaceRange(
            firstAttrAfterAudio,
            firstAttrAfterAudio,
            '${lineEnd}b=AS:$asKbps${lineEnd}b=TIAS:$tiasBps',
          );
        }
      }
    }

    return result;
  }

  /// Pre-flight check for desktop devices (inspired by noscall).
  /// Verifies hardware audio input presence before attempting media stream creation.
  static Future<bool> preflightDesktopMediaDevices() async {
    if (kIsWeb ||
        (defaultTargetPlatform != TargetPlatform.windows &&
            defaultTargetPlatform != TargetPlatform.linux &&
            defaultTargetPlatform != TargetPlatform.macOS)) {
      return true;
    }
    try {
      final devices = await navigator.mediaDevices.enumerateDevices();
      return devices.any((d) => d.kind == 'audioinput');
    } catch (_) {
      return true;
    }
  }
}
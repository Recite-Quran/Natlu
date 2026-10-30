import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:audio_session/audio_session.dart';
import 'package:bip340/bip340.dart' as bip340;
import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart' hide Hmac;
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

enum MaglisPacketType {
  snapshot,
  recitationUpdate,
  floorClaim,
  floorRelease,
  ping,
  pong,
}

class MaglisPacket {
  final MaglisPacketType type;
  final int seq;
  final String senderId;
  final int page;
  final int surah;
  final int ayah;
  final int? activeWord;
  final List<int> greenWords;
  final List<int> yellowWords;
  final List<int> redWords;
  final String? activeReciterId;
  final Map<String, int>? cumulative;
  final Map<String, List<Map<String, dynamic>>>? errors;
  final int ts;

  const MaglisPacket({
    required this.type,
    required this.seq,
    required this.senderId,
    required this.page,
    required this.surah,
    required this.ayah,
    this.activeWord,
    this.greenWords = const [],
    this.yellowWords = const [],
    this.redWords = const [],
    this.activeReciterId,
    this.cumulative,
    this.errors,
    required this.ts,
  });

  String pack() {
    final map = <String, dynamic>{
      't': type.index,
      'q': seq,
      'u': senderId,
      'p': page,
      's': surah,
      'a': ayah,
      'm': ts,
    };
    if (activeWord != null) map['w'] = activeWord;
    if (greenWords.isNotEmpty) map['g'] = greenWords;
    if (yellowWords.isNotEmpty) map['y'] = yellowWords;
    if (redWords.isNotEmpty) map['r'] = redWords;
    if (activeReciterId != null) map['c'] = activeReciterId;
    if (cumulative != null && cumulative!.isNotEmpty) map['k'] = cumulative;
    if (errors != null && errors!.isNotEmpty) map['e'] = errors;
    return jsonEncode(map);
  }

  factory MaglisPacket.unpack(String raw) {
    final m = jsonDecode(raw) as Map<String, dynamic>;
    final tIdx = (m['t'] as int?) ?? 0;

    return MaglisPacket(
      type: MaglisPacketType
          .values[tIdx.clamp(0, MaglisPacketType.values.length - 1)],
      seq: (m['q'] as int?) ?? 0,
      senderId: (m['u'] as String?) ?? '',
      page: (m['p'] as int?) ?? 1,
      surah: (m['s'] as int?) ?? 1,
      ayah: (m['a'] as int?) ?? 1,
      activeWord: m['w'] as int?,
      greenWords: (m['g'] as List<dynamic>?)?.map((e) => e as int).toList() ??
          const [],
      yellowWords: (m['y'] as List<dynamic>?)?.map((e) => e as int).toList() ??
          const [],
      redWords:
          (m['r'] as List<dynamic>?)?.map((e) => e as int).toList() ?? const [],
      activeReciterId: m['c'] as String?,
      cumulative: (m['k'] as Map<String, dynamic>?)?.map(
        (k, v) => MapEntry(k, v as int),
      ),
      errors: (m['e'] as Map<String, dynamic>?)?.map(
        (k, v) => MapEntry(
          k,
          (v as List<dynamic>)
              .map((e) => Map<String, dynamic>.from(e as Map))
              .toList(),
        ),
      ),
      ts: (m['m'] as int?) ?? DateTime.now().millisecondsSinceEpoch,
    );
  }
}

class MaglisSignal {
  final String type; // 'beacon' | 'offer' | 'answer' | 'ice' | 'leave'
  final String senderId;
  final String? targetId;
  final Map<String, dynamic> data;

  const MaglisSignal({
    required this.type,
    required this.senderId,
    this.targetId,
    required this.data,
  });

  String pack() => jsonEncode({
        't': type,
        'u': senderId,
        if (targetId != null) 'to': targetId,
        'd': data,
      });

  factory MaglisSignal.unpack(String raw) {
    final m = jsonDecode(raw) as Map<String, dynamic>;
    return MaglisSignal(
      type: (m['t'] as String?) ?? '',
      senderId: (m['u'] as String?) ?? '',
      targetId: m['to'] as String?,
      data: (m['d'] as Map<String, dynamic>?) ?? const {},
    );
  }
}

class MaglisCrypto {
  static final Random _rng = Random.secure();
  static final AesGcm _aes = AesGcm.with256bits();

  // Internal 256-bit application pepper to prevent public relay rainbow-table attacks on 5-digit room codes
  static const List<int> _appPepper = [
    0x51, 0x75, 0x72, 0x61, 0x6e, 0x4d, 0x61, 0x67,
    0x6c, 0x69, 0x73, 0x53, 0x65, 0x63, 0x75, 0x72,
    0x65, 0x50, 0x65, 0x70, 0x70, 0x65, 0x72, 0x32,
    0x30, 0x32, 0x36, 0x5f, 0x76, 0x32, 0x21, 0x24,
  ];

  static int get currentEpoch =>
      DateTime.now().millisecondsSinceEpoch ~/ (15 * 60 * 1000); // 15-minute rotation window

  static String randomHex32() {
    final bytes = List<int>.generate(32, (_) => _rng.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// Derives blinded tag using HMAC-SHA256 with 256-bit app pepper and dynamic 15-minute epoch.
  /// Without the internal app pepper, no third-party relay scraper can rainbow-table 5-digit codes.
  static String blindedTag(String code, {int? epoch}) {
    final ep = epoch ?? currentEpoch;
    final hmac = Hmac(sha256, _appPepper);
    final digest = hmac.convert(utf8.encode('maglis_v2_${ep}_${code.trim()}'));
    return digest.toString().substring(0, 32);
  }

  /// Returns current and previous 15-minute epoch tags to ensure uninterrupted connection
  /// across 15-minute boundary transitions.
  static List<String> activeBlindedTags(String code) {
    final ep = currentEpoch;
    return [
      blindedTag(code, epoch: ep),
      blindedTag(code, epoch: ep - 1),
    ];
  }

  static final Map<String, SecretKey> _keyCache = {};

  static SecretKey _deriveKey(String code) {
    final trimmed = code.trim();
    return _keyCache.putIfAbsent(trimmed, () {
      final hmac = Hmac(sha256, _appPepper);
      final bytes = hmac.convert(utf8.encode('maglis_v2_aes_$trimmed')).bytes;
      return SecretKey(bytes);
    });
  }

  /// Generates a HMAC admission token proving knowledge of the room code and peer identity
  static String admissionToken(String code, String peerId) {
    final hmac = Hmac(sha256, _appPepper);
    final digest =
        hmac.convert(utf8.encode('maglis_v2_auth_${code.trim()}_$peerId'));
    return digest.toString().substring(0, 16);
  }

  /// Validates an incoming admission token
  static bool verifyAdmissionToken(String code, String peerId, String token) {
    return admissionToken(code, peerId) == token;
  }

  static Future<String> encrypt(String plain, String code) async {
    final nonce = List<int>.generate(12, (_) => _rng.nextInt(256));
    final box = await _aes.encrypt(
      utf8.encode(plain),
      secretKey: _deriveKey(code),
      nonce: nonce,
    );
    return base64Encode(box.concatenation());
  }

  static Future<String?> decrypt(String b64, String code) async {
    try {
      final raw = base64Decode(b64);
      if (raw.length < 28) return null;
      final box = SecretBox.fromConcatenation(
        raw,
        nonceLength: 12,
        macLength: 16,
      );
      final clear = await _aes.decrypt(box, secretKey: _deriveKey(code));
      return utf8.decode(clear);
    } catch (_) {
      return null;
    }
  }

  static final Map<String, String> _pubKeyCache = {};

  static String getPublicKey(String privHex) {
    return _pubKeyCache.putIfAbsent(privHex, () => bip340.getPublicKey(privHex));
  }

  static String signNostrEvent({
    required String privHex,
    String? pubHex,
    required String tag,
    List<String>? additionalTags,
    required String content,
  }) {
    final pub = pubHex ?? getPublicKey(privHex);
    final createdAt = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    const kind = 20000; // Ephemeral Nostr Event
    final tags = <List<String>>[
      ['t', tag],
      if (additionalTags != null)
        for (final t in additionalTags) ['t', t],
    ];
    final serialized = jsonEncode([0, pub, createdAt, kind, tags, content]);
    final idHex = sha256.convert(utf8.encode(serialized)).toString();
    final sigHex = bip340.sign(privHex, idHex, randomHex32());

    return jsonEncode([
      'EVENT',
      {
        'id': idHex,
        'pubkey': pub,
        'created_at': createdAt,
        'kind': kind,
        'tags': tags,
        'content': content,
        'sig': sigHex,
      }
    ]);
  }

  /// Asynchronously signs Nostr event in background isolate so UI thread never drops frames
  static Future<String> signNostrEventAsync({
    required String privHex,
    String? pubHex,
    required String tag,
    List<String>? additionalTags,
    required String content,
  }) {
    return compute(
      _signNostrEventWorker,
      _NostrSignParams(
        privHex: privHex,
        pubHex: pubHex,
        tag: tag,
        additionalTags: additionalTags,
        content: content,
      ),
    );
  }
}

class _NostrSignParams {
  final String privHex;
  final String? pubHex;
  final String tag;
  final List<String>? additionalTags;
  final String content;

  const _NostrSignParams({
    required this.privHex,
    this.pubHex,
    required this.tag,
    this.additionalTags,
    required this.content,
  });
}

String _signNostrEventWorker(_NostrSignParams p) {
  return MaglisCrypto.signNostrEvent(
    privHex: p.privHex,
    pubHex: p.pubHex,
    tag: p.tag,
    additionalTags: p.additionalTags,
    content: p.content,
  );
}

enum MaglisJoinResult {
  success,
  notFound,
  full,
  error,
}

class MaglisPlatform {
  static StreamSubscription? _deviceChangeSub;
  static StreamSubscription? _interruptionSub;
  static bool _audioInitialized = false;

  static Future<bool> requestPermissions() async {
    if (kIsWeb) return true;
    try {
      if (Platform.isAndroid || Platform.isIOS) {
        final mic = await Permission.microphone.request();
        return mic.isGranted;
      }
      // On Desktop (Windows, macOS, Linux), permissions are handled by the OS settings
      return true;
    } catch (_) {}
    return true;
  }

  static Future<void> initAudio() async {
    if (kIsWeb) return;
    if (_audioInitialized) return;
    _audioInitialized = true;

    try {
      final androidConfig = AndroidAudioConfiguration(
        manageAudioFocus: true,
        androidAudioMode: AndroidAudioMode.inCommunication,
        androidAudioFocusMode: AndroidAudioFocusMode.gain,
        androidAudioStreamType: AndroidAudioStreamType.music,
        androidAudioAttributesUsageType:
            AndroidAudioAttributesUsageType.media,
        androidAudioAttributesContentType:
            AndroidAudioAttributesContentType.music,
        forceHandleAudioRouting: true,
      );

      // 1. Initialize WebRTC audio pipeline cleanly with music media attributes
      try {
        await WebRTC.initialize(options: {
          'audioSampleRate': 48000,
          'audioOutputSampleRate': 48000,
          'androidUseHardwareAudioProcessing': false, // Software APM handles AGC & AEC cleanly without hardware noise suppression crushing Quran recitation
          if (Platform.isAndroid)
            'androidAudioConfiguration': androidConfig.toMap(),
        });
      } catch (_) {}

      // 2. Set silent microphone mute mode (prevents OS beep on iOS/macOS)
      try {
        if (Platform.isIOS || Platform.isMacOS) {
          await Helper.setMicrophoneMuteMode(MicrophoneMuteMode.inputMixer);
        }
      } catch (_) {}

      // 3. Configure platform audio routing for high-fidelity media loudspeaker playout
      if (Platform.isAndroid) {
        await Helper.setAndroidAudioConfiguration(androidConfig);
        await Helper.setSpeakerphoneOn(true);
      } else if (Platform.isIOS) {
        try {
          await Helper.ensureAudioSession();
        } catch (_) {}
        await Helper.setAppleAudioConfiguration(
          AppleAudioConfiguration(
            appleAudioCategory: AppleAudioCategory.playAndRecord,
            appleAudioMode: AppleAudioMode.videoChat, // videoChat provides loud loudspeaker handsfree playout + full AEC
            appleAudioCategoryOptions: {
              AppleAudioCategoryOption.defaultToSpeaker,
              AppleAudioCategoryOption.allowBluetooth,
              AppleAudioCategoryOption.allowBluetoothA2DP,
              AppleAudioCategoryOption.allowAirPlay,
            },
          ),
        );
        await Helper.setSpeakerphoneOn(true);
      }

      // 4. Configure system audio_session for loud media playout & hardware speakerphone
      if (Platform.isAndroid || Platform.isIOS) {
        try {
          final session = await AudioSession.instance;
          await session.configure(
            AudioSessionConfiguration(
              avAudioSessionCategory: AVAudioSessionCategory.playAndRecord,
              avAudioSessionCategoryOptions:
                  AVAudioSessionCategoryOptions.defaultToSpeaker |
                       AVAudioSessionCategoryOptions.allowBluetooth |
                      AVAudioSessionCategoryOptions.allowBluetoothA2dp |
                      AVAudioSessionCategoryOptions.allowAirPlay,
              avAudioSessionMode: AVAudioSessionMode.videoChat,
              androidAudioAttributes: const AndroidAudioAttributes(
                contentType: AndroidAudioContentType.music,
                usage: AndroidAudioUsage.media,
              ),
              androidAudioFocusGainType: AndroidAudioFocusGainType.gain,
              androidWillPauseWhenDucked: false,
            ),
          );
          await session.setActive(true);

          // Auto-switch to bluetooth or speakerphone when devices are plugged or unplugged
          _deviceChangeSub?.cancel();
          _deviceChangeSub = session.devicesChangedEventStream.listen((_) {
            setSpeaker(true);
          });

          // Recover audio route if interrupted by incoming phone call or system alarm
          _interruptionSub?.cancel();
          _interruptionSub = session.interruptionEventStream.listen((event) {
            if (!event.begin) {
              session.setActive(true).then((_) {
                setSpeaker(true);
              }).catchError((_) {});
            }
          });
        } catch (_) {}
      }

      // Final speakerphone enforcement
      await setSpeaker(true);
    } catch (e) {
      debugPrint('[MaglisPlatform] initAudio error: $e');
    }
  }

  static Future<void> setSpeaker(bool on) async {
    if (kIsWeb) return;
    try {
      if (Platform.isAndroid || Platform.isIOS) {
        await Helper.setSpeakerphoneOn(on);
      }
    } catch (_) {}
  }

  static Future<void> resetAudio() async {
    if (kIsWeb) return;
    try {
      _audioInitialized = false;
      _deviceChangeSub?.cancel();
      _deviceChangeSub = null;
      _interruptionSub?.cancel();
      _interruptionSub = null;

      if (Platform.isAndroid) {
        await Helper.setAndroidAudioConfiguration(
          AndroidAudioConfiguration.media,
        );
        await Helper.clearAndroidCommunicationDevice();
        await Helper.setSpeakerphoneOn(false);
      } else if (Platform.isIOS) {
        await Helper.setAppleAudioConfiguration(
          AppleAudioConfiguration(
            appleAudioCategory: AppleAudioCategory.playback,
          ),
        );
        await Helper.setSpeakerphoneOn(false);
      }

      // Restore system audio_session for standard Quran playback
      final session = await AudioSession.instance;
      await session.configure(
        const AudioSessionConfiguration(
          avAudioSessionCategory: AVAudioSessionCategory.playback,
          avAudioSessionCategoryOptions:
              AVAudioSessionCategoryOptions.duckOthers,
          avAudioSessionMode: AVAudioSessionMode.spokenAudio,
          androidAudioAttributes: AndroidAudioAttributes(
            contentType: AndroidAudioContentType.music,
            usage: AndroidAudioUsage.media,
          ),
          androidAudioFocusGainType: AndroidAudioFocusGainType.gain,
        ),
      );
    } catch (_) {}
  }

  static Future<void> setWakeLock(bool on) async {
    try {
      if (on) {
        await WakelockPlus.enable();
      } else {
        await WakelockPlus.disable();
      }
    } catch (_) {}
  }
}

/// Converts any Eastern Arabic digits (٠-٩) in [input] to standard ASCII digits (0-9).
String normalizeArabicDigits(String input) {
  const eastern = ['٠', '١', '٢', '٣', '٤', '٥', '٦', '٧', '٨', '٩'];
  String result = input;
  for (int i = 0; i < 10; i++) {
    result = result.replaceAll(eastern[i], i.toString());
  }
  return result;
}

/// Formats a 5-digit room code according to locale:
/// - If [isArabic] is true, converts to Eastern Arabic digits ('٠'-'٩').
/// - If false, keeps ASCII digits ('0'-'9').
/// Always maintains strict Left-to-Right reading order.
String formatMaglisCode(String code, {required bool isArabic}) {
  if (code.isEmpty) return code;
  final normalized = normalizeArabicDigits(code);
  if (!isArabic) return normalized;
  const digits = ['٠', '١', '٢', '٣', '٤', '٥', '٦', '٧', '٨', '٩'];
  return normalized.split('').map((char) {
    final n = int.tryParse(char);
    return n != null ? digits[n] : char;
  }).join('');
}

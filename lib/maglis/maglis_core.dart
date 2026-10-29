import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:audio_session/audio_session.dart';
import 'package:bip340/bip340.dart' as bip340;
import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
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

  static String randomHex32() {
    final bytes = List<int>.generate(32, (_) => _rng.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  static String blindedTag(String code) {
    final digest = sha256.convert(utf8.encode('maglis_v1_tag_${code.trim()}'));
    return digest.toString().substring(0, 32);
  }

  static final Map<String, SecretKey> _keyCache = {};

  static SecretKey _deriveKey(String code) {
    final trimmed = code.trim();
    return _keyCache.putIfAbsent(trimmed, () {
      final bytes =
          sha256.convert(utf8.encode('maglis_v1_aes_$trimmed')).bytes;
      return SecretKey(bytes);
    });
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

  static String signNostrEvent({
    required String privHex,
    required String tag,
    required String content,
  }) {
    final pubHex = bip340.getPublicKey(privHex);
    final createdAt = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    const kind = 20000; // Ephemeral Nostr Event
    final tags = <List<String>>[
      ['t', tag],
    ];
    final serialized = jsonEncode([0, pubHex, createdAt, kind, tags, content]);
    final idHex = sha256.convert(utf8.encode(serialized)).toString();
    final sigHex = bip340.sign(privHex, idHex, randomHex32());

    return jsonEncode([
      'EVENT',
      {
        'id': idHex,
        'pubkey': pubHex,
        'created_at': createdAt,
        'kind': kind,
        'tags': tags,
        'content': content,
        'sig': sigHex,
      }
    ]);
  }
}

class MaglisPlatform {
  static Future<bool> requestPermissions() async {
    if (kIsWeb) return true;
    try {
      if (Platform.isAndroid || Platform.isIOS) {
        final mic = await Permission.microphone.request();
        return mic.isGranted;
      } else if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
        final devices = await navigator.mediaDevices.enumerateDevices();
        return devices.any((d) => d.kind == 'audioinput');
      }
    } catch (_) {}
    return true;
  }

  static Future<void> initAudio() async {
    if (kIsWeb) return;
    try {
      // 1. Initialize WebRTC field trials (WARP enabled for ultra-fast connection setup)
      try {
        await WebRTC.initialize(options: {'enableWARP': true});
      } catch (_) {}

      // 2. Configure system audio_session for VoIP voice chat & hardware speakerphone
      if (Platform.isAndroid || Platform.isIOS) {
        final session = await AudioSession.instance;
        await session.configure(
          AudioSessionConfiguration(
            avAudioSessionCategory: AVAudioSessionCategory.playAndRecord,
            avAudioSessionCategoryOptions:
                AVAudioSessionCategoryOptions.defaultToSpeaker |
                    AVAudioSessionCategoryOptions.allowBluetooth |
                    AVAudioSessionCategoryOptions.allowBluetoothA2dp,
            avAudioSessionMode: AVAudioSessionMode.voiceChat,
            androidAudioAttributes: const AndroidAudioAttributes(
              contentType: AndroidAudioContentType.speech,
              usage: AndroidAudioUsage.voiceCommunication,
            ),
            androidAudioFocusGainType: AndroidAudioFocusGainType.gainTransient,
            androidWillPauseWhenDucked: false,
          ),
        );
        await session.setActive(true);
      }

      // 3. Configure platform audio routing for voice communication (WhatsApp-grade loud speakerphone)
      if (Platform.isAndroid) {
        await Helper.setAndroidAudioConfiguration(
          AndroidAudioConfiguration.communication,
        );
        await Helper.setSpeakerphoneOn(true);
        await Helper.setSpeakerphoneOnButPreferBluetooth();
      } else if (Platform.isIOS) {
        await Helper.setAppleAudioConfiguration(
          AppleAudioConfiguration(
            appleAudioCategory: AppleAudioCategory.playAndRecord,
            appleAudioMode: AppleAudioMode.videoChat,
            appleAudioCategoryOptions: {
              AppleAudioCategoryOption.defaultToSpeaker,
              AppleAudioCategoryOption.allowBluetooth,
              AppleAudioCategoryOption.allowBluetoothA2DP,
            },
          ),
        );
        await Helper.setSpeakerphoneOn(true);
        await Helper.setSpeakerphoneOnButPreferBluetooth();
      }
    } catch (e) {
      debugPrint('[MaglisPlatform] initAudio error: $e');
    }
  }

  static Future<void> setSpeaker(bool on) async {
    if (kIsWeb) return;
    try {
      if (Platform.isAndroid || Platform.isIOS) {
        if (on) {
          await Helper.setSpeakerphoneOn(true);
          await Helper.setSpeakerphoneOnButPreferBluetooth();
        } else {
          await Helper.setSpeakerphoneOn(false);
        }
      }
    } catch (_) {}
  }

  static Future<void> resetAudio() async {
    if (kIsWeb) return;
    try {
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

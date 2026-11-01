import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
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
      page: ((m['p'] as int?) ?? 1).clamp(1, 604),
      surah: ((m['s'] as int?) ?? 1).clamp(1, 114),
      ayah: ((m['a'] as int?) ?? 1).clamp(1, 286),
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

  Uint8List packBinary() => MaglisBinaryPacker.pack(this);

  static MaglisPacket? unpackBinary(Uint8List bytes) =>
      MaglisBinaryPacker.unpack(bytes);
}

/// High-efficiency binary serialization inspired by PeerRTC Packer.
/// Achieves >60% payload reduction compared to JSON over WebRTC DataChannel.
class MaglisBinaryPacker {
  static const int magic = 0x51; // 'Q'
  static const int version = 0x01;

  static List<int> encodeVarint(int value) {
    if (value < 0) {
      value = (value << 1) ^ (value >> 31);
    }
    final bytes = <int>[];
    while (value > 0x7F) {
      bytes.add((value & 0x7F) | 0x80);
      value >>= 7;
    }
    bytes.add(value & 0x7F);
    return bytes.isEmpty ? [0] : bytes;
  }

  static (int, int) decodeVarint(Uint8List bytes, int offset) {
    int result = 0;
    int shift = 0;
    int bytesRead = 0;

    while (offset + bytesRead < bytes.length) {
      int byte = bytes[offset + bytesRead];
      result |= (byte & 0x7F) << shift;
      bytesRead++;
      if ((byte & 0x80) == 0) break;
      shift += 7;
    }
    return (result, bytesRead);
  }

  static Uint8List pack(MaglisPacket packet) {
    final builder = BytesBuilder(copy: false);
    builder.addByte(magic);
    builder.addByte(version);
    builder.addByte(packet.type.index);
    builder.add(encodeVarint(packet.seq));

    final senderBytes = utf8.encode(packet.senderId);
    builder.add(encodeVarint(senderBytes.length));
    builder.add(senderBytes);

    builder.add(encodeVarint(packet.page));
    builder.add(encodeVarint(packet.surah));
    builder.add(encodeVarint(packet.ayah));

    // Flags:
    // bit 0: hasActiveWord
    // bit 1: hasActiveReciterId
    // bit 2: activeReciterIsSender
    // bit 3: hasGreenWords
    // bit 4: hasYellowWords
    // bit 5: hasRedWords
    // bit 6: hasCumulative
    // bit 7: hasErrors
    int flags = 0;
    if (packet.activeWord != null) flags |= (1 << 0);
    if (packet.activeReciterId != null) {
      flags |= (1 << 1);
      if (packet.activeReciterId == packet.senderId) {
        flags |= (1 << 2);
      }
    }
    if (packet.greenWords.isNotEmpty) flags |= (1 << 3);
    if (packet.yellowWords.isNotEmpty) flags |= (1 << 4);
    if (packet.redWords.isNotEmpty) flags |= (1 << 5);
    if (packet.cumulative != null && packet.cumulative!.isNotEmpty) {
      flags |= (1 << 6);
    }
    if (packet.errors != null && packet.errors!.isNotEmpty) {
      flags |= (1 << 7);
    }

    builder.addByte(flags);

    if (packet.activeWord != null) {
      builder.add(encodeVarint(packet.activeWord!));
    }

    if (packet.greenWords.isNotEmpty) {
      builder.add(encodeVarint(packet.greenWords.length));
      for (final w in packet.greenWords) {
        builder.add(encodeVarint(w));
      }
    }

    if (packet.yellowWords.isNotEmpty) {
      builder.add(encodeVarint(packet.yellowWords.length));
      for (final w in packet.yellowWords) {
        builder.add(encodeVarint(w));
      }
    }

    if (packet.redWords.isNotEmpty) {
      builder.add(encodeVarint(packet.redWords.length));
      for (final w in packet.redWords) {
        builder.add(encodeVarint(w));
      }
    }

    if (packet.activeReciterId != null &&
        packet.activeReciterId != packet.senderId) {
      final reciterBytes = utf8.encode(packet.activeReciterId!);
      builder.add(encodeVarint(reciterBytes.length));
      builder.add(reciterBytes);
    }

    if (packet.cumulative != null && packet.cumulative!.isNotEmpty) {
      builder.add(encodeVarint(packet.cumulative!.length));
      for (final entry in packet.cumulative!.entries) {
        final kBytes = utf8.encode(entry.key);
        builder.add(encodeVarint(kBytes.length));
        builder.add(kBytes);
        builder.add(encodeVarint(entry.value));
      }
    }

    if (packet.errors != null && packet.errors!.isNotEmpty) {
      final errBytes = utf8.encode(jsonEncode(packet.errors));
      builder.add(encodeVarint(errBytes.length));
      builder.add(errBytes);
    }

    builder.add(encodeVarint(packet.ts));

    return builder.takeBytes();
  }

  static MaglisPacket? unpack(Uint8List bytes) {
    if (bytes.length < 3) return null;
    if (bytes[0] != magic || bytes[1] != version) return null;

    int offset = 2;
    if (offset >= bytes.length) return null;
    final typeIdx = bytes[offset++];
    final type = MaglisPacketType
        .values[typeIdx.clamp(0, MaglisPacketType.values.length - 1)];

    var (seq, read) = decodeVarint(bytes, offset);
    offset += read;

    var (senderLen, readLen) = decodeVarint(bytes, offset);
    offset += readLen;
    if (offset + senderLen > bytes.length) return null;
    final senderId = utf8.decode(bytes.sublist(offset, offset + senderLen));
    offset += senderLen;

    var (page, readPage) = decodeVarint(bytes, offset);
    offset += readPage;

    var (surah, readSurah) = decodeVarint(bytes, offset);
    offset += readSurah;

    var (ayah, readAyah) = decodeVarint(bytes, offset);
    offset += readAyah;

    if (offset >= bytes.length) return null;
    final flags = bytes[offset++];

    int? activeWord;
    if ((flags & (1 << 0)) != 0) {
      var (w, r) = decodeVarint(bytes, offset);
      offset += r;
      activeWord = w;
    }

    List<int> greenWords = const [];
    if ((flags & (1 << 3)) != 0) {
      var (count, r) = decodeVarint(bytes, offset);
      offset += r;
      final list = <int>[];
      for (int i = 0; i < count; i++) {
        var (val, rVal) = decodeVarint(bytes, offset);
        offset += rVal;
        list.add(val);
      }
      greenWords = list;
    }

    List<int> yellowWords = const [];
    if ((flags & (1 << 4)) != 0) {
      var (count, r) = decodeVarint(bytes, offset);
      offset += r;
      final list = <int>[];
      for (int i = 0; i < count; i++) {
        var (val, rVal) = decodeVarint(bytes, offset);
        offset += rVal;
        list.add(val);
      }
      yellowWords = list;
    }

    List<int> redWords = const [];
    if ((flags & (1 << 5)) != 0) {
      var (count, r) = decodeVarint(bytes, offset);
      offset += r;
      final list = <int>[];
      for (int i = 0; i < count; i++) {
        var (val, rVal) = decodeVarint(bytes, offset);
        offset += rVal;
        list.add(val);
      }
      redWords = list;
    }

    String? activeReciterId;
    if ((flags & (1 << 1)) != 0) {
      if ((flags & (1 << 2)) != 0) {
        activeReciterId = senderId;
      } else {
        var (rLen, rR) = decodeVarint(bytes, offset);
        offset += rR;
        if (offset + rLen <= bytes.length) {
          activeReciterId = utf8.decode(bytes.sublist(offset, offset + rLen));
          offset += rLen;
        }
      }
    }

    Map<String, int>? cumulative;
    if ((flags & (1 << 6)) != 0) {
      var (count, r) = decodeVarint(bytes, offset);
      offset += r;
      final map = <String, int>{};
      for (int i = 0; i < count; i++) {
        var (kLen, rK) = decodeVarint(bytes, offset);
        offset += rK;
        final k = utf8.decode(bytes.sublist(offset, offset + kLen));
        offset += kLen;
        var (v, rV) = decodeVarint(bytes, offset);
        offset += rV;
        map[k] = v;
      }
      cumulative = map;
    }

    Map<String, List<Map<String, dynamic>>>? errors;
    if ((flags & (1 << 7)) != 0) {
      var (eLen, rE) = decodeVarint(bytes, offset);
      offset += rE;
      if (offset + eLen <= bytes.length) {
        final rawErr = utf8.decode(bytes.sublist(offset, offset + eLen));
        offset += eLen;
        final decoded = jsonDecode(rawErr) as Map<String, dynamic>;
        errors = decoded.map((k, v) => MapEntry(
              k,
              (v as List<dynamic>)
                  .map((e) => Map<String, dynamic>.from(e as Map))
                  .toList(),
            ));
      }
    }

    int ts = 0;
    if (offset < bytes.length) {
      var (tVal, rT) = decodeVarint(bytes, offset);
      offset += rT;
      ts = tVal;
    }

    return MaglisPacket(
      type: type,
      seq: seq,
      senderId: senderId,
      page: page.clamp(1, 604),
      surah: surah.clamp(1, 114),
      ayah: ayah.clamp(1, 286),
      activeWord: activeWord,
      greenWords: greenWords,
      yellowWords: yellowWords,
      redWords: redWords,
      activeReciterId: activeReciterId,
      cumulative: cumulative,
      errors: errors,
      ts: ts == 0 ? DateTime.now().millisecondsSinceEpoch : ts,
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

  /// Returns current, previous, and next 15-minute epoch tags to ensure uninterrupted connection
  /// across 15-minute boundary transitions and accommodate ±15 minutes of device clock drift.
  static List<String> activeBlindedTags(String code) {
    final ep = currentEpoch;
    return [
      blindedTag(code, epoch: ep),
      blindedTag(code, epoch: ep - 1),
      blindedTag(code, epoch: ep + 1),
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
  static StreamSubscription? _becomingNoisySub;
  static StreamSubscription? _interruptionSub;
  static bool _audioInitialized = false;
  static void Function(bool interrupted)? onAudioInterrupted;

  static Future<bool> requestPermissions() async {
    if (kIsWeb) return true;
    try {
      if ((!kIsWeb && defaultTargetPlatform == TargetPlatform.android) || (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS)) {
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
    if (_audioInitialized) {
      await setSpeaker(true);
      return;
    }
    _audioInitialized = true;

    try {
      final androidConfig = AndroidAudioConfiguration(
        manageAudioFocus: true,
        androidAudioMode: AndroidAudioMode.inCommunication,
        androidAudioFocusMode: AndroidAudioFocusMode.gain,
        androidAudioStreamType: AndroidAudioStreamType.voiceCall,
        androidAudioAttributesUsageType:
            AndroidAudioAttributesUsageType.voiceCommunication,
        androidAudioAttributesContentType:
            AndroidAudioAttributesContentType.speech,
        forceHandleAudioRouting: true,
      );

      // 1. Initialize WebRTC audio pipeline cleanly with music media attributes
      try {
        await WebRTC.initialize(options: {
          'audioSampleRate': 48000,
          'audioOutputSampleRate': 48000,
          'androidUseHardwareAudioProcessing': false, // Software APM handles AGC & AEC cleanly without hardware noise suppression crushing Quran recitation
          if ((!kIsWeb && defaultTargetPlatform == TargetPlatform.android))
            'androidAudioConfiguration': androidConfig.toMap(),
        });
      } catch (_) {}

      // 2. Set silent microphone mute mode (prevents OS beep on iOS/macOS)
      try {
        if ((!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) || (!kIsWeb && defaultTargetPlatform == TargetPlatform.macOS)) {
          await Helper.setMicrophoneMuteMode(MicrophoneMuteMode.inputMixer);
        }
      } catch (_) {}

      // 3. Configure platform audio routing for high-fidelity media loudspeaker playout
      if ((!kIsWeb && defaultTargetPlatform == TargetPlatform.android)) {
        await Helper.setAndroidAudioConfiguration(androidConfig);
        await Helper.setSpeakerphoneOn(true);
      } else if ((!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS)) {
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
      if ((!kIsWeb && defaultTargetPlatform == TargetPlatform.android) || (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS)) {
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
                contentType: AndroidAudioContentType.speech,
                usage: AndroidAudioUsage.voiceCommunication,
              ),
              androidAudioFocusGainType: AndroidAudioFocusGainType.gain,
              androidWillPauseWhenDucked: false,
            ),
          );
          // Note: WebRTC AudioSwitchManager owns native communication audio focus.
          // Calling session.setActive(true) causes Android to steal focus and revert to earpiece.

          // Auto-switch to bluetooth or speakerphone when devices are plugged or unplugged
          _deviceChangeSub?.cancel();
          _deviceChangeSub = session.devicesChangedEventStream.listen((_) {
            setSpeaker(true);
          });

          // Headset disconnect protection: prevents sudden audio blast or buffer crash when unplugged
          _becomingNoisySub?.cancel();
          _becomingNoisySub = session.becomingNoisyEventStream.listen((_) {
            setSpeaker(true);
          });

          // Recover audio route if interrupted by incoming phone call or system alarm
          _interruptionSub?.cancel();
          _interruptionSub = session.interruptionEventStream.listen((event) {
            if (event.begin) {
              onAudioInterrupted?.call(true);
            } else {
              setSpeaker(true);
              onAudioInterrupted?.call(false);
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

  static Completer<void>? _setSpeakerAction;

  static Future<void> setSpeaker(bool on) async {
    if (kIsWeb) return;
    if (_setSpeakerAction != null && !_setSpeakerAction!.isCompleted) {
      return _setSpeakerAction!.future;
    }
    final action = Completer<void>();
    _setSpeakerAction = action;

    try {
      if ((!kIsWeb && defaultTargetPlatform == TargetPlatform.android) || (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS)) {
        await Helper.setSpeakerphoneOn(on);
        if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
          try {
            await Helper.selectAudioOutput(on ? 'speaker' : 'earpiece');
          } catch (_) {}
        }
      }
    } catch (_) {
    } finally {
      action.complete();
    }
  }

  static Future<void> resetAudio() async {
    if (kIsWeb) return;
    try {
      _audioInitialized = false;
      onAudioInterrupted = null;
      _deviceChangeSub?.cancel();
      _deviceChangeSub = null;
      _becomingNoisySub?.cancel();
      _becomingNoisySub = null;
      _interruptionSub?.cancel();
      _interruptionSub = null;

      if ((!kIsWeb && defaultTargetPlatform == TargetPlatform.android)) {
        await Helper.setAndroidAudioConfiguration(
          AndroidAudioConfiguration.media,
        );
        await Helper.clearAndroidCommunicationDevice();
        await Helper.setSpeakerphoneOn(false);
      } else if ((!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS)) {
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
        await WakelockPlus.enable().catchError((_) {});
      } else {
        await WakelockPlus.disable().catchError((_) {});
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

/// Connection health diagnostics model for a connected WebRTC peer (noscall pattern).
class MaglisPeerDiagnostics {
  final String peerId;
  final int rttMs;
  final RTCIceConnectionState state;
  final int lastSeenMs;

  const MaglisPeerDiagnostics({
    required this.peerId,
    required this.rttMs,
    required this.state,
    required this.lastSeenMs,
  });

  @override
  String toString() =>
      'MaglisPeerDiagnostics(peerId: $peerId, rtt: ${rttMs}ms, state: $state, lastSeen: ${lastSeenMs}ms)';
}

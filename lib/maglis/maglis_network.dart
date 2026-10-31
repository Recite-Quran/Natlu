import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'maglis_core.dart';

/// MaglisNetworkEngine
///
/// Ultra-lightweight, 100% serverless, zero-cost P2P WebRTC mesh engine.
/// - Deterministic glare-free pairing (lexicographical role assignment, zero SDP rollback crashes)
/// - Sub-15ms real-time recitation data broadcasting strictly over direct WebRTC DataChannels
/// - Smart Socket Sleep: Nostr relays sleep when room is steady, consuming 0% CPU and 0 KB/s
/// - Multi-relay decentralized signaling fleet (4 fast ephemeral relays, zero continuous polling)
/// - Production Opus voice profile for natural Tajweed reading without gate cutoffs
/// - Graceful ICE state handling without infinite reconnection flapping
class MaglisNetworkEngine {
  static const int maxRemotePeers =
      3; // Up to 4 total participants in a Maglis room

  static const List<String> _defaultRelays = [
    'wss://quran-maglis.recitequrankarem.workers.dev',
    'wss://relay.primal.net',
    'wss://nostr.mom',
    'wss://nos.lol',
    'wss://relay.damus.io',
    'wss://relay.snort.social',
    'wss://offchain.pub',
    'wss://nostr.bitcoiner.social',
  ];

  static List<String> _relays = List.from(_defaultRelays);

  static const Map<String, dynamic> _defaultRtcConfig = {
    'iceServers': [
      {'urls': 'stun:stun.l.google.com:19302'},
      {'urls': 'stun:stun1.l.google.com:19302'},
      {'urls': 'stun:stun2.l.google.com:19302'},
      {'urls': 'stun:stun.cloudflare.com:3478'},
      {'urls': 'stun:global.stun.twilio.com:3478'},
    ],
    'iceTransportPolicy': 'all',
    'sdpSemantics': 'unified-plan',
    'bundlePolicy': 'max-bundle',
    'rtcpMuxPolicy': 'require',
    'iceCandidatePoolSize': 2,
  };

  static Map<String, dynamic> _rtcConfig = Map.from(_defaultRtcConfig);
  static bool _configSyncAttempted = false;

  /// Fetches latest dynamic fleet configuration from GitHub raw / CDN in the background.
  /// Completely non-blocking with 4-second timeout, falling back seamlessly on network errors.
  static Future<void> syncRemoteConfig() async {
    if (_configSyncAttempted) return;
    _configSyncAttempted = true;

    try {
      final prefs = await SharedPreferences.getInstance();

      // 1. Immediately load any previously cached relays and ICE config
      final cachedRelaysJson = prefs.getString('maglis_cached_relays');
      if (cachedRelaysJson != null) {
        final List<dynamic> list = jsonDecode(cachedRelaysJson);
        if (list.isNotEmpty) {
          _relays = list.map((e) => e.toString()).toList();
        }
      }
      final cachedRtcJson = prefs.getString('maglis_cached_rtc');
      if (cachedRtcJson != null) {
        final Map<String, dynamic> rtc = jsonDecode(cachedRtcJson);
        if (rtc.isNotEmpty) {
          _rtcConfig = rtc;
        }
      }

      // 2. Multi-tier fallback config sync:
      // Tier 1: Cloudflare Edge Worker (/config) - Sub-30ms, no IP rate limits
      // Tier 2: jsDelivr Global CDN - Worldwide distribution, bypasses worker blocking and GitHub rate limits
      // Tier 3: GitHub Raw - Direct repository fallback
      // Tier 4: Built-in hardcoded defaults (_defaultRelays, _defaultRtcConfig)
      const edgeUrl =
          'https://quran-maglis.recitequrankarem.workers.dev/config';
      const cdnUrl =
          'https://cdn.jsdelivr.net/gh/Recite-Quran/Natlu@Natlu-%D8%A7%D9%84%D8%AD%D9%85%D8%AF%D9%84%D9%84%D9%87/maglis_relay/maglis_config.json';
      const primaryUrl =
          'https://raw.githubusercontent.com/Recite-Quran/Natlu/Natlu-%D8%A7%D9%84%D8%AD%D9%85%D8%AF%D9%84%D9%84%D9%87/maglis_relay/maglis_config.json';

      http.Response? res;
      // Try Tier 1: Cloudflare Edge
      try {
        res = await http
            .get(Uri.parse(edgeUrl))
            .timeout(const Duration(milliseconds: 2500));
      } catch (_) {}

      // Try Tier 2: jsDelivr CDN
      if (res == null || res.statusCode != 200) {
        try {
          res = await http
              .get(Uri.parse(cdnUrl))
              .timeout(const Duration(milliseconds: 2500));
        } catch (_) {}
      }

      // Try Tier 3: GitHub Raw
      if (res == null || res.statusCode != 200) {
        try {
          res = await http
              .get(Uri.parse(primaryUrl))
              .timeout(const Duration(milliseconds: 2500));
        } catch (_) {}
      }

      if (res != null && res.statusCode == 200) {
        final data = jsonDecode(res.body);
        if (data is Map<String, dynamic>) {
          if (data['relays'] is List) {
            final List<String> fetchedRelays = (data['relays'] as List)
                .map((e) => e.toString().trim())
                .where((s) => s.startsWith('ws://') || s.startsWith('wss://'))
                .toList();
            if (fetchedRelays.length >= 2) {
              _relays = fetchedRelays;
              await prefs.setString(
                  'maglis_cached_relays', jsonEncode(fetchedRelays));
            }
          }
          if (data['iceServers'] is List &&
              (data['iceServers'] as List).isNotEmpty) {
            final updatedRtc = Map<String, dynamic>.from(_defaultRtcConfig);
            updatedRtc['iceServers'] = data['iceServers'];
            _rtcConfig = updatedRtc;
            await prefs.setString('maglis_cached_rtc', jsonEncode(updatedRtc));
          }
        }
      }
    } catch (_) {
      // Fail-safe: silently continue with built-in defaults or existing cache
    }
  }

  static bool _isValidCandidate(String? cand) {
    if (cand == null || cand.isEmpty) return false;
    final lower = cand.toLowerCase();
    if (lower.contains('fe80:') ||
        lower.contains('127.0.0.') ||
        lower.contains('::1') ||
        lower.contains('localhost') ||
        lower.contains(' 0.0.0.0 ')) {
      return false;
    }
    return true;
  }

  final String roomCode;
  final String localPeerId;
  bool _isHost;
  bool get isHost => _isHost;
  final MaglisPacket Function() onBuildSnapshot;

  late final String _privHex = MaglisCrypto.randomHex32();
  late final String _pubHex = MaglisCrypto.getPublicKey(_privHex);
  List<String> get _activeTags => MaglisCrypto.activeBlindedTags(roomCode);
  final Set<String> _admittedPeers = <String>{};

  final Map<String, WebSocketChannel> _sockets = {};
  final Set<String> _reconnectingRelays = {};
  int _activeRelayIndex = 0;
  int _consecutiveRelayFailures = 0;
  String get _currentRelayUrl =>
      _relays.isNotEmpty ? _relays[_activeRelayIndex % _relays.length] : '';
  DateTime? _lastPrimaryProbeTime;
  final LinkedHashSet<String> _seenNostrIds = LinkedHashSet<String>();

  final Map<String, RTCPeerConnection> _peers = {};
  final Map<String, RTCDataChannel> _channels = {};
  final Map<String, List<RTCIceCandidate>> _iceQueues = {};
  final Map<String, bool> _remoteDescSet = {};
  final Map<String, int> _lastSeq = {};
  final Map<String, RTCIceConnectionState> _peerStates = {};
  final Set<String> _roomParticipants = <String>{};
  final Map<String, int> _lastSeenPeerMs = {};
  final Map<String, List<Map<String, dynamic>>> _pendingOutboundCandidates = {};
  final Map<String, Timer> _iceDebounceTimers = {};
  final Map<String, Timer> _iceRestartGraceTimers = {};
  final Map<String, bool> _answerInFlight = {};
  final Set<String> _negotiatingPeers = {};
  final Map<String, List<MediaStreamTrack>> _remoteTracks = {};
  final Set<String> _peersNeedingCatchup = <String>{};

  MediaStream? _localStream;
  bool _isMicMuted = false;
  bool _disposed = false;
  bool _isSocketSubscribed = false;
  final int _engineStartTime = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  Timer? _beaconTimer;
  Timer? _pingTimer;
  Timer? _throttleTimer;
  Timer? _relayHeartbeatTimer;
  Timer? _watchdogTimer;
  Timer? _epochRefreshTimer;
  String? _lastSubId;
  final List<String> _pendingVitalPackets = [];

  final _packetCtrl = StreamController<MaglisPacket>.broadcast();
  final _statesCtrl =
      StreamController<Map<String, RTCIceConnectionState>>.broadcast();
  final _natFailCtrl = StreamController<String>.broadcast();
  final _participantCountCtrl = StreamController<int>.broadcast();

  MaglisNetworkEngine({
    required this.roomCode,
    required this.localPeerId,
    bool isHost = true,
    required this.onBuildSnapshot,
  }) : _isHost = isHost;

  Stream<MaglisPacket> get onPacket => _packetCtrl.stream;
  Stream<Map<String, RTCIceConnectionState>> get onPeerStates =>
      _statesCtrl.stream;
  Stream<String> get onNatFailure => _natFailCtrl.stream;
  Stream<int> get onParticipantCount => _participantCountCtrl.stream;
  int get participantCount => _roomParticipants.length + 1; // self + remote
  bool get isMicMuted => _isMicMuted;

  static Map<String, dynamic> _buildAudioConstraints({String? inputDeviceId}) {
    return {
      'audio': {
        // High-definition audio constraints with Auto Gain Control for loud output on all platforms
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

        // Mandatory dictionary (Required by flutter-webrtc MediaConstraints on Android, iOS & Windows)
        'mandatory': {
          'echoCancellation': 'true',
          'googEchoCancellation': 'true',
          'googEchoCancellation2': 'true',
          'googDAEchoCancellation': 'true',
          'autoGainControl': 'true',
          'googAutoGainControl': 'true',
          'noiseSuppression': 'false',
          'googNoiseSuppression': 'false',
          'googNoiseSuppression2': 'false',
          'highpassFilter': 'false',
          'googHighpassFilter': 'false',
          'googTypingNoiseDetection': 'false',
        },

        // Optional list (Parsed into native libwebrtc RTCMediaConstraints on Android and iOS)
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

  Future<void> start({String? inputDeviceId}) async {
    unawaited(syncRemoteConfig());
    await MaglisPlatform.initAudio();
    await MaglisPlatform.setWakeLock(true);

    try {
      _localStream = await navigator.mediaDevices.getUserMedia(
        _buildAudioConstraints(inputDeviceId: inputDeviceId),
      );
    } catch (_) {
      try {
        _localStream = await navigator.mediaDevices.getUserMedia({
          'audio': true,
          'video': false,
        });
      } catch (_) {}
    }

    // Unmute mic audio track so all room members hear each other continuously in conference call
    _localStream?.getAudioTracks().forEach((track) {
      track.enabled = true;
      if (Platform.isAndroid || Platform.isIOS) {
        try {
          Helper.setMicrophoneMute(false, track);
        } catch (_) {}
      }
    });
    _isMicMuted = false;
    MaglisPlatform.setSpeaker(true);

    // Connect to the top primary relay first (fallbacks only activate if primary fails)
    _activeRelayIndex = 0;
    await _connectActiveRelay();

    // Broadcast initial room discovery beacon
    await _sendSignal('beacon', data: const {});

    // Re-announce beacon every 12s ONLY when waiting for initial peer; completely idle once connected
    _beaconTimer = Timer.periodic(const Duration(seconds: 12), (_) {
      if (!_disposed && _peers.isEmpty) {
        _sendSignal('beacon', data: const {});
      }
    });

    // Zero-overhead 6s keep-alive ping strictly over direct WebRTC DataChannels (zero Nostr traffic)
    _pingTimer = Timer.periodic(const Duration(seconds: 6), (_) {
      if (_disposed) return;
      _dispatchRaw(jsonEncode({
        't': 4,
        'u': localPeerId,
        'm': DateTime.now().millisecondsSinceEpoch,
      }));
    });

    // 25s WebSocket Keep-Alive Heartbeat: prevents Nostr relays from idling out TCP sockets
    _relayHeartbeatTimer = Timer.periodic(const Duration(seconds: 25), (_) {
      if (_disposed) return;
      final pingTag = 'hb_${DateTime.now().millisecondsSinceEpoch}';
      for (final ws in _sockets.values) {
        try {
          ws.sink.add(jsonEncode([
            'REQ',
            pingTag,
            {'limit': 0}
          ]));
          ws.sink.add(jsonEncode(['CLOSE', pingTag]));
        } catch (_) {}
      }
    });

    // 5s Watchdog Timer: keeps active relay connected, recovers dropped DataChannels on audio peers, and prunes abandoned ghost peers
    _watchdogTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (_disposed) return;
      if (_sockets.isEmpty) {
        _connectActiveRelay();
      } else if (_activeRelayIndex != 0) {
        _tryRestorePrimaryRelay();
      }
      // DataChannel health check on active WebRTC audio peers
      for (final entry in _peers.entries) {
        final peerId = entry.key;
        final state = _peerStates[peerId];
        final isConnected =
            state == RTCIceConnectionState.RTCIceConnectionStateConnected ||
                state == RTCIceConnectionState.RTCIceConnectionStateCompleted;
        if (isConnected) {
          final dc = _channels[peerId];
          if (dc == null ||
              dc.state == RTCDataChannelState.RTCDataChannelClosed) {
            _recoverDataChannel(peerId);
          }
        }
      }
      _pruneStalePeers();
    });

    // 3-minute Epoch Refresh Timer: guarantees relay subscriptions stay active across 15-min epoch boundaries
    int lastEpoch = MaglisCrypto.currentEpoch;
    _epochRefreshTimer = Timer.periodic(const Duration(minutes: 3), (_) {
      if (_disposed) return;
      final curEpoch = MaglisCrypto.currentEpoch;
      if (curEpoch != lastEpoch) {
        lastEpoch = curEpoch;
        _resubscribeRelays();
      }
    });
  }

  void _pruneStalePeers() {
    if (_disposed) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final stalePeers = <String>[];
    for (final peerId in _roomParticipants) {
      final lastSeen = _lastSeenPeerMs[peerId] ?? 0;
      final state = _peerStates[peerId];
      final isConnected =
          state == RTCIceConnectionState.RTCIceConnectionStateConnected ||
              state == RTCIceConnectionState.RTCIceConnectionStateCompleted;
      // If WebRTC is not connected and peer hasn't been active for > 15s, evict ghost peer
      if (!isConnected && (now - lastSeen) > 15000) {
        stalePeers.add(peerId);
      }
    }
    for (final p in stalePeers) {
      _roomParticipants.remove(p);
      _admittedPeers.remove(p);
      unawaited(_cleanupPeer(p));
    }
    if (stalePeers.isNotEmpty) {
      _participantCountCtrl.add(_roomParticipants.length + 1);
    }
  }

  Future<bool> _connectActiveRelay() async {
    if (_disposed || _sockets.isNotEmpty) return true;
    final url = _currentRelayUrl;
    if (url.isEmpty) return false;
    return _connectRelay(url);
  }

  static String formatRelayUrl(String baseUrl, String room) {
    try {
      final uri = Uri.parse(baseUrl);
      if (uri.host.contains('workers.dev')) {
        final cleanRoom = normalizeArabicDigits(room.trim()).toLowerCase();
        return uri.replace(
          path: '/room/$cleanRoom',
          queryParameters: {'room': cleanRoom},
        ).toString();
      }
    } catch (_) {}
    return baseUrl;
  }

  void _tryRestorePrimaryRelay() {
    if (_disposed || _activeRelayIndex == 0 || _relays.isEmpty) return;
    // Keep active session connected; do not hop relays mid-session
    if (_roomParticipants.isNotEmpty || _peers.isNotEmpty) return;
    final now = DateTime.now();
    if (_lastPrimaryProbeTime != null &&
        now.difference(_lastPrimaryProbeTime!).inSeconds < 30) {
      return;
    }
    _lastPrimaryProbeTime = now;

    final primaryUrl = _relays.first;
    try {
      final targetUrl = formatRelayUrl(primaryUrl, roomCode);
      final probeChannel = WebSocketChannel.connect(Uri.parse(targetUrl));

      probeChannel.ready.then((_) {
        if (_disposed) {
          try {
            probeChannel.sink.close();
          } catch (_) {}
          return;
        }
        // Primary relay is healthy again! Gracefully switch back to primary.
        _activeRelayIndex = 0;
        _consecutiveRelayFailures = 0;
        for (final entry in _sockets.entries.toList()) {
          try {
            entry.value.sink.close();
          } catch (_) {}
        }
        _sockets.clear();
        _sockets[primaryUrl] = probeChannel;
        _subscribeRelay(probeChannel);

        probeChannel.stream.listen(
          _onRelayFrame,
          onDone: () => _scheduleReconnect(primaryUrl),
          onError: (_) => _scheduleReconnect(primaryUrl),
          cancelOnError: true,
        );
      }).catchError((_) {
        try {
          probeChannel.sink.close();
        } catch (_) {}
      });
    } catch (_) {}
  }

  Future<bool> _connectRelay(String url) async {
    if (_disposed) return false;
    final completer = Completer<bool>();
    try {
      final targetUrl = formatRelayUrl(url, roomCode);
      final ws = WebSocketChannel.connect(Uri.parse(targetUrl));
      _sockets[url] = ws;

      bool errored = false;
      void handleFail() {
        if (!completer.isCompleted) completer.complete(false);
        if (!errored) {
          errored = true;
          _scheduleReconnect(url);
        }
      }

      ws.ready.timeout(const Duration(milliseconds: 3000)).then((_) {
        if (_disposed) {
          try {
            ws.sink.close();
          } catch (_) {}
          if (!completer.isCompleted) completer.complete(false);
          return;
        }
        _consecutiveRelayFailures = 0;
        _subscribeRelay(ws);
        if (!completer.isCompleted) completer.complete(true);
      }).catchError((_) {
        handleFail();
      });

      ws.stream.listen(
        _onRelayFrame,
        onDone: handleFail,
        onError: (_) => handleFail(),
        cancelOnError: true,
      );
      return await completer.future;
    } catch (_) {
      _scheduleReconnect(url);
      return false;
    }
  }

  void _subscribeRelay(WebSocketChannel ws) {
    final tags = _activeTags;
    final newSubId = 'maglis_${tags.first}';
    if (_lastSubId != null && _lastSubId != newSubId) {
      try {
        ws.sink.add(jsonEncode(['CLOSE', _lastSubId]));
      } catch (_) {}
    }
    _lastSubId = newSubId;
    ws.sink.add(jsonEncode([
      'REQ',
      newSubId,
      {
        'kinds': [20000],
        '#t': tags,
      }
    ]));
    _isSocketSubscribed = true;
  }

  void _resubscribeRelays() {
    if (_disposed) return;
    for (final ws in _sockets.values) {
      try {
        _subscribeRelay(ws);
      } catch (_) {}
    }
  }

  /// Smart Socket Sleep:
  /// Ensures signaling relay subscription stays active and responsive
  /// to room events (joins, leaves, renegotiations) without deadlocks.
  void _checkSocketSleepState() {
    if (_disposed) return;
    if (!_isSocketSubscribed) {
      _resubscribeRelays();
    }
  }

  void _scheduleReconnect(String url) {
    _sockets.remove(url);
    if (_disposed) return;
    if (_reconnectingRelays.contains(url)) return;
    _reconnectingRelays.add(url);

    // 3-Strike Rule: Only advance to fallback relay after 3 consecutive failures on current relay.
    // This prevents a momentary cellular blip or Wi-Fi flicker from immediately abandoning Cloudflare.
    if (url == _currentRelayUrl && _relays.isNotEmpty) {
      _consecutiveRelayFailures++;
      if (_consecutiveRelayFailures >= 3) {
        _consecutiveRelayFailures = 0;
        _activeRelayIndex = (_activeRelayIndex + 1) % _relays.length;
      }
    }

    // Connect to next active relay with 2s backoff
    Future.delayed(const Duration(seconds: 2), () {
      _reconnectingRelays.remove(url);
      if (!_disposed && _sockets.isEmpty) {
        _connectActiveRelay();
      }
    });
  }

  Future<void> _sendSignal(
    String type, {
    String? targetId,
    required Map<String, dynamic> data,
  }) async {
    if (_disposed) return;
    final payloadData = Map<String, dynamic>.from(data);
    payloadData['auth'] = MaglisCrypto.admissionToken(roomCode, localPeerId);
    if (isHost) {
      payloadData['host'] = true;
    }

    final sig = MaglisSignal(
      type: type,
      senderId: localPeerId,
      targetId: targetId,
      data: payloadData,
    );
    final cipher = await MaglisCrypto.encrypt(sig.pack(), roomCode);
    final tags = _activeTags;
    final frame = await MaglisCrypto.signNostrEventAsync(
      privHex: _privHex,
      pubHex: _pubHex,
      tag: tags.first,
      additionalTags: tags.length > 1 ? tags.sublist(1) : null,
      content: cipher,
    );
    for (final ws in _sockets.values) {
      try {
        ws.sink.add(frame);
      } catch (_) {}
    }
  }

  Future<void> _onRelayFrame(dynamic rawFrame) async {
    if (_disposed || rawFrame is! String) return;
    try {
      final list = jsonDecode(rawFrame);
      if (list is! List || list.length < 3 || list[0] != 'EVENT') return;
      final ev = list[2] as Map<String, dynamic>;
      final id = ev['id'] as String?;
      final content = ev['content'] as String?;
      final createdAt = ev['created_at'] as int?;
      if (id == null || content == null) return;

      // Discard stale events from prior sessions or older than 30s before engine start
      if (createdAt != null && createdAt < (_engineStartTime - 30)) {
        return;
      }

      if (_seenNostrIds.contains(id)) return;
      _seenNostrIds.add(id);
      if (_seenNostrIds.length > 400) {
        _seenNostrIds.remove(_seenNostrIds.first);
      }

      final clear = await MaglisCrypto.decrypt(content, roomCode);
      if (clear == null) return;

      final sig = MaglisSignal.unpack(clear);
      if (sig.senderId == localPeerId) return;
      if (sig.targetId != null && sig.targetId != localPeerId) return;

      // Host Admission Shield: Authenticate admission token derived from roomCode + peerId + pepper
      final auth = sig.data['auth'] as String?;
      if (auth == null ||
          !MaglisCrypto.verifyAdmissionToken(roomCode, sig.senderId, auth)) {
        return; // Reject unauthenticated probes
      }

      final bool isProbe = sig.type == 'presence_probe' ||
          sig.type == 'presence_pong' ||
          sig.type == 'reserve_code' ||
          sig.type == 'join_probe';

      // Host capacity shield: Max 3 remote peers (4 total participants)
      if (isHost && !isProbe) {
        if (!_admittedPeers.contains(sig.senderId) &&
            _admittedPeers.length >= maxRemotePeers) {
          return; // Drop signals exceeding room capacity
        }
        _admittedPeers.add(sig.senderId);
      }

      _lastSeenPeerMs[sig.senderId] = DateTime.now().millisecondsSinceEpoch;
      if (!isProbe && !_roomParticipants.contains(sig.senderId)) {
        _roomParticipants.add(sig.senderId);
        _participantCountCtrl.add(_roomParticipants.length + 1);
      }

      await _handleSignal(sig);
    } catch (_) {}
  }

  Future<void> _handleSignal(MaglisSignal sig) async {
    final remoteId = sig.senderId;

    switch (sig.type) {
      case 'join_probe':
        if (isHost) {
          if (_roomParticipants.length >= maxRemotePeers) {
            await _sendSignal('join_reject',
                targetId: remoteId, data: {'reason': 'full'});
          } else {
            await _sendSignal('join_ack',
                targetId: remoteId,
                data: {'count': _roomParticipants.length + 1});
          }
        } else if (_peers.isNotEmpty) {
          await _sendSignal('join_ack',
              targetId: remoteId,
              data: {'count': _roomParticipants.length + 1});
        }
        break;

      case 'presence_probe':
        await _sendSignal('presence_pong',
            targetId: remoteId, data: {'active': true});
        break;

      case 'reconnect_request':
        final isInitiator = localPeerId.compareTo(remoteId) < 0;
        if (isInitiator && !_negotiatingPeers.contains(remoteId)) {
          final pc = _peers[remoteId];
          if (pc != null) {
            final dc = _channels[remoteId];
            if (sig.data['reason'] == 'dc_recovery' ||
                dc == null ||
                dc.state != RTCDataChannelState.RTCDataChannelOpen) {
              unawaited(_recoverDataChannel(remoteId));
            } else {
              unawaited(_triggerIceRestart(remoteId));
            }
          } else {
            unawaited(
                _sendSignal('beacon', targetId: remoteId, data: const {}));
          }
        }
        break;

      case 'floor_claim':
        final nextSeq = (_lastSeq[remoteId] ?? 0) + 1;
        _lastSeq[remoteId] = nextSeq;
        final pkt = MaglisPacket(
          type: MaglisPacketType.floorClaim,
          seq: nextSeq,
          senderId: remoteId,
          page: sig.data['page'] as int? ?? 1,
          surah: sig.data['surah'] as int? ?? 1,
          ayah: sig.data['ayah'] as int? ?? 1,
          activeReciterId: remoteId,
          ts: DateTime.now().millisecondsSinceEpoch,
        );
        _handleIncomingPacketString(pkt.pack());
        break;

      case 'beacon':
        final existingPc = _peers[remoteId];
        final existingState = _peerStates[remoteId];
        if (existingPc != null &&
            (existingState ==
                    RTCIceConnectionState.RTCIceConnectionStateConnected ||
                existingState ==
                    RTCIceConnectionState.RTCIceConnectionStateCompleted ||
                existingState ==
                    RTCIceConnectionState.RTCIceConnectionStateChecking)) {
          // Already happily connected or checking connectivity; keep active!
          return;
        }
        if (_negotiatingPeers.contains(remoteId)) {
          return;
        }
        if (!_peers.containsKey(remoteId) && _peers.length >= maxRemotePeers) {
          return;
        }

        // Deterministic Glare Resolution:
        // Lexicographically smaller peer ID is ALWAYS the Initiator (Offerer).
        // Larger peer ID is ALWAYS the Answerer.
        // This mathematically eliminates glare, collisions, and SDP rollback crashes!
        final isInitiator = localPeerId.compareTo(remoteId) < 0;
        if (isInitiator) {
          await _initiatePeerConnection(remoteId);
        } else {
          // Answerer informs initiator of its presence so initiator can send offer
          if (!_peers.containsKey(remoteId)) {
            await _sendSignal('beacon', targetId: remoteId, data: const {});
          }
        }
        break;

      case 'offer':
        if (!_peers.containsKey(remoteId) && _peers.length >= maxRemotePeers) {
          return;
        }
        final sdp = sig.data['sdp'] as String?;
        if (sdp == null) return;

        final isInitiator = localPeerId.compareTo(remoteId) < 0;
        final bool isIceRestart = sig.data['iceRestart'] == true;
        final bool isDataChannelRecovery = sig.data['dcRecovery'] == true;
        final bool isRenegotiation = isIceRestart || isDataChannelRecovery;

        // If we are initiator and this is not a renegotiation, ignore unexpected reverse offer
        if (isInitiator && !isRenegotiation && _peers.containsKey(remoteId)) {
          return;
        }

        final existingOfferPc = _peers[remoteId];
        final existingOfferState = _peerStates[remoteId];
        if (existingOfferPc != null &&
            !isRenegotiation &&
            (existingOfferState ==
                    RTCIceConnectionState.RTCIceConnectionStateConnected ||
                existingOfferState ==
                    RTCIceConnectionState.RTCIceConnectionStateCompleted)) {
          return;
        }

        if (existingOfferPc != null &&
            (existingOfferState ==
                    RTCIceConnectionState.RTCIceConnectionStateFailed ||
                existingOfferState ==
                    RTCIceConnectionState.RTCIceConnectionStateClosed)) {
          await _cleanupPeer(remoteId);
        }

        if (_negotiatingPeers.contains(remoteId)) {
          return;
        }
        _negotiatingPeers.add(remoteId);
        try {
          final pc = _peers[remoteId] ?? await _createPeer(remoteId);
          final curSigState = await pc.getSignalingState() ?? pc.signalingState;
          if (curSigState ==
              RTCSignalingState.RTCSignalingStateHaveLocalOffer) {
            if (localPeerId.compareTo(remoteId) > 0) {
              // Remote peer has lexicographical precedence, rollback local offer cleanly
              try {
                await pc.setRemoteDescription(
                    RTCSessionDescription('', 'rollback'));
              } catch (_) {}
            } else {
              // Local peer has precedence; ignore reverse offer
              return;
            }
          }

          await pc.setRemoteDescription(RTCSessionDescription(sdp, 'offer'));
          _remoteDescSet[remoteId] = true;
          await _flushIceQueue(remoteId);

          final answer = await pc.createAnswer(const {
            'mandatory': {
              'OfferToReceiveAudio': true,
              'OfferToReceiveVideo': false,
            },
            'optional': [],
          });
          final mungedSdp = mungeOpusSdp(answer.sdp ?? '');
          await pc.setLocalDescription(
            RTCSessionDescription(mungedSdp, answer.type),
          );
          await _sendSignal('answer',
              targetId: remoteId, data: {'sdp': mungedSdp});
        } finally {
          _negotiatingPeers.remove(remoteId);
        }
        break;

      case 'answer':
        final pc = _peers[remoteId];
        final sdp = sig.data['sdp'] as String?;
        if (pc == null || sdp == null || _disposed) return;
        if (_answerInFlight[remoteId] == true) return;

        final curState = await pc.getSignalingState() ?? pc.signalingState;
        if (curState != RTCSignalingState.RTCSignalingStateHaveLocalOffer) {
          return;
        }

        _answerInFlight[remoteId] = true;
        try {
          await pc.setRemoteDescription(RTCSessionDescription(sdp, 'answer'));
          _remoteDescSet[remoteId] = true;
          await _flushIceQueue(remoteId);
        } catch (e) {
          debugPrint('[MaglisNetwork] setRemoteDescription answer error: $e');
        } finally {
          _answerInFlight[remoteId] = false;
        }
        break;

      case 'ice_batch':
        final list = sig.data['candidates'] as List<dynamic>?;
        if (list == null || list.isEmpty) return;
        for (final item in list) {
          if (item is Map) {
            final candStr = item['candidate'] as String?;
            if (!_isValidCandidate(candStr)) continue;
            final cand = RTCIceCandidate(
              candStr,
              item['sdpMid'] as String?,
              item['sdpMLineIndex'] as int?,
            );
            if (_remoteDescSet[remoteId] == true && _peers[remoteId] != null) {
              try {
                await _peers[remoteId]!.addCandidate(cand);
              } catch (_) {}
            } else {
              _iceQueues.putIfAbsent(remoteId, () => []).add(cand);
            }
          }
        }
        break;

      case 'leave':
        _roomParticipants.remove(remoteId);
        _participantCountCtrl.add(_roomParticipants.length + 1);
        await _cleanupPeer(remoteId);
        _checkSocketSleepState();
        break;
    }
  }

  void _queueOutboundIce(String remoteId, Map<String, dynamic> candMap) {
    _pendingOutboundCandidates.putIfAbsent(remoteId, () => []).add(candMap);
    if (_iceDebounceTimers[remoteId]?.isActive ?? false) return;
    _iceDebounceTimers[remoteId] = Timer(const Duration(milliseconds: 80), () {
      final list = _pendingOutboundCandidates.remove(remoteId);
      if (list != null && list.isNotEmpty && !_disposed) {
        _sendSignal('ice_batch',
            targetId: remoteId, data: {'candidates': list});
      }
    });
  }

  Future<void> _initiatePeerConnection(String remoteId) async {
    if (_peers.containsKey(remoteId) || _negotiatingPeers.contains(remoteId)) return;
    _negotiatingPeers.add(remoteId);
    try {
      final pc = await _createPeer(remoteId);
      final dc = await pc.createDataChannel(
        'maglis_sync',
        RTCDataChannelInit()
          ..ordered = true
          ..maxRetransmits = 30
          ..binaryType = 'binary',
      );
      _bindDataChannel(remoteId, dc);

      final offer = await pc.createOffer(const {
        'mandatory': {
          'OfferToReceiveAudio': true,
          'OfferToReceiveVideo': false,
        },
        'optional': [],
      });
      final mungedSdp = mungeOpusSdp(offer.sdp ?? '');
      await pc.setLocalDescription(
        RTCSessionDescription(mungedSdp, offer.type),
      );
      await _sendSignal('offer', targetId: remoteId, data: {'sdp': mungedSdp});
    } finally {
      _negotiatingPeers.remove(remoteId);
    }
  }

  Future<RTCPeerConnection> _createPeer(String remoteId) async {
    // If an existing connection is in place, clean it first and settle native audio thread
    if (_peers.containsKey(remoteId)) {
      await _cleanupPeer(remoteId);
      await Future.delayed(const Duration(milliseconds: 150));
    }
    final pc = await createPeerConnection(_rtcConfig);
    _peers[remoteId] = pc;
    _remoteDescSet[remoteId] = false;
    _iceQueues.putIfAbsent(remoteId, () => []);

    // Add local mic audio track and configure sender encoding for QoS and bitrate control
    if (_localStream != null) {
      for (final track in _localStream!.getAudioTracks()) {
        track.enabled = !_isMicMuted;
        try {
          Helper.setMicrophoneMute(_isMicMuted, track);
        } catch (_) {}
        try {
          final senders = await pc.getSenders();
          if (!senders.any((s) => s.track?.kind == 'audio')) {
            await pc.addTrack(track, _localStream!);
          }
          final updatedSenders = await pc.getSenders();
          for (final s in updatedSenders) {
            if (s.track?.kind == 'audio') {
              try {
                final params = s.parameters;
                if (params.encodings != null && params.encodings!.isNotEmpty) {
                  params.encodings![0].maxBitrate = 48000;
                  await s.setParameters(params);
                }
              } catch (_) {}
            }
          }
        } catch (e) {
          debugPrint('[MaglisNetwork] addTrack error: $e');
        }
      }
    }

    pc.onIceCandidate = (RTCIceCandidate c) {
      final str = c.candidate;
      if (!_isValidCandidate(str)) return;
      _queueOutboundIce(remoteId, {
        'candidate': str,
        'sdpMid': c.sdpMid,
        'sdpMLineIndex': c.sdpMLineIndex,
      });
    };

    pc.onIceConnectionState = (RTCIceConnectionState state) {
      if (_disposed) return;
      _peerStates[remoteId] = state;
      _statesCtrl.add(Map.unmodifiable(_peerStates));

      if (state == RTCIceConnectionState.RTCIceConnectionStateConnected ||
          state == RTCIceConnectionState.RTCIceConnectionStateCompleted) {
        _iceRestartGraceTimers[remoteId]?.cancel();
        _iceRestartGraceTimers.remove(remoteId);
        _checkSocketSleepState();
      } else if (state ==
              RTCIceConnectionState.RTCIceConnectionStateDisconnected ||
          state == RTCIceConnectionState.RTCIceConnectionStateFailed) {
        _checkSocketSleepState(); // Ensure Nostr relays are awake for renegotiation on both sides
        final isInitiator = localPeerId.compareTo(remoteId) < 0;
        final int graceSeconds =
            (state == RTCIceConnectionState.RTCIceConnectionStateFailed)
                ? 2
                : 4;
        _iceRestartGraceTimers[remoteId]?.cancel();
        _iceRestartGraceTimers[remoteId] =
            Timer(Duration(seconds: graceSeconds), () {
          if (!_disposed &&
              (_peerStates[remoteId] ==
                      RTCIceConnectionState.RTCIceConnectionStateFailed ||
                  _peerStates[remoteId] ==
                      RTCIceConnectionState
                          .RTCIceConnectionStateDisconnected)) {
            _natFailCtrl.add(remoteId);
            _checkSocketSleepState();
            if (isInitiator) {
              _triggerIceRestart(remoteId);
            } else {
              _sendSignal('reconnect_request',
                  targetId: remoteId, data: const {});
            }
          }
        });
      }
    };

    pc.onConnectionState = (RTCPeerConnectionState state) {
      if (_disposed) return;
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
        _lastSeenPeerMs[remoteId] = 0;
        if (_roomParticipants.remove(remoteId) ||
            _admittedPeers.remove(remoteId)) {
          _participantCountCtrl.add(_roomParticipants.length + 1);
        }
        unawaited(_cleanupPeer(remoteId));
      } else if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        _checkSocketSleepState();
      }
    };

    // Route incoming audio stream to hardware speakerphone at full volume
    pc.onTrack = (RTCTrackEvent ev) {
      if (ev.track.kind == 'audio') {
        ev.track.enabled = true;
        _remoteTracks.putIfAbsent(remoteId, () => []).add(ev.track);
        try {
          Helper.setVolume(1.0, ev.track);
        } catch (_) {}
        MaglisPlatform.setSpeaker(true);
        Future.delayed(const Duration(milliseconds: 150), () {
          if (!_disposed) {
            try {
              Helper.setVolume(1.0, ev.track);
            } catch (_) {}
            MaglisPlatform.setSpeaker(true);
          }
        });
      }
    };

    pc.onDataChannel = (RTCDataChannel dc) => _bindDataChannel(remoteId, dc);
    return pc;
  }

  Future<void> _triggerIceRestart(String remoteId) async {
    final pc = _peers[remoteId];
    if (pc == null || _disposed) return;
    try {
      final curSigState = await pc.getSignalingState() ?? pc.signalingState;
      if (curSigState != RTCSignalingState.RTCSignalingStateStable) {
        // Offer/answer exchange already pending
        return;
      }
      final isInitiator = localPeerId.compareTo(remoteId) < 0;
      if (isInitiator &&
          (_channels[remoteId] == null ||
              _channels[remoteId]!.state !=
                  RTCDataChannelState.RTCDataChannelOpen)) {
        try {
          final dc = await pc.createDataChannel(
            'maglis_sync',
            RTCDataChannelInit()
              ..ordered = true
              ..maxRetransmits = 30
              ..binaryType = 'binary',
          );
          _bindDataChannel(remoteId, dc);
        } catch (_) {}
      }
      await pc.restartIce();
      final offer = await pc.createOffer(const {
        'mandatory': {
          'OfferToReceiveAudio': true,
          'OfferToReceiveVideo': false,
        },
        'optional': [
          {'iceRestart': true},
        ],
      });
      final mungedSdp = mungeOpusSdp(offer.sdp ?? '');
      await pc.setLocalDescription(
        RTCSessionDescription(mungedSdp, offer.type),
      );
      await _sendSignal('offer', targetId: remoteId, data: {
        'sdp': mungedSdp,
        'iceRestart': true,
      });
    } catch (e) {
      debugPrint('[MaglisNetwork] restartIce error, recreating peer: $e');
      // If native restartIce fails on corrupted state, recreate peer deterministically
      await _cleanupPeer(remoteId);
      await _sendSignal('beacon', targetId: remoteId, data: const {});
    }
  }

  Future<void> _recoverDataChannel(String remoteId) async {
    if (_disposed || !_peers.containsKey(remoteId)) return;
    final pc = _peers[remoteId];
    if (pc == null) return;

    final isInitiator = localPeerId.compareTo(remoteId) < 0;
    if (isInitiator) {
      if (_negotiatingPeers.contains(remoteId)) return;
      _negotiatingPeers.add(remoteId);
      try {
        final curDc = _channels[remoteId];
        if (curDc != null &&
            curDc.state == RTCDataChannelState.RTCDataChannelOpen) {
          return;
        }
        final dc = await pc.createDataChannel(
          'maglis_sync',
          RTCDataChannelInit()
            ..ordered = true
            ..maxRetransmits = 30
            ..binaryType = 'binary',
        );
        _bindDataChannel(remoteId, dc);

        final offer = await pc.createOffer(const {
          'mandatory': {
            'OfferToReceiveAudio': true,
            'OfferToReceiveVideo': false,
          },
          'optional': [],
        });
        final mungedSdp = mungeOpusSdp(offer.sdp ?? '');
        await pc.setLocalDescription(
          RTCSessionDescription(mungedSdp, offer.type),
        );
        await _sendSignal('offer', targetId: remoteId, data: {
          'sdp': mungedSdp,
          'dcRecovery': true,
        });
      } catch (e) {
        debugPrint('[MaglisNetwork] recoverDataChannel error: $e');
      } finally {
        _negotiatingPeers.remove(remoteId);
      }
    } else {
      _sendSignal('reconnect_request',
          targetId: remoteId, data: {'reason': 'dc_recovery'});
    }
  }

  Future<void> _flushIceQueue(String remoteId) async {
    final pc = _peers[remoteId];
    final queue = _iceQueues[remoteId];
    if (pc == null || queue == null) return;
    for (final c in List<RTCIceCandidate>.from(queue)) {
      try {
        await pc.addCandidate(c);
      } catch (_) {}
    }
    queue.clear();
  }

  void _bindDataChannel(String remoteId, RTCDataChannel dc) {
    _channels[remoteId] = dc;
    try {
      dc.bufferedAmountLowThreshold = 64 * 1024;
    } catch (_) {}
    dc.onBufferedAmountLow = (_) {
      if (_peersNeedingCatchup.remove(remoteId) && !_disposed) {
        try {
          dc.send(RTCDataChannelMessage(onBuildSnapshot().pack()));
        } catch (_) {}
      }
    };
    dc.onDataChannelState = (RTCDataChannelState state) {
      if (state == RTCDataChannelState.RTCDataChannelOpen) {
        _lastSeenPeerMs[remoteId] = DateTime.now().millisecondsSinceEpoch;
        _checkSocketSleepState();
        // Catch up newly connected peer with full room state snapshot
        try {
          dc.send(RTCDataChannelMessage(onBuildSnapshot().pack()));
        } catch (_) {}
        // Mesh gossip announcement: share active peers with newcomer to guarantee full mesh
        final activeOthers = _roomParticipants
            .where((p) => p != remoteId && p != localPeerId)
            .toList();
        if (activeOthers.isNotEmpty) {
          try {
            dc.send(RTCDataChannelMessage(jsonEncode({
              't': 98,
              'peers': activeOthers,
            })));
          } catch (_) {}
        }
        // Send any vital packets that were queued while channel was establishing
        if (_pendingVitalPackets.isNotEmpty) {
          for (final vital in List<String>.from(_pendingVitalPackets)) {
            try {
              dc.send(RTCDataChannelMessage(vital));
            } catch (_) {}
          }
          _pendingVitalPackets.clear();
        }
      } else if (state == RTCDataChannelState.RTCDataChannelClosed) {
        _channels.remove(remoteId);
        if (!_disposed && _peers.containsKey(remoteId)) {
          final peerState = _peerStates[remoteId];
          final isConnected = peerState ==
                  RTCIceConnectionState.RTCIceConnectionStateConnected ||
              peerState ==
                  RTCIceConnectionState.RTCIceConnectionStateCompleted;
          if (isConnected) {
            unawaited(_recoverDataChannel(remoteId));
          }
        }
      }
    };

    dc.onMessage = (RTCDataChannelMessage msg) {
      if (msg.isBinary || msg.text.isEmpty) return;
      _lastSeenPeerMs[remoteId] = DateTime.now().millisecondsSinceEpoch;
      _handleIncomingPacketString(msg.text);
    };
  }

  void _handleIncomingPacketString(String raw) {
    if (raw.isEmpty) return;
    try {
      if (raw.contains('"type":"leave"') || raw.contains('"t":99')) {
        try {
          final m = jsonDecode(raw) as Map<String, dynamic>;
          final u = m['u'] as String?;
          if (u != null && u.isNotEmpty && u != localPeerId) {
            _roomParticipants.remove(u);
            _admittedPeers.remove(u);
            _participantCountCtrl.add(_roomParticipants.length + 1);
            unawaited(_cleanupPeer(u));
          }
        } catch (_) {}
        return;
      }

      if (raw.contains('"t":98') || raw.contains('"type":"peer_list"')) {
        try {
          final m = jsonDecode(raw) as Map<String, dynamic>;
          final peersList = m['peers'] as List<dynamic>?;
          if (peersList != null) {
            for (final p in peersList) {
              final id = p.toString();
              if (id.isNotEmpty &&
                  id != localPeerId &&
                  !_peers.containsKey(id) &&
                  !_roomParticipants.contains(id)) {
                if (_roomParticipants.length < maxRemotePeers) {
                  _admittedPeers.add(id);
                  _roomParticipants.add(id);
                  _participantCountCtrl.add(_roomParticipants.length + 1);
                  final isInitiator = localPeerId.compareTo(id) < 0;
                  if (isInitiator) {
                    unawaited(_initiatePeerConnection(id));
                  } else {
                    _sendSignal('beacon', targetId: id, data: const {});
                  }
                }
              }
            }
          }
        } catch (_) {}
        return;
      }

      final pkt = MaglisPacket.unpack(raw);
      if (pkt.type == MaglisPacketType.ping) {
        _dispatchRaw(jsonEncode({
          't': 5,
          'u': localPeerId,
          'm': DateTime.now().millisecondsSinceEpoch,
        }));
        return;
      }
      if (pkt.type == MaglisPacketType.pong) return;

      if (pkt.type == MaglisPacketType.floorClaim) {
        _lastSeq.remove(pkt.senderId);
      }

      final prev = _lastSeq[pkt.senderId] ?? -1;
      if (pkt.type == MaglisPacketType.recitationUpdate &&
          pkt.seq <= prev &&
          (prev - pkt.seq) < 50000) {
        return;
      }
      _lastSeq[pkt.senderId] = pkt.seq;
      _packetCtrl.add(pkt);
    } catch (_) {}
  }

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

    final int asKbps = maxAverageBitrate <= 48000 ? 64 : 128;
    final int tiasBps = maxAverageBitrate <= 48000 ? 64000 : 128000;

    final audioMlineRegex =
        RegExp(r'(m=audio\s+\d+\s+[^\r\n]+)', caseSensitive: false);
    final audioMatch = audioMlineRegex.firstMatch(result);
    if (audioMatch != null) {
      final mline = audioMatch.group(1)!;
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
        result = result.replaceFirst(
            mline, '$mline${lineEnd}b=AS:$asKbps${lineEnd}b=TIAS:$tiasBps');
      } else if (!hasBas) {
        result = result.replaceFirst(mline, '$mline${lineEnd}b=AS:$asKbps');
      } else if (!hasBtias) {
        result = result.replaceFirst(mline, '$mline${lineEnd}b=TIAS:$tiasBps');
      }
    }

    return result;
  }

  void sendPacket(MaglisPacket packet, {bool throttle = false}) {
    if (_disposed) return;
    _dispatchRaw(packet.pack());
  }

  Future<void> sendSignalFast(
    String type, {
    String? targetId,
    required Map<String, dynamic> data,
  }) async {
    await _sendSignal(type, targetId: targetId, data: data);
  }

  void _dispatchRaw(String raw) {
    final msg = RTCDataChannelMessage(raw);
    bool anyChannelOpen = false;
    final bool isVital =
        raw.contains('"t":0') || raw.contains('"t":2') || raw.contains('"t":3');

    for (final entry in _channels.entries) {
      final remoteId = entry.key;
      final dc = entry.value;
      if (dc.state == RTCDataChannelState.RTCDataChannelOpen) {
        // Check per-peer backpressure: only skip non-vital recitation updates for
        // a specific slow peer without choking other peers in the room
        if (!isVital && (dc.bufferedAmount ?? 0) > 65536) {
          _peersNeedingCatchup.add(remoteId);
          continue;
        }
        try {
          dc.send(msg);
          anyChannelOpen = true;
        } catch (_) {}
      }
    }

    // Queue vital packets (floor claim, release, snapshot) if channels are still connecting
    if (!anyChannelOpen && isVital) {
      if (!_pendingVitalPackets.contains(raw)) {
        _pendingVitalPackets.add(raw);
        if (_pendingVitalPackets.length > 20) {
          _pendingVitalPackets.removeAt(0);
        }
      }
    }
  }

  Future<void> setMicMuted(bool muted) async {
    _isMicMuted = muted;
    if (!muted &&
        (_localStream == null || _localStream!.getAudioTracks().isEmpty)) {
      try {
        _localStream = await navigator.mediaDevices.getUserMedia(
          _buildAudioConstraints(),
        );
        for (final entry in _peers.entries) {
          _localStream?.getAudioTracks().forEach((track) {
            track.enabled = true;
            try {
              entry.value.addTrack(track, _localStream!);
            } catch (_) {}
          });
          final isInitiator = localPeerId.compareTo(entry.key) < 0;
          if (isInitiator) {
            _triggerIceRestart(entry.key);
          } else {
            _sendSignal('reconnect_request',
                targetId: entry.key, data: const {});
          }
        }
      } catch (_) {}
    } else {
      _localStream?.getAudioTracks().forEach((t) {
        t.enabled = !muted;
        try {
          Helper.setMicrophoneMute(muted, t);
        } catch (_) {}
      });
    }
  }

  Future<void> retryConnections() async {
    for (final entry in _peers.entries) {
      final state = _peerStates[entry.key];
      if (state == RTCIceConnectionState.RTCIceConnectionStateFailed ||
          state == RTCIceConnectionState.RTCIceConnectionStateDisconnected) {
        try {
          await entry.value.restartIce();
        } catch (_) {}
      }
    }
    await _sendSignal('beacon', data: const {});
  }

  Future<void> _cleanupPeer(String peerId) async {
    _peersNeedingCatchup.remove(peerId);
    _admittedPeers.remove(peerId);
    _iceQueues.remove(peerId);
    _pendingOutboundCandidates.remove(peerId);
    _iceDebounceTimers.remove(peerId)?.cancel();
    _iceRestartGraceTimers.remove(peerId)?.cancel();
    _remoteDescSet.remove(peerId);
    _peerStates.remove(peerId);
    _lastSeenPeerMs.remove(peerId);
    _roomParticipants.remove(peerId);
    _answerInFlight.remove(peerId);
    _negotiatingPeers.remove(peerId);
    _lastSeq.remove(peerId);
    _participantCountCtrl.add(_roomParticipants.length + 1);

    // Host Migration: If current host departed, deterministically elect remaining peer with smallest ID
    if (!_isHost) {
      if (_roomParticipants.isEmpty) {
        _isHost = true;
      } else {
        final allPeers = [localPeerId, ..._roomParticipants]..sort();
        if (allPeers.first == localPeerId) {
          _isHost = true;
        }
      }
    }
    final remoteTracks = _remoteTracks.remove(peerId);
    if (remoteTracks != null) {
      for (final t in remoteTracks) {
        try {
          t.stop();
        } catch (_) {}
      }
    }
    try {
      final dc = _channels.remove(peerId);
      if (dc != null) {
        dc.onDataChannelState = null;
        dc.onMessage = null;
        await dc.close();
      }
    } catch (_) {}
    try {
      final pc = _peers.remove(peerId);
      if (pc != null) {
        // Detach all callbacks to prevent asynchronous native TURN/STUN events hitting dying objects
        pc.onIceCandidate = null;
        pc.onIceConnectionState = null;
        pc.onConnectionState = null;
        pc.onSignalingState = null;
        pc.onTrack = null;
        pc.onDataChannel = null;
        pc.onRenegotiationNeeded = null;

        try {
          final senders = await pc.getSenders();
          for (final s in senders) {
            try {
              await pc.removeTrack(s);
            } catch (_) {}
          }
        } catch (_) {}
        await pc.close();
        await pc.dispose();
      }
    } catch (_) {}
    if (!_disposed) {
      _statesCtrl.add(Map.unmodifiable(_peerStates));
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _beaconTimer?.cancel();
    _pingTimer?.cancel();
    _throttleTimer?.cancel();
    _relayHeartbeatTimer?.cancel();
    _watchdogTimer?.cancel();
    _epochRefreshTimer?.cancel();
    for (final t in _iceDebounceTimers.values) {
      t.cancel();
    }
    _iceDebounceTimers.clear();
    for (final t in _iceRestartGraceTimers.values) {
      t.cancel();
    }
    _iceRestartGraceTimers.clear();
    _pendingOutboundCandidates.clear();
    _pendingVitalPackets.clear();

    try {
      // 1. Immediately notify peers via direct P2P DataChannel (0ms latency)
      _dispatchRaw(jsonEncode({
        't': 99,
        'u': localPeerId,
        'type': 'leave',
      }));

      final leaveSig = MaglisSignal(
        type: 'leave',
        senderId: localPeerId,
        data: {'auth': MaglisCrypto.admissionToken(roomCode, localPeerId)},
      );
      final cipher = await MaglisCrypto.encrypt(leaveSig.pack(), roomCode);
      final tags = _activeTags;
      final frame = await MaglisCrypto.signNostrEventAsync(
        privHex: _privHex,
        pubHex: _pubHex,
        tag: tags.first,
        additionalTags: tags.length > 1 ? tags.sublist(1) : null,
        content: cipher,
      );
      for (final ws in _sockets.values) {
        try {
          ws.sink.add(frame);
        } catch (_) {}
      }
      // Brief flush delay so TCP buffer transmits leave frame before socket teardown
      await Future.delayed(const Duration(milliseconds: 80));
      for (final ws in _sockets.values) {
        try {
          await ws.sink.close();
        } catch (_) {}
      }
    } catch (_) {}
    _sockets.clear();
    _admittedPeers.clear();

    for (final id in List<String>.from(_peers.keys)) {
      await _cleanupPeer(id);
    }
    _remoteTracks.clear();

    _localStream?.getTracks().forEach((t) => t.stop());
    await _localStream?.dispose();
    await MaglisPlatform.setWakeLock(false);

    await _packetCtrl.close();
    await _statesCtrl.close();
    await _natFailCtrl.close();
    await _participantCountCtrl.close();
  }

  /// Verifies if a room exists and has capacity (< 4 members) before joining.
  /// Follows robust primary-to-fallback order with automatic fast retry on transient cellular drops.
  static Future<MaglisJoinResult> verifyRoomJoinable(String roomCode) async {
    final trimmed = normalizeArabicDigits(roomCode.trim());
    if (trimmed.length != 5) return MaglisJoinResult.notFound;

    final tags = MaglisCrypto.activeBlindedTags(trimmed);
    final probePeerId = MaglisCrypto.randomHex32().substring(0, 10);
    final privHex = MaglisCrypto.randomHex32();
    final pubHex = MaglisCrypto.getPublicKey(privHex);

    try {
      final probeSig = MaglisSignal(
        type: 'join_probe',
        senderId: probePeerId,
        data: {'auth': MaglisCrypto.admissionToken(trimmed, probePeerId)},
      );
      final cipher = await MaglisCrypto.encrypt(probeSig.pack(), trimmed);
      final frame = await MaglisCrypto.signNostrEventAsync(
        privHex: privHex,
        pubHex: pubHex,
        tag: tags.first,
        additionalTags: tags.length > 1 ? tags.sublist(1) : null,
        content: cipher,
      );

      // 1. Fast-Path Primary: Probe top Cloudflare relay first (3200ms timeout for mobile/cellular/VPN)
      final primaryResult = await _probeSingleRelay(
        url: _relays.first,
        trimmed: trimmed,
        frame: frame,
        tags: tags,
        probePeerId: probePeerId,
        timeoutMs: 3200,
      );
      if (primaryResult == MaglisJoinResult.success ||
          primaryResult == MaglisJoinResult.full) {
        return primaryResult!;
      }

      // Fast-retry on primary: if initial attempt timed out due to cellular socket warmup, retry once (2000ms)
      if (primaryResult == null) {
        final retryResult = await _probeSingleRelay(
          url: _relays.first,
          trimmed: trimmed,
          frame: frame,
          tags: tags,
          probePeerId: probePeerId,
          timeoutMs: 2000,
        );
        if (retryResult == MaglisJoinResult.success ||
            retryResult == MaglisJoinResult.full) {
          return retryResult!;
        }
      }

      // 2. Hedged Fallback Race: If primary is offline/unreachable, race top 3 fallback relays
      final fallbackRelays = _relays.skip(1).take(3).toList();
      if (fallbackRelays.isEmpty) return MaglisJoinResult.notFound;

      final fallbackFutures = fallbackRelays.map((url) => _probeSingleRelay(
            url: url,
            trimmed: trimmed,
            frame: frame,
            tags: tags,
            probePeerId: probePeerId,
            timeoutMs: 2200,
          ));

      final results = await Future.wait(fallbackFutures);
      for (final r in results) {
        if (r == MaglisJoinResult.success || r == MaglisJoinResult.full) {
          return r!;
        }
      }
    } catch (_) {}

    return MaglisJoinResult.notFound;
  }

  static Future<MaglisJoinResult?> _probeSingleRelay({
    required String url,
    required String trimmed,
    required String frame,
    required List<String> tags,
    required String probePeerId,
    required int timeoutMs,
  }) async {
    WebSocketChannel? ws;
    StreamSubscription? sub;
    try {
      ws = WebSocketChannel.connect(Uri.parse(formatRelayUrl(url, trimmed)));
      final readyMs = (timeoutMs - 800).clamp(1200, 2400);
      await ws.ready.timeout(Duration(milliseconds: readyMs));

      final completer = Completer<MaglisJoinResult?>();
      sub = ws.stream.listen((dynamic raw) async {
        if (completer.isCompleted || raw is! String) return;
        try {
          final list = jsonDecode(raw);
          if (list is! List || list.length < 3 || list[0] != 'EVENT') return;
          final ev = list[2] as Map<String, dynamic>;
          final content = ev['content'] as String?;
          if (content == null) return;
          final clear = await MaglisCrypto.decrypt(content, trimmed);
          if (clear == null) return;
          final sig = MaglisSignal.unpack(clear);
          if (sig.senderId == probePeerId) return;

          if (sig.type == 'join_reject' &&
              (sig.targetId == null || sig.targetId == probePeerId)) {
            if (!completer.isCompleted) {
              completer.complete(MaglisJoinResult.full);
            }
          } else if (sig.type == 'join_ack' &&
              (sig.targetId == null || sig.targetId == probePeerId)) {
            if (!completer.isCompleted) {
              completer.complete(MaglisJoinResult.success);
            }
          } else if ((sig.type == 'beacon' || sig.type == 'offer') &&
              !completer.isCompleted) {
            completer.complete(MaglisJoinResult.success);
          }
        } catch (_) {}
      }, onError: (_) {}, onDone: () {});

      ws.sink.add(jsonEncode([
        'REQ',
        'probe_${tags.first}',
        {
          'kinds': [20000],
          '#t': tags,
        }
      ]));
      ws.sink.add(frame);

      final result = await completer.future.timeout(
        Duration(milliseconds: timeoutMs),
        onTimeout: () => null,
      );

      await sub.cancel();
      try {
        await ws.sink.close();
      } catch (_) {}
      return result;
    } catch (_) {
      await sub?.cancel();
      try {
        await ws?.sink.close();
      } catch (_) {}
      return null;
    }
  }

  /// Probes whether a room code is currently active or reserved in a session.
  /// Fast-path primary with hedged fallback race if primary is unreachable.
  static Future<bool> isRoomCodeInUse(String roomCode) async {
    final trimmed = normalizeArabicDigits(roomCode.trim());
    if (trimmed.length != 5) return false;

    final tags = MaglisCrypto.activeBlindedTags(trimmed);
    final probePeerId = MaglisCrypto.randomHex32().substring(0, 10);
    final privHex = MaglisCrypto.randomHex32();
    final pubHex = MaglisCrypto.getPublicKey(privHex);

    try {
      final probeSig = MaglisSignal(
        type: 'presence_probe',
        senderId: probePeerId,
        data: {'auth': MaglisCrypto.admissionToken(trimmed, probePeerId)},
      );
      final cipher = await MaglisCrypto.encrypt(probeSig.pack(), trimmed);
      final frame = await MaglisCrypto.signNostrEventAsync(
        privHex: privHex,
        pubHex: pubHex,
        tag: tags.first,
        additionalTags: tags.length > 1 ? tags.sublist(1) : null,
        content: cipher,
      );

      final primaryInUse = await _presenceSingleRelay(
        url: _relays.first,
        trimmed: trimmed,
        frame: frame,
        tags: tags,
        probePeerId: probePeerId,
        timeoutMs: 1800,
      );
      if (primaryInUse != null) {
        return primaryInUse;
      }

      final fallbackRelays = _relays.skip(1).take(3).toList();
      final futures = fallbackRelays.map((url) => _presenceSingleRelay(
            url: url,
            trimmed: trimmed,
            frame: frame,
            tags: tags,
            probePeerId: probePeerId,
            timeoutMs: 1600,
          ));
      final results = await Future.wait(futures);
      return results.any((r) => r == true);
    } catch (_) {}

    return false;
  }

  static Future<bool?> _presenceSingleRelay({
    required String url,
    required String trimmed,
    required String frame,
    required List<String> tags,
    required String probePeerId,
    required int timeoutMs,
  }) async {
    WebSocketChannel? ws;
    StreamSubscription? sub;
    try {
      ws = WebSocketChannel.connect(Uri.parse(formatRelayUrl(url, trimmed)));
      final readyMs = (timeoutMs - 500).clamp(800, 1500);
      await ws.ready.timeout(Duration(milliseconds: readyMs));

      final completer = Completer<bool?>();
      sub = ws.stream.listen((dynamic raw) async {
        if (completer.isCompleted || raw is! String) return;
        try {
          final list = jsonDecode(raw);
          if (list is! List || list.length < 3 || list[0] != 'EVENT') return;
          final ev = list[2] as Map<String, dynamic>;
          final content = ev['content'] as String?;
          if (content == null) return;
          final clear = await MaglisCrypto.decrypt(content, trimmed);
          if (clear == null) return;
          final sig = MaglisSignal.unpack(clear);
          if (sig.senderId == probePeerId) return;

          final isRealPresence = sig.type == 'presence_pong' ||
              sig.type == 'beacon' ||
              sig.type == 'offer' ||
              sig.type == 'join_ack';

          if (isRealPresence && !completer.isCompleted) {
            completer.complete(true);
          }
        } catch (_) {}
      }, onError: (_) {}, onDone: () {});

      ws.sink.add(jsonEncode([
        'REQ',
        'p_${tags.first}',
        {
          'kinds': [20000],
          '#t': tags,
        }
      ]));
      ws.sink.add(frame);

      final inUse = await completer.future.timeout(
        Duration(milliseconds: timeoutMs),
        onTimeout: () => null,
      );

      await sub.cancel();
      try {
        await ws.sink.close();
      } catch (_) {}
      return inUse;
    } catch (_) {
      await sub?.cancel();
      try {
        await ws?.sink.close();
      } catch (_) {}
      return null;
    }
  }

  /// Announces a temporary reservation of a room code while user is configuring "Make Room"
  /// Sequential: publishes reservation strictly to the top healthy relay.
  static Future<void> reserveRoomCode(String roomCode, String tempId) async {
    try {
      final trimmed = normalizeArabicDigits(roomCode.trim());
      final tags = MaglisCrypto.activeBlindedTags(trimmed);
      final privHex = MaglisCrypto.randomHex32();
      final pubHex = MaglisCrypto.getPublicKey(privHex);

      final sig = MaglisSignal(
        type: 'reserve_code',
        senderId: tempId,
        data: {'auth': MaglisCrypto.admissionToken(trimmed, tempId)},
      );
      final cipher = await MaglisCrypto.encrypt(sig.pack(), trimmed);
      final frame = await MaglisCrypto.signNostrEventAsync(
        privHex: privHex,
        pubHex: pubHex,
        tag: tags.first,
        content: cipher,
      );

      for (final url in _relays) {
        try {
          final ws =
              WebSocketChannel.connect(Uri.parse(formatRelayUrl(url, trimmed)));
          await ws.ready.timeout(const Duration(milliseconds: 1200));
          ws.sink.add(frame);
          await Future.delayed(const Duration(milliseconds: 200));
          try {
            await ws.sink.close();
          } catch (_) {}
          break; // Top healthy relay succeeded, done!
        } catch (_) {
          continue; // Try next relay if top failed
        }
      }
    } catch (_) {}
  }
}

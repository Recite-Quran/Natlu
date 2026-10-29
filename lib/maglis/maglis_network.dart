import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'maglis_core.dart';

class MaglisNetworkEngine {
  static const int maxRemotePeers = 3; // 4 total participants in a Maglis
  static const List<String> _relays = [
    'wss://relay.damus.io',
    'wss://nos.lol',
    'wss://relay.primal.net',
    'wss://nostr.mom',
  ];

  static const Map<String, dynamic> _rtcConfig = {
    'iceServers': [
      {'urls': 'stun:stun.l.google.com:19302'},
      {'urls': 'stun:stun1.l.google.com:19302'},
      {'urls': 'stun:stun2.l.google.com:19302'},
      {'urls': 'stun:stun3.l.google.com:19302'},
      {'urls': 'stun:stun4.l.google.com:19302'},
      {'urls': 'stun:stun.cloudflare.com:3478'},
      {
        'urls': [
          'turn:openrelay.metered.ca:80',
          'turn:openrelay.metered.ca:80?transport=tcp',
          'turn:openrelay.metered.ca:443',
          'turn:openrelay.metered.ca:443?transport=tcp',
          'turn:openrelay.metered.ca:443?transport=udp',
        ],
        'username': 'openrelayproject',
        'credential': 'openrelayproject',
      },
    ],
    'sdpSemantics': 'unified-plan',
    'bundlePolicy': 'max-bundle',
    'rtcpMuxPolicy': 'require',
    'iceCandidatePoolSize': 10,
  };

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
  final MaglisPacket Function() onBuildSnapshot;

  late final String _privHex = MaglisCrypto.randomHex32();
  late final String _blindedTag = MaglisCrypto.blindedTag(roomCode);

  final Map<String, WebSocketChannel> _sockets = {};
  final LinkedHashSet<String> _seenNostrIds = LinkedHashSet<String>();

  final Map<String, RTCPeerConnection> _peers = {};
  final Map<String, RTCDataChannel> _channels = {};
  final Map<String, List<RTCIceCandidate>> _iceQueues = {};
  final Map<String, bool> _remoteDescSet = {};
  final Map<String, int> _lastSeq = {};
  final Map<String, RTCIceConnectionState> _peerStates = {};
  final Set<String> _roomParticipants = <String>{};
  final Map<String, int> _lastSeenPeerMs = {};
  final Map<String, bool> _makingOffer = {};

  MediaStream? _localStream;
  bool _isMicMuted = false; // Always-on open mic conference for all room members
  bool _disposed = false;
  Timer? _beaconTimer;
  Timer? _pingTimer;
  Timer? _throttleTimer;
  Timer? _relayHeartbeatTimer;
  Timer? _livenessReaperTimer;
  MaglisPacket? _queuedPacket;

  final _packetCtrl = StreamController<MaglisPacket>.broadcast();
  final _statesCtrl =
      StreamController<Map<String, RTCIceConnectionState>>.broadcast();
  final _natFailCtrl = StreamController<String>.broadcast();
  final _participantCountCtrl = StreamController<int>.broadcast();

  MaglisNetworkEngine({
    required this.roomCode,
    required this.localPeerId,
    required this.onBuildSnapshot,
  });

  Stream<MaglisPacket> get onPacket => _packetCtrl.stream;
  Stream<Map<String, RTCIceConnectionState>> get onPeerStates =>
      _statesCtrl.stream;
  Stream<String> get onNatFailure => _natFailCtrl.stream;
  Stream<int> get onParticipantCount => _participantCountCtrl.stream;
  int get participantCount => _roomParticipants.length + 1; // self + remote
  bool get isMicMuted => _isMicMuted;

  static Map<String, dynamic> _buildAudioConstraints({String? inputDeviceId}) {
    return {
      'mandatory': {
        'googEchoCancellation': 'true',
        'googEchoCancellation2': 'true',
        'googDAEchoCancellation': 'true',
        'googAutoGainControl': 'true',
        'googAutoGainControl2': 'true',
        'googNoiseSuppression': 'false', // Unfiltered natural Tajweed recitation
        'googHighpassFilter': 'true', // Cuts subsonic pops and DC rumble
        'googTypingNoiseDetection': 'false',
        'googAudioMirroring': 'false',
      },
      'optional': [
        {'echoCancellation': 'true'},
        {'autoGainControl': 'true'},
        {'noiseSuppression': 'false'},
        {'highpassFilter': 'true'},
        if (inputDeviceId != null) {'deviceId': inputDeviceId},
      ],
      'echoCancellation': true, // Hardware AEC prevents loudspeaker howl
      'autoGainControl': true, // High volume amplification for distance reading
      'noiseSuppression': false, // No aggressive noise gate cuts on Madd/Ghunnah
      'highpassFilter': true,
      'channelCount': 1,
      'sampleRate': 48000,
      if (inputDeviceId != null) 'deviceId': inputDeviceId,
    };
  }

  Future<void> start({String? inputDeviceId}) async {
    await MaglisPlatform.initAudio();
    await MaglisPlatform.setWakeLock(true);

    try {
      _localStream = await navigator.mediaDevices.getUserMedia({
        'audio': _buildAudioConstraints(inputDeviceId: inputDeviceId),
        'video': false,
      });
    } catch (_) {
      try {
        _localStream = await navigator.mediaDevices.getUserMedia({
          'audio': true,
          'video': false,
        });
      } catch (_) {}
    }

    // Always-on open mic: tracks start enabled so all members can talk and discuss
    _localStream?.getAudioTracks().forEach((track) {
      track.enabled = true;
    });
    _isMicMuted = false;

    for (final url in _relays) {
      _connectRelay(url);
    }

    await _sendSignal('beacon', data: const {});
    // Periodic beaconing to discover new peers until room capacity is reached
    _beaconTimer = Timer.periodic(const Duration(seconds: 12), (_) {
      if (!_disposed && _peers.length < maxRemotePeers) {
        _sendSignal('beacon', data: const {});
      }
    });

    _pingTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (_disposed) return;
      final snap = onBuildSnapshot();
      sendPacket(
        MaglisPacket(
          type: MaglisPacketType.ping,
          seq: snap.seq,
          senderId: localPeerId,
          page: snap.page,
          surah: snap.surah,
          ayah: snap.ayah,
          activeReciterId: snap.activeReciterId,
          ts: DateTime.now().millisecondsSinceEpoch,
        ),
      );
    });

    // 25s WebSocket Keep-Alive Heartbeat: prevents Nostr relays from idling out & closing TCP sockets
    _relayHeartbeatTimer = Timer.periodic(const Duration(seconds: 25), (_) {
      if (_disposed) return;
      final pingTag = 'hb_${DateTime.now().millisecondsSinceEpoch}';
      for (final ws in _sockets.values) {
        try {
          ws.sink.add(jsonEncode(['REQ', pingTag, {'limit': 0}]));
        } catch (_) {}
      }
    });

    // Liveness Reaper: auto-evicts zombie/dead peers who killed their app or dropped connection
    _livenessReaperTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (_disposed) return;
      final now = DateTime.now().millisecondsSinceEpoch;
      for (final peerId in List<String>.from(_roomParticipants)) {
        final lastSeen = _lastSeenPeerMs[peerId] ?? 0;
        if (lastSeen > 0 && (now - lastSeen) > 16000) {
          _cleanupPeer(peerId);
        }
      }
    });
  }

  void _connectRelay(String url) {
    if (_disposed) return;
    try {
      final ws = WebSocketChannel.connect(Uri.parse(url));
      _sockets[url] = ws;

      // 2 minutes window to accommodate any client/server clock skew
      final since = (DateTime.now().millisecondsSinceEpoch ~/ 1000) - 120;
      ws.sink.add(jsonEncode([
        'REQ',
        'maglis_$_blindedTag',
        {
          'kinds': [20000],
          '#t': [_blindedTag],
          'since': since,
        }
      ]));

      ws.stream.listen(
        _onRelayFrame,
        onDone: () => _scheduleReconnect(url),
        onError: (_) => _scheduleReconnect(url),
      );
    } catch (_) {
      _scheduleReconnect(url);
    }
  }

  void _scheduleReconnect(String url) {
    _sockets.remove(url);
    if (_disposed) return;
    Future.delayed(const Duration(seconds: 4), () => _connectRelay(url));
  }

  Future<void> _sendSignal(
    String type, {
    String? targetId,
    required Map<String, dynamic> data,
  }) async {
    if (_disposed) return;
    final sig = MaglisSignal(
      type: type,
      senderId: localPeerId,
      targetId: targetId,
      data: data,
    );
    final cipher = await MaglisCrypto.encrypt(sig.pack(), roomCode);
    final frame = MaglisCrypto.signNostrEvent(
      privHex: _privHex,
      tag: _blindedTag,
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
      if (id == null || content == null) return;

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

      _lastSeenPeerMs[sig.senderId] = DateTime.now().millisecondsSinceEpoch;
      if (!_roomParticipants.contains(sig.senderId)) {
        _roomParticipants.add(sig.senderId);
        _participantCountCtrl.add(_roomParticipants.length + 1);
      }

      await _handleSignal(sig);
    } catch (_) {}
  }

  Future<void> _handleSignal(MaglisSignal sig) async {
    final remoteId = sig.senderId;

    switch (sig.type) {
      case 'beacon':
        final existingPc = _peers[remoteId];
        final existingState = _peerStates[remoteId];
        if (existingPc != null &&
            existingState !=
                RTCIceConnectionState.RTCIceConnectionStateFailed &&
            existingState !=
                RTCIceConnectionState.RTCIceConnectionStateDisconnected &&
            existingState !=
                RTCIceConnectionState.RTCIceConnectionStateClosed) {
          // Already connected or in-flight negotiation with this peer; do not tear down!
          return;
        }
        if (!_peers.containsKey(remoteId) && _peers.length >= maxRemotePeers) {
          return;
        }

        // Deterministic Glare Resolution: smaller ID initiates Offer
        final isInitiator = localPeerId.compareTo(remoteId) < 0;
        if (isInitiator) {
          final pc = await _createPeer(remoteId);
          final dc = await pc.createDataChannel(
            'maglis_sync',
            RTCDataChannelInit()..ordered = true,
          );
          _bindDataChannel(remoteId, dc);

          _makingOffer[remoteId] = true;
          try {
            final offer = await pc.createOffer();
            final mungedSdp = _mungeOpusSdp(offer.sdp ?? '');
            await pc.setLocalDescription(
                RTCSessionDescription(mungedSdp, offer.type));
            await _sendSignal('offer',
                targetId: remoteId, data: {'sdp': mungedSdp});
          } finally {
            _makingOffer[remoteId] = false;
          }
        } else if (sig.targetId == null) {
          await _sendSignal('beacon', targetId: remoteId, data: const {});
        }
        break;

      case 'offer':
        if (!_peers.containsKey(remoteId) && _peers.length >= maxRemotePeers) {
          return;
        }
        final pc = _peers[remoteId] ?? await _createPeer(remoteId);
        final sdp = sig.data['sdp'] as String?;
        if (sdp == null) return;

        // W3C Perfect Negotiation Collision Handling:
        // Polite peer rolls back local description; impolite peer ignores collision
        final isPolite = localPeerId.compareTo(remoteId) > 0;
        final bool offerCollision = (_makingOffer[remoteId] == true) ||
            (pc.signalingState != RTCSignalingState.RTCSignalingStateStable);

        if (offerCollision) {
          if (!isPolite) {
            return; // Impolite peer ignores colliding offer
          }
          try {
            await pc.setLocalDescription(RTCSessionDescription('', 'rollback'));
          } catch (_) {}
        }

        await pc.setRemoteDescription(RTCSessionDescription(sdp, 'offer'));
        _remoteDescSet[remoteId] = true;
        await _flushIceQueue(remoteId);

        final answer = await pc.createAnswer();
        final mungedSdp = _mungeOpusSdp(answer.sdp ?? '');
        await pc
            .setLocalDescription(RTCSessionDescription(mungedSdp, answer.type));
        await _sendSignal('answer',
            targetId: remoteId, data: {'sdp': mungedSdp});
        break;

      case 'answer':
        final pc = _peers[remoteId];
        final sdp = sig.data['sdp'] as String?;
        if (pc == null || sdp == null) return;
        if (pc.signalingState ==
            RTCSignalingState.RTCSignalingStateHaveLocalOffer) {
          await pc.setRemoteDescription(RTCSessionDescription(sdp, 'answer'));
          _remoteDescSet[remoteId] = true;
          await _flushIceQueue(remoteId);
        }
        break;

      case 'ice':
        final candStr = sig.data['candidate'] as String?;
        if (!_isValidCandidate(candStr)) return;
        final cand = RTCIceCandidate(
          candStr,
          sig.data['sdpMid'] as String?,
          sig.data['sdpMLineIndex'] as int?,
        );
        if (_remoteDescSet[remoteId] == true && _peers[remoteId] != null) {
          await _peers[remoteId]!.addCandidate(cand);
        } else {
          _iceQueues.putIfAbsent(remoteId, () => []).add(cand);
        }
        break;

      case 'pkt':
        final raw = sig.data['p'] as String?;
        if (raw != null) {
          _handleIncomingPacketString(raw);
        }
        break;

      case 'leave':
        _roomParticipants.remove(remoteId);
        _participantCountCtrl.add(_roomParticipants.length + 1);
        await _cleanupPeer(remoteId);
        break;
    }
  }

  Future<RTCPeerConnection> _createPeer(String remoteId) async {
    await _cleanupPeer(remoteId);
    final pc = await createPeerConnection(_rtcConfig);
    _peers[remoteId] = pc;
    _remoteDescSet[remoteId] = false;
    _iceQueues[remoteId] = [];

    _localStream?.getAudioTracks().forEach((track) {
      track.enabled = !_isMicMuted;
      pc.addTrack(track, _localStream!);
    });

    pc.onIceCandidate = (RTCIceCandidate c) {
      final str = c.candidate;
      if (!_isValidCandidate(str)) return;
      _sendSignal('ice', targetId: remoteId, data: {
        'candidate': str,
        'sdpMid': c.sdpMid,
        'sdpMLineIndex': c.sdpMLineIndex,
      });
    };

    pc.onIceConnectionState = (RTCIceConnectionState state) async {
      if (_disposed) return;
      _peerStates[remoteId] = state;
      _statesCtrl.add(Map.unmodifiable(_peerStates));

      // Network handover / NAT failure: Trigger genuine full ICE restart renegotiation
      if (state == RTCIceConnectionState.RTCIceConnectionStateDisconnected ||
          state == RTCIceConnectionState.RTCIceConnectionStateFailed) {
        _natFailCtrl.add(remoteId);
        await _triggerIceRestart(remoteId);
      }
    };

    // Flutter WebRTC plays incoming audio streams natively through hardware speaker
    pc.onTrack = (RTCTrackEvent ev) {
      if (ev.track.kind == 'audio') {
        ev.track.enabled = true;
        try {
          Helper.setVolume(1.0, ev.track);
        } catch (_) {}
        MaglisPlatform.setSpeaker(true);
      }
    };

    pc.onDataChannel = (RTCDataChannel dc) => _bindDataChannel(remoteId, dc);
    return pc;
  }

  Future<void> _triggerIceRestart(String remoteId) async {
    final pc = _peers[remoteId];
    if (pc == null || _disposed) return;
    try {
      _makingOffer[remoteId] = true;
      await pc.restartIce();
      final offer = await pc.createOffer({'iceRestart': true});
      final mungedSdp = _mungeOpusSdp(offer.sdp ?? '');
      await pc
          .setLocalDescription(RTCSessionDescription(mungedSdp, offer.type));
      await _sendSignal('offer', targetId: remoteId, data: {
        'sdp': mungedSdp,
        'iceRestart': true,
      });
    } catch (_) {} finally {
      _makingOffer[remoteId] = false;
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
    dc.onDataChannelState = (RTCDataChannelState state) {
      if (state == RTCDataChannelState.RTCDataChannelOpen) {
        try {
          dc.send(RTCDataChannelMessage(onBuildSnapshot().pack()));
        } catch (_) {}
      }
    };

    dc.onMessage = (RTCDataChannelMessage msg) {
      if (msg.isBinary || msg.text.isEmpty) return;
      _handleIncomingPacketString(msg.text);
    };
  }

  void _handleIncomingPacketString(String raw) {
    if (raw.isEmpty) return;
    try {
      final pkt = MaglisPacket.unpack(raw);
      if (pkt.type == MaglisPacketType.ping) {
        sendPacket(
          MaglisPacket(
            type: MaglisPacketType.pong,
            seq: pkt.seq,
            senderId: localPeerId,
            page: pkt.page,
            surah: pkt.surah,
            ayah: pkt.ayah,
            activeReciterId: pkt.activeReciterId,
            ts: DateTime.now().millisecondsSinceEpoch,
          ),
        );
        return;
      }
      if (pkt.type == MaglisPacketType.pong) return;

      final prev = _lastSeq[pkt.senderId] ?? -1;
      if (pkt.type == MaglisPacketType.recitationUpdate && pkt.seq <= prev) {
        return;
      }
      _lastSeq[pkt.senderId] = pkt.seq;
      _packetCtrl.add(pkt);
    } catch (_) {}
  }

  String _mungeOpusSdp(String sdp) {
    final rtpmapRegex = RegExp(r'a=rtpmap:(\d+) opus/48000/2');
    final match = rtpmapRegex.firstMatch(sdp);
    if (match == null) return sdp;
    final pt = match.group(1)!;

    // WhatsApp-grade Opus voice profile:
    // - VBR (cbr=0) adapts instantly to mobile jitter, eliminating metallic robotic drops
    // - useinbandfec=1 enables Forward Error Correction to heal dropped packets without artifacts
    // - ptime=20 guarantees ultra-low 20ms audio latency frames
    // - maxaveragebitrate=48000 gives full studio-quality voice while preventing mesh buffer bloat
    // - maxplaybackrate=48000 & sprop-maxcapturerate=48000 for crystal-clear fullband recitation
    // - usedtx=0 ensures smooth voice without chopping soft letters or whispers
    final opusParams = [
      'minptime=20',
      'ptime=20',
      'maxptime=20',
      'useinbandfec=1',
      'usedtx=0',
      'stereo=0',
      'sprop-stereo=0',
      'maxaveragebitrate=48000',
      'maxplaybackrate=48000',
      'sprop-maxcapturerate=48000',
      'cbr=0',
    ].join(';');

    final fmtpRegex = RegExp('a=fmtp:$pt .*');
    if (fmtpRegex.hasMatch(sdp)) {
      return sdp.replaceFirst(fmtpRegex, 'a=fmtp:$pt $opusParams');
    } else {
      return sdp.replaceFirst(
        match.group(0)!,
        '${match.group(0)!}\r\na=fmtp:$pt $opusParams',
      );
    }
  }

  void sendPacket(MaglisPacket packet, {bool throttle = false}) {
    if (_disposed) return;
    if (!throttle) {
      _dispatchRaw(packet.pack());
      return;
    }
    _queuedPacket = packet;
    if (_throttleTimer?.isActive ?? false) return;
    _throttleTimer = Timer(const Duration(milliseconds: 35), () {
      final p = _queuedPacket;
      _queuedPacket = null;
      if (p != null && !_disposed) {
        _dispatchRaw(p.pack());
      }
    });
  }

  void _dispatchRaw(String raw) {
    final msg = RTCDataChannelMessage(raw);
    bool anyChannelOpen = false;
    for (final dc in _channels.values) {
      if (dc.state == RTCDataChannelState.RTCDataChannelOpen) {
        try {
          dc.send(msg);
          anyChannelOpen = true;
        } catch (_) {}
      }
    }

    // High-frequency recitation updates strictly flow over direct WebRTC DataChannel
    // to guarantee < 20ms latency and 0% UI thread CPU overhead.
    if (raw.contains('"t":1')) {
      return;
    }

    // Resilience Fallback: Only relay floorClaim, floorRelease, and snapshot via Nostr.
    final bool isVital = raw.contains('"t":0') ||
        raw.contains('"t":2') ||
        raw.contains('"t":3');
    if (!anyChannelOpen || isVital) {
      _sendSignal('pkt', data: {'p': raw});
    }
  }

  Future<void> setMicMuted(bool muted) async {
    _isMicMuted = muted;
    if (!muted &&
        (_localStream == null || _localStream!.getAudioTracks().isEmpty)) {
      try {
        _localStream = await navigator.mediaDevices.getUserMedia({
          'audio': _buildAudioConstraints(),
          'video': false,
        });
        for (final pc in _peers.values) {
          _localStream?.getAudioTracks().forEach((track) {
            track.enabled = true;
            try {
              pc.addTrack(track, _localStream!);
            } catch (_) {}
          });
        }
      } catch (_) {}
    } else {
      _localStream?.getAudioTracks().forEach((t) => t.enabled = !muted);
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
    _iceQueues.remove(peerId);
    _remoteDescSet.remove(peerId);
    _peerStates.remove(peerId);
    _lastSeenPeerMs.remove(peerId);
    _makingOffer.remove(peerId);
    _roomParticipants.remove(peerId);
    _participantCountCtrl.add(_roomParticipants.length + 1);
    try {
      await _channels.remove(peerId)?.close();
    } catch (_) {}
    try {
      await _peers.remove(peerId)?.close();
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
    _livenessReaperTimer?.cancel();

    try {
      final leaveSig = MaglisSignal(
        type: 'leave',
        senderId: localPeerId,
        data: const {},
      );
      final cipher = await MaglisCrypto.encrypt(leaveSig.pack(), roomCode);
      final frame = MaglisCrypto.signNostrEvent(
        privHex: _privHex,
        tag: _blindedTag,
        content: cipher,
      );
      for (final ws in _sockets.values) {
        ws.sink.add(frame);
        await ws.sink.close();
      }
    } catch (_) {}
    _sockets.clear();

    for (final id in List<String>.from(_peers.keys)) {
      await _cleanupPeer(id);
    }

    _localStream?.getTracks().forEach((t) => t.stop());
    await _localStream?.dispose();
    await MaglisPlatform.setWakeLock(false);

    await _packetCtrl.close();
    await _statesCtrl.close();
    await _natFailCtrl.close();
    await _participantCountCtrl.close();
  }
}

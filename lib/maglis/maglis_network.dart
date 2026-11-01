import 'dart:async';
import 'dart:convert';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'maglis_core.dart';
import 'network/maglis_config_manager.dart';
import 'network/maglis_media_helper.dart';
import 'network/maglis_relay_fleet.dart';
import 'network/maglis_peer_session.dart';

export 'network/maglis_config_manager.dart';
export 'network/maglis_media_helper.dart';
export 'network/maglis_relay_fleet.dart';
export 'network/maglis_peer_session.dart';
export 'network/maglis_reconnection_scheduler.dart';
export 'network/maglis_room_discovery.dart';

/// MaglisNetworkEngine
///
/// High-level coordinator facade for Maglis decentralized serverless WebRTC.
/// Restructured into noscall-style modular architecture:
/// - [MaglisConfigManager]: Dynamic relay fleet & STUN/TURN management with multi-tier failover
/// - [MaglisMediaHelper]: HD Opus voice constraints, SDP munging, and ICE candidate filtering
/// - [MaglisRelayFleet]: Multi-relay Nostr signaling transport with cryptographic blinding & verification
/// - [MaglisPeerSession]: RTCPeerConnection lifecycle, dual SCTP DataChannels, and low-latency packet dispatch
class MaglisNetworkEngine {
  static const int maxRemotePeers = 3;

  static Future<void> syncRemoteConfig() => MaglisConfigManager.syncRemoteConfig();
  static Future<void> prewarmIce() => MaglisConfigManager.prewarmIce();
  static List<String> roomRelaysForCode(String code) => MaglisConfigManager.roomRelaysForCode(code);
  static String formatRelayUrl(String baseUrl, String room) => MaglisRelayFleet.formatRelayUrl(baseUrl, room);
  static String mungeOpusSdp(
    String sdp, {
    int maxAverageBitrate = 48000,
    bool enableDtx = false,
  }) =>
      MaglisMediaHelper.mungeOpusSdp(
        sdp,
        maxAverageBitrate: maxAverageBitrate,
        enableDtx: enableDtx,
      );

  static Future<MaglisJoinResult> verifyRoomJoinable(String roomCode) =>
      MaglisRelayFleet.verifyRoomJoinable(roomCode);

  static Future<bool> isRoomCodeInUse(String roomCode) =>
      MaglisRelayFleet.isRoomCodeInUse(roomCode);

  static Future<void> reserveRoomCode(String roomCode, String tempId) =>
      MaglisRelayFleet.reserveRoomCode(roomCode, tempId);

  final String roomCode;
  final String localPeerId;
  bool _isHost;
  bool get isHost => _isHost;
  final MaglisPacket Function() onBuildSnapshot;

  late final MaglisRelayFleet _relayFleet;
  late final MaglisPeerSession _peerSession;

  final _packetCtrl = StreamController<MaglisPacket>.broadcast();
  final _statesCtrl = StreamController<Map<String, RTCIceConnectionState>>.broadcast();
  final _natFailCtrl = StreamController<String>.broadcast();
  final _participantCountCtrl = StreamController<int>.broadcast();

  final Set<String> _roomParticipants = <String>{};
  final Set<String> _admittedPeers = <String>{};

  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;
  List<ConnectivityResult> _lastConnectivity = const [];
  Timer? _networkChangeDebounceTimer;
  Timer? _beaconTimer;
  Timer? _pingTimer;
  Timer? _watchdogTimer;
  Timer? _epochRefreshTimer;
  bool _disposed = false;

  MaglisNetworkEngine({
    required String roomCode,
    required this.localPeerId,
    bool isHost = true,
    required this.onBuildSnapshot,
  })  : roomCode = normalizeArabicDigits(roomCode.trim()),
        _isHost = isHost {
    _relayFleet = MaglisRelayFleet(
      roomCode: this.roomCode,
      localPeerId: localPeerId,
      isHost: () => _isHost,
      onSignalReceived: _onSignalReceived,
    );

    _peerSession = MaglisPeerSession(
      roomCode: this.roomCode,
      localPeerId: localPeerId,
      sendSignal: (type, {targetId, required data}) =>
          _relayFleet.sendSignal(type, targetId: targetId, data: data),
      onBuildSnapshot: onBuildSnapshot,
      onNatFailure: (peerId) => _natFailCtrl.add(peerId),
      onStatesChanged: (states) => _statesCtrl.add(states),
      onPacketReceived: (packet) => _packetCtrl.add(packet),
      onPeerClosed: (peerId) {
        _roomParticipants.remove(peerId);
        _admittedPeers.remove(peerId);
        _participantCountCtrl.add(participantCount);
        _checkHostMigration();
      },
      onPeerListDiscovered: (discoveredPeers) {
        for (final p in discoveredPeers) {
          final id = p.toString();
          if (id.isNotEmpty &&
              id != localPeerId &&
              !_peerSession.peers.containsKey(id) &&
              !_peerSession.negotiatingPeers.contains(id)) {
            if (_roomParticipants.length < maxRemotePeers) {
              _admittedPeers.add(id);
              if (_roomParticipants.add(id)) {
                _participantCountCtrl.add(participantCount);
              }
              final isInitiator = localPeerId.compareTo(id) < 0;
              if (isInitiator) {
                unawaited(_peerSession.initiatePeerConnection(id));
              } else {
                unawaited(_relayFleet.sendSignal('beacon', targetId: id, data: const {}));
              }
            }
          }
        }
      },
      checkSocketSleepState: () => _relayFleet.checkSocketSleepState(),
    );
  }

  Stream<MaglisPacket> get onPacket => _packetCtrl.stream;
  Stream<Map<String, RTCIceConnectionState>> get onPeerStates => _statesCtrl.stream;
  Stream<String> get onNatFailure => _natFailCtrl.stream;
  Stream<int> get onParticipantCount => _participantCountCtrl.stream;
  int get participantCount => _roomParticipants.length + 1; // self + remote
  bool get isMicMuted => _peerSession.isMicMuted;
  int getPeerLatency(String peerId) => _peerSession.getPeerLatency(peerId);
  Map<String, MaglisPeerDiagnostics> get peerDiagnostics => _peerSession.peerDiagnostics;
  void updateActiveFloor(String? activeReciterId) => _peerSession.updateActiveFloor(activeReciterId);

  int get _activeRemoteParticipantCount {
    final now = DateTime.now().millisecondsSinceEpoch;
    return _roomParticipants.where((p) {
      final state = _peerSession.peerStates[p];
      final isAlive =
          state == RTCIceConnectionState.RTCIceConnectionStateConnected ||
              state == RTCIceConnectionState.RTCIceConnectionStateCompleted ||
              state == RTCIceConnectionState.RTCIceConnectionStateChecking ||
              state == RTCIceConnectionState.RTCIceConnectionStateNew ||
              _peerSession.negotiatingPeers.contains(p);
      final lastSeen = _peerSession.lastSeenPeerMs[p] ?? 0;
      return isAlive || (now - lastSeen) < 22000;
    }).length;
  }

  Future<void> start({String? inputDeviceId}) async {
    unawaited(MaglisConfigManager.syncRemoteConfig());
    await MaglisPlatform.initAudio();
    await MaglisPlatform.setWakeLock(true);

    try {
      _peerSession.localStream = await navigator.mediaDevices.getUserMedia(
        MaglisMediaHelper.buildAudioConstraints(inputDeviceId: inputDeviceId),
      );
    } catch (_) {
      try {
        _peerSession.localStream = await navigator.mediaDevices.getUserMedia({
          'audio': true,
          'video': false,
        });
      } catch (_) {}
    }

    // Unmute mic audio track so all room members hear each other continuously in conference call
    _peerSession.localStream?.getAudioTracks().forEach((track) {
      track.enabled = true;
      if (!kIsWeb && (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS)) {
        try {
          Helper.setMicrophoneMute(false, track);
        } catch (_) {}
      }
    });
    _peerSession.isMicMuted = false;
    MaglisPlatform.setSpeaker(true);

    MaglisPlatform.onAudioInterrupted = (interrupted) {
      if (_disposed) return;
      if (interrupted) {
        _peerSession.localStream?.getAudioTracks().forEach((track) {
          track.enabled = false;
        });
      } else {
        _peerSession.localStream?.getAudioTracks().forEach((track) {
          track.enabled = !_peerSession.isMicMuted;
        });
        MaglisPlatform.setSpeaker(true);
      }
    };

    if (!kIsWeb) {
      _connectivitySub?.cancel();
      _connectivitySub = Connectivity().onConnectivityChanged.listen((results) {
        if (_disposed) return;
        final hasConnection =
            results.isNotEmpty && !results.contains(ConnectivityResult.none);
        _relayFleet.updateConnectivity(hasConnection);
        final changed = !listEquals(_lastConnectivity, results);
        _lastConnectivity = List.from(results);
        if (changed && hasConnection) {
          _onNetworkInterfaceChanged();
        }
      });
    }

    // Connect to the multi-relay quorum (Primary + fallbacks concurrently)
    await _relayFleet.connectRelayFleet();
    _relayFleet.startHeartbeat();

    // Broadcast initial room discovery beacon
    await _relayFleet.sendSignal('beacon', data: const {});

    // Re-announce beacon every 12s ONLY when waiting for initial peer; completely idle once connected
    _beaconTimer = Timer.periodic(const Duration(seconds: 12), (_) {
      if (!_disposed && _peerSession.peers.isEmpty && _peerSession.negotiatingPeers.isEmpty) {
        _relayFleet.sendSignal('beacon', data: const {});
      }
    });

    // Zero-overhead 6s keep-alive ping strictly over direct WebRTC DataChannels (zero Nostr traffic)
    _pingTimer = Timer.periodic(const Duration(seconds: 6), (_) {
      if (_disposed) return;
      _peerSession.dispatchRaw(jsonEncode({
        't': 4,
        'u': localPeerId,
        'm': DateTime.now().millisecondsSinceEpoch,
      }));
    });

    // 5s Watchdog Timer: keeps relay fleet connected, recovers dropped DataChannels, heals mesh links, and prunes abandoned ghost peers
    _watchdogTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (_disposed) return;
      if (_relayFleet.sockets.length < MaglisRelayFleet.targetRelayCount) {
        _relayFleet.connectRelayFleet();
      } else {
        final now = DateTime.now();
        if (now.difference(_relayFleet.lastRelayFrameTime).inSeconds > 35) {
          debugPrint('[MaglisNetwork] Zombie relay socket detected (no traffic for 35s), recycling...');
          _relayFleet.lastRelayFrameTime = now;
          for (final ws in _relayFleet.sockets.values) {
            try {
              ws.sink.close();
            } catch (_) {}
          }
          _relayFleet.sockets.clear();
          _relayFleet.connectRelayFleet();
          return;
        }
      }

      // DataChannel health check on active WebRTC audio peers
      for (final entry in _peerSession.peers.entries) {
        final peerId = entry.key;
        final state = _peerSession.peerStates[peerId];
        final isConnected =
            state == RTCIceConnectionState.RTCIceConnectionStateConnected ||
                state == RTCIceConnectionState.RTCIceConnectionStateCompleted;
        if (isConnected) {
          final dc = _peerSession.channels[peerId];
          if (dc == null || dc.state == RTCDataChannelState.RTCDataChannelClosed) {
            _peerSession.recoverDataChannel(peerId);
          }
        }
      }

      // Periodic Mesh Self-Healing Audit
      for (final p in _roomParticipants.toList()) {
        if (!_peerSession.peers.containsKey(p) && !_peerSession.negotiatingPeers.contains(p)) {
          final isInitiator = localPeerId.compareTo(p) < 0;
          if (isInitiator) {
            unawaited(_peerSession.initiatePeerConnection(p));
          } else {
            unawaited(_relayFleet.sendSignal('beacon', targetId: p, data: const {}));
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
        _relayFleet.resubscribeRelays();
      }
    });
  }

  Future<void> _onSignalReceived(MaglisSignal sig) async {
    final remoteId = sig.senderId;

    final bool isProbe = sig.type == 'presence_probe' ||
        sig.type == 'presence_pong' ||
        sig.type == 'reserve_code' ||
        sig.type == 'join_probe';

    // Host capacity shield: Max 3 remote peers (4 total participants)
    if (_isHost && !isProbe) {
      _pruneStalePeers();
      if (!_admittedPeers.contains(remoteId) &&
          _activeRemoteParticipantCount >= maxRemotePeers) {
        return; // Drop signals exceeding room capacity
      }
      _admittedPeers.add(remoteId);
    }

    _peerSession.lastSeenPeerMs[remoteId] = DateTime.now().millisecondsSinceEpoch;
    if (!isProbe && !_roomParticipants.contains(remoteId)) {
      _roomParticipants.add(remoteId);
      _participantCountCtrl.add(participantCount);
    }

    // Deterministic Host Arbitration:
    if (_isHost && sig.data['host'] == true && remoteId != localPeerId) {
      if (localPeerId.compareTo(remoteId) > 0) {
        _isHost = false;
      }
    }

    switch (sig.type) {
      case 'join_probe':
        _pruneStalePeers();
        if (_isHost) {
          if (_activeRemoteParticipantCount >= maxRemotePeers &&
              !_admittedPeers.contains(remoteId) &&
              !_roomParticipants.contains(remoteId)) {
            await _relayFleet.sendSignal('join_reject',
                targetId: remoteId, data: {'reason': 'full'});
          } else {
            await _relayFleet.sendSignal('join_ack',
                targetId: remoteId,
                data: {'count': _activeRemoteParticipantCount + 1});
          }
        } else if (_peerSession.peers.isNotEmpty) {
          await _relayFleet.sendSignal('join_ack',
              targetId: remoteId,
              data: {'count': _activeRemoteParticipantCount + 1});
        }
        break;

      case 'presence_probe':
        await _relayFleet.sendSignal('presence_pong',
            targetId: remoteId, data: {'active': true});
        break;

      case 'reconnect_request':
        final isInitiator = localPeerId.compareTo(remoteId) < 0;
        if (isInitiator && !_peerSession.negotiatingPeers.contains(remoteId)) {
          final pc = _peerSession.peers[remoteId];
          if (pc != null) {
            final dc = _peerSession.channels[remoteId];
            if (sig.data['reason'] == 'dc_recovery' ||
                dc == null ||
                dc.state != RTCDataChannelState.RTCDataChannelOpen) {
              unawaited(_peerSession.recoverDataChannel(remoteId));
            } else {
              unawaited(_peerSession.triggerIceRestart(remoteId));
            }
          } else {
            unawaited(_relayFleet.sendSignal('beacon', targetId: remoteId, data: const {}));
          }
        }
        break;

      case 'floor_claim':
        final nextSeq = (_peerSession.lastSeq[remoteId] ?? 0) + 1;
        _peerSession.lastSeq[remoteId] = nextSeq;
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
        _peerSession.handleIncomingPacketString(pkt.pack());
        break;

      case 'beacon':
        final existingPc = _peerSession.peers[remoteId];
        final existingState = _peerSession.peerStates[remoteId];
        if (existingPc != null &&
            (existingState == null ||
                existingState ==
                    RTCIceConnectionState.RTCIceConnectionStateConnected ||
                existingState ==
                    RTCIceConnectionState.RTCIceConnectionStateCompleted ||
                existingState ==
                    RTCIceConnectionState.RTCIceConnectionStateChecking ||
                existingState ==
                    RTCIceConnectionState.RTCIceConnectionStateNew)) {
          return;
        }
        if (_peerSession.negotiatingPeers.contains(remoteId)) {
          return;
        }
        if (!_peerSession.peers.containsKey(remoteId) &&
            _peerSession.peers.length >= maxRemotePeers) {
          return;
        }

        final isInitiator = localPeerId.compareTo(remoteId) < 0;
        if (isInitiator) {
          await _peerSession.initiatePeerConnection(remoteId);
        } else {
          if (!_peerSession.peers.containsKey(remoteId)) {
            await _relayFleet.sendSignal('beacon', targetId: remoteId, data: const {});
          }
        }
        break;

      case 'offer':
        final sdp = sig.data['sdp'] as String?;
        if (sdp != null) {
          await _peerSession.handleOffer(
            remoteId,
            sdp,
            isIceRestart: sig.data['iceRestart'] == true,
            isDataChannelRecovery: sig.data['dcRecovery'] == true,
          );
        }
        break;

      case 'answer':
        final sdp = sig.data['sdp'] as String?;
        if (sdp != null) {
          await _peerSession.handleAnswer(remoteId, sdp);
        }
        break;

      case 'ice_batch':
        final candidates = sig.data['candidates'] as List<dynamic>?;
        if (candidates != null) {
          await _peerSession.handleIceBatch(remoteId, candidates);
        }
        break;

      case 'leave':
        _roomParticipants.remove(remoteId);
        _admittedPeers.remove(remoteId);
        _participantCountCtrl.add(participantCount);
        _checkHostMigration();
        await _peerSession.cleanupPeer(remoteId);
        _relayFleet.checkSocketSleepState();
        break;
    }
  }

  void _checkHostMigration() {
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
  }

  void _onNetworkInterfaceChanged() {
    if (_disposed) return;
    _networkChangeDebounceTimer?.cancel();
    _networkChangeDebounceTimer =
        Timer(const Duration(milliseconds: 650), () async {
      if (_disposed) return;
      for (final ws in _relayFleet.sockets.values) {
        try {
          ws.sink.close();
        } catch (_) {}
      }
      _relayFleet.sockets.clear();
      _relayFleet.reconnectingRelays.clear();
      _relayFleet.resetReconnectionScheduler();
      await _relayFleet.connectRelayFleet();

      for (final remoteId in _peerSession.peers.keys) {
        final isInitiator = localPeerId.compareTo(remoteId) < 0;
        if (isInitiator) {
          unawaited(_peerSession.triggerIceRestart(remoteId));
        } else {
          unawaited(_relayFleet.sendSignal('reconnect_request',
              targetId: remoteId, data: const {}));
        }
      }
    });
  }

  void _pruneStalePeers() {
    if (_disposed) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final stalePeers = <String>[];
    for (final peerId in _roomParticipants) {
      final lastSeen = _peerSession.lastSeenPeerMs[peerId] ?? 0;
      final state = _peerSession.peerStates[peerId];
      final isConnected =
          state == RTCIceConnectionState.RTCIceConnectionStateConnected ||
              state == RTCIceConnectionState.RTCIceConnectionStateCompleted;
      final isConnecting =
          state == RTCIceConnectionState.RTCIceConnectionStateChecking ||
              state == RTCIceConnectionState.RTCIceConnectionStateNew ||
              _peerSession.negotiatingPeers.contains(peerId);
      final isExplicitlyDead =
          state == RTCIceConnectionState.RTCIceConnectionStateClosed;

      // 1. If actively connected, keep alive! Peer is in the audio conference.
      // If silent on DataChannel for > 25s, recover DataChannel without dropping peer
      if (isConnected) {
        if ((now - lastSeen) > 25000) {
          _peerSession.recoverDataChannel(peerId);
        }
        continue;
      }

      // 2. Allow up to 30s for WebRTC handshake & ICE checks to complete on mobile networks / TURN relays
      if (isConnecting) {
        if ((now - lastSeen) > 30000) {
          stalePeers.add(peerId);
        }
        continue;
      }

      // 3. If explicitly closed or silent without connection for > 35s, prune ghost peer
      if (isExplicitlyDead || (now - lastSeen) > 35000) {
        stalePeers.add(peerId);
      }
    }

    for (final p in stalePeers) {
      _roomParticipants.remove(p);
      _admittedPeers.remove(p);
      _peerSession.lastSeenPeerMs.remove(p);
      unawaited(_peerSession.cleanupPeer(p));
    }
    if (stalePeers.isNotEmpty) {
      _participantCountCtrl.add(participantCount);
      _checkHostMigration();
      _relayFleet.checkSocketSleepState();
    }
  }

  void sendPacket(MaglisPacket packet, {bool throttle = false}) {
    _peerSession.sendPacket(packet, throttle: throttle);
  }

  Future<void> sendSignalFast(
    String type, {
    String? targetId,
    required Map<String, dynamic> data,
  }) async {
    await _relayFleet.sendSignal(type, targetId: targetId, data: data);
  }

  Future<void> setMicMuted(bool muted) async {
    await _peerSession.setMicMuted(muted);
  }

  Future<void> retryConnections() async {
    await _relayFleet.connectRelayFleet();
    await _peerSession.retryConnections();
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;

    _beaconTimer?.cancel();
    _pingTimer?.cancel();
    _watchdogTimer?.cancel();
    _epochRefreshTimer?.cancel();
    _networkChangeDebounceTimer?.cancel();
    await _connectivitySub?.cancel();

    MaglisPlatform.onAudioInterrupted = null;

    try {
      _peerSession.dispatchRaw(jsonEncode({'t': 99, 'u': localPeerId, 'type': 'leave'}));
      await _relayFleet.sendSignal('leave', data: const {});
      // Brief flush delay so TCP buffer transmits leave frame before socket teardown
      await Future.delayed(const Duration(milliseconds: 80));
    } catch (_) {}

    await _peerSession.dispose();
    _relayFleet.dispose();

    await _packetCtrl.close();
    await _statesCtrl.close();
    await _natFailCtrl.close();
    await _participantCountCtrl.close();

    await MaglisPlatform.setWakeLock(false);
  }
}

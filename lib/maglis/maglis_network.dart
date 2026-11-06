import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'maglis_core.dart';
import 'network/maglis_config_manager.dart';
import 'network/maglis_media_helper.dart';
import 'network/maglis_relay_fleet.dart';
import 'network/maglis_peer_session.dart';
import 'network/maglis_participant.dart';

export 'network/maglis_config_manager.dart';
export 'network/maglis_media_helper.dart';
export 'network/maglis_relay_fleet.dart';
export 'network/maglis_peer_session.dart';
export 'network/maglis_reconnection_scheduler.dart';
export 'network/maglis_room_discovery.dart';
export 'network/maglis_participant.dart';
export 'network/maglis_session.dart';

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

  static Future<void> syncRemoteConfig() =>
      MaglisConfigManager.syncRemoteConfig();
  static List<String> roomRelaysForCode(String code) =>
      MaglisConfigManager.roomRelaysForCode(code);
  static String formatRelayUrl(String baseUrl, String room) =>
      MaglisRelayFleet.formatRelayUrl(baseUrl, room);
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

  final String roomCode;
  final String localPeerId;
  bool _isHost;
  bool get isHost => _isHost;
  final MaglisPacket Function() onBuildSnapshot;
  final void Function(String peerId)? onParticipantJoined;
  final void Function(String peerId)? onParticipantLeft;

  late final MaglisRelayFleet _relayFleet;
  late final MaglisPeerSession _peerSession;

  @visibleForTesting
  MaglisRelayFleet get relayFleet => _relayFleet;

  @visibleForTesting
  MaglisPeerSession get peerSession => _peerSession;

  final _packetCtrl = StreamController<MaglisPacket>.broadcast();
  final _statesCtrl =
      StreamController<Map<String, RTCIceConnectionState>>.broadcast();
  final _natFailCtrl = StreamController<String>.broadcast();
  final _participantCountCtrl = StreamController<int>.broadcast();

  final ParticipantCollection remoteParticipants = ParticipantCollection();
  final Set<String> _admittedPeers = <String>{};
  final Set<String> _departedPeers = <String>{};

  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;
  List<ConnectivityResult> _lastConnectivity = const [];
  Timer? _networkChangeDebounceTimer;
  Timer? _beaconTimer;
  Timer? _watchdogTimer;
  Timer? _epochRefreshTimer;
  int _lastKnownHostHeartbeatMs = 0;
  String? _knownHostPeerId;
  bool _disposed = false;

  MaglisNetworkEngine({
    required String roomCode,
    required this.localPeerId,
    bool isHost = true,
    required this.onBuildSnapshot,
    this.onParticipantJoined,
    this.onParticipantLeft,
  })  : roomCode = normalizeArabicDigits(roomCode.trim()),
        _isHost = isHost,
        _knownHostPeerId = isHost ? localPeerId : null {
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
      onStatesChanged: (states) {
        for (final entry in List<MapEntry<String, RTCIceConnectionState>>.from(
            states.entries)) {
          if (!_departedPeers.contains(entry.key)) {
            _addOrUpdateParticipant(entry.key, iceState: entry.value);
          }
        }
        _statesCtrl.add(states);
      },
      onPacketReceived: (packet) {
        if (packet.senderId.isNotEmpty &&
            packet.senderId != localPeerId &&
            !_departedPeers.contains(packet.senderId)) {
          if (packet.senderId == _knownHostPeerId) {
            _lastKnownHostHeartbeatMs = DateTime.now().millisecondsSinceEpoch;
          }
          _addOrUpdateParticipant(packet.senderId, dataChannelOpen: true);
        }
        _packetCtrl.add(packet);
      },
      onPeerClosed: (peerId) {
        _removeParticipant(peerId);
      },
      onPeerListDiscovered: (discoveredPeers) {
        for (final p in discoveredPeers) {
          final id = p.toString();
          if (id.isNotEmpty &&
              id != localPeerId &&
              !_departedPeers.contains(id) &&
              !_peerSession.peers.containsKey(id) &&
              !_peerSession.negotiatingPeers.contains(id)) {
            if (remoteParticipants.length < maxRemotePeers) {
              _admittedPeers.add(id);
              _addOrUpdateParticipant(id);
              final isInitiator = localPeerId.compareTo(id) < 0;
              if (isInitiator) {
                unawaited(_peerSession.initiatePeerConnection(id));
              } else {
                unawaited(_relayFleet.sendSignal('beacon',
                    targetId: id, data: const {}));
              }
            }
          }
        }
      },
      checkSocketSleepState: () => _relayFleet.checkSocketSleepState(),
    );
  }

  void _addOrUpdateParticipant(
    String peerId, {
    RTCIceConnectionState? iceState,
    bool? dataChannelOpen,
  }) {
    if (peerId.isEmpty ||
        peerId == localPeerId ||
        _departedPeers.contains(peerId)) return;
    if (_disposed) return;
    if (iceState == RTCIceConnectionState.RTCIceConnectionStateClosed) {
      _removeParticipant(peerId);
      return;
    }

    var p = remoteParticipants.get(peerId);
    final bool isNew = p == null;
    if (isNew) {
      if (remoteParticipants.length >= maxRemotePeers) return;
      p = MaglisRemoteParticipant(
        identity: peerId,
        iceState: iceState ?? RTCIceConnectionState.RTCIceConnectionStateNew,
        isDataChannelOpen: dataChannelOpen ?? false,
      );
      remoteParticipants.set(p);
      _admittedPeers.add(peerId);
      _participantCountCtrl.add(participantCount);
      onParticipantJoined?.call(peerId);
    } else {
      if (iceState != null) p.iceState = iceState;
      if (dataChannelOpen != null) p.isDataChannelOpen = dataChannelOpen;
      p.lastSeenMs = DateTime.now().millisecondsSinceEpoch;
    }
  }

  void _removeParticipant(String peerId) {
    _admittedPeers.remove(peerId);
    if (_knownHostPeerId == peerId) {
      _knownHostPeerId = null;
      _lastKnownHostHeartbeatMs = 0;
    }
    if (remoteParticipants.removeByIdentity(peerId) != null) {
      _participantCountCtrl.add(participantCount);
      onParticipantLeft?.call(peerId);
      _checkHostMigration();
    } else {
      _checkHostMigration();
    }
  }

  Stream<MaglisPacket> get onPacket => _packetCtrl.stream;
  Stream<Map<String, RTCIceConnectionState>> get onPeerStates =>
      _statesCtrl.stream;
  Stream<String> get onNatFailure => _natFailCtrl.stream;
  Stream<int> get onParticipantCount => _participantCountCtrl.stream;
  int get participantCount =>
      _disposed ? 1 : (remoteParticipants.length + 1); // self + remote
  bool get isMicMuted => _peerSession.isMicMuted;
  int getPeerLatency(String peerId) => _peerSession.getPeerLatency(peerId);
  Map<String, MaglisPeerDiagnostics> get peerDiagnostics =>
      _peerSession.peerDiagnostics;
  void updateActiveFloor(String? activeReciterId) =>
      _peerSession.updateActiveFloor(activeReciterId);

  int get _activeRemoteParticipantCount {
    final now = DateTime.now().millisecondsSinceEpoch;
    return remoteParticipants.where((p) {
      if (_departedPeers.contains(p.identity)) return false;
      final state = _peerSession.peerStates[p.identity];
      final isAlive =
          state == RTCIceConnectionState.RTCIceConnectionStateConnected ||
              state == RTCIceConnectionState.RTCIceConnectionStateCompleted ||
              state == RTCIceConnectionState.RTCIceConnectionStateChecking ||
              state == RTCIceConnectionState.RTCIceConnectionStateNew ||
              _peerSession.negotiatingPeers.contains(p.identity);
      final lastSeen = _peerSession.lastSeenPeerMs[p.identity] ?? p.lastSeenMs;
      return isAlive || (now - lastSeen) < 22000;
    }).length;
  }

  Future<void> start({String? inputDeviceId}) async {
    // 1. Rigorous pre-flight connectivity check (livekit / noscall pattern)
    if (!kIsWeb) {
      final connectivity = await Connectivity().checkConnectivity();
      final hasConnection = connectivity.isNotEmpty &&
          !connectivity.contains(ConnectivityResult.none);
      if (!hasConnection) {
        throw const SocketException('No active internet connection');
      }
    }

    unawaited(MaglisConfigManager.syncRemoteConfig());
    await MaglisPlatform.initAudio();

    final hasAudioInput =
        await MaglisMediaHelper.preflightDesktopMediaDevices();
    if (hasAudioInput) {
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
    }

    // Unmute mic audio track so all room members hear each other continuously in conference call
    _peerSession.localStream?.getAudioTracks().forEach((track) {
      track.enabled = true;
      if (!kIsWeb &&
          (defaultTargetPlatform == TargetPlatform.android ||
              defaultTargetPlatform == TargetPlatform.iOS)) {
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
      _connectivitySub =
          Connectivity().onConnectivityChanged.listen((results) {
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

    // Connect to the multi-relay quorum and verify at least one relay is alive!
    final ok = await _relayFleet.connectRelayFleet();
    if (!ok || _relayFleet.sockets.isEmpty) {
      throw const SocketException(
          'Failed to connect to any Maglis signaling relay');
    }
    _relayFleet.startHeartbeat();

    // Broadcast initial room discovery beacon
    await _relayFleet.sendSignal('beacon', data: const {});

    // Re-announce beacon every 12s ONLY when waiting for initial peer; completely idle once connected
    _beaconTimer = Timer.periodic(const Duration(seconds: 12), (_) {
      if (!_disposed &&
          _peerSession.peers.isEmpty &&
          _peerSession.negotiatingPeers.isEmpty) {
        _relayFleet.sendSignal('beacon', data: const {});
      }
    });

    // Note: Keep-alive pings over WebRTC DataChannels are handled directly by
    // MaglisPeerSession._heartbeatTimer (every 4s), avoiding duplicate timer traffic.

    // 5s Watchdog Timer: keeps relay fleet connected, recovers dropped DataChannels, heals mesh links, and prunes abandoned ghost peers
    _watchdogTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (_disposed) return;
      if (_relayFleet.sockets.length < MaglisRelayFleet.targetRelayCount) {
        _relayFleet.connectRelayFleet();
      } else {
        final now = DateTime.now();
        if (now.difference(_relayFleet.lastRelayFrameTime).inSeconds > 35) {
          debugPrint(
              '[MaglisNetwork] Relay silence for 35s, resubscribing fleet and checking connections...');
          _relayFleet.lastRelayFrameTime = now;
          _relayFleet.resubscribeRelays();
          if (_relayFleet.sockets.length < MaglisRelayFleet.targetRelayCount) {
            _relayFleet.connectRelayFleet();
          }
        }
      }

      // DataChannel health check on active WebRTC audio peers
      for (final entry in List<MapEntry<String, RTCPeerConnection>>.from(
          _peerSession.peers.entries)) {
        final peerId = entry.key;
        final state = _peerSession.peerStates[peerId];
        final isConnected =
            state == RTCIceConnectionState.RTCIceConnectionStateConnected ||
                state == RTCIceConnectionState.RTCIceConnectionStateCompleted;
        if (isConnected) {
          final dc = _peerSession.channels[peerId];
          if (dc == null ||
              dc.state == RTCDataChannelState.RTCDataChannelClosed) {
            _peerSession.recoverDataChannel(peerId);
          }
        }
      }

      // Periodic Mesh Self-Healing Audit
      for (final p in remoteParticipants.identities) {
        if (!_departedPeers.contains(p) &&
            !_peerSession.peers.containsKey(p) &&
            !_peerSession.negotiatingPeers.contains(p)) {
          final isInitiator = localPeerId.compareTo(p) < 0;
          if (isInitiator) {
            unawaited(_peerSession.initiatePeerConnection(p));
          } else {
            unawaited(
                _relayFleet.sendSignal('beacon', targetId: p, data: const {}));
          }
        }
      }
      _pruneStalePeers();
      _checkHostMigration();
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
    if (remoteId.isEmpty || remoteId == localPeerId) return;

    // 1. Handle explicit 'leave' FIRST before any participant addition or host heartbeat update!
    // Otherwise a 'leave' signal over Nostr re-adds a peer that already left via DataChannel,
    // and sets _lastKnownHostHeartbeatMs = now which blocks _checkHostMigration()!
    if (sig.type == 'leave') {
      _departedPeers.add(remoteId);
      _peerSession.departedPeers.add(remoteId);
      _peerSession.peerStates.remove(remoteId);
      _removeParticipant(remoteId);
      await _peerSession.cleanupPeer(remoteId);
      _relayFleet.checkSocketSleepState();
      return;
    }

    // 2. Ignore any late in-flight Nostr signals from a peer session that already departed
    if (_departedPeers.contains(remoteId)) {
      return;
    }

    final bool isProbe = sig.type == 'presence_probe' ||
        sig.type == 'presence_pong' ||
        sig.type == 'reserve_code' ||
        sig.type == 'join_probe';

    // Host capacity shield: Max 3 remote peers (4 total participants)
    if (_isHost && !isProbe) {
      _pruneStalePeers();
      if (!_admittedPeers.contains(remoteId) &&
          (remoteParticipants.length >= maxRemotePeers ||
              _activeRemoteParticipantCount >= maxRemotePeers)) {
        return; // Drop signals exceeding room capacity
      }
      _admittedPeers.add(remoteId);
    }

    _peerSession.lastSeenPeerMs[remoteId] =
        DateTime.now().millisecondsSinceEpoch;
    if (!isProbe) {
      _addOrUpdateParticipant(remoteId);
    }

    // Deterministic Host Arbitration & Lease Tracking:
    if (sig.data['host'] == true && remoteId != localPeerId) {
      _lastKnownHostHeartbeatMs = DateTime.now().millisecondsSinceEpoch;
      if (!_isHost) {
        _knownHostPeerId = remoteId;
      } else if (localPeerId.compareTo(remoteId) > 0) {
        _isHost = false;
        _knownHostPeerId = remoteId;
      }
    }

    switch (sig.type) {
      case 'join_probe':
        _pruneStalePeers();
        _checkHostMigration();
        if (_isHost) {
          if ((remoteParticipants.length >= maxRemotePeers ||
                  _activeRemoteParticipantCount >= maxRemotePeers) &&
              !_admittedPeers.contains(remoteId) &&
              !remoteParticipants.containsIdentity(remoteId)) {
            await _relayFleet.sendSignal('join_reject',
                targetId: remoteId, data: {'reason': 'full'});
          } else {
            await _relayFleet.sendSignal('join_ack',
                targetId: remoteId,
                data: {'count': _activeRemoteParticipantCount + 1});
          }
        } else {
          // Any active participant in the room can acknowledge a join_probe so
          // a room remains joinable even while host migration is in progress.
          final activeCount = _activeRemoteParticipantCount + 1;
          if (activeCount >= 4 &&
              !_admittedPeers.contains(remoteId) &&
              !remoteParticipants.containsIdentity(remoteId)) {
            await _relayFleet.sendSignal('join_reject',
                targetId: remoteId, data: {'reason': 'full'});
          } else {
            await _relayFleet.sendSignal('join_ack',
                targetId: remoteId, data: {'count': activeCount});
          }
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
            final iceState = _peerSession.peerStates[remoteId];
            final isIceHealthy = iceState ==
                    RTCIceConnectionState.RTCIceConnectionStateConnected ||
                iceState ==
                    RTCIceConnectionState.RTCIceConnectionStateCompleted;
            final dc = _peerSession.channels[remoteId];
            if (sig.data['reason'] == 'dc_recovery' &&
                sig.data['iceRestart'] != true &&
                isIceHealthy &&
                (dc == null ||
                    dc.state != RTCDataChannelState.RTCDataChannelOpen)) {
              unawaited(_peerSession.recoverDataChannel(remoteId));
            } else {
              unawaited(_peerSession.triggerIceRestart(remoteId));
            }
          } else {
            unawaited(_peerSession.initiatePeerConnection(remoteId));
          }
        }
        break;

      case 'floor_claim':
        final claimSeq = (sig.data['seq'] as int?) ??
            ((_peerSession.lastSeq[remoteId] ?? 0) + 1);
        final pkt = MaglisPacket(
          type: MaglisPacketType.floorClaim,
          seq: claimSeq,
          senderId: remoteId,
          page: sig.data['page'] as int? ?? 1,
          surah: sig.data['surah'] as int? ?? 1,
          ayah: sig.data['ayah'] as int? ?? 1,
          activeReciterId: remoteId,
          ts: (sig.data['ts'] as int?) ?? DateTime.now().millisecondsSinceEpoch,
        );
        _peerSession.handleIncomingPacket(pkt);
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
          await _relayFleet.sendSignal('beacon',
              targetId: remoteId, data: const {});
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
    }
  }

  void _checkHostMigration() {
    if (!_isHost) {
      final now = DateTime.now().millisecondsSinceEpoch;
      // Do not usurp host if the known host is still an active participant in the room
      if (_knownHostPeerId != null &&
          !_departedPeers.contains(_knownHostPeerId) &&
          remoteParticipants.containsIdentity(_knownHostPeerId!)) {
        final hostLastSeen = _peerSession.lastSeenPeerMs[_knownHostPeerId!] ??
            remoteParticipants.get(_knownHostPeerId!)?.lastSeenMs ??
            0;
        if ((now - hostLastSeen) < 20000) {
          return;
        }
      }
      // Host lease grace period: do not usurp host if last host signal was within 6s
      if (_knownHostPeerId != null &&
          !_departedPeers.contains(_knownHostPeerId) &&
          _lastKnownHostHeartbeatMs > 0 &&
          (now - _lastKnownHostHeartbeatMs) < 6000 &&
          remoteParticipants.isNotEmpty) {
        return;
      }

      if (remoteParticipants.isEmpty) {
        _isHost = true;
        _knownHostPeerId = localPeerId;
      } else {
        final allPeers = [localPeerId, ...remoteParticipants.identities]
          ..sort();
        if (allPeers.first == localPeerId) {
          _isHost = true;
          _knownHostPeerId = localPeerId;
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
      for (final ws in List.from(_relayFleet.sockets.values)) {
        try {
          ws.sink.close();
        } catch (_) {}
      }
      _relayFleet.sockets.clear();
      _relayFleet.reconnectingRelays.clear();
      _relayFleet.resetReconnectionScheduler();
      await _relayFleet.connectRelayFleet();
      await _relayFleet.sendSignal('beacon', data: const {});

      for (final remoteId in List<String>.from(_peerSession.peers.keys)) {
        final isInitiator = localPeerId.compareTo(remoteId) < 0;
        if (isInitiator) {
          unawaited(_peerSession.triggerIceRestart(remoteId));
        } else {
          unawaited(_relayFleet.sendSignal('reconnect_request',
              targetId: remoteId, data: {'iceRestart': true}));
        }
      }
    });
  }

  void _pruneStalePeers() {
    if (_disposed) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final stalePeers = <String>[];
    for (final p in List<MaglisRemoteParticipant>.from(remoteParticipants)) {
      final peerId = p.identity;
      final lastSeen = _peerSession.lastSeenPeerMs[peerId] ?? p.lastSeenMs;
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
      final isFailedOrDisconnected =
          state == RTCIceConnectionState.RTCIceConnectionStateFailed ||
              state == RTCIceConnectionState.RTCIceConnectionStateDisconnected;

      // 1. If actively connected, keep alive! Peer is in the audio conference.
      // If silent on DataChannel for > 25s, recover DataChannel without dropping peer
      if (isConnected) {
        if ((now - lastSeen) > 25000) {
          _peerSession.recoverDataChannel(peerId);
        }
        continue;
      }

      // 2. Allow up to 25s for WebRTC handshake & ICE checks to complete on mobile networks / TURN relays
      if (isConnecting) {
        if ((now - lastSeen) > 25000) {
          stalePeers.add(peerId);
        }
        continue;
      }

      // 3. If disconnected or failed and silent for > 15s (recovery window elapsed), reap peer
      if (isFailedOrDisconnected && (now - lastSeen) > 15000) {
        stalePeers.add(peerId);
        continue;
      }

      // 4. If explicitly closed or silent without connection for > 20s, prune ghost peer
      if (isExplicitlyDead || (now - lastSeen) > 20000) {
        stalePeers.add(peerId);
      }
    }

    for (final p in stalePeers) {
      _peerSession.peerStates.remove(p);
      _removeParticipant(p);
      _peerSession.lastSeenPeerMs.remove(p);
      unawaited(_peerSession.cleanupPeer(p));
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
    _watchdogTimer?.cancel();
    _epochRefreshTimer?.cancel();
    _networkChangeDebounceTimer?.cancel();
    await _connectivitySub?.cancel();

    MaglisPlatform.onAudioInterrupted = null;

    try {
      _peerSession.dispatchRaw(
        jsonEncode({'t': 99, 'u': localPeerId, 'type': 'leave'}),
        isVital: false,
      );
      await _relayFleet.sendSignal('leave', data: const {});
      // Brief flush delay so TCP buffer transmits leave frame before socket teardown
      await Future.delayed(const Duration(milliseconds: 80));
    } catch (_) {}

    await _peerSession.dispose();
    _relayFleet.dispose();
    remoteParticipants.clear();
    _admittedPeers.clear();
    _departedPeers.clear();

    await _packetCtrl.close();
    await _statesCtrl.close();
    await _natFailCtrl.close();
    await _participantCountCtrl.close();
  }
}
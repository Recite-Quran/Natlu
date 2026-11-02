import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import '../maglis_core.dart';
import 'maglis_config_manager.dart';
import 'maglis_media_helper.dart';
import 'maglis_participant.dart';

/// MaglisPeerSession
///
/// Encapsulates WebRTC RTCPeerConnection and dual SCTP DataChannel handling (noscall pattern).
/// Manages peer connections, media tracks, audio playout, ICE trickle queues,
/// and fast binary recitation synchronization.
class MaglisPeerSession {
  final String roomCode;
  final String localPeerId;
  final Future<void> Function(String type,
      {String? targetId, required Map<String, dynamic> data}) sendSignal;
  final MaglisPacket Function() onBuildSnapshot;
  final void Function(String peerId) onNatFailure;
  final void Function(Map<String, RTCIceConnectionState> states)
      onStatesChanged;
  final void Function(MaglisPacket packet) onPacketReceived;
  final void Function(String peerId) onPeerClosed;
  final void Function(List<String> discoveredPeers) onPeerListDiscovered;
  final void Function() checkSocketSleepState;

  MaglisPeerSession({
    required this.roomCode,
    required this.localPeerId,
    required this.sendSignal,
    required this.onBuildSnapshot,
    required this.onNatFailure,
    required this.onStatesChanged,
    required this.onPacketReceived,
    required this.onPeerClosed,
    required this.onPeerListDiscovered,
    required this.checkSocketSleepState,
  }) {
    _startHeartbeatTimer();
  }

  MediaStream? localStream;
  bool isMicMuted = false;
  bool disposed = false;
  Timer? _heartbeatTimer;

  final Map<String, RTCPeerConnection> peers = {};
  final Map<String, RTCDataChannel> channels = {};
  final Map<String, List<RTCIceCandidate>> iceQueues = {};
  final Map<String, bool> remoteDescSet = {};
  final Map<String, int> lastSeq = {};
  final Map<String, int> lastSeenSurah = {};
  final Map<String, int> lastSeenAyah = {};
  final Map<String, int> _lastRelayedSeq = {};
  final Map<String, int> _lastRelayedClaimTs = {};
  final Map<String, RTCIceConnectionState> peerStates = {};
  final Map<String, int> lastSeenPeerMs = {};
  final Map<String, int> peerLatency = {};
  final Map<String, List<Map<String, dynamic>>> pendingOutboundCandidates = {};
  final Map<String, Set<String>> sentCandidateKeys = {};
  final Map<String, Timer> iceDebounceTimers = {};
  final Map<String, Timer> iceRestartGraceTimers = {};
  final Map<String, MaglisPeerRecoveryWindow> recoveryWindows = {};
  final Map<String, int> reconnectAttempts = {};
  final Map<String, bool> isRestartInProgress = {};
  final Map<String, bool> answerInFlight = {};
  final Set<String> negotiatingPeers = {};
  final Set<String> departedPeers = {};
  final Map<String, List<MediaStreamTrack>> remoteTracks = {};
  final Map<String, List<MediaStream>> remoteStreams = {};
  final Map<String, RTCVideoRenderer> _audioRenderers = {};
  final Set<String> peersNeedingCatchup = <String>{};
  final Set<String> renegotiatePending = <String>{};
  final PeerTaskQueue _taskQueue = PeerTaskQueue();
  final List<String> pendingVitalPackets = [];
  final Map<String, List<String>> _peerVitalQueues = {};

  static const int maxDataChannelBufferedAmount = 128 * 1024;
  static const int maxRemotePeers = 3;

  int getPeerLatency(String peerId) => peerLatency[peerId] ?? 0;

  Map<String, MaglisPeerDiagnostics> get peerDiagnostics {
    final map = <String, MaglisPeerDiagnostics>{};
    for (final peerId in List<String>.from(peers.keys)) {
      map[peerId] = MaglisPeerDiagnostics(
        peerId: peerId,
        rttMs: peerLatency[peerId] ?? 0,
        state: peerStates[peerId] ??
            RTCIceConnectionState.RTCIceConnectionStateNew,
        lastSeenMs: lastSeenPeerMs[peerId] ?? 0,
      );
    }
    return map;
  }

  /// Synchronizes audio track playout across all room participants.
  /// All 4 connected peers share conference audio continuously while only the active reciter
  /// broadcasts highlighting and Tajweed data.
  void updateActiveFloor(String? activeReciterId) {
    localStream?.getAudioTracks().forEach((t) {
      t.enabled = !isMicMuted;
      try {
        Helper.setMicrophoneMute(isMicMuted, t);
      } catch (_) {}
    });

    // Keep all remote audio tracks enabled at full volume so all peers share audio
    // without Android/iOS OpenSLES/AVAudioEngine playout stalls.
    for (final entry in List<MapEntry<String, List<MediaStreamTrack>>>.from(
        remoteTracks.entries)) {
      final tracks = entry.value;
      for (final t in List<MediaStreamTrack>.from(tracks)) {
        t.enabled = true;
        try {
          Helper.setVolume(1.0, t);
        } catch (_) {}
      }
    }

    MaglisPlatform.setSpeaker(true);
  }

  void _startHeartbeatTimer() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 4), (_) {
      if (disposed) return;
      final now = DateTime.now().millisecondsSinceEpoch;

      if (channels.isNotEmpty) {
        final pingJson = jsonEncode({
          't': 4,
          'u': localPeerId,
          'm': now,
        });
        dispatchReliable(pingJson, isVital: false);

        // Periodic full-mesh peer gossip: ensures 3- and 4-peer rooms always
        // converge to a complete mesh even if two peers joined at the exact same millisecond.
        final activePeerIds = peers.keys
            .where((p) => p != localPeerId && !departedPeers.contains(p))
            .toList();
        if (activePeerIds.length >= 2) {
          final gossipJson = jsonEncode({
            't': 98,
            'peers': activePeerIds,
          });
          dispatchReliable(gossipJson, isVital: false);
        }
      }

      // Ghost peer reaping (noscall pattern): reap dead peers after 25s without packets.
      // Preserve connected audio peers by recovering their DataChannel instead of dropping the call.
      final stalePeers = <String>[];
      for (final peerId in List<String>.from(peers.keys)) {
        if (recoveryWindows[peerId]?.active == true) continue;
        final lastSeen = lastSeenPeerMs[peerId];
        if (lastSeen != null && lastSeen > 0 && (now - lastSeen) > 25000) {
          final state = peerStates[peerId];
          final isConnected = state ==
                  RTCIceConnectionState.RTCIceConnectionStateConnected ||
              state == RTCIceConnectionState.RTCIceConnectionStateCompleted;
          if (isConnected) {
            unawaited(recoverDataChannel(peerId));
          } else {
            stalePeers.add(peerId);
          }
        }
      }

      for (final peerId in stalePeers) {
        peerStates.remove(peerId);
        onPeerClosed(peerId);
        unawaited(cleanupPeer(peerId));
      }
    });
  }

  Future<T> runPeerExclusive<T>(String peerId, Future<T> Function() block) {
    if (disposed) return Future.error(StateError('MaglisPeerSession disposed'));
    return _taskQueue.run(peerId, block);
  }

  void queueOutboundIce(String remoteId, Map<String, dynamic> candMap) {
    if (departedPeers.contains(remoteId)) return;
    final candStr = candMap['candidate'] as String?;
    if (candStr != null) {
      final sent = sentCandidateKeys.putIfAbsent(remoteId, () => <String>{});
      if (!sent.add(candStr)) {
        return; // Eliminate duplicate candidate dispatch over Nostr signaling
      }
    }
    pendingOutboundCandidates.putIfAbsent(remoteId, () => []).add(candMap);
    if (iceDebounceTimers[remoteId]?.isActive ?? false) return;
    iceDebounceTimers[remoteId] = Timer(const Duration(milliseconds: 80), () {
      final list = pendingOutboundCandidates.remove(remoteId);
      if (list != null &&
          list.isNotEmpty &&
          !disposed &&
          !departedPeers.contains(remoteId)) {
        sendSignal('ice_batch', targetId: remoteId, data: {'candidates': list});
      }
    });
  }

  Future<void> initiatePeerConnection(String remoteId) {
    if (departedPeers.contains(remoteId)) return Future.value();
    return runPeerExclusive(
        remoteId, () => initiatePeerConnectionInternal(remoteId));
  }

  Future<void> initiatePeerConnectionInternal(String remoteId) async {
    if (departedPeers.contains(remoteId) ||
        peers.containsKey(remoteId) ||
        negotiatingPeers.contains(remoteId)) {
      return;
    }
    negotiatingPeers.add(remoteId);
    try {
      final pc = await createPeerInternal(remoteId);
      final dc = await pc.createDataChannel(
        'maglis_data',
        RTCDataChannelInit()
          ..ordered = true
          ..binaryType = 'binary',
      );
      bindDataChannel(remoteId, dc);

      final offer = await pc.createOffer(const {
        'mandatory': {
          'OfferToReceiveAudio': true,
          'OfferToReceiveVideo': false
        },
        'optional': []
      });
      final mungedSdp = MaglisMediaHelper.mungeOpusSdp(offer.sdp ?? '');
      await pc.setLocalDescription(
        RTCSessionDescription(mungedSdp, offer.type),
      );
      await sendSignal('offer', targetId: remoteId, data: {'sdp': mungedSdp});
    } catch (e) {
      debugPrint('[MaglisPeerSession] initiatePeerConnection error: $e');
      await cleanupPeerInternal(remoteId);
    } finally {
      negotiatingPeers.remove(remoteId);
    }
  }

  Future<RTCPeerConnection> createPeerInternal(String remoteId) async {
    if (peers.containsKey(remoteId)) {
      await cleanupPeerInternal(remoteId, isReconnecting: true);
      await Future.delayed(const Duration(milliseconds: 150));
    }
    final pc = await createPeerConnection(MaglisConfigManager.rtcConfig);
    peers[remoteId] = pc;
    remoteDescSet[remoteId] = false;
    iceQueues.putIfAbsent(remoteId, () => []);

    // Ensure local stream is active before adding to peer
    if (localStream == null || localStream!.getAudioTracks().isEmpty) {
      try {
        localStream = await navigator.mediaDevices.getUserMedia(
          MaglisMediaHelper.buildAudioConstraints(),
        );
      } catch (_) {
        try {
          localStream = await navigator.mediaDevices.getUserMedia({
            'audio': true,
            'video': false,
          });
        } catch (_) {}
      }
    }

    // Add local mic audio track
    if (localStream != null) {
      for (final track in localStream!.getAudioTracks()) {
        track.enabled = !isMicMuted;
        try {
          Helper.setMicrophoneMute(isMicMuted, track);
        } catch (_) {}
        try {
          final senders = await pc.getSenders();
          if (!senders.any((s) => s.track?.kind == 'audio')) {
            await pc.addTrack(track, localStream!);
          }
        } catch (e) {
          debugPrint('[MaglisPeerSession] addTrack error: $e');
        }
      }
    }

    pc.onIceCandidate = (RTCIceCandidate c) {
      if (disposed ||
          peers[remoteId] != pc ||
          departedPeers.contains(remoteId)) {
        return;
      }
      final str = c.candidate;
      if (!MaglisMediaHelper.isValidCandidate(str)) return;
      queueOutboundIce(remoteId, {
        'candidate': str,
        'sdpMid': c.sdpMid,
        'sdpMLineIndex': c.sdpMLineIndex,
      });
    };

    const iceHandler = CallingIceStateHandler();
    pc.onIceConnectionState = (RTCIceConnectionState state) {
      if (disposed ||
          peers[remoteId] != pc ||
          departedPeers.contains(remoteId)) {
        return;
      }
      peerStates[remoteId] = state;
      onStatesChanged(Map.unmodifiable(peerStates));

      iceHandler.handle(
        state,
        onConnected: () {
          reconnectAttempts.remove(remoteId);
          isRestartInProgress[remoteId] = false;
          recoveryWindows.remove(remoteId)?.cancel();
          iceRestartGraceTimers[remoteId]?.cancel();
          iceRestartGraceTimers.remove(remoteId);
          checkSocketSleepState();
          MaglisPlatform.setSpeaker(true);
        },
        onHangup: () {
          checkSocketSleepState();
          if (isRestartInProgress[remoteId] == true) return;

          // Bounded 15s recovery window with dual retries (at 2s and 6.5s)
          final window = recoveryWindows.putIfAbsent(
            remoteId,
            () => MaglisPeerRecoveryWindow(),
          );

          window.start(
            onTimeout: () {
              if (!disposed &&
                  peers[remoteId] == pc &&
                  (peerStates[remoteId] ==
                          RTCIceConnectionState.RTCIceConnectionStateFailed ||
                      peerStates[remoteId] ==
                          RTCIceConnectionState
                              .RTCIceConnectionStateDisconnected)) {
                onNatFailure(remoteId);
                lastSeenPeerMs[remoteId] = 0;
                peerStates.remove(remoteId);
                onPeerClosed(remoteId);
                unawaited(cleanupPeer(remoteId));
                checkSocketSleepState();
              }
            },
            onRetry: () {
              if (!disposed &&
                  peers[remoteId] == pc &&
                  (peerStates[remoteId] ==
                          RTCIceConnectionState.RTCIceConnectionStateFailed ||
                      peerStates[remoteId] ==
                          RTCIceConnectionState
                              .RTCIceConnectionStateDisconnected)) {
                final attempts = (reconnectAttempts[remoteId] ?? 0) + 1;
                reconnectAttempts[remoteId] = attempts;
                final isInitiator = localPeerId.compareTo(remoteId) < 0;
                if (isInitiator) {
                  triggerIceRestart(remoteId);
                } else {
                  sendSignal('reconnect_request',
                      targetId: remoteId, data: {'iceRestart': true});
                }
              }
            },
          );
        },
      );
    };

    pc.onConnectionState = (RTCPeerConnectionState state) {
      if (disposed ||
          peers[remoteId] != pc ||
          departedPeers.contains(remoteId)) {
        return;
      }
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        peerStates[remoteId] =
            RTCIceConnectionState.RTCIceConnectionStateConnected;
        if (!disposed) {
          onStatesChanged(Map.unmodifiable(Map.from(peerStates)));
        }
      } else if (state == RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
        lastSeenPeerMs[remoteId] = 0;
        peerStates.remove(remoteId);
        onPeerClosed(remoteId);
        unawaited(cleanupPeer(remoteId));
      } else if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        checkSocketSleepState();
      }
    };

    // Route incoming audio stream to hardware speakerphone at full volume (noscall stream preservation pattern)
    pc.onTrack = (RTCTrackEvent ev) {
      if (disposed ||
          peers[remoteId] != pc ||
          departedPeers.contains(remoteId)) {
        return;
      }
      if (ev.track.kind == 'audio') {
        ev.track.enabled = true;
        if (ev.streams.isNotEmpty) {
          final streamList = remoteStreams.putIfAbsent(remoteId, () => []);
          for (final s in ev.streams) {
            if (!streamList.any((existing) => existing.id == s.id)) {
              streamList.add(s);
            }
          }
          if (kIsWeb) {
            _attachWebAudioRenderer(remoteId, ev.streams.first);
          }
        } else if (kIsWeb) {
          final existing = remoteStreams[remoteId];
          if (existing != null && existing.isNotEmpty) {
            _attachWebAudioRenderer(remoteId, existing.first);
          }
        }
        final list = remoteTracks.putIfAbsent(remoteId, () => []);
        if (!list.any((t) => t.id == ev.track.id)) {
          list.add(ev.track);
        }
        try {
          Helper.setVolume(1.0, ev.track);
        } catch (_) {}
        if (peerStates[remoteId] !=
            RTCIceConnectionState.RTCIceConnectionStateConnected) {
          peerStates[remoteId] =
              RTCIceConnectionState.RTCIceConnectionStateConnected;
          if (!disposed) {
            onStatesChanged(Map.unmodifiable(Map.from(peerStates)));
          }
        }
        MaglisPlatform.setSpeaker(true);
      }
    };

    pc.onDataChannel = (RTCDataChannel dc) {
      if (disposed ||
          peers[remoteId] != pc ||
          departedPeers.contains(remoteId)) {
        return;
      }
      bindDataChannel(remoteId, dc);
    };

    return pc;
  }

  Future<void> triggerIceRestart(String remoteId) {
    if (departedPeers.contains(remoteId)) return Future.value();
    return runPeerExclusive(
        remoteId, () => triggerIceRestartInternal(remoteId));
  }

  Future<void> triggerIceRestartInternal(String remoteId) async {
    final pc = peers[remoteId];
    if (pc == null || disposed || departedPeers.contains(remoteId)) return;
    if (isRestartInProgress[remoteId] == true) return;
    isRestartInProgress[remoteId] = true;
    sentCandidateKeys[remoteId]?.clear();
    try {
      final curSigState = await pc.getSignalingState() ?? pc.signalingState;
      if (curSigState != RTCSignalingState.RTCSignalingStateStable) {
        renegotiatePending.add(remoteId);
        return;
      }
      renegotiatePending.remove(remoteId);
      final isInitiator = localPeerId.compareTo(remoteId) < 0;
      if (isInitiator) {
        if (channels[remoteId] == null ||
            channels[remoteId]!.state !=
                RTCDataChannelState.RTCDataChannelOpen) {
          try {
            final dc = await pc.createDataChannel(
              'maglis_data',
              RTCDataChannelInit()
                ..ordered = true
                ..binaryType = 'binary',
            );
            bindDataChannel(remoteId, dc);
          } catch (_) {}
        }
        if (!kIsWeb) {
          try {
            await pc.restartIce();
          } catch (_) {}
        }
        final offer = await pc.createOffer(const {
          'mandatory': {
            'OfferToReceiveAudio': true,
            'OfferToReceiveVideo': false,
          },
          'optional': [
            {'iceRestart': true},
          ],
        });
        final mungedSdp = MaglisMediaHelper.mungeOpusSdp(offer.sdp ?? '');
        await pc.setLocalDescription(
          RTCSessionDescription(mungedSdp, offer.type),
        );
        remoteDescSet[remoteId] = false;
        await sendSignal('offer', targetId: remoteId, data: {
          'sdp': mungedSdp,
          'iceRestart': true,
        });
      } else {
        // Non-initiator requests the designated offerer to restart ICE (noscall pattern)
        await sendSignal('reconnect_request',
            targetId: remoteId, data: {'iceRestart': true});
      }
    } catch (e) {
      debugPrint('[MaglisPeerSession] restartIce error: $e');
      await cleanupPeerInternal(remoteId);
      await sendSignal('beacon', targetId: remoteId, data: const {});
    } finally {
      iceRestartGraceTimers[remoteId]?.cancel();
      iceRestartGraceTimers[remoteId] =
          Timer(const Duration(milliseconds: 2500), () {
        isRestartInProgress[remoteId] = false;
        iceRestartGraceTimers.remove(remoteId);
      });
    }
  }

  Future<void> recoverDataChannel(String remoteId) {
    if (departedPeers.contains(remoteId)) return Future.value();
    return runPeerExclusive(
        remoteId, () => recoverDataChannelInternal(remoteId));
  }

  Future<void> recoverDataChannelInternal(String remoteId) async {
    if (disposed ||
        departedPeers.contains(remoteId) ||
        !peers.containsKey(remoteId)) {
      return;
    }
    final pc = peers[remoteId];
    if (pc == null) return;

    final isInitiator = localPeerId.compareTo(remoteId) < 0;
    if (isInitiator) {
      if (negotiatingPeers.contains(remoteId)) {
        renegotiatePending.add(remoteId);
        return;
      }
      negotiatingPeers.add(remoteId);
      try {
        final curDc = channels[remoteId];
        final bool isDcOk = curDc != null &&
            curDc.state == RTCDataChannelState.RTCDataChannelOpen;

        if (isDcOk) return;

        final curSigState = await pc.getSignalingState() ?? pc.signalingState;
        if (curSigState != RTCSignalingState.RTCSignalingStateStable) {
          renegotiatePending.add(remoteId);
          return;
        }

        // Detach stale callbacks on any defunct DataChannel before replacing it
        if (curDc != null) {
          curDc.onDataChannelState = null;
          curDc.onMessage = null;
          curDc.onBufferedAmountLow = null;
        }

        final dc = await pc.createDataChannel(
          'maglis_data',
          RTCDataChannelInit()
            ..ordered = true
            ..binaryType = 'binary',
        );
        bindDataChannel(remoteId, dc);

        final offer = await pc.createOffer(const {
          'mandatory': {
            'OfferToReceiveAudio': true,
            'OfferToReceiveVideo': false
          },
          'optional': []
        });
        final mungedSdp = MaglisMediaHelper.mungeOpusSdp(offer.sdp ?? '');
        await pc.setLocalDescription(
          RTCSessionDescription(mungedSdp, offer.type),
        );
        await sendSignal('offer', targetId: remoteId, data: {
          'sdp': mungedSdp,
          'dcRecovery': true,
        });
      } catch (e) {
        debugPrint('[MaglisPeerSession] recoverDataChannel error: $e');
      } finally {
        negotiatingPeers.remove(remoteId);
      }
    } else {
      sendSignal('reconnect_request',
          targetId: remoteId, data: {'reason': 'dc_recovery'});
    }
  }

  Future<void> flushIceQueue(String remoteId) async {
    final pc = peers[remoteId];
    final queue = iceQueues[remoteId];
    if (pc == null || queue == null) return;
    for (final c in List<RTCIceCandidate>.from(queue)) {
      try {
        await pc.addCandidate(c);
      } catch (_) {}
    }
    queue.clear();
  }

  void bindDataChannel(String remoteId, RTCDataChannel dc) {
    final prevDc = channels[remoteId];
    if (prevDc != null && prevDc != dc) {
      prevDc.onDataChannelState = null;
      prevDc.onMessage = null;
      prevDc.onBufferedAmountLow = null;
    }
    channels[remoteId] = dc;
    try {
      dc.bufferedAmountLowThreshold = 64 * 1024;
    } catch (_) {}
    dc.onBufferedAmountLow = (_) {
      if (!disposed && channels[remoteId] == dc) {
        final peerQueue = _peerVitalQueues.remove(remoteId);
        if (peerQueue != null && peerQueue.isNotEmpty) {
          for (final vital in peerQueue) {
            try {
              dc.send(RTCDataChannelMessage(vital));
            } catch (_) {}
          }
        }
        if (pendingVitalPackets.isNotEmpty) {
          final toSend = List<String>.from(pendingVitalPackets);
          pendingVitalPackets.clear();
          for (final vital in toSend) {
            try {
              dc.send(RTCDataChannelMessage(vital));
            } catch (_) {}
          }
        }
        if (peersNeedingCatchup.remove(remoteId)) {
          try {
            dc.send(RTCDataChannelMessage(onBuildSnapshot().pack()));
          } catch (_) {}
        }
      }
    };

    void sendGossipList() {
      final activeOthers = peers.keys
          .where((p) =>
              p != remoteId && p != localPeerId && !departedPeers.contains(p))
          .toList();
      if (activeOthers.isNotEmpty) {
        try {
          dc.send(RTCDataChannelMessage(jsonEncode({
            't': 98,
            'peers': activeOthers,
          })));
        } catch (_) {}
      }
      for (final existingPeerId in activeOthers) {
        final existingDc = channels[existingPeerId];
        if (existingDc != null &&
            existingDc.state == RTCDataChannelState.RTCDataChannelOpen) {
          try {
            existingDc.send(RTCDataChannelMessage(jsonEncode({
              't': 98,
              'peers': [remoteId],
            })));
          } catch (_) {}
        }
      }
    }

    void onChannelOpen() {
      if (disposed ||
          channels[remoteId] != dc ||
          departedPeers.contains(remoteId)) {
        return;
      }
      lastSeenPeerMs[remoteId] = DateTime.now().millisecondsSinceEpoch;
      peerStates[remoteId] =
          RTCIceConnectionState.RTCIceConnectionStateConnected;
      if (!disposed) {
        onStatesChanged(Map.unmodifiable(Map.from(peerStates)));
      }
      checkSocketSleepState();

      try {
        dc.send(RTCDataChannelMessage(onBuildSnapshot().pack()));
      } catch (_) {}

      sendGossipList();

      // Hedged 350ms follow-up snapshot + peer gossip guarantees state and mesh synchronization
      // even if initial frame was sent before remote listener binding or concurrent peer negotiation completed.
      Future.delayed(const Duration(milliseconds: 350), () {
        if (!disposed &&
            channels[remoteId] == dc &&
            dc.state == RTCDataChannelState.RTCDataChannelOpen) {
          try {
            dc.send(RTCDataChannelMessage(onBuildSnapshot().pack()));
          } catch (_) {}
          sendGossipList();
        }
      });

      final peerQueue = _peerVitalQueues.remove(remoteId);
      if (peerQueue != null && peerQueue.isNotEmpty) {
        for (final vital in peerQueue) {
          try {
            dc.send(RTCDataChannelMessage(vital));
          } catch (_) {}
        }
      }
      if (pendingVitalPackets.isNotEmpty) {
        for (final vital in List<String>.from(pendingVitalPackets)) {
          try {
            dc.send(RTCDataChannelMessage(vital));
          } catch (_) {}
        }
        pendingVitalPackets.clear();
      }
    }

    // Attach dc.onMessage FIRST before inspecting dc.state or triggering onChannelOpen
    dc.onMessage = (RTCDataChannelMessage msg) {
      if (disposed || departedPeers.contains(remoteId)) return;
      lastSeenPeerMs[remoteId] = DateTime.now().millisecondsSinceEpoch;
      if (peerStates[remoteId] !=
          RTCIceConnectionState.RTCIceConnectionStateConnected) {
        peerStates[remoteId] =
            RTCIceConnectionState.RTCIceConnectionStateConnected;
        if (!disposed) {
          onStatesChanged(Map.unmodifiable(Map.from(peerStates)));
        }
      }
      if (msg.isBinary) {
        final pkt = MaglisPacket.unpackBinary(msg.binary);
        if (pkt != null) {
          handleIncomingPacket(pkt);
        }
        return;
      }
      if (msg.text.isEmpty) return;
      handleIncomingPacketString(msg.text);
    };

    dc.onDataChannelState = (RTCDataChannelState state) {
      if (disposed || channels[remoteId] != dc) return;
      if (state == RTCDataChannelState.RTCDataChannelOpen) {
        onChannelOpen();
      } else if (state == RTCDataChannelState.RTCDataChannelClosed) {
        channels.remove(remoteId);
        if (!disposed &&
            !departedPeers.contains(remoteId) &&
            peers.containsKey(remoteId)) {
          final peerState = peerStates[remoteId];
          final isConnected = peerState ==
                  RTCIceConnectionState.RTCIceConnectionStateConnected ||
              peerState == RTCIceConnectionState.RTCIceConnectionStateCompleted;
          if (isConnected) {
            unawaited(recoverDataChannel(remoteId));
          }
        }
      }
    };

    if (dc.state == RTCDataChannelState.RTCDataChannelOpen) {
      onChannelOpen();
    }
  }

  void handleIncomingPacketString(String raw) {
    if (raw.isEmpty) return;
    try {
      if (raw.contains('"type":"leave"') || raw.contains('"t":99')) {
        try {
          final m = jsonDecode(raw) as Map<String, dynamic>;
          final u = m['u'] as String?;
          if (u != null && u.isNotEmpty && u != localPeerId) {
            departedPeers.add(u);
            peerStates.remove(u);
            onPeerClosed(u);
            unawaited(cleanupPeer(u));
          }
        } catch (_) {}
        return;
      }

      if (raw.contains('"t":98') || raw.contains('"type":"peer_list"')) {
        try {
          final m = jsonDecode(raw) as Map<String, dynamic>;
          final peersList = m['peers'] as List<dynamic>?;
          if (peersList != null) {
            final list = peersList
                .map((e) => e.toString())
                .where((id) => !departedPeers.contains(id))
                .toList();
            if (list.isNotEmpty) {
              onPeerListDiscovered(list);
            }
          }
        } catch (_) {}
        return;
      }

      final pkt = MaglisPacket.unpack(raw);
      handleIncomingPacket(pkt);
    } catch (_) {}
  }

  void _relayPacketToOtherPeers(MaglisPacket pkt) {
    if (disposed || channels.length < 2) return;
    if (pkt.senderId.isEmpty || pkt.senderId == localPeerId) return;

    if (pkt.type == MaglisPacketType.floorClaim) {
      if (pkt.ts > 0 && _lastRelayedClaimTs[pkt.senderId] == pkt.ts) return;
      _lastRelayedClaimTs[pkt.senderId] = pkt.ts;
    } else if (pkt.type == MaglisPacketType.floorRelease ||
        pkt.type == MaglisPacketType.recitationUpdate) {
      final prevRelayed = _lastRelayedSeq[pkt.senderId] ?? -1;
      if (pkt.seq <= prevRelayed && (prevRelayed - pkt.seq) < 50000) return;
      _lastRelayedSeq[pkt.senderId] = pkt.seq;
    } else {
      return;
    }

    final msg = RTCDataChannelMessage.fromBinary(pkt.packBinary());
    for (final entry
        in List<MapEntry<String, RTCDataChannel>>.from(channels.entries)) {
      final targetId = entry.key;
      if (targetId == pkt.senderId ||
          targetId == localPeerId ||
          departedPeers.contains(targetId)) {
        continue;
      }
      final dc = entry.value;
      if (dc.state == RTCDataChannelState.RTCDataChannelOpen) {
        final buf = dc.bufferedAmount ?? 0;
        if (buf <= maxDataChannelBufferedAmount) {
          try {
            dc.send(msg);
          } catch (_) {}
        }
      }
    }
  }

  void handleIncomingPacket(MaglisPacket pkt) {
    try {
      if (pkt.senderId.isEmpty || departedPeers.contains(pkt.senderId)) return;
      if (pkt.senderId != localPeerId) {
        lastSeenPeerMs[pkt.senderId] = DateTime.now().millisecondsSinceEpoch;
        if (peers.containsKey(pkt.senderId) &&
            peerStates[pkt.senderId] !=
                RTCIceConnectionState.RTCIceConnectionStateConnected) {
          peerStates[pkt.senderId] =
              RTCIceConnectionState.RTCIceConnectionStateConnected;
          if (!disposed) {
            onStatesChanged(Map.unmodifiable(Map.from(peerStates)));
          }
        }
      }

      if (pkt.type == MaglisPacketType.ping) {
        final pongJson = jsonEncode({
          't': 5,
          'u': localPeerId,
          'm': pkt.ts,
        });
        final targetDc = channels[pkt.senderId];
        if (targetDc != null &&
            targetDc.state == RTCDataChannelState.RTCDataChannelOpen) {
          final buf = targetDc.bufferedAmount ?? 0;
          if (buf <= maxDataChannelBufferedAmount) {
            try {
              targetDc.send(RTCDataChannelMessage(pongJson));
            } catch (_) {}
          }
        } else {
          dispatchReliable(pongJson, isVital: false);
        }
        onPacketReceived(pkt);
        return;
      }
      if (pkt.type == MaglisPacketType.pong) {
        final now = DateTime.now().millisecondsSinceEpoch;
        final rtt = (now - pkt.ts).clamp(0, 10000);
        peerLatency[pkt.senderId] = rtt;
        onPacketReceived(pkt);
        return;
      }

      final prev = lastSeq[pkt.senderId] ?? -1;
      if ((pkt.type == MaglisPacketType.floorClaim ||
              pkt.type == MaglisPacketType.snapshot) &&
          (prev - pkt.seq) > 50000) {
        lastSeq.remove(pkt.senderId);
      }

      final curPrev = lastSeq[pkt.senderId] ?? -1;
      final lastS = lastSeenSurah[pkt.senderId] ?? -1;
      final lastA = lastSeenAyah[pkt.senderId] ?? -1;
      final bool isForwardVerseChange =
          pkt.type == MaglisPacketType.recitationUpdate &&
              (pkt.surah != lastS || pkt.ayah != lastA) &&
              pkt.seq != curPrev;

      if (pkt.type == MaglisPacketType.recitationUpdate &&
          !isForwardVerseChange &&
          pkt.seq <= curPrev &&
          (curPrev - pkt.seq) < 50000) {
        return;
      }
      if (pkt.seq > curPrev ||
          pkt.type == MaglisPacketType.floorClaim ||
          pkt.type == MaglisPacketType.snapshot) {
        lastSeq[pkt.senderId] = pkt.seq;
      }
      lastSeenSurah[pkt.senderId] = pkt.surah;
      lastSeenAyah[pkt.senderId] = pkt.ayah;

      // 1-hop deduplicated mesh relay: ensures peers whose direct P2P link is still
      // negotiating (or behind Symmetric NAT) still receive floor claims and highlights immediately.
      _relayPacketToOtherPeers(pkt);

      onPacketReceived(pkt);
    } catch (_) {}
  }

  void dispatchReliable(String raw, {bool isVital = true}) {
    final msg = RTCDataChannelMessage(raw);
    bool anyChannelOpen = false;

    for (final entry
        in List<MapEntry<String, RTCDataChannel>>.from(channels.entries)) {
      final dc = entry.value;
      if (dc.state == RTCDataChannelState.RTCDataChannelOpen) {
        anyChannelOpen = true;
        final buf = dc.bufferedAmount ?? 0;
        if (buf <= maxDataChannelBufferedAmount) {
          try {
            dc.send(msg);
          } catch (_) {}
        } else if (isVital) {
          _queuePeerVitalPacket(entry.key, raw);
        }
      } else if (isVital) {
        _queuePeerVitalPacket(entry.key, raw);
      }
    }

    if (!anyChannelOpen && isVital) {
      queueVitalPacket(raw);
    }
  }

  void _queuePeerVitalPacket(String peerId, String raw) {
    final list = _peerVitalQueues.putIfAbsent(peerId, () => <String>[]);
    if (!list.contains(raw)) {
      list.add(raw);
      if (list.length > 30) {
        list.removeAt(0);
      }
    }
  }

  void queueVitalPacket(String raw) {
    if (!pendingVitalPackets.contains(raw)) {
      pendingVitalPackets.add(raw);
      if (pendingVitalPackets.length > 30) {
        pendingVitalPackets.removeAt(0);
      }
    }
  }

  void dispatchReliableBinary(Uint8List bytes, {String? vitalFallbackJson}) {
    final msg = RTCDataChannelMessage.fromBinary(bytes);
    bool anyChannelOpen = false;

    for (final entry
        in List<MapEntry<String, RTCDataChannel>>.from(channels.entries)) {
      final dc = entry.value;
      if (dc.state == RTCDataChannelState.RTCDataChannelOpen) {
        anyChannelOpen = true;
        final buf = dc.bufferedAmount ?? 0;
        if (buf <= maxDataChannelBufferedAmount) {
          try {
            dc.send(msg);
          } catch (_) {}
        } else {
          peersNeedingCatchup.add(entry.key);
          if (vitalFallbackJson != null) {
            _queuePeerVitalPacket(entry.key, vitalFallbackJson);
          }
        }
      } else if (vitalFallbackJson != null) {
        _queuePeerVitalPacket(entry.key, vitalFallbackJson);
      }
    }

    if (!anyChannelOpen && vitalFallbackJson != null) {
      queueVitalPacket(vitalFallbackJson);
    }
  }

  void dispatchRaw(String raw, {bool? isVital}) {
    dispatchReliable(raw, isVital: isVital ?? true);
  }

  Future<void> handleOffer(
    String remoteId,
    String sdp, {
    bool isIceRestart = false,
    bool isDataChannelRecovery = false,
  }) async {
    if (departedPeers.contains(remoteId)) return;
    return runPeerExclusive(remoteId, () async {
      if (departedPeers.contains(remoteId)) return;
      if (!peers.containsKey(remoteId) && peers.length >= maxRemotePeers) {
        return;
      }

      final isInitiator = localPeerId.compareTo(remoteId) < 0;
      final bool isRenegotiation = isIceRestart || isDataChannelRecovery;

      if (isInitiator && !isRenegotiation && peers.containsKey(remoteId)) {
        return;
      }

      final existingOfferPc = peers[remoteId];
      final existingOfferState = peerStates[remoteId];
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
        await cleanupPeerInternal(remoteId);
      }

      if (negotiatingPeers.contains(remoteId)) {
        return;
      }
      negotiatingPeers.add(remoteId);
      try {
        var pc = peers[remoteId] ?? await createPeerInternal(remoteId);
        final curSigState = await pc.getSignalingState() ?? pc.signalingState;
        if (curSigState == RTCSignalingState.RTCSignalingStateHaveLocalOffer) {
          if (localPeerId.compareTo(remoteId) > 0) {
            // Deterministic Glare Resolution (Noscall & PeerRTC pattern):
            // Local peer has higher ID and yields to lower ID peer.
            // Reset peer connection cleanly to accept remote offer without native rollback crash.
            await cleanupPeerInternal(remoteId, isReconnecting: true);
            pc = await createPeerInternal(remoteId);
          } else {
            // Local peer has lower ID (designated offerer); its offer takes precedence
            return;
          }
        }

        if (localStream != null) {
          for (final track in localStream!.getAudioTracks()) {
            track.enabled = !isMicMuted;
            try {
              Helper.setMicrophoneMute(isMicMuted, track);
            } catch (_) {}
            try {
              final senders = await pc.getSenders();
              if (!senders.any((s) => s.track?.kind == 'audio')) {
                await pc.addTrack(track, localStream!);
              }
            } catch (_) {}
          }
        }

        await pc.setRemoteDescription(RTCSessionDescription(sdp, 'offer'));
        remoteDescSet[remoteId] = true;

        // Ensure Unified Plan audio transceiver is bidirectional (sendrecv) so both peers hear each other
        if (localStream != null && localStream!.getAudioTracks().isNotEmpty) {
          try {
            final transceivers = await pc.getTransceivers();
            for (final tr in transceivers) {
              if (tr.receiver.track?.kind == 'audio' ||
                  tr.sender.track?.kind == 'audio') {
                final dir = await tr.getCurrentDirection();
                if (dir == TransceiverDirection.RecvOnly) {
                  await tr.setDirection(TransceiverDirection.SendRecv);
                }
              }
            }
          } catch (_) {}
        }

        final answer = await pc.createAnswer(const {
          'mandatory': {
            'OfferToReceiveAudio': true,
            'OfferToReceiveVideo': false
          },
          'optional': []
        });
        final mungedSdp = MaglisMediaHelper.mungeOpusSdp(answer.sdp ?? '');
        await pc.setLocalDescription(
          RTCSessionDescription(mungedSdp, answer.type),
        );
        await flushIceQueue(remoteId);
        await sendSignal('answer',
            targetId: remoteId, data: {'sdp': mungedSdp});
      } catch (e) {
        debugPrint('[MaglisPeerSession] handleOffer SDP exchange error: $e');
        await cleanupPeerInternal(remoteId);
      } finally {
        negotiatingPeers.remove(remoteId);
      }
    });
  }

  Future<void> handleAnswer(String remoteId, String sdp) async {
    if (departedPeers.contains(remoteId)) return;
    return runPeerExclusive(remoteId, () async {
      final pc = peers[remoteId];
      if (pc == null || disposed || departedPeers.contains(remoteId)) return;
      if (answerInFlight[remoteId] == true) return;

      final curState = await pc.getSignalingState() ?? pc.signalingState;
      if (curState != RTCSignalingState.RTCSignalingStateHaveLocalOffer) {
        return;
      }

      answerInFlight[remoteId] = true;
      try {
        await pc.setRemoteDescription(RTCSessionDescription(sdp, 'answer'));
        remoteDescSet[remoteId] = true;
        await flushIceQueue(remoteId);
      } catch (e) {
        debugPrint('[MaglisPeerSession] setRemoteDescription answer error: $e');
      } finally {
        answerInFlight[remoteId] = false;
      }

      if (renegotiatePending.remove(remoteId) && !disposed) {
        final isInitiator = localPeerId.compareTo(remoteId) < 0;
        if (isInitiator) {
          unawaited(triggerIceRestart(remoteId));
        }
      }
    });
  }

  Future<void> handleIceBatch(String remoteId, List<dynamic> list) async {
    if (disposed || departedPeers.contains(remoteId)) return;
    for (final item in list) {
      if (item is Map) {
        final candStr = item['candidate'] as String?;
        if (!MaglisMediaHelper.isValidCandidate(candStr)) continue;
        final cand = RTCIceCandidate(
          candStr,
          item['sdpMid'] as String?,
          item['sdpMLineIndex'] as int?,
        );
        if (remoteDescSet[remoteId] == true && peers[remoteId] != null) {
          try {
            await peers[remoteId]!.addCandidate(cand);
          } catch (_) {
            iceQueues.putIfAbsent(remoteId, () => []).add(cand);
          }
        } else {
          iceQueues.putIfAbsent(remoteId, () => []).add(cand);
        }
      }
    }
  }

  void sendPacket(MaglisPacket packet, {bool throttle = false}) {
    if (disposed) return;
    final bytes = packet.packBinary();
    final bool isVitalFloorEvent = packet.type == MaglisPacketType.floorClaim ||
        packet.type == MaglisPacketType.floorRelease;
    dispatchReliableBinary(
      bytes,
      vitalFallbackJson: isVitalFloorEvent ? packet.pack() : null,
    );
  }

  Future<void> setMicMuted(bool muted) async {
    isMicMuted = muted;
    if (!muted &&
        (localStream == null || localStream!.getAudioTracks().isEmpty)) {
      try {
        localStream = await navigator.mediaDevices.getUserMedia(
          MaglisMediaHelper.buildAudioConstraints(),
        );
        for (final entry
            in List<MapEntry<String, RTCPeerConnection>>.from(peers.entries)) {
          if (localStream != null) {
            for (final track in localStream!.getAudioTracks()) {
              track.enabled = true;
              try {
                Helper.setMicrophoneMute(false, track);
              } catch (_) {}
              try {
                final senders = await entry.value.getSenders();
                if (!senders.any((s) => s.track?.kind == 'audio')) {
                  await entry.value.addTrack(track, localStream!);
                }
              } catch (_) {}
            }
          }
          final isInitiator = localPeerId.compareTo(entry.key) < 0;
          if (isInitiator) {
            triggerIceRestart(entry.key);
          } else {
            sendSignal('reconnect_request',
                targetId: entry.key, data: {'iceRestart': true});
          }
        }
      } catch (_) {}
    } else {
      localStream?.getAudioTracks().forEach((t) {
        t.enabled = !muted;
        try {
          Helper.setMicrophoneMute(muted, t);
        } catch (_) {}
      });
    }
  }

  Future<void> retryConnections() async {
    for (final entry
        in List<MapEntry<String, RTCPeerConnection>>.from(peers.entries)) {
      final state = peerStates[entry.key];
      if (state == RTCIceConnectionState.RTCIceConnectionStateFailed ||
          state == RTCIceConnectionState.RTCIceConnectionStateDisconnected) {
        final isInitiator = localPeerId.compareTo(entry.key) < 0;
        if (isInitiator) {
          unawaited(triggerIceRestart(entry.key));
        } else {
          unawaited(sendSignal('reconnect_request',
              targetId: entry.key, data: {'iceRestart': true}));
        }
      }
    }
    await sendSignal('beacon', data: const {});
  }

  Future<void> cleanupPeer(String peerId) {
    return runPeerExclusive(peerId, () => cleanupPeerInternal(peerId));
  }

  Future<void> cleanupPeerInternal(String peerId,
      {bool isReconnecting = false}) async {
    peersNeedingCatchup.remove(peerId);
    renegotiatePending.remove(peerId);
    _peerVitalQueues.remove(peerId);
    iceQueues.remove(peerId);
    pendingOutboundCandidates.remove(peerId);
    iceDebounceTimers.remove(peerId)?.cancel();
    iceRestartGraceTimers.remove(peerId)?.cancel();
    recoveryWindows.remove(peerId)?.cancel();
    sentCandidateKeys.remove(peerId);
    reconnectAttempts.remove(peerId);
    isRestartInProgress.remove(peerId);
    peerLatency.remove(peerId);
    remoteDescSet.remove(peerId);
    answerInFlight.remove(peerId);
    negotiatingPeers.remove(peerId);
    lastSeq.remove(peerId);
    lastSeenSurah.remove(peerId);
    lastSeenAyah.remove(peerId);
    _lastRelayedSeq.remove(peerId);
    _lastRelayedClaimTs.remove(peerId);

    if (!isReconnecting) {
      peerStates.remove(peerId);
      lastSeenPeerMs.remove(peerId);
    } else {
      peerStates[peerId] = RTCIceConnectionState.RTCIceConnectionStateChecking;
    }

    final streams = remoteStreams.remove(peerId);
    if (streams != null) {
      for (final s in streams) {
        try {
          await s.dispose();
        } catch (_) {}
      }
    }

    final webRenderer = _audioRenderers.remove(peerId);
    if (webRenderer != null) {
      try {
        webRenderer.srcObject = null;
        await webRenderer.dispose();
      } catch (_) {}
    }

    final tracks = remoteTracks.remove(peerId);
    if (tracks != null) {
      for (final t in tracks) {
        try {
          t.enabled = false;
          Helper.setVolume(0.0, t);
        } catch (_) {}
      }
    }

    try {
      final dc = channels.remove(peerId);
      if (dc != null) {
        dc.onDataChannelState = null;
        dc.onMessage = null;
        dc.onBufferedAmountLow = null;
        try {
          if (dc.state == RTCDataChannelState.RTCDataChannelOpen) {
            await dc.close();
          }
        } catch (_) {}
      }
    } catch (_) {}

    try {
      final pc = peers.remove(peerId);
      if (pc != null) {
        pc.onIceCandidate = null;
        pc.onIceConnectionState = null;
        pc.onConnectionState = null;
        pc.onSignalingState = null;
        pc.onTrack = null;
        pc.onDataChannel = null;
        pc.onRenegotiationNeeded = null;

        try {
          await pc.close();
        } catch (_) {}
        try {
          await pc.dispose();
        } catch (_) {}
      }
    } catch (_) {}

    // Cancel any pending tasks queued for this peer AFTER async teardown completes
    if (!isReconnecting) {
      _taskQueue.cancelPeer(peerId);
    }

    if (!disposed) {
      onStatesChanged(Map.unmodifiable(Map.from(peerStates)));
    }
  }

  Future<void> dispose() async {
    disposed = true;
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    for (final timer in List<Timer>.from(iceDebounceTimers.values)) {
      timer.cancel();
    }
    iceDebounceTimers.clear();
    for (final timer in List<Timer>.from(iceRestartGraceTimers.values)) {
      timer.cancel();
    }
    iceRestartGraceTimers.clear();
    for (final window
        in List<MaglisPeerRecoveryWindow>.from(recoveryWindows.values)) {
      window.cancel();
    }
    recoveryWindows.clear();
    sentCandidateKeys.clear();
    reconnectAttempts.clear();
    isRestartInProgress.clear();
    peerLatency.clear();
    pendingOutboundCandidates.clear();
    pendingVitalPackets.clear();
    _peerVitalQueues.clear();
    renegotiatePending.clear();
    departedPeers.clear();
    _lastRelayedSeq.clear();
    _lastRelayedClaimTs.clear();
    _taskQueue.clear();

    // 1. Immediately stop hardware mic track to terminate native audio recording and buffer
    try {
      localStream?.getTracks().forEach((t) {
        try {
          t.stop();
        } catch (_) {}
      });
      await localStream?.dispose();
      localStream = null;
    } catch (_) {}

    // 2. Clear all DataChannels callbacks
    for (final dc in List<RTCDataChannel>.from(channels.values)) {
      try {
        dc.onDataChannelState = null;
        dc.onMessage = null;
        dc.onBufferedAmountLow = null;
      } catch (_) {}
    }
    channels.clear();

    // 3. Tear down all peer connections and remote audio tracks
    for (final id in List<String>.from(peers.keys)) {
      await cleanupPeerInternal(id);
    }
    for (final list in List<List<MediaStream>>.from(remoteStreams.values)) {
      for (final s in list) {
        try {
          await s.dispose();
        } catch (_) {}
      }
    }
    for (final r in List<RTCVideoRenderer>.from(_audioRenderers.values)) {
      try {
        r.srcObject = null;
        await r.dispose();
      } catch (_) {}
    }
    _audioRenderers.clear();
    remoteStreams.clear();
    remoteTracks.clear();
  }

  void _attachWebAudioRenderer(String remoteId, MediaStream stream) {
    if (!kIsWeb) return;
    unawaited(() async {
      try {
        var renderer = _audioRenderers[remoteId];
        if (renderer == null) {
          renderer = RTCVideoRenderer();
          await renderer.initialize();
          if (disposed || departedPeers.contains(remoteId)) {
            await renderer.dispose();
            return;
          }
          _audioRenderers[remoteId] = renderer;
        }
        renderer.srcObject = stream;
      } catch (e) {
        debugPrint('[MaglisPeerSession] Web audio renderer error: $e');
      }
    }());
  }
}

/// A bounded recovery attempt for an individual WebRTC peer connection (noscall pattern).
/// - Fixed grace period (15s deadline)
/// - Paced retries (at 2s and 6.5s)
/// - Repeated disconnect events cannot extend or delay the deadline.
class MaglisPeerRecoveryWindow {
  static const Duration defaultGracePeriod = Duration(seconds: 15);
  static const Duration defaultRetryDelay = Duration(seconds: 2);

  final Duration gracePeriod;
  final Duration retryDelay;

  Timer? _deadline;
  Timer? _retry;
  Timer? _secondRetry;

  MaglisPeerRecoveryWindow({
    this.gracePeriod = defaultGracePeriod,
    this.retryDelay = defaultRetryDelay,
  });

  bool get active => _deadline != null;

  void start({
    required void Function() onTimeout,
    required void Function() onRetry,
  }) {
    if (active) return;
    _deadline = Timer(gracePeriod, () {
      cancel();
      onTimeout();
    });
    _retry = Timer(retryDelay, onRetry);
    if (gracePeriod.inMilliseconds > 7000) {
      _secondRetry = Timer(const Duration(milliseconds: 6500), onRetry);
    }
  }

  void cancel() {
    _deadline?.cancel();
    _retry?.cancel();
    _secondRetry?.cancel();
    _deadline = null;
    _retry = null;
    _secondRetry = null;
  }
}

/// Sequential task execution queue per peer (LiveKit & PeerRTC pattern).
/// Enforces bounded execution, prevents concurrent state mutations, and eliminates deadlocks.
class PeerTaskQueue {
  final Map<String, List<_QueuedTask>> _queues = {};
  final Map<String, bool> _running = {};

  Future<T> run<T>(
    String peerId,
    Future<T> Function() action, {
    Duration timeout = const Duration(seconds: 8),
  }) {
    final completer = Completer<T>();
    final task = _QueuedTask(
      action: () async {
        try {
          final res = await action().timeout(timeout);
          if (!completer.isCompleted) completer.complete(res);
        } catch (e, st) {
          if (!completer.isCompleted) completer.completeError(e, st);
        }
      },
      completer: completer,
    );

    _queues.putIfAbsent(peerId, () => []).add(task);
    _processNext(peerId);
    return completer.future;
  }

  void _processNext(String peerId) {
    if (_running[peerId] == true) return;
    final queue = _queues[peerId];
    if (queue == null || queue.isEmpty) {
      _queues.remove(peerId);
      _running.remove(peerId);
      return;
    }

    _running[peerId] = true;
    final task = queue.removeAt(0);

    task.action().whenComplete(() {
      _running[peerId] = false;
      _processNext(peerId);
    });
  }

  void cancelPeer(String peerId) {
    final queue = _queues.remove(peerId);
    // Do NOT remove _running[peerId] here if a task is currently mid-flight;
    // whenComplete() will clear _running[peerId] once the active task finishes.
    if (_running[peerId] != true) {
      _running.remove(peerId);
    }
    if (queue != null) {
      for (final t in queue) {
        if (!t.completer.isCompleted) {
          t.completer.completeError(StateError('Peer $peerId queue cancelled'));
        }
      }
    }
  }

  void clear() {
    for (final peerId in List<String>.from(_queues.keys)) {
      final queue = _queues.remove(peerId);
      if (queue != null) {
        for (final t in queue) {
          if (!t.completer.isCompleted) {
            t.completer
                .completeError(StateError('Peer $peerId queue cancelled'));
          }
        }
      }
    }
    _queues.clear();
    _running.clear();
  }
}

class _QueuedTask {
  final Future<void> Function() action;
  final Completer completer;
  _QueuedTask({required this.action, required this.completer});
}
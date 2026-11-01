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
  String? _currentActiveReciterId;

  final Map<String, RTCPeerConnection> peers = {};
  final Map<String, RTCDataChannel> channels = {};
  final Map<String, RTCDataChannel> lossyChannels = {};
  final Map<String, List<RTCIceCandidate>> iceQueues = {};
  final Map<String, bool> remoteDescSet = {};
  final Map<String, int> lastSeq = {};
  final Map<String, int> lastSeenSurah = {};
  final Map<String, int> lastSeenAyah = {};
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
  final Map<String, List<MediaStreamTrack>> remoteTracks = {};
  final Map<String, List<MediaStream>> remoteStreams = {};
  final Set<String> peersNeedingCatchup = <String>{};
  final Set<String> renegotiatePending = <String>{};
  final Map<String, Future<void>> peerLockChains = {};
  final List<String> pendingVitalPackets = [];

  static const int maxDataChannelBufferedAmount = 128 * 1024;
  static const int maxRemotePeers = 3;

  int getPeerLatency(String peerId) => peerLatency[peerId] ?? 0;

  Map<String, MaglisPeerDiagnostics> get peerDiagnostics {
    final map = <String, MaglisPeerDiagnostics>{};
    for (final peerId in List<String>.from(peers.keys)) {
      map[peerId] = MaglisPeerDiagnostics(
        peerId: peerId,
        rttMs: peerLatency[peerId] ?? 0,
        state: peerStates[peerId] ?? RTCIceConnectionState.RTCIceConnectionStateNew,
        lastSeenMs: lastSeenPeerMs[peerId] ?? 0,
      );
    }
    return map;
  }

  /// Synchronizes audio track playout to the active reciter (Floor-Forwarding).
  /// Disables decoding and audio output for silent peers, cutting cellular bandwidth and noise.
  void updateActiveFloor(String? activeReciterId) {
    _currentActiveReciterId = activeReciterId;

    if (activeReciterId == localPeerId) {
      localStream?.getAudioTracks().forEach((t) {
        t.enabled = !isMicMuted;
        Helper.setMicrophoneMute(isMicMuted, t);
      });
    }

    remoteTracks.forEach((remoteId, tracks) {
      final shouldHear = (activeReciterId == null) || (activeReciterId == remoteId);
      for (final t in tracks) {
        t.enabled = shouldHear;
        try {
          Helper.setVolume(shouldHear ? 1.0 : 0.0, t);
        } catch (_) {}
      }
    });
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
        dispatchLossy(pingJson);
      }

      // Ghost peer reaping (noscall pattern): reap dead peers after 12s without packets
      final stalePeers = <String>[];
      for (final peerId in List<String>.from(peers.keys)) {
        final lastSeen = lastSeenPeerMs[peerId];
        if (lastSeen != null && lastSeen > 0 && (now - lastSeen) > 12000) {
          stalePeers.add(peerId);
        }
      }

      for (final peerId in stalePeers) {
        cleanupPeer(peerId);
        onPeerClosed(peerId);
      }
    });
  }

  Future<T> runPeerExclusive<T>(String peerId, Future<T> Function() block) {
    final prev = peerLockChains[peerId] ?? Future.value();
    final completer = Completer<void>();
    peerLockChains[peerId] = completer.future;

    return prev.then((_) => block()).whenComplete(() {
      completer.complete();
      if (peerLockChains[peerId] == completer.future) {
        peerLockChains.remove(peerId);
      }
    });
  }

  void queueOutboundIce(String remoteId, Map<String, dynamic> candMap) {
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
      if (list != null && list.isNotEmpty && !disposed) {
        sendSignal('ice_batch', targetId: remoteId, data: {'candidates': list});
      }
    });
  }

  Future<void> initiatePeerConnection(String remoteId) {
    return runPeerExclusive(
        remoteId, () => initiatePeerConnectionInternal(remoteId));
  }

  Future<void> initiatePeerConnectionInternal(String remoteId) async {
    if (peers.containsKey(remoteId) || negotiatingPeers.contains(remoteId))
      return;
    negotiatingPeers.add(remoteId);
    try {
      final pc = await createPeerInternal(remoteId);
      final dcReliable = await pc.createDataChannel(
        'maglis_reliable',
        RTCDataChannelInit()
          ..ordered = true
          ..binaryType = 'binary',
      );
      bindDataChannel(remoteId, dcReliable, isLossy: false);

      final dcLossy = await pc.createDataChannel(
        'maglis_lossy',
        RTCDataChannelInit()
          ..ordered = false
          ..maxRetransmits = 0
          ..binaryType = 'binary',
      );
      bindDataChannel(remoteId, dcLossy, isLossy: true);

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
      if (disposed) return;
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

          // Bounded 15s recovery window (noscall pattern)
          final window = recoveryWindows.putIfAbsent(
            remoteId,
            () => MaglisPeerRecoveryWindow(),
          );

          window.start(
            onTimeout: () {
              if (!disposed &&
                  (peerStates[remoteId] ==
                          RTCIceConnectionState.RTCIceConnectionStateFailed ||
                      peerStates[remoteId] ==
                          RTCIceConnectionState
                              .RTCIceConnectionStateDisconnected)) {
                onNatFailure(remoteId);
                lastSeenPeerMs[remoteId] = 0;
                onPeerClosed(remoteId);
                unawaited(cleanupPeer(remoteId));
                checkSocketSleepState();
              }
            },
            onRetry: () {
              if (!disposed &&
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
                      targetId: remoteId, data: const {});
                }
              }
            },
          );
        },
      );
    };

    pc.onConnectionState = (RTCPeerConnectionState state) {
      if (disposed) return;
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        peerStates[remoteId] =
            RTCIceConnectionState.RTCIceConnectionStateConnected;
        if (!disposed) {
          onStatesChanged(Map.unmodifiable(Map.from(peerStates)));
        }
      } else if (state == RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
        lastSeenPeerMs[remoteId] = 0;
        onPeerClosed(remoteId);
        unawaited(cleanupPeer(remoteId));
      } else if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        checkSocketSleepState();
      }
    };

    // Route incoming audio stream to hardware speakerphone at full volume (noscall stream preservation pattern)
    pc.onTrack = (RTCTrackEvent ev) {
      if (ev.track.kind == 'audio') {
        final shouldHear = (_currentActiveReciterId == null) ||
            (_currentActiveReciterId == remoteId);
        ev.track.enabled = shouldHear;
        if (ev.streams.isNotEmpty) {
          final streamList = remoteStreams.putIfAbsent(remoteId, () => []);
          for (final s in ev.streams) {
            if (!streamList.any((existing) => existing.id == s.id)) {
              streamList.add(s);
            }
          }
        }
        final list = remoteTracks.putIfAbsent(remoteId, () => []);
        if (!list.any((t) => t.id == ev.track.id)) {
          list.add(ev.track);
        }
        try {
          Helper.setVolume(shouldHear ? 1.0 : 0.0, ev.track);
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
      final isLossy = dc.label?.contains('lossy') == true;
      bindDataChannel(remoteId, dc, isLossy: isLossy);
    };

    return pc;
  }

  Future<void> triggerIceRestart(String remoteId) {
    return runPeerExclusive(
        remoteId, () => triggerIceRestartInternal(remoteId));
  }

  Future<void> triggerIceRestartInternal(String remoteId) async {
    final pc = peers[remoteId];
    if (pc == null || disposed) return;
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
            final dcRel = await pc.createDataChannel(
              'maglis_reliable',
              RTCDataChannelInit()
                ..ordered = true
                ..binaryType = 'binary',
            );
            bindDataChannel(remoteId, dcRel, isLossy: false);
          } catch (_) {}
        }
        if (lossyChannels[remoteId] == null ||
            lossyChannels[remoteId]!.state !=
                RTCDataChannelState.RTCDataChannelOpen) {
          try {
            final dcLossy = await pc.createDataChannel(
              'maglis_lossy',
              RTCDataChannelInit()
                ..ordered = false
                ..maxRetransmits = 0
                ..binaryType = 'binary',
            );
            bindDataChannel(remoteId, dcLossy, isLossy: true);
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
      Timer(const Duration(milliseconds: 2500), () {
        isRestartInProgress[remoteId] = false;
      });
    }
  }

  Future<void> recoverDataChannel(String remoteId) {
    return runPeerExclusive(
        remoteId, () => recoverDataChannelInternal(remoteId));
  }

  Future<void> recoverDataChannelInternal(String remoteId) async {
    if (disposed || !peers.containsKey(remoteId)) return;
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
        final curRelDc = channels[remoteId];
        final curLossyDc = lossyChannels[remoteId];
        final bool relOk = curRelDc != null &&
            curRelDc.state == RTCDataChannelState.RTCDataChannelOpen;
        final bool lossyOk = curLossyDc != null &&
            curLossyDc.state == RTCDataChannelState.RTCDataChannelOpen;

        if (relOk && lossyOk) return;

        if (!relOk) {
          final dc = await pc.createDataChannel(
            'maglis_reliable',
            RTCDataChannelInit()
              ..ordered = true
              ..binaryType = 'binary',
          );
          bindDataChannel(remoteId, dc, isLossy: false);
        }
        if (!lossyOk) {
          final dcLossy = await pc.createDataChannel(
            'maglis_lossy',
            RTCDataChannelInit()
              ..ordered = false
              ..maxRetransmits = 0
              ..binaryType = 'binary',
          );
          bindDataChannel(remoteId, dcLossy, isLossy: true);
        }

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

  void bindDataChannel(String remoteId, RTCDataChannel dc,
      {bool isLossy = false}) {
    if (isLossy) {
      lossyChannels[remoteId] = dc;
    } else {
      channels[remoteId] = dc;
    }
    try {
      dc.bufferedAmountLowThreshold = 64 * 1024;
    } catch (_) {}
    dc.onBufferedAmountLow = (_) {
      if (!isLossy && !disposed) {
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

    void onChannelOpen() {
      lastSeenPeerMs[remoteId] = DateTime.now().millisecondsSinceEpoch;
      peerStates[remoteId] =
          RTCIceConnectionState.RTCIceConnectionStateConnected;
      if (!disposed) {
        onStatesChanged(Map.unmodifiable(Map.from(peerStates)));
      }
      checkSocketSleepState();

      if (!isLossy) {
        try {
          dc.send(RTCDataChannelMessage(onBuildSnapshot().pack()));
        } catch (_) {}

        // Hedged 350ms follow-up snapshot guarantees state synchronization
        // even if initial frame was sent before remote listener binding completed.
        Future.delayed(const Duration(milliseconds: 350), () {
          if (!disposed && dc.state == RTCDataChannelState.RTCDataChannelOpen) {
            try {
              dc.send(RTCDataChannelMessage(onBuildSnapshot().pack()));
            } catch (_) {}
          }
        });

        final activeOthers =
            peers.keys.where((p) => p != remoteId && p != localPeerId).toList();
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
        if (pendingVitalPackets.isNotEmpty) {
          for (final vital in List<String>.from(pendingVitalPackets)) {
            try {
              dc.send(RTCDataChannelMessage(vital));
            } catch (_) {}
          }
          pendingVitalPackets.clear();
        }
      }
    }

    // Attach dc.onMessage FIRST before inspecting dc.state or triggering onChannelOpen
    dc.onMessage = (RTCDataChannelMessage msg) {
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
      if (state == RTCDataChannelState.RTCDataChannelOpen) {
        onChannelOpen();
      } else if (state == RTCDataChannelState.RTCDataChannelClosed) {
        if (isLossy) {
          lossyChannels.remove(remoteId);
        } else {
          channels.remove(remoteId);
          if (!disposed && peers.containsKey(remoteId)) {
            final peerState = peerStates[remoteId];
            final isConnected = peerState ==
                    RTCIceConnectionState.RTCIceConnectionStateConnected ||
                peerState ==
                    RTCIceConnectionState.RTCIceConnectionStateCompleted;
            if (isConnected) {
              unawaited(recoverDataChannel(remoteId));
            }
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
            final list = peersList.map((e) => e.toString()).toList();
            onPeerListDiscovered(list);
          }
        } catch (_) {}
        return;
      }

      final pkt = MaglisPacket.unpack(raw);
      handleIncomingPacket(pkt);
    } catch (_) {}
  }

  void handleIncomingPacket(MaglisPacket pkt) {
    try {
      if (pkt.senderId.isNotEmpty && pkt.senderId != localPeerId) {
        lastSeenPeerMs[pkt.senderId] = DateTime.now().millisecondsSinceEpoch;
        if (peerStates[pkt.senderId] !=
            RTCIceConnectionState.RTCIceConnectionStateConnected) {
          peerStates[pkt.senderId] =
              RTCIceConnectionState.RTCIceConnectionStateConnected;
          if (!disposed) {
            onStatesChanged(Map.unmodifiable(Map.from(peerStates)));
          }
        }
      }

      if (pkt.type == MaglisPacketType.ping) {
        dispatchRaw(jsonEncode({
          't': 5,
          'u': localPeerId,
          'm': pkt.ts,
        }));
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

      if (pkt.type == MaglisPacketType.floorClaim ||
          pkt.type == MaglisPacketType.snapshot) {
        lastSeq.remove(pkt.senderId);
      }

      final prev = lastSeq[pkt.senderId] ?? -1;
      final bool isVerseChange =
          pkt.type == MaglisPacketType.recitationUpdate &&
              (pkt.surah != (lastSeenSurah[pkt.senderId] ?? -1) ||
                  pkt.ayah != (lastSeenAyah[pkt.senderId] ?? -1));

      if (pkt.type == MaglisPacketType.recitationUpdate &&
          !isVerseChange &&
          pkt.seq <= prev &&
          (prev - pkt.seq) < 50000) {
        return;
      }
      lastSeq[pkt.senderId] = pkt.seq;
      lastSeenSurah[pkt.senderId] = pkt.surah;
      lastSeenAyah[pkt.senderId] = pkt.ayah;
      onPacketReceived(pkt);
    } catch (_) {}
  }

  void dispatchReliable(String raw) {
    final msg = RTCDataChannelMessage(raw);
    bool anyChannelOpen = false;

    for (final entry in List<MapEntry<String, RTCDataChannel>>.from(channels.entries)) {
      final dc = entry.value;
      if (dc.state == RTCDataChannelState.RTCDataChannelOpen) {
        anyChannelOpen = true;
        final buf = dc.bufferedAmount ?? 0;
        if (buf <= maxDataChannelBufferedAmount) {
          try {
            dc.send(msg);
          } catch (_) {}
        } else {
          queueVitalPacket(raw);
        }
      }
    }

    if (!anyChannelOpen) {
      queueVitalPacket(raw);
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

  void dispatchLossy(String raw) {
    final msg = RTCDataChannelMessage(raw);

    for (final remoteId in List<String>.from(peers.keys)) {
      final lossyDc = lossyChannels[remoteId];
      if (lossyDc != null &&
          lossyDc.state == RTCDataChannelState.RTCDataChannelOpen) {
        final buf = lossyDc.bufferedAmount ?? 0;
        if (buf <= maxDataChannelBufferedAmount) {
          try {
            lossyDc.send(msg);
            continue;
          } catch (_) {}
        } else {
          continue;
        }
      }

      final relDc = channels[remoteId];
      if (relDc != null &&
          relDc.state == RTCDataChannelState.RTCDataChannelOpen) {
        final buf = relDc.bufferedAmount ?? 0;
        if (buf <= maxDataChannelBufferedAmount) {
          try {
            relDc.send(msg);
          } catch (_) {}
        }
      }
    }
  }

  void dispatchReliableBinary(Uint8List bytes) {
    final msg = RTCDataChannelMessage.fromBinary(bytes);
    for (final entry in List<MapEntry<String, RTCDataChannel>>.from(channels.entries)) {
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

  void dispatchLossyBinary(Uint8List bytes) {
    final msg = RTCDataChannelMessage.fromBinary(bytes);
    for (final remoteId in List<String>.from(peers.keys)) {
      final lossyDc = lossyChannels[remoteId];
      if (lossyDc != null &&
          lossyDc.state == RTCDataChannelState.RTCDataChannelOpen) {
        final buf = lossyDc.bufferedAmount ?? 0;
        if (buf <= maxDataChannelBufferedAmount) {
          try {
            lossyDc.send(msg);
            continue;
          } catch (_) {}
        }
      }

      final relDc = channels[remoteId];
      if (relDc != null &&
          relDc.state == RTCDataChannelState.RTCDataChannelOpen) {
        final buf = relDc.bufferedAmount ?? 0;
        if (buf <= maxDataChannelBufferedAmount) {
          try {
            relDc.send(msg);
          } catch (_) {}
        }
      }
    }
  }

  void dispatchRaw(String raw, {bool? isVital}) {
    final bool vital = isVital ??
        (raw.startsWith('{"t":0,') ||
            raw.startsWith('{"t":2,') ||
            raw.startsWith('{"t":3,') ||
            raw.startsWith('{"t":4,') ||
            raw.startsWith('{"t":5,') ||
            raw.contains('"t":99'));

    if (vital) {
      dispatchReliable(raw);
    } else {
      dispatchLossy(raw);
    }
  }

  Future<void> handleOffer(
    String remoteId,
    String sdp, {
    bool isIceRestart = false,
    bool isDataChannelRecovery = false,
  }) async {
    return runPeerExclusive(remoteId, () async {
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
        final pc = peers[remoteId] ?? await createPeerInternal(remoteId);
        final curSigState = await pc.getSignalingState() ?? pc.signalingState;
        if (curSigState == RTCSignalingState.RTCSignalingStateHaveLocalOffer) {
          if (localPeerId.compareTo(remoteId) > 0) {
            try {
              await pc
                  .setRemoteDescription(RTCSessionDescription('', 'rollback'));
            } catch (_) {}
          } else {
            return;
          }
        }

        if (localStream != null) {
          for (final track in localStream!.getAudioTracks()) {
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
      } finally {
        negotiatingPeers.remove(remoteId);
      }
    });
  }

  Future<void> handleAnswer(String remoteId, String sdp) async {
    return runPeerExclusive(remoteId, () async {
      final pc = peers[remoteId];
      if (pc == null || disposed) return;
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
    final isVital = packet.type == MaglisPacketType.floorClaim ||
        packet.type == MaglisPacketType.floorRelease ||
        packet.type == MaglisPacketType.snapshot ||
        (packet.errors != null && packet.errors!.isNotEmpty) ||
        packet.activeWord == null ||
        packet.greenWords.isNotEmpty ||
        packet.yellowWords.isNotEmpty ||
        packet.redWords.isNotEmpty;

    final bytes = packet.packBinary();
    if (isVital) {
      dispatchReliableBinary(bytes);
    } else {
      dispatchLossyBinary(bytes);
    }
  }

  Future<void> setMicMuted(bool muted) async {
    isMicMuted = muted;
    if (!muted &&
        (localStream == null || localStream!.getAudioTracks().isEmpty)) {
      try {
        localStream = await navigator.mediaDevices.getUserMedia(
          MaglisMediaHelper.buildAudioConstraints(),
        );
        for (final entry in List<MapEntry<String, RTCPeerConnection>>.from(peers.entries)) {
          localStream?.getAudioTracks().forEach((track) {
            track.enabled = true;
            try {
              entry.value.addTrack(track, localStream!);
            } catch (_) {}
          });
          final isInitiator = localPeerId.compareTo(entry.key) < 0;
          if (isInitiator) {
            triggerIceRestart(entry.key);
          } else {
            sendSignal('reconnect_request',
                targetId: entry.key, data: const {});
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
    for (final entry in List<MapEntry<String, RTCPeerConnection>>.from(peers.entries)) {
      final state = peerStates[entry.key];
      if (state == RTCIceConnectionState.RTCIceConnectionStateFailed ||
          state == RTCIceConnectionState.RTCIceConnectionStateDisconnected) {
        final isInitiator = localPeerId.compareTo(entry.key) < 0;
        if (isInitiator) {
          unawaited(triggerIceRestart(entry.key));
        } else {
          unawaited(sendSignal('reconnect_request',
              targetId: entry.key, data: const {}));
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
      final lossyDc = lossyChannels.remove(peerId);
      if (lossyDc != null) {
        lossyDc.onDataChannelState = null;
        lossyDc.onMessage = null;
        try {
          if (lossyDc.state == RTCDataChannelState.RTCDataChannelOpen) {
            await lossyDc.close();
          }
        } catch (_) {}
      }
    } catch (_) {}

    try {
      final dc = channels.remove(peerId);
      if (dc != null) {
        dc.onDataChannelState = null;
        dc.onMessage = null;
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
    for (final window in List<MaglisPeerRecoveryWindow>.from(recoveryWindows.values)) {
      window.cancel();
    }
    recoveryWindows.clear();
    sentCandidateKeys.clear();
    reconnectAttempts.clear();
    isRestartInProgress.clear();
    peerLatency.clear();
    pendingOutboundCandidates.clear();
    pendingVitalPackets.clear();
    renegotiatePending.clear();
    peerLockChains.clear();

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
    for (final dc in List<RTCDataChannel>.from(lossyChannels.values)) {
      try {
        dc.onDataChannelState = null;
        dc.onMessage = null;
      } catch (_) {}
    }
    lossyChannels.clear();

    for (final dc in List<RTCDataChannel>.from(channels.values)) {
      try {
        dc.onDataChannelState = null;
        dc.onMessage = null;
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
    remoteStreams.clear();
    remoteTracks.clear();
  }
}

/// A bounded recovery attempt for an individual WebRTC peer connection (noscall pattern).
/// - Fixed grace period (15s deadline)
/// - Paced retry timer (2s)
/// - Repeated disconnect events cannot extend or delay the deadline.
class MaglisPeerRecoveryWindow {
  static const Duration defaultGracePeriod = Duration(seconds: 15);
  static const Duration defaultRetryDelay = Duration(seconds: 2);

  final Duration gracePeriod;
  final Duration retryDelay;

  Timer? _deadline;
  Timer? _retry;

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
  }

  void cancel() {
    _deadline?.cancel();
    _retry?.cancel();
    _deadline = null;
    _retry = null;
  }
}

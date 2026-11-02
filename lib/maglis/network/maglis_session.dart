import 'dart:async';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import '../maglis_core.dart';
import '../maglis_highlight_store.dart';
import '../maglis_network.dart';

/// MaglisActiveSession
///
/// Encapsulates the live state of an active Maglis room session (Noscall pattern).
/// Instantiated fresh upon room entry and disposed completely upon room exit,
/// guaranteeing zero state leakage, zero lingering timers, and zero memory leaks.
class MaglisActiveSession {
  final String roomCode;
  final String localPeerId;
  final bool isHost;
  final MaglisNetworkEngine net;
  final MaglisHighlightStore highlightStore = MaglisHighlightStore();

  StreamSubscription<MaglisPacket>? pktSub;
  StreamSubscription<Map<String, RTCIceConnectionState>>? stateSub;
  StreamSubscription<String>? natSub;
  StreamSubscription<int>? participantSub;
  Timer? recitationSyncTimer;
  Timer? floorClaimHedgeTimer1;
  Timer? floorClaimHedgeTimer2;

  int seq = 0;
  String? activeReciterId;
  String? natFailedPeer;
  Map<String, RTCIceConnectionState> peers = {};

  /// Local epoch timestamp (ms) when the local user last pressed Record (claimFloor).
  /// Used to distinguish true <500ms simultaneous button-press glare from deliberate takeovers
  /// without relying on remote peer wall-clock synchronization.
  int localFloorClaimTs = 0;

  /// Local epoch timestamp (ms) when the most recent floor claim (local or remote) was accepted.
  /// Used to fence out stale in-flight recitationUpdate packets from a preempted reciter.
  int lastFloorClaimTs = 0;

  /// Origin packet timestamp (`pkt.ts`) of the most recently accepted floorClaim.
  /// Deduplicates dual-path (DataChannel + Nostr + hedged re-transmits) arrival even if the
  /// reciter has already advanced to the next ayah before the slower copy arrives.
  int lastFloorClaimRemoteOriginTs = 0;

  /// Local timestamp (ms) of the last preemptive floorClaim re-assertion sent to silence
  /// a previous reciter whose in-flight recitationUpdate packets are still arriving.
  int lastPreemptionRemindTs = 0;

  int remotePage;
  int remoteSurah;
  int remoteAyah;
  int? remoteWord;
  List<int> remoteGreenWords = const [];
  List<int> remoteYellowWords = const [];
  List<int> remoteRedWords = const [];

  int? lastBroadcastPage;
  int? lastBroadcastSurah;
  int? lastBroadcastAyah;
  int? lastBroadcastWord;

  MaglisActiveSession({
    required this.roomCode,
    required this.localPeerId,
    required this.isHost,
    required this.net,
    this.remotePage = 1,
    this.remoteSurah = 1,
    this.remoteAyah = 1,
  });

  bool get isLocalReciting => activeReciterId == localPeerId;
  bool get isRemoteReciting =>
      activeReciterId != null && activeReciterId != localPeerId;

  Future<void> dispose() async {
    recitationSyncTimer?.cancel();
    recitationSyncTimer = null;
    floorClaimHedgeTimer1?.cancel();
    floorClaimHedgeTimer1 = null;
    floorClaimHedgeTimer2?.cancel();
    floorClaimHedgeTimer2 = null;
    localFloorClaimTs = 0;
    lastFloorClaimTs = 0;
    lastFloorClaimRemoteOriginTs = 0;
    lastPreemptionRemindTs = 0;
    await pktSub?.cancel();
    await stateSub?.cancel();
    await natSub?.cancel();
    await participantSub?.cancel();
    pktSub = null;
    stateSub = null;
    natSub = null;
    participantSub = null;
    try {
      await net.dispose();
    } catch (_) {}
    highlightStore.clearAll();
  }
}
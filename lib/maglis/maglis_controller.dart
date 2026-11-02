import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:recite_quran/recite_quran.dart';
import '../state/app_state.dart';
import 'maglis_core.dart';
import 'maglis_highlight_store.dart';
import 'maglis_network.dart';
import '../ui/widgets/mushaf/mushaf_provider.dart';

class MaglisController extends ChangeNotifier {
  MaglisController._();
  static final MaglisController instance = MaglisController._();

  void Function(int page, int surah, int ayah)? onSyncMushafUI;
  void Function(int surah, int ayah)? onRemoteFloorClaimed;
  VoidCallback? onSessionEnded;

  MaglisActiveSession? _session;
  String _fallbackPeerId = MaglisCrypto.randomHex32().substring(0, 10);

  final ChangeNotifier _sessionNotifier = ChangeNotifier();
  Listenable get sessionListenable => _sessionNotifier;

  void _notifySessionChanged() {
    _sessionNotifier.notifyListeners();
  }

  // Compact 32-bit integer key: ((surah & 0xFF) << 20) | ((ayah & 0xFFF) << 8) | (word0 & 0xFF)
  static int wordKey(int surah, int ayah, int word0) =>
      MaglisHighlightStore.wordKey(surah, ayah, word0);

  /// Ultra-compact structured error map for minimum bandwidth over WebRTC.
  static Map<String, dynamic> compactErrorMap(ReciterError e) =>
      MaglisHighlightStore.compactErrorMap(e);

  List<ReciterError>? getWordErrors(int surah, int ayah, int word0) =>
      _session?.highlightStore.getWordErrors(surah, ayah, word0);

  int? getWordHighlight(int surah, int ayah, int word0) =>
      _session?.highlightStore.getWordHighlight(surah, ayah, word0);

  int? getCumulativeHighlightByKey(int key) =>
      _session?.highlightStore.getCumulativeHighlightByKey(key);

  void recordWordHighlight(int surah, int ayah, int word0, int color) {
    _session?.highlightStore.recordWordHighlight(surah, ayah, word0, color);
  }

  bool get hasCumulativeHighlights =>
      _session?.highlightStore.hasCumulativeHighlights ?? false;
  int get cumulativeVersion => _session?.highlightStore.cumulativeVersion ?? 0;

  /// Clears cumulative session highlights from [startSurah, startAyah] onwards when recording starts.
  /// Any verse coming before [startSurah, startAyah] strictly keeps its highlights.
  void clearHighlightsFrom(int startSurah, int startAyah) {
    final s = _session;
    if (s == null) return;
    s.highlightStore.clearHighlightsFrom(startSurah, startAyah);
    s.lastBroadcastPage = null;
    s.lastBroadcastSurah = null;
    s.lastBroadcastAyah = null;
    s.lastBroadcastWord = null;
    notifyListeners();
  }

  void _onPeerJoined(String peerId) {
    AppState.instance.showMaglisPeerJoinedBanner();
    _notifySessionChanged();
  }

  void _onPeerLeft(String peerId) {
    final s = _session;
    if (s == null) return;
    bool reciterLeft = false;
    if (s.activeReciterId == peerId) {
      s.activeReciterId = null;
      s.remoteWord = null;
      s.net.updateActiveFloor(null);
      reciterLeft = true;
    }
    AppState.instance.showMaglisPeerLeftBanner();
    _notifySessionChanged();
    if (reciterLeft) {
      notifyListeners();
    }
  }

  bool get inSession => _session != null;
  String get roomCode => _session?.roomCode ?? '';
  String get localPeerId => _session?.localPeerId ?? _fallbackPeerId;
  bool get isHost => _session?.isHost ?? false;
  String? get activeReciterId => _session?.activeReciterId;
  String? get natFailedPeer => _session?.natFailedPeer;
  int get participantCount => _session?.net.participantCount ?? 1;
  bool get isLocalReciting => inSession && _session!.isLocalReciting;
  bool get isRemoteReciting => inSession && _session!.isRemoteReciting;
  bool get isMicMuted => _session?.net.isMicMuted ?? true;
  Map<String, MaglisPeerDiagnostics> get peerDiagnostics =>
      _session?.net.peerDiagnostics ?? const {};

  Future<void> setMicMuted(bool muted) async {
    await _session?.net.setMicMuted(muted);
    _notifySessionChanged();
    notifyListeners();
  }

  Future<void> toggleMic() async {
    final next = !isMicMuted;
    await setMicMuted(next);
  }

  int get remotePage => _session?.remotePage ?? 1;
  int get remoteSurah => _session?.remoteSurah ?? 1;
  int get remoteAyah => _session?.remoteAyah ?? 1;
  int? get remoteWord => _session?.remoteWord;
  List<int> get remoteGreenWords => _session?.remoteGreenWords ?? const [];
  List<int> get remoteYellowWords => _session?.remoteYellowWords ?? const [];
  List<int> get remoteRedWords => _session?.remoteRedWords ?? const [];
  Map<String, RTCIceConnectionState> get peers =>
      _session != null ? Map.unmodifiable(_session!.peers) : const {};

  /// Verifies room existence and capacity before connecting.
  Future<MaglisJoinResult> verifyAndJoinRoom({
    required String code,
    required int page,
    required int surah,
    required int ayah,
  }) async {
    final check = await MaglisNetworkEngine.verifyRoomJoinable(code);
    if (check != MaglisJoinResult.success) {
      return check;
    }
    final started = await startSession(
      code: code,
      isHost: false,
      page: page,
      surah: surah,
      ayah: ayah,
    );
    return started ? MaglisJoinResult.success : MaglisJoinResult.error;
  }

  Future<bool> startSession({
    String? code,
    bool isHost = true,
    int page = 1,
    int surah = 1,
    int ayah = 1,
  }) async {
    try {
      final granted = await MaglisPlatform.requestPermissions();
      if (!granted) return false;

      await leaveSession(resetHardwareAudio: false, restoreMode: false);

      final sessionPeerId = MaglisCrypto.randomHex32().substring(0, 10);
      _fallbackPeerId = sessionPeerId;
      final sessionRoomCode = (code != null && code.trim().isNotEmpty)
          ? code.trim()
          : (10000 + Random.secure().nextInt(90000)).toString();

      final net = MaglisNetworkEngine(
        roomCode: sessionRoomCode,
        localPeerId: sessionPeerId,
        isHost: isHost,
        onBuildSnapshot: _buildSnapshot,
        onParticipantJoined: _onPeerJoined,
        onParticipantLeft: _onPeerLeft,
      );

      final session = MaglisActiveSession(
        roomCode: sessionRoomCode,
        localPeerId: sessionPeerId,
        isHost: isHost,
        net: net,
        remotePage: page,
        remoteSurah: surah,
        remoteAyah: ayah,
      );
      _session = session;

      session.pktSub = net.onPacket.listen(_handleIncomingPacket);
      session.stateSub = net.onPeerStates.listen((map) {
        if (_session != session) return;
        session.peers = map;
        _notifySessionChanged();
      });
      session.natSub = net.onNatFailure.listen((peerId) {
        if (_session != session) return;
        if (session.natFailedPeer != peerId) {
          session.natFailedPeer = peerId;
          _notifySessionChanged();
        }
      });
      session.participantSub = net.onParticipantCount.listen((_) {
        if (_session != session) return;
        _notifySessionChanged();
      });

      // Connect and establish room presence across relays (throws if offline or unreachable)
      await net.start();

      // Only enter session UI once room connection is verified!
      final mappedPage = MushafProvider.instance.getPageForAyah(
            AppState.instance.lastSurah,
            AppState.instance.lastAyah,
          ) ??
          page;
      AppState.instance.enterMaglisSession(mappedPage);

      _notifySessionChanged();
      notifyListeners();
      return true;
    } catch (e, st) {
      debugPrint('Maglis startSession failed: $e\n$st');
      await leaveSession(resetHardwareAudio: true, restoreMode: false);
      return false;
    }
  }

  MaglisPacket _buildSnapshot() {
    final s = _session;
    return MaglisPacket(
      type: MaglisPacketType.snapshot,
      seq: s != null ? ++s.seq : 1,
      senderId: localPeerId,
      page: s?.remotePage ?? 1,
      surah: s?.remoteSurah ?? 1,
      ayah: s?.remoteAyah ?? 1,
      activeWord: s?.remoteWord,
      greenWords: s?.remoteGreenWords ?? const [],
      yellowWords: s?.remoteYellowWords ?? const [],
      redWords: s?.remoteRedWords ?? const [],
      activeReciterId: s?.activeReciterId,
      cumulative: s?.highlightStore.buildSnapshotCumulativeMap(),
      errors: s?.highlightStore.buildSnapshotErrorsMap(),
      ts: DateTime.now().millisecondsSinceEpoch,
    );
  }

  void _handleIncomingPacket(MaglisPacket pkt) {
    final s = _session;
    if (s == null) return;

    if (pkt.type == MaglisPacketType.ping ||
        pkt.type == MaglisPacketType.pong) {
      return;
    }

    final now = DateTime.now().millisecondsSinceEpoch;

    // 1. Preemption & Local-Reciter Shield:
    // Evaluate BEFORE merging words/errors so stale in-flight packets from a
    // preempted reciter never overwrite the new reciter's cleared highlights.
    if (s.isLocalReciting && pkt.type != MaglisPacketType.floorClaim) {
      if (pkt.activeReciterId != null && pkt.activeReciterId != s.localPeerId) {
        final localClaimAge = now - s.localFloorClaimTs;
        if (localClaimAge >= 0 && localClaimAge < 1500) {
          // Stale in-flight packet from the previous reciter sent before our
          // floorClaim reached them. Ignore completely.
          return;
        }
        // Fail-safe: Another peer is genuinely reciting after the grace window
        // (e.g., their floorClaim packet was dropped on a lossy link). Yield floor!
        s.recitationSyncTimer?.cancel();
        s.recitationSyncTimer = null;
        s.activeReciterId = pkt.activeReciterId;
        s.lastFloorClaimTs = now;
        s.net.updateActiveFloor(pkt.activeReciterId);
        onRemoteFloorClaimed?.call(pkt.surah, pkt.ayah);
      } else {
        // Local reciter drives their own UI from local engine.
        // Only merge background cumulative history from initial snapshots if present.
        if (pkt.type == MaglisPacketType.snapshot &&
            pkt.cumulative != null &&
            pkt.cumulative!.isNotEmpty) {
          if (s.highlightStore.mergeCumulative(pkt.cumulative!)) {
            notifyListeners();
          }
        }
        return;
      }
    }

    // 2. Listener Preemption Fence:
    // If Peer B just claimed the floor, drop any late in-flight recitationUpdate
    // packets arriving from Peer A within the 1500ms transition window.
    if (pkt.type == MaglisPacketType.recitationUpdate &&
        s.activeReciterId != null &&
        pkt.senderId != s.activeReciterId &&
        (now - s.lastFloorClaimTs) >= 0 &&
        (now - s.lastFloorClaimTs) < 1500) {
      return;
    }

    // 3. Deduplicate dual-path (DataChannel + Nostr fast signal) arrival for the same floorClaim
    // BEFORE merging words or clearing highlights so a late Nostr floor_claim copy never
    // rolls back the verse position or wipes highlights after the reciter already advanced.
    if (pkt.type == MaglisPacketType.floorClaim) {
      final bool isSameClaimByTimestamp =
          pkt.ts > 0 && pkt.ts == s.lastFloorClaimRemoteOriginTs;
      final bool isRecentDuplicateFromActiveReciter =
          s.activeReciterId == pkt.senderId &&
              (isSameClaimByTimestamp ||
                  (s.remoteSurah == pkt.surah &&
                      s.remoteAyah == pkt.ayah &&
                      (now - s.lastFloorClaimTs).abs() < 2500));
      if (isRecentDuplicateFromActiveReciter) {
        return;
      }
    }

    // 4. Merge cumulative and live words into persistent room highlights with fast radix decoding
    bool cumulativeChanged = false;
    if (pkt.cumulative != null && pkt.cumulative!.isNotEmpty) {
      if (s.highlightStore.mergeCumulative(pkt.cumulative!)) {
        cumulativeChanged = true;
      }
    }
    if (s.highlightStore.mergeWords(
      pkt.surah,
      pkt.ayah,
      greenWords: pkt.greenWords,
      yellowWords: pkt.yellowWords,
      redWords: pkt.redWords,
    )) {
      cumulativeChanged = true;
    }

    if (pkt.errors != null && pkt.errors!.isNotEmpty) {
      s.highlightStore.mergeErrors(pkt.surah, pkt.ayah, pkt.errors!);
    }

    switch (pkt.type) {
      case MaglisPacketType.floorClaim:
        if (pkt.senderId != s.localPeerId) {
          if (s.isLocalReciting) {
            // TRUE GLARE DETECTION (Clock-Skew Immune):
            // Measure how long the LOCAL user has been reciting using strictly local time.
            // Only apply deterministic tiebreak if the local user ALSO pressed Record
            // within the last 500ms (true simultaneous button press).
            // For deliberate takeovers (local user has been recording >= 500ms),
            // the new remote claim ALWAYS wins regardless of peer ID ordering.
            final localRecitingAge = now - s.localFloorClaimTs;
            final isSimultaneousGlare =
                localRecitingAge >= 0 && localRecitingAge < 500;

            if (isSimultaneousGlare) {
              final localWins = s.localPeerId.compareTo(pkt.senderId) < 0;
              if (localWins) {
                s.net.sendPacket(
                  MaglisPacket(
                    type: MaglisPacketType.floorClaim,
                    seq: ++s.seq,
                    senderId: s.localPeerId,
                    page: s.remotePage,
                    surah: s.remoteSurah,
                    ayah: s.remoteAyah,
                    activeReciterId: s.localPeerId,
                    ts: now,
                  ),
                );
                return;
              }
            }
            // DELIBERATE TAKEOVER or lost glare: yield floor to the remote peer
            s.recitationSyncTimer?.cancel();
            s.recitationSyncTimer = null;
          }
        }
        s.activeReciterId = pkt.senderId;
        s.lastFloorClaimTs = now;
        s.lastFloorClaimRemoteOriginTs = pkt.ts;
        s.net.updateActiveFloor(pkt.senderId);
        s.remotePage = pkt.page;
        s.remoteSurah = pkt.surah;
        s.remoteAyah = pkt.ayah;
        s.remoteWord = pkt.activeWord;
        s.remoteGreenWords = List<int>.from(pkt.greenWords)..sort();
        s.remoteYellowWords = List<int>.from(pkt.yellowWords)..sort();
        s.remoteRedWords = List<int>.from(pkt.redWords)..sort();

        if (pkt.senderId != s.localPeerId) {
          onRemoteFloorClaimed?.call(pkt.surah, pkt.ayah);
        }
        clearHighlightsFrom(pkt.surah, pkt.ayah);

        _notifySessionChanged();
        notifyListeners();
        onSyncMushafUI?.call(pkt.page, pkt.surah, pkt.ayah);
        break;

      case MaglisPacketType.floorRelease:
        if (s.activeReciterId == pkt.senderId) {
          s.activeReciterId = null;
          s.remoteWord = null;
          s.net.updateActiveFloor(null);
          _notifySessionChanged();
          notifyListeners();
        }
        break;

      case MaglisPacketType.recitationUpdate:
        final bool pageChanged = s.remotePage != pkt.page;
        final bool ayahChanged =
            pkt.surah != s.remoteSurah || pkt.ayah != s.remoteAyah;

        final newGreenList = List<int>.from(pkt.greenWords)..sort();
        final newYellowList = List<int>.from(pkt.yellowWords)..sort();
        final newRedList = List<int>.from(pkt.redWords)..sort();

        final bool wordsChanged =
            !listEquals(s.remoteGreenWords, newGreenList) ||
                !listEquals(s.remoteYellowWords, newYellowList) ||
                !listEquals(s.remoteRedWords, newRedList);

        final bool posChanged = pageChanged ||
            ayahChanged ||
            s.remoteWord != pkt.activeWord ||
            s.activeReciterId != pkt.senderId;

        if (!posChanged && !wordsChanged && !cumulativeChanged) {
          return;
        }

        final bool reciterChanged = s.activeReciterId != pkt.senderId;
        s.activeReciterId = pkt.senderId;
        s.net.updateActiveFloor(pkt.senderId);
        s.remotePage = pkt.page;
        s.remoteSurah = pkt.surah;
        s.remoteAyah = pkt.ayah;
        s.remoteWord = pkt.activeWord;
        s.remoteGreenWords = newGreenList;
        s.remoteYellowWords = newYellowList;
        s.remoteRedWords = newRedList;

        if (reciterChanged) {
          _notifySessionChanged();
        }
        notifyListeners();
        if (pageChanged) {
          onSyncMushafUI?.call(pkt.page, pkt.surah, pkt.ayah);
        }
        break;

      case MaglisPacketType.snapshot:
        if (pkt.activeReciterId != null) {
          s.activeReciterId = pkt.activeReciterId;
          s.net.updateActiveFloor(pkt.activeReciterId);
          s.remotePage = pkt.page;
          s.remoteSurah = pkt.surah;
          s.remoteAyah = pkt.ayah;
          s.remoteWord = pkt.activeWord;
          s.remoteGreenWords = List<int>.from(pkt.greenWords)..sort();
          s.remoteYellowWords = List<int>.from(pkt.yellowWords)..sort();
          s.remoteRedWords = List<int>.from(pkt.redWords)..sort();
          _notifySessionChanged();
          notifyListeners();
          onSyncMushafUI?.call(pkt.page, pkt.surah, pkt.ayah);
        } else {
          if (s.isLocalReciting) break;
          if (cumulativeChanged || s.highlightStore.hasCumulativeHighlights) {
            notifyListeners();
          }
        }
        break;

      case MaglisPacketType.ping:
      case MaglisPacketType.pong:
        return;
    }
  }

  /// Called when the local user presses Record to start reciting
  Future<void> claimFloor({
    required int page,
    required int surah,
    required int ayah,
  }) async {
    final s = _session;
    if (s == null) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    s.localFloorClaimTs = now;
    s.lastFloorClaimTs = now;
    s.lastFloorClaimRemoteOriginTs = now;
    s.activeReciterId = s.localPeerId;
    s.net.updateActiveFloor(s.localPeerId);
    unawaited(setMicMuted(false));
    s.remotePage = page;
    s.remoteSurah = surah;
    s.remoteAyah = ayah;
    s.remoteWord = null;
    s.remoteGreenWords = const [];
    s.remoteYellowWords = const [];
    s.remoteRedWords = const [];

    s.lastBroadcastPage = null;
    s.lastBroadcastSurah = null;
    s.lastBroadcastAyah = null;
    s.lastBroadcastWord = null;
    s.highlightStore.sentErrorWords.clear();

    final claimSeq = ++s.seq;
    s.net.sendPacket(
      MaglisPacket(
        type: MaglisPacketType.floorClaim,
        seq: claimSeq,
        senderId: s.localPeerId,
        page: page,
        surah: surah,
        ayah: ayah,
        activeReciterId: s.localPeerId,
        ts: now,
      ),
    );
    s.net.sendSignalFast('floor_claim', data: {
      'page': page,
      'surah': surah,
      'ayah': ayah,
      'seq': claimSeq,
      'ts': now,
    });

    // Periodic 2.5s recitation state sync: heals any packet dropped over cellular/VPN
    s.recitationSyncTimer?.cancel();
    int syncTicks = 0;
    s.recitationSyncTimer =
        Timer.periodic(const Duration(milliseconds: 2500), (_) {
      if (_session != s || !s.isLocalReciting) return;
      syncTicks++;
      final bool includeCumulative = (syncTicks % 3 == 0);

      Map<String, int>? cumulativeMap;
      if (includeCumulative && s.highlightStore.hasCumulativeHighlights) {
        cumulativeMap = s.highlightStore.buildSnapshotCumulativeMap();
      }

      final currentVerseErrors = s.highlightStore.buildVerseErrorsMap(
        s.remoteSurah,
        s.remoteAyah,
      );

      s.net.sendPacket(
        MaglisPacket(
          type: MaglisPacketType.recitationUpdate,
          seq: ++s.seq,
          senderId: s.localPeerId,
          page: s.remotePage,
          surah: s.remoteSurah,
          ayah: s.remoteAyah,
          activeWord: s.remoteWord,
          greenWords: s.remoteGreenWords,
          yellowWords: s.remoteYellowWords,
          redWords: s.remoteRedWords,
          activeReciterId: s.localPeerId,
          cumulative: cumulativeMap,
          errors: currentVerseErrors,
          ts: DateTime.now().millisecondsSinceEpoch,
        ),
      );
    });

    _notifySessionChanged();
    notifyListeners();
  }

  /// Called when the local user stops recording
  Future<void> releaseFloor({
    required int page,
    required int surah,
    required int ayah,
  }) async {
    final s = _session;
    if (s == null) return;
    s.recitationSyncTimer?.cancel();
    s.recitationSyncTimer = null;
    if (s.activeReciterId == s.localPeerId) {
      s.activeReciterId = null;
      s.localFloorClaimTs = 0;
      s.net.updateActiveFloor(null);

      s.net.sendPacket(
        MaglisPacket(
          type: MaglisPacketType.floorRelease,
          seq: ++s.seq,
          senderId: s.localPeerId,
          page: page,
          surah: surah,
          ayah: ayah,
          ts: DateTime.now().millisecondsSinceEpoch,
        ),
      );
      _notifySessionChanged();
      notifyListeners();
    }
  }

  /// Broadcasts live recitation position and word highlights (green/yellow/red).
  /// Strictly transmits only DELTAS (newly colored words) and transmits each Tajweed error ONCE
  /// to achieve the absolute minimum packet size and network bandwidth.
  void broadcastRecitation({
    required int page,
    required int surah,
    required int ayah,
    int? activeWord,
    List<int> greenWords = const [],
    List<int> yellowWords = const [],
    List<int> redWords = const [],
    Map<int, List<ReciterError>>? errors,
  }) {
    final s = _session;
    if (s == null || s.activeReciterId != s.localPeerId) return;

    final sortedGreen = List<int>.from(greenWords)..sort();
    final sortedYellow = List<int>.from(yellowWords)..sort();
    final sortedRed = List<int>.from(redWords)..sort();

    // Persist local words into cumulative session highlights with fast integer hashing
    s.highlightStore.mergeWords(
      surah,
      ayah,
      greenWords: sortedGreen,
      yellowWords: sortedYellow,
      redWords: sortedRed,
    );

    // Save local errors into remoteWordErrors as well so local reciter has exact same lookup map
    if (errors != null && errors.isNotEmpty) {
      s.highlightStore.recordLocalErrors(surah, ayah, errors);
    }

    // Serialize active errors strictly once per word BEFORE deduplication check
    // so already-transmitted verse errors do not trigger redundant packets when the reciter pauses.
    final serializedErrors = s.highlightStore.serializeNewErrors(
      surah,
      ayah,
      errors,
    );

    s.remotePage = page;
    s.remoteSurah = surah;
    s.remoteAyah = ayah;
    s.remoteWord = activeWord;

    // Deduplication check:
    final bool pageOrVerseChanged = page != s.lastBroadcastPage ||
        surah != s.lastBroadcastSurah ||
        ayah != s.lastBroadcastAyah;

    final bool cursorMoved = activeWord != s.lastBroadcastWord;

    final bool wordsChanged = !listEquals(sortedGreen, s.remoteGreenWords) ||
        !listEquals(sortedYellow, s.remoteYellowWords) ||
        !listEquals(sortedRed, s.remoteRedWords);

    final bool errorsChanged =
        serializedErrors != null && serializedErrors.isNotEmpty;

    if (!pageOrVerseChanged &&
        !cursorMoved &&
        !wordsChanged &&
        !errorsChanged) {
      return; // Absolute zero packets sent if reciter pauses or stays on current word!
    }

    s.lastBroadcastPage = page;
    s.lastBroadcastSurah = surah;
    s.lastBroadcastAyah = ayah;
    s.lastBroadcastWord = activeWord;

    s.remoteGreenWords = sortedGreen;
    s.remoteYellowWords = sortedYellow;
    s.remoteRedWords = sortedRed;

    s.net.sendPacket(
      MaglisPacket(
        type: MaglisPacketType.recitationUpdate,
        seq: ++s.seq,
        senderId: s.localPeerId,
        page: page,
        surah: surah,
        ayah: ayah,
        activeWord: activeWord,
        greenWords: sortedGreen,
        yellowWords: sortedYellow,
        redWords: sortedRed,
        activeReciterId: s.localPeerId,
        errors: serializedErrors,
        ts: DateTime.now().millisecondsSinceEpoch,
      ),
      throttle: true,
    );
  }

  Future<void> leaveSession({
    bool resetHardwareAudio = true,
    bool restoreMode = true,
  }) async {
    if (restoreMode) {
      try {
        AppState.instance.exitMaglisSession();
      } catch (_) {}
    }

    final oldSession = _session;
    if (oldSession == null) return;
    _session = null;
    onSessionEnded?.call();

    try {
      await oldSession.dispose();
    } catch (_) {
    } finally {
      if (resetHardwareAudio) {
        try {
          await MaglisPlatform.resetAudio();
        } catch (_) {}
      }
      _notifySessionChanged();
      notifyListeners();
    }
  }
}
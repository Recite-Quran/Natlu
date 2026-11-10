import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import '../core/highlighting_controller.dart';
import '../core/app_state.dart';
import 'maglis_core.dart';
import 'maglis_network.dart';
import '../mushaf/mushaf_provider.dart';

class MaglisController extends ChangeNotifier {
  MaglisController._();
  static final MaglisController instance = MaglisController._();

  void Function(int page, int surah, int ayah)? onSyncMushafUI;
  void Function(int surah, int ayah)? onRemoteFloorClaimed;
  VoidCallback? onSessionEnded;
  Map<String, int> Function()? onGetSnapshotCumulativeMap;
  void Function({
    required int surah,
    required int ayah,
    int? activeWord,
    List<int> greenWords,
    List<int> yellowWords,
    List<int> redWords,
    Map<int, List<ReciterError>>? errors,
    Map<String, int>? cumulative,
    bool isReciting,
  })? onRemoteRecitationProgress;

  MaglisActiveSession? _session;
  String _fallbackPeerId = MaglisCrypto.randomHex32().substring(0, 10);

  final ChangeNotifier _sessionNotifier = ChangeNotifier();
  Listenable get sessionListenable => _sessionNotifier;

  void _notifySessionChanged() {
    _sessionNotifier.notifyListeners();
  }

  // Compact 32-bit integer key: delegated to canonical QuranCoordinate
  static int wordKey(int surah, int ayah, int word0) =>
      QuranCoordinate.packWordKey(surah, ayah, word0);

  /// Ultra-compact structured error map for minimum bandwidth over WebRTC.
  static Map<String, dynamic> compactErrorMap(ReciterError e) =>
      MaglisPacket.compactErrorMap(e);

  /// Clears broadcast state when local floor claim begins.
  void clearHighlightsFrom(int startSurah, int startAyah) {
    final s = _session;
    if (s == null) return;
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
      cumulative: onGetSnapshotCumulativeMap?.call(),
      errors: null,
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
    // preempted reciter (or a passive listener's DataChannel snapshot) never
    // overwrite the new reciter's cleared highlights or kill their active recording.
    if (s.isLocalReciting && pkt.type != MaglisPacketType.floorClaim) {
      // Background connection snapshots must NEVER preempt the local reciter.
      if (pkt.type == MaglisPacketType.snapshot) {
        if (pkt.cumulative != null && pkt.cumulative!.isNotEmpty) {
          final currentKeyPrefix =
              QuranCoordinate.packWordKey(s.remoteSurah, s.remoteAyah, 0);
          final priorOnly = <String, int>{};
          pkt.cumulative!.forEach((k, v) {
            final parsed = int.tryParse(k, radix: 16);
            if (parsed != null && parsed < currentKeyPrefix) {
              priorOnly[k] = v;
            }
          });
          if (priorOnly.isNotEmpty) {
            onRemoteRecitationProgress?.call(
              surah: s.remoteSurah,
              ayah: s.remoteAyah,
              cumulative: priorOnly,
              isReciting: true,
            );
          }
        }
        return;
      }

      if (pkt.activeReciterId != null && pkt.activeReciterId != s.localPeerId) {
        final localClaimAge = now - s.localFloorClaimTs;
        if (localClaimAge >= 0 && localClaimAge < 1500) {
          // Stale in-flight packet from the previous reciter sent before our
          // floorClaim reached them. Re-assert our floorClaim (rate-limited to
          // once per 300ms) so their device is forced to stop immediately!
          if ((now - s.lastPreemptionRemindTs) >= 300) {
            s.lastPreemptionRemindTs = now;
            final remindTs = s.lastFloorClaimRemoteOriginTs > 0
                ? s.lastFloorClaimRemoteOriginTs
                : now;
            s.net.sendPacket(
              MaglisPacket(
                type: MaglisPacketType.floorClaim,
                seq: ++s.seq,
                senderId: s.localPeerId,
                page: s.remotePage,
                surah: s.remoteSurah,
                ayah: s.remoteAyah,
                activeReciterId: s.localPeerId,
                ts: remindTs,
              ),
            );
            s.net.sendSignalFast('floor_claim', data: {
              'page': s.remotePage,
              'surah': s.remoteSurah,
              'ayah': s.remoteAyah,
              'seq': s.seq,
              'ts': remindTs,
            });
          }
          return;
        }
        // Fail-safe: Another peer is genuinely reciting after the grace window
        // (e.g., their floorClaim packet was dropped on a lossy link). Yield floor!
        s.recitationSyncTimer?.cancel();
        s.recitationSyncTimer = null;
        s.floorClaimHedgeTimer1?.cancel();
        s.floorClaimHedgeTimer1 = null;
        s.floorClaimHedgeTimer2?.cancel();
        s.floorClaimHedgeTimer2 = null;
        s.activeReciterId = pkt.activeReciterId;
        s.lastFloorClaimTs = now;
        s.net.updateActiveFloor(pkt.activeReciterId);
        onRemoteFloorClaimed?.call(pkt.surah, pkt.ayah);
      } else {
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

    // 3. Deduplicate dual-path (DataChannel + Nostr + hedged re-transmits + mesh relay) arrival for floorClaim
    // BEFORE merging words or clearing highlights so a late copy never rolls back the verse position,
    // wipes highlights after the reciter already advanced, or re-locks a floor that was already released.
    if (pkt.type == MaglisPacketType.floorClaim) {
      final bool isSameClaimByTimestamp =
          pkt.ts > 0 && pkt.ts == s.lastFloorClaimRemoteOriginTs;
      final lastReleaseTs = s.lastFloorReleaseOriginTsByPeer[pkt.senderId] ?? 0;
      final bool isAlreadyReleasedClaim =
          pkt.ts > 0 && lastReleaseTs > 0 && pkt.ts <= lastReleaseTs;
      final bool isRecentDuplicateFromActiveReciter =
          s.activeReciterId == pkt.senderId &&
              s.remoteSurah == pkt.surah &&
              s.remoteAyah == pkt.ayah &&
              (now - s.lastFloorClaimTs).abs() < 2000;
      if (isSameClaimByTimestamp ||
          isAlreadyReleasedClaim ||
          isRecentDuplicateFromActiveReciter) {
        return;
      }
    }

    // 4. Protect active recitation cursor from third-party background connection snapshots:
    // If we are already tracking an active reciter, a snapshot from a different peer
    // (e.g. a 3rd or 4th peer whose DataChannel just opened) must only merge cumulative history,
    // never overwrite the live reciter's ID or verse cursor.
    if (pkt.type == MaglisPacketType.snapshot &&
        s.activeReciterId != null &&
        pkt.senderId != s.activeReciterId &&
        pkt.activeReciterId != s.activeReciterId) {
      if (pkt.cumulative != null && pkt.cumulative!.isNotEmpty) {
        onRemoteRecitationProgress?.call(
          surah: s.remoteSurah,
          ayah: s.remoteAyah,
          cumulative: pkt.cumulative,
          isReciting: false,
        );
      }
      return;
    }

    final bool cumulativeChanged =
        (pkt.cumulative != null && pkt.cumulative!.isNotEmpty);

    Map<int, List<ReciterError>>? parsedWordErrors;
    if (pkt.errors != null && pkt.errors!.isNotEmpty) {
      parsedWordErrors = <int, List<ReciterError>>{};
      pkt.errors!.forEach((k, list) {
        int? w0;
        final key = int.tryParse(k, radix: 16);
        if (key != null) {
          final (sNum, aNum, word0) = QuranCoordinate.unpackWordKey(key);
          if (sNum == pkt.surah && aNum == pkt.ayah) {
            w0 = word0;
          }
        } else {
          w0 = int.tryParse(k);
        }
        if (w0 != null) {
          parsedWordErrors![w0] = list
              .map((m) => MaglisPacket.decodeError(m as Map))
              .toList();
        }
      });
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
                    ts: s.lastFloorClaimRemoteOriginTs > 0
                        ? s.lastFloorClaimRemoteOriginTs
                        : now,
                  ),
                );
                return;
              }
            }
            // DELIBERATE TAKEOVER or lost glare: yield floor to the remote peer
            s.recitationSyncTimer?.cancel();
            s.recitationSyncTimer = null;
            s.floorClaimHedgeTimer1?.cancel();
            s.floorClaimHedgeTimer1 = null;
            s.floorClaimHedgeTimer2?.cancel();
            s.floorClaimHedgeTimer2 = null;
          }
        }
        s.activeReciterId = pkt.senderId;
        s.lastFloorClaimTs = now;
        s.lastFloorClaimRemoteOriginTs = pkt.ts;
        s.net.updateActiveFloor(pkt.senderId);
        s.remotePage = pkt.page;
        s.remoteSurah = pkt.surah;
        s.remoteAyah = pkt.ayah;
        final int remoteWord = pkt.activeWord ?? 0;
        s.remoteWord = remoteWord;
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
        if (pkt.senderId != s.localPeerId) {
          onRemoteRecitationProgress?.call(
            surah: pkt.surah,
            ayah: pkt.ayah,
            activeWord: remoteWord,
            greenWords: pkt.greenWords,
            yellowWords: pkt.yellowWords,
            redWords: pkt.redWords,
            errors: parsedWordErrors,
            cumulative: pkt.cumulative,
            isReciting: true,
          );
        }
        break;

      case MaglisPacketType.floorRelease:
        if (pkt.ts > 0) {
          s.lastFloorReleaseOriginTsByPeer[pkt.senderId] = pkt.ts;
        }
        if (s.activeReciterId == pkt.senderId) {
          s.activeReciterId = null;
          s.remoteWord = null;
          s.net.updateActiveFloor(null);
          _notifySessionChanged();
          notifyListeners();
          onRemoteRecitationProgress?.call(
            surah: s.remoteSurah,
            ayah: s.remoteAyah,
            activeWord: null,
            isReciting: false,
          );
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
        if (pkt.senderId != s.localPeerId) {
          onRemoteRecitationProgress?.call(
            surah: pkt.surah,
            ayah: pkt.ayah,
            activeWord: pkt.activeWord,
            greenWords: pkt.greenWords,
            yellowWords: pkt.yellowWords,
            redWords: pkt.redWords,
            errors: parsedWordErrors,
            cumulative: pkt.cumulative,
            isReciting: true,
          );
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
          if (pkt.activeReciterId != s.localPeerId) {
            onRemoteRecitationProgress?.call(
              surah: pkt.surah,
              ayah: pkt.ayah,
              activeWord: pkt.activeWord,
              greenWords: pkt.greenWords,
              yellowWords: pkt.yellowWords,
              redWords: pkt.redWords,
              errors: parsedWordErrors,
              cumulative: pkt.cumulative,
              isReciting: true,
            );
          }
        } else {
          if (s.isLocalReciting) break;
          if (cumulativeChanged) {
            notifyListeners();
            if (pkt.cumulative != null && pkt.cumulative!.isNotEmpty) {
              onRemoteRecitationProgress?.call(
                surah: s.remoteSurah,
                ayah: s.remoteAyah,
                cumulative: pkt.cumulative,
                isReciting: false,
              );
            }
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
    int activeWord = 0,
  }) async {
    final s = _session;
    if (s == null) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    s.localFloorClaimTs = now;
    s.lastFloorClaimTs = now;
    s.lastFloorClaimRemoteOriginTs = now;
    s.lastPreemptionRemindTs = now;
    s.activeReciterId = s.localPeerId;
    s.net.updateActiveFloor(s.localPeerId);
    unawaited(setMicMuted(false));
    s.remotePage = page;
    s.remoteSurah = surah;
    s.remoteAyah = ayah;
    s.remoteWord = activeWord;
    s.remoteGreenWords = const [];
    s.remoteYellowWords = const [];
    s.remoteRedWords = const [];

    // Clear broadcast state from [surah, ayah] onwards so stale highlights
    // from a previous reciter are never re-broadcast by recitationSyncTimer.
    clearHighlightsFrom(surah, ayah);
    s.lastBroadcastPage = null;
    s.lastBroadcastSurah = null;
    s.lastBroadcastAyah = null;
    s.lastBroadcastWord = null;

    final claimSeq = ++s.seq;
    s.net.sendPacket(
      MaglisPacket(
        type: MaglisPacketType.floorClaim,
        seq: claimSeq,
        senderId: s.localPeerId,
        page: page,
        surah: surah,
        ayah: ayah,
        activeWord: activeWord,
        activeReciterId: s.localPeerId,
        ts: now,
      ),
    );
    s.net.sendSignalFast('floor_claim', data: {
      'page': page,
      'surah': surah,
      'ayah': ayah,
      'activeWord': activeWord,
      'seq': claimSeq,
      'ts': now,
    });

    // Hedged 250ms & 650ms floorClaim re-transmits over DataChannel defeat mobile packet loss
    // and ensure a preempted reciter ALWAYS stops recording immediately.
    // Peers that already received the first packet deduplicate these via `lastFloorClaimRemoteOriginTs == now`.
    s.floorClaimHedgeTimer1?.cancel();
    s.floorClaimHedgeTimer2?.cancel();
    s.floorClaimHedgeTimer1 = Timer(const Duration(milliseconds: 250), () {
      if (_session == s &&
          s.isLocalReciting &&
          s.lastFloorClaimRemoteOriginTs == now) {
        s.net.sendPacket(
          MaglisPacket(
            type: MaglisPacketType.floorClaim,
            seq: claimSeq,
            senderId: s.localPeerId,
            page: s.remotePage,
            surah: s.remoteSurah,
            ayah: s.remoteAyah,
            activeWord: s.remoteWord,
            activeReciterId: s.localPeerId,
            ts: now,
          ),
        );
      }
    });
    s.floorClaimHedgeTimer2 = Timer(const Duration(milliseconds: 650), () {
      if (_session == s &&
          s.isLocalReciting &&
          s.lastFloorClaimRemoteOriginTs == now) {
        s.net.sendPacket(
          MaglisPacket(
            type: MaglisPacketType.floorClaim,
            seq: claimSeq,
            senderId: s.localPeerId,
            page: s.remotePage,
            surah: s.remoteSurah,
            ayah: s.remoteAyah,
            activeWord: s.remoteWord,
            activeReciterId: s.localPeerId,
            ts: now,
          ),
        );
      }
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
      if (includeCumulative) {
        cumulativeMap = onGetSnapshotCumulativeMap?.call();
      }

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
          errors: null,
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
    s.floorClaimHedgeTimer1?.cancel();
    s.floorClaimHedgeTimer1 = null;
    s.floorClaimHedgeTimer2?.cancel();
    s.floorClaimHedgeTimer2 = null;
    if (s.activeReciterId == s.localPeerId) {
      final now = DateTime.now().millisecondsSinceEpoch;
      s.activeReciterId = null;
      s.localFloorClaimTs = 0;
      s.lastFloorReleaseOriginTsByPeer[s.localPeerId] = now;
      s.net.updateActiveFloor(null);

      final releaseSeq = ++s.seq;
      s.net.sendPacket(
        MaglisPacket(
          type: MaglisPacketType.floorRelease,
          seq: releaseSeq,
          senderId: s.localPeerId,
          page: page,
          surah: surah,
          ayah: ayah,
          ts: now,
        ),
      );
      s.net.sendSignalFast('floor_release', data: {
        'page': page,
        'surah': surah,
        'ayah': ayah,
        'seq': releaseSeq,
        'ts': now,
      });
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

    // Serialize active errors strictly once per word
    final serializedErrors = MaglisPacket.serializeErrors(
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
    onRemoteRecitationProgress?.call(
      surah: 1,
      ayah: 1,
      isReciting: false,
    );

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

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

  MaglisNetworkEngine? _net;
  StreamSubscription<MaglisPacket>? _pktSub;
  StreamSubscription<Map<String, RTCIceConnectionState>>? _stateSub;
  StreamSubscription<String>? _natSub;
  StreamSubscription<int>? _participantSub;
  Timer? _recitationSyncTimer;

  bool _inSession = false;
  int _seq = 0;
  String _roomCode = '';
  String _localPeerId = MaglisCrypto.randomHex32().substring(0, 10);
  String get localPeerId => _localPeerId;
  String? _activeReciterId;
  String? _natFailedPeer;
  int _participantCount = 1;

  int _remotePage = 1;
  int _remoteSurah = 1;
  int _remoteAyah = 1;
  int? _remoteWord;
  List<int> _remoteGreenWords = const [];
  List<int> _remoteYellowWords = const [];
  List<int> _remoteRedWords = const [];

  int? _lastBroadcastPage;
  int? _lastBroadcastSurah;
  int? _lastBroadcastAyah;
  int? _lastBroadcastWord;


  final MaglisHighlightStore _highlightStore = MaglisHighlightStore();

  Map<String, RTCIceConnectionState> _peers = {};
  final Set<String> _connectedPeers = <String>{};
  final Map<String, Timer> _peerDisconnectTimers = {};

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
      _highlightStore.getWordErrors(surah, ayah, word0);

  int? getWordHighlight(int surah, int ayah, int word0) =>
      _highlightStore.getWordHighlight(surah, ayah, word0);

  int? getCumulativeHighlightByKey(int key) =>
      _highlightStore.getCumulativeHighlightByKey(key);

  void recordWordHighlight(int surah, int ayah, int word0, int color) {
    _highlightStore.recordWordHighlight(surah, ayah, word0, color);
  }

  bool get hasCumulativeHighlights => _highlightStore.hasCumulativeHighlights;
  int get cumulativeVersion => _highlightStore.cumulativeVersion;

  /// Clears cumulative session highlights from [startSurah, startAyah] onwards when recording starts.
  /// Any verse coming before [startSurah, startAyah] strictly keeps its highlights.
  void clearHighlightsFrom(int startSurah, int startAyah) {
    _highlightStore.clearHighlightsFrom(startSurah, startAyah);
    _lastBroadcastPage = null;
    _lastBroadcastSurah = null;
    _lastBroadcastAyah = null;
    _lastBroadcastWord = null;
    notifyListeners();
  }

  void _onPeerJoined(String peerId) {
    if (_connectedPeers.add(peerId)) {
      AppState.instance.showMaglisPeerJoinedBanner();
      _notifySessionChanged();
    }
  }

  void _onPeerLeft(String peerId) {
    bool reciterLeft = false;
    if (_activeReciterId == peerId) {
      _activeReciterId = null;
      _remoteWord = null;
      reciterLeft = true;
    }
    if (_connectedPeers.remove(peerId)) {
      AppState.instance.showMaglisPeerLeftBanner();
      _notifySessionChanged();
      if (reciterLeft) {
        notifyListeners();
      }
    }
  }

  bool get inSession => _inSession;
  String get roomCode => _roomCode;
  bool get isHost => _net?.isHost ?? false;
  String? get activeReciterId => _activeReciterId;
  String? get natFailedPeer => _natFailedPeer;
  int get participantCount =>
      _participantCount > (_connectedPeers.length + 1)
          ? _participantCount
          : (_connectedPeers.length + 1);
  bool get isLocalReciting => _inSession && _activeReciterId == localPeerId;
  bool get isRemoteReciting =>
      _inSession && _activeReciterId != null && _activeReciterId != localPeerId;
  bool get isMicMuted => _net?.isMicMuted ?? true;
  Map<String, MaglisPeerDiagnostics> get peerDiagnostics =>
      _net?.peerDiagnostics ?? const {};

  Future<void> setMicMuted(bool muted) async {
    await _net?.setMicMuted(muted);
    _notifySessionChanged();
    notifyListeners();
  }

  Future<void> toggleMic() async {
    final next = !isMicMuted;
    await setMicMuted(next);
  }

  int get remotePage => _remotePage;
  int get remoteSurah => _remoteSurah;
  int get remoteAyah => _remoteAyah;
  int? get remoteWord => _remoteWord;
  List<int> get remoteGreenWords => _remoteGreenWords;
  List<int> get remoteYellowWords => _remoteYellowWords;
  List<int> get remoteRedWords => _remoteRedWords;
  Map<String, RTCIceConnectionState> get peers => Map.unmodifiable(_peers);

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

      final mappedPage = MushafProvider.instance.getPageForAyah(
        AppState.instance.lastSurah,
        AppState.instance.lastAyah,
      ) ?? page;
      AppState.instance.enterMaglisSession(mappedPage);

      _localPeerId = MaglisCrypto.randomHex32().substring(0, 10);
      _roomCode = (code != null && code.trim().isNotEmpty)
          ? code.trim()
          : (10000 + Random.secure().nextInt(90000)).toString();

      _remotePage = page;
      _remoteSurah = surah;
      _remoteAyah = ayah;
      _remoteWord = null;
      _remoteGreenWords = const [];
      _remoteYellowWords = const [];
      _remoteRedWords = const [];
      _activeReciterId = null;
      _natFailedPeer = null;

      _net = MaglisNetworkEngine(
        roomCode: _roomCode,
        localPeerId: localPeerId,
        isHost: isHost,
        onBuildSnapshot: _buildSnapshot,
      );

      _pktSub = _net!.onPacket.listen(_handleIncomingPacket);
      _stateSub = _net!.onPeerStates.listen((map) {
        bool peersChanged = false;
        final currentConnected = map.entries
            .where((e) =>
                e.value == RTCIceConnectionState.RTCIceConnectionStateConnected ||
                e.value == RTCIceConnectionState.RTCIceConnectionStateCompleted)
            .map((e) => e.key)
            .toSet();

        for (final peerId in currentConnected) {
          _peerDisconnectTimers.remove(peerId)?.cancel();
          if (!_connectedPeers.contains(peerId)) {
            _onPeerJoined(peerId);
            peersChanged = true;
          }
        }

        for (final peerId in _connectedPeers.toList()) {
          final state = map[peerId];
          final bool isExplicitlyClosed =
              state == RTCIceConnectionState.RTCIceConnectionStateClosed;
          final bool isUnstableOrMissing = !map.containsKey(peerId) ||
              state == RTCIceConnectionState.RTCIceConnectionStateDisconnected ||
              state == RTCIceConnectionState.RTCIceConnectionStateFailed;

          if (isExplicitlyClosed) {
            _peerDisconnectTimers.remove(peerId)?.cancel();
            _onPeerLeft(peerId);
            peersChanged = true;
          } else if (isUnstableOrMissing) {
            if (!_peerDisconnectTimers.containsKey(peerId)) {
              // Give an 8-second grace period for ICE to recover or renegotiate
              // before considering the peer departed. Eliminates banner/state flapping!
              _peerDisconnectTimers[peerId] =
                  Timer(const Duration(seconds: 8), () {
                _peerDisconnectTimers.remove(peerId);
                if (_connectedPeers.contains(peerId)) {
                  _onPeerLeft(peerId);
                  _notifySessionChanged();
                }
              });
            }
          }
        }

        _peers = map;
        if (peersChanged) {
          _notifySessionChanged();
        }
      });
      _natSub = _net!.onNatFailure.listen((peerId) {
        if (_natFailedPeer != peerId) {
          _natFailedPeer = peerId;
          _notifySessionChanged();
        }
      });
      _participantSub = _net!.onParticipantCount.listen((count) {
        if (_participantCount != count) {
          _participantCount = count;
          _notifySessionChanged();
        }
      });
      _participantCount = _net!.participantCount;

      await _net!.start();
      _inSession = true;
      _notifySessionChanged();
      notifyListeners();
      return true;
    } catch (e, st) {
      debugPrint('Maglis startSession failed: $e\n$st');
      AppState.instance.exitMaglisSession();
      return false;
    }
  }

  MaglisPacket _buildSnapshot() {
    return MaglisPacket(
      type: MaglisPacketType.snapshot,
      seq: ++_seq,
      senderId: localPeerId,
      page: _remotePage,
      surah: _remoteSurah,
      ayah: _remoteAyah,
      activeWord: _remoteWord,
      greenWords: _remoteGreenWords,
      yellowWords: _remoteYellowWords,
      redWords: _remoteRedWords,
      activeReciterId: _activeReciterId,
      cumulative: _highlightStore.buildSnapshotCumulativeMap(),
      errors: _highlightStore.buildSnapshotErrorsMap(),
      ts: DateTime.now().millisecondsSinceEpoch,
    );
  }

  void _handleIncomingPacket(MaglisPacket pkt) {
    if (pkt.senderId.isNotEmpty && pkt.senderId != localPeerId) {
      _onPeerJoined(pkt.senderId);
    }

    // Merge cumulative and live words into persistent room highlights with fast radix decoding
    bool cumulativeChanged = false;
    if (pkt.cumulative != null && pkt.cumulative!.isNotEmpty) {
      if (_highlightStore.mergeCumulative(pkt.cumulative!)) {
        cumulativeChanged = true;
      }
    }
    if (_highlightStore.mergeWords(
      pkt.surah,
      pkt.ayah,
      greenWords: pkt.greenWords,
      yellowWords: pkt.yellowWords,
      redWords: pkt.redWords,
    )) {
      cumulativeChanged = true;
    }

    if (pkt.errors != null && pkt.errors!.isNotEmpty) {
      _highlightStore.mergeErrors(pkt.surah, pkt.ayah, pkt.errors!);
    }

    if (isLocalReciting && pkt.type != MaglisPacketType.floorClaim) {
      if (pkt.activeReciterId != null && pkt.activeReciterId != localPeerId) {
        // Fail-safe: Another peer is actively reciting! Force-stop local recording immediately.
        _recitationSyncTimer?.cancel();
        _recitationSyncTimer = null;
        onRemoteFloorClaimed?.call(pkt.surah, pkt.ayah);
        _activeReciterId = pkt.activeReciterId;
      } else {
        // Local reciter drives their own UI from local engine. Do not let incoming packets stutter local screen.
        return;
      }
    }

    switch (pkt.type) {
      case MaglisPacketType.floorClaim:
        // Duplicate detection: If the same peer is already active on this exact verse,
        // do not wipe or reset current verse highlights on duplicate arrival (e.g. from relay)
        if (_activeReciterId == pkt.senderId &&
            _remoteSurah == pkt.surah &&
            _remoteAyah == pkt.ayah) {
          return;
        }

        // Strict Single Reciter Rule with Deterministic Collision Arbitration:
        // When any peer claims the floor:
        if (pkt.senderId != localPeerId) {
          if (isLocalReciting) {
            // Concurrent claim collision: smaller peer ID deterministically wins
            final localWins = localPeerId.compareTo(pkt.senderId) < 0;
            if (localWins) {
              // Local peer retains the floor; re-assert claim so the other peer yields
              _net?.sendPacket(
                MaglisPacket(
                  type: MaglisPacketType.floorClaim,
                  seq: ++_seq,
                  senderId: localPeerId,
                  page: _remotePage,
                  surah: _remoteSurah,
                  ayah: _remoteAyah,
                  activeReciterId: localPeerId,
                  ts: DateTime.now().millisecondsSinceEpoch,
                ),
              );
              return;
            } else {
              _recitationSyncTimer?.cancel();
              _recitationSyncTimer = null;
            }
          }
          onRemoteFloorClaimed?.call(pkt.surah, pkt.ayah);
        }
        _activeReciterId = pkt.senderId;
        _net?.updateActiveFloor(pkt.senderId);
        _remotePage = pkt.page;
        _remoteSurah = pkt.surah;
        _remoteAyah = pkt.ayah;
        _remoteWord = pkt.activeWord;
        _remoteGreenWords = pkt.greenWords;
        _remoteYellowWords = pkt.yellowWords;
        _remoteRedWords = pkt.redWords;
        // Clearing is synchronized across all peers from the chosen verse onwards
        clearHighlightsFrom(pkt.surah, pkt.ayah);

        _notifySessionChanged();
        notifyListeners();
        onSyncMushafUI?.call(pkt.page, pkt.surah, pkt.ayah);
        break;

      case MaglisPacketType.floorRelease:
        if (_activeReciterId == pkt.senderId) {
          _activeReciterId = null;
          _remoteWord = null;
          _net?.updateActiveFloor(null);
          _notifySessionChanged();
          notifyListeners();
        }
        break;

      case MaglisPacketType.recitationUpdate:
        final bool pageChanged = _remotePage != pkt.page;
        final bool ayahChanged =
            pkt.surah != _remoteSurah || pkt.ayah != _remoteAyah;

        final newGreenList = List<int>.from(pkt.greenWords)..sort();
        final newYellowList = List<int>.from(pkt.yellowWords)..sort();
        final newRedList = List<int>.from(pkt.redWords)..sort();

        final bool wordsChanged =
            !listEquals(_remoteGreenWords, newGreenList) ||
            !listEquals(_remoteYellowWords, newYellowList) ||
            !listEquals(_remoteRedWords, newRedList);

        final bool posChanged = pageChanged ||
            ayahChanged ||
            _remoteWord != pkt.activeWord ||
            _activeReciterId != pkt.senderId;

        if (!posChanged && !wordsChanged && !cumulativeChanged) {
          return;
        }

        _activeReciterId = pkt.senderId;
        _net?.updateActiveFloor(pkt.senderId);
        _remotePage = pkt.page;
        _remoteSurah = pkt.surah;
        _remoteAyah = pkt.ayah;
        _remoteWord = pkt.activeWord;
        _remoteGreenWords = newGreenList;
        _remoteYellowWords = newYellowList;
        _remoteRedWords = newRedList;

        notifyListeners();
        if (pageChanged) {
          onSyncMushafUI?.call(pkt.page, pkt.surah, pkt.ayah);
        }
        break;

      case MaglisPacketType.snapshot:
        if (pkt.activeReciterId != null) {
          _activeReciterId = pkt.activeReciterId;
          _remotePage = pkt.page;
          _remoteSurah = pkt.surah;
          _remoteAyah = pkt.ayah;
          _remoteWord = pkt.activeWord;
          _remoteGreenWords = List<int>.from(pkt.greenWords)..sort();
          _remoteYellowWords = List<int>.from(pkt.yellowWords)..sort();
          _remoteRedWords = List<int>.from(pkt.redWords)..sort();
          _notifySessionChanged();
          notifyListeners();
          onSyncMushafUI?.call(pkt.page, pkt.surah, pkt.ayah);
        } else {
          if (isLocalReciting) break;
          // When NO ONE is reciting, do NOT force-navigate Mushaf UI to another idle peer's page!
          // Only update cumulative session highlights.
          if (cumulativeChanged || _highlightStore.hasCumulativeHighlights) {
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
    if (!_inSession) return;
    _activeReciterId = localPeerId;
    _net?.updateActiveFloor(localPeerId);
    unawaited(setMicMuted(false));
    _remotePage = page;
    _remoteSurah = surah;
    _remoteAyah = ayah;
    _remoteWord = null;
    _remoteGreenWords = const [];
    _remoteYellowWords = const [];
    _remoteRedWords = const [];

    _lastBroadcastPage = null;
    _lastBroadcastSurah = null;
    _lastBroadcastAyah = null;
    _lastBroadcastWord = null;
    _highlightStore.sentErrorWords.clear();

    _net?.sendPacket(
      MaglisPacket(
        type: MaglisPacketType.floorClaim,
        seq: ++_seq,
        senderId: localPeerId,
        page: page,
        surah: surah,
        ayah: ayah,
        activeReciterId: localPeerId,
        ts: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    _net?.sendSignalFast('floor_claim', data: {
      'page': page,
      'surah': surah,
      'ayah': ayah,
    });

    // Periodic 2.5s recitation state sync: heals any packet dropped over cellular/VPN
    _recitationSyncTimer?.cancel();
    int syncTicks = 0;
    _recitationSyncTimer =
        Timer.periodic(const Duration(milliseconds: 2500), (_) {
      if (!_inSession || !isLocalReciting) return;
      syncTicks++;
      final bool includeCumulative = (syncTicks % 3 == 0);

      Map<String, int>? cumulativeMap;
      if (includeCumulative && _highlightStore.hasCumulativeHighlights) {
        cumulativeMap = _highlightStore.buildSnapshotCumulativeMap();
      }

      final currentVerseErrors = _highlightStore.buildVerseErrorsMap(
        _remoteSurah,
        _remoteAyah,
      );

      _net?.sendPacket(
        MaglisPacket(
          type: MaglisPacketType.recitationUpdate,
          seq: ++_seq,
          senderId: localPeerId,
          page: _remotePage,
          surah: _remoteSurah,
          ayah: _remoteAyah,
          activeWord: _remoteWord,
          greenWords: _remoteGreenWords,
          yellowWords: _remoteYellowWords,
          redWords: _remoteRedWords,
          activeReciterId: localPeerId,
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
    if (!_inSession) return;
    _recitationSyncTimer?.cancel();
    _recitationSyncTimer = null;
    if (_activeReciterId == localPeerId) {
      _activeReciterId = null;
      _net?.updateActiveFloor(null);

      _net?.sendPacket(
        MaglisPacket(
          type: MaglisPacketType.floorRelease,
          seq: ++_seq,
          senderId: localPeerId,
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
    if (!_inSession || _activeReciterId != localPeerId) return;

    // Persist local words into cumulative session highlights with fast integer hashing
    _highlightStore.mergeWords(
      surah,
      ayah,
      greenWords: greenWords,
      yellowWords: yellowWords,
      redWords: redWords,
    );

    // Save local errors into _remoteWordErrors as well so local reciter has exact same lookup map
    if (errors != null && errors.isNotEmpty) {
      _highlightStore.recordLocalErrors(surah, ayah, errors);
    }

    _remotePage = page;
    _remoteSurah = surah;
    _remoteAyah = ayah;
    _remoteWord = activeWord;

    // Deduplication check:
    final bool pageOrVerseChanged = page != _lastBroadcastPage ||
        surah != _lastBroadcastSurah ||
        ayah != _lastBroadcastAyah;

    final bool cursorMoved = activeWord != _lastBroadcastWord;

    final bool wordsChanged =
        !listEquals(greenWords, _remoteGreenWords) ||
        !listEquals(yellowWords, _remoteYellowWords) ||
        !listEquals(redWords, _remoteRedWords);

    final bool errorsChanged = errors != null && errors.isNotEmpty;

    if (!pageOrVerseChanged && !cursorMoved && !wordsChanged && !errorsChanged) {
      return; // Absolute zero packets sent if reciter pauses or stays on current word!
    }

    _lastBroadcastPage = page;
    _lastBroadcastSurah = surah;
    _lastBroadcastAyah = ayah;
    _lastBroadcastWord = activeWord;

    _remoteGreenWords = List<int>.from(greenWords);
    _remoteYellowWords = List<int>.from(yellowWords);
    _remoteRedWords = List<int>.from(redWords);

    // Serialize active errors strictly once per word to achieve minimum packet size
    final serializedErrors = _highlightStore.serializeNewErrors(
      surah,
      ayah,
      errors,
    );

    _net?.sendPacket(
      MaglisPacket(
        type: MaglisPacketType.recitationUpdate,
        seq: ++_seq,
        senderId: localPeerId,
        page: page,
        surah: surah,
        ayah: ayah,
        activeWord: activeWord,
        greenWords: greenWords,
        yellowWords: yellowWords,
        redWords: redWords,
        activeReciterId: localPeerId,
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

    if (!_inSession && _net == null) return;
    _inSession = false;
    _activeReciterId = null;
    _recitationSyncTimer?.cancel();
    _recitationSyncTimer = null;
    onSessionEnded?.call();

    await _pktSub?.cancel();
    await _stateSub?.cancel();
    await _natSub?.cancel();
    await _participantSub?.cancel();
    await _net?.dispose();
    _net = null;
    _peers = {};
    _connectedPeers.clear();
    _participantCount = 1;
    _remoteGreenWords = const [];
    _remoteYellowWords = const [];
    _remoteRedWords = const [];
    _highlightStore.clearAll();
    _lastBroadcastPage = null;
    _lastBroadcastSurah = null;
    _lastBroadcastAyah = null;
    _lastBroadcastWord = null;
    for (final t in _peerDisconnectTimers.values) {
      t.cancel();
    }
    _peerDisconnectTimers.clear();
    if (resetHardwareAudio) {
      await MaglisPlatform.resetAudio();
    }
    _notifySessionChanged();
    notifyListeners();
  }
}

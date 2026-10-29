import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import '../state/app_state.dart';
import 'maglis_core.dart';
import 'maglis_network.dart';

class MaglisController extends ChangeNotifier {
  MaglisController._();
  static final MaglisController instance = MaglisController._();

  void Function(int page, int surah, int ayah)? onSyncMushafUI;
  VoidCallback? onRemoteFloorClaimed;

  MaglisNetworkEngine? _net;
  StreamSubscription<MaglisPacket>? _pktSub;
  StreamSubscription<Map<String, RTCIceConnectionState>>? _stateSub;
  StreamSubscription<String>? _natSub;
  StreamSubscription<int>? _participantSub;

  bool _inSession = false;
  int _seq = 0;
  String _roomCode = '';
  final String localPeerId = MaglisCrypto.randomHex32().substring(0, 10);
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
  int _lastGreenCount = -1;
  int _lastYellowCount = -1;
  int _lastRedCount = -1;

  Map<String, RTCIceConnectionState> _peers = {};
  final Set<String> _connectedPeers = <String>{};

  // Cumulative session word highlights: key = "${surah}_${ayah}_$word0", value = 1 (green), 2 (yellow), 3 (red)
  final Map<String, int> _cumulativeHighlights = {};
  Map<String, int> get cumulativeHighlights => _cumulativeHighlights;

  int? getWordHighlight(int surah, int ayah, int word0) =>
      _cumulativeHighlights['${surah}_${ayah}_$word0'];

  void _onPeerJoined(String peerId) {
    if (_connectedPeers.add(peerId)) {
      AppState.instance.showMaglisPeerJoinedBanner();
      notifyListeners();
    }
  }

  void _onPeerLeft(String peerId) {
    if (_activeReciterId == peerId) {
      _activeReciterId = null;
      _remoteWord = null;
    }
    if (_connectedPeers.remove(peerId)) {
      AppState.instance.showMaglisPeerLeftBanner();
      notifyListeners();
    }
  }

  bool get inSession => _inSession;
  String get roomCode => _roomCode;
  String? get activeReciterId => _activeReciterId;
  String? get natFailedPeer => _natFailedPeer;
  int get participantCount => max(_participantCount, _connectedPeers.length + 1);
  bool get isLocalReciting => _inSession && _activeReciterId == localPeerId;
  bool get isRemoteReciting =>
      _inSession && _activeReciterId != null && _activeReciterId != localPeerId;
  bool get isMicMuted => _net?.isMicMuted ?? true;

  int get remotePage => _remotePage;
  int get remoteSurah => _remoteSurah;
  int get remoteAyah => _remoteAyah;
  int? get remoteWord => _remoteWord;
  List<int> get remoteGreenWords => _remoteGreenWords;
  List<int> get remoteYellowWords => _remoteYellowWords;
  List<int> get remoteRedWords => _remoteRedWords;
  Map<String, RTCIceConnectionState> get peers => Map.unmodifiable(_peers);

  Future<bool> startSession({
    String? code,
    int page = 1,
    int surah = 1,
    int ayah = 1,
  }) async {
    final granted = await MaglisPlatform.requestPermissions();
    if (!granted) return false;

    await leaveSession();

    _roomCode = (code != null && code.trim().isNotEmpty)
        ? code.trim()
        : (100000 + Random.secure().nextInt(900000)).toString();

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
      onBuildSnapshot: _buildSnapshot,
    );

    _pktSub = _net!.onPacket.listen(_handleIncomingPacket);
    _stateSub = _net!.onPeerStates.listen((map) {
      final currentConnected = map.entries
          .where((e) =>
              e.value == RTCIceConnectionState.RTCIceConnectionStateConnected ||
              e.value == RTCIceConnectionState.RTCIceConnectionStateCompleted)
          .map((e) => e.key)
          .toSet();

      for (final peerId in currentConnected) {
        if (!_connectedPeers.contains(peerId)) {
          _onPeerJoined(peerId);
        }
      }

      for (final peerId in _connectedPeers.toList()) {
        if (!map.containsKey(peerId) ||
            map[peerId] == RTCIceConnectionState.RTCIceConnectionStateDisconnected ||
            map[peerId] == RTCIceConnectionState.RTCIceConnectionStateFailed ||
            map[peerId] == RTCIceConnectionState.RTCIceConnectionStateClosed) {
          _onPeerLeft(peerId);
        }
      }

      _peers = map;
      notifyListeners();
    });
    _natSub = _net!.onNatFailure.listen((peerId) {
      _natFailedPeer = peerId;
      notifyListeners();
    });
    _participantSub = _net!.onParticipantCount.listen((count) {
      _participantCount = count;
      notifyListeners();
    });
    _participantCount = _net!.participantCount;

    await _net!.start();
    _inSession = true;
    notifyListeners();
    return true;
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
      cumulative: Map.unmodifiable(_cumulativeHighlights),
      ts: DateTime.now().millisecondsSinceEpoch,
    );
  }

  void _handleIncomingPacket(MaglisPacket pkt) {
    if (pkt.senderId.isNotEmpty && pkt.senderId != localPeerId) {
      _onPeerJoined(pkt.senderId);
    }

    // Merge cumulative and live words into persistent room highlights
    if (pkt.cumulative != null && pkt.cumulative!.isNotEmpty) {
      _cumulativeHighlights.addAll(pkt.cumulative!);
    }
    for (final w in pkt.greenWords) {
      _cumulativeHighlights['${pkt.surah}_${pkt.ayah}_$w'] = 1;
    }
    for (final w in pkt.yellowWords) {
      _cumulativeHighlights['${pkt.surah}_${pkt.ayah}_$w'] = 2;
    }
    for (final w in pkt.redWords) {
      _cumulativeHighlights['${pkt.surah}_${pkt.ayah}_$w'] = 3;
    }

    switch (pkt.type) {
      case MaglisPacketType.floorClaim:
        final bool wasIreciting = isLocalReciting;
        _activeReciterId = pkt.senderId;
        _remotePage = pkt.page;
        _remoteSurah = pkt.surah;
        _remoteAyah = pkt.ayah;
        _remoteWord = pkt.activeWord;
        _remoteGreenWords = pkt.greenWords;
        _remoteYellowWords = pkt.yellowWords;
        _remoteRedWords = pkt.redWords;

        if (wasIreciting) {
          // Relinquish ASR tracking floor to the new reciter, but KEEP mic open for talking/notes!
          onRemoteFloorClaimed?.call();
        }
        onSyncMushafUI?.call(pkt.page, pkt.surah, pkt.ayah);
        break;

      case MaglisPacketType.floorRelease:
        if (_activeReciterId == pkt.senderId) {
          _activeReciterId = null;
          _remoteWord = null;
        }
        break;

      case MaglisPacketType.recitationUpdate:
        _activeReciterId = pkt.senderId;
        _remotePage = pkt.page;
        _remoteSurah = pkt.surah;
        _remoteAyah = pkt.ayah;
        _remoteWord = pkt.activeWord;
        _remoteGreenWords = pkt.greenWords;
        _remoteYellowWords = pkt.yellowWords;
        _remoteRedWords = pkt.redWords;

        onSyncMushafUI?.call(pkt.page, pkt.surah, pkt.ayah);
        break;

      case MaglisPacketType.snapshot:
        if (_activeReciterId == null && pkt.activeReciterId != null) {
          _activeReciterId = pkt.activeReciterId;
          _remotePage = pkt.page;
          _remoteSurah = pkt.surah;
          _remoteAyah = pkt.ayah;
          _remoteWord = pkt.activeWord;
          _remoteGreenWords = pkt.greenWords;
          _remoteYellowWords = pkt.yellowWords;
          _remoteRedWords = pkt.redWords;
          onSyncMushafUI?.call(pkt.page, pkt.surah, pkt.ayah);
        }
        break;

      case MaglisPacketType.ping:
      case MaglisPacketType.pong:
        return;
    }
    notifyListeners();
  }

  /// Called when the local user presses Record to start reciting
  Future<void> claimFloor({
    required int page,
    required int surah,
    required int ayah,
  }) async {
    if (!_inSession) return;
    _activeReciterId = localPeerId;
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
    _lastGreenCount = -1;
    _lastYellowCount = -1;
    _lastRedCount = -1;

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
    notifyListeners();
  }

  /// Called when the local user stops recording
  Future<void> releaseFloor({
    required int page,
    required int surah,
    required int ayah,
  }) async {
    if (!_inSession) return;
    if (_activeReciterId == localPeerId) {
      _activeReciterId = null;

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
      notifyListeners();
    }
  }

  /// Broadcasts live recitation position and word highlights (green/yellow/red)
  void broadcastRecitation({
    required int page,
    required int surah,
    required int ayah,
    int? activeWord,
    List<int> greenWords = const [],
    List<int> yellowWords = const [],
    List<int> redWords = const [],
  }) {
    if (!_inSession || _activeReciterId != localPeerId) return;

    // Persist local words into cumulative session highlights
    for (final w in greenWords) {
      _cumulativeHighlights['${surah}_${ayah}_$w'] = 1;
    }
    for (final w in yellowWords) {
      _cumulativeHighlights['${surah}_${ayah}_$w'] = 2;
    }
    for (final w in redWords) {
      _cumulativeHighlights['${surah}_${ayah}_$w'] = 3;
    }

    // Deduplicate: avoid sending redundant packets if state hasn't changed
    if (page == _lastBroadcastPage &&
        surah == _lastBroadcastSurah &&
        ayah == _lastBroadcastAyah &&
        activeWord == _lastBroadcastWord &&
        greenWords.length == _lastGreenCount &&
        yellowWords.length == _lastYellowCount &&
        redWords.length == _lastRedCount) {
      return;
    }
    _lastBroadcastPage = page;
    _lastBroadcastSurah = surah;
    _lastBroadcastAyah = ayah;
    _lastBroadcastWord = activeWord;
    _lastGreenCount = greenWords.length;
    _lastYellowCount = yellowWords.length;
    _lastRedCount = redWords.length;

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
        ts: DateTime.now().millisecondsSinceEpoch,
      ),
      throttle: true,
    );
  }

  Future<void> leaveSession() async {
    if (!_inSession) return;
    _inSession = false;
    _activeReciterId = null;

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
    _cumulativeHighlights.clear();
    _lastBroadcastPage = null;
    _lastBroadcastSurah = null;
    _lastBroadcastAyah = null;
    _lastBroadcastWord = null;
    _lastGreenCount = -1;
    _lastYellowCount = -1;
    _lastRedCount = -1;
    await MaglisPlatform.resetAudio();
    notifyListeners();
  }
}

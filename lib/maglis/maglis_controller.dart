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
  final Map<String, Timer> _peerDisconnectTimers = {};

  final ChangeNotifier _sessionNotifier = ChangeNotifier();
  Listenable get sessionListenable => _sessionNotifier;

  void _notifySessionChanged() {
    _sessionNotifier.notifyListeners();
  }

  // Compact 32-bit integer key: ((surah & 0xFF) << 20) | ((ayah & 0xFFF) << 8) | (word0 & 0xFF)
  static int wordKey(int surah, int ayah, int word0) =>
      ((surah & 0xFF) << 20) | ((ayah & 0xFFF) << 8) | (word0 & 0xFF);

  // Cumulative session word highlights: key = wordKey(surah, ayah, word0), value = 1 (green), 2 (yellow), 3 (red)
  final Map<int, int> _cumulativeHighlights = {};
  int _cumulativeVersion = 0;

  int? getWordHighlight(int surah, int ayah, int word0) =>
      _cumulativeHighlights[wordKey(surah, ayah, word0)];

  bool get hasCumulativeHighlights => _cumulativeHighlights.isNotEmpty;
  int get cumulativeVersion => _cumulativeVersion;

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
  int get participantCount => max(_participantCount, _connectedPeers.length + 1);
  bool get isLocalReciting => _inSession && _activeReciterId == localPeerId;
  bool get isRemoteReciting =>
      _inSession && _activeReciterId != null && _activeReciterId != localPeerId;
  bool get isMicMuted => _net?.isMicMuted ?? true;

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

  Future<bool> startSession({
    String? code,
    bool isHost = true,
    int page = 1,
    int surah = 1,
    int ayah = 1,
  }) async {
    final granted = await MaglisPlatform.requestPermissions();
    if (!granted) return false;

    await leaveSession();

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
        final bool isExplicitlyGone = !map.containsKey(peerId) ||
            state == RTCIceConnectionState.RTCIceConnectionStateClosed;
        final bool isUnstable =
            state == RTCIceConnectionState.RTCIceConnectionStateDisconnected ||
            state == RTCIceConnectionState.RTCIceConnectionStateFailed;

        if (isExplicitlyGone) {
          _peerDisconnectTimers.remove(peerId)?.cancel();
          _onPeerLeft(peerId);
          peersChanged = true;
        } else if (isUnstable) {
          if (!_peerDisconnectTimers.containsKey(peerId)) {
            // Give a 5-second grace period for ICE to recover or renegotiate
            // before considering the peer departed. Eliminates banner/state flapping!
            _peerDisconnectTimers[peerId] =
                Timer(const Duration(seconds: 5), () {
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
  }

  MaglisPacket _buildSnapshot() {
    final stringMap = <String, int>{};
    _cumulativeHighlights.forEach((k, v) {
      stringMap[k.toRadixString(16)] = v;
    });

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
      cumulative: stringMap,
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
      pkt.cumulative!.forEach((k, v) {
        final parsed = int.tryParse(k, radix: 16);
        if (parsed != null) {
          if (_cumulativeHighlights[parsed] != v) {
            _cumulativeHighlights[parsed] = v;
            cumulativeChanged = true;
          }
        } else if (k.contains('_')) {
          final parts = k.split('_');
          if (parts.length == 3) {
            final s = int.tryParse(parts[0]);
            final a = int.tryParse(parts[1]);
            final w = int.tryParse(parts[2]);
            if (s != null && a != null && w != null) {
              final key = wordKey(s, a, w);
              if (_cumulativeHighlights[key] != v) {
                _cumulativeHighlights[key] = v;
                cumulativeChanged = true;
              }
            }
          }
        }
      });
    }
    for (final w in pkt.greenWords) {
      final key = wordKey(pkt.surah, pkt.ayah, w);
      if (_cumulativeHighlights[key] != 1) {
        _cumulativeHighlights[key] = 1;
        cumulativeChanged = true;
      }
    }
    for (final w in pkt.yellowWords) {
      final key = wordKey(pkt.surah, pkt.ayah, w);
      if (_cumulativeHighlights[key] != 2) {
        _cumulativeHighlights[key] = 2;
        cumulativeChanged = true;
      }
    }
    for (final w in pkt.redWords) {
      final key = wordKey(pkt.surah, pkt.ayah, w);
      if (_cumulativeHighlights[key] != 3) {
        _cumulativeHighlights[key] = 3;
        cumulativeChanged = true;
      }
    }
    if (cumulativeChanged) {
      _cumulativeVersion++;
    }

    if (isLocalReciting && pkt.type != MaglisPacketType.floorClaim) {
      // Local reciter drives their own UI from local engine. Do not let incoming packets stutter local screen.
      return;
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
        _notifySessionChanged();
        notifyListeners();
        onSyncMushafUI?.call(pkt.page, pkt.surah, pkt.ayah);
        break;

      case MaglisPacketType.floorRelease:
        if (_activeReciterId == pkt.senderId) {
          _activeReciterId = null;
          _remoteWord = null;
          _notifySessionChanged();
          notifyListeners();
        }
        break;

      case MaglisPacketType.recitationUpdate:
        final bool pageChanged = _remotePage != pkt.page;
        final bool posChanged = pageChanged ||
            _remoteSurah != pkt.surah ||
            _remoteAyah != pkt.ayah ||
            _remoteWord != pkt.activeWord;

        bool wordsMatch(List<int> a, List<int> b) {
          if (identical(a, b)) return true;
          if (a.length != b.length) return false;
          if (a.isEmpty) return true;
          if (a.first != b.first || a.last != b.last) return false;
          return listEquals(a, b);
        }

        final bool wordsChanged =
            !wordsMatch(_remoteGreenWords, pkt.greenWords) ||
            !wordsMatch(_remoteYellowWords, pkt.yellowWords) ||
            !wordsMatch(_remoteRedWords, pkt.redWords);

        if (!posChanged && !wordsChanged && _activeReciterId == pkt.senderId) {
          return;
        }

        _activeReciterId = pkt.senderId;
        _remotePage = pkt.page;
        _remoteSurah = pkt.surah;
        _remoteAyah = pkt.ayah;
        _remoteWord = pkt.activeWord;
        _remoteGreenWords = pkt.greenWords;
        _remoteYellowWords = pkt.yellowWords;
        _remoteRedWords = pkt.redWords;

        notifyListeners();
        if (pageChanged) {
          onSyncMushafUI?.call(pkt.page, pkt.surah, pkt.ayah);
        }
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
          _notifySessionChanged();
          notifyListeners();
          onSyncMushafUI?.call(pkt.page, pkt.surah, pkt.ayah);
        } else if (cumulativeChanged || _cumulativeHighlights.isNotEmpty) {
          notifyListeners();
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
      _notifySessionChanged();
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

    // Persist local words into cumulative session highlights with fast integer hashing
    bool cumulativeChanged = false;
    for (final w in greenWords) {
      final key = wordKey(surah, ayah, w);
      if (_cumulativeHighlights[key] != 1) {
        _cumulativeHighlights[key] = 1;
        cumulativeChanged = true;
      }
    }
    for (final w in yellowWords) {
      final key = wordKey(surah, ayah, w);
      if (_cumulativeHighlights[key] != 2) {
        _cumulativeHighlights[key] = 2;
        cumulativeChanged = true;
      }
    }
    for (final w in redWords) {
      final key = wordKey(surah, ayah, w);
      if (_cumulativeHighlights[key] != 3) {
        _cumulativeHighlights[key] = 3;
        cumulativeChanged = true;
      }
    }
    if (cumulativeChanged) {
      _cumulativeVersion++;
    }

    _remotePage = page;
    _remoteSurah = surah;
    _remoteAyah = ayah;
    _remoteWord = activeWord;
    _remoteGreenWords = greenWords;
    _remoteYellowWords = yellowWords;
    _remoteRedWords = redWords;

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
    _cumulativeVersion = 0;
    _lastBroadcastPage = null;
    _lastBroadcastSurah = null;
    _lastBroadcastAyah = null;
    _lastBroadcastWord = null;
    _lastGreenCount = -1;
    _lastYellowCount = -1;
    _lastRedCount = -1;
    for (final t in _peerDisconnectTimers.values) {
      t.cancel();
    }
    _peerDisconnectTimers.clear();
    await MaglisPlatform.resetAudio();
    _notifySessionChanged();
    notifyListeners();
  }
}

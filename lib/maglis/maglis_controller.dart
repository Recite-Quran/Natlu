import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:recite_quran/recite_quran.dart';
import '../state/app_state.dart';
import 'maglis_core.dart';
import 'maglis_network.dart';

class MaglisController extends ChangeNotifier {
  MaglisController._();
  static final MaglisController instance = MaglisController._();

  void Function(int page, int surah, int ayah)? onSyncMushafUI;
  void Function(int surah, int ayah)? onRemoteFloorClaimed;

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


  // Error deduplication: strictly ensure each Tajweed error map is serialized once per verse
  final Set<int> _sentErrorWords = <int>{};

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

  /// Ultra-compact structured error map for minimum bandwidth over WebRTC.
  /// Pre-rendered human strings are omitted because ReciterError dynamically computes them.
  static Map<String, dynamic> compactErrorMap(ReciterError e) {
    final m = <String, dynamic>{
      'errorType': e.errorType.index,
      'speechErrorType': e.speechErrorType.index,
      'expectedPh': e.expectedPh,
      'predictedPh': e.predictedPh,
    };
    if (e.durationStatus != null) {
      m['durationStatus'] = e.durationStatus!.index;
    }
    if (e.expectedRule != null) {
      m['expectedRule'] = {
        'type': e.expectedRule.runtimeType.toString(),
        'nameAr': e.expectedRule!.name.ar,
        'nameEn': e.expectedRule!.name.en,
        'goldenLen': e.expectedRule!.goldenLen,
      };
    }
    if (e.expectedDuration != null) {
      m['expectedDuration'] =
          double.parse(e.expectedDuration!.toStringAsFixed(2));
    }
    if (e.actualDuration != null) {
      m['actualDuration'] =
          double.parse(e.actualDuration!.toStringAsFixed(2));
    }
    return m;
  }

  // Cumulative session word highlights: key = wordKey(surah, ayah, word0), value = 1 (green), 2 (yellow), 3 (red)
  final Map<int, int> _cumulativeHighlights = {};
  int _cumulativeVersion = 0;

  // Remote word errors received from peers: key = wordKey(surah, ayah, word0)
  final Map<int, List<ReciterError>> _remoteWordErrors = {};

  List<ReciterError>? getWordErrors(int surah, int ayah, int word0) =>
      _remoteWordErrors[wordKey(surah, ayah, word0)];

  int? getWordHighlight(int surah, int ayah, int word0) =>
      _cumulativeHighlights[wordKey(surah, ayah, word0)];

  int? getCumulativeHighlightByKey(int key) => _cumulativeHighlights[key];

  void recordWordHighlight(int surah, int ayah, int word0, int color) {
    final key = wordKey(surah, ayah, word0);
    if (_cumulativeHighlights[key] != color) {
      _cumulativeHighlights[key] = color;
      _cumulativeVersion++;
    }
  }

  bool get hasCumulativeHighlights => _cumulativeHighlights.isNotEmpty;
  int get cumulativeVersion => _cumulativeVersion;

  /// Clears cumulative session highlights from [startSurah, startAyah] onwards when recording starts.
  /// Any verse coming before [startSurah, startAyah] strictly keeps its highlights.
  void clearHighlightsFrom(int startSurah, int startAyah) {
    _cumulativeHighlights.removeWhere((key, _) {
      final s = (key >> 20) & 0xFF;
      final a = (key >> 8) & 0xFFF;
      return s > startSurah || (s == startSurah && a >= startAyah);
    });
    _remoteWordErrors.removeWhere((key, _) {
      final s = (key >> 20) & 0xFF;
      final a = (key >> 8) & 0xFFF;
      return s > startSurah || (s == startSurah && a >= startAyah);
    });
    _sentErrorWords.clear();
    _lastBroadcastPage = null;
    _lastBroadcastSurah = null;
    _lastBroadcastAyah = null;
    _lastBroadcastWord = null;
    _cumulativeVersion++;
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

      await leaveSession(resetHardwareAudio: false);

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
      return false;
    }
  }

  MaglisPacket _buildSnapshot() {
    final stringMap = <String, int>{};
    _cumulativeHighlights.forEach((k, v) {
      stringMap[k.toRadixString(16)] = v;
    });

    Map<String, List<Map<String, dynamic>>>? snapshotErrors;
    if (_remoteWordErrors.isNotEmpty) {
      _remoteWordErrors.forEach((key, list) {
        (snapshotErrors ??= {})[key.toRadixString(16)] =
            list.map((e) => compactErrorMap(e)).toList();
      });
    }

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
      errors: snapshotErrors,
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

    if (pkt.errors != null && pkt.errors!.isNotEmpty) {
      pkt.errors!.forEach((k, list) {
        int? key = int.tryParse(k, radix: 16);
        if (key == null) {
          final w0 = int.tryParse(k);
          if (w0 != null) key = wordKey(pkt.surah, pkt.ayah, w0);
        }
        if (key != null) {
          _remoteWordErrors[key] = list
              .map((m) => ReciterError.fromMap(m))
              .toList();
        }
      });
    }

    if (isLocalReciting && pkt.type != MaglisPacketType.floorClaim) {
      if (pkt.activeReciterId != null && pkt.activeReciterId != localPeerId) {
        // Fail-safe: Another peer is actively reciting! Force-stop local recording immediately.
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

        // Strict Single Reciter Rule:
        // When any peer claims the floor, any local recording must stop immediately
        // and yield the floor to the new reciter.
        if (pkt.senderId != localPeerId) {
          onRemoteFloorClaimed?.call(pkt.surah, pkt.ayah);
        }
        _activeReciterId = pkt.senderId;
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
          _remotePage = pkt.page;
          _remoteSurah = pkt.surah;
          _remoteAyah = pkt.ayah;
          if (cumulativeChanged || _cumulativeHighlights.isNotEmpty) {
            notifyListeners();
          }
          if (pkt.page >= 1 && pkt.page <= 604) {
            onSyncMushafUI?.call(pkt.page, pkt.surah, pkt.ayah);
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
    _sentErrorWords.clear();

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
    _recitationSyncTimer =
        Timer.periodic(const Duration(milliseconds: 2500), (_) {
      if (!_inSession || !isLocalReciting) return;
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

    // Save local errors into _remoteWordErrors as well so local reciter has exact same lookup map
    if (errors != null && errors.isNotEmpty) {
      errors.forEach((w0, errList) {
        final key = wordKey(surah, ayah, w0);
        _remoteWordErrors[key] = errList;
      });
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
    Map<String, List<Map<String, dynamic>>>? serializedErrors;
    if (errors != null && errors.isNotEmpty) {
      for (final entry in errors.entries) {
        if (_sentErrorWords.add(entry.key)) {
          final key = wordKey(surah, ayah, entry.key);
          (serializedErrors ??= {})[key.toRadixString(16)] =
              entry.value.map((e) => compactErrorMap(e)).toList();
        }
      }
    }

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

  Future<void> leaveSession({bool resetHardwareAudio = true}) async {
    if (!_inSession && _net == null) return;
    _inSession = false;
    _activeReciterId = null;
    _recitationSyncTimer?.cancel();
    _recitationSyncTimer = null;

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
    _remoteWordErrors.clear();
    _sentErrorWords.clear();
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

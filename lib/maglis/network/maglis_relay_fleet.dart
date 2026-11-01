import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../maglis_core.dart';
import 'maglis_config_manager.dart';
import 'maglis_reconnection_scheduler.dart';
import 'maglis_room_discovery.dart';

/// MaglisRelayFleet
///
/// Encapsulates multi-relay Nostr signaling transport (noscall pattern).
/// Manages WebSocket connection pools, ping/pong heartbeats, cryptographic signal
/// encryption/signing, and ephemeral room presence verification.
/// Integrated with [MaglisReconnectionScheduler] for jittered exponential backoff.
class MaglisRelayFleet {
  final String roomCode;
  final String localPeerId;
  final bool Function() isHost;
  final Function(MaglisSignal signal) onSignalReceived;

  MaglisRelayFleet({
    required this.roomCode,
    required this.localPeerId,
    required this.isHost,
    required this.onSignalReceived,
  });

  late final String privHex = MaglisCrypto.randomHex32();
  late final String pubHex = MaglisCrypto.getPublicKey(privHex);
  List<String> get activeTags => MaglisCrypto.activeBlindedTags(roomCode);

  final Map<String, WebSocketChannel> sockets = {};
  final Set<String> reconnectingRelays = {};
  final LinkedHashSet<String> seenNostrIds = LinkedHashSet<String>();
  final List<String> pendingOutboundSignals = [];
  final MaglisReconnectionScheduler _reconnectionScheduler =
      MaglisReconnectionScheduler();

  bool hasNetworkConnectivity = true;
  bool disposed = false;
  bool isSocketSubscribed = false;
  String? lastSubId;
  DateTime lastRelayFrameTime = DateTime.now();
  final int engineStartTime = DateTime.now().millisecondsSinceEpoch ~/ 1000;

  Timer? relayHeartbeatTimer;
  static const int targetRelayCount = 3;

  List<String> get roomRelays => MaglisConfigManager.roomRelaysForCode(roomCode);

  List<String> get targetRelayUrls {
    final list = roomRelays;
    if (list.isEmpty) return const [];

    // Prioritize the relay confirmed active during room discovery
    final cached = MaglisRoomDiscovery.getCachedRelayForRoom(roomCode);
    if (cached != null && list.contains(cached)) {
      final prioritized = [cached, ...list.where((r) => r != cached)];
      return prioritized.take(targetRelayCount).toList();
    }
    return list.take(targetRelayCount).toList();
  }

  static String formatRelayUrl(String baseUrl, String room) {
    try {
      final uri = Uri.parse(baseUrl);
      if (uri.host.contains('workers.dev')) {
        final cleanRoom = normalizeArabicDigits(room.trim()).toLowerCase();
        return uri.replace(
          path: '/room/$cleanRoom',
          queryParameters: {'room': cleanRoom},
        ).toString();
      }
    } catch (_) {}
    return baseUrl;
  }

  Future<bool> connectRelayFleet({Duration timeout = const Duration(seconds: 6)}) async {
    if (disposed) return false;
    final targets = targetRelayUrls;
    final futures = <Future<bool>>[];
    for (final url in targets) {
      if (!sockets.containsKey(url) && !reconnectingRelays.contains(url)) {
        futures.add(connectRelay(url));
      }
    }
    if (futures.isNotEmpty) {
      final anySuccess = Completer<void>();
      for (final f in futures) {
        f.then((ok) {
          if (ok && !anySuccess.isCompleted) anySuccess.complete();
        });
      }
      await Future.any([
        Future.wait(futures),
        anySuccess.future,
        Future.delayed(timeout),
      ]);
    }
    return sockets.isNotEmpty && isSocketSubscribed;
  }

  Future<bool> connectRelay(String url) async {
    if (disposed) return false;
    final completer = Completer<bool>();
    try {
      final targetUrl = formatRelayUrl(url, roomCode);
      final ws = WebSocketChannel.connect(Uri.parse(targetUrl));

      bool errored = false;
      void handleFail() {
        sockets.remove(url);
        if (!completer.isCompleted) completer.complete(false);
        if (!errored) {
          errored = true;
          scheduleReconnect(url);
        }
      }

      ws.ready.timeout(const Duration(milliseconds: 5500)).then((_) {
        if (disposed) {
          try {
            ws.sink.close();
          } catch (_) {}
          sockets.remove(url);
          if (!completer.isCompleted) completer.complete(false);
          return;
        }
        sockets[url] = ws;
        _reconnectionScheduler.recordSuccess(url);
        subscribeRelay(ws);
        if (pendingOutboundSignals.isNotEmpty) {
          final toSend = List<String>.from(pendingOutboundSignals);
          pendingOutboundSignals.clear();
          for (final f in toSend) {
            try {
              ws.sink.add(f);
            } catch (_) {}
          }
        }
        if (!completer.isCompleted) completer.complete(true);
      }).catchError((_) {
        handleFail();
      });

      ws.stream.listen(
        onRelayFrame,
        onDone: handleFail,
        onError: (_) => handleFail(),
        cancelOnError: true,
      );
      return await completer.future;
    } catch (_) {
      sockets.remove(url);
      scheduleReconnect(url);
      return false;
    }
  }

  void subscribeRelay(WebSocketChannel ws) {
    final tags = activeTags;
    final newSubId = 'maglis_${tags.first}';
    if (lastSubId != null && lastSubId != newSubId) {
      try {
        ws.sink.add(jsonEncode(['CLOSE', lastSubId]));
      } catch (_) {}
    }
    lastSubId = newSubId;
    ws.sink.add(jsonEncode([
      'REQ',
      newSubId,
      {
        'kinds': [20000],
        '#t': tags,
      }
    ]));
    isSocketSubscribed = true;
  }

  void resubscribeRelays() {
    if (disposed) return;
    for (final ws in sockets.values) {
      try {
        subscribeRelay(ws);
      } catch (_) {}
    }
  }

  void checkSocketSleepState() {
    if (disposed) return;
    if (!isSocketSubscribed) {
      resubscribeRelays();
    }
  }

  void scheduleReconnect(String url) {
    sockets.remove(url);
    if (disposed) return;

    reconnectingRelays.add(url);
    _reconnectionScheduler.schedule(
      relay: url,
      hasNetworkConnectivity: hasNetworkConnectivity,
      isRelayManaged: () => !disposed && roomRelays.contains(url),
      reconnect: () {
        reconnectingRelays.remove(url);
        if (!disposed && sockets.length < targetRelayCount) {
          connectRelayFleet();
        }
      },
    );
  }

  void startHeartbeat() {
    relayHeartbeatTimer?.cancel();
    relayHeartbeatTimer = Timer.periodic(const Duration(seconds: 18), (_) {
      if (disposed) return;
      final pingTag = 'hb_${DateTime.now().millisecondsSinceEpoch}';
      for (final ws in sockets.values) {
        try {
          ws.sink.add(jsonEncode([
            'REQ',
            pingTag,
            {'limit': 0}
          ]));
          ws.sink.add(jsonEncode(['CLOSE', pingTag]));
        } catch (_) {}
      }
    });
  }

  Future<void> sendSignal(
    String type, {
    String? targetId,
    required Map<String, dynamic> data,
  }) async {
    if (disposed) return;
    final payloadData = Map<String, dynamic>.from(data);
    payloadData['auth'] = MaglisCrypto.admissionToken(roomCode, localPeerId);
    if (isHost()) {
      payloadData['host'] = true;
    }

    final sig = MaglisSignal(
      type: type,
      senderId: localPeerId,
      targetId: targetId,
      data: payloadData,
    );
    final cipher = await MaglisCrypto.encrypt(sig.pack(), roomCode);
    final tags = activeTags;
    final frame = await MaglisCrypto.signNostrEventAsync(
      privHex: privHex,
      pubHex: pubHex,
      tag: tags.first,
      additionalTags: tags.length > 1 ? tags.sublist(1) : null,
      content: cipher,
    );
    if (sockets.isEmpty) {
      pendingOutboundSignals.add(frame);
      if (pendingOutboundSignals.length > 25) {
        pendingOutboundSignals.removeAt(0);
      }
      return;
    }
    for (final ws in sockets.values) {
      try {
        ws.sink.add(frame);
      } catch (_) {}
    }

    // Hedge critical reconnection signals to the primary relay to eliminate split-brain relay partitioning
    final bool isCriticalSignaling = type == 'reconnect_request' ||
        (type == 'offer' &&
            (data['iceRestart'] == true || data['dcRecovery'] == true)) ||
        type == 'answer';

    if (isCriticalSignaling && sockets.length < 2 && roomRelays.isNotEmpty) {
      final primaryUrl = roomRelays.first;
      if (!sockets.containsKey(primaryUrl)) {
        unawaited(sendSignalToRelay(primaryUrl, frame));
      }
    }
  }

  Future<void> sendSignalToRelay(String url, String frame) async {
    try {
      final targetUrl = formatRelayUrl(url, roomCode);
      final ws = WebSocketChannel.connect(Uri.parse(targetUrl));
      await ws.ready.timeout(const Duration(milliseconds: 1200));
      ws.sink.add(frame);
      await Future.delayed(const Duration(milliseconds: 150));
      try {
        await ws.sink.close();
      } catch (_) {}
    } catch (_) {}
  }

  Future<void> onRelayFrame(dynamic rawFrame) async {
    if (disposed || rawFrame is! String) return;
    lastRelayFrameTime = DateTime.now();
    try {
      final list = jsonDecode(rawFrame);
      if (list is! List || list.length < 3 || list[0] != 'EVENT') return;
      final ev = list[2] as Map<String, dynamic>;
      final id = ev['id'] as String?;
      final content = ev['content'] as String?;
      final createdAt = ev['created_at'] as int?;
      if (id == null || content == null) return;

      // Discard stale events from prior sessions or older than 300s (5 min) before engine start
      if (createdAt != null && createdAt < (engineStartTime - 300)) {
        return;
      }

      if (seenNostrIds.contains(id)) return;
      seenNostrIds.add(id);
      if (seenNostrIds.length > 400) {
        seenNostrIds.remove(seenNostrIds.first);
      }

      final clear = await MaglisCrypto.decrypt(content, roomCode);
      if (clear == null) return;

      final sig = MaglisSignal.unpack(clear);
      if (sig.senderId == localPeerId) return;
      if (sig.targetId != null && sig.targetId != localPeerId) return;

      // Host Admission Shield: Authenticate admission token derived from roomCode + peerId + pepper
      final auth = sig.data['auth'] as String?;
      if (auth == null ||
          !MaglisCrypto.verifyAdmissionToken(roomCode, sig.senderId, auth)) {
        return; // Reject unauthenticated probes
      }

      onSignalReceived(sig);
    } catch (_) {}
  }

  void resetReconnectionScheduler() {
    _reconnectionScheduler.resetAll();
  }

  void updateConnectivity(bool hasConnection) {
    hasNetworkConnectivity = hasConnection;
    if (hasConnection) {
      _reconnectionScheduler.resetAll();
    }
  }

  void dispose() {
    disposed = true;
    _reconnectionScheduler.cancelAll();
    relayHeartbeatTimer?.cancel();
    relayHeartbeatTimer = null;
    for (final ws in sockets.values) {
      try {
        ws.sink.close();
      } catch (_) {}
    }
    sockets.clear();
    reconnectingRelays.clear();
    pendingOutboundSignals.clear();
  }

  // --- Static Presence and Verification Delegations (Noscall Facade Pattern) ---

  static Future<MaglisJoinResult> verifyRoomJoinable(String roomCode) =>
      MaglisRoomDiscovery.verifyRoomJoinable(roomCode);

}

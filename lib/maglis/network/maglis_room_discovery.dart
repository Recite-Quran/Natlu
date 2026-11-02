import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../maglis_core.dart';
import 'maglis_config_manager.dart';
import 'maglis_relay_fleet.dart';

/// MaglisRoomDiscovery
///
/// Encapsulates fast, resilient room probing, join verification, and code reservation.
/// Solves Nostr ephemeral event (kind 20000) relay partitioning by:
/// 1. Concurrently racing probes across the primary anchor relay + top fallback relays.
/// 2. Completing immediately upon the first affirmative reply (`join_ack`, `join_reject`, `beacon`).
/// 3. Hedging with a warm retransmit at 750ms to defeat mobile packet loss.
/// 4. Caching the active relay that answered, ensuring the joining peer immediately anchors to the host's relay.
class MaglisRoomDiscovery {
  static final Map<String, String> _discoveredRelayCache = {};

  /// Retrieves the known responsive relay for this room, if discovered recently.
  static String? getCachedRelayForRoom(String roomCode) {
    final clean = normalizeArabicDigits(roomCode.trim());
    return _discoveredRelayCache[clean];
  }

  /// Clears cached room relay mappings.
  static void clearCache() {
    _discoveredRelayCache.clear();
  }

  /// Verifies room existence and capacity across the multi-relay quorum.
  /// Races primary and secondary relays with 750ms warm retransmission.
  static Future<MaglisJoinResult> verifyRoomJoinable(String roomCode) async {
    final trimmed = normalizeArabicDigits(roomCode.trim());
    if (trimmed.length != 5) return MaglisJoinResult.notFound;

    final tags = MaglisCrypto.activeBlindedTags(trimmed);
    final probePeerId = MaglisCrypto.randomHex32().substring(0, 10);
    final privHex = MaglisCrypto.randomHex32();
    final pubHex = MaglisCrypto.getPublicKey(privHex);

    final cancelSignal = Completer<void>();
    Timer? overallTimeoutTimer;

    try {
      final probeSig = MaglisSignal(
        type: 'join_probe',
        senderId: probePeerId,
        data: {'auth': MaglisCrypto.admissionToken(trimmed, probePeerId)},
      );
      final cipher = await MaglisCrypto.encrypt(probeSig.pack(), trimmed);
      final frame = await MaglisCrypto.signNostrEventAsync(
        privHex: privHex,
        pubHex: pubHex,
        tag: tags.first,
        additionalTags: tags.length > 1 ? tags.sublist(1) : null,
        content: cipher,
      );

      final roomRelays = MaglisConfigManager.roomRelaysForCode(trimmed);
      if (roomRelays.isEmpty) return MaglisJoinResult.notFound;

      // Check if we previously found an active relay for this room code
      final cachedRelay = _discoveredRelayCache[trimmed];
      final targetRelays = <String>[];
      if (cachedRelay != null && roomRelays.contains(cachedRelay)) {
        targetRelays.add(cachedRelay);
      }
      for (final r in roomRelays.take(3)) {
        if (!targetRelays.contains(r)) {
          targetRelays.add(r);
        }
      }

      final completer = Completer<MaglisJoinResult>();

      // Concurrent hedged race: probe top relays in parallel
      final futures = targetRelays.map((url) async {
        final result = await _probeSingleRelay(
          url: url,
          trimmed: trimmed,
          frame: frame,
          tags: tags,
          probePeerId: probePeerId,
          timeoutMs: 6500,
          cancelSignal: cancelSignal.future,
          privHex: privHex,
          pubHex: pubHex,
        );
        if (result != null && !completer.isCompleted) {
          if (_discoveredRelayCache.length > 64 &&
              !_discoveredRelayCache.containsKey(trimmed)) {
            _discoveredRelayCache.remove(_discoveredRelayCache.keys.first);
          }
          _discoveredRelayCache[trimmed] = url;
          completer.complete(result);
          if (!cancelSignal.isCompleted) {
            cancelSignal.complete();
          }
        }
      }).toList();

      // Overall race timeout: 7500ms
      overallTimeoutTimer = Timer(const Duration(milliseconds: 7500), () {
        if (!completer.isCompleted) {
          completer.complete(MaglisJoinResult.notFound);
        }
        if (!cancelSignal.isCompleted) {
          cancelSignal.complete();
        }
      });

      unawaited(Future.wait(futures).then((_) {
        if (!completer.isCompleted) {
          completer.complete(MaglisJoinResult.notFound);
        }
        if (!cancelSignal.isCompleted) {
          cancelSignal.complete();
        }
      }));

      return await completer.future;
    } catch (e) {
      debugPrint('[MaglisRoomDiscovery] verifyRoomJoinable error: $e');
      return MaglisJoinResult.notFound;
    } finally {
      overallTimeoutTimer?.cancel();
      if (!cancelSignal.isCompleted) {
        cancelSignal.complete();
      }
    }
  }

  static Future<MaglisJoinResult?> _probeSingleRelay({
    required String url,
    required String trimmed,
    required String frame,
    required List<String> tags,
    required String probePeerId,
    required int timeoutMs,
    required Future<void> cancelSignal,
    String? privHex,
    String? pubHex,
  }) async {
    WebSocketChannel? ws;
    StreamSubscription? sub;
    Timer? retransmitTimer;
    final completer = Completer<MaglisJoinResult?>();

    unawaited(cancelSignal.then((_) {
      retransmitTimer?.cancel();
      if (!completer.isCompleted) {
        completer.complete(null);
      }
    }));

    try {
      final formattedUrl = MaglisRelayFleet.formatRelayUrl(url, trimmed);
      ws = WebSocketChannel.connect(Uri.parse(formattedUrl));
      final readyMs = (timeoutMs - 500).clamp(1500, 5000);
      await Future.any([
        ws.ready.timeout(Duration(milliseconds: readyMs)),
        cancelSignal,
      ]);
      if (completer.isCompleted) return null;

      final probeStartSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;

      sub = ws.stream.listen(
        (dynamic raw) async {
          if (completer.isCompleted || raw is! String) return;
          try {
            final list = jsonDecode(raw);
            if (list is! List || list.length < 3 || list[0] != 'EVENT') return;
            final ev = list[2] as Map<String, dynamic>;
            final content = ev['content'] as String?;
            final createdAt = ev['created_at'] as int?;
            if (content == null) return;

            // Ignore stale historical events older than 5 minutes
            if (createdAt != null && createdAt < (probeStartSec - 300)) {
              return;
            }

            final clear = await MaglisCrypto.decrypt(content, trimmed);
            if (clear == null || completer.isCompleted) return;
            final sig = MaglisSignal.unpack(clear);
            if (sig.senderId.isEmpty || sig.senderId == probePeerId) return;

            // Authenticate admission token so corrupted/foreign frames are ignored
            final auth = sig.data['auth'] as String?;
            if (auth == null ||
                !MaglisCrypto.verifyAdmissionToken(
                    trimmed, sig.senderId, auth)) {
              return;
            }

            if (sig.type == 'join_reject' &&
                (sig.targetId == null || sig.targetId == probePeerId)) {
              retransmitTimer?.cancel();
              if (!completer.isCompleted) {
                completer.complete(MaglisJoinResult.full);
              }
            } else if (sig.type == 'join_ack' &&
                (sig.targetId == null || sig.targetId == probePeerId)) {
              final count = sig.data['count'] as int? ?? 1;
              retransmitTimer?.cancel();
              if (!completer.isCompleted) {
                completer.complete(count >= 4
                    ? MaglisJoinResult.full
                    : MaglisJoinResult.success);
              }
            } else if (sig.type == 'beacon' ||
                sig.type == 'offer' ||
                sig.type == 'presence_pong' ||
                sig.type == 'floor_claim') {
              retransmitTimer?.cancel();
              if (!completer.isCompleted) {
                completer.complete(MaglisJoinResult.success);
              }
            }
          } catch (_) {}
        },
        onError: (_) {
          retransmitTimer?.cancel();
          if (!completer.isCompleted) completer.complete(null);
        },
        onDone: () {
          retransmitTimer?.cancel();
          if (!completer.isCompleted) completer.complete(null);
        },
        cancelOnError: true,
      );

      final subId = 'probe_${tags.first}';
      ws.sink.add(jsonEncode([
        'REQ',
        subId,
        {
          'kinds': [20000],
          '#t': tags,
        }
      ]));
      ws.sink.add(frame);

      // Hedged 750ms warm re-transmit if no ACK received yet (defeats cellular packet loss)
      if (privHex != null && pubHex != null) {
        retransmitTimer = Timer(const Duration(milliseconds: 750), () async {
          final activeWs = ws;
          if (!completer.isCompleted && activeWs != null) {
            try {
              final warmFrame = await MaglisCrypto.signNostrEventAsync(
                privHex: privHex,
                pubHex: pubHex,
                tag: tags.first,
                additionalTags: tags.length > 1 ? tags.sublist(1) : null,
                content: await MaglisCrypto.encrypt(
                  MaglisSignal(
                    type: 'join_probe',
                    senderId: probePeerId,
                    data: {
                      'auth': MaglisCrypto.admissionToken(trimmed, probePeerId),
                      'retry': true,
                    },
                  ).pack(),
                  trimmed,
                ),
              );
              if (!completer.isCompleted) {
                activeWs.sink.add(warmFrame);
              }
            } catch (_) {}
          }
        });
      }

      final res = await completer.future
          .timeout(Duration(milliseconds: timeoutMs), onTimeout: () => null);
      retransmitTimer?.cancel();
      return res;
    } catch (_) {
      retransmitTimer?.cancel();
      return null;
    } finally {
      retransmitTimer?.cancel();
      try {
        await sub?.cancel();
        await ws?.sink.close();
      } catch (_) {}
    }
  }
}

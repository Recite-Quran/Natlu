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
          timeoutMs: 3200,
          privHex: privHex,
          pubHex: pubHex,
        );
        if (result != null && !completer.isCompleted) {
          _discoveredRelayCache[trimmed] = url;
          completer.complete(result);
        }
      }).toList();

      // Overall race timeout: 3500ms
      final overallTimeout = Future.delayed(const Duration(milliseconds: 3500), () {
        if (!completer.isCompleted) {
          completer.complete(MaglisJoinResult.notFound);
        }
      });

      unawaited(Future.wait(futures).then((_) {
        if (!completer.isCompleted) {
          completer.complete(MaglisJoinResult.notFound);
        }
      }));

      await Future.any([completer.future, overallTimeout]);
      return await completer.future;
    } catch (e) {
      debugPrint('[MaglisRoomDiscovery] verifyRoomJoinable error: $e');
      return MaglisJoinResult.notFound;
    }
  }

  static Future<MaglisJoinResult?> _probeSingleRelay({
    required String url,
    required String trimmed,
    required String frame,
    required List<String> tags,
    required String probePeerId,
    required int timeoutMs,
    String? privHex,
    String? pubHex,
  }) async {
    WebSocketChannel? ws;
    StreamSubscription? sub;
    Timer? retransmitTimer;
    try {
      final formattedUrl = MaglisRelayFleet.formatRelayUrl(url, trimmed);
      ws = WebSocketChannel.connect(Uri.parse(formattedUrl));
      final readyMs = (timeoutMs - 400).clamp(1500, 3000);
      await ws.ready.timeout(Duration(milliseconds: readyMs));

      final completer = Completer<MaglisJoinResult?>();
      sub = ws.stream.listen((dynamic raw) async {
        if (completer.isCompleted || raw is! String) return;
        try {
          final list = jsonDecode(raw);
          if (list is! List || list.length < 3 || list[0] != 'EVENT') return;
          final ev = list[2] as Map<String, dynamic>;
          final content = ev['content'] as String?;
          if (content == null) return;

          final clear = await MaglisCrypto.decrypt(content, trimmed);
          if (clear == null) return;
          final sig = MaglisSignal.unpack(clear);
          if (sig.senderId == probePeerId) return;

          if (sig.type == 'join_reject' &&
              (sig.targetId == null || sig.targetId == probePeerId)) {
            retransmitTimer?.cancel();
            if (!completer.isCompleted) {
              completer.complete(MaglisJoinResult.full);
            }
          } else if (sig.type == 'join_ack') {
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
      });

      final subId = 'probe_${tags.first}';
      ws.sink.add(jsonEncode([
        'REQ',
        subId,
        {'kinds': [20000], '#t': tags}
      ]));
      ws.sink.add(frame);

      // Hedged 750ms warm re-transmit if no ACK received yet (defeats cellular packet loss)
      if (privHex != null && pubHex != null) {
        retransmitTimer = Timer(const Duration(milliseconds: 750), () async {
          if (!completer.isCompleted && ws != null) {
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
              ws.sink.add(warmFrame);
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

  /// Checks whether a room code is currently in use across the relay quorum.
  static Future<bool> isRoomCodeInUse(String roomCode) async {
    final trimmed = normalizeArabicDigits(roomCode.trim());
    if (trimmed.length != 5) return false;

    final tags = MaglisCrypto.activeBlindedTags(trimmed);
    final probePeerId = MaglisCrypto.randomHex32().substring(0, 10);
    final privHex = MaglisCrypto.randomHex32();
    final pubHex = MaglisCrypto.getPublicKey(privHex);

    try {
      final probeSig = MaglisSignal(
        type: 'presence_probe',
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
      final targetRelays = roomRelays.take(3).toList();

      final futures = targetRelays.map((url) => _presenceSingleRelay(
            url: url,
            trimmed: trimmed,
            frame: frame,
            tags: tags,
            probePeerId: probePeerId,
            timeoutMs: 1600,
          ));

      final results = await Future.wait(futures);
      return results.any((r) => r == true);
    } catch (_) {
      return false;
    }
  }

  static Future<bool?> _presenceSingleRelay({
    required String url,
    required String trimmed,
    required String frame,
    required List<String> tags,
    required String probePeerId,
    required int timeoutMs,
  }) async {
    WebSocketChannel? ws;
    StreamSubscription? sub;
    try {
      final formattedUrl = MaglisRelayFleet.formatRelayUrl(url, trimmed);
      ws = WebSocketChannel.connect(Uri.parse(formattedUrl));
      final readyMs = (timeoutMs - 400).clamp(800, 1400);
      await ws.ready.timeout(Duration(milliseconds: readyMs));

      final completer = Completer<bool?>();
      sub = ws.stream.listen((dynamic raw) async {
        if (completer.isCompleted || raw is! String) return;
        try {
          final list = jsonDecode(raw);
          if (list is! List || list.length < 3 || list[0] != 'EVENT') return;
          final ev = list[2] as Map<String, dynamic>;
          final content = ev['content'] as String?;
          if (content == null) return;

          final clear = await MaglisCrypto.decrypt(content, trimmed);
          if (clear == null) return;
          final sig = MaglisSignal.unpack(clear);
          if (sig.senderId == probePeerId) return;

          if ((sig.type == 'presence_pong' ||
                  sig.type == 'beacon' ||
                  sig.type == 'offer' ||
                  sig.type == 'join_ack' ||
                  sig.type == 'reserve_code') &&
              !completer.isCompleted) {
            completer.complete(true);
          }
        } catch (_) {}
      });

      final subId = 'presence_${tags.first}';
      ws.sink.add(jsonEncode([
        'REQ',
        subId,
        {'kinds': [20000], '#t': tags}
      ]));
      ws.sink.add(frame);

      final res = await completer.future
          .timeout(Duration(milliseconds: timeoutMs), onTimeout: () => null);
      return res;
    } catch (_) {
      return null;
    } finally {
      try {
        await sub?.cancel();
        await ws?.sink.close();
      } catch (_) {}
    }
  }

  /// Reserves a newly generated room code across the relay quorum.
  static Future<void> reserveRoomCode(String roomCode, String tempId) async {
    try {
      final trimmed = normalizeArabicDigits(roomCode.trim());
      final tags = MaglisCrypto.activeBlindedTags(trimmed);
      final privHex = MaglisCrypto.randomHex32();
      final pubHex = MaglisCrypto.getPublicKey(privHex);

      final sig = MaglisSignal(
        type: 'reserve_code',
        senderId: tempId,
        data: {'auth': MaglisCrypto.admissionToken(trimmed, tempId)},
      );
      final cipher = await MaglisCrypto.encrypt(sig.pack(), trimmed);
      final frame = await MaglisCrypto.signNostrEventAsync(
        privHex: privHex,
        pubHex: pubHex,
        tag: tags.first,
        content: cipher,
      );

      final roomRelays = MaglisConfigManager.roomRelaysForCode(trimmed);
      for (final url in roomRelays.take(2)) {
        try {
          final formattedUrl = MaglisRelayFleet.formatRelayUrl(url, trimmed);
          final ws = WebSocketChannel.connect(Uri.parse(formattedUrl));
          await ws.ready.timeout(const Duration(milliseconds: 1200));
          ws.sink.add(frame);
          await Future.delayed(const Duration(milliseconds: 150));
          try {
            await ws.sink.close();
          } catch (_) {}
          break; // Primary healthy relay succeeded
        } catch (_) {
          continue;
        }
      }
    } catch (_) {}
  }
}


import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// MaglisConfigManager
///
/// Manages dynamic relays and WebRTC ICE (STUN/TURN) configurations.
/// Follows noscall-style separated ICE server manager with multi-tier failover:
/// - Tier 1: Cloudflare Edge Worker (/config) - Sub-30ms, no IP rate limits
/// - Tier 2: jsDelivr Global CDN - Worldwide distribution, bypasses worker blocking and GitHub rate limits
/// - Tier 3: GitHub Raw - Direct repository fallback
/// - Tier 4: Built-in hardcoded defaults (_defaultRelays, _defaultRtcConfig)
class MaglisConfigManager {
  static const List<String> defaultRelays = [
    'wss://quran-maglis.recitequrankarem.workers.dev',
    'wss://relay.damus.io',
    'wss://relay.primal.net',
    'wss://relay.snort.social',
  ];

  static List<String> _relays = List.from(defaultRelays);
  static List<String> get relays => List.unmodifiable(_relays);

  static const Map<String, dynamic> defaultRtcConfig = {
    'iceServers': [
      {'urls': 'stun:stun.l.google.com:19302'},
      {'urls': 'stun:stun1.l.google.com:19302'},
      {'urls': 'stun:stun.cloudflare.com:3478'},
      {
        'urls': [
          'turn:52.76.210.159:5349',
          'turn:13.213.17.140:5349',
          'turn:15.222.242.167:5349',
        ],
        'username': '0xchat',
        'credential': 'Prettyvs511',
      },
      {
        'urls': [
          'turn:openrelay.metered.ca:80',
          'turn:openrelay.metered.ca:443',
          'turn:openrelay.metered.ca:443?transport=tcp',
        ],
        'username': 'openrelayproject',
        'credential': 'openrelayproject',
      },
    ],
    'iceTransportPolicy': 'all',
    'sdpSemantics': 'unified-plan',
    'bundlePolicy': 'max-bundle',
    'rtcpMuxPolicy': 'require',
    'iceCandidatePoolSize': 2,
  };

  static Map<String, dynamic> _rtcConfig = Map.from(defaultRtcConfig);
  static Map<String, dynamic> get rtcConfig => Map.unmodifiable(_rtcConfig);

  static Future<void>? _configSyncFuture;

  static List<String>? _testRelays;

  @visibleForTesting
  static void setRelaysForTesting(List<String>? testRelays) {
    _testRelays = testRelays != null ? List.from(testRelays) : null;
  }

  /// Deterministically distributes Nostr relays across rooms based on 5-digit roomCode hash.
  static List<String> roomRelaysForCode(String code) {
    if (_testRelays != null && _testRelays!.isNotEmpty) {
      return List.from(_testRelays!);
    }
    if (_relays.isEmpty) return const [];
    if (_relays.length <= 2) return List.unmodifiable(_relays);
    final primary = _relays.first;
    final fallbacks = _relays.sublist(1);
    final trimmed = code.trim();
    final hash =
        trimmed.codeUnits.fold<int>(0, (p, c) => (p * 31 + c) & 0x7FFFFFFF);
    final ordered = List<String>.generate(
      fallbacks.length,
      (i) => fallbacks[(hash + i) % fallbacks.length],
    );
    return [primary, ...ordered];
  }

  /// Fetches latest dynamic fleet configuration from GitHub raw / CDN in the background.
  /// Completely non-blocking with 2.5-second per-tier timeout, falling back seamlessly on network errors.
  static Future<void> syncRemoteConfig() {
    return _configSyncFuture ??= _syncRemoteConfigInternal();
  }

  static Future<void> _syncRemoteConfigInternal() async {
    try {
      final prefs = await SharedPreferences.getInstance();

      // 1. Immediately load any previously cached relays and ICE config
      final cachedRelaysJson = prefs.getString('maglis_cached_relays');
      if (cachedRelaysJson != null) {
        final List<dynamic> list = jsonDecode(cachedRelaysJson);
        if (list.isNotEmpty) {
          final List<String> loaded = list.map((e) => e.toString()).toList();
          // Filter out known dead or obsolete relays from old device caches
          const deadDomains = [
            'nostr.mom',
            'nos.lol',
            'offchain.pub',
            'nostr.bitcoiner.social',
            'relay.nostr.band',
            'relay.0xchat.com',
          ];
          final cleaned = loaded
              .where((r) => !deadDomains.any((d) => r.contains(d)))
              .toList();
          if (cleaned.isNotEmpty) {
            if (!cleaned.contains(defaultRelays.first)) {
              cleaned.insert(0, defaultRelays.first);
            }
            _relays = cleaned;
          }
        }
      }
      final cachedRtcJson = prefs.getString('maglis_cached_rtc');
      if (cachedRtcJson != null) {
        final Map<String, dynamic> rtc = jsonDecode(cachedRtcJson);
        final ice = rtc['iceServers'] as List?;
        if (ice != null && ice.isNotEmpty) {
          final mergedRtc = Map<String, dynamic>.from(defaultRtcConfig);
          mergedRtc.addAll(rtc);
          mergedRtc['iceServers'] = List.from(ice);
          _rtcConfig = mergedRtc;
        }
      }

      // 2. Multi-tier fallback config sync
      const edgeUrl =
          'https://quran-maglis.recitequrankarem.workers.dev/config';
      const cdnUrl =
          'https://cdn.jsdelivr.net/gh/Recite-Quran/Natlu@Natlu-%D8%A7%D9%84%D8%AD%D9%85%D8%AF%D9%84%D9%84%D9%87/maglis_relay/maglis_config.json';
      const primaryUrl =
          'https://raw.githubusercontent.com/Recite-Quran/Natlu/Natlu-%D8%A7%D9%84%D8%AD%D9%85%D8%AF%D9%84%D9%84%D9%87/maglis_relay/maglis_config.json';

      http.Response? res;
      // Try Tier 1: Cloudflare Edge
      try {
        res = await http
            .get(Uri.parse(edgeUrl))
            .timeout(const Duration(milliseconds: 2500));
      } catch (_) {}

      // Try Tier 2: jsDelivr CDN
      if (res == null || res.statusCode != 200) {
        try {
          res = await http
              .get(Uri.parse(cdnUrl))
              .timeout(const Duration(milliseconds: 2500));
        } catch (_) {}
      }

      // Try Tier 3: GitHub Raw
      if (res == null || res.statusCode != 200) {
        try {
          res = await http
              .get(Uri.parse(primaryUrl))
              .timeout(const Duration(milliseconds: 2500));
        } catch (_) {}
      }

      if (res != null && res.statusCode == 200) {
        final data = jsonDecode(res.body);
        if (data is Map<String, dynamic>) {
          if (data['relays'] is List) {
            final List<String> fetchedRelays = (data['relays'] as List)
                .map((e) => e.toString().trim())
                .where((s) => s.startsWith('ws://') || s.startsWith('wss://'))
                .toList();
            if (fetchedRelays.length >= 2) {
              _relays = fetchedRelays;
              await prefs.setString(
                  'maglis_cached_relays', jsonEncode(fetchedRelays));
            }
          }
          if (data['iceServers'] is List &&
              (data['iceServers'] as List).isNotEmpty) {
            final updatedRtc = Map<String, dynamic>.from(defaultRtcConfig);
            final List<dynamic> fetchedIce =
                List.from(data['iceServers'] as List);
            updatedRtc['iceServers'] = fetchedIce;
            _rtcConfig = updatedRtc;
            await prefs.setString('maglis_cached_rtc', jsonEncode(updatedRtc));
          }
        }
      }
    } catch (_) {
      // Fail-safe: silently continue with built-in defaults or existing cache
    }
  }
}

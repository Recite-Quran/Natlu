import 'dart:async';
import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import '../main.dart';
import '../ui/widgets/dialogs/dialog_service.dart';
import 'platform_utils.dart';

/// MaglisLinkService
///
/// Application-level deep link and App Links manager dedicated to Maglis sessions.
/// Listens to operating system incoming links and routes them to the UI facade.
/// Kept in lib/core/ to keep the lib/maglis/ engine folder completely isolated from UI.
class MaglisLinkService {
  MaglisLinkService._();
  static final MaglisLinkService instance = MaglisLinkService._();

  static const String baseUrl = 'https://natlu.pages.dev';

  AppLinks? _appLinks;
  StreamSubscription<Uri>? _sub;
  String? _lastHandledCode;
  DateTime? _lastHandledTime;

  bool isAppReady = false;
  String? _pendingRoomCode;

  /// Whether a room code arrived before the app finished initialization
  bool get hasPendingRoomCode => _pendingRoomCode != null;

  /// Builds short HTTPS share link: https://natlu.pages.dev/48291
  static String formatUrl(String code) => '$baseUrl/$code';

  /// Builds rich invitation message for any platform
  static String formatInviteText(String code, {required bool isArabic}) {
    final link = formatUrl(code);
    if (isArabic) {
      return '> إن الذين يتلون كتاب الله وأقاموا الصلاة وأنفقوا مما رزقناهم سرا وعلانية يرجون تجارة لن تبور\n\n'
          'منتظرك في مجلس التلاوة في تطبيق "اتلو القران" ❤️\n\n'
          '🔗 رابط الدخول:\n'
          '$link\n\n'
          'رمز المجلس: $code';
    } else {
      return '> Indeed, those who recite the Book of Allah and establish prayer and spend out of what We have provided them, secretly and publicly, expect a trade that will never perish.\n\n'
          'Waiting for you in our recitation circle on "Recite Quran" ❤️\n\n'
          '🔗 Direct Link:\n'
          '$link\n\n'
          'Maglis Code: $code';
    }
  }

  /// Extracts 5-digit room code from incoming URI
  static String? extractRoomCode(Uri uri) {
    final segments = uri.pathSegments;

    // 1. Direct root format: /48291
    if (segments.length == 1) {
      final code = segments.first.replaceAll(RegExp(r'\D'), '');
      if (code.length == 5) return code;
    }

    // 2. Prefixed path format: /m/48291
    final mIndex = segments.indexOf('m');
    if (mIndex != -1 && mIndex + 1 < segments.length) {
      final code = segments[mIndex + 1].replaceAll(RegExp(r'\D'), '');
      if (code.length == 5) return code;
    }

    // 3. Custom scheme: natlu://maglis/48291
    if (uri.scheme == 'natlu' && uri.host == 'maglis') {
      if (segments.isNotEmpty) {
        final code = segments.first.replaceAll(RegExp(r'\D'), '');
        if (code.length == 5) return code;
      }
    }

    // 4. Web Hash route format: #/48291 or #/m/48291
    if (uri.fragment.isNotEmpty) {
      final fragmentMatch =
          RegExp(r'(?:^|/)(?:m/)?(\d{5})(?:$|/)').firstMatch(uri.fragment);
      if (fragmentMatch != null) {
        return fragmentMatch.group(1);
      }
    }

    // 5. Query params fallback (if any external link passed params): ?m=48291 or ?code=48291
    final queryParam = uri.queryParameters['m'] ??
        uri.queryParameters['code'] ??
        uri.queryParameters['maglis'];
    if (queryParam != null) {
      final code = queryParam.replaceAll(RegExp(r'\D'), '');
      if (code.length == 5) return code;
    }

    return null;
  }

  /// Initializes deep link streams (cold start, warm resume, and Web)
  void init() {
    if (PlatformCapabilities.isWeb) {
      try {
        final code = extractRoomCode(Uri.base);
        if (code != null) {
          _pendingRoomCode = code;
        }
      } catch (_) {}
      return;
    }

    try {
      _appLinks = AppLinks();

      // Check cold-start initial launch URI
      _appLinks!.getInitialLink().then((uri) {
        if (uri != null) _handleIncomingUri(uri);
      }).catchError((_) {});

      // Listen to incoming URIs while running
      _sub?.cancel();
      _sub = _appLinks!.uriLinkStream.listen(
        _handleIncomingUri,
        onError: (_) {},
      );
    } catch (_) {}
  }

  void _handleIncomingUri(Uri uri) {
    final code = extractRoomCode(uri);
    if (code == null) return;

    // Debounce duplicate triggers within 3 seconds
    final now = DateTime.now();
    if (_lastHandledCode == code &&
        _lastHandledTime != null &&
        now.difference(_lastHandledTime!) < const Duration(seconds: 3)) {
      return;
    }
    _lastHandledCode = code;
    _lastHandledTime = now;

    final context = QuranApp.navigatorKey.currentContext;
    if (context != null && context.mounted && isAppReady) {
      _openJoinDialog(code);
    } else {
      _pendingRoomCode = code;
    }
  }

  /// Consumes cached room code after MaterialApp and Orchestrator are ready
  void consumePendingIfAny(BuildContext context) {
    final code = _pendingRoomCode;
    _pendingRoomCode = null;
    if (code != null) {
      _openJoinDialog(code);
    }
  }

  void _openJoinDialog(String code) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = QuranApp.navigatorKey.currentContext;
      if (ctx == null || !ctx.mounted) return;
      if (AppModalRouteObserver.instance.isModalOpen) {
        try {
          Navigator.of(ctx, rootNavigator: true).pop();
        } catch (_) {}
      }
      DialogService.showMaglisEntry(ctx, initialTab: 0, initialCode: code);
    });
  }

  void dispose() {
    _sub?.cancel();
    _sub = null;
  }
}

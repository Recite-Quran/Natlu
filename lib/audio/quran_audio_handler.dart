import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';

import '../core/highlighting_controller.dart' show QuranMetadata;
import 'quran_audio_service.dart';

/// Central AudioHandler connecting `just_audio` to `audio_service` and Android MediaSession.
///
/// Implements a unified, single-instance background and lockscreen media notification:
/// - Exact 3 controls: Previous, Play/Pause, Next
/// - App logo cached and passed as [MediaItem.artUri]
/// - Tagged and labeled: "القران العظيم"
/// - Swipe-to-dismiss support: `androidStopForegroundOnPause: true` + [onNotificationDeleted] -> stops audio.
class QuranAudioHandler extends BaseAudioHandler
    with QueueHandler, SeekHandler {
  static QuranAudioHandler? _instance;
  static QuranAudioHandler get instance =>
      _instance ??= QuranAudioHandler._internal();

  static bool _isServiceInitialized = false;
  static Uri? _cachedArtUri;

  QuranAudioHandler._internal();

  /// Initializes the system AudioService singleton on mobile platforms (Android & iOS).
  /// Safe to call multiple times; executes only once.
  static Future<void> ensureInitialized() async {
    if (_isServiceInitialized) return;
    // TODO(playstore-fgs): Temporarily skipped on Android while FOREGROUND_SERVICE_MEDIA_PLAYBACK
    // is removed for Play Store update; restore (!Platform.isAndroid && !Platform.isIOS) next update.
    if (kIsWeb || !Platform.isIOS) {
      return;
    }

    try {
      await _cacheAppIconUri();

      await AudioService.init(
        builder: () => instance,
        config: const AudioServiceConfig(
          androidNotificationChannelId: 'com.recitequran.app.audio',
          androidNotificationChannelName: 'القران العظيم',
          androidNotificationOngoing: false,
          androidStopForegroundOnPause: true,
          androidNotificationIcon: 'mipmap/ic_launcher',
          androidShowNotificationBadge: true,
        ),
      );

      _isServiceInitialized = true;
    } catch (e, stack) {
      debugPrint('[QuranAudioHandler] Initialization error: $e\n$stack');
    }
  }

  /// Caches the app logo asset from `assets/icon/app_icon.png` to disk so Android
  /// MediaStyle notification and lockscreen artwork can load it instantly via file URI.
  static Future<void> _cacheAppIconUri() async {
    if (_cachedArtUri != null) return;
    try {
      final byteData = await rootBundle.load('assets/icon/app_icon.png');
      final tempDir = await getTemporaryDirectory();
      final file = File('${tempDir.path}/quran_app_logo.png');
      if (!file.existsSync() || file.lengthSync() != byteData.lengthInBytes) {
        await file.writeAsBytes(byteData.buffer.asUint8List(), flush: true);
      }
      _cachedArtUri = Uri.file(file.path);
    } catch (e) {
      debugPrint('[QuranAudioHandler] Failed to cache app logo: $e');
    }
  }

  /// Updates the current verse metadata in the system notification.
  void updateVerse({required int surah, required int ayah}) {
    if (!_isServiceInitialized) return;

    final String surahName = QuranMetadata.getSurahNameArabic(surah);
    final String verseLabel = 'سورة $surahName - الآية $ayah';

    final item = MediaItem(
      id: '$surah:$ayah',
      album: 'القران العظيم',
      title: verseLabel,
      displayTitle: 'القران العظيم',
      displaySubtitle: verseLabel,
      artUri: _cachedArtUri,
    );

    mediaItem.add(item);
  }

  /// Synchronizes `just_audio` player state directly into `audio_service` PlaybackState.
  void syncPlaybackState({
    required AudioPlayer player,
    required bool isPlaying,
    required bool isBuffering,
  }) {
    if (!_isServiceInitialized) return;

    AudioProcessingState processing;
    if (isBuffering ||
        player.processingState == ProcessingState.loading ||
        player.processingState == ProcessingState.buffering) {
      processing = AudioProcessingState.buffering;
    } else if (player.processingState == ProcessingState.ready) {
      processing = AudioProcessingState.ready;
    } else if (player.processingState == ProcessingState.completed) {
      processing = AudioProcessingState.completed;
    } else {
      processing = AudioProcessingState.idle;
    }

    playbackState.add(
      PlaybackState(
        controls: [
          MediaControl.skipToPrevious,
          if (isPlaying) MediaControl.pause else MediaControl.play,
          MediaControl.skipToNext,
        ],
        systemActions: const {
          MediaAction.seek,
          MediaAction.seekForward,
          MediaAction.seekBackward,
        },
        androidCompactActionIndices: const [0, 1, 2],
        processingState: processing,
        playing: isPlaying,
        updatePosition: player.position,
        bufferedPosition: player.bufferedPosition,
        speed: player.speed,
      ),
    );
  }

  /// Resets the notification state when playback stops.
  void resetState() {
    if (!_isServiceInitialized) return;
    playbackState.add(
      PlaybackState(
        controls: const [],
        processingState: AudioProcessingState.idle,
        playing: false,
      ),
    );
  }

  // ── System Media Controls Callbacks (Lock Screen / Notification Drawer) ──

  @override
  Future<void> play() async {
    await QuranAudioService.instance.resume();
  }

  @override
  Future<void> pause() async {
    await QuranAudioService.instance.pause();
  }

  @override
  Future<void> skipToNext() async {
    await QuranAudioService.instance.skipToNextAyah();
  }

  @override
  Future<void> skipToPrevious() async {
    await QuranAudioService.instance.skipToPreviousAyah();
  }

  @override
  Future<void> seek(Duration position) async {
    await QuranAudioService.instance.seek(position);
  }

  @override
  Future<void> stop() async {
    await QuranAudioService.instance.stop();
  }

  /// Triggered on Android when the user swipes away the notification from the drawer.
  /// Fulfills user requirement: "when user swipe it away then it is removed and audio stops".
  @override
  Future<void> onNotificationDeleted() async {
    await stop();
    return super.onNotificationDeleted();
  }
}

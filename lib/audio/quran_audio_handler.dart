import 'dart:async';
import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart';
import 'quran_audio_service.dart';

/// Central AudioHandler for system playback notifications and lock screen controls.
///
/// Directly matches the professional stream-pipelined architecture of `quran_library`:
/// - 4 controls: [skipToPrevious, play/pause, stop, skipToNext].
/// - Compact action indices: [0, 1, 3] (previous, play/pause, next in compact view;
///   stop button accessible in expanded status bar and media notification card).
/// - Event-driven: pipes JustAudio's native `playbackEventStream` into `playbackState`
///   with zero lag, zero polling, and zero CPU overhead.
/// - Exactly one notification instance: preserves foreground service without zombie
///   duplications across verse switches and pause/play cycles.
/// - Dismissible on pause: allows clean swipe-to-kill removal when paused.
class QuranAudioHandler extends BaseAudioHandler with QueueHandler, SeekHandler {
  static final QuranAudioHandler instance = QuranAudioHandler._();
  
  StreamSubscription<PlaybackEvent>? _playbackEventSub;
  StreamSubscription<Duration?>? _durationSub;
  AudioPlayer? _player;

  QuranAudioHandler._() {
    mediaItem.add(VerseAudioPlayer.defaultMediaItem);
    attachPlayer(QuranAudioService.instance.audioPlayer);
  }

  /// Attaches the native JustAudio player to this AudioHandler.
  void attachPlayer(AudioPlayer player) {
    if (_player == player) return;
    _playbackEventSub?.cancel();
    _durationSub?.cancel();
    _player = player;

    _playbackEventSub = player.playbackEventStream.listen((event) {
      playbackState.add(_transformEvent(player, event));
    });

    _durationSub = player.durationStream.listen((duration) {
      final current = mediaItem.value;
      if (current != null && duration != null && current.duration != duration) {
        mediaItem.add(current.copyWith(duration: duration));
      }
    });

    playbackState.add(_transformEvent(player, player.playbackEvent));
  }

  @override
  Future<void> updateMediaItem(MediaItem mediaItem) async {
    this.mediaItem.add(mediaItem);
  }

  /// Transforms JustAudio events into AudioService PlaybackState.
  ///
  /// Matches `quran_library`:
  /// - Controls: [skipToPrevious, play/pause, stop, skipToNext].
  /// - Compact indices: [0, 1, 3].
  /// - Guard: avoids sending [AudioProcessingState.idle] during track preparation
  ///   so Android's foreground service is never abruptly destroyed and resurrected,
  ///   preventing duplicate/ghost notification instances.
  PlaybackState _transformEvent(AudioPlayer player, PlaybackEvent event) {
    final bool playing = player.playing;
    final bool isPreparing = QuranAudioService.instance.isPreparingNewTrack;

    final AudioProcessingState processingState;
    if (isPreparing) {
      processingState = AudioProcessingState.loading;
    } else {
      processingState = const {
        ProcessingState.idle: AudioProcessingState.idle,
        ProcessingState.loading: AudioProcessingState.loading,
        ProcessingState.buffering: AudioProcessingState.buffering,
        ProcessingState.ready: AudioProcessingState.ready,
        ProcessingState.completed: AudioProcessingState.completed,
      }[player.processingState] ?? AudioProcessingState.idle;
    }

    return PlaybackState(
      controls: [
        MediaControl.skipToPrevious,
        MediaControl.stop,
        MediaControl.skipToNext,
      ],
      systemActions: const {
        MediaAction.seek,
        MediaAction.seekForward,
        MediaAction.seekBackward,
        MediaAction.skipToPrevious,
        MediaAction.skipToNext,
        MediaAction.stop,
      },
      androidCompactActionIndices: const [0, 1, 2],
      processingState: processingState,
      playing: playing,
      updatePosition: player.position,
      bufferedPosition: player.bufferedPosition,
      speed: player.speed,
      queueIndex: event.currentIndex,
    );
  }

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
    playbackState.add(playbackState.value.copyWith(
      processingState: AudioProcessingState.idle,
      playing: false,
    ));
    await super.stop();
  }

  @override
  Future<void> onNotificationDeleted() async {
    await stop();
  }
}

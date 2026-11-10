import 'dart:async';
import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart';
import 'quran_audio_service.dart';

/// Central AudioHandler for system playback notifications and lock screen controls.
///
/// Directly matches the professional stream-pipelined architecture of `quran_library`:
/// - Strictly displays 3 controls: [previous verse, play/pause, next verse].
/// - Event-driven: pipes JustAudio's native `playbackEventStream` into `playbackState`
///   with zero lag, zero polling, and zero CPU overhead.
/// - Maintains notification on lock screen and drawer when paused for instant resumption.
class QuranAudioHandler extends BaseAudioHandler with QueueHandler, SeekHandler {
  static final QuranAudioHandler instance = QuranAudioHandler._();
  
  StreamSubscription<PlaybackEvent>? _playbackEventSub;
  StreamSubscription<Duration?>? _durationSub;
  AudioPlayer? _player;

  QuranAudioHandler._() {
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
  /// Enforces strictly 3 controls: [skipToPrevious, play/pause, skipToNext].
  /// Compact action indices [0, 1, 2] ensure all 3 are displayed in lockscreen and
  /// collapsed notification panels without extra buttons (such as stop).
  PlaybackState _transformEvent(AudioPlayer player, PlaybackEvent event) {
    final bool playing = player.playing;
    return PlaybackState(
      controls: [
        MediaControl.skipToPrevious,
        if (playing) MediaControl.pause else MediaControl.play,
        MediaControl.skipToNext,
      ],
      systemActions: const {
        MediaAction.seek,
        MediaAction.seekForward,
        MediaAction.seekBackward,
      },
      androidCompactActionIndices: const [0, 1, 2],
      processingState: const {
        ProcessingState.idle: AudioProcessingState.idle,
        ProcessingState.loading: AudioProcessingState.loading,
        ProcessingState.buffering: AudioProcessingState.buffering,
        ProcessingState.ready: AudioProcessingState.ready,
        ProcessingState.completed: AudioProcessingState.completed,
      }[player.processingState] ?? AudioProcessingState.idle,
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
    await super.stop();
  }
}

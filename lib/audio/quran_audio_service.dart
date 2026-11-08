import 'dart:async';
import 'package:flutter/foundation.dart';
import '../state/highlighting_controller.dart';
import 'verse_audio_player.dart';

/// Central Quran Audio Service facade.
///
/// Unifies both word-level auditioning and full-Ayah recitation under the exact same
/// professional audio engine (matching `AudioCtrl` from `quran_library`):
/// - Reciter: Mahmoud Khalil Al-Husary exclusively across both words and ayahs.
/// - Data Source: MP3Quran v4 streaming API with sample-accurate timestamp seeking.
/// - Zero player conflict: uses a single [AudioPlayer] instance to eliminate native
///   audio focus contention, resource duplication, and "Loading interrupted" crashes.
class QuranAudioService {
  QuranAudioService._() {
    _player.onAudioProgress = ({
      int? surah,
      int? ayah,
      int? wordIndex,
      required bool isPlaying,
      required bool isBuffering,
    }) {
      onAudioProgress?.call(
        surah: surah,
        ayah: ayah,
        wordIndex: wordIndex,
        isPlaying: isPlaying,
        isBuffering: isBuffering,
      );
    };
    _player.onPlayingChanged = (playing) {
      isPlayingNotifier.value = playing;
      onPlayingChanged?.call(playing);
    };
  }
  static final QuranAudioService instance = QuranAudioService._();

  final VerseAudioPlayer _player = VerseAudioPlayer();

  final ValueNotifier<bool> isPlayingNotifier = ValueNotifier<bool>(false);
  AudioProgressCallback? onAudioProgress;
  ValueChanged<bool>? onPlayingChanged;

  bool get isSingleWordMode => _player.isSingleWordMode;
  bool get isPaused => _player.isPaused;
  bool get isPlaying => _player.isPlaying;
  bool get isBuffering => _player.isBuffering;
  int? get activeSurah => _player.activeSurah;
  int? get activeAyah => _player.activeAyah;
  int? get activeWordIndex => _player.activeWordIndex;

  /// Returns the streaming URL for a Surah audio file from MP3Quran.
  static String getSurahAudioUrl(int surah) =>
      VerseAudioPlayer.getSurahAudioUrl(surah);

  /// Pre-caches or resolves Ayah audio file in background for instant 0ms playback.
  static Future<String> ensureAyahDownloaded(int surah, int ayah) =>
      VerseAudioPlayer.ensureAyahDownloaded(surah, ayah);

  /// Plays an individual word alone using Al-Husary's recitation from MP3Quran.
  Future<void> playWord({
    required int surah,
    required int ayah,
    required int wordIndex,
  }) async {
    await _player.playWord(
      surah: surah,
      ayah: ayah,
      wordIndex: wordIndex,
    );
  }

  /// Plays the specified [ayah] in [surah] recited by Mahmoud Khalil Al-Husary.
  Future<void> play({
    required int surah,
    required int ayah,
    required bool continuous,
  }) async {
    await _player.play(
      surah: surah,
      ayah: ayah,
      continuous: continuous,
    );
  }

  /// Pauses the active playback.
  Future<void> pause() async {
    await _player.pause();
  }

  /// Resumes the paused playback.
  Future<void> resume() async {
    await _player.resume();
  }

  /// Completely stops playback and resets state.
  Future<void> stop() async {
    await _player.stop();
  }

  /// Releases all player resources.
  Future<void> dispose() async {
    await _player.dispose();
  }

  /// Toggles Ayah playback: if currently playing -> pause; if paused -> resume; otherwise -> play.
  Future<void> toggleAyah({
    required int surah,
    required int ayah,
    required HighlightingController controller,
    bool continuous = true,
    VoidCallback? onTap,
  }) async {
    if (controller.isAudioBuffering &&
        controller.audioSurah == surah &&
        controller.audioAyah == ayah) {
      return;
    }
    onTap?.call();

    if (controller.isAudioPlaying &&
        controller.audioSurah == surah &&
        controller.audioAyah == ayah) {
      await pause();
    } else if (controller.isAudioPaused &&
        controller.audioSurah == surah &&
        controller.audioAyah == ayah) {
      await resume();
    } else {
      await play(
        surah: surah,
        ayah: ayah,
        continuous: continuous,
      );
    }
  }
}

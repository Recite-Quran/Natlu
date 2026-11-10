import 'dart:async';
import 'dart:developer' show log;
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:audio_session/audio_session.dart';
import 'package:http/http.dart' as http;
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:path_provider/path_provider.dart';
import '../core/app_state.dart';
import '../core/highlighting_controller.dart';
import 'quran_timing_service.dart';

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
      bool? isPaused,
    }) {
      onAudioProgress?.call(
        surah: surah,
        ayah: ayah,
        wordIndex: wordIndex,
        isPlaying: isPlaying,
        isBuffering: isBuffering,
        isPaused: isPaused,
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

  /// Skips to the next Ayah in the Surah or subsequent Surah.
  Future<void> skipToNextAyah() async {
    await _player.skipToNextAyah();
  }

  /// Skips to the previous Ayah in the Surah or prior Surah.
  Future<void> skipToPreviousAyah() async {
    await _player.skipToPreviousAyah();
  }

  /// Releases all player resources.
  Future<void> dispose() async {
    await _player.dispose();
  }

  /// Toggles Ayah playback: if currently playing/buffering this ayah -> stop; otherwise -> stop any active playback and play.
  Future<void> toggleAyah({
    required int surah,
    required int ayah,
    required HighlightingController controller,
    bool continuous = true,
    VoidCallback? onTap,
  }) async {
    onTap?.call();

    final bool isThisAyahActive =
        (controller.isAudioPlaying || controller.isAudioBuffering) &&
        controller.audioSurah == surah &&
        controller.audioAyah == ayah;

    if (isThisAyahActive) {
      // STOP button pressed: stop playback completely
      await stop();
      controller.clearAudio();
    } else {
      // PLAY button pressed: stop any existing audio first to avoid collision, then play
      if (controller.isAudioActive || isPlaying || isBuffering) {
        await stop();
        controller.clearAudio();
      }
      await play(
        surah: surah,
        ayah: ayah,
        continuous: continuous,
      );
    }
  }
}

/// Verse and word audio playback service directly matching the professional architecture
/// and stability patterns of `quran_library` and `alquranalkareem`.
///
/// Architecture & Highlights:
/// - **Reciter**:  Mahmoud Khalil Al-Husary at **64kbps** (per-Ayah files from EveryAyah).
/// - **Zero Full-Surah Downloads**: Only downloads isolated, tiny per-Ayah files (~20-40 KB each).
/// - **Fast First-Time Local Disk Cache**: Caches each Ayah file to `quran_audio/Husary_64kbps/$s$a.mp3`.
///   Once cached, playback from disk is 100% instant (0ms latency, zero network wait).
/// - **Frame-Accurate Word Highlighting**: Synced with Quran.com Reciter 6 (Mahmoud Khalil Al-Husary)
///   0ms-relative word segments from [QuranTimingService].
/// - **Single Word Playback**: Plays any tapped word in  Al-Husary's voice by seeking to
///   the exact millisecond boundaries of that word in the cached Ayah file.
/// - **Background Pre-Warming**: While Ayah $N$ is actively playing, automatically pre-downloads
///   Ayah $N+1$ so continuous transitions between verses are seamless.
/// Progress callback signature emitted by [VerseAudioPlayer].
typedef AudioProgressCallback = void Function({
  int? surah,
  int? ayah,
  int? wordIndex,
  required bool isPlaying,
  required bool isBuffering,
  bool? isPaused,
});

class VerseAudioPlayer {
  static const String everyAyahHusaryBaseUrl =
      'https://everyayah.com/data/Husary_64kbps';

  /// Canonical Ayah count for Surahs 1 to 114 from QuranMetadata.
  static List<int> get surahAyahCounts => QuranMetadata.surahAyahCounts;

  AudioPlayer? _player;
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<PlayerState>? _playerStateSub;
  StreamSubscription<SequenceState?>? _sequenceSub;

  int _sessionId = 0;
  int? _currentSurah;
  int? _currentAyah;
  bool _isContinuous = true;
  bool _isHandlingComplete = false;
  bool _isAdvancingSurah = false;
  double _lastCompleteTime = 0.0;

  // Gapless continuous playlist state
  List<int> _playlistAyahs = [];
  int? _playlistSurah;
  bool _isPreparingNewTrack = false;

  // Single word auditioning mode state
  bool _isSingleWordMode = false;
  int? _targetWordIndex;
  int? _targetWordEndMs;

  // Pause retention state
  bool _isPaused = false;
  int? _pausedSurah;
  int? _pausedAyah;
  int? _pausedWordIndex;

  AudioProgressCallback? onAudioProgress;
  ValueChanged<bool>? onPlayingChanged;

  int? _activeSurah;
  int? _activeAyah;
  int? _activeWordIndex;
  bool _isPlaying = false;
  bool _isBuffering = false;

  bool get isPaused => _isPaused;
  int? get pausedSurah => _pausedSurah;
  int? get pausedAyah => _pausedAyah;
  int? get pausedWordIndex => _pausedWordIndex;
  bool get isPlaying => _isPlaying;
  bool get isBuffering => _isBuffering;
  bool get isSingleWordMode => _isSingleWordMode;
  int? get activeWordIndex => _activeWordIndex ?? _targetWordIndex;
  int? get currentSurah => _activeSurah ?? _currentSurah;
  int? get currentAyah => _activeAyah ?? _currentAyah;
  int? get activeSurah => _activeSurah;
  int? get activeAyah => _activeAyah;

  void _notifyProgress() {
    onAudioProgress?.call(
      surah: _activeSurah,
      ayah: _activeAyah,
      wordIndex: _activeWordIndex,
      isPlaying: _isPlaying,
      isBuffering: _isBuffering,
      isPaused: _isPaused,
    );
  }

  void _setBuffering(bool buffering) {
    if (_isBuffering != buffering) {
      _isBuffering = buffering;
      _notifyProgress();
    }
  }

  void _setPlaying(bool playing) {
    if (_isPlaying != playing) {
      _isPlaying = playing;
      onPlayingChanged?.call(playing);
      _notifyProgress();
    }
  }

  void _setVerse(int? surah, int? ayah) {
    bool changed = false;
    if (_activeSurah != surah) {
      _activeSurah = surah;
      changed = true;
    }
    if (_activeAyah != ayah) {
      _activeAyah = ayah;
      changed = true;
    }
    if (changed) {
      if (surah != null && ayah != null) {
        AppState.instance.saveLastPosition(surah, ayah);
      }
      _notifyProgress();
    }
  }

  void _setWordIndex(int? wordIndex) {
    if (_activeWordIndex != wordIndex) {
      _activeWordIndex = wordIndex;
      _notifyProgress();
    }
  }

  /// Formats the standard canonical 6-digit audio filename (e.g. 001001.mp3).
  static String formatAyahAudioFileName(int surah, int ayah) {
    final s = surah.toString().padLeft(3, '0');
    final a = ayah.toString().padLeft(3, '0');
    return '$s$a.mp3';
  }

  /// Returns the per-Ayah 64kbps audio URL ( Mahmoud Khalil Al-Husary).
  static String getAyahAudioUrl(int surah, int ayah) {
    return '$everyAyahHusaryBaseUrl/${formatAyahAudioFileName(surah, ayah)}';
  }

  /// Backward-compatible URL helper.
  static String getSurahAudioUrl(int surah) => getAyahAudioUrl(surah, 1);

  static String? _cachedAudioDirPath;

  /// Resolves the local disk cache file for an Ayah.
  static Future<File> getLocalAyahFile(int surah, int ayah) async {
    if (_cachedAudioDirPath == null) {
      final dir = await getApplicationSupportDirectory();
      final audioDir = Directory('${dir.path}/quran_audio/Husary_64kbps');
      if (!audioDir.existsSync()) {
        audioDir.createSync(recursive: true);
      }
      _cachedAudioDirPath = audioDir.path;
    }
    return File('$_cachedAudioDirPath/${formatAyahAudioFileName(surah, ayah)}');
  }

  /// Creates MediaItem metadata for background notification and lock screen controls.
  /// Shows strictly the Surah name and Ayah number as required for minimal, elegant playback display.
  static MediaItem createMediaItem(int surah, int ayah) {
    final surahName = QuranMetadata.getSurahNameArabic(surah);
    final ayahStr = QuranTypography.toArabicDigits(ayah);
    return MediaItem(
      id: '$surah:$ayah',
      album: 'سورة $surahName',
      title: 'سورة $surahName',
      artist: 'الآية $ayahStr',
      artUri: Uri.parse('asset:///assets/icon/app_icon.png'),
    );
  }

  /// Creates an AudioSource for an Ayah, utilizing local cached file if present,
  /// or progressive streaming URL, tagged with MediaItem for background notification.
  static Future<AudioSource> createAyahAudioSource(int surah, int ayah) async {
    final url = getAyahAudioUrl(surah, ayah);
    final mediaItem = createMediaItem(surah, ayah);
    if (kIsWeb) {
      return AudioSource.uri(Uri.parse(url), tag: mediaItem);
    }
    try {
      final file = await getLocalAyahFile(surah, ayah);
      if (file.existsSync() && file.lengthSync() > 1024) {
        return AudioSource.file(file.path, tag: mediaItem);
      }
      return AudioSource.uri(Uri.parse(url), tag: mediaItem);
    } catch (_) {
      return AudioSource.uri(Uri.parse(url), tag: mediaItem);
    }
  }

  static final Set<String> _inFlightDownloads = {};

  /// Fast first-time cache: checks local disk first (0ms), otherwise downloads
  /// the tiny ~20KB file to disk once for instant offline playback.
  static Future<String> ensureAyahDownloaded(int surah, int ayah) async {
    final url = getAyahAudioUrl(surah, ayah);
    if (kIsWeb) {
      return url;
    }
    try {
      final file = await getLocalAyahFile(surah, ayah);
      if (file.existsSync() && file.lengthSync() > 1024) {
        return file.path;
      }

      await _downloadAndCacheAyah(surah, ayah, file);
      if (file.existsSync() && file.lengthSync() > 1024) {
        return file.path;
      }
      return url;
    } catch (_) {
      return url;
    }
  }

  static Future<void> _downloadAndCacheAyah(
    int surah,
    int ayah,
    File file,
  ) async {
    if (kIsWeb) return;
    final key = '$surah:$ayah';
    if (_inFlightDownloads.contains(key)) return;
    _inFlightDownloads.add(key);

    final client = http.Client();
    try {
      final url = getAyahAudioUrl(surah, ayah);
      final res = await client.get(
        Uri.parse(url),
        headers: {
          if (!kIsWeb) 'User-Agent': 'Flutter/Natlu',
        },
      ).timeout(const Duration(seconds: 15));

      if (res.statusCode == 200 && res.bodyBytes.isNotEmpty) {
        final tmpFile = File('${file.path}.tmp');
        await tmpFile.writeAsBytes(res.bodyBytes, flush: true);
        if (tmpFile.existsSync() && tmpFile.lengthSync() > 1024) {
          if (file.existsSync()) {
            try {
              file.deleteSync();
            } catch (_) {}
          }
          await tmpFile.rename(file.path);
        }
      }
    } catch (_) {
      // Background cache failure is non-fatal; playback continues via HTTP stream
    } finally {
      _inFlightDownloads.remove(key);
      client.close();
    }
  }

  /// Cancels all active subscriptions.
  void cancelAllSubscriptions() {
    _positionSub?.cancel();
    _positionSub = null;
    _playerStateSub?.cancel();
    _playerStateSub = null;
    _sequenceSub?.cancel();
    _sequenceSub = null;
  }

  /// Explicitly configures and activates the native media audio session (STREAM_MUSIC)
  /// so recitation plays through high-fidelity media speakers at full volume.
  static Future<void> ensureMediaAudioSession() async {
    if (!kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS)) {
      try {
        final session = await AudioSession.instance;
        await session.configure(const AudioSessionConfiguration.music());
        await session.setActive(true);
      } catch (_) {}
    }
  }

  AudioPlayer get _audioPlayer {
    if (_player == null) {
      final p = AudioPlayer(
        handleInterruptions: true,
        handleAudioSessionActivation: true,
      );
      _player = p;
      _ensureSubscriptions(p);
    } else {
      _ensureSubscriptions(_player!);
    }
    return _player!;
  }

  void _ensureSubscriptions(AudioPlayer p) {
    _positionSub ??= p
        .createPositionStream(
          minPeriod: const Duration(milliseconds: 20),
          maxPeriod: const Duration(milliseconds: 40),
        )
        .listen(_handlePosition);
    _sequenceSub ??= p.sequenceStateStream.listen((seqState) {
      if (_isSingleWordMode || _isPaused) return;
      _handleIndexChanged(seqState.currentIndex);
    });

    _playerStateSub ??= p.playerStateStream.listen((state) {
      final isBuffering = state.processingState == ProcessingState.buffering ||
          state.processingState == ProcessingState.loading;
      _setBuffering(isBuffering);

      if (state.processingState == ProcessingState.completed) {
        _handleTrackComplete();
      } else if (state.processingState == ProcessingState.idle) {
        if (!_isAdvancingSurah && !_isPreparingNewTrack) {
          _resetStopped();
        }
      } else if (state.playing) {
        _setPlaying(true);
        // When audio officially begins playing, activate target word or word 0
        if (_isSingleWordMode) {
          if (_targetWordIndex != null) {
            _setWordIndex(_targetWordIndex);
          }
        } else if (_activeWordIndex == null) {
          _setWordIndex(0);
        }
      } else if (!state.playing && !isBuffering && !_isAdvancingSurah && !_isPreparingNewTrack) {
        _setPlaying(false);
      }
    });
  }

  /// Handles playlist index changes for seamless gapless transition between Ayahs.
  void _handleIndexChanged(int? index) {
    if (_isSingleWordMode || _isPaused) return;
    if (_playlistAyahs.isEmpty) return;
    if (index == null || index < 0 || index >= _playlistAyahs.length) return;

    final newAyah = _playlistAyahs[index];
    final surah = _playlistSurah ?? _currentSurah;
    if (surah == null) return;

    if (_currentAyah != newAyah || _currentSurah != surah) {
      _currentAyah = newAyah;
      _currentSurah = surah;
      _setVerse(surah, newAyah);
      _setWordIndex(0);
    }

    final maxAyahs = QuranMetadata.getAyahCount(surah);

    // Pre-cache next Ayah to disk in background
    if (newAyah < maxAyahs) {
      unawaited(ensureAyahDownloaded(surah, newAyah + 1));
    } else if (surah < 114) {
      // Near end of Surah: pre-load next Surah's first Ayah and timings!
      unawaited(ensureAyahDownloaded(surah + 1, 1));
      unawaited(QuranTimingService.instance.ensureSurahLoaded(surah + 1));
    }
  }

  /// Plays a single word in [ayah] of [surah] recited by  Mahmoud Khalil Al-Husary.
  Future<void> playWord({
    required int surah,
    required int ayah,
    required int wordIndex,
  }) async {
    final int session = ++_sessionId;

    try {
      _player?.stop();
    } catch (_) {}

    _isPreparingNewTrack = true;
    _isSingleWordMode = true;
    _isPaused = false;
    _currentSurah = surah;
    _currentAyah = ayah;
    _targetWordIndex = wordIndex;
    _isContinuous = false;
    _playlistSurah = surah;
    _playlistAyahs = [ayah];

    _setVerse(surah, ayah);
    _setWordIndex(wordIndex);
    _setBuffering(true);
    _setPlaying(false);

    try {
      // 1. Ensure timings are loaded from Quran.com / disk cache
      final surahTiming =
          await QuranTimingService.instance.ensureSurahLoaded(surah);
      if (session != _sessionId) {
        _isPreparingNewTrack = false;
        return;
      }

      final ayahTiming = surahTiming?.getAyah(ayah);
      WordTiming? targetWord;
      if (ayahTiming != null && ayahTiming.words.isNotEmpty) {
        for (final w in ayahTiming.words) {
          if (w.wordIndex == wordIndex) {
            targetWord = w;
            break;
          }
        }
        if (targetWord == null &&
            wordIndex >= 0 &&
            wordIndex < ayahTiming.words.length) {
          targetWord = ayahTiming.words[wordIndex];
        }
      }

      await ensureMediaAudioSession();
      final player = _audioPlayer;

      // Ensure local file is on disk for instant 0ms auditioning
      await ensureAyahDownloaded(surah, ayah);
      if (session != _sessionId) {
        _isPreparingNewTrack = false;
        return;
      }

      // 2. Fetch/resolve cached 64kbps Ayah file AudioSource
      final source = await createAyahAudioSource(surah, ayah);
      if (session != _sessionId) {
        _isPreparingNewTrack = false;
        return;
      }

      int startMs = 0;
      int endMs = 2000;
      if (targetWord != null) {
        startMs = targetWord.startMs;
        endMs = targetWord.endMs;
      } else if (ayahTiming != null && ayahTiming.words.isNotEmpty) {
        final last = ayahTiming.words.last;
        startMs = last.startMs;
        endMs = last.endMs;
      } else {
        // Fallback: estimate bounded word slice
        startMs = (wordIndex * 600).clamp(0, 30000);
        endMs = startMs + 800;
      }

      _targetWordEndMs = endMs;

      try {
        await player.stop();
      } catch (_) {}
      if (session != _sessionId) {
        _isPreparingNewTrack = false;
        return;
      }

      AudioSource wordSource = source;
      if (source is UriAudioSource) {
        wordSource = ClippingAudioSource(
          child: source,
          start: Duration(milliseconds: startMs),
          end: Duration(milliseconds: endMs),
          tag: createMediaItem(surah, ayah),
        );
      }

      await player.setAudioSources([wordSource]);
      if (session != _sessionId) {
        _isPreparingNewTrack = false;
        return;
      }

      _isPreparingNewTrack = false;
      _setBuffering(false);
      _setPlaying(true);
      _setWordIndex(wordIndex);

      await player.play();
    } on PlatformException catch (e, stack) {
      _isPreparingNewTrack = false;
      if (session == _sessionId) {
        log('PlatformException in playWord: ${e.message}',
            name: 'VerseAudioPlayer', error: e, stackTrace: stack);
        _resetStopped(triggerError: true);
      }
    } catch (e, stack) {
      _isPreparingNewTrack = false;
      if (session == _sessionId) {
        log('Error playing word $surah:$ayah:$wordIndex: $e',
            name: 'VerseAudioPlayer', error: e, stackTrace: stack);
        _resetStopped(triggerError: true);
      }
    }
  }

  /// Plays [ayah] in [surah] recited by  Mahmoud Khalil Al-Husary (64kbps) with
  /// gapless 0ms playlist queuing matching `quran_library`.
  Future<void> play({
    required int surah,
    required int ayah,
    required bool continuous,
  }) async {
    final int session = ++_sessionId;

    _isPreparingNewTrack = true;
    _playlistAyahs = [];

    // Synchronously stop any active audio immediately so no old playback or
    // position callbacks leak through while loading the new verse.
    try {
      _player?.stop();
    } catch (_) {}

    // Fast-path resume if this exact Ayah was paused (and not single-word mode)
    if (!_isSingleWordMode &&
        _player != null &&
        _currentSurah == surah &&
        _currentAyah == ayah &&
        _player!.processingState == ProcessingState.ready &&
        !_player!.playing) {
      _isContinuous = continuous;
      _isPreparingNewTrack = false;
      await resume();
      return;
    }

    _isSingleWordMode = false;
    _targetWordIndex = null;
    _targetWordEndMs = null;
    _isPaused = false;
    _currentSurah = surah;
    _currentAyah = ayah;
    _isContinuous = continuous;
    _playlistSurah = surah;

    _setVerse(surah, ayah);
    _setWordIndex(0);
    _setBuffering(true);
    _setPlaying(false);

    // Pre-warm Surah timing in background
    unawaited(QuranTimingService.instance.ensureSurahLoaded(surah));

    try {
      await ensureMediaAudioSession();
      final player = _audioPlayer;
      final int maxAyahs = QuranMetadata.getAyahCount(surah);

      // Ensure current Ayah audio is cached
      await ensureAyahDownloaded(surah, ayah);
      if (session != _sessionId) {
        _isPreparingNewTrack = false;
        return;
      }

      // In continuous mode, build playlist starting directly at [ayah] through the rest of the Surah.
      // Index 0 is always the requested Ayah, preventing any spurious playback jumps to Ayah 1 or Page 2.
      _playlistAyahs = continuous
          ? [for (int a = ayah; a <= maxAyahs; a++) a]
          : [ayah];
      _playlistSurah = surah;

      final sources = await Future.wait(
        _playlistAyahs.map((a) => createAyahAudioSource(surah, a)),
      );
      if (session != _sessionId) {
        _isPreparingNewTrack = false;
        return;
      }

      try {
        await player.stop();
      } catch (_) {}
      if (session != _sessionId) {
        _isPreparingNewTrack = false;
        return;
      }

      await player.setAudioSources(
        sources,
        initialIndex: 0,
        initialPosition: Duration.zero,
      );
      await player.setShuffleModeEnabled(false);
      await player.setLoopMode(LoopMode.off);

      if (session != _sessionId) {
        _isPreparingNewTrack = false;
        return;
      }

      _isPreparingNewTrack = false;
      _setBuffering(false);
      _setPlaying(true);
      _setWordIndex(0); // Highlight first word as sound starts

      // Pre-cache current and next Ayah in background
      unawaited(ensureAyahDownloaded(surah, ayah));
      if (ayah < maxAyahs) {
        unawaited(ensureAyahDownloaded(surah, ayah + 1));
      }

      await player.play();
    } catch (e, stack) {
      _isPreparingNewTrack = false;
      if (session == _sessionId) {
        log('Error playing $surah:$ayah: $e',
            name: 'VerseAudioPlayer', error: e, stackTrace: stack);
        _resetStopped(triggerError: true);
      }
    }
  }

  /// Real-time position listener for word-by-word tracking.
  void _handlePosition(Duration pos) {
    if (_isPaused || !isPlaying || !(_player?.playing ?? false)) return;
    if (_player?.processingState != ProcessingState.ready) return;

    // Single-word mode: stop cleanly when target word end timestamp is reached
    if (_isSingleWordMode) {
      final int posMs = pos.inMilliseconds;
      if (_targetWordEndMs != null && posMs >= _targetWordEndMs!) {
        stop();
      }
      return;
    }

    if (_playlistAyahs.isEmpty) return;

    final int? playerIndex = _player?.currentIndex;
    if (playerIndex == null ||
        playerIndex < 0 ||
        playerIndex >= _playlistAyahs.length) {
      return;
    }

    final int playingAyah = _playlistAyahs[playerIndex];
    final int? playingSurah = _playlistSurah ?? _currentSurah;
    if (playingSurah == null) return;

    // Synchronize current Ayah state with the exact track playing in hardware
    if (_currentAyah != playingAyah || _currentSurah != playingSurah) {
      _currentAyah = playingAyah;
      _currentSurah = playingSurah;
      _setVerse(playingSurah, playingAyah);
    }

    final int posMs = pos.inMilliseconds;

    // Single-ayah mode (e.g. record mode):
    // Stop immediately when the reciter finishes the last word (no trailing silence delay)
    if (!_isContinuous) {
      final ayahTiming = QuranTimingService.instance
          .getCachedAyahTiming(playingSurah, playingAyah);
      if (ayahTiming != null && ayahTiming.words.isNotEmpty) {
        final lastWordEndMs = ayahTiming.words.last.endMs;
        if (posMs >= lastWordEndMs + 80) {
          stop();
          return;
        }
      }
    }

    // Continuous recitation mode: lookup active word index
    int? activeIdx = QuranTimingService.instance.getActiveWordIndexAtMs(
      surah: playingSurah,
      ayah: playingAyah,
      positionMs: posMs,
    );

    // Fallback if timing data is still downloading or offline:
    // Estimate word index proportionally from track duration or safe average
    if (activeIdx == null) {
      if (QuranTimingService.instance.getSurahTiming(playingSurah) == null) {
        unawaited(QuranTimingService.instance.ensureSurahLoaded(playingSurah));
      }
      final duration = _player?.duration;
      final ayahTiming = QuranTimingService.instance
          .getCachedAyahTiming(playingSurah, playingAyah);
      final int wordCount = (ayahTiming != null && ayahTiming.words.isNotEmpty)
          ? ayahTiming.words.length
          : 8;
      final int totalMs = (duration != null && duration.inMilliseconds > 0)
          ? duration.inMilliseconds
          : (wordCount * 600);
      if (totalMs > 0 && wordCount > 0) {
        activeIdx =
            ((posMs / totalMs) * wordCount).floor().clamp(0, wordCount - 1);
      }
    }

    if (activeIdx != null && _activeWordIndex != activeIdx) {
      _setWordIndex(activeIdx);
    }
  }

  void _handleTrackComplete() {
    final now = DateTime.now().millisecondsSinceEpoch / 1000.0;
    if (_isHandlingComplete ||
        (now - _lastCompleteTime) < 0.2 ||
        _isAdvancingSurah) return;
    _isHandlingComplete = true;
    _lastCompleteTime = now;

    try {
      if (_isSingleWordMode || !_isContinuous) {
        stop();
        return;
      }

      final surah = _currentSurah;
      final ayah = _currentAyah;
      if (surah == null || ayah == null) {
        stop();
        return;
      }

      final maxAyahs = QuranMetadata.getAyahCount(surah);

      // Verify that the Surah has TRULY reached its final Ayah before advancing.
      // This strictly prevents premature jumping between Surahs.
      final next = QuranMetadata.getNextAyah(surah, ayah);
      if (ayah >= maxAyahs && next != null) {
        // Entire Surah finished in playlist; roll seamlessly to next Surah Ayah 1
        _isAdvancingSurah = true;
        unawaited(() async {
          try {
            await play(
              surah: next.$1,
              ayah: next.$2,
              continuous: true,
            );
          } finally {
            _isAdvancingSurah = false;
            _isHandlingComplete = false;
          }
        }());
        return;
      }

      stop();
    } finally {
      if (!_isAdvancingSurah) {
        _isHandlingComplete = false;
      }
    }
  }

  /// Pauses playback and clears active word highlight while retaining resume state.
  Future<void> pause() async {
    try {
      _isPaused = true;
      _pausedSurah = _currentSurah;
      _pausedAyah = _currentAyah;
      _pausedWordIndex = _activeWordIndex;
      await _player?.pause();
    } catch (e) {
      log('Error pausing: $e', name: 'VerseAudioPlayer');
    }
    _setPlaying(false);
    _setBuffering(false);
  }

  /// Resumes playback from the exact paused position.
  Future<void> resume() async {
    try {
      await ensureMediaAudioSession();
      _isPaused = false;
      _setBuffering(false);
      _setPlaying(true);
      if (_pausedWordIndex != null) {
        _setWordIndex(_pausedWordIndex);
      }
      await _audioPlayer.play();
    } catch (e, stack) {
      log('Error resuming: $e',
          name: 'VerseAudioPlayer', error: e, stackTrace: stack);
      _resetStopped(triggerError: true);
    }
  }

  /// Stops playback and clears all active audio states.
  Future<void> stop() async {
    _sessionId++;
    try {
      await _player?.stop();
    } catch (e) {
      log('Error stopping: $e', name: 'VerseAudioPlayer');
    }
    _resetStopped();
  }

  void _resetStopped({bool triggerError = false}) {
    _isPaused = false;
    _isSingleWordMode = false;
    _targetWordIndex = null;
    _targetWordEndMs = null;
    _pausedSurah = null;
    _pausedAyah = null;
    _pausedWordIndex = null;
    _currentSurah = null;
    _currentAyah = null;
    _playlistAyahs = [];
    _playlistSurah = null;

    _activeWordIndex = null;
    _activeAyah = null;
    _activeSurah = null;
    _isBuffering = false;
    if (_isPlaying) {
      _isPlaying = false;
      onPlayingChanged?.call(false);
    }
    _notifyProgress();

    if (triggerError) {
      AppState.instance
          .triggerAudioError(QuranTimingService.instance.lastFailureReason);
    }
  }

  /// Skips to the next Ayah in the Surah or subsequent Surah.
  Future<void> skipToNextAyah() async {
    final player = _player;
    if (player == null) return;
    if (player.hasNext) {
      await player.seekToNext();
    } else {
      final s = _currentSurah;
      final a = _currentAyah;
      if (s != null && a != null) {
        final next = QuranMetadata.getNextAyah(s, a);
        if (next != null) {
          await play(surah: next.$1, ayah: next.$2, continuous: true);
        }
      }
    }
  }

  /// Skips to the previous Ayah in the Surah or prior Surah.
  Future<void> skipToPreviousAyah() async {
    final player = _player;
    if (player == null) return;
    if (player.hasPrevious) {
      await player.seekToPrevious();
    } else {
      final s = _currentSurah;
      if (s != null && s > 1) {
        final prevSurah = s - 1;
        final prevMax = QuranMetadata.getAyahCount(prevSurah);
        await play(surah: prevSurah, ayah: prevMax, continuous: true);
      }
    }
  }

  Future<void> dispose() async {
    await stop();
    cancelAllSubscriptions();
    try {
      await _player?.dispose();
    } catch (_) {}
    _player = null;
  }
}

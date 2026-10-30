import 'dart:async';
import 'dart:developer' show log;
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:audio_session/audio_session.dart';
import 'package:http/http.dart' as http;
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import '../../state/app_state.dart';
import '../quran_timing_service.dart';

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
class VerseAudioPlayer {
  static const String everyAyahHusaryBaseUrl =
      'https://everyayah.com/data/Husary_64kbps';

  /// Canonical Ayah count for Surahs 1 to 114.
  static const List<int> surahAyahCounts = [
    7,
    286,
    200,
    176,
    120,
    165,
    206,
    75,
    129,
    109,
    123,
    111,
    43,
    52,
    99,
    128,
    111,
    110,
    98,
    135,
    112,
    78,
    118,
    64,
    77,
    227,
    93,
    88,
    69,
    60,
    34,
    30,
    73,
    54,
    45,
    83,
    182,
    88,
    75,
    85,
    54,
    53,
    89,
    59,
    37,
    35,
    38,
    29,
    18,
    45,
    60,
    49,
    62,
    55,
    78,
    96,
    29,
    22,
    24,
    13,
    14,
    11,
    11,
    18,
    12,
    12,
    30,
    52,
    52,
    44,
    28,
    28,
    20,
    56,
    40,
    31,
    50,
    40,
    46,
    42,
    29,
    19,
    36,
    25,
    22,
    17,
    19,
    26,
    30,
    20,
    15,
    21,
    11,
    8,
    8,
    19,
    5,
    8,
    8,
    11,
    11,
    8,
    3,
    9,
    5,
    4,
    7,
    3,
    6,
    3,
    5,
    4,
    5,
    6
  ];

  AudioPlayer? _player;
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<PlayerState>? _playerStateSub;
  StreamSubscription<int?>? _currentIndexSub;

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

  // Single word auditioning mode state
  bool _isSingleWordMode = false;
  int? _targetWordIndex;
  int? _targetWordEndMs;

  // Pause retention state
  bool _isPaused = false;
  int? _pausedSurah;
  int? _pausedAyah;
  int? _pausedWordIndex;

  bool get isPaused => _isPaused;
  int? get pausedSurah => _pausedSurah;
  int? get pausedAyah => _pausedAyah;
  int? get pausedWordIndex => _pausedWordIndex;
  bool get isPlaying => _player?.playing ?? false;
  bool get isSingleWordMode => _isSingleWordMode;
  int? get activeWordIndex => _targetWordIndex;
  int? get currentSurah => _currentSurah;
  int? get currentAyah => _currentAyah;

  /// Returns the per-Ayah 64kbps audio URL ( Mahmoud Khalil Al-Husary).
  static String getAyahAudioUrl(int surah, int ayah) {
    final s = surah.toString().padLeft(3, '0');
    final a = ayah.toString().padLeft(3, '0');
    return '$everyAyahHusaryBaseUrl/$s$a.mp3';
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
    final s = surah.toString().padLeft(3, '0');
    final a = ayah.toString().padLeft(3, '0');
    return File('$_cachedAudioDirPath/$s$a.mp3');
  }

  /// Creates an AudioSource for an Ayah, utilizing local cached file if present,
  /// or progressive streaming URL.
  static Future<AudioSource> createAyahAudioSource(int surah, int ayah) async {
    final url = getAyahAudioUrl(surah, ayah);
    try {
      final file = await getLocalAyahFile(surah, ayah);
      if (file.existsSync() && file.lengthSync() > 1024) {
        return AudioSource.file(file.path);
      }
      return AudioSource.uri(Uri.parse(url));
    } catch (_) {
      return AudioSource.uri(Uri.parse(url));
    }
  }

  static final Set<String> _inFlightDownloads = {};

  /// Fast first-time cache: checks local disk first (0ms), otherwise downloads
  /// the tiny ~20KB file to disk once for instant offline playback.
  static Future<String> ensureAyahDownloaded(int surah, int ayah) async {
    final url = getAyahAudioUrl(surah, ayah);
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
    final key = '$surah:$ayah';
    if (_inFlightDownloads.contains(key)) return;
    _inFlightDownloads.add(key);

    final client = http.Client();
    try {
      final url = getAyahAudioUrl(surah, ayah);
      final res = await client.get(
        Uri.parse(url),
        headers: const {
          'User-Agent': 'Flutter/Natlu',
        },
      ).timeout(const Duration(seconds: 15));

      if (res.statusCode == 200 && res.bodyBytes.isNotEmpty) {
        final tmpFile = File('${file.path}.tmp');
        await tmpFile.writeAsBytes(res.bodyBytes, flush: true);
        if (tmpFile.existsSync() && tmpFile.lengthSync() > 1024) {
          if (file.existsSync()) {
            try { file.deleteSync(); } catch (_) {}
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
    _currentIndexSub?.cancel();
    _currentIndexSub = null;
  }

  /// Explicitly configures and activates the native media audio session (STREAM_MUSIC)
  /// so recitation plays through high-fidelity media speakers at full volume.
  static Future<void> ensureMediaAudioSession() async {
    if (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS) {
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
        handleAudioSessionActivation: false,
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
    _currentIndexSub ??= p.currentIndexStream.listen(_handleIndexChanged);

    _playerStateSub ??= p.playerStateStream.listen((state) {
      final app = AppState.instance;
      final isBuffering = state.processingState == ProcessingState.buffering ||
          state.processingState == ProcessingState.loading;
      app.isAudioBuffering.value = isBuffering;

      if (state.processingState == ProcessingState.completed) {
        _handleTrackComplete();
      } else if (state.playing) {
        app.isAudioPlaying.value = true;
        // When audio officially begins playing, activate target word or word 0
        if (_isSingleWordMode) {
          if (_targetWordIndex != null) {
            app.activeAudioWordIndex.value = _targetWordIndex;
          }
        } else if (app.activeAudioWordIndex.value == null) {
          app.activeAudioWordIndex.value = 0;
        }
      } else if (!state.playing && !isBuffering && !_isAdvancingSurah) {
        app.isAudioPlaying.value = false;
      }
    });
  }

  /// Handles playlist index changes for seamless gapless transition between Ayahs.
  void _handleIndexChanged(int? index) {
    if (index == null || index < 0 || index >= _playlistAyahs.length) return;
    if (_isSingleWordMode || _isPaused) return;

    final newAyah = _playlistAyahs[index];
    final surah = _playlistSurah;
    if (surah == null) return;

    if (_currentAyah != newAyah || _currentSurah != surah) {
      _currentAyah = newAyah;
      _currentSurah = surah;
      final app = AppState.instance;
      if (app.activeAudioSurah.value != surah) {
        app.activeAudioSurah.value = surah;
      }
      if (app.activeAudioAyah.value != newAyah) {
        app.activeAudioAyah.value = newAyah;
      }
      app.activeAudioWordIndex.value = 0;
      app.saveLastPosition(surah, newAyah);
    }

    final maxAyahs = (surah >= 1 && surah <= 114)
        ? surahAyahCounts[surah - 1]
        : 286;

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

    _isSingleWordMode = true;
    _isPaused = false;
    _currentSurah = surah;
    _currentAyah = ayah;
    _targetWordIndex = wordIndex;
    _isContinuous = false;
    _playlistSurah = surah;
    _playlistAyahs = [ayah];

    final app = AppState.instance;
    app.activeAudioSurah.value = surah;
    app.activeAudioAyah.value = ayah;
    app.activeAudioWordIndex.value = wordIndex;
    app.isContinuousPlayback.value = false;
    app.isAudioBuffering.value = true;
    app.isAudioPlaying.value = false;

    try {
      // 1. Ensure timings are loaded from Quran.com / disk cache
      final surahTiming =
          await QuranTimingService.instance.ensureSurahLoaded(surah);
      if (session != _sessionId) return;

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
      if (session != _sessionId) return;

      // 2. Fetch/resolve cached 64kbps Ayah file AudioSource
      final source = await createAyahAudioSource(surah, ayah);
      if (session != _sessionId) return;

      int startMs = 0;
      int endMs = 999999;
      if (targetWord != null) {
        startMs = targetWord.startMs;
        endMs = targetWord.endMs;
      }

      _targetWordEndMs = endMs;

      try {
        await player.stop();
      } catch (_) {}
      if (session != _sessionId) return;

      await player.setAudioSources(
        [source],
        initialPosition: Duration(milliseconds: startMs),
      );
      if (session != _sessionId) return;

      try {
        await player.seek(Duration(milliseconds: startMs));
      } catch (_) {}
      if (session != _sessionId) return;

      app.isAudioBuffering.value = false;
      app.isAudioPlaying.value = true;
      app.activeAudioWordIndex.value = wordIndex;

      await player.play();
    } on PlatformException catch (e, stack) {
      if (session == _sessionId) {
        log('PlatformException in playWord: ${e.message}',
            name: 'VerseAudioPlayer', error: e, stackTrace: stack);
        _resetStopped(triggerError: true);
      }
    } catch (e, stack) {
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
      AppState.instance.isContinuousPlayback.value = continuous;
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

    final app = AppState.instance;
    app.activeAudioSurah.value = surah;
    app.activeAudioAyah.value = ayah;
    app.saveLastPosition(surah, ayah);
    app.activeAudioWordIndex.value = 0;
    app.isContinuousPlayback.value = continuous;
    app.isAudioBuffering.value = true;
    app.isAudioPlaying.value = false;

    // Pre-warm Surah timing in background
    unawaited(QuranTimingService.instance.ensureSurahLoaded(surah));

    try {
      await ensureMediaAudioSession();
      final player = _audioPlayer;
      final int maxAyahs =
          (surah >= 1 && surah <= 114) ? surahAyahCounts[surah - 1] : 286;

      // Ensure current Ayah is cached so first track plays directly from disk
      await ensureAyahDownloaded(surah, ayah);
      if (session != _sessionId) return;

      // In continuous mode, build full remaining playlist for the Surah:
      // from [ayah] to [maxAyahs]! Zero dynamic additions needed later!
      final int endAyah = continuous ? maxAyahs : ayah;
      _playlistAyahs = [for (int a = ayah; a <= endAyah; a++) a];

      final sources = await Future.wait(
        _playlistAyahs.map((a) => createAyahAudioSource(surah, a)),
      );
      if (session != _sessionId) return;

      try {
        await player.stop();
      } catch (_) {}
      if (session != _sessionId) return;

      await player.setAudioSources(
        sources,
        initialIndex: 0,
        initialPosition: Duration.zero,
      );
      await player.setShuffleModeEnabled(false);
      await player.setLoopMode(LoopMode.off);

      if (session != _sessionId) return;

      try {
        await player.seek(Duration.zero, index: 0);
      } catch (_) {}
      if (session != _sessionId) return;

      app.isAudioBuffering.value = false;
      app.isAudioPlaying.value = true;
      app.activeAudioWordIndex.value =
          0; // Highlight first word as sound starts

      // Pre-cache current and next Ayah in background
      unawaited(ensureAyahDownloaded(surah, ayah));
      if (ayah < maxAyahs) {
        unawaited(ensureAyahDownloaded(surah, ayah + 1));
      }

      await player.play();
    } catch (e, stack) {
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

    final int? playerIndex = _player?.currentIndex;
    if (playerIndex == null ||
        playerIndex < 0 ||
        playerIndex >= _playlistAyahs.length) {
      return;
    }

    final int playingAyah = _playlistAyahs[playerIndex];
    final int? playingSurah = _playlistSurah;
    if (playingSurah == null) return;

    // Synchronize current Ayah state with the exact track playing in hardware
    if (_currentAyah != playingAyah || _currentSurah != playingSurah) {
      _currentAyah = playingAyah;
      _currentSurah = playingSurah;
      final app = AppState.instance;
      if (app.activeAudioSurah.value != playingSurah) {
        app.activeAudioSurah.value = playingSurah;
      }
      if (app.activeAudioAyah.value != playingAyah) {
        app.activeAudioAyah.value = playingAyah;
      }
      app.saveLastPosition(playingSurah, playingAyah);
    }

    final int posMs = pos.inMilliseconds;

    // Ignore stale late position spikes during track start transition
    if (posMs > 2500 && AppState.instance.activeAudioWordIndex.value == 0) {
      final ayahTiming = QuranTimingService.instance
          .getCachedAyahTiming(playingSurah, playingAyah);
      if (ayahTiming != null &&
          ayahTiming.words.isNotEmpty &&
          posMs > ayahTiming.words.last.endMs + 500) {
        return;
      }
    }

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
    final int? activeIdx = QuranTimingService.instance.getActiveWordIndexAtMs(
      surah: playingSurah,
      ayah: playingAyah,
      positionMs: posMs,
    );

    if (activeIdx != null &&
        AppState.instance.activeAudioWordIndex.value != activeIdx) {
      AppState.instance.activeAudioWordIndex.value = activeIdx;
    }
  }

  void _handleTrackComplete() {
    final now = DateTime.now().millisecondsSinceEpoch / 1000.0;
    if (_isHandlingComplete || (now - _lastCompleteTime) < 0.2 || _isAdvancingSurah) return;
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

      final maxAyahs = (surah >= 1 && surah <= 114)
          ? surahAyahCounts[surah - 1]
          : 286;

      // Verify that the Surah has TRULY reached its final Ayah before advancing.
      // This strictly prevents premature jumping between Surahs.
      if (ayah >= maxAyahs && surah < 114) {
        // Entire Surah finished in playlist; roll seamlessly to next Surah Ayah 1
        _isAdvancingSurah = true;
        unawaited(() async {
          try {
            await play(
              surah: surah + 1,
              ayah: 1,
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
      _pausedWordIndex = AppState.instance.activeAudioWordIndex.value;
      await _player?.pause();
    } catch (e) {
      log('Error pausing: $e', name: 'VerseAudioPlayer');
    }
    final app = AppState.instance;
    app.isAudioPlaying.value = false;
    app.isAudioBuffering.value = false;
  }

  /// Resumes playback from the exact paused position.
  Future<void> resume() async {
    try {
      await ensureMediaAudioSession();
      _isPaused = false;
      final app = AppState.instance;
      app.isAudioBuffering.value = false;
      app.isAudioPlaying.value = true;
      if (_pausedWordIndex != null) {
        app.activeAudioWordIndex.value = _pausedWordIndex;
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

    final app = AppState.instance;
    app.activeAudioWordIndex.value = null;
    app.activeAudioAyah.value = null;
    app.activeAudioSurah.value = null;
    app.isAudioBuffering.value = false;
    app.isAudioPlaying.value = false;

    if (triggerError) {
      app.triggerAudioError(QuranTimingService.instance.lastFailureReason);
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

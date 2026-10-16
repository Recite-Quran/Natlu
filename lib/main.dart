/// بسم الله الرحمن الرحيم
///
/// ReciteQuran — Real-time Quran recitation tracking app.
///
/// Architecture:
///   main.dart → _Orchestrator (manages engine + audio + controller)
///            → TrackingScreen (UI)
///
/// The _Orchestrator initializes:
///   1. Microphone permissions
///   2. Sherpa-ONNX ASR engine (in a background Isolate)
///   3. Quran metadata (quran.json)
///   4. HighlightingController (bridges ASR → UI)
///
/// Recording flow:
///   AudioProcessor captures mic → feeds chunks to Controller →
///   Controller sends to SherpaEngine (Isolate) → gets transcription →
///   matches words against expected Quran text → updates highlighting
library;

import 'dart:async';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:in_app_update/in_app_update.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:flutter_displaymode/flutter_displaymode.dart';

import 'package:recite_quran/recite_quran.dart';
import 'services/recitation/highlighting_recitation_tracker.dart';
import 'services/prayer/prayer_session.dart';
import 'services/prayer/prayer_voice.dart';
import 'state/app_state.dart';
import 'ui/tracking_screen.dart';
import 'ui/widgets/dialogs/theme_selection_dialog.dart';
import 'ui/widgets/dialogs/permission_dialog.dart';
import 'ui/widgets/dialogs/model_download_dialog.dart';
import 'ui/widgets/mushaf/mushaf_view.dart';
import 'ui/widgets/dialogs/whats_new_dialog.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:just_audio_media_kit/just_audio_media_kit.dart';

void main() async {
  runZonedGuarded(
    () async {
      WidgetsFlutterBinding.ensureInitialized();

      // Initialize Windows audio backend as in reference app (alquranalkareem / quran_library)
      if (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows) {
        try {
          JustAudioMediaKit.bufferSize = 2 * 1024 * 1024;
          JustAudioMediaKit.ensureInitialized(windows: true, linux: false);
        } catch (_) {}
      }

      // Initialize audio session for standard media/recitation playback (STREAM_MUSIC)
      if (!kIsWeb &&
          (defaultTargetPlatform == TargetPlatform.iOS ||
              defaultTargetPlatform == TargetPlatform.android)) {
        try {
          final session = await AudioSession.instance;
          await session.configure(
            const AudioSessionConfiguration(
              avAudioSessionCategory: AVAudioSessionCategory.playback,
              avAudioSessionCategoryOptions:
                  AVAudioSessionCategoryOptions.duckOthers,
              avAudioSessionMode: AVAudioSessionMode.spokenAudio,
              androidAudioAttributes: AndroidAudioAttributes(
                contentType: AndroidAudioContentType.music,
                usage: AndroidAudioUsage.media,
              ),
              androidAudioFocusGainType: AndroidAudioFocusGainType.gain,
            ),
          );
        } catch (e) {
          DebugLogger.logSimple(
            'AudioSession',
            'Failed to configure AudioSession: $e',
          );
        }
      }

      if (kReleaseMode) {
        debugPrint = (String? message, {int? wrapWidth}) {
          if (message != null) print(message);
        };
      }

      if (!kIsWeb) {
        // Transparent system bars for immersive experience
        SystemChrome.setSystemUIOverlayStyle(
          const SystemUiOverlayStyle(
            statusBarColor: Colors.transparent,
            systemNavigationBarColor: Colors.transparent,
          ),
        );
        SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      }

      await AppState.instance.load();
      runApp(const QuranApp());
    },
    (error, stack) {
      DebugLogger.logSimple('Error', 'Uncaught Error: $error');
    },
    zoneSpecification: ZoneSpecification(
      print: (Zone self, ZoneDelegate parent, Zone zone, String line) {
        if (!kReleaseMode || kIsWeb) {
          parent.print(zone, line);
        }
      },
    ),
  );
}

/// Root widget — rebuilds MaterialApp when theme/language changes.
class QuranApp extends StatelessWidget {
  const QuranApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: AppState.instance,
      builder: (context, child) {
        final ThemeColors c = AppState.instance.colors;
        final isDark = AppState.instance.isDarkMode;
        return MaterialApp(
          debugShowCheckedModeBanner: false,
          title: 'Recite Quran - اتلو القران',
          theme: ThemeData(
            useMaterial3: true,
            brightness: isDark ? Brightness.dark : Brightness.light,
            scaffoldBackgroundColor: c.bg,
            colorScheme: ColorScheme(
              brightness: isDark ? Brightness.dark : Brightness.light,
              primary: c.primary,
              onPrimary: c.onPrimary,
              secondary: c.secondary,
              onSecondary: Colors.white,
              error: c.error,
              onError: Colors.white,
              surface: c.surface,
              onSurface: c.text,
              surfaceContainerHighest: c.surfaceHigh,
              outline: c.border,
            ),
            cardTheme: CardThemeData(
              color: c.surface,
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
                side: BorderSide(color: c.border, width: 1),
              ),
            ),
            dialogTheme: DialogThemeData(
              backgroundColor: c.surface,
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(24),
                side: BorderSide(color: c.border, width: 1),
              ),
            ),
            fontFamily: 'cairo',
          ),
          builder: (context, child) {
            if (!kIsWeb) return child!;
            return Scaffold(
              backgroundColor: isDark ? Colors.black : const Color(0xFFE5E7EB),
              body: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 480),
                  child: Container(
                    clipBehavior: Clip.antiAlias,
                    decoration: BoxDecoration(
                      color: c.bg,
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.15),
                          blurRadius: 25,
                          spreadRadius: 5,
                        ),
                      ],
                    ),
                    child: child,
                  ),
                ),
              ),
            );
          },
          home: const _Orchestrator(),
        );
      },
    );
  }
}

/// The conductor — owns the ASR engine, audio processor, and controller.
/// Manages the full lifecycle of a recording session.
class _Orchestrator extends StatefulWidget {
  const _Orchestrator();
  @override
  State<_Orchestrator> createState() => _OrchestratorState();
}

class _OrchestratorState extends State<_Orchestrator> with WidgetsBindingObserver {
  final SherpaEngine _engine = SherpaEngine();
  final AudioProcessor _audio = AudioProcessor();
  late final VoiceSearchController _voiceSearchCtrl;

  QuranRepository? _repo;
  HighlightingController? _ctrl;

  /// Prayer mode (rehearsal): the running session, or the last one until
  /// its log is closed.
  final ValueNotifier<PrayerSession?> _prayer = ValueNotifier(null);
  HighlightingRecitationTracker? _prayerTracker;
  StreamSubscription<TranscriptionResult>? _prayerSub;

  /// Prayer mode's sounds (none in silent mode).
  PrayerVoice? _prayerVoice;
  PrayerSound? _prayerSound;

  /// The microphone was let go of on Android while prayer mode read words.
  bool _micReleasedForPrayer = false;

  bool _isInit = true;
  bool _isRecording = false;
  String _initStatus = 'Starting…';
  bool _isToggling = false; // Prevents double-tap hardware crashes
  bool _isEngineLoading =
      false; // Tracks if ASR is compiling/extracting when user presses record
  bool _isVoiceSearching = false;
  final ValueNotifier<String> _voiceSearchAsrNotifier = ValueNotifier('');
  String get _voiceSearchAsrText => _voiceSearchAsrNotifier.value;
  StreamSubscription? _transcriptionSub;

  // Timer logic removed, we now rely on Sherpa's VAD endpoint with 4s silence

  @override
  void initState() {
    super.initState();
    if (!kIsWeb) {
      WidgetsBinding.instance.addObserver(this);
    }
    _voiceSearchCtrl = VoiceSearchController(engine: _engine);
    AppState.instance.isAudioPlaying.addListener(_onVerseAudioPlayingChanged);

    // Global subscription for Voice Search text and Endpoint auto-stopping
    _transcriptionSub = _engine.transcriptionStream.listen((res) {
      if (_isVoiceSearching && mounted) {
        _voiceSearchAsrNotifier.value = res.text;

        // REAL-TIME SEARCH EVALUATION
        _voiceSearchCtrl.processRealtime(res.text).then((rtResult) {
          if (rtResult != null) {
            // Unique match found! Instantly navigate to it without waiting.
            _stopVoiceSearch(precalculatedResult: rtResult);
          } else if (res.isFinal && _isVoiceSearching) {
            final current = _voiceSearchCtrl.currentResult.value;
            // Only auto-stop on silence endpoint if NO candidates were found at all.
            // When candidates exist, VoiceSearchDialog handles the user selection,
            // the dynamic countdown, and the Hold/Pause state.
            if (current == null || !current.hasCandidates) {
              DebugLogger.log(
                'VoiceSearch',
                'Auto-stopping on VAD endpoint (no matches found)',
              );
              _stopVoiceSearch();
            }
          }
        });
      }
    });

    _init();
    // Defer update check by 5s so Play Core native code doesn't compete
    // with XNNPACK/ONNX initialization for memory and IPC resources
    // during the critical startup window.
    Future.delayed(const Duration(seconds: 15), _checkForUpdates);

    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        try {
          await FlutterDisplayMode.setHighRefreshRate();
        } catch (e) {
          DebugLogger.logSimple(
            'DisplayMode',
            'Failed to set high refresh rate: $e',
          );
        }
      });
    }
  }

  Future<void> _checkForUpdates() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    try {
      const platform = MethodChannel('com.recitequran.app/playstore');
      final bool hasPlayStore = await platform.invokeMethod('isPlayStoreInstalled');
      
      if (!hasPlayStore) {
        DebugLogger.logSimple('Update', 'Play Store missing (LineageOS). Bypassing Play Core API.');
        return;
      }

      final info = await InAppUpdate.checkForUpdate();
      if (info.updateAvailability == UpdateAvailability.updateAvailable) {
        await InAppUpdate.performImmediateUpdate();
      }
    } catch (e) {
      DebugLogger.logSimple('Update', "Play Core update check aborted safely: $e");
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      AppState.instance.stopVerseAudio();
    }
  }

  @override
  void dispose() {
    if (!kIsWeb) {
      WidgetsBinding.instance.removeObserver(this);
    }
    AppState.instance.isAudioPlaying.removeListener(_onVerseAudioPlayingChanged);
    _transcriptionSub?.cancel();
    AppState.instance.stopVerseAudio();
    _endPrayerSession();
    _prayer.value?.dispose();
    _prayer.dispose();
    _ctrl?.dispose();
    _voiceSearchAsrNotifier.dispose();
    super.dispose();
  }

  /// Sequential initialization pipeline in the background.
  /// Does not block the splash screen for the heavy model extraction.
  Future<void> _init() async {
    try {
      if (mounted) setState(() => _initStatus = 'Preparing ASR engine…');
      if (kIsWeb) {
        // On Web, warm up silently only if model is already cached in IndexedDB.
        // If not cached, wait until user consents via record or voice search.
        _engine.isModelCached().then((isCached) {
          if (isCached) _engine.initialize();
        });
      } else {
        _engine.initialize(); // Fire-and-forget in background Isolate
      }

      if (mounted) setState(() => _initStatus = 'Loading Quran database…');
      final service = QuranMetadataService();
      _repo = QuranRepository(service);
      final initialSurah = AppState.instance.lastSurah;
      final initialAyah = AppState.instance.lastAyah;
      await _repo!.loadSurahAsync(initialSurah);
      final rawData = service.rawJson;
      if (rawData != null) {
        MushafRepository.instance.populateAllVerseWords(rawData);
      }
      _voiceSearchCtrl.repository = _repo;

      _voiceSearchCtrl.preloadIndex(); // Fire-and-forget in background
      MushafView.preloadData(); // Fire-and-forget in background Isolate

      _ctrl = HighlightingController(
        engine: _engine,
        repository: _repo!,
        isTajweed: AppState.instance.currentMode == AppMode.tajweed,
        config: AppState.instance.trackerConfig,
        // onAyahChanged is called on explicit user actions (manual tap, session start).
        // Automatic ayah-advance uses flushAndResetForNextAyah() inside
        // HighlightingController itself — that handles the flush-before-reset pattern.
        // We only clear the audio processor's frame buffer here (which is a no-op anyway).
        onAyahChanged: () {
          _audio.clearBuffer();
          // DO NOT call _engine.resetBuffer() here.
          // The correct reset path at ayah boundaries is flushAndResetForNextAyah()
          // which is triggered from _onIsolateWordMatched in HighlightingController.
          // Calling resetBuffer() here would wipe the live cache before the flush,
          // silently discarding the final word's right-context tail every ayah.
        },
      );
      await _ctrl!.setTargetSurah(initialSurah);
      _ctrl!.setManualAyah(initialSurah, initialAyah);
      if (!kIsWeb) {
        try {
          WakelockPlus.enable();
        } catch (_) {}
      }

      if (mounted) setState(() => _isInit = false);

      WidgetsBinding.instance.addPostFrameCallback((_) async {
        final prefs = await SharedPreferences.getInstance();
        final hasChosenTheme = prefs.getBool('has_chosen_theme') ?? false;
        if (!hasChosenTheme && mounted) {
          showDialog(
            context: context,
            barrierDismissible: false,
            builder: (ctx) => ThemeSelectionDialog(
              onThemeSelected: () {
                prefs.setBool('has_chosen_theme', true);
                Navigator.of(ctx).pop();
                _checkAndShowWhatsNew();
              },
            ),
          );
        } else {
          _checkAndShowWhatsNew();
        }
      });
    } catch (e) {
      DebugLogger.logSimple('INIT', '❌ Error: $e');
      if (mounted) setState(() => _initStatus = 'Error: $e');
    }
  }

  Future<void> _checkAndShowWhatsNew() async {
    final prefs = await SharedPreferences.getInstance();
    final hasSeen = prefs.getBool('has_seen_mushaf_whats_new') ?? false;
    if (!hasSeen && mounted) {
      await WhatsNewDialog.show(context);
    }
  }

  /// Ensures the ASR engine is initialized.
  /// On Web, prompts for user bandwidth consent if the ~72MB model is not yet downloaded.
  Future<bool> _ensureEngineReady() async {
    if (_engine.isInitialized) return true;

    if (kIsWeb) {
      final bool isCached = await _engine.isModelCached();
      if (!isCached && mounted) {
        final bool? proceed = await showDialog<bool>(
          context: context,
          barrierDismissible: true,
          builder: (ctx) => const ModelDownloadDialog(),
        );
        if (proceed != true) {
          return false;
        }
      }
    }

    if (!_engine.isInitialized) {
      if (mounted) setState(() => _isEngineLoading = true);
      try {
        await _engine.initialize();
      } finally {
        if (mounted) setState(() => _isEngineLoading = false);
      }
    }
    return _engine.isInitialized;
  }

  Future<void> _startAudioRecordingStream() async {
    try {
      await _audio.start(
        onChunk: (chunk, isFinal) {
          // Software mute: drop mic frames while verse audio is playing
          // so the AI model never hears the phone speaker or accepts input!
          if (AppState.instance.isAudioPlaying.value) return;
          // Prayer mode mustn't take the words it reads out for the
          // reciter's.
          if (_prayerSound == PrayerSound.words) return;
          if (_prayer.value?.phase == PrayerPhase.waitingForFatiha) {
            // Prayer mode isn't following the plan (the tracker is paused)
            // but still listens, for the end of al-Fātiḥa.
            _engine.transcribe(chunk, isFinal: isFinal);
          } else {
            _ctrl?.feed(chunk, isFinal: isFinal);
          }
        },
      );
    } catch (e) {
      DebugLogger.logSimple('AUDIO', '❌ ERROR: $e');
      _endPrayerSession();
      if (mounted) setState(() => _isRecording = false);
    }
  }

  void _onVerseAudioPlayingChanged() {
    final bool isAudio = AppState.instance.isAudioPlaying.value;
    if (_isRecording) {
      if (isAudio) {
        // While verse audio is playing on Android, release the hardware mic
        // so playback doesn't conflict with capture or get invalidated by Android OS.
        if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
          _audio.stop().catchError((_) {});
        }
      } else {
        // Verse audio has stopped:
        _audio.clearBuffer();
        _engine.resetBuffer();
        // On Android, seamlessly re-open the mic stream so recitation works immediately!
        if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
          _startAudioRecordingStream();
        }
      }
    }
    if (!kIsWeb) {
      if (isAudio || _isRecording || _isVoiceSearching) {
        try { WakelockPlus.enable(); } catch (_) {}
      } else {
        try { WakelockPlus.disable(); } catch (_) {}
      }
    }
  }

  /// Toggles recording on/off with hardware-safe locking.
  Future<void> _toggleRecord() async {
    if (_isToggling) return;
    _isToggling = true;

    try {
      if (_isRecording) {
        _endPrayerSession();
        await _audio.stop();
        _engine.resetBuffer();
        _ctrl?.finalize();
        if (!kIsWeb && !AppState.instance.isAudioPlaying.value) {
          try { await WakelockPlus.disable(); } catch (_) {}
        }
        if (mounted) {
          setState(() {
            _isRecording = false;
          });
        }
      } else {
        if (!kIsWeb) {
          final status = await Permission.microphone.request();
          if (status != PermissionStatus.granted) {
            if (mounted) {
              showDialog(
                context: context,
                builder: (ctx) =>
                    const PermissionDialog(reason: PermissionReason.tracking),
              );
            }
            _isToggling = false;
            return;
          }
        }

        // Ensure engine is ready (with consent dialog on Web if model is not yet downloaded)
        if (!await _ensureEngineReady()) {
          _isToggling = false;
          return;
        }

        if (!kIsWeb) {
          try { await WakelockPlus.enable(); } catch (_) {}
        }
        AppState.instance.stopVerseAudio();
        _engine.resetBuffer();

        if (_ctrl != null) {
          if (AppState.instance.isMushafMode) {
            await MushafView.ensureActiveAyahOnCurrentPage(
              controller: _ctrl!,
            );
          }
          _ctrl!.startRecordingSession();
          if (mounted) setState(() => _isRecording = true);
          await _startAudioRecordingStream();
        }
      }
    } catch (e) {
      DebugLogger.logSimple('RECORD', '❌ ERROR: $e');
      _endPrayerSession();
      if (mounted)
        setState(() {
          _isRecording = false;
        });
    } finally {
      _isToggling = false;
    }
  }

  /// Starts prayer mode (rehearsal) following the recitation from [ayah] of
  /// [surah]: starts recording, then lets the session take over the tracker.
  Future<void> _startPrayer(int surah, int ayah) async {
    final ctrl = _ctrl;
    final repo = _repo;
    if (ctrl == null || repo == null) return;
    if (_prayer.value?.phase == PrayerPhase.waitingForFatiha ||
        _prayer.value?.phase == PrayerPhase.following) {
      return;
    }
    if (_isRecording) await _toggleRecord();
    if (ctrl.targetSurah != surah) await ctrl.setTargetSurah(surah);
    ctrl.setManualAyah(surah, ayah);
    await _toggleRecord();
    if (!_isRecording) return;

    final tracker = HighlightingRecitationTracker(ctrl);
    final session = await PrayerSession.create(
      tracker: tracker,
      repository: repo,
      log: (m) => DebugLogger.logSimple('PRAYER', m),
    );
    _prayerTracker = tracker;
    if (!session.silent) {
      final voice = PrayerVoice(
        session: session,
        output: JustAudioPrayerOutput(),
        log: (m) => DebugLogger.logSimple('PRAYER', m),
      );
      voice.playing.addListener(_onPrayerSoundChanged);
      _prayerVoice = voice;
    }
    _prayerSub = _engine.transcriptionStream.listen((r) {
      session.addTranscription(
        tokens: r.tokens,
        isFinal: r.isFinal,
        epoch: r.streamEpoch,
      );
    });
    _replacePrayerSession(session);
    await session.start(surah, ayah);
  }

  /// Shows [session] (or nothing) instead of the current one, which is
  /// disposed once the screen has let go of it.
  void _replacePrayerSession(PrayerSession? session) {
    final old = _prayer.value;
    _prayer.value = session;
    if (old != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
    }
  }

  /// Stops prayer mode and recording. The session's log stays on screen.
  Future<void> _stopPrayer() async {
    if (_isRecording) {
      await _toggleRecord(); // ends the prayer session too
    } else {
      _endPrayerSession();
    }
  }

  void _endPrayerSession() {
    _prayerSub?.cancel();
    _prayerSub = null;
    _prayer.value?.stop();
    _prayerTracker?.restore();
    _prayerTracker = null;
    final voice = _prayerVoice;
    _prayerVoice = null;
    if (voice != null) {
      voice.playing.removeListener(_onPrayerSoundChanged);
      voice.dispose();
      // Prayer mode ends with recording: don't take the microphone back.
      _micReleasedForPrayer = false;
      _setPrayerSound(null);
    }
  }

  void _onPrayerSoundChanged() =>
      _setPrayerSound(_prayerVoice?.playing.value);

  /// Mutes the microphone while prayer mode reads words aloud (on Android
  /// it also lets go of it, as for verse audio, and takes it back after).
  /// The beep is short and no word: the microphone stays on for it.
  void _setPrayerSound(PrayerSound? sound) {
    if (_prayerSound == sound) return;
    _prayerSound = sound;
    final android = !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
    if (sound == PrayerSound.words && android && _isRecording) {
      _micReleasedForPrayer = true;
      _audio.stop().catchError((_) {});
    } else if (sound == null) {
      _audio.clearBuffer();
      if (_micReleasedForPrayer) {
        _micReleasedForPrayer = false;
        if (_isRecording) _startAudioRecordingStream();
      }
    }
  }

  /// Toggles global voice search across the Quran
  Future<void> _toggleVoiceSearch() async {
    AppState.instance.stopVerseAudio();
    if (_isToggling) return;

    if (_isVoiceSearching) {
      await _stopVoiceSearch();
    } else {
      if (_isRecording) {
        await _toggleRecord();
      }
      await _startVoiceSearch();
    }
  }

  Future<void> _startVoiceSearch() async {
    AppState.instance.stopVerseAudio();
    if (_isVoiceSearching || _isToggling) return;
    _isToggling = true;

    try {
      if (!kIsWeb) {
        final status = await Permission.microphone.request();
        if (status != PermissionStatus.granted) {
          if (mounted) {
            showDialog(
              context: context,
              builder: (ctx) =>
                  const PermissionDialog(reason: PermissionReason.voiceSearch),
            );
          }
          _isToggling = false;
          return;
        }
      }

      if (!await _ensureEngineReady()) {
        _isToggling = false;
        return;
      }

      // Suspend highlighting controller so it doesn't consume/reset the engine buffer!
      _ctrl?.finalize();

      // SHOW UI IMMEDIATELY!
      if (mounted) {
        setState(() {
          _isVoiceSearching = true;
        });
      }
      _voiceSearchAsrNotifier.value = '';

      await _voiceSearchCtrl.startSearch();
      if (!kIsWeb) {
        try { await WakelockPlus.enable(); } catch (_) {}
      }

      _audio
          .start(
            onChunk: (chunk, isFinal) {
              _engine.transcribe(chunk, isFinal: isFinal);
            },
          )
          .catchError((e) {
            DebugLogger.logSimple('AUDIO', '❌ ERROR in Voice Search: $e');
            if (mounted) setState(() => _isVoiceSearching = false);
          });
    } catch (e) {
      DebugLogger.logSimple('VOICE_SEARCH', '❌ START ERROR: $e');
      if (mounted) setState(() => _isVoiceSearching = false);
    } finally {
      _isToggling = false;
    }
  }

  Future<void> _stopVoiceSearch({AnchorResult? precalculatedResult}) async {
    if (!_isVoiceSearching || _isToggling) return;
    _isToggling = true;

    try {
      await _audio.stop();
      _engine.resetBuffer();
      if (!kIsWeb && !AppState.instance.isAudioPlaying.value) {
        try { await WakelockPlus.disable(); } catch (_) {}
      }

      if (mounted) {
        setState(() {
          _isVoiceSearching = false;
        });
      }

      AnchorResult? result = precalculatedResult;
      if (result == null) {
        result = await _voiceSearchCtrl.stopSearch(_voiceSearchAsrText);
      }
      _voiceSearchCtrl.clear();
      if (result != null && _ctrl != null) {
        // Automatically navigate to the found Ayah!
        await _ctrl!.setTargetSurah(result.surah);
        _ctrl!.setManualAyah(result.surah, result.ayah);


      } else {
        // Fallback: resume previous state if no Ayah was found
        _ctrl?.resumeTracking();

        AppState.instance.showAyahNotFoundBanner();
      }
    } catch (e) {
      DebugLogger.logSimple('VOICE_SEARCH', '❌ STOP ERROR: $e');
    } finally {
      _isToggling = false;
    }
  }

  /// Warm, elegant splash screen with Quran ayah.
  Widget _loadingScreen() {
    final ThemeColors c = AppState.instance.colors;
    return Scaffold(
      backgroundColor: c.bg,
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Spacer(flex: 3),

            // ── Decorative top line ──
            Container(
              width: 60,
              height: 1.5,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    Colors.transparent,
                    c.gold.withValues(alpha: 0.4),
                    Colors.transparent,
                  ],
                ),
              ),
            ),
            const SizedBox(height: 24),

            // ── Quran Ayah ──
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  'وَلَقَدْ يَسَّرْنَا الْقُرْآنَ لِلذِّكْرِ فَهَلْ مِن مُّدَّكِرٍ',
                  style: TextStyle(
                    fontFamily: 'HafsSmart',
                    color: c.text.withValues(alpha: 0.7),
                    fontSize: 24,
                  ),
                  textAlign: TextAlign.center,
                  textDirection: TextDirection.rtl,
                ),
              ),
            ),

            const SizedBox(height: 24),

            // ── Decorative bottom line ──
            Container(
              width: 60,
              height: 1.5,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    Colors.transparent,
                    c.gold.withValues(alpha: 0.4),
                    Colors.transparent,
                  ],
                ),
              ),
            ),

            const Spacer(flex: 2),

            // ── Loading indicator ──
            SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(
                strokeWidth: 1.5,
                valueColor: AlwaysStoppedAnimation(
                  c.gold.withValues(alpha: 0.5),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              _initStatus,
              style: TextStyle(
                color: c.muted.withValues(alpha: 0.5),
                fontSize: 12,
              ),
            ),
            const Spacer(flex: 1),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_isInit) return _loadingScreen();
    return TrackingScreen(
      controller: _ctrl!,
      isRecording: _isRecording,
      isLoadingEngine: _isEngineLoading,
      isVoiceSearching: _isVoiceSearching,
      voiceSearchText: _voiceSearchAsrText,
      voiceSearchTextNotifier: _voiceSearchAsrNotifier,
      voiceSearchController: _voiceSearchCtrl,
      onToggleRecord: _toggleRecord,
      onVoiceSearchToggle: _toggleVoiceSearch,
      isVoiceSearchLoading: _voiceSearchCtrl.isIndexLoading,
      onSelectVoiceCandidate: (surah, ayah) {
        _stopVoiceSearch(
          precalculatedResult: AnchorResult(surah: surah, ayah: ayah),
        );
      },
      onClearBuffer: () {
        _engine.resetBuffer();
        _audio.clearBuffer();
      },
      prayerSession: _prayer,
      onStartPrayer: _startPrayer,
      onStopPrayer: _stopPrayer,
      onClosePrayer: () {
        _endPrayerSession();
        _replacePrayerSession(null);
      },
    );
  }
}

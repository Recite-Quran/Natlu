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
import 'state/app_state.dart';
import 'ui/tracking_screen.dart';
import 'ui/widgets/dialogs/theme_selection_dialog.dart';
import 'ui/widgets/dialogs/permission_dialog.dart';
import 'ui/widgets/mushaf/mushaf_view.dart';
import 'ui/widgets/dialogs/whats_new_dialog.dart';
import 'maglis/maglis_controller.dart';
import 'maglis/maglis_core.dart';
import 'services/app_audio_processor.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'services/quran_audio_service.dart';

void main() async {
  runZonedGuarded(
    () async {
      WidgetsFlutterBinding.ensureInitialized();

      // Initialize Windows audio backend as in reference app (alquranalkareem / quran_library)
      if (defaultTargetPlatform == TargetPlatform.windows) {
        try {
          JustAudioMediaKit.bufferSize = 2 * 1024 * 1024;
          JustAudioMediaKit.ensureInitialized(windows: true);
        } catch (_) {}
      }

      // Initialize audio session for standard media/recitation playback (STREAM_MUSIC)
      if (defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.android) {
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

      // Transparent system bars for immersive experience
      SystemChrome.setSystemUIOverlayStyle(
        const SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          systemNavigationBarColor: Colors.transparent,
        ),
      );
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

      await AppState.instance.load();
      runApp(const QuranApp());
    },
    (error, stack) {
      DebugLogger.logSimple('Error', 'Uncaught Error: $error');
    },
    zoneSpecification: ZoneSpecification(
      print: (Zone self, ZoneDelegate parent, Zone zone, String line) {
        if (!kReleaseMode) {
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
      listenable: AppState.instance.themeNotifier,
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
  final AppAudioProcessor _audio = AppAudioProcessor();
  late final VoiceSearchController _voiceSearchCtrl;

  QuranRepository? _repo;
  HighlightingController? _ctrl;

  bool _isInit = true;
  bool _isRecording = false;
  String _initStatus = 'Starting…';
  bool _isToggling = false; // Prevents double-tap hardware crashes
  bool _isEngineLoading =
      false; // Tracks if ASR is compiling/extracting when user presses record
  bool _isVoiceSearching = false;
  bool _isVoiceSearchPaused = false;
  final ValueNotifier<String> _voiceSearchAsrNotifier = ValueNotifier('');
  String get _voiceSearchAsrText => _voiceSearchAsrNotifier.value;
  StreamSubscription? _transcriptionSub;

  // Timer logic removed, we now rely on Sherpa's VAD endpoint with 4s silence

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _voiceSearchCtrl = VoiceSearchController(engine: _engine);
    AppState.instance.isAudioPlaying.addListener(_onVerseAudioPlayingChanged);

    MaglisController.instance.onRemoteFloorClaimed = () {
      if (mounted) {
        _stopRecordingForRemoteClaim();
      }
    };

    // Global subscription for Voice Search text and Endpoint auto-stopping
    _transcriptionSub = _engine.transcriptionStream.listen((res) {
      if (_isVoiceSearching && !_isVoiceSearchPaused && mounted) {
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

    if (defaultTargetPlatform == TargetPlatform.android) {
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
    if (defaultTargetPlatform != TargetPlatform.android) return;
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
    if (state == AppLifecycleState.detached ||
        QuranAudioService.instance.isSingleWordMode) {
      AppState.instance.stopVerseAudio();
    }
  }

  @override
  void dispose() {
    MaglisController.instance.onRemoteFloorClaimed = null;
    _maglisBroadcastThrottle?.cancel();
    _ctrl?.removeListener(_throttledBroadcastMaglisProgress);
    WidgetsBinding.instance.removeObserver(this);
    AppState.instance.isAudioPlaying.removeListener(_onVerseAudioPlayingChanged);
    _transcriptionSub?.cancel();
    AppState.instance.stopVerseAudio();
    _ctrl?.dispose();
    _voiceSearchAsrNotifier.dispose();
    super.dispose();
  }

  /// Sequential initialization pipeline in the background.
  /// Does not block the splash screen for the heavy model extraction.
  Future<void> _init() async {
    try {
      if (mounted) setState(() => _initStatus = 'Preparing ASR engine…');
      _engine.initialize(); // Fire-and-forget in background Isolate

      if (mounted) setState(() => _initStatus = 'Loading Quran database…');
      final service = QuranMetadataService();
      _repo = QuranRepository(service);
      final initialSurah = AppState.instance.lastSurah;
      final initialAyah = AppState.instance.lastAyah;
      await _repo!.loadSurahAsync(initialSurah);
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
      _ctrl!.addListener(_throttledBroadcastMaglisProgress);
      await _ctrl!.setTargetSurah(initialSurah);
      _ctrl!.setManualAyah(initialSurah, initialAyah);
      try {
        WakelockPlus.enable();
      } catch (_) {}

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
    final hasSeen = prefs.getBool('has_seen_v1_2_maglis_whats_new') ?? false;
    if (!hasSeen && mounted) {
      await WhatsNewDialog.show(context);
    }
  }

  /// Ensures the ASR engine is initialized.
  Future<bool> _ensureEngineReady() async {
    if (_engine.isInitialized) return true;

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

  Future<bool> _ensureMicPermission(PermissionReason reason) async {
    if (defaultTargetPlatform != TargetPlatform.android &&
        defaultTargetPlatform != TargetPlatform.iOS) {
      return true;
    }
    final status = await Permission.microphone.status;
    if (status.isGranted) return true;

    final request = await Permission.microphone.request();
    if (request.isGranted) return true;

    if (mounted) {
      showDialog(
        context: context,
        builder: (ctx) => PermissionDialog(reason: reason),
      );
    }
    return false;
  }

  Future<void> _startAudioRecordingStream() async {
    try {
      await _audio.start(
        onChunk: (chunk, isFinal) {
          // Software mute: drop mic frames while verse audio is playing
          // so the AI model never hears the phone speaker or accepts input!
          if (AppState.instance.isAudioPlaying.value) return;
          _ctrl?.feed(chunk, isFinal: isFinal);
        },
      );
    } catch (e) {
      DebugLogger.logSimple('AUDIO', '❌ ERROR: $e');
      if (mounted) setState(() => _isRecording = false);
    }
  }

  void _onVerseAudioPlayingChanged() {
    final bool isAudio = AppState.instance.isAudioPlaying.value;
    if (_isRecording) {
      if (isAudio) {
        // While verse audio is playing on Android, release the hardware mic
        // so playback doesn't conflict with capture or get invalidated by Android OS.
        if (defaultTargetPlatform == TargetPlatform.android) {
          _audio.stop().catchError((_) {});
        }
      } else {
        // Verse audio has stopped:
        _audio.clearBuffer();
        _engine.resetBuffer();
        // On Android, seamlessly re-open the mic stream so recitation works immediately!
        if (defaultTargetPlatform == TargetPlatform.android) {
          _startAudioRecordingStream();
        }
      }
    }
    if (isAudio || _isRecording || _isVoiceSearching) {
      try { WakelockPlus.enable(); } catch (_) {}
    } else {
      try { WakelockPlus.disable(); } catch (_) {}
    }
  }

  /// Toggles recording on/off with hardware-safe locking.
  Future<void> _toggleRecord() async {
    if (_isToggling) return;
    _isToggling = true;

    try {
      if (_isRecording) {
        _maglisBroadcastThrottle?.cancel();
        await _audio.stop();
        _engine.resetBuffer();
        _ctrl?.finalize();
        if (MaglisController.instance.inSession) {
          unawaited(MaglisController.instance.releaseFloor(
            page: AppState.instance.currentMushafPage.value,
            surah: _ctrl?.targetSurah ?? AppState.instance.lastSurah,
            ayah: _ctrl?.activeAyah.value ?? AppState.instance.lastAyah,
          ));
          MaglisPlatform.setSpeaker(true);
        }
        if (!AppState.instance.isAudioPlaying.value) {
          try { await WakelockPlus.disable(); } catch (_) {}
        }
        if (mounted) {
          setState(() {
            _isRecording = false;
          });
        }
      } else {
        if (!await _ensureMicPermission(PermissionReason.tracking)) {
          _isToggling = false;
          return;
        }

        // Ensure engine is ready
        if (!await _ensureEngineReady()) {
          _isToggling = false;
          return;
        }

        try { await WakelockPlus.enable(); } catch (_) {}
        AppState.instance.stopVerseAudio();
        _engine.resetBuffer();

        if (_ctrl != null) {
          await MushafView.ensureActiveAyahOnCurrentPage(
            controller: _ctrl!,
          );
          _ctrl!.startRecordingSession();
          if (MaglisController.instance.inSession) {
            unawaited(MaglisController.instance.claimFloor(
              page: AppState.instance.currentMushafPage.value,
              surah: _ctrl!.targetSurah,
              ayah: _ctrl!.activeAyah.value ?? 1,
            ));
          }
          if (mounted) setState(() => _isRecording = true);
          await _startAudioRecordingStream();
        }
      }
    } catch (e) {
      DebugLogger.logSimple('RECORD', '❌ ERROR: $e');
      if (mounted)
        setState(() {
          _isRecording = false;
        });
    } finally {
      _isToggling = false;
    }
  }

  void _stopRecordingForRemoteClaim() {
    if (!_isRecording) return;
    _maglisBroadcastThrottle?.cancel();
    _audio.stop();
    _engine.resetBuffer();
    _ctrl?.finalize();
    if (!AppState.instance.isAudioPlaying.value) {
      try {
        WakelockPlus.disable();
      } catch (_) {}
    }
    if (mounted) {
      setState(() {
        _isRecording = false;
        _isToggling = false;
      });
    }
    MaglisPlatform.setSpeaker(true);
    AppState.instance.showBanner(AppBannerInfo(
      id: 'maglis_reciter_changed',
      messageAr: 'انتقلت التلاوة للمشارك الآخر • استمع وتابع معه',
      messageEn: 'Recitation passed to peer • Listen and follow along',
      icon: Icons.record_voice_over_rounded,
      customDuration: const Duration(seconds: 3),
    ));
  }

  Timer? _maglisBroadcastThrottle;
  int? _lastProcessedAyah;
  int? _lastProcessedSurah;

  void _throttledBroadcastMaglisProgress() {
    if (!MaglisController.instance.isLocalReciting || !_isRecording) return;
    final int? currentAyah = _ctrl?.activeAyah.value;
    // When ayah transitions or finishes, broadcast immediately to flush completed words without throttle lag
    if (currentAyah != null && currentAyah != _lastProcessedAyah) {
      _maglisBroadcastThrottle?.cancel();
      _broadcastMaglisProgress();
      return;
    }
    if (_maglisBroadcastThrottle?.isActive ?? false) return;
    _maglisBroadcastThrottle = Timer(const Duration(milliseconds: 35), () {
      _broadcastMaglisProgress();
    });
  }

  void _broadcastMaglisProgress() {
    final maglis = MaglisController.instance;
    if (!maglis.isLocalReciting || !_isRecording || _ctrl == null) return;

    final int targetSurah = _ctrl!.targetSurah;
    final int? activeAyah = _ctrl!.activeAyah.value;
    if (activeAyah == null) return;

    final int currentPage = AppState.instance.currentMushafPage.value;
    final int page =
        MushafProvider.instance.getPageForAyah(targetSurah, activeAyah) ??
            currentPage;

    final pageWords =
        MushafProvider.instance.getCachedPage(page)?.words ??
        MushafProvider.instance.getCachedPage(currentPage)?.words ??
        const [];

    // If activeAyah just advanced, ensure the previous ayah's final word is flushed and saved as completed
    if (_lastProcessedAyah != null &&
        (_lastProcessedAyah != activeAyah || _lastProcessedSurah != targetSurah)) {
      final prevAyah = _lastProcessedAyah!;
      final prevSurah = _lastProcessedSurah!;
      final prevGreen = <int>[];
      for (final w in pageWords) {
        if (w.surah == prevSurah && w.ayah == prevAyah) {
          final w0 = w.word - 1;
          prevGreen.add(w0);
          maglis.recordWordHighlight(prevSurah, prevAyah, w0, 1);
        }
      }
      if (prevGreen.isNotEmpty) {
        maglis.broadcastRecitation(
          page: page,
          surah: prevSurah,
          ayah: prevAyah,
          activeWord: null,
          greenWords: prevGreen,
          yellowWords: const [],
          redWords: const [],
        );
      }
    }
    _lastProcessedAyah = activeAyah;
    _lastProcessedSurah = targetSurah;

    final greenWords = <int>[];
    final yellowWords = <int>[];
    final redWords = <int>[];
    int? activeWord;
    bool foundAyah = false;

    for (final w in pageWords) {
      final w0 = w.word - 1;
      if (w.surah == targetSurah && w.ayah == activeAyah) {
        foundAyah = true;
        if (_ctrl!.isWordGreen(activeAyah, w0, surah: targetSurah) ||
            _ctrl!.completedAyahsFor(targetSurah).contains(activeAyah)) {
          greenWords.add(w0);
          maglis.recordWordHighlight(targetSurah, activeAyah, w0, 1);
        } else if (_ctrl!.isWordYellow(activeAyah, w0, surah: targetSurah)) {
          yellowWords.add(w0);
          maglis.recordWordHighlight(targetSurah, activeAyah, w0, 2);
        } else if (_ctrl!.isWordRed(activeAyah, w0, surah: targetSurah)) {
          redWords.add(w0);
          maglis.recordWordHighlight(targetSurah, activeAyah, w0, 3);
        } else if (activeWord == null &&
            !_ctrl!.isWordNeutral(activeAyah, w0, surah: targetSurah)) {
          activeWord = w0;
        }
      } else {
        // Also persist completed/green words on current page into cumulative highlights
        if (_ctrl!.completedAyahsFor(w.surah).contains(w.ayah) ||
            _ctrl!.isWordGreen(w.ayah, w0, surah: w.surah)) {
          maglis.recordWordHighlight(w.surah, w.ayah, w0, 1);
        }
      }
    }

    if (activeWord == null) {
      if (greenWords.isNotEmpty) {
        activeWord = greenWords.last + 1;
      } else if (foundAyah) {
        activeWord = 0;
      }
    }

    maglis.broadcastRecitation(
      page: page,
      surah: targetSurah,
      ayah: activeAyah,
      activeWord: activeWord,
      greenWords: greenWords,
      yellowWords: yellowWords,
      redWords: redWords,
    );
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
      if (!await _ensureMicPermission(PermissionReason.voiceSearch)) {
        _isToggling = false;
        return;
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
      try { await WakelockPlus.enable(); } catch (_) {}

      _isVoiceSearchPaused = false;
      _audio
          .start(
            onChunk: (chunk, isFinal) {
              if (!_isVoiceSearchPaused) {
                _engine.transcribe(chunk, isFinal: isFinal);
              }
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
    _isVoiceSearchPaused = false;

    try {
      await _audio.stop();
      _engine.resetBuffer();
      if (!AppState.instance.isAudioPlaying.value) {
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

  void _onVoiceSearchHoldChanged(bool isPaused) {
    _isVoiceSearchPaused = isPaused;
    if (!isPaused) {
      _engine.resetBuffer();
      _audio.clearBuffer();
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
      onVoiceSearchHoldChanged: _onVoiceSearchHoldChanged,
      onSelectVoiceCandidate: (surah, ayah) {
        _stopVoiceSearch(
          precalculatedResult: AnchorResult(surah: surah, ayah: ayah),
        );
      },
      onClearBuffer: () {
        _engine.resetBuffer();
        _audio.clearBuffer();
      },
    );
  }
}

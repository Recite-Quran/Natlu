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
import 'package:flutter_displaymode/flutter_displaymode.dart';

import 'core/app_state.dart';
import 'core/highlighting_controller.dart';
import 'ui/tracking_screen.dart';
import 'mushaf/mushaf_view.dart';
import 'maglis/maglis_controller.dart';
import 'maglis/maglis_core.dart';
import 'core/maglis_link_service.dart';
import 'core/app_audio_processor.dart';
import 'core/platform_utils.dart';
import 'mushaf/web/mushaf_web_storage.dart'
    if (dart.library.js_interop) 'mushaf/web/mushaf_web_storage_web.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:audio_service/audio_service.dart';
import 'audio/quran_audio_handler.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'audio/quran_audio_service.dart';
import 'audio/quran_download_service.dart';
import 'ui/widgets/dialogs/dialog_service.dart';

void main() async {
  runZonedGuarded(
    () async {
      WidgetsFlutterBinding.ensureInitialized();

      // Initialize Windows audio backend as in reference app (alquranalkareem / quran_library)
      if (PlatformCapabilities.usesMediaKitAudio) {
        try {
          JustAudioMediaKit.bufferSize = 2 * 1024 * 1024;
          JustAudioMediaKit.ensureInitialized(windows: true);
        } catch (_) {}
      }

      // Initialize audio session for standard media/recitation playback (STREAM_MUSIC)
      if (PlatformCapabilities.isMobile) {
        try {
          final session = await AudioSession.instance;
          await session.configure(
            const AudioSessionConfiguration.music(),
          );
        } catch (e) {
          DebugLogger.logSimple(
            'AudioSession',
            'Failed to configure AudioSession: $e',
          );
        }

        try {
          await AudioService.init(
            builder: () => QuranAudioHandler.instance,
            config: const AudioServiceConfig(
              androidNotificationChannelId: 'com.recitequran.app.audio',
              androidNotificationChannelName: 'القرآن العظيم',
              androidNotificationOngoing: true,
              androidStopForegroundOnPause: true,
              androidNotificationIcon: 'mipmap/ic_launcher',
            ),
          );
        } catch (e) {
          DebugLogger.logSimple(
            'AudioService',
            'Failed to configure AudioService: $e',
          );
        }
      }

      unawaited(QuranDownloadService.instance.init());

      if (kReleaseMode) {
        debugPrint = (String? message, {int? wrapWidth}) {
          if (message != null) print(message);
        };
      }

      if (!PlatformCapabilities.isWeb) {
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
  static final GlobalKey<NavigatorState> navigatorKey =
      GlobalKey<NavigatorState>();

  const QuranApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: AppState.instance.themeNotifier,
      builder: (context, child) {
        final ThemeColors c = AppState.instance.colors;
        final isDark = AppState.instance.isDarkMode;
        return MaterialApp(
          navigatorKey: QuranApp.navigatorKey,
          debugShowCheckedModeBanner: false,
          navigatorObservers: [AppModalRouteObserver.instance],
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
            Widget appWidget = child ?? const SizedBox.shrink();
            if (kIsWeb) {
              final media = MediaQuery.of(context);
              final isWide = media.size.width > 480;
              final constrainedWidth = isWide ? 480.0 : media.size.width;

              appWidget = Scaffold(
                backgroundColor:
                    isDark ? Colors.black : const Color(0xFFE5E7EB),
                body: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 480),
                    child: Container(
                      clipBehavior: Clip.antiAlias,
                      decoration: BoxDecoration(
                        color: c.bg,
                        boxShadow: isWide
                            ? [
                                BoxShadow(
                                  color: Colors.black.withValues(alpha: 0.18),
                                  blurRadius: 25,
                                  spreadRadius: 5,
                                ),
                              ]
                            : null,
                      ),
                      child: MediaQuery(
                        data: media.copyWith(
                          size: Size(constrainedWidth, media.size.height),
                        ),
                        child: appWidget,
                      ),
                    ),
                  ),
                ),
              );
            }
            return appWidget;
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

class _OrchestratorState extends State<_Orchestrator>
    with WidgetsBindingObserver {
  static const MethodChannel _lifecycleChannel =
      MethodChannel('com.recitequran.app/audio_lifecycle');

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
  bool _isBackgrounded = false;
  Timer? _maglisIdleTimer;
  Timer? _enginePrewarmTimer;
  DateTime? _maglisSoloSince;
  bool _hasAttachedMaglisBroadcast = false;

  void _syncMaglisBroadcastListeners() {
    final inSession = MaglisController.instance.inSession;
    if (inSession && !_hasAttachedMaglisBroadcast && _ctrl != null) {
      _hasAttachedMaglisBroadcast = true;
      _ctrl!.addListener(_throttledBroadcastMaglisProgress);
      _ctrl!.globalRevision.addListener(_throttledBroadcastMaglisProgress);
      _ctrl!.activeAyah.addListener(_throttledBroadcastMaglisProgress);
    } else if (!inSession && _hasAttachedMaglisBroadcast) {
      _hasAttachedMaglisBroadcast = false;
      _maglisBroadcastThrottle?.cancel();
      _ctrl?.removeListener(_throttledBroadcastMaglisProgress);
      _ctrl?.globalRevision.removeListener(_throttledBroadcastMaglisProgress);
      _ctrl?.activeAyah.removeListener(_throttledBroadcastMaglisProgress);
    }
  }

  // Timer logic removed, we now rely on Sherpa's VAD endpoint with 4s silence

  @override
  void initState() {
    super.initState();
    MaglisLinkService.instance.init();
    initModelDownloadTracker();
    WidgetsBinding.instance.addObserver(this);
    _voiceSearchCtrl = VoiceSearchController(engine: _engine);
    QuranAudioService.instance.onAudioProgress = ({
      int? surah,
      int? ayah,
      int? wordIndex,
      required bool isPlaying,
      required bool isBuffering,
      bool? isPaused,
    }) {
      _ctrl?.applyAudioProgress(
        surah: surah,
        ayah: ayah,
        wordIndex: wordIndex,
        isPlaying: isPlaying,
        isBuffering: isBuffering,
        isPaused: isPaused,
      );
      AppState.instance.updateAudioState(
        surah: surah,
        ayah: ayah,
        wordIndex: wordIndex,
        isPlaying: isPlaying,
        isBuffering: isBuffering,
      );
    };
    QuranAudioService.instance.onPlayingChanged = _onVerseAudioPlayingChanged;
    MaglisController.instance.sessionListenable
        .addListener(_onMaglisSessionChangedForIdleTimer);
    MaglisController.instance.sessionListenable
        .addListener(_syncMaglisBroadcastListeners);

    MaglisController.instance.onGetSnapshotCumulativeMap = () {
      return _ctrl?.highlightStore.buildSnapshotMap() ?? {};
    };

    MaglisController.instance.onRemoteRecitationProgress = ({
      required int surah,
      required int ayah,
      int? activeWord,
      List<int> greenWords = const [],
      List<int> yellowWords = const [],
      List<int> redWords = const [],
      Map<int, List<ReciterError>>? errors,
      Map<String, int>? cumulative,
      bool isReciting = true,
    }) {
      if (mounted && _ctrl != null) {
        _ctrl!.applyRemoteRecitation(
          surah: surah,
          ayah: ayah,
          activeWord: activeWord,
          greenWords: greenWords,
          yellowWords: yellowWords,
          redWords: redWords,
          errors: errors,
          cumulative: cumulative,
          isReciting: isReciting,
        );
      }
    };

    MaglisController.instance.onRemoteFloorClaimed = (surah, ayah) {
      if (mounted && _ctrl != null) {
        _ctrl!.setManualAyah(surah, ayah);
        _ctrl!.clearHighlightsForwardFrom(surah, ayah);
        _ctrl!.globalRevision.value++;
        _stopRecordingForRemoteClaim();
      }
    };

    MaglisController.instance.onSessionEnded = () {
      AppState.instance.exitMaglisSession();
      if (mounted && _isRecording) {
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

    if (PlatformCapabilities.supportsHighRefreshRate) {
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
    if (!PlatformCapabilities.isAndroid) return;
    try {
      const platform = MethodChannel('com.recitequran.app/playstore');
      final bool hasPlayStore =
          await platform.invokeMethod('isPlayStoreInstalled');

      if (!hasPlayStore) {
        DebugLogger.logSimple('Update',
            'Play Store missing (LineageOS). Bypassing Play Core API.');
        return;
      }

      final info = await InAppUpdate.checkForUpdate();
      if (info.updateAvailability == UpdateAvailability.updateAvailable) {
        await InAppUpdate.performImmediateUpdate();
      }
    } catch (e) {
      DebugLogger.logSimple(
          'Update', "Play Core update check aborted safely: $e");
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.detached) {
      QuranAudioService.instance.stop();
      _enginePrewarmTimer?.cancel();
      _enginePrewarmTimer = null;
      _maglisIdleTimer?.cancel();
      _maglisIdleTimer = null;
      _maglisSoloSince = null;
      if (MaglisController.instance.inSession) {
        unawaited(MaglisController.instance.leaveSession());
      }
      return;
    }

    if (state == AppLifecycleState.resumed) {
      _isBackgrounded = false;
      _maglisIdleTimer?.cancel();
      _maglisIdleTimer = null;
      if (_maglisSoloSince != null) {
        final elapsed = DateTime.now().difference(_maglisSoloSince!);
        if (elapsed >= const Duration(minutes: 10) &&
            MaglisController.instance.inSession &&
            MaglisController.instance.participantCount <= 1) {
          unawaited(MaglisController.instance.leaveSession());
        }
        _maglisSoloSince = null;
      }
      if (!_engine.isInitialized) {
        _scheduleEnginePrewarm();
      }
    }

    // On Desktop (Windows, macOS, Linux) and Web, alt-tab, tab switching, and loss of focus
    // must NEVER leave the Maglis session so users can multitask while talking/listening!
    final bool isDesktopOrWeb =
        PlatformCapabilities.isWeb || PlatformCapabilities.isDesktop;

    if (!isDesktopOrWeb) {
      // Leave session when phone locks (screen timeout or power button), NOT when switching apps.
      if (state == AppLifecycleState.paused) {
        _isBackgrounded = true;
        _enginePrewarmTimer?.cancel();
        _enginePrewarmTimer = null;
        if (MaglisController.instance.inSession) {
          _leaveSessionIfLocked();
          _onMaglisSessionChangedForIdleTimer();
        }
      }
    } else {
      if (state == AppLifecycleState.paused) {
        _enginePrewarmTimer?.cancel();
        _enginePrewarmTimer = null;
      }
    }
  }

  void _onMaglisSessionChangedForIdleTimer() {
    if (!_isBackgrounded) return;
    if (MaglisController.instance.participantCount > 1) {
      // Someone joined while we are in background: cancel idle countdown!
      _maglisIdleTimer?.cancel();
      _maglisIdleTimer = null;
      _maglisSoloSince = null;
    } else if (MaglisController.instance.inSession &&
        _maglisIdleTimer == null) {
      // Alone in room while backgrounded: start fresh 10-minute countdown
      _maglisSoloSince = DateTime.now();
      _maglisIdleTimer = Timer(const Duration(minutes: 10), () {
        if (_isBackgrounded &&
            MaglisController.instance.inSession &&
            MaglisController.instance.participantCount <= 1) {
          unawaited(MaglisController.instance.leaveSession());
        }
      });
    }
  }

  Future<void> _leaveSessionIfLocked() async {
    try {
      final isLocked =
          await _lifecycleChannel.invokeMethod<bool>('isScreenOffOrLocked') ??
              false;
      if (isLocked && MaglisController.instance.inSession) {
        await MaglisController.instance.leaveSession();
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    MaglisLinkService.instance.dispose();
    MaglisController.instance.sessionListenable
        .removeListener(_onMaglisSessionChangedForIdleTimer);
    MaglisController.instance.sessionListenable
        .removeListener(_syncMaglisBroadcastListeners);
    _maglisIdleTimer?.cancel();
    _maglisIdleTimer = null;
    _maglisSoloSince = null;
    _enginePrewarmTimer?.cancel();
    _enginePrewarmTimer = null;
    if (MaglisController.instance.inSession) {
      unawaited(MaglisController.instance.leaveSession());
    }
    MaglisController.instance.onRemoteFloorClaimed = null;
    MaglisController.instance.onRemoteRecitationProgress = null;
    MaglisController.instance.onGetSnapshotCumulativeMap = null;
    MaglisController.instance.onSessionEnded = null;
    if (_hasAttachedMaglisBroadcast) {
      _hasAttachedMaglisBroadcast = false;
      _maglisBroadcastThrottle?.cancel();
      _ctrl?.removeListener(_throttledBroadcastMaglisProgress);
      _ctrl?.globalRevision.removeListener(_throttledBroadcastMaglisProgress);
      _ctrl?.activeAyah.removeListener(_throttledBroadcastMaglisProgress);
    }
    if (!PlatformCapabilities.isWeb) {
      WidgetsBinding.instance.removeObserver(this);
    }
    QuranAudioService.instance.onAudioProgress = null;
    QuranAudioService.instance.onPlayingChanged = null;
    QuranAudioService.instance.stop();
    _transcriptionSub?.cancel();
    _audio.dispose();
    _ctrl?.dispose();
    _voiceSearchAsrNotifier.dispose();
    super.dispose();
  }

  /// Sequential initialization pipeline in the background.
  /// Does not block the splash screen for the heavy model extraction.
  Future<void> _init() async {
    try {
      // ASR engine initialization is lazily deferred until the user initiates recitation
      // or voice search via _ensureEngineReady(), keeping silent reading cool, lean, and jank-free.
      if (mounted) setState(() => _initStatus = 'Loading Quran database…');
      final service = QuranMetadataService();
      _repo = QuranRepository(service);
      final initialSurah = AppState.instance.lastSurah;
      final initialAyah = AppState.instance.lastAyah;
      await _repo!.loadSurahAsync(initialSurah);
      _voiceSearchCtrl.repository = _repo;

      // Voice search phonetic index is lazily loaded on first voice search tap,
      // saving ~20MB RAM and preventing background isolate CPU churn during startup and silent reading.
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
          // DO NOT call _audio.clearBuffer() here: in continuous recitation,
          // clearing the frame buffer discards up to 480ms of audio, causing
          // the model to drop the first 2 letters of the incoming ayah.
          // DO NOT call _engine.resetBuffer() here.
          // The correct reset path at ayah boundaries is flushAndResetForNextAyah()
          // which is triggered from _onIsolateWordMatched in HighlightingController.
          // Calling resetBuffer() here would wipe the live cache before the flush,
          // silently discarding the final word's right-context tail every ayah.
        },
      );
      _syncMaglisBroadcastListeners();
      await _ctrl!.setTargetSurah(initialSurah);
      _ctrl!.setManualAyah(initialSurah, initialAyah);

      if (mounted) setState(() => _isInit = false);
      MaglisLinkService.instance.isAppReady = true;

      // Platform-aware ASR pre-warming:
      if (PlatformCapabilities.isWeb) {
        // On Web, warm up silently ONLY if the ~72MB model is already cached in browser IndexedDB.
        // If not cached, we strictly wait until the user taps Record to request bandwidth consent.
        _engine.isModelCached().then((isCached) {
          if (isCached && mounted && !_engine.isInitialized) {
            unawaited(_engine.initialize().catchError((_) {}));
          }
        });
      } else {
        // On Native (Android, iOS, Windows, macOS), schedule deferred pre-warm after the UI settles.
        _scheduleEnginePrewarm();
      }

      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted) return;
        if (MaglisLinkService.instance.hasPendingRoomCode) {
          MaglisLinkService.instance.consumePendingIfAny(context);
          return;
        }

        if (PlatformCapabilities.isWeb)
          return; // Zero intro / popup interruptions on Web
        final prefs = await SharedPreferences.getInstance();
        final hasChosenTheme = prefs.getBool('has_chosen_theme') ?? false;
        if (!hasChosenTheme && mounted) {
          await DialogService.showThemeSelection(
            context,
            onThemeSelected: () {
              prefs.setBool('has_chosen_theme', true);
              Navigator.of(context).pop();
            },
          );
          if (mounted) {
            await Future<void>.delayed(const Duration(milliseconds: 250));
            await _checkAndShowAppGuide();
          }
        } else {
          await _checkAndShowAppGuide();
        }
      });
    } catch (e) {
      DebugLogger.logSimple('INIT', '❌ Error: $e');
      if (mounted) setState(() => _initStatus = 'Error: $e');
    }
  }

  Future<void> _checkAndShowAppGuide() async {
    final prefs = await SharedPreferences.getInstance();
    final hasSeen = prefs.getBool('has_seen_app_guide_v1') ?? false;
    if (!hasSeen && mounted) {
      DialogService.showAppGuide(context);
    }
  }

  /// Silently pre-warms the ASR neural engine in the background on native platforms
  /// after the initial Mushaf frame is completely rendered and idle (1500ms delay).
  /// This eliminates the 1-2s delay on first record tap while avoiding cold-start contention.
  void _scheduleEnginePrewarm() {
    if (PlatformCapabilities.isWeb || _engine.isInitialized) return;
    _enginePrewarmTimer?.cancel();
    _enginePrewarmTimer = Timer(const Duration(milliseconds: 1500), () {
      _enginePrewarmTimer = null;
      if (!mounted || _isBackgrounded || _engine.isInitialized) return;
      DebugLogger.logSimple('ASR', '⚡ Background pre-warming ASR engine...');
      unawaited(_engine.initialize().catchError((e) {
        DebugLogger.logSimple(
          'ASR',
          '⚠️ Background engine pre-warm safely handled error: $e',
        );
      }));
    });
  }

  /// Ensures the ASR engine is initialized.
  /// On Web, prompts for user bandwidth consent if the ~72MB model is not yet downloaded.
  Future<bool> _ensureEngineReady() async {
    _enginePrewarmTimer?.cancel();
    _enginePrewarmTimer = null;

    if (_engine.isInitialized) return true;

    if (PlatformCapabilities.isWeb) {
      final bool isCached = await _engine.isModelCached();
      if (!isCached && mounted) {
        final bool? proceed = await DialogService.showModelDownload(context);
        if (proceed != true) {
          return false;
        }
      }
    }

    if (!_engine.isInitialized) {
      if (mounted) setState(() => _isEngineLoading = true);
      AppState.instance.startModelDownload();
      try {
        await _engine.initialize();
        if (_engine.isInitialized) {
          AppState.instance.completeModelDownload();
        } else {
          AppState.instance.resetModelDownload();
        }
      } catch (e) {
        AppState.instance.resetModelDownload();
      } finally {
        if (mounted) setState(() => _isEngineLoading = false);
      }
    }
    return _engine.isInitialized;
  }

  Future<bool> _ensureMicPermission(PermissionReason reason) async {
    if (!PlatformCapabilities.isMobile) {
      return true;
    }
    final status = await Permission.microphone.status;
    if (status.isGranted) return true;

    final request = await Permission.microphone.request();
    if (request.isGranted) return true;

    if (mounted) {
      DialogService.showPermission(context, reason: reason);
    }
    return false;
  }

  Future<void> _startAudioRecordingStream() async {
    try {
      await _audio.start(
        onChunk: (chunk, isFinal) {
          // Software mute: drop mic frames while verse audio is playing or recording is inactive
          // so the AI model never hears the phone speaker or accepts input!
          if (QuranAudioService.instance.isPlaying || !_isRecording) return;
          _ctrl?.feed(chunk, isFinal: isFinal);
        },
      );
    } catch (e) {
      DebugLogger.logSimple('AUDIO', '❌ ERROR: $e');
      if (mounted) setState(() => _isRecording = false);
    }
  }

  void _onVerseAudioPlayingChanged(bool isAudio) {
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
          _broadcastMaglisProgress();
          unawaited(MaglisController.instance.releaseFloor(
            page: AppState.instance.currentMushafPage.value,
            surah: _ctrl?.targetSurah ?? AppState.instance.lastSurah,
            ayah: _ctrl?.activeAyah.value ?? AppState.instance.lastAyah,
          ));
          MaglisPlatform.setSpeaker(true);
        }
        // Screen remains awake continuously
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

        QuranAudioService.instance.stop();
        _engine.resetBuffer();

        if (_ctrl != null) {
          final int currentPage = AppState.instance.currentMushafPage.value;
          final int? activeAyah = _ctrl!.activeAyah.value;
          final int activeSurah = _ctrl!.targetSurah != 0
              ? _ctrl!.targetSurah
              : AppState.instance.lastSurah;

          int selectedSurah =
              QuranMetadata.isValidSurah(activeSurah) ? activeSurah : 1;
          int selectedAyah = (activeAyah != null && activeAyah > 0)
              ? activeAyah
              : AppState.instance.lastAyah;

          if (AppState.instance.isMushafMode) {
            // In a Maglis session, if another peer was reciting or an active verse was established,
            // maintain that exact verse instead of falling back to the first ayah on the page!
            final maglis = MaglisController.instance;
            if (maglis.inSession &&
                maglis.remoteAyah > 0 &&
                (maglis.isRemoteReciting || activeAyah == null) &&
                MushafProvider.instance.isAyahOnPage(
                  pageNumber: currentPage,
                  surah: maglis.remoteSurah,
                  ayah: maglis.remoteAyah,
                )) {
              selectedSurah = maglis.remoteSurah;
              selectedAyah = maglis.remoteAyah;
            } else if (activeAyah == null ||
                !MushafProvider.instance.isAyahOnPage(
                  pageNumber: currentPage,
                  surah: selectedSurah,
                  ayah: activeAyah,
                )) {
              final firstOnPage =
                  MushafProvider.instance.getFirstAyahOnPage(currentPage);
              if (firstOnPage != null) {
                selectedSurah = firstOnPage.$1;
                selectedAyah = firstOnPage.$2;
              } else {
                selectedAyah = 1;
              }
            } else {
              selectedAyah = activeAyah;
            }
          } else {
            // In Verse List mode:
            // Verses are chosen manually in the active surah. Do not reset to first ayah of Mushaf page!
            selectedSurah = QuranMetadata.isValidSurah(_ctrl!.targetSurah)
                ? _ctrl!.targetSurah
                : AppState.instance.lastSurah;
            selectedAyah = (activeAyah != null && activeAyah > 0)
                ? activeAyah
                : (AppState.instance.lastAyah > 0
                    ? AppState.instance.lastAyah
                    : 1);
          }

          if (_ctrl!.targetSurah != selectedSurah) {
            await _ctrl!.setTargetSurah(
              selectedSurah,
              preserveOtherSurahStates: true,
              clearTargetSurah: false,
            );
          }
          _ctrl!.setManualAyah(selectedSurah, selectedAyah);
          AppState.instance.saveLastPosition(selectedSurah, selectedAyah);
          final mappedPage = MushafProvider.instance
              .getPageForAyah(selectedSurah, selectedAyah);
          if (mappedPage != null) {
            AppState.instance.saveMushafPage(mappedPage);
          }

          // Only clear highlighting when the reciter presses the record button:
          // The current verse and any verse coming after it clears its coloring/highlighting
          // so it can be recolored by the new record. Verses before are strictly preserved.
          _ctrl!.clearHighlightsForwardFrom(selectedSurah, selectedAyah);
          MaglisController.instance
              .clearHighlightsFrom(selectedSurah, selectedAyah);

          _lastProcessedAyah = null;
          _lastProcessedSurah = null;

          _ctrl!.globalRevision.value++;

          _ctrl!.setRemoteReciting(false);
          _ctrl!.startRecordingSession();
          if (MaglisController.instance.inSession) {
            unawaited(MaglisController.instance.claimFloor(
              page: mappedPage ?? currentPage,
              surah: selectedSurah,
              ayah: selectedAyah,
              activeWord: 0,
            ));
          }
          if (mounted) setState(() => _isRecording = true);
          _broadcastMaglisProgress();
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
    _isRecording = false;
    _isToggling = false;
    _maglisBroadcastThrottle?.cancel();
    _audio.stop();
    _engine.resetBuffer();
    _ctrl?.finalize();
    // Screen remains awake continuously
    if (mounted) {
      setState(() {});
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

    // If activeAyah just advanced, ensure the previous ayah's final word is flushed preserving exact errors
    if (_lastProcessedAyah != null &&
        (_lastProcessedAyah != activeAyah ||
            _lastProcessedSurah != targetSurah)) {
      final prevAyah = _lastProcessedAyah!;
      final prevSurah = _lastProcessedSurah!;
      final prevVerse = _ctrl!.repository.getVerse(prevSurah, prevAyah);
      final prevWordCount = prevVerse?.uthmaniWords.length ?? 0;
      final prevClassification = _ctrl!.extractAyahWordClassification(
        prevSurah,
        prevAyah,
        prevWordCount,
      );

      if (prevClassification.greenWords.isNotEmpty ||
          prevClassification.yellowWords.isNotEmpty ||
          prevClassification.redWords.isNotEmpty) {
        final prevPage =
            MushafProvider.instance.getPageForAyah(prevSurah, prevAyah) ?? page;
        maglis.broadcastRecitation(
          page: prevPage,
          surah: prevSurah,
          ayah: prevAyah,
          activeWord: null,
          greenWords: prevClassification.greenWords,
          yellowWords: prevClassification.yellowWords,
          redWords: prevClassification.redWords,
          errors: prevClassification.wordErrors,
        );
      }
    }
    _lastProcessedAyah = activeAyah;
    _lastProcessedSurah = targetSurah;

    // Scan canonical verse words directly from loaded repository (never depends on GPU page cache)
    final currentVerse = _ctrl!.repository.getVerse(targetSurah, activeAyah);
    final wordCount = currentVerse?.uthmaniWords.length ?? 0;

    final classification = _ctrl!.extractAyahWordClassification(
      targetSurah,
      activeAyah,
      wordCount,
    );

    final activeWord = _ctrl!.getLeadWordIndex(
      surah: targetSurah,
      ayah: activeAyah,
      totalWords: wordCount,
      isRecording: true,
    );

    maglis.broadcastRecitation(
      page: page,
      surah: targetSurah,
      ayah: activeAyah,
      activeWord: activeWord,
      greenWords: classification.greenWords,
      yellowWords: classification.yellowWords,
      redWords: classification.redWords,
      errors: classification.wordErrors,
    );
  }

  /// Toggles global voice search across the Quran
  Future<void> _toggleVoiceSearch() async {
    QuranAudioService.instance.stop();
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
    QuranAudioService.instance.stop();
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

      _isVoiceSearchPaused = false;
      _audio.start(
        onChunk: (chunk, isFinal) {
          if (!_isVoiceSearchPaused) {
            _engine.transcribe(chunk, isFinal: isFinal);
          }
        },
      ).catchError((e) {
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
      // Screen remains awake continuously

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
        await _ctrl!.setTargetSurah(
          result.surah,
          preserveOtherSurahStates: true,
          clearTargetSurah: false,
        );
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
    if (kIsWeb) {
      return Scaffold(
        backgroundColor: c.bg,
        body: const SizedBox.expand(),
      );
    }
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

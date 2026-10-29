// Global application state singleton.
//
// Manages all user-configurable settings (language, theme, font size,
// blur mode, auto-scroll) and exposes the active [ThemeColors]
// palette. All UI widgets listen to this via [ChangeNotifier].
//
// Design: Zero-persistence — settings reset on app restart.
// This keeps the codebase dependency-free and startup instant.

import 'dart:async';
import 'package:flutter/material.dart';
import 'dart:ui' as ui;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:recite_quran/recite_quran.dart';
import '../services/quran_audio_service.dart';

// Supported UI languages.
enum AppLanguage { ar, en }

// Application Mode: Word Checker (Sherpa) vs Tajweed (Muaalem)
enum AppMode { wordChecker, tajweed }


// Available color themes: White and Black.
enum AppTheme { white, black }

// Failure reasons for audio streaming & API fetch.
enum AudioFailureReason {
  networkOffline,
  serverUnavailable,
  rateLimited,
  unknown,
}

/// Data payload for modern floating slide-up banners across the app.
class AppBannerInfo {
  final String id;
  final String messageAr;
  final String messageEn;
  final IconData icon;
  final Color Function(ThemeColors c, bool isDark)? customColor;
  final bool isWarning;
  final Duration? customDuration;

  const AppBannerInfo({
    required this.id,
    required this.messageAr,
    required this.messageEn,
    required this.icon,
    this.customColor,
    this.isWarning = false,
    this.customDuration,
  });
}

class AppState extends ChangeNotifier {
  AppState._() {
    // Initialize default language from the device's OS setting.
    final deviceLang = ui.PlatformDispatcher.instance.locale.languageCode;
    _lang = (deviceLang == 'ar') ? AppLanguage.ar : AppLanguage.en;
    languageNotifier = ValueNotifier<AppLanguage>(_lang);
    themeNotifier = ValueNotifier<AppTheme>(_theme);
  }

  /// Singleton instance — accessed everywhere as `AppState.instance`.
  static final AppState instance = AppState._();

  /// Dedicated ValueNotifiers for fine-grained reactivity without rebuilding the entire app tree.
  late final ValueNotifier<AppLanguage> languageNotifier;
  late final ValueNotifier<AppTheme> themeNotifier;
  final ValueNotifier<AppMode> modeNotifier = ValueNotifier<AppMode>(AppMode.wordChecker);
  final ValueNotifier<AppBannerInfo?> bannerNotifier = ValueNotifier<AppBannerInfo?>(null);

  SharedPreferences? _prefs;

  Future<SharedPreferences> _getPrefs() async {
    return _prefs ??= await SharedPreferences.getInstance();
  }

  // ── Language ───────────────────────────────────────────────────────────────

  late AppLanguage _lang;
  AppLanguage get lang => _lang;
  bool get isArabic => _lang == AppLanguage.ar;

  void toggleLanguage() async {
    _lang = _lang == AppLanguage.ar ? AppLanguage.en : AppLanguage.ar;
    languageNotifier.value = _lang;
    notifyListeners();
    final prefs = await _getPrefs();
    await prefs.setString('lang', _lang.name);
  }

  // ── Mode ───────────────────────────────────────────────────────────────────

  AppMode currentMode = AppMode.wordChecker;
  int tajweedClickCount = 0;
  bool get hasClickedTajweedWord => tajweedClickCount >= 10;

  void setMode(AppMode mode) {
    if (currentMode != mode) {
      currentMode = mode;
      modeNotifier.value = mode;
      notifyListeners();
    }
  }

  Future<void> markTajweedWordClicked() async {
    if (tajweedClickCount < 10) {
      tajweedClickCount++;
      notifyListeners();
      final prefs = await _getPrefs();
      await prefs.setInt('tajweed_click_count', tajweedClickCount);
    }
  }

  // ── Theme ──────────────────────────────────────────────────────────────────

  AppTheme _theme = AppTheme.white;
  AppTheme get theme => _theme;
  bool get isDarkMode => _theme == AppTheme.black;
  bool get isBlack => _theme == AppTheme.black;
  bool get isWhite => _theme == AppTheme.white;
  bool get isOled => _theme == AppTheme.black;
  bool get isParchment => false;

  void setTheme(AppTheme t) async {
    _theme = t;
    themeNotifier.value = _theme;
    notifyListeners();
    final prefs = await _getPrefs();
    await prefs.setString('theme', _theme.name);
  }

  // ── Blur Mode ──────────────────────────────────────────────────────────────

  bool isBlurMode = false;

  /// Dedicated notifier for blur mode changes (allows scoped listening without global ChangeNotifier).
  final ValueNotifier<bool> blurModeNotifier = ValueNotifier<bool>(false);

  void toggleBlurMode() async {
    isBlurMode = !isBlurMode;
    blurModeNotifier.value = isBlurMode;
    notifyListeners();
    final prefs = await _getPrefs();
    await prefs.setBool('blurMode', isBlurMode);
  }

  // ── Mushaf Layout ──────────────────────────────────────────────────────────
  final ValueNotifier<int> currentMushafPage = ValueNotifier<int>(1);

  int mushafAudioClickCount = 0;
  bool get hasClickedMushafAudioAyah => mushafAudioClickCount >= 10;

  Future<void> markMushafAudioAyahClicked() async {
    if (mushafAudioClickCount < 10) {
      mushafAudioClickCount++;
      notifyListeners();
      final prefs = await _getPrefs();
      await prefs.setInt('mushaf_audio_click_count', mushafAudioClickCount);
    }
  }

  Future<void> saveMushafPage(int page) async {
    if (page < 1 || page > 604) return;
    currentMushafPage.value = page;
    try {
      final prefs = await _getPrefs();
      await prefs.setInt('last_mushaf_page', page);
    } catch (_) {}
  }


  // ── Last Recitation Position ──────────────────────────────────────────────

  int lastSurah = 1;
  int lastAyah = 1;

  Future<void> saveLastPosition(int surah, int ayah) async {
    if (surah < 1 || surah > 114 || ayah < 1 || ayah > 286) return;
    if (lastSurah == surah && lastAyah == ayah) return;
    lastSurah = surah;
    lastAyah = ayah;
    try {
      final prefs = await _getPrefs();
      await prefs.setInt('last_surah', surah);
      await prefs.setInt('last_ayah', ayah);
    } catch (_) {}
  }

  // ── Tracker Configuration ──────────────────────────────────────────────────
  // Tajweed and Dictation modes use standard normal calibration with auto-reanchor enabled (stall threshold: 50).
  TrackerConfig _trackerConfig = TrackerConfig.normal(
    enableAutoReanchor: true,
    reanchorStallThreshold: 50,
  );
  TrackerConfig get trackerConfig => _trackerConfig;

  // ── Verse Audio Playback (UI state ready for backend audio wiring) ───────────
  /// Currently active audio verse playback.
  final ValueNotifier<int?> activeAudioAyah = ValueNotifier<int?>(null);
  final ValueNotifier<int?> activeAudioSurah = ValueNotifier<int?>(null);
  final ValueNotifier<bool> isAudioPlaying = ValueNotifier<bool>(false);

  /// Whether audio is actively connecting or buffering, providing instant feedback on tap.
  final ValueNotifier<bool> isAudioBuffering = ValueNotifier<bool>(false);

  /// Active word index (0-based) inside the active audio Ayah, synchronized to audio playback.
  final ValueNotifier<int?> activeAudioWordIndex = ValueNotifier<int?>(null);

  /// Determines whether playback automatically advances to next Ayah (continuous mode)
  /// or stops after playing a single Ayah (record mode).
  final ValueNotifier<bool> isContinuousPlayback = ValueNotifier<bool>(true);

  /// Currently active modern banner (replaces old SnackBars and unifies feedback).
  AppBannerInfo? currentBanner;
  Timer? _bannerTimer;

  bool get isBannerVisible => currentBanner != null;

  /// Whether audio failure banner is visible (backward compatibility).
  bool get isAudioErrorBannerVisible => currentBanner?.id == 'audio_error';
  AudioFailureReason lastAudioFailureReason = AudioFailureReason.networkOffline;

  /// Set of banner IDs already seen by the user to provide adaptive display durations.
  final Set<String> _seenBannerIds = <String>{};

  /// Computes adaptive duration: readable on first impression, fast and non-intrusive on subsequent views.
  Duration _getDynamicBannerDuration(AppBannerInfo banner) {
    if (banner.customDuration != null) return banner.customDuration!;

    final bool isFirstTime = !_seenBannerIds.contains(banner.id);
    if (isFirstTime) {
      _seenBannerIds.add(banner.id);
      unawaited(_saveSeenBanners());
      // First appearance: comfortably readable
      if (banner.id == 'ayah_not_found') {
        return const Duration(milliseconds: 2400);
      }
      return const Duration(milliseconds: 3200);
    } else {
      // Subsequent appearances: fast, snappy confirmation
      if (banner.id == 'ayah_not_found') {
        return const Duration(milliseconds: 1700);
      }
      return const Duration(milliseconds: 1800);
    }
  }

  Future<void> _saveSeenBanners() async {
    try {
      final prefs = await _getPrefs();
      await prefs.setStringList('seen_banner_ids', _seenBannerIds.toList());
    } catch (_) {}
  }

  /// Displays the modern slide-up floating banner.
  void showBanner(AppBannerInfo banner) {
    currentBanner = banner;
    bannerNotifier.value = banner;
    _bannerTimer?.cancel();
    notifyListeners();

    final Duration effectiveDuration = _getDynamicBannerDuration(banner);
    _bannerTimer = Timer(effectiveDuration, () {
      if (currentBanner?.id == banner.id) {
        currentBanner = null;
        bannerNotifier.value = null;
        notifyListeners();
      }
    });
  }

  /// Dismisses any currently visible modern banner.
  void dismissBanner() {
    _bannerTimer?.cancel();
    if (currentBanner != null) {
      currentBanner = null;
      bannerNotifier.value = null;
      notifyListeners();
    }
  }

  /// Dispatches an audio failure event to display the modern serene banner.
  void triggerAudioError([AudioFailureReason reason = AudioFailureReason.networkOffline]) {
    lastAudioFailureReason = reason;

    final String arMsg;
    final String enMsg;
    final IconData icon;
    switch (reason) {
      case AudioFailureReason.serverUnavailable:
        icon = Icons.cloud_off_rounded;
        arMsg = 'تعذر الوصول إلى خادم التلاوة • يرجى المحاولة لاحقاً';
        enMsg = 'Audio server temporarily unavailable • Please try again later';
        break;
      case AudioFailureReason.rateLimited:
        icon = Icons.hourglass_top_rounded;
        arMsg = 'تم تجاوز حد الطلبات المؤقت • يرجى الانتظار قليلاً';
        enMsg = 'Rate limit reached • Please wait a moment and try again';
        break;
      case AudioFailureReason.networkOffline:
      case AudioFailureReason.unknown:
        icon = Icons.wifi_off_rounded;
        arMsg = 'يتطلب تشغيل التلاوة اتصالاً بالإنترنت • تحقق من الشبكة وحاول ثانية';
        enMsg = 'Audio playback requires internet • Check connection and try again';
        break;
    }

    showBanner(AppBannerInfo(
      id: 'audio_error',
      messageAr: arMsg,
      messageEn: enMsg,
      icon: icon,
      isWarning: true,
      customDuration: const Duration(milliseconds: 3600),
    ));
  }

  /// Immediately dismisses the audio error banner.
  void dismissAudioError() {
    if (currentBanner?.id == 'audio_error') {
      dismissBanner();
    }
  }

  /// Dispatches the modern Tajweed mode enabled banner.
  void showTajweedBanner() {
    showBanner(const AppBannerInfo(
      id: 'tajweed',
      messageAr: 'تم تفعيل التجويد • اضغط على الكلمات الصفراء لمعرفة الخطأ',
      messageEn: 'Tajweed Enabled • Tap yellow words for error details',
      icon: Icons.record_voice_over_rounded,
      isWarning: false,
    ));
  }

  /// Dismisses the Tajweed banner.
  void dismissTajweedBanner() {
    if (currentBanner?.id == 'tajweed') {
      dismissBanner();
    }
  }

  /// Dispatches the modern Ayah Not Found banner (replacing old SnackBar).
  void showAyahNotFoundBanner() {
    showBanner(const AppBannerInfo(
      id: 'ayah_not_found',
      messageAr: 'لم يتم العثور على أي آية • حاول مرة أخرى',
      messageEn: 'No Ayah found • Please try again',
      icon: Icons.search_off_rounded,
      isWarning: true,
    ));
  }

  /// Dispatches the modern Settings Reset banner (replacing old SnackBar).
  void showSettingsResetBanner() {
    showBanner(const AppBannerInfo(
      id: 'settings_reset',
      messageAr: 'تمت إعادة ضبط الإعدادات بنجاح',
      messageEn: 'Settings reset successfully',
      icon: Icons.check_circle_outline_rounded,
      isWarning: false,
    ));
  }

  /// Dispatches the modern Memorization (Blur) banner.
  void showBlurBanner(bool isEnabled) {
    if (isEnabled) {
      showBanner(const AppBannerInfo(
        id: 'blur_mode',
        messageAr: 'تم تفعيل وضع الحفظ • إخفاء الكلمات لاختبار التسميع',
        messageEn: 'Memorization Mode Enabled • Words hidden for recitation test',
        icon: Icons.visibility_off_rounded,
        isWarning: false,
      ));
    }
  }

  /// Dispatches the Mushaf Ayah audio hint banner (shows until user clicks ayah audio 10 times).
  void showMushafAudioBanner() {
    if (hasClickedMushafAudioAyah) return;
    showBanner(const AppBannerInfo(
      id: 'mushaf_audio_hint',
      messageAr: 'المس رقم أي آية للاستماع إلى التلاوة العطرة',
      messageEn: 'Tap any Ayah number to listen to recitation',
      icon: Icons.headphones_rounded,
      isWarning: false,
      customDuration: Duration(milliseconds: 4000),
    ));
  }

  /// Dismisses the Mushaf Ayah audio hint banner.
  void dismissMushafAudioBanner() {
    if (currentBanner?.id == 'mushaf_audio_hint') {
      dismissBanner();
    }
  }

  /// Toggles play/pause state for a specific verse.
  /// When [continuous] is true (outside record mode), playback advances to the next Ayah on finish.
  /// When [continuous] is false (in record mode), only this single Ayah is played.
  void toggleVerseAudio({
    required int surah,
    required int ayah,
    bool continuous = true,
  }) {
    final bool isWord = QuranAudioService.instance.isSingleWordMode;
    if (isWord) {
      QuranAudioService.instance.play(
        surah: surah,
        ayah: ayah,
        continuous: continuous,
      );
      return;
    }
    if (activeAudioSurah.value == surah &&
        activeAudioAyah.value == ayah &&
        isAudioPlaying.value) {
      QuranAudioService.instance.pause();
    } else if (activeAudioSurah.value == surah &&
               activeAudioAyah.value == ayah &&
               QuranAudioService.instance.isPaused) {
      QuranAudioService.instance.resume();
    } else {
      QuranAudioService.instance.play(
        surah: surah,
        ayah: ayah,
        continuous: continuous,
      );
    }
  }

  /// Advances playback to the next Ayah if continuous mode is active.
  /// Stops playback if [isContinuousPlayback] is false (e.g. record mode) or if surah end is reached.
  void onAyahAudioFinished({int? totalAyahsInSurah}) {
    if (!isAudioPlaying.value) return;

    if (!isContinuousPlayback.value) {
      // In record mode: single ayah only per click
      stopVerseAudio();
      return;
    }

    // Out of record mode: advance to next ayah
    final currentAyah = activeAudioAyah.value;
    final currentSurah = activeAudioSurah.value;
    if (currentAyah == null || currentSurah == null) {
      stopVerseAudio();
      return;
    }

    final maxAyah = totalAyahsInSurah ?? 286;
    if (currentAyah < maxAyah) {
      QuranAudioService.instance.play(
        surah: currentSurah,
        ayah: currentAyah + 1,
        continuous: true,
      );
    } else if (currentSurah < 114) {
      QuranAudioService.instance.play(
        surah: currentSurah + 1,
        ayah: 1,
        continuous: true,
      );
    } else {
      stopVerseAudio();
    }
  }

  /// Pauses or stops active verse audio playback.
  void stopVerseAudio() {
    isAudioBuffering.value = false;
    QuranAudioService.instance.stop();
  }

  // ── Colors ─────────────────────────────────────────────────────────────────

  /// Returns the active color palette based on the current theme.
  ThemeColors get colors {
    switch (_theme) {
      case AppTheme.white:
        return _whiteColors;
      case AppTheme.black:
        return _blackColors;
    }
  }

  // ──────────────────────────────────────────────────────────────────────────
  // WHITE THEME — Warm Natural Linen (Zero Glare, Eye-Comfortable)
  // Warm ivory foundation (#FAF8F5), soft clean surfaces, gentle borders,
  // deep charcoal typography (#1E293B) to avoid harsh optical glare.
  // ──────────────────────────────────────────────────────────────────────────
  static const ThemeColors _whiteColors = ThemeColors(
    bg: Color(0xFFFAF8F5),             // Warm natural linen paper (minimizes blue light)
    surface: Color(0xFFFFFFFF),        // Clean white card surface
    surfaceHigh: Color(0xFFF4F0E8),    // Soft warm elevation layer 1
    surfaceVariant: Color(0xFFEBE5D8), // Soft warm elevation layer 2
    glassSurface: Color(0xEEFAF8F5),   // 93% frosted linen overlay
    border: Color(0xFFE8E2D5),          // Gentle warm border
    cardBorder: Color(0xFFE8E2D5),
    primary: Color(0xFF047857),        // Deep calm emerald green
    onPrimary: Color(0xFFFFFFFF),      // Crisp white on primary
    secondary: Color(0xFF0D9488),      // Calming Teal
    gold: Color(0xFFB45309),           // Warm antique gold
    green: Color(0xFF15803D),          // Soothing Botanical Green (true green, 5.4:1 contrast on linen, zero glare)
    red: Color(0xFFC02626),            // Warm terracotta crimson (refined, 5.8:1 contrast, non-alarming)
    muted: Color(0xFF64748B),          // Slate-500 neutral muted
    currentWord: Color(0xFF0D9488),    // Calming teal active word highlight
    wordHighlight: Color(0xFF0D9488),  // Calming teal active word highlight
    text: Color(0xFF1E293B),           // Slate-800 deep charcoal (13:1 eye-gentle contrast)
    textSecondary: Color(0xFF475569),  // Slate-600 secondary text
    ayahOutline: Color(0x2EB45309),    // Soft warm amber outline (~18% alpha)
    ambientGlow: Color(0x18047857),    // Ambient soft emerald glow
    success: Color(0xFF15803D),        // Soothing botanical green success
    warning: Color(0xFFB58900),        // Eye-comforting warm golden yellow (high legibility on linen, zero orange glare)
    error: Color(0xFFC02626),          // Terracotta crimson error
    info: Color(0xFF2563EB),           // Calming sapphire info
    cyan: Color(0xFF0D9488),           // Calm teal
    indigo: Color(0xFF4338CA),         // Royal Indigo
    emerald: Color(0xFF047857),        // Deep emerald
  );

  // ──────────────────────────────────────────────────────────────────────────
  // BLACK THEME — Deep OLED True Black (Tahajjud Eye Comfort)
  // True black foundation (#000000) for OLED battery, paired with soft
  // moonlit pearl text (#E2E8F0) to eliminate night glare & eye fatigue.
  // ──────────────────────────────────────────────────────────────────────────
  static const ThemeColors _blackColors = ThemeColors(
    bg: Color(0xFF000000),             // Pure OLED True Black
    surface: Color(0xFF0D0F14),        // Ultra-deep charcoal surface
    surfaceHigh: Color(0xFF151922),    // Elevation layer 1
    surfaceVariant: Color(0xFF1C222E), // Elevation layer 2
    glassSurface: Color(0xE005070A),   // 88% OLED glassmorphism
    border: Color(0xFF202736),          // Subtle boundary
    cardBorder: Color(0xFF202736),
    primary: Color(0xFF10B981),        // Serene Emerald
    onPrimary: Color(0xFF000000),
    secondary: Color(0xFF06B6D4),      // Cyan Spark
    gold: Color(0xFFEAB308),           // Luminous Amber Gold
    green: Color(0xFF22C55E),          // Calming leaf green (soothing, zero halation)
    red: Color(0xFFE06D63),            // Gentle rose terracotta (soft, halation-free)
    muted: Color(0xFF64748B),          // Slate-500 neutral muted
    currentWord: Color(0xFF14B8A6),    // Calming luminous teal active word highlight
    wordHighlight: Color(0xFF14B8A6),  // Calming luminous teal active word highlight
    text: Color(0xFFE2E8F0),           // Moonlit pearl (halation-free)
    textSecondary: Color(0xFF94A3B8),  // Slate-400
    ayahOutline: Color(0x35EAB308),    // Soft amber outline
    ambientGlow: Color(0x2510B981),    // Gentle emerald glow
    success: Color(0xFF22C55E),        // Calming leaf green success
    warning: Color(0xFFFACC15),        // Soothing luminous candlelight yellow (pure warm yellow, zero orange glare)
    error: Color(0xFFE06D63),          // Gentle rose terracotta error
    info: Color(0xFF38BDF8),
    cyan: Color(0xFF06B6D4),
    indigo: Color(0xFF818CF8),
    emerald: Color(0xFF10B981),
  );

  Future<void> load() async {
    try {
      final prefs = await _getPrefs();

      if (prefs.containsKey('lang')) {
        _lang = prefs.getString('lang') == 'en'
            ? AppLanguage.en
            : AppLanguage.ar;
      }
      if (prefs.containsKey('theme')) {
        final themeStr = prefs.getString('theme');
        try {
          _theme = AppTheme.values.firstWhere((t) => t.name == themeStr);
        } catch (_) {
          _theme = (themeStr == 'dark' || themeStr == 'oled' || themeStr == 'black')
              ? AppTheme.black
              : AppTheme.white;
        }
      } else {
        final brightness = WidgetsBinding.instance.platformDispatcher.platformBrightness;
        _theme = brightness == Brightness.dark ? AppTheme.black : AppTheme.white;
      }
      isBlurMode = prefs.getBool('blurMode') ?? false;
      blurModeNotifier.value = isBlurMode;

      tajweedClickCount = prefs.getInt('tajweed_click_count') ?? 0;
      // Migrate old boolean value if present
      if (tajweedClickCount == 0 && (prefs.getBool('has_clicked_tajweed_word') ?? false)) {
        tajweedClickCount = 10;
      }

      mushafAudioClickCount = prefs.getInt('mushaf_audio_click_count') ?? 0;

      final seenBanners = prefs.getStringList('seen_banner_ids');
      if (seenBanners != null) {
        _seenBannerIds.addAll(seenBanners);
      }

      lastSurah = (prefs.getInt('last_surah') ?? 1).clamp(1, 114);
      lastAyah = (prefs.getInt('last_ayah') ?? 1).clamp(1, 286);
      final savedPage = prefs.getInt('last_mushaf_page');
      if (savedPage != null && savedPage >= 1 && savedPage <= 604) {
        currentMushafPage.value = savedPage;
      }

      themeNotifier.value = _theme;
      languageNotifier.value = _lang;
      modeNotifier.value = currentMode;

      notifyListeners();
    } catch (e) {
      DebugLogger.logSimple('AppState', "Error loading settings: $e");
    }
  }
}

/// 2026 Design Token Palette used across the application.
///
/// Implements WCAG AA/AAA compliant Obsidian / Slate dark mode architecture,
/// clean spacious light mode, and vibrant 2026 accents (Emerald Glow, Cyan Spark, Electric Indigo).
class ThemeColors {
  final Color bg;
  final Color surface;
  final Color surfaceHigh;
  final Color surfaceVariant;
  final Color glassSurface;
  final Color border;
  final Color cardBorder;
  final Color primary;
  final Color onPrimary;
  final Color secondary;
  final Color gold;
  final Color green;
  final Color red;
  final Color muted;
  final Color currentWord;
  final Color wordHighlight;
  final Color text;
  final Color textSecondary;
  final Color ayahOutline;
  final Color ambientGlow;
  final Color success;
  final Color warning;
  final Color error;
  final Color info;
  final Color cyan;
  final Color indigo;
  final Color emerald;

  const ThemeColors({
    required this.bg,
    required this.surface,
    required this.surfaceHigh,
    required this.surfaceVariant,
    required this.glassSurface,
    required this.border,
    required this.cardBorder,
    required this.primary,
    required this.onPrimary,
    required this.secondary,
    required this.gold,
    required this.green,
    required this.red,
    required this.muted,
    required this.currentWord,
    required this.wordHighlight,
    required this.text,
    required this.textSecondary,
    required this.ayahOutline,
    required this.ambientGlow,
    required this.success,
    required this.warning,
    required this.error,
    required this.info,
    required this.cyan,
    required this.indigo,
    required this.emerald,
  });

  /// A faded version of gold for subtle backgrounds.
  Color get goldFade => gold.withValues(alpha: 0.25);
  
  /// A faded version of primary for subtle pill backgrounds.
  Color get primaryFade => primary.withValues(alpha: 0.12);

  /// Modern eye-comforting word recitation text colors:
  /// green = correct, red = skipped, yellow/warning = wrong/mistake
  Color get wordCorrect => green;
  Color get wordSkipped => red;
  Color get wordWrong => warning;
}

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:recite_quran/recite_quran.dart' show QuranRepository;

import '../prayer/prayer_mode.dart';
import 'auto_correct.dart';
import 'recitation_event.dart';
import 'recitation_tracker.dart';
import 'recited_word.dart';

/// One recitation (a recording session of the microphone) with what runs
/// alongside the tracker: [prayer] mode and/or [autoCorrect], both adding
/// to the one [log].
///
/// Speech recognizer results go to both; prayer mode hears them first (an
/// "Allāhu akbar" ends the recitation before auto-correct could take it for
/// a wrong word).
class RecitationSession extends ChangeNotifier {
  RecitationSession({
    required this.log,
    this.prayer,
    AutoCorrect? autoCorrect,
    this.autoTick = true,
  }) : _autoCorrect = autoCorrect {
    log.addListener(notifyListeners);
    prayer?.addListener(notifyListeners);
    autoCorrect?.addListener(notifyListeners);
  }

  /// A session for the app's Quran data: prayer mode if [prayer], and
  /// auto-correct, silent if [autoCorrectSilent] (prayer mode without
  /// auto-correct shows what it would do).
  static Future<RecitationSession> create({
    required RecitationTracker tracker,
    required QuranRepository repository,
    bool prayer = false,
    bool autoCorrect = true,
    bool autoCorrectSilent = false,
    void Function(String message)? debugLog,
  }) async {
    final log = RecitationLog(debugLog: debugLog);
    return RecitationSession(
      log: log,
      prayer: prayer
          ? PrayerMode.create(
              tracker: tracker, repository: repository, log: log)
          : null,
      autoCorrect: autoCorrect
          ? await AutoCorrect.create(
              tracker: tracker,
              repository: repository,
              log: log,
              silent: autoCorrectSilent,
              debugLog: debugLog,
            )
          : null,
    );
  }

  final RecitationLog log;
  final PrayerMode? prayer;
  AutoCorrect? _autoCorrect;

  /// Auto-correct, if it runs (in prayer mode it always does: silent when
  /// auto-correct is off).
  AutoCorrect? get autoCorrect => _autoCorrect;

  /// Whether the session runs its own timer; tests call [tick] instead.
  final bool autoTick;

  Timer? _timer;
  bool _running = false;

  bool get running => _running;
  List<RecitationEvent> get events => log.events;

  /// Where the recitation is: where prayer mode will resume while it waits
  /// for al-Fātiḥa, otherwise the next word expected.
  MushafWord? get position {
    final p = prayer;
    if (p != null && p.phase != PrayerPhase.following) return p.position;
    return autoCorrect?.position ?? p?.position;
  }

  /// Starts; prayer mode (if any) with the plan beginning at [ayah] of
  /// [surah].
  Future<void> start({int? surah, int? ayah}) async {
    if (_running) return;
    _running = true;
    final p = prayer;
    if (p != null) await p.start(surah!, ayah!);
    autoCorrect?.start();
    if (autoTick) {
      _timer = Timer.periodic(const Duration(milliseconds: 250), (_) => tick());
    }
    notifyListeners();
  }

  void stop() {
    if (!_running) return;
    _running = false;
    _timer?.cancel();
    _timer = null;
    prayer?.stop();
    autoCorrect?.stop();
    notifyListeners();
  }

  /// Puts [next] (or nothing) in place of auto-correct, as it is turned on
  /// or off during the recitation. The new one follows from where the
  /// tracker is.
  void replaceAutoCorrect(AutoCorrect? next) {
    final old = _autoCorrect;
    if (identical(old, next)) return;
    old?.removeListener(notifyListeners);
    old?.dispose();
    _autoCorrect = next;
    next?.addListener(notifyListeners);
    if (_running) next?.start();
    notifyListeners();
  }

  /// Feeds one speech recognizer result.
  void addTranscription({
    required List<String> tokens,
    bool isFinal = false,
    int epoch = 0,
  }) {
    if (!_running) return;
    prayer?.addTranscription(tokens: tokens, isFinal: isFinal, epoch: epoch);
    autoCorrect?.addTranscription(
        tokens: tokens, isFinal: isFinal, epoch: epoch);
    tick();
  }

  /// Re-checks everything time-based. Called every 250 ms while running.
  void tick() {
    if (!_running) return;
    prayer?.tick();
    autoCorrect?.tick();
  }

  @override
  void dispose() {
    stop();
    log.removeListener(notifyListeners);
    prayer?.removeListener(notifyListeners);
    autoCorrect?.removeListener(notifyListeners);
    prayer?.dispose();
    autoCorrect?.dispose();
    log.dispose();
    super.dispose();
  }
}

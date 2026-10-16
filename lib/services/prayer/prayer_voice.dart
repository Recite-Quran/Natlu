import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

import '../audio/verse_audio_player.dart';
import '../quran_timing_service.dart';
import '../recitation/recited_word.dart';
import 'prayer_session.dart';

/// What prayer mode is playing.
enum PrayerSound {
  /// The mistake beep.
  beep,

  /// The words the reciter is expected to say next, read aloud (a prompt
  /// after a pause or a wrong word). The microphone should be muted
  /// meanwhile, so the tracker doesn't take them for the reciter's.
  words,

  /// Words the reciter left out, read aloud. The tracker has gone past
  /// them, so it won't take them for the reciter's: the microphone stays on
  /// (the reciter may well be reciting on).
  leftOutWords,
}

/// Plays prayer mode's sounds.
abstract class PrayerAudioOutput {
  /// Plays the mistake beep; completes when it has finished.
  Future<void> beep();

  /// Reads words [firstWord] to [lastWord] (word indexes, from 0) of [ayah]
  /// of [surah] aloud; completes when they have been read, or [stop] was
  /// called. Calls [onAudible] once loading is done and they start to be
  /// heard. False if the recitation of that ayah can't be played (e.g.
  /// offline and not cached).
  Future<bool> playWords(int surah, int ayah, int firstWord, int lastWord,
      {void Function()? onAudible});

  /// Stops whatever is playing; what was playing completes.
  Future<void> stop();

  /// Gets [ayah] of [surah] ready to be read from, if it can (in the
  /// background).
  void prepare(int surah, int ayah);

  void dispose();
}

/// Makes the sounds of a [PrayerSession]: a beep at each mistake, and the
/// right words read aloud at each prompt.
///
/// A prompt cuts a beep short; a beep while words are being read is left
/// out (the words say more). If the words can't be played, a double beep
/// stands in for them (they are shown on screen). It also keeps the
/// recitation of the ayahs ahead ready, so a prompt plays without delay.
class PrayerVoice {
  PrayerVoice({required this.session, required this.output, this.log}) {
    _seen = session.events.length;
    session.addListener(_onSession);
    _prepareAround(session.position);
  }

  final PrayerSession session;
  final PrayerAudioOutput output;
  final void Function(String message)? log;

  /// What can be heard now, if anything.
  final ValueNotifier<PrayerSound?> playing = ValueNotifier(null);

  /// The sound in progress (still loading, or playing).
  PrayerSound? _current;
  int _seen = 0;
  int _generation = 0;
  (int, int)? _prepared;
  bool _disposed = false;

  void _onSession() {
    final events = session.events;
    for (int i = _seen; i < events.length; i++) {
      _handle(events[i]);
    }
    _seen = events.length;
    _prepareAround(session.position);
  }

  void _handle(PrayerEvent e) {
    switch (e.kind) {
      case PrayerEventKind.mistake:
        if (_current == null) {
          unawaited(_play(PrayerSound.beep, (_) => output.beep(), 'beep'));
        }
      case PrayerEventKind.prompt:
        final refs = e.wordRefs;
        if (refs.isEmpty) return;
        final first = refs.first;
        // Read the words in the first word's ayah (a prompt rarely runs on
        // into the next one, and then the first words are what matter).
        final last = refs
            .lastWhere((w) => w.surah == first.surah && w.ayah == first.ayah);
        final what = '${first.surah}:${first.ayah} words '
            '${first.wordIndex0}-${last.wordIndex0}';
        final sound = e.reason == PrayerReason.skipped
            ? PrayerSound.leftOutWords
            : PrayerSound.words;
        unawaited(_play(sound, (heard) async {
          final read = await output.playWords(
              first.surah, first.ayah, first.wordIndex0, last.wordIndex0,
              onAudible: () => heard(sound));
          if (!read) {
            heard(PrayerSound.beep);
            log?.call('sound: $what unavailable, double beep instead');
            await output.beep();
            await output.beep();
          }
        }, what));
      case PrayerEventKind.takbir:
      case PrayerEventKind.stopped:
        unawaited(stop());
      case PrayerEventKind.started:
      case PrayerEventKind.fatihaEnded:
      case PrayerEventKind.nextSurah:
      case PrayerEventKind.corrected:
        break;
    }
  }

  /// Plays [sound] by running [body], which calls the function it is given
  /// with what starts to be heard.
  Future<void> _play(
      PrayerSound sound,
      Future<void> Function(void Function(PrayerSound heard) heard) body,
      String what) async {
    final generation = ++_generation;
    if (_current != null) {
      try {
        await output.stop();
      } catch (_) {}
    }
    if (_disposed || generation != _generation) return;
    _current = sound;
    playing.value = sound == PrayerSound.beep ? sound : null;
    final started = DateTime.now();
    log?.call('sound: $what');
    try {
      await body((heard) {
        if (!_disposed && generation == _generation) playing.value = heard;
      });
      log?.call('sound: $what done in '
          '${DateTime.now().difference(started).inMilliseconds} ms');
    } catch (e) {
      log?.call('sound: $what failed: $e');
    } finally {
      if (!_disposed && generation == _generation) {
        _current = null;
        playing.value = null;
      }
    }
  }

  /// Stops any sound now.
  Future<void> stop() async {
    _generation++;
    _current = null;
    try {
      await output.stop();
    } catch (_) {}
    if (!_disposed) playing.value = null;
  }

  /// Keeps the ayah at [where] and the one after it ready.
  void _prepareAround(MushafWord? where) {
    if (where == null) return;
    final key = (where.surah, where.ayah);
    if (_prepared == key) return;
    _prepared = key;
    output.prepare(where.surah, where.ayah);
    output.prepare(where.surah, where.ayah + 1);
  }

  void dispose() {
    if (_disposed) return;
    _generation++;
    session.removeListener(_onSession);
    unawaited(output.stop().catchError((_) {}));
    output.dispose();
    _disposed = true;
    playing.dispose();
  }
}

/// [PrayerAudioOutput] with the app's recitation (Al-Ḥuṣarī, one file per
/// ayah, cached on the device) and word timings, on its own player.
class JustAudioPrayerOutput implements PrayerAudioOutput {
  static const String beepAsset = 'assets/audio/prayer_beep.wav';

  /// Taken from before and after the words' timings, so their first and last
  /// sounds aren't clipped.
  static const Duration _lead = Duration(milliseconds: 40);
  static const Duration _tail = Duration(milliseconds: 150);

  AudioPlayer? _player;

  /// Completed by [stop], to end the sound in progress.
  Completer<void>? _stopped;

  /// The sound in progress; the next one waits for it to wind down.
  Future<void> _last = Future.value();

  AudioPlayer get _audio => _player ??= AudioPlayer(
        handleInterruptions: false,
        handleAudioSessionActivation: false,
      );

  @override
  Future<void> beep() async {
    await _playSource(() async => AudioSource.asset(beepAsset),
        timeout: const Duration(seconds: 3));
  }

  @override
  Future<bool> playWords(int surah, int ayah, int firstWord, int lastWord,
      {void Function()? onAudible}) {
    return _playSource(() async {
      final timing = (await QuranTimingService.instance
              .ensureSurahLoaded(surah)
              .timeout(const Duration(seconds: 8), onTimeout: () => null))
          ?.getAyah(ayah);
      if (timing == null) return null;
      int? startMs;
      int? endMs;
      for (final w in timing.words) {
        if (w.wordIndex == firstWord) startMs = w.startMs;
        if (w.wordIndex == lastWord) endMs = w.endMs;
      }
      if (startMs == null || endMs == null || endMs <= startMs) return null;
      final source = await VerseAudioPlayer.createAyahAudioSource(surah, ayah);
      if (source is! UriAudioSource) return null;
      final start = Duration(milliseconds: startMs) - _lead;
      return ClippingAudioSource(
        child: source,
        start: start.isNegative ? Duration.zero : start,
        end: Duration(milliseconds: endMs) + _tail,
      );
    }, timeout: const Duration(seconds: 20), onAudible: onAudible);
  }

  /// Plays what [source] gives (nothing if it gives null), one sound at a
  /// time. False if there was nothing to play or it couldn't be loaded;
  /// true once it has played or was stopped.
  Future<bool> _playSource(Future<AudioSource?> Function() source,
      {required Duration timeout, void Function()? onAudible}) {
    final stopped = Completer<void>();
    final previous = _last;
    final run = () async {
      await previous;
      _stopped = stopped;
      if (stopped.isCompleted) return true;
      final player = _audio;
      try {
        await VerseAudioPlayer.ensureMediaAudioSession();
        final s = await source();
        if (s == null) return false;
        if (stopped.isCompleted) return true;
        await player.setAudioSource(s).timeout(timeout);
        if (stopped.isCompleted) return true;
        final done = player.processingStateStream.firstWhere((state) =>
            state == ProcessingState.completed ||
            state == ProcessingState.idle);
        onAudible?.call();
        // play() only completes once playback ends, which a stalled stream
        // never does: wait for the end (or stop) with a time limit instead.
        unawaited(player.play().catchError((_) {}));
        await Future.any([done, stopped.future]).timeout(timeout);
        return true;
      } catch (e) {
        if (stopped.isCompleted) return true;
        debugPrint('[PRAYER] could not play: $e');
        return false;
      } finally {
        try {
          await player.stop();
        } catch (_) {}
      }
    }();
    _last = run.then((_) {}, onError: (_) {});
    return run;
  }

  @override
  Future<void> stop() async {
    final stopped = _stopped;
    if (stopped != null && !stopped.isCompleted) stopped.complete();
    try {
      await _player?.stop();
    } catch (_) {}
  }

  @override
  void prepare(int surah, int ayah) {
    if (surah < 1 ||
        surah > 114 ||
        ayah > VerseAudioPlayer.surahAyahCounts[surah - 1]) {
      return;
    }
    unawaited(QuranTimingService.instance
        .ensureSurahLoaded(surah)
        .then((_) {}, onError: (_) {}));
    if (!kIsWeb) {
      unawaited(VerseAudioPlayer.ensureAyahDownloaded(surah, ayah)
          .then((_) {}, onError: (_) {}));
    }
  }

  @override
  void dispose() {
    unawaited(stop());
    unawaited(_player?.dispose());
    _player = null;
  }
}

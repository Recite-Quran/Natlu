import 'dart:async';
import 'dart:math';

/// State representation for an individual relay's reconnection lifecycle.
/// Directly inspired by noscall's ReconnectionState pattern with added jitter
/// to prevent thundering-herd spikes against public relays.
class MaglisReconnectionState {
  int attemptCount;
  DateTime lastAttemptTime;
  DateTime? lastSuccessTime;
  bool isReconnecting;

  MaglisReconnectionState({
    this.attemptCount = 0,
    DateTime? lastAttemptTime,
    this.lastSuccessTime,
    this.isReconnecting = false,
  }) : lastAttemptTime = lastAttemptTime ?? DateTime.now();

  void reset() {
    attemptCount = 0;
    lastAttemptTime = DateTime.now();
    isReconnecting = false;
  }

  void recordAttempt() {
    attemptCount++;
    lastAttemptTime = DateTime.now();
    isReconnecting = true;
  }

  void recordSuccess() {
    lastSuccessTime = DateTime.now();
    isReconnecting = false;
    attemptCount = 0;
  }

  /// Calculates exponential backoff delay with ±20% jitter.
  /// Base delay: 2 seconds, maximum capped at 45 seconds.
  Duration getBackoffDelay({
    int baseSeconds = 2,
    int maxSeconds = 45,
    bool withJitter = true,
  }) {
    if (attemptCount <= 0) return Duration(seconds: baseSeconds);

    final exponential = baseSeconds * (1 << (attemptCount - 1).clamp(0, 5));
    final clampedSeconds = exponential.clamp(baseSeconds, maxSeconds);

    if (!withJitter) {
      return Duration(seconds: clampedSeconds);
    }

    // Jitter: 0.8 to 1.2 x delay
    final jitterFactor = 0.8 + (Random().nextDouble() * 0.4);
    final jitteredMs = (clampedSeconds * 1000 * jitterFactor).round();
    return Duration(milliseconds: jitteredMs);
  }

  /// Determines whether reconnection should be scheduled based on attempt bounds and cooldown.
  bool shouldReconnect({
    int maxAttempts = 8,
    Duration cooldownPeriod = const Duration(seconds: 4),
  }) {
    if (attemptCount >= maxAttempts) {
      return false;
    }

    if (lastSuccessTime != null) {
      final timeSinceSuccess = DateTime.now().difference(lastSuccessTime!);
      if (timeSinceSuccess < cooldownPeriod) {
        return false;
      }
    }

    if (attemptCount > 0) {
      final timeSinceLastAttempt = DateTime.now().difference(lastAttemptTime);
      final backoffDelay = getBackoffDelay(withJitter: false);
      if (timeSinceLastAttempt < backoffDelay) {
        return false;
      }
    }

    return true;
  }
}

/// Schedular managing multi-relay reconnection backoffs (noscall pattern).
/// Prevents socket thrashing, handles network drops, and eliminates relay spamming.
class MaglisReconnectionScheduler {
  final Map<String, Timer> _timers = {};
  final Map<String, MaglisReconnectionState> _states = {};

  Iterable<MaglisReconnectionState> get states => _states.values;

  bool isRelayScheduled(String relay) => _timers.containsKey(relay);

  int getRelayAttemptCount(String relay) => _states[relay]?.attemptCount ?? 0;

  void resetAll() {
    for (final state in List<dynamic>.from(_states.values)) {
      state.reset();
    }
  }

  void resetRelay(String relay) {
    _states[relay]?.reset();
  }

  void recordSuccess(String relay) {
    _states[relay]?.recordSuccess();
  }

  void cancelRelay(String relay) {
    _timers[relay]?.cancel();
    _timers.remove(relay);
    _states.remove(relay);
  }

  void cancelAll() {
    for (final timer in List<Timer>.from(_timers.values)) {
      timer.cancel();
    }
    _timers.clear();
    _states.clear();
  }

  /// Schedules a reconnection attempt for [relay].
  /// Returns `true` if scheduled, `false` if skipped.
  bool schedule({
    required String relay,
    required bool hasNetworkConnectivity,
    required bool Function() isRelayManaged,
    required void Function() reconnect,
    int maxAttempts = 8,
  }) {
    if (!isRelayManaged()) {
      return false;
    }

    final state = _states[relay] ??= MaglisReconnectionState();

    if (state.isReconnecting) {
      return false;
    }

    if (!hasNetworkConnectivity) {
      return false;
    }

    if (!state.shouldReconnect(maxAttempts: maxAttempts)) {
      return false;
    }

    state.recordAttempt();
    final backoffDelay = state.getBackoffDelay();

    _timers[relay]?.cancel();
    _timers[relay] = Timer(backoffDelay, () {
      _timers.remove(relay);
      state.isReconnecting = false;

      if (isRelayManaged()) {
        reconnect();
      }
    });

    return true;
  }
}

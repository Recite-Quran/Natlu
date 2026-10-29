import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Centralized, high-performance haptics manager.
///
/// Gates all haptic calls strictly to physical mobile devices (Android / iOS).
/// Completely eliminates redundant platform-channel IPC roundtrips on Windows,
/// macOS, Linux, and Web desktop targets where hardware vibration does not exist.
abstract final class AppHaptics {
  static bool get _supportsHaptics =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  static void lightImpact() {
    if (_supportsHaptics) {
      HapticFeedback.lightImpact();
    }
  }

  static void mediumImpact() {
    if (_supportsHaptics) {
      HapticFeedback.mediumImpact();
    }
  }

  static void heavyImpact() {
    if (_supportsHaptics) {
      HapticFeedback.heavyImpact();
    }
  }

  static void selectionClick() {
    if (_supportsHaptics) {
      HapticFeedback.selectionClick();
    }
  }
}

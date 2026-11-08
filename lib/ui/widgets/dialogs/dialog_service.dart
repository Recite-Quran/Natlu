import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../../../core/highlighting_controller.dart';
import 'error_detail_dialog.dart';
import 'voice_search_dialog.dart';
import 'theme_selection_dialog.dart';
import 'model_download_dialog.dart';
import 'permission_dialog.dart';
import 'whats_new_dialog.dart';
import 'speed_selection_dialog.dart';
import 'maglis_entry_dialog.dart';
import 'maglis_explanation_dialog.dart';
import '../settings/settings_dialog.dart';

export 'permission_dialog.dart' show PermissionReason;
export 'package:recite_quran/recite_quran.dart' show VoiceSearchResult;

/// Centralized Dialog Service facade.
///
/// Prevents dialog collision, standardizes barrier dim styling,
/// and unifies modal presentations across the application.
abstract final class DialogService {
  /// Opens the Tajweed Phonetic Error breakdown bottom sheet.
  static void showTajweedError(
    BuildContext context, {
    required String word,
    required List<ReciterError> errors,
    int? surah,
    int? ayah,
    int? wordIndex,
  }) {
    ErrorDetailDialog.show(
      context,
      word: word,
      errors: errors,
      surah: surah,
      ayah: ayah,
      wordIndex: wordIndex,
    );
  }

  /// Displays the Voice Search modal dialog.
  static void showVoiceSearch(
    BuildContext context, {
    required VoidCallback onStop,
    ValueListenable<bool>? isLoading,
    ValueListenable<String>? asrTextNotifier,
    ValueListenable<VoiceSearchResult?>? searchResultNotifier,
    void Function(int surah, int ayah)? onSelectCandidate,
    ValueChanged<bool>? onHoldChanged,
  }) {
    VoiceSearchDialog.show(
      context,
      onStop: onStop,
      isLoading: isLoading,
      asrTextNotifier: asrTextNotifier,
      searchResultNotifier: searchResultNotifier,
      onSelectCandidate: onSelectCandidate,
      onHoldChanged: onHoldChanged,
    );
  }

  /// Opens the App Theme selection dialog.
  static Future<void> showThemeSelection(
    BuildContext context, {
    required VoidCallback onThemeSelected,
    bool barrierDismissible = false,
  }) {
    return showDialog<void>(
      context: context,
      barrierDismissible: barrierDismissible,
      builder: (ctx) => ThemeSelectionDialog(onThemeSelected: onThemeSelected),
    );
  }

  /// Displays the Sherpa-ONNX model download modal dialog.
  static Future<bool?> showModelDownload(BuildContext context) {
    return showDialog<bool>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => const ModelDownloadDialog(),
    );
  }

  /// Opens the Microphone permission prompt dialog.
  static Future<void> showPermission(
    BuildContext context, {
    required PermissionReason reason,
  }) {
    return showDialog<void>(
      context: context,
      builder: (ctx) => PermissionDialog(reason: reason),
    );
  }

  /// Displays the What's New changelog bottom sheet.
  static void showWhatsNew(BuildContext context) {
    WhatsNewDialog.show(context);
  }

  /// Opens the audio playback speed selection bottom sheet.
  static Future<void> showSpeedSelection(
    BuildContext context, {
    VoidCallback? onSpeedSelected,
  }) {
    return showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => SpeedSelectionDialog(
        onSpeedSelected: () {
          onSpeedSelected?.call();
          if (Navigator.of(ctx).canPop()) {
            Navigator.of(ctx).pop();
          }
        },
      ),
    );
  }

  /// Opens the app settings modal bottom sheet.
  static Future<void> showSettings(BuildContext context) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: 0.54),
      elevation: 0,
      builder: (_) => const SettingsDialog(),
    );
  }

  /// Opens the Maglis Room entry/hosting bottom sheet.
  static void showMaglisEntry(BuildContext context) {
    MaglisEntryDialog.show(context);
  }

  /// Displays the Maglis informational explanation dialog.
  static Future<void> showMaglisExplanation(BuildContext context) {
    return MaglisExplanationDialog.show(context);
  }
}


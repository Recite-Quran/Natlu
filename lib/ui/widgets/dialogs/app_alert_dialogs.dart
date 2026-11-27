import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import '../../../core/app_state.dart';
import 'dialog_base.dart';

// ══════════════════════════════════════════════════════════════════════════════
// 1. PERMISSION REASON & PROMPT DIALOG
// ══════════════════════════════════════════════════════════════════════════════

enum PermissionReason { tracking, voiceSearch }

/// Dialog prompting user to grant microphone permissions.
class PermissionDialog extends StatelessWidget {
  final PermissionReason reason;

  const PermissionDialog({
    super.key,
    required this.reason,
  });

  @override
  Widget build(BuildContext context) {
    final app = AppState.instance;
    final isAr = app.isArabic;

    final title = isAr ? 'إذن مطلوب' : 'Permission Required';
    final message = isAr
        ? (reason == PermissionReason.tracking
            ? 'نحتاج إلى صلاحية الميكروفون لتتبع التلاوة. يرجى تفعيلها من الإعدادات.'
            : 'نحتاج إلى صلاحية الميكروفون للبحث الصوتي. يرجى تفعيلها من الإعدادات.')
        : (reason == PermissionReason.tracking
            ? 'Microphone access is needed for recitation tracking. Please enable it in Settings.'
            : 'Microphone access is needed for Voice Search. Please enable it in Settings.');

    return AppDialog(
      heroIcon: const AppDialogHeroIcon(
        icon: Icons.mic_off_rounded,
      ),
      title: title,
      subtitle: message,
      primaryAction: AppDialogActionItem(
        label: isAr ? 'الإعدادات' : 'Settings',
        onPressed: () {
          Navigator.pop(context);
          openAppSettings();
        },
      ),
      secondaryAction: AppDialogActionItem(
        label: isAr ? 'إلغاء' : 'Cancel',
        onPressed: () => Navigator.pop(context),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// 2. MODEL DOWNLOAD PROMPT DIALOG
// ══════════════════════════════════════════════════════════════════════════════

/// Dialog asking the user before downloading the on-device speech model.
class ModelDownloadDialog extends StatelessWidget {
  const ModelDownloadDialog({super.key});

  @override
  Widget build(BuildContext context) {
    final bool isAr = AppState.instance.isArabic;

    return AppDialog(
      heroIcon: const AppDialogHeroIcon(icon: Icons.download_rounded),
      title: isAr ? 'تحميل نموذج التلاوة' : 'Download Recitation Model',
      subtitle: isAr
          ? 'يتطلب التتبع الصوتي تحميل نموذج الذكاء الاصطناعي لمرة واحدة (حوالي 56 ميجابايت). هل تريد التحميل الآن؟'
          : 'Voice recitation tracking requires a one-time AI model download (~56 MB). Download now?',
      primaryAction: AppDialogActionItem(
        label: isAr ? 'تحميل' : 'Download',
        onPressed: () => Navigator.pop(context, true),
      ),
      secondaryAction: AppDialogActionItem(
        label: isAr ? 'لاحقاً' : 'Later',
        onPressed: () => Navigator.pop(context, false),
      ),
    );
  }
}


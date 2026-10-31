import 'package:flutter/material.dart';
import '../../../state/app_state.dart';

/// Beautiful bilingual dialog asking for user consent before downloading the ~72MB AI speech model on Web.
class ModelDownloadDialog extends StatelessWidget {
  const ModelDownloadDialog({super.key});

  @override
  Widget build(BuildContext context) {
    final app = AppState.instance;
    return RepaintBoundary(
      child: ListenableBuilder(
        listenable: app,
        builder: (context, _) {
          final c = app.colors;
          final isAr = app.isArabic;
          final isDark = app.isDarkMode;

          final title = isAr ? 'تنزيل محرك الذكاء الاصطناعي' : 'Download AI Voice Model';
          final message = isAr
              ? 'يتطلب التتبع الصوتي والبحث تنزيل نموذج التعرف على الصوت (حوالي 72 ميجابايت) لمرة واحدة فقط ليعمل بدون إنترنت لاحقاً.'
              : 'Voice tracking requires downloading the speech model (~72MB) once to work offline.';

          return Dialog(
            backgroundColor: Colors.transparent,
            insetPadding: const EdgeInsets.symmetric(horizontal: 32),
            child: Container(
              decoration: BoxDecoration(
                color: c.surface,
                borderRadius: BorderRadius.circular(24),
                border: Border.all(
                  color: c.border.withValues(alpha: 0.25),
                  width: 1,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: isDark ? 0.35 : 0.10),
                    blurRadius: 16,
                    offset: const Offset(0, 6),
                  ),
                ],
              ),
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: c.primary.withValues(alpha: 0.10),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.cloud_download_rounded,
                      color: c.primary,
                      size: 36,
                    ),
                  ),
                  const SizedBox(height: 18),
                  Text(
                    title,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: c.text,
                      fontSize: 19,
                      fontWeight: FontWeight.bold,
                      letterSpacing: isAr ? 0.0 : -0.3,
                      height: isAr ? 1.3 : 1.2,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    message,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: c.muted,
                      fontSize: 14,
                      height: 1.5,
                    ),
                  ),
                  const SizedBox(height: 14),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: c.primary.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.data_usage_rounded, size: 16, color: c.primary),
                        const SizedBox(width: 6),
                        Text(
                          isAr ? 'حجم البيانات: ~72 ميجابايت' : 'Download size: ~72 MB',
                          style: TextStyle(
                            color: c.primary,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),
                  Row(
                    children: [
                      Expanded(
                        child: TextButton(
                          onPressed: () => Navigator.pop(context, false),
                          style: TextButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 13),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          child: Text(
                            isAr ? 'إلغاء' : 'Cancel',
                            style: TextStyle(
                              color: c.muted,
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: ElevatedButton(
                          onPressed: () => Navigator.pop(context, true),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: c.primary,
                            foregroundColor: Colors.white,
                            elevation: 0,
                            padding: const EdgeInsets.symmetric(vertical: 13),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          child: Text(
                            isAr ? 'موافق • تنزيل' : 'Download',
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

import 'package:flutter/material.dart';

import '../../services/prayer/prayer_session.dart';
import '../../services/recitation/recitation_event.dart';
import '../../state/app_state.dart';
import 'prayer_event_text.dart';

/// Shows prayer mode's state and its latest events above the recitation
/// controls; tap for the whole log.
class PrayerStatusCard extends StatelessWidget {
  const PrayerStatusCard({
    super.key,
    required this.session,
    required this.surahName,
    required this.onStop,
    required this.onClose,
  });

  final PrayerSession session;
  final String Function(int surah) surahName;
  final VoidCallback onStop;
  final VoidCallback onClose;

  void _showLog(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _PrayerLogSheet(session: session, surahName: surahName),
    );
  }

  @override
  Widget build(BuildContext context) {
    final app = AppState.instance;
    return ListenableBuilder(
      listenable: Listenable.merge([app, session]),
      builder: (context, _) {
        final c = app.colors;
        final ar = app.isArabic;
        final running = session.phase != PrayerPhase.idle;
        final latest = session.events.reversed.take(3).toList();
        return Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(18),
            onTap: () => _showLog(context),
            child: Container(
              padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
              decoration: BoxDecoration(
                color: c.surface,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: c.primary.withValues(alpha: 0.35)),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black
                        .withValues(alpha: app.isDarkMode ? 0.35 : 0.10),
                    blurRadius: 14,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Icon(Icons.mosque_rounded, size: 18, color: c.primary),
                      if (session.silent) ...[
                        const SizedBox(width: 4),
                        Tooltip(
                          message: ar ? 'صامت (تجربة)' : 'Silent (rehearsal)',
                          child: Icon(Icons.volume_off_rounded,
                              size: 16, color: c.textSecondary),
                        ),
                      ],
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '${prayerPhaseText(session.phase, ar)}'
                          '${session.position == null ? '' : ' · ${prayerPositionText(session.position, ar, surahName)}'}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: c.text,
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      TextButton(
                        onPressed: running ? onStop : onClose,
                        child: Text(
                          running
                              ? (ar ? 'إيقاف' : 'Stop')
                              : (ar ? 'إغلاق' : 'Close'),
                          style: TextStyle(color: c.primary),
                        ),
                      ),
                    ],
                  ),
                  for (final e in latest)
                    _EventLine(
                      event: e,
                      surahName: surahName,
                      silent: session.silent,
                      compact: true,
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _EventLine extends StatelessWidget {
  const _EventLine({
    required this.event,
    required this.surahName,
    required this.silent,
    this.compact = false,
  });

  final RecitationEvent event;
  final String Function(int surah) surahName;
  final bool silent;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final app = AppState.instance;
    final c = app.colors;
    final ar = app.isArabic;
    final t = describeRecitationEvent(event, ar, surahName, c.primary, c.gold,
        silent: silent);
    return Padding(
      padding: EdgeInsets.symmetric(vertical: compact ? 2 : 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(t.icon, size: 16, color: t.color),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  t.title,
                  maxLines: compact ? 1 : null,
                  overflow: compact ? TextOverflow.ellipsis : null,
                  style: TextStyle(color: c.text, fontSize: 12.5),
                ),
                if (t.words != null && t.words!.isNotEmpty)
                  Directionality(
                    textDirection: TextDirection.rtl,
                    child: Text(
                      t.words!,
                      style: TextStyle(
                        fontFamily: 'HafsSmart',
                        color: t.color,
                        fontSize: compact ? 17 : 21,
                        height: 1.5,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 6),
          Text(
            prayerClockText(event.at, ar),
            style: TextStyle(color: c.textSecondary, fontSize: 11),
          ),
        ],
      ),
    );
  }
}

class _PrayerLogSheet extends StatelessWidget {
  const _PrayerLogSheet({required this.session, required this.surahName});

  final PrayerSession session;
  final String Function(int surah) surahName;

  @override
  Widget build(BuildContext context) {
    final app = AppState.instance;
    return ListenableBuilder(
      listenable: session,
      builder: (context, _) {
        final c = app.colors;
        final ar = app.isArabic;
        final events = session.events.reversed.toList();
        final mistakes =
            events.where((e) => e.kind == RecitationEventKind.mistake).length;
        final prompts =
            events.where((e) => e.kind == RecitationEventKind.prompt).length;
        return Directionality(
          textDirection: ar ? TextDirection.rtl : TextDirection.ltr,
          child: Container(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height * 0.85,
            ),
            decoration: BoxDecoration(
              color: c.surface,
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(24)),
            ),
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
            child: SafeArea(
              top: false,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    ar ? 'سجل وضع الصلاة' : 'Prayer Mode Log',
                    style: TextStyle(
                      color: c.text,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    ar
                        ? 'تنبيهات: ${localizedNumber(mistakes, true)} · قراءات: ${localizedNumber(prompts, true)}'
                            '${session.silent ? ' (صامت)' : ''}'
                        : '${session.silent ? 'Would have beeped' : 'Beeped'} '
                            '$mistakes ${mistakes == 1 ? 'time' : 'times'} '
                            'and read $prompts '
                            '${prompts == 1 ? 'time' : 'times'}',
                    style: TextStyle(color: c.textSecondary, fontSize: 12.5),
                  ),
                  const SizedBox(height: 8),
                  Flexible(
                    child: ListView.separated(
                      shrinkWrap: true,
                      itemCount: events.length,
                      separatorBuilder: (_, __) => Divider(
                          height: 1, color: c.border.withValues(alpha: 0.4)),
                      itemBuilder: (_, i) => _EventLine(
                        event: events[i],
                        surahName: surahName,
                        silent: session.silent,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

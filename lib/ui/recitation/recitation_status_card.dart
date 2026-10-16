import 'package:flutter/material.dart';

import '../../services/recitation/recitation_event.dart';
import '../../services/recitation/recitation_session.dart';
import '../../state/app_state.dart';
import '../prayer/prayer_event_text.dart';
import 'auto_correct_sheet.dart' show autoCorrectIcon;

/// Shows prayer mode's state, or auto-correct's, and the latest events
/// above the recitation controls; tap for the whole log.
///
/// Auto-correct on its own shows only once it has something to say, and
/// can be put away until it has more.
class RecitationStatusCard extends StatefulWidget {
  const RecitationStatusCard({
    super.key,
    required this.session,
    required this.surahName,
    required this.onStop,
    required this.onClose,
  });

  final RecitationSession session;
  final String Function(int surah) surahName;

  /// Stops prayer mode (and recording).
  final VoidCallback onStop;

  /// Closes the log of a session that has ended.
  final VoidCallback onClose;

  @override
  State<RecitationStatusCard> createState() => _RecitationStatusCardState();
}

class _RecitationStatusCardState extends State<RecitationStatusCard> {
  /// How many events there were when auto-correct's card was put away.
  int _hiddenAt = 0;

  RecitationSession get session => widget.session;

  void _showLog(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) =>
          _RecitationLogSheet(session: session, surahName: widget.surahName),
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
        final prayer = session.prayer;
        final events = session.events;
        if (prayer == null && events.length <= _hiddenAt) {
          return const SizedBox.shrink();
        }
        final running = session.running;
        final silent = session.autoCorrect?.silent ?? true;
        final latest = events.reversed.take(3).toList();
        final where = session.position == null
            ? ''
            : ' · ${prayerPositionText(session.position, ar, widget.surahName)}';
        final title = prayer != null
            ? prayerPhaseText(prayer.phase, ar)
            : (ar ? 'التصحيح التلقائي' : 'Auto-correct');
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
                      Icon(
                          prayer != null
                              ? Icons.mosque_rounded
                              : autoCorrectIcon,
                          size: 18,
                          color: c.primary),
                      if (prayer != null && silent) ...[
                        const SizedBox(width: 4),
                        Tooltip(
                          message: ar
                              ? 'التصحيح التلقائي متوقف'
                              : 'Auto-correct off',
                          child: Icon(Icons.volume_off_rounded,
                              size: 16, color: c.textSecondary),
                        ),
                      ],
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '$title$where',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: c.text,
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      if (running && prayer == null)
                        IconButton(
                          onPressed: () =>
                              setState(() => _hiddenAt = events.length),
                          icon: const Icon(Icons.close_rounded, size: 18),
                          color: c.textSecondary,
                          tooltip: ar ? 'إخفاء' : 'Hide',
                          visualDensity: VisualDensity.compact,
                        )
                      else
                        TextButton(
                          onPressed: running ? widget.onStop : widget.onClose,
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
                      surahName: widget.surahName,
                      silent: silent,
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

class _RecitationLogSheet extends StatelessWidget {
  const _RecitationLogSheet({required this.session, required this.surahName});

  final RecitationSession session;
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
        final silent = session.autoCorrect?.silent ?? true;
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
                    session.prayer != null
                        ? (ar ? 'سجل وضع الصلاة' : 'Prayer Mode Log')
                        : (ar ? 'سجل التصحيح التلقائي' : 'Auto-correct Log'),
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
                            '${silent ? ' (صامت)' : ''}'
                        : '${silent ? 'Would have beeped' : 'Beeped'} '
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
                        silent: silent,
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

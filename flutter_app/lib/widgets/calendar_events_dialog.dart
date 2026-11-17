import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/models.dart';
import '../services/api_service.dart';
import '../services/calendar_service.dart';

/// Material Design 3 startup permission dialog asking the user to grant Calendar
/// access so same-day `"Call <Guest>"` events are created automatically when matches arrive.
class CalendarPermissionPromptDialog extends StatefulWidget {
  const CalendarPermissionPromptDialog({super.key});

  @override
  State<CalendarPermissionPromptDialog> createState() =>
      _CalendarPermissionPromptDialogState();
}

class _CalendarPermissionPromptDialogState
    extends State<CalendarPermissionPromptDialog> {
  bool _requesting = false;

  Future<void> _handleGrant() async {
    setState(() => _requesting = true);
    final granted = await CalendarService.instance.requestCalendarPermission();
    if (!mounted) return;
    Navigator.of(context).pop(granted);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          granted
              ? 'Calendar permission enabled — same-day guest call events will be created automatically when matches are found.'
              : 'Calendar permission was not granted. You can enable it anytime from the Calendar icon in the top bar.',
        ),
      ),
    );
  }

  Future<void> _handleNotNow() async {
    await CalendarService.instance.dismissPermissionPrompt();
    if (!mounted) return;
    Navigator.of(context).pop(false);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      icon: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: scheme.primaryContainer,
          shape: BoxShape.circle,
        ),
        child: Icon(
          Icons.event_available_rounded,
          color: scheme.onPrimaryContainer,
          size: 28,
        ),
      ),
      title: const Text(
        'Allow Calendar Access?',
        textAlign: TextAlign.center,
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Preston Motor Guest Scout would like permission to access your calendar so it can automatically schedule a same-day reminder to call your guest whenever a matching vehicle is found.',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.phone_in_talk_rounded,
                        size: 18,
                        color: scheme.primary,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Same-Day "Call Guest" Event',
                          style: Theme.of(context)
                              .textTheme
                              .labelLarge
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '• Includes guest phone number, latest notes, matched vehicle price & Preston dealership location\n• Scheduled strictly on that same day with a 15-minute reminder\n• Never sends calendar invites to customers',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                          height: 1.4,
                        ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _requesting ? null : _handleNotNow,
          child: const Text('Not Now'),
        ),
        FilledButton.icon(
          onPressed: _requesting ? null : _handleGrant,
          icon: _requesting
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.check_circle_outline_rounded, size: 18),
          label: const Text('Allow Calendar Access'),
        ),
      ],
    );
  }
}

/// Dialog accessible from the AppBar Calendar button showing permission status
/// and all automatically scheduled same-day `"Call <Guest>"` calendar events.
class CalendarEventsDialog extends StatelessWidget {
  final void Function(String guestId) onSelectGuest;

  const CalendarEventsDialog({
    super.key,
    required this.onSelectGuest,
  });

  String _formatEventWindow(String startIso, String endIso) {
    final s = DateTime.tryParse(startIso)?.toLocal();
    final e = DateTime.tryParse(endIso)?.toLocal();
    if (s == null) return startIso;
    final dayLabel = DateFormat('EEE, MMM d, y').format(s);
    final startLabel = DateFormat('h:mm a').format(s);
    if (e == null) return '$dayLabel • $startLabel';
    final endLabel = DateFormat('h:mm a').format(e);
    return '$dayLabel • $startLabel – $endLabel';
  }

  Future<void> _openGoogleCalendarTemplate(CalendarCallEvent item) async {
    if (item.calendarLink.trim().isNotEmpty) {
      final linkUri = Uri.tryParse(item.calendarLink.trim());
      if (linkUri != null) {
        await launchUrl(linkUri, mode: LaunchMode.externalApplication);
        return;
      }
    }
    final s = DateTime.tryParse(item.startAt)?.toUtc();
    final e = DateTime.tryParse(item.endAt)?.toUtc();
    String fmtUtc(DateTime dt) =>
        DateFormat("yyyyMMdd'T'HHmmss'Z'").format(dt.toUtc());
    final datesParam = (s != null && e != null) ? '${fmtUtc(s)}/${fmtUtc(e)}' : '';
    final uri = Uri.https('calendar.google.com', '/calendar/render', <String, String>{
      'action': 'TEMPLATE',
      'text': item.title,
      'details': item.description,
      'location': item.location,
      if (datesParam.isNotEmpty) 'dates': datesParam,
    });
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 580, maxHeight: 660),
        child: ListenableBuilder(
          listenable: CalendarService.instance,
          builder: (context, _) {
            final svc = CalendarService.instance;
            final granted = svc.permissionGranted;
            final events = svc.events;

            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 18, 12, 12),
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(9),
                        decoration: BoxDecoration(
                          color: scheme.primaryContainer,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Icon(
                          Icons.event_available_outlined,
                          color: scheme.onPrimaryContainer,
                          size: 22,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Same-Day Guest Call Calendar',
                              style: Theme.of(context)
                                  .textTheme
                                  .titleMedium
                                  ?.copyWith(fontWeight: FontWeight.w700),
                            ),
                            Text(
                              'Automatically schedules a same-day call event when a match is found',
                              style: Theme.of(context)
                                  .textTheme
                                  .bodySmall
                                  ?.copyWith(color: scheme.onSurfaceVariant),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        tooltip: 'Close',
                        onPressed: () => Navigator.of(context).pop(),
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                ),
                Divider(height: 1, color: scheme.outlineVariant),
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  child: Row(
                    children: [
                      Icon(
                        granted
                            ? Icons.verified_rounded
                            : Icons.warning_amber_rounded,
                        size: 18,
                        color: granted ? Colors.green.shade700 : scheme.error,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          granted
                              ? 'Calendar Permission Granted • Auto-scheduling active'
                              : 'Calendar Permission Required to auto-create same-day call events',
                          style:
                              Theme.of(context).textTheme.bodySmall?.copyWith(
                                    fontWeight: FontWeight.w600,
                                    color: granted
                                        ? scheme.onSurface
                                        : scheme.error,
                                  ),
                        ),
                      ),
                      if (!granted)
                        FilledButton.tonalIcon(
                          onPressed: () async {
                            final ok = await svc.requestCalendarPermission();
                            if (!context.mounted) return;
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                  ok
                                      ? 'Calendar permission granted! Same-day guest call events are now active.'
                                      : 'Calendar permission was not granted — check device settings if blocked.',
                                ),
                              ),
                            );
                          },
                          icon: const Icon(Icons.event_available_rounded,
                              size: 17),
                          label: const Text('Grant Permission'),
                        )
                      else if (events.isNotEmpty)
                        TextButton(
                          onPressed: () {
                            ApiService.clearCalendarEvents();
                          },
                          child: const Text('Clear Log'),
                        ),
                    ],
                  ),
                ),
                Divider(height: 1, color: scheme.outlineVariant),
                Flexible(
                  child: events.isEmpty
                      ? Padding(
                          padding: const EdgeInsets.all(32),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.calendar_today_outlined,
                                size: 44,
                                color: scheme.outline,
                              ),
                              const SizedBox(height: 12),
                              Text(
                                granted
                                    ? 'No same-day guest call events scheduled yet'
                                    : 'Allow Calendar Access to auto-schedule guest calls',
                                textAlign: TextAlign.center,
                                style: Theme.of(context)
                                    .textTheme
                                    .titleSmall
                                    ?.copyWith(fontWeight: FontWeight.w600),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                'Whenever a vehicle match is found for a guest, Preston Motor Guest Scout automatically creates a calendar event for that same day to call the guest with the matched vehicle details.',
                                textAlign: TextAlign.center,
                                style: Theme.of(context)
                                    .textTheme
                                    .bodySmall
                                    ?.copyWith(color: scheme.onSurfaceVariant),
                              ),
                            ],
                          ),
                        )
                      : ListView.separated(
                          shrinkWrap: true,
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          itemCount: events.length,
                          separatorBuilder: (_, _) => Divider(
                            height: 1,
                            indent: 16,
                            endIndent: 16,
                            color:
                                scheme.outlineVariant.withValues(alpha: 0.5),
                          ),
                          itemBuilder: (context, index) {
                            final item = events[index];
                            final timeWindow =
                                _formatEventWindow(item.startAt, item.endAt);
                            final phonePart = item.guestPhone.trim().isNotEmpty
                                ? ' • ${item.guestPhone.trim()}'
                                : '';

                            return ListTile(
                              leading: CircleAvatar(
                                backgroundColor: scheme.primaryContainer,
                                child: Icon(
                                  Icons.phone_callback_rounded,
                                  color: scheme.onPrimaryContainer,
                                  size: 19,
                                ),
                              ),
                              title: Text(
                                item.title,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              subtitle: Padding(
                                padding: const EdgeInsets.only(top: 4),
                                child: Text(
                                  '$timeWindow$phonePart\n${item.location}',
                                  style: Theme.of(context)
                                      .textTheme
                                      .bodySmall
                                      ?.copyWith(
                                        color: scheme.onSurfaceVariant,
                                        height: 1.35,
                                      ),
                                ),
                              ),
                              isThreeLine: true,
                              trailing: IconButton(
                                tooltip: 'Open in Calendar',
                                onPressed: () =>
                                    _openGoogleCalendarTemplate(item),
                                icon: const Icon(Icons.open_in_new_rounded,
                                    size: 19),
                              ),
                              onTap: () {
                                Navigator.of(context).pop();
                                onSelectGuest(item.guestId);
                              },
                            );
                          },
                        ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

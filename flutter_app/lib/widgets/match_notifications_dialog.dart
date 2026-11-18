import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';
import '../models/models.dart';
import '../services/api_service.dart';
import '../services/match_notification_service.dart';

class MatchNotificationsDialog extends StatelessWidget {
  final void Function(String guestId) onSelectGuest;

  const MatchNotificationsDialog({
    super.key,
    required this.onSelectGuest,
  });

  String _formatDateTime(String iso) {
    if (iso.isEmpty) return '';
    final dt = DateTime.tryParse(iso)?.toLocal();
    if (dt == null) return iso;
    return DateFormat('MMM d, y • h:mm a').format(dt);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final priceFmt = NumberFormat.currency(symbol: '\$', decimalDigits: 0);

    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 660),
        child: ListenableBuilder(
          listenable: MatchNotificationService.instance,
          builder: (context, _) {
            final svc = MatchNotificationService.instance;
            final alerts = svc.notifications;
            final unread = svc.unreadCount;
            final permGranted = svc.permissionGranted;

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
                          Icons.notifications_active_outlined,
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
                              'New Match Notifications',
                              style: Theme.of(context)
                                  .textTheme
                                  .titleMedium
                                  ?.copyWith(fontWeight: FontWeight.w700),
                            ),
                            Text(
                              'Full Android & OS alerts with guest name + vehicle model after initial search',
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
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Icon(
                            permGranted
                                ? Icons.verified_rounded
                                : Icons.notifications_paused_rounded,
                            size: 18,
                            color: permGranted
                                ? Colors.green.shade700
                                : scheme.error,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              permGranted
                                  ? 'Android & System Notifications Active (Heads-Up + Sound)'
                                  : 'System Notifications Disabled — allow notifications to receive match alerts',
                              style: Theme.of(context)
                                  .textTheme
                                  .bodySmall
                                  ?.copyWith(
                                    fontWeight: FontWeight.w600,
                                    color: permGranted
                                        ? scheme.onSurface
                                        : scheme.error,
                                  ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        alignment: WrapAlignment.spaceBetween,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: [
                              if (!permGranted)
                                FilledButton.tonalIcon(
                                  onPressed: () async {
                                    final ok = await svc.requestPermission();
                                    if (!context.mounted) return;
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                        content: Text(
                                          ok
                                              ? 'Android match notifications enabled!'
                                              : 'Notification permission blocked — tap "Android Settings" to allow.',
                                        ),
                                      ),
                                    );
                                  },
                                  icon: const Icon(
                                      Icons.notifications_active_rounded,
                                      size: 17),
                                  label: const Text('Enable OS Alerts'),
                                ),
                              if (!kIsWeb)
                                OutlinedButton.icon(
                                  onPressed: () {
                                    svc.openNotificationSettings();
                                  },
                                  icon: const Icon(Icons.tune_rounded, size: 16),
                                  label: const Text('Android Settings'),
                                ),
                              TextButton.icon(
                                onPressed: () async {
                                  final sent = await svc.sendTestNotification();
                                  if (!context.mounted) return;
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text(
                                        sent
                                            ? 'Sent test Android notification: "Sample Guest - Match Found - Ford Bronco"'
                                            : 'Could not post notification — enable notifications in Android Settings.',
                                      ),
                                    ),
                                  );
                                },
                                icon: const Icon(Icons.send_to_mobile_rounded,
                                    size: 16),
                                label: const Text('Test Alert'),
                              ),
                            ],
                          ),
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (unread > 0)
                                TextButton(
                                  onPressed: () {
                                    ApiService.markAllNotificationsRead();
                                  },
                                  child: const Text('Mark All Read'),
                                ),
                              if (alerts.isNotEmpty)
                                TextButton(
                                  onPressed: () {
                                    ApiService.clearNotifications();
                                  },
                                  child: const Text('Clear'),
                                ),
                            ],
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                Divider(height: 1, color: scheme.outlineVariant),
                Flexible(
                  child: alerts.isEmpty
                      ? Padding(
                          padding: const EdgeInsets.all(32),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.notifications_none_rounded,
                                size: 44,
                                color: scheme.outline,
                              ),
                              const SizedBox(height: 12),
                              Text(
                                'No post-initial-search match alerts yet',
                                textAlign: TextAlign.center,
                                style: Theme.of(context)
                                    .textTheme
                                    .titleSmall
                                    ?.copyWith(fontWeight: FontWeight.w600),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                'Initial intake searches are silent. Whenever a new matching vehicle is found for a guest after their first initial search (during 7:30 AM, 2:00 PM, background, or manual scans), a full Android notification is posted with the guest\'s name and vehicle model:\n"Guest Name - Match Found - Vehicle Model"',
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
                          itemCount: alerts.length,
                          separatorBuilder: (_, _) => Divider(
                            height: 1,
                            indent: 16,
                            endIndent: 16,
                            color:
                                scheme.outlineVariant.withValues(alpha: 0.5),
                          ),
                          itemBuilder: (context, index) {
                            final MatchAlertNotification item = alerts[index];
                            final subtitleParts = <String>[];
                            if (item.guestName.trim().isNotEmpty &&
                                item.vehicleModel.trim().isNotEmpty) {
                              subtitleParts.add(
                                  '${item.guestName.trim()} • ${item.vehicleModel.trim()}');
                            }
                            if (item.price != null && item.price! > 0) {
                              subtitleParts.add(priceFmt.format(item.price));
                            }
                            if (item.location.isNotEmpty) {
                              subtitleParts.add(item.location);
                            }
                            final whenStr = _formatDateTime(item.createdAt);
                            if (whenStr.isNotEmpty) {
                              subtitleParts.add(whenStr);
                            }

                            return ListTile(
                              tileColor: item.read
                                  ? null
                                  : scheme.primaryContainer
                                      .withValues(alpha: 0.25),
                              leading: CircleAvatar(
                                backgroundColor: item.read
                                    ? scheme.surfaceContainerHighest
                                    : scheme.primaryContainer,
                                child: Icon(
                                  Icons.directions_car_filled_outlined,
                                  color: item.read
                                      ? scheme.onSurfaceVariant
                                      : scheme.onPrimaryContainer,
                                  size: 20,
                                ),
                              ),
                              title: Text(
                                item.message,
                                style: TextStyle(
                                  fontWeight: item.read
                                      ? FontWeight.w500
                                      : FontWeight.w700,
                                ),
                              ),
                              subtitle: subtitleParts.isEmpty
                                  ? null
                                  : Padding(
                                      padding: const EdgeInsets.only(top: 3),
                                      child: Text(
                                        subtitleParts.join(' • '),
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodySmall
                                            ?.copyWith(
                                              color: scheme.onSurfaceVariant,
                                            ),
                                      ),
                                    ),
                              trailing:
                                  const Icon(Icons.chevron_right_rounded),
                              onTap: () {
                                ApiService.markAllNotificationsRead();
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

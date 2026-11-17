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
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 640),
        child: ListenableBuilder(
          listenable: MatchNotificationService.instance,
          builder: (context, _) {
            final svc = MatchNotificationService.instance;
            final alerts = svc.notifications;
            final unread = svc.unreadCount;

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
                              'Alerts sent after initial search when new matches arrive',
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
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    alignment: WrapAlignment.spaceBetween,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      TextButton.icon(
                        onPressed: () async {
                          final ok = await svc.requestPermission();
                          if (!context.mounted) return;
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(
                                ok
                                    ? 'System notifications are enabled.'
                                    : 'Notification permission requested — check device/browser notification settings if blocked.',
                              ),
                            ),
                          );
                        },
                        icon: const Icon(Icons.tune_rounded, size: 17),
                        label: const Text('Enable OS Alerts'),
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
                                'Initial intake searches are silent. Whenever a new matching vehicle arrives on a subsequent 7:30 AM, 2:00 PM, or manual search, you will receive a notification saying:\n"Client Name - Match Found - Model"',
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
                            color: scheme.outlineVariant.withValues(alpha: 0.5),
                          ),
                          itemBuilder: (context, index) {
                            final MatchAlertNotification item = alerts[index];
                            final subtitleParts = <String>[];
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

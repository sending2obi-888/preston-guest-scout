import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import '../models/models.dart';
import 'match_notification_web.dart';

/// Cross-platform OS notification dispatcher and in-app notification center state
/// for post-initial-search vehicle matches (`"Client Name - Match Found - <Model>"`).
class MatchNotificationService extends ChangeNotifier {
  MatchNotificationService._();
  static final MatchNotificationService instance = MatchNotificationService._();

  static const MethodChannel _channel =
      MethodChannel('com.prestonmotor.scout/notifications');

  bool _initialized = false;
  List<MatchAlertNotification> _notifications = [];
  final Set<String> _deliveredIds = <String>{};

  /// Optional callback invoked when a brand-new post-initial-search match alert arrives
  /// while the app is open so MainShellScreen can display an immediate banner.
  void Function(MatchAlertNotification alert)? onForegroundBanner;

  List<MatchAlertNotification> get notifications =>
      List<MatchAlertNotification>.unmodifiable(_notifications);

  int get unreadCount => _notifications.where((n) => !n.read).length;

  Future<void> initialize({
    required void Function(String guestId) onTapNotification,
  }) async {
    if (_initialized) return;
    _initialized = true;

    if (kIsWeb) {
      registerBrowserNotificationClickListener(onTapNotification);
      try {
        await requestBrowserNotificationPermission();
      } catch (_) {}
      return;
    }

    try {
      await _channel.invokeMethod<bool>('requestNotificationPermission');
    } catch (_) {}
  }

  /// Requests OS notification permission explicitly (e.g., from the Notification Center dialog).
  Future<bool> requestPermission() async {
    if (kIsWeb) {
      final perm = await requestBrowserNotificationPermission();
      return perm == 'granted';
    }
    try {
      final granted =
          await _channel.invokeMethod<bool>('requestNotificationPermission');
      return granted ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Hydrates persisted local notifications on app startup without re-posting old alerts
  /// to the OS notification shade.
  void hydratePersistedNotifications(List<MatchAlertNotification> stored) {
    final byId = <String, MatchAlertNotification>{};
    for (final n in stored) {
      if (n.id.isEmpty) continue;
      byId[n.id] = n;
      _deliveredIds.add(n.id);
    }
    final list = byId.values.toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    _notifications = list;
    notifyListeners();
  }

  /// Synchronizes notifications from the Node.js backend (Web / API mode) and dispatches
  /// browser OS notifications for any newly arrived unread match alerts.
  Future<void> syncFromServerList(
    List<MatchAlertNotification> serverAlerts,
  ) async {
    final freshToDispatch = <MatchAlertNotification>[];
    for (final alert in serverAlerts) {
      if (alert.id.isEmpty) continue;
      if (!_deliveredIds.contains(alert.id)) {
        _deliveredIds.add(alert.id);
        if (!alert.read) {
          freshToDispatch.add(alert);
        }
      }
    }

    final sorted = [...serverAlerts]
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    _notifications = sorted;
    notifyListeners();

    int posted = 0;
    for (final alert in freshToDispatch) {
      if (posted < 8) {
        await _postSystemNotification(alert);
        posted++;
      }
    }
    if (freshToDispatch.isNotEmpty) {
      onForegroundBanner?.call(freshToDispatch.first);
    }
  }

  /// Dispatches newly discovered post-initial-search match alerts to the OS notification bar
  /// (Android/Googlebook NotificationManager or Web Notification API) + in-app center.
  Future<void> dispatchNewNotifications(
    List<MatchAlertNotification> alerts,
  ) async {
    if (alerts.isEmpty) return;

    final undelivered = <MatchAlertNotification>[];
    final existingById = <String, MatchAlertNotification>{
      for (final n in _notifications) n.id: n,
    };

    for (final alert in alerts) {
      if (alert.id.isEmpty) continue;
      existingById[alert.id] = alert;
      if (_deliveredIds.add(alert.id)) {
        undelivered.add(alert);
      }
    }

    final merged = existingById.values.toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    _notifications = merged;
    notifyListeners();

    int posted = 0;
    for (final alert in undelivered) {
      if (posted < 8) {
        await _postSystemNotification(alert);
        posted++;
      }
    }

    if (undelivered.isNotEmpty) {
      onForegroundBanner?.call(undelivered.first);
    }
  }

  void markAllReadLocally() {
    _notifications = _notifications
        .map((n) => n.read ? n : n.copyWith(read: true))
        .toList();
    notifyListeners();
  }

  void clearAllLocally() {
    _notifications = [];
    notifyListeners();
  }

  String _formatSubtitle(MatchAlertNotification alert) {
    final parts = <String>[];
    if (alert.price != null && alert.price! > 0) {
      final fmt = NumberFormat.currency(symbol: '\$', decimalDigits: 0);
      parts.add(fmt.format(alert.price));
    }
    if (alert.location.trim().isNotEmpty) {
      parts.add(alert.location.trim());
    }
    if (parts.isEmpty) {
      return '${alert.message} — Tap to view vehicle match';
    }
    return '${parts.join(' • ')} — Tap to view vehicle match';
  }

  Future<void> _postSystemNotification(MatchAlertNotification alert) async {
    final title = alert.message;
    final body = _formatSubtitle(alert);

    if (kIsWeb) {
      showBrowserMatchNotification(
        title: title,
        body: body,
        tag: alert.id,
        guestId: alert.guestId,
      );
      return;
    }

    final notifId = alert.id.hashCode & 0x7fffffff;
    try {
      await _channel.invokeMethod<bool>('showMatchNotification', {
        'notifId': notifId,
        'guestId': alert.guestId,
        'title': title,
        'body': body,
      });
    } catch (_) {}
  }

  void resetForTest() {
    _initialized = false;
    _notifications = [];
    _deliveredIds.clear();
    onForegroundBanner = null;
  }
}

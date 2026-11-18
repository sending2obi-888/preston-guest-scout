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
  bool _permissionGranted = false;
  List<MatchAlertNotification> _notifications = [];
  final Set<String> _deliveredIds = <String>{};

  /// Optional callback invoked when a brand-new post-initial-search match alert arrives
  /// while the app is open so MainShellScreen can display an immediate banner.
  void Function(MatchAlertNotification alert)? onForegroundBanner;

  bool get permissionGranted => _permissionGranted;

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
        final perm = await requestBrowserNotificationPermission();
        _permissionGranted = perm == 'granted';
      } catch (_) {}
      notifyListeners();
      return;
    }

    _channel.setMethodCallHandler(_handleNativeMethodCall);

    try {
      final alreadyEnabled =
          await _channel.invokeMethod<bool>('areNotificationsEnabled') ?? false;
      if (alreadyEnabled) {
        _permissionGranted = true;
      } else {
        final granted =
            await _channel.invokeMethod<bool>('requestNotificationPermission') ??
                false;
        _permissionGranted = granted;
      }
    } catch (_) {}
    notifyListeners();
  }

  Future<dynamic> _handleNativeMethodCall(MethodCall call) async {
    if (call.method == 'onNotificationPermissionChanged') {
      final enabled = call.arguments == true;
      if (_permissionGranted != enabled) {
        _permissionGranted = enabled;
        notifyListeners();
      }
    }
    return null;
  }

  /// Refreshes current Android / browser notification permission state.
  Future<bool> refreshPermissionStatus() async {
    if (kIsWeb) {
      return _permissionGranted;
    }
    try {
      final enabled =
          await _channel.invokeMethod<bool>('areNotificationsEnabled') ?? false;
      if (_permissionGranted != enabled) {
        _permissionGranted = enabled;
        notifyListeners();
      }
      return enabled;
    } catch (_) {
      return _permissionGranted;
    }
  }

  /// Requests OS notification permission explicitly (e.g., from the Notification Center dialog).
  Future<bool> requestPermission() async {
    if (kIsWeb) {
      final perm = await requestBrowserNotificationPermission();
      _permissionGranted = perm == 'granted';
      notifyListeners();
      return _permissionGranted;
    }
    try {
      final granted =
          await _channel.invokeMethod<bool>('requestNotificationPermission') ??
              false;
      _permissionGranted = granted;
      notifyListeners();
      return granted;
    } catch (_) {
      return false;
    }
  }

  /// Opens Android's system App Notification Settings screen for Preston Motor Guest Scout.
  Future<bool> openNotificationSettings() async {
    if (kIsWeb) return false;
    try {
      final opened =
          await _channel.invokeMethod<bool>('openNotificationSettings') ??
              false;
      return opened;
    } catch (_) {
      return false;
    }
  }

  /// Posts a live test notification so the user can verify full Android heads-up alerts
  /// (with guest name & vehicle model) immediately on their device.
  Future<bool> sendTestNotification({
    String guestName = 'Sample Guest',
    String vehicleModel = 'Ford Bronco',
  }) async {
    if (!_permissionGranted) {
      await requestPermission();
    }
    final title = '$guestName - Match Found - $vehicleModel';
    const body =
        'New Ford Bronco found for Sample Guest • \$45,990 • Boulevard Ford of Millsboro';
    if (kIsWeb) {
      showBrowserMatchNotification(
        title: title,
        body: body,
        tag: 'test-match-alert',
        guestId: '',
      );
      return true;
    }
    try {
      final ok = await _channel.invokeMethod<bool>('showMatchNotification', {
        'notifId': DateTime.now().millisecondsSinceEpoch & 0x7fffffff,
        'guestId': '',
        'guestName': guestName,
        'guestPhone': '',
        'vehicleModel': vehicleModel,
        'vehicleTitle': '2026 $vehicleModel Big Bend 4WD',
        'price': 45990.0,
        'location': 'Boulevard Ford of Millsboro',
        'title': title,
        'body': body,
      });
      return ok ?? false;
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
  /// OS notifications for any newly arrived unread match alerts.
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

  /// Dispatches newly discovered post-initial-search match alerts to the Android
  /// NotificationManager (or Web Notification API) + in-app notification center.
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
    if (alert.guestName.trim().isNotEmpty &&
        alert.vehicleModel.trim().isNotEmpty) {
      parts.add('New ${alert.vehicleModel.trim()} found for ${alert.guestName.trim()}');
    }
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
    return parts.join(' • ');
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
      final posted = await _channel.invokeMethod<bool>('showMatchNotification', {
        'notifId': notifId,
        'guestId': alert.guestId,
        'guestName': alert.guestName,
        'guestPhone': alert.guestPhone,
        'vehicleModel': alert.vehicleModel,
        'vehicleTitle': alert.vehicleTitle,
        'price': alert.price,
        'location': alert.location,
        'title': title,
        'body': body,
      });
      if (posted == true && !_permissionGranted) {
        _permissionGranted = true;
        notifyListeners();
      }
    } catch (_) {}
  }

  void resetForTest() {
    _initialized = false;
    _permissionGranted = false;
    _notifications = [];
    _deliveredIds.clear();
    onForegroundBanner = null;
  }
}

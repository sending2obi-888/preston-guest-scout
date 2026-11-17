Future<String> requestBrowserNotificationPermission() async => 'unsupported';

bool showBrowserMatchNotification({
  required String title,
  required String body,
  required String tag,
  required String guestId,
}) =>
    false;

void registerBrowserNotificationClickListener(
  void Function(String guestId) onTap,
) {}

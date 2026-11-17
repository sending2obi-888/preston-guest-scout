import 'dart:js_interop';

@JS('prestonRequestNotificationPermission')
external JSPromise<JSString> _prestonRequestNotificationPermission();

@JS('prestonShowBrowserNotification')
external JSBoolean _prestonShowBrowserNotification(
  JSString title,
  JSString body,
  JSString tag,
  JSString guestId,
);

@JS('prestonRegisterNotificationClickListener')
external void _prestonRegisterNotificationClickListener(JSFunction callback);

Future<String> requestBrowserNotificationPermission() async {
  try {
    final perm = await _prestonRequestNotificationPermission().toDart;
    return perm.toDart;
  } catch (_) {
    return 'default';
  }
}

bool showBrowserMatchNotification({
  required String title,
  required String body,
  required String tag,
  required String guestId,
}) {
  try {
    return _prestonShowBrowserNotification(
      title.toJS,
      body.toJS,
      tag.toJS,
      guestId.toJS,
    ).toDart;
  } catch (_) {
    return false;
  }
}

void registerBrowserNotificationClickListener(
  void Function(String guestId) onTap,
) {
  try {
    void jsHandler(JSString jsGuestId) {
      final id = jsGuestId.toDart;
      if (id.isNotEmpty) {
        onTap(id);
      }
    }

    _prestonRegisterNotificationClickListener(jsHandler.toJS);
  } catch (_) {}
}

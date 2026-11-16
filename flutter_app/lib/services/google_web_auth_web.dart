import 'dart:convert';
import 'dart:js_interop';

@JS('prestonGoogleWebSignIn')
external JSPromise<JSString> _prestonGoogleWebSignIn(
  JSString clientId,
  JSString driveScope,
);

@JS('prestonReadSavedWebSession')
external JSString _prestonReadSavedWebSession();

@JS('prestonClearSavedWebSession')
external void _prestonClearSavedWebSession();

@JS('prestonRegisterVisibilityListener')
external void _prestonRegisterVisibilityListener(JSFunction callback);

Future<Map<String, dynamic>> signInWithGoogleWebGis({
  required String clientId,
  required String driveScope,
}) async {
  try {
    final jsRes = await _prestonGoogleWebSignIn(
      clientId.toJS,
      driveScope.toJS,
    ).toDart;
    final raw = jsRes.toDart;
    if (raw.isEmpty) {
      return <String, dynamic>{'signedIn': false};
    }
    return Map<String, dynamic>.from(jsonDecode(raw) as Map);
  } catch (e) {
    return <String, dynamic>{
      'signedIn': false,
      'error': e.toString(),
    };
  }
}

Map<String, dynamic>? readSavedGoogleWebSession() {
  try {
    final raw = _prestonReadSavedWebSession().toDart;
    if (raw.trim().isEmpty) return null;
    final decoded = Map<String, dynamic>.from(jsonDecode(raw) as Map);
    final exp = (decoded['expiresAtMs'] as num?)?.toInt() ?? 0;
    if (exp > 0 && DateTime.now().millisecondsSinceEpoch >= exp) {
      _prestonClearSavedWebSession();
      return null;
    }
    return decoded;
  } catch (_) {
    return null;
  }
}

void clearSavedGoogleWebSession() {
  try {
    _prestonClearSavedWebSession();
  } catch (_) {}
}

void registerWebAppReopenListener(void Function() onReopen) {
  try {
    _prestonRegisterVisibilityListener(onReopen.toJS);
  } catch (_) {}
}

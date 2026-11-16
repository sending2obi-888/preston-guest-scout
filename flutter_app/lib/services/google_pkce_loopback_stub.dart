Future<Map<String, dynamic>> signInWithBrowserLoopbackPkce({
  required String clientId,
  String clientSecret = '',
  required String driveScope,
  String? loginHint,
}) async {
  return <String, dynamic>{
    'signedIn': false,
    'error': 'Loopback PKCE is only used on native devices.',
  };
}

Future<Map<String, dynamic>> signInWithGoogleDeviceFlow({
  required String clientId,
  String clientSecret = '',
  required String driveScope,
  required void Function(String userCode, String verificationUrl) onCodeIssued,
  required bool Function() isCanceled,
}) async {
  return <String, dynamic>{
    'signedIn': false,
    'unsupportedClient': true,
    'error': 'Device flow is only used on native devices.',
  };
}

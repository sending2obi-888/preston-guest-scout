Future<Map<String, dynamic>> signInWithBrowserLoopbackPkce({
  required String clientId,
  String clientSecret = '',
  required String driveScope,
}) async {
  return <String, dynamic>{
    'signedIn': false,
    'error': 'Loopback PKCE is only used on native devices.',
  };
}

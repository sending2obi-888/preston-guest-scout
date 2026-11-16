Future<Map<String, dynamic>> signInWithGoogleWebGis({
  required String clientId,
  required String driveScope,
}) async {
  return <String, dynamic>{
    'signedIn': false,
    'error': 'Web GIS SSO is only used on Flutter Web.',
  };
}

Map<String, dynamic>? readSavedGoogleWebSession() => null;

void clearSavedGoogleWebSession() {}

void registerWebAppReopenListener(void Function() onReopen) {}

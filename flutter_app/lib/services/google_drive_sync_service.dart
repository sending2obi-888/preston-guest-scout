import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'api_service.dart';
import 'google_pkce_loopback.dart';
import 'google_web_auth.dart';
import 'local_engine.dart';

/// Manages Google Single Sign-On (SSO) and automatic multi-device Google Drive sync
/// (`preston_guest_scout_cloud_sync.json`) across Android, Googlebook, and Web.
class GoogleDriveSyncService extends ChangeNotifier {
  GoogleDriveSyncService._();
  static final GoogleDriveSyncService instance = GoogleDriveSyncService._();

  static const MethodChannel _authChannel =
      MethodChannel('com.prestonmotor.scout/google_auth');

  static const String driveSyncFileName = 'preston_guest_scout_cloud_sync.json';
  static const String defaultDriveScope = 'https://www.googleapis.com/auth/drive';

  bool _initialized = false;
  bool _isSigningIn = false;
  bool _isSyncing = false;

  bool _isSignedIn = false;
  String _userEmail = '';
  String _userDisplayName = '';
  String _userPhotoUrl = '';
  String _accessToken = '';
  String _refreshToken = '';
  int _expiresAtMs = 0;
  String _authMethod = ''; // native_google_sso | oauth_pkce | web_gis_sso | connected_drive

  bool _connectedDriveAvailable = false;
  String _driveFileId = '';
  String _customOAuthClientId = '';
  String _customOAuthClientSecret = '';
  String _signingPackageName = 'com.prestonmotor.preston_guest_scout';
  String _signingSha1 =
      'D3:F4:84:4D:1F:42:5F:3A:89:F7:DE:13:A3:31:89:05:00:93:BC:8C';

  DateTime? _lastQueriedAt;
  DateTime? _lastSavedAt;
  String? _lastError;

  Timer? _autoSaveDebounce;
  Future<bool>? _syncInFlight;
  final Set<VoidCallback> _onCloudMergedCallbacks = <VoidCallback>{};

  bool get isSigningIn => _isSigningIn;
  bool get isSyncing => _isSyncing;
  bool get isSignedIn => _isSignedIn;
  String get userEmail => _userEmail;
  String get userDisplayName => _userDisplayName;
  String get userPhotoUrl => _userPhotoUrl;
  String get accessToken => _accessToken;
  String get authMethod => _authMethod;
  bool get connectedDriveAvailable => _connectedDriveAvailable;
  String get driveFileId => _driveFileId;
  String get customOAuthClientId => _customOAuthClientId;
  String get customOAuthClientSecret => _customOAuthClientSecret;
  String get signingPackageName => _signingPackageName;
  String get signingSha1 => _signingSha1;
  DateTime? get lastQueriedAt => _lastQueriedAt;
  DateTime? get lastSavedAt => _lastSavedAt;
  String? get lastError => _lastError;

  void addCloudMergeListener(VoidCallback cb) =>
      _onCloudMergedCallbacks.add(cb);

  void removeCloudMergeListener(VoidCallback cb) =>
      _onCloudMergedCallbacks.remove(cb);

  void _notifyCloudMerged() {
    for (final cb in [..._onCloudMergedCallbacks]) {
      try {
        cb();
      } catch (_) {}
    }
  }

  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;

    LocalScoutEngine.onDataMutatedForCloudSave = scheduleAutoSave;

    if (kIsWeb) {
      final savedWeb = readSavedGoogleWebSession();
      if (savedWeb != null && savedWeb['signedIn'] == true) {
        _applySessionMap(savedWeb);
      }
      await _refreshWebBackendDriveStatus();
      registerWebAppReopenListener(() {
        queryDriveOnAppOpen();
      });
      return;
    }

    // Native Android / Googlebook initialization
    try {
      final info = await _authChannel
          .invokeMapMethod<String, dynamic>('getSigningInfo');
      if (info != null) {
        final pkg = info['packageName']?.toString() ?? '';
        final sha = info['sha1']?.toString() ?? '';
        if (pkg.isNotEmpty) _signingPackageName = pkg;
        if (sha.isNotEmpty) _signingSha1 = sha;
      }
    } catch (_) {}

    final localCfg = await LocalScoutEngine.getLocalAuthConfig();
    _customOAuthClientId = localCfg['googleOAuthClientId']?.toString() ?? '';
    _customOAuthClientSecret =
        localCfg['googleOAuthClientSecret']?.toString() ?? '';
    _driveFileId = localCfg['driveSyncFileId']?.toString() ?? '';

    final savedSession = localCfg['session'];
    if (savedSession is Map && savedSession['signedIn'] == true) {
      _applySessionMap(Map<String, dynamic>.from(savedSession));
    }

    // Attempt silent session refresh on startup
    await _restoreOrRefreshNativeSession(invalidateToken: null);
  }

  Future<void> _refreshWebBackendDriveStatus() async {
    try {
      final res = await http
          .get(Uri.parse('${ApiService.baseUrl}/api/drive-sync/status'))
          .timeout(const Duration(seconds: 10));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        _connectedDriveAvailable = data['connectedDriveAvailable'] == true;
        final fid = data['fileId']?.toString() ?? '';
        if (fid.isNotEmpty) _driveFileId = fid;
        final cid = data['googleWebClientId']?.toString() ?? '';
        if (_customOAuthClientId.isEmpty && cid.isNotEmpty) {
          _customOAuthClientId = cid;
        }
        final ls = data['lastSyncedAt']?.toString() ?? '';
        if (ls.isNotEmpty) _lastQueriedAt = DateTime.tryParse(ls);
        final lp = data['lastPushedAt']?.toString() ?? '';
        if (lp.isNotEmpty) _lastSavedAt = DateTime.tryParse(lp);

        // If connected workspace Google Drive is authenticated and no manual GIS override is active
        if (_connectedDriveAvailable && !_isSignedIn) {
          _isSignedIn = true;
          _authMethod = 'connected_drive';
          _userEmail = data['connectedAccountEmail']?.toString() ??
              'Connected Google Account';
          _userDisplayName = data['connectedAccountName']?.toString() ??
              'Google Drive Synced';
          _userPhotoUrl = data['connectedAccountPhotoUrl']?.toString() ?? '';
        }
        notifyListeners();
      }
    } catch (_) {}
  }

  void _applySessionMap(Map<String, dynamic> map) {
    _isSignedIn = map['signedIn'] == true;
    _userEmail = map['email']?.toString() ?? '';
    _userDisplayName = map['displayName']?.toString() ??
        (_userEmail.isNotEmpty ? _userEmail : 'Google Account');
    _userPhotoUrl = map['photoUrl']?.toString() ?? '';
    _accessToken = map['accessToken']?.toString() ?? '';
    if ((map['refreshToken']?.toString() ?? '').isNotEmpty) {
      _refreshToken = map['refreshToken'].toString();
    }
    _expiresAtMs = (map['expiresAtMs'] as num?)?.toInt() ?? 0;
    _authMethod = map['authMethod']?.toString() ?? 'native_google_sso';
    ApiService.setAuthBearerToken(_accessToken);
    notifyListeners();
  }

  Future<void> saveOAuthClientConfig({
    required String clientId,
    String clientSecret = '',
  }) async {
    _customOAuthClientId = clientId.trim();
    _customOAuthClientSecret = clientSecret.trim();
    if (kIsWeb) {
      await ApiService.updateSettings(
        googleOAuthClientId: _customOAuthClientId,
      );
    } else {
      await LocalScoutEngine.saveLocalAuthConfig(
        googleOAuthClientId: _customOAuthClientId,
        googleOAuthClientSecret: _customOAuthClientSecret,
      );
    }
    notifyListeners();
  }

  /// Launches interactive Google Single Sign-On (Native OS Google Sign-In on Android/Googlebook,
  /// OAuth 2.0 PKCE Browser Loopback fallback, or Google Identity Services on Web).
  Future<bool> signInWithGoogle({bool preferBrowserPkce = false}) async {
    await initialize();
    if (_isSigningIn) return false;

    _isSigningIn = true;
    _lastError = null;
    notifyListeners();

    try {
      if (kIsWeb) {
        if (_customOAuthClientId.trim().isNotEmpty) {
          final webRes = await signInWithGoogleWebGis(
            clientId: _customOAuthClientId.trim(),
            driveScope: defaultDriveScope,
          );
          if (webRes['signedIn'] == true) {
            _applySessionMap(webRes);
            await queryAndSyncDrive(pushAfterMerge: true);
            return true;
          }
          _lastError =
              webRes['error']?.toString() ?? 'Google Sign-In was canceled.';
          return false;
        }

        await _refreshWebBackendDriveStatus();
        if (_connectedDriveAvailable) {
          _isSignedIn = true;
          _authMethod = 'connected_drive';
          await queryAndSyncDrive(pushAfterMerge: true);
          return true;
        }

        _lastError =
            'Enter a Web Google OAuth Client ID below to sign in with Google in this browser.';
        return false;
      }

      // Native Android / Googlebook SSO
      if (!preferBrowserPkce) {
        try {
          final nativeRes = await _authChannel
              .invokeMapMethod<String, dynamic>('signInWithGoogle', {
            'driveScope': defaultDriveScope,
            'webClientId': _customOAuthClientId.trim().isNotEmpty &&
                    _customOAuthClientId.contains('.apps.googleusercontent.com')
                ? _customOAuthClientId.trim()
                : null,
          });
          if (nativeRes != null && nativeRes['signedIn'] == true) {
            _applySessionMap(nativeRes);
            await _persistNativeSession();
            await queryAndSyncDrive(pushAfterMerge: true);
            return true;
          }
        } on PlatformException catch (pe) {
          if (pe.code == 'SIGN_IN_SHA1_NOT_REGISTERED' &&
              _customOAuthClientId.trim().isNotEmpty) {
            // Automatically fall through to OAuth 2.0 Loopback PKCE if a Client ID is configured!
          } else {
            _lastError = pe.message ?? 'Google Sign-In failed (${pe.code}).';
            return false;
          }
        }
      }

      // Browser Loopback PKCE Sign-In (works with any Desktop / Installed Google OAuth Client ID)
      if (_customOAuthClientId.trim().isEmpty) {
        _lastError =
            'To use Browser PKCE Sign-In, paste a Desktop OAuth Client ID below, or register the Android package & SHA-1 shown below for 1-tap OS Sign-In.';
        return false;
      }

      final pkceRes = await signInWithBrowserLoopbackPkce(
        clientId: _customOAuthClientId.trim(),
        clientSecret: _customOAuthClientSecret.trim(),
        driveScope: defaultDriveScope,
      );
      if (pkceRes['signedIn'] == true) {
        _applySessionMap(pkceRes);
        await _persistNativeSession();
        await queryAndSyncDrive(pushAfterMerge: true);
        return true;
      }

      _lastError = pkceRes['error']?.toString() ?? 'Google Sign-In failed.';
      return false;
    } finally {
      _isSigningIn = false;
      notifyListeners();
    }
  }

  Future<void> signOut() async {
    _autoSaveDebounce?.cancel();
    if (kIsWeb) {
      clearSavedGoogleWebSession();
    } else {
      try {
        await _authChannel.invokeMethod('signOut');
      } catch (_) {}
      await LocalScoutEngine.saveLocalAuthConfig(session: <String, dynamic>{});
    }

    _isSignedIn = false;
    _userEmail = '';
    _userDisplayName = '';
    _userPhotoUrl = '';
    _accessToken = '';
    _refreshToken = '';
    _expiresAtMs = 0;
    _authMethod = '';
    _lastError = null;
    ApiService.setAuthBearerToken('');
    notifyListeners();
  }

  Future<void> _persistNativeSession() async {
    if (kIsWeb) return;
    await LocalScoutEngine.saveLocalAuthConfig(
      driveSyncFileId: _driveFileId,
      session: <String, dynamic>{
        'signedIn': _isSignedIn,
        'email': _userEmail,
        'displayName': _userDisplayName,
        'photoUrl': _userPhotoUrl,
        'accessToken': _accessToken,
        'refreshToken': _refreshToken,
        'expiresAtMs': _expiresAtMs,
        'authMethod': _authMethod,
      },
    );
  }

  Future<bool> _restoreOrRefreshNativeSession({String? invalidateToken}) async {
    if (kIsWeb) return _isSignedIn;

    // 1. If signed in via OAuth PKCE with a refresh token, refresh silently if needed
    if (_authMethod == 'oauth_pkce' && _refreshToken.isNotEmpty) {
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      if (invalidateToken == null &&
          _accessToken.isNotEmpty &&
          _expiresAtMs > nowMs + 60000) {
        return true;
      }
      if (_customOAuthClientId.trim().isNotEmpty) {
        try {
          final body = <String, String>{
            'client_id': _customOAuthClientId.trim(),
            'refresh_token': _refreshToken,
            'grant_type': 'refresh_token',
          };
          if (_customOAuthClientSecret.trim().isNotEmpty) {
            body['client_secret'] = _customOAuthClientSecret.trim();
          }
          final res = await http
              .post(
                Uri.parse('https://oauth2.googleapis.com/token'),
                headers: {'Content-Type': 'application/x-www-form-urlencoded'},
                body: body,
              )
              .timeout(const Duration(seconds: 15));
          if (res.statusCode == 200) {
            final data = jsonDecode(res.body) as Map<String, dynamic>;
            final newToken = data['access_token']?.toString() ?? '';
            if (newToken.isNotEmpty) {
              _accessToken = newToken;
              final exp = (data['expires_in'] as num?)?.toInt() ?? 3500;
              _expiresAtMs = DateTime.now().millisecondsSinceEpoch + exp * 1000;
              _isSignedIn = true;
              ApiService.setAuthBearerToken(_accessToken);
              await _persistNativeSession();
              notifyListeners();
              return true;
            }
          }
        } catch (_) {}
      }
    }

    // 2. Native OS Google Sign-In silent restore / token refresh
    try {
      final silentRes =
          await _authChannel.invokeMapMethod<String, dynamic>('silentSignIn', {
        'driveScope': defaultDriveScope,
        'invalidateToken': invalidateToken,
      });
      if (silentRes != null && silentRes['signedIn'] == true) {
        _applySessionMap(silentRes);
        await _persistNativeSession();
        return true;
      }
    } catch (_) {}

    return _isSignedIn && _accessToken.isNotEmpty;
  }

  /// Automatically saves the latest guest & vehicle search info to Google Drive
  /// whenever data changes on this device.
  void scheduleAutoSave() {
    _autoSaveDebounce?.cancel();
    _autoSaveDebounce = Timer(const Duration(milliseconds: 700), () {
      queryAndSyncDrive(pushAfterMerge: true);
    });
  }

  /// Queries Google Drive every time the app is opened or foregrounded so all devices
  /// stay continuously up to date.
  Future<bool> queryDriveOnAppOpen() async {
    await initialize();
    return queryAndSyncDrive(pushAfterMerge: true);
  }

  /// Pulls `preston_guest_scout_cloud_sync.json` from Google Drive, merges remote
  /// guests, deletions, and vehicle matches conflict-free, and saves the merged state back.
  Future<bool> queryAndSyncDrive({bool pushAfterMerge = true}) async {
    await initialize();
    if (_syncInFlight != null) return _syncInFlight!;

    final completer = Completer<bool>();
    _syncInFlight = completer.future;

    try {
      if (kIsWeb) {
        final ok = await _syncViaWebBackend(pushAfterMerge: pushAfterMerge);
        completer.complete(ok);
        return ok;
      }

      if (!_isSignedIn || _accessToken.isEmpty) {
        final restored = await _restoreOrRefreshNativeSession();
        if (!restored || _accessToken.isEmpty) {
          completer.complete(false);
          return false;
        }
      }

      final ok = await _syncDirectWithDriveRestApi(
        pushAfterMerge: pushAfterMerge,
        allowTokenRetry: true,
      );
      completer.complete(ok);
      return ok;
    } catch (e) {
      _lastError = e.toString();
      notifyListeners();
      completer.complete(false);
      return false;
    } finally {
      _syncInFlight = null;
    }
  }

  Future<bool> _syncViaWebBackend({required bool pushAfterMerge}) async {
    _isSyncing = true;
    _lastError = null;
    notifyListeners();

    try {
      final headers = <String, String>{'Content-Type': 'application/json'};
      if (_accessToken.isNotEmpty) {
        headers['Authorization'] = 'Bearer $_accessToken';
      }
      final res = await http
          .post(
            Uri.parse('${ApiService.baseUrl}/api/drive-sync/sync'),
            headers: headers,
            body: jsonEncode({
              'accessToken': _accessToken,
              'pushAfterMerge': pushAfterMerge,
              'deviceLabel': 'Preston Guest Scout Web',
            }),
          )
          .timeout(const Duration(seconds: 30));

      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        if (data['ok'] == true) {
          _lastQueriedAt = DateTime.now();
          if (pushAfterMerge) _lastSavedAt = _lastQueriedAt;
          final fid = data['fileId']?.toString() ?? '';
          if (fid.isNotEmpty) _driveFileId = fid;
          if (!_isSignedIn && data['mode'] == 'connected-google-drive') {
            await _refreshWebBackendDriveStatus();
          }
          _notifyCloudMerged();
          return true;
        } else if (data['error'] != null) {
          _lastError = data['error'].toString();
        }
      }
      return false;
    } catch (e) {
      _lastError = e.toString();
      return false;
    } finally {
      _isSyncing = false;
      notifyListeners();
    }
  }

  Future<bool> _syncDirectWithDriveRestApi({
    required bool pushAfterMerge,
    required bool allowTokenRetry,
  }) async {
    _isSyncing = true;
    _lastError = null;
    notifyListeners();

    try {
      final remoteMeta = await _findCloudFileInDrive(_accessToken);
      if (remoteMeta != null && (remoteMeta['id']?.toString() ?? '').isNotEmpty) {
        _driveFileId = remoteMeta['id'].toString();
        final remoteSnapshot =
            await _downloadCloudFileFromDrive(_accessToken, _driveFileId);
        if (remoteSnapshot != null) {
          await LocalScoutEngine.mergeCloudSnapshot(remoteSnapshot);
        }
        _lastQueriedAt = DateTime.now();

        if (pushAfterMerge) {
          final mergedLocal = await LocalScoutEngine.exportCloudSnapshot(
            deviceLabel: 'Preston Guest Scout Android/Googlebook',
          );
          await _uploadCloudFileToDrive(
            accessToken: _accessToken,
            existingFileId: _driveFileId,
            snapshot: mergedLocal,
          );
          _lastSavedAt = DateTime.now();
        }
      } else {
        // First time syncing on this Google account — create preston_guest_scout_cloud_sync.json
        _lastQueriedAt = DateTime.now();
        final initialLocal = await LocalScoutEngine.exportCloudSnapshot(
          deviceLabel: 'Preston Guest Scout Android/Googlebook',
        );
        final createdId = await _uploadCloudFileToDrive(
          accessToken: _accessToken,
          existingFileId: null,
          snapshot: initialLocal,
        );
        if (createdId.isNotEmpty) {
          _driveFileId = createdId;
        }
        _lastSavedAt = DateTime.now();
      }

      await LocalScoutEngine.saveLocalAuthConfig(driveSyncFileId: _driveFileId);
      _notifyCloudMerged();
      return true;
    } on _DriveUnauthorizedException {
      if (allowTokenRetry) {
        final refreshed = await _restoreOrRefreshNativeSession(
          invalidateToken: _accessToken,
        );
        if (refreshed && _accessToken.isNotEmpty) {
          _isSyncing = false;
          return _syncDirectWithDriveRestApi(
            pushAfterMerge: pushAfterMerge,
            allowTokenRetry: false,
          );
        }
      }
      _lastError = 'Google Drive session expired. Tap Sign in with Google to reconnect.';
      return false;
    } catch (e) {
      _lastError = e.toString();
      return false;
    } finally {
      _isSyncing = false;
      notifyListeners();
    }
  }

  Future<Map<String, dynamic>?> _findCloudFileInDrive(String token) async {
    final uri = Uri.https('www.googleapis.com', '/drive/v3/files', {
      'q': "name = '$driveSyncFileName' and trashed = false",
      'spaces': 'drive',
      'fields': 'files(id,name,modifiedTime)',
      'orderBy': 'modifiedTime desc',
      'pageSize': '5',
    });
    final res = await http
        .get(uri, headers: {'Authorization': 'Bearer $token'})
        .timeout(const Duration(seconds: 15));
    if (res.statusCode == 401) throw const _DriveUnauthorizedException();
    if (res.statusCode != 200) {
      throw Exception('Google Drive query HTTP ${res.statusCode}');
    }
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    final files = data['files'] as List<dynamic>? ?? [];
    if (files.isEmpty) return null;
    return Map<String, dynamic>.from(files.first as Map);
  }

  Future<Map<String, dynamic>?> _downloadCloudFileFromDrive(
    String token,
    String fileId,
  ) async {
    final uri = Uri.https(
      'www.googleapis.com',
      '/drive/v3/files/$fileId',
      {'alt': 'media'},
    );
    final res = await http
        .get(uri, headers: {'Authorization': 'Bearer $token'})
        .timeout(const Duration(seconds: 20));
    if (res.statusCode == 401) throw const _DriveUnauthorizedException();
    if (res.statusCode == 404) return null;
    if (res.statusCode != 200) {
      throw Exception('Google Drive download HTTP ${res.statusCode}');
    }
    if (res.body.trim().isEmpty) return null;
    return Map<String, dynamic>.from(jsonDecode(res.body) as Map);
  }

  Future<String> _uploadCloudFileToDrive({
    required String accessToken,
    required String? existingFileId,
    required Map<String, dynamic> snapshot,
  }) async {
    final jsonPayload = jsonEncode(snapshot);

    if (existingFileId != null && existingFileId.isNotEmpty) {
      final uri = Uri.https(
        'www.googleapis.com',
        '/upload/drive/v3/files/$existingFileId',
        {'uploadType': 'media', 'fields': 'id,name,modifiedTime'},
      );
      final res = await http
          .patch(
            uri,
            headers: {
              'Authorization': 'Bearer $accessToken',
              'Content-Type': 'application/json; charset=utf-8',
            },
            body: jsonPayload,
          )
          .timeout(const Duration(seconds: 25));
      if (res.statusCode == 401) throw const _DriveUnauthorizedException();
      if (res.statusCode == 404) {
        return _uploadCloudFileToDrive(
          accessToken: accessToken,
          existingFileId: null,
          snapshot: snapshot,
        );
      }
      if (res.statusCode < 200 || res.statusCode >= 300) {
        throw Exception('Google Drive save HTTP ${res.statusCode}');
      }
      final parsed = jsonDecode(res.body) as Map<String, dynamic>;
      return parsed['id']?.toString() ?? existingFileId;
    }

    final boundary = 'preston_drive_${DateTime.now().millisecondsSinceEpoch}';
    final metadata = jsonEncode({
      'name': driveSyncFileName,
      'mimeType': 'application/json',
      'description':
          'Preston Motor Guest Scout multi-device search & vehicle match sync file',
    });
    final multipartBody =
        '--$boundary\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n$metadata\r\n'
        '--$boundary\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n$jsonPayload\r\n'
        '--$boundary--';

    final uri = Uri.https(
      'www.googleapis.com',
      '/upload/drive/v3/files',
      {'uploadType': 'multipart', 'fields': 'id,name,modifiedTime'},
    );
    final res = await http
        .post(
          uri,
          headers: {
            'Authorization': 'Bearer $accessToken',
            'Content-Type': 'multipart/related; boundary=$boundary',
          },
          body: multipartBody,
        )
        .timeout(const Duration(seconds: 25));
    if (res.statusCode == 401) throw const _DriveUnauthorizedException();
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception('Google Drive create HTTP ${res.statusCode}');
    }
    final parsed = jsonDecode(res.body) as Map<String, dynamic>;
    return parsed['id']?.toString() ?? '';
  }
}

class _DriveUnauthorizedException implements Exception {
  const _DriveUnauthorizedException();
}

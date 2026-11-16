import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

/// Standard RFC 6234 SHA-256 implementation for OAuth 2.0 PKCE S256 code_challenge.
Uint8List _sha256Bytes(List<int> input) {
  const k = <int>[
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
  ];

  int rotr(int x, int n) => ((x & 0xffffffff) >>> n) | ((x << (32 - n)) & 0xffffffff);

  final bitLen = input.length * 8;
  final padded = <int>[...input, 0x80];
  while ((padded.length % 64) != 56) {
    padded.add(0);
  }
  final lenBytes = ByteData(8)..setUint64(0, bitLen, Endian.big);
  for (var i = 0; i < 8; i++) {
    padded.add(lenBytes.getUint8(i));
  }

  var h0 = 0x6a09e667;
  var h1 = 0xbb67ae85;
  var h2 = 0x3c6ef372;
  var h3 = 0xa54ff53a;
  var h4 = 0x510e527f;
  var h5 = 0x9b05688c;
  var h6 = 0x1f83d9ab;
  var h7 = 0x5be0cd19;

  final data = ByteData.sublistView(Uint8List.fromList(padded));
  final w = List<int>.filled(64, 0);

  for (var chunk = 0; chunk < padded.length; chunk += 64) {
    for (var i = 0; i < 16; i++) {
      w[i] = data.getUint32(chunk + i * 4, Endian.big);
    }
    for (var i = 16; i < 64; i++) {
      final s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ ((w[i - 15] & 0xffffffff) >>> 3);
      final s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ ((w[i - 2] & 0xffffffff) >>> 10);
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) & 0xffffffff;
    }

    var a = h0, b = h1, c = h2, d = h3, e = h4, f = h5, g = h6, h = h7;
    for (var i = 0; i < 64; i++) {
      final s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25);
      final ch = (e & f) ^ ((~e & 0xffffffff) & g);
      final temp1 = (h + s1 + ch + k[i] + w[i]) & 0xffffffff;
      final s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22);
      final maj = (a & b) ^ (a & c) ^ (b & c);
      final temp2 = (s0 + maj) & 0xffffffff;

      h = g;
      g = f;
      f = e;
      e = (d + temp1) & 0xffffffff;
      d = c;
      c = b;
      b = a;
      a = (temp1 + temp2) & 0xffffffff;
    }

    h0 = (h0 + a) & 0xffffffff;
    h1 = (h1 + b) & 0xffffffff;
    h2 = (h2 + c) & 0xffffffff;
    h3 = (h3 + d) & 0xffffffff;
    h4 = (h4 + e) & 0xffffffff;
    h5 = (h5 + f) & 0xffffffff;
    h6 = (h6 + g) & 0xffffffff;
    h7 = (h7 + h) & 0xffffffff;
  }

  final out = ByteData(32)
    ..setUint32(0, h0, Endian.big)
    ..setUint32(4, h1, Endian.big)
    ..setUint32(8, h2, Endian.big)
    ..setUint32(12, h3, Endian.big)
    ..setUint32(16, h4, Endian.big)
    ..setUint32(20, h5, Endian.big)
    ..setUint32(24, h6, Endian.big)
    ..setUint32(28, h7, Endian.big);
  return out.buffer.asUint8List();
}

String _randomUrlSafe(int length) {
  const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';
  final rng = Random.secure();
  return List.generate(length, (_) => chars[rng.nextInt(chars.length)]).join();
}

Future<Map<String, String>> _fetchUserProfile(String accessToken) async {
  String email = '';
  String displayName = 'Google Account';
  String photoUrl = '';
  try {
    final uRes = await http
        .get(
          Uri.parse('https://www.googleapis.com/oauth2/v3/userinfo'),
          headers: {'Authorization': 'Bearer $accessToken'},
        )
        .timeout(const Duration(seconds: 12));
    if (uRes.statusCode == 200) {
      final info = jsonDecode(uRes.body) as Map<String, dynamic>;
      email = info['email']?.toString() ?? '';
      displayName =
          info['name']?.toString() ?? (email.isNotEmpty ? email : 'Google Account');
      photoUrl = info['picture']?.toString() ?? '';
    }
  } catch (_) {}
  return {
    'email': email,
    'displayName': displayName,
    'photoUrl': photoUrl,
  };
}

/// Googlebook-safe OAuth 2.0 Device Authorization Flow (RFC 8628).
/// Works seamlessly inside ChromeOS ARCVM containers as well as Android phones & tablets
/// without needing localhost loopback port forwarding or SHA-1 registration.
Future<Map<String, dynamic>> signInWithGoogleDeviceFlow({
  required String clientId,
  String clientSecret = '',
  required String driveScope,
  required void Function(String userCode, String verificationUrl) onCodeIssued,
  required bool Function() isCanceled,
}) async {
  try {
    final codeRes = await http
        .post(
          Uri.parse('https://oauth2.googleapis.com/device/code'),
          headers: {'Content-Type': 'application/x-www-form-urlencoded'},
          body: {
            'client_id': clientId.trim(),
            'scope': '$driveScope email profile',
          },
        )
        .timeout(const Duration(seconds: 15));

    final codeJson = jsonDecode(codeRes.body) as Map<String, dynamic>;
    if (codeRes.statusCode != 200 ||
        (codeJson['device_code']?.toString() ?? '').isEmpty) {
      return <String, dynamic>{
        'signedIn': false,
        'unsupportedClient': true,
        'error': codeJson['error_description']?.toString() ??
            codeJson['error']?.toString() ??
            'Client ID is not a TV/Device OAuth client (${codeRes.statusCode}).',
      };
    }

    final deviceCode = codeJson['device_code'].toString();
    final userCode = codeJson['user_code']?.toString() ?? '';
    final verificationUrl = codeJson['verification_url']?.toString() ??
        codeJson['verification_uri']?.toString() ??
        'https://www.google.com/device';
    final expiresInSec = (codeJson['expires_in'] as num?)?.toInt() ?? 900;
    var intervalSec = (codeJson['interval'] as num?)?.toInt() ?? 5;
    if (intervalSec < 3) intervalSec = 5;

    try {
      await Clipboard.setData(ClipboardData(text: userCode));
    } catch (_) {}
    onCodeIssued(userCode, verificationUrl);

    try {
      await launchUrl(
        Uri.parse(verificationUrl),
        mode: LaunchMode.externalApplication,
      );
    } catch (_) {}

    final deadline = DateTime.now().add(Duration(seconds: expiresInSec));
    while (DateTime.now().isBefore(deadline)) {
      if (isCanceled()) {
        return <String, dynamic>{
          'signedIn': false,
          'error': 'Google verification code sign-in was canceled.',
        };
      }
      await Future<void>.delayed(Duration(seconds: intervalSec));
      if (isCanceled()) {
        return <String, dynamic>{
          'signedIn': false,
          'error': 'Google verification code sign-in was canceled.',
        };
      }

      final pollBody = <String, String>{
        'client_id': clientId.trim(),
        'device_code': deviceCode,
        'grant_type': 'urn:ietf:params:oauth:grant-type:device_code',
      };
      if (clientSecret.trim().isNotEmpty) {
        pollBody['client_secret'] = clientSecret.trim();
      }

      final tokenRes = await http
          .post(
            Uri.parse('https://oauth2.googleapis.com/token'),
            headers: {'Content-Type': 'application/x-www-form-urlencoded'},
            body: pollBody,
          )
          .timeout(const Duration(seconds: 15));

      final tokenJson = jsonDecode(tokenRes.body) as Map<String, dynamic>;
      final accessToken = tokenJson['access_token']?.toString() ?? '';
      if (tokenRes.statusCode == 200 && accessToken.isNotEmpty) {
        final profile = await _fetchUserProfile(accessToken);
        final exp = (tokenJson['expires_in'] as num?)?.toInt() ?? 3500;
        return <String, dynamic>{
          'signedIn': true,
          'email': profile['email'] ?? '',
          'displayName': profile['displayName'] ?? 'Google Account',
          'photoUrl': profile['photoUrl'] ?? '',
          'accessToken': accessToken,
          'refreshToken': tokenJson['refresh_token']?.toString() ?? '',
          'expiresAtMs': DateTime.now().millisecondsSinceEpoch + exp * 1000,
          'authMethod': 'oauth_pkce',
        };
      }

      final errCode = tokenJson['error']?.toString() ?? '';
      if (errCode == 'authorization_pending') {
        continue;
      } else if (errCode == 'slow_down') {
        intervalSec += 5;
        continue;
      } else {
        return <String, dynamic>{
          'signedIn': false,
          'error': tokenJson['error_description']?.toString() ??
              'Google OAuth error: $errCode',
        };
      }
    }

    return <String, dynamic>{
      'signedIn': false,
      'error': 'Verification code expired before completion. Please try again.',
    };
  } catch (e) {
    return <String, dynamic>{
      'signedIn': false,
      'unsupportedClient': true,
      'error': e.toString(),
    };
  }
}

Future<Map<String, dynamic>> signInWithBrowserLoopbackPkce({
  required String clientId,
  String clientSecret = '',
  required String driveScope,
  String? loginHint,
}) async {
  HttpServer? server;
  try {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final redirectUri = 'http://127.0.0.1:${server.port}/oauth2redirect';
    final codeVerifier = _randomUrlSafe(64);
    final challenge = base64UrlEncode(_sha256Bytes(utf8.encode(codeVerifier)))
        .replaceAll('=', '');
    final state = _randomUrlSafe(24);

    final queryParams = <String, String>{
      'client_id': clientId.trim(),
      'redirect_uri': redirectUri,
      'response_type': 'code',
      'scope': '$driveScope openid email profile',
      'code_challenge': challenge,
      'code_challenge_method': 'S256',
      'access_type': 'offline',
      'prompt': 'consent select_account',
      'state': state,
    };
    if (loginHint != null && loginHint.trim().isNotEmpty) {
      queryParams['login_hint'] = loginHint.trim();
    }

    final authUri =
        Uri.https('accounts.google.com', '/o/oauth2/v2/auth', queryParams);

    final launched =
        await launchUrl(authUri, mode: LaunchMode.externalApplication);
    if (!launched) {
      return <String, dynamic>{
        'signedIn': false,
        'error': 'Could not open system browser for Google SSO.',
      };
    }

    final req = await server.first.timeout(const Duration(minutes: 3));
    final params = req.uri.queryParameters;
    final returnedState = params['state'] ?? '';
    final code = params['code'] ?? '';
    final err = params['error'] ?? '';

    req.response.statusCode = 200;
    req.response.headers.contentType = ContentType.html;
    req.response.write('''<!DOCTYPE html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Preston Motor Guest Scout</title>
<style>body{font-family:system-ui,sans-serif;background:#f8fafd;color:#1b1b1f;display:flex;align-items:center;justify-content:center;min-height:90vh;margin:0;padding:24px;text-align:center}
.card{background:#fff;border-radius:20px;padding:32px;max-width:420px;box-shadow:0 8px 28px rgba(11,87,208,.12)}
h2{color:#0b57d0;margin-top:0}a.btn{display:inline-block;margin-top:16px;padding:12px 24px;background:#0b57d0;color:#fff;text-decoration:none;border-radius:999px;font-weight:600}</style>
<script>setTimeout(function(){window.location.href="prestonscout://oauth2redirect?done=1";},400);</script>
</head><body><div class="card">
<h2>${code.isNotEmpty ? 'Google Sign-In Complete' : 'Google Sign-In Closed'}</h2>
<p>${code.isNotEmpty ? 'Your Google Drive multi-device sync is now active. Returning to Preston Motor Guest Scout...' : 'You may return to Preston Motor Guest Scout.'}</p>
<a class="btn" href="prestonscout://oauth2redirect?done=1">Return to App</a>
</div></body></html>''');
    await req.response.close();

    if (err.isNotEmpty || code.isEmpty) {
      return <String, dynamic>{
        'signedIn': false,
        'error': err.isNotEmpty
            ? 'Google OAuth error: $err'
            : 'Browser authorization closed before completing.',
      };
    }
    if (returnedState != state) {
      return <String, dynamic>{
        'signedIn': false,
        'error': 'OAuth state mismatch. Please try signing in again.',
      };
    }

    final tokenBody = <String, String>{
      'client_id': clientId.trim(),
      'code': code,
      'code_verifier': codeVerifier,
      'grant_type': 'authorization_code',
      'redirect_uri': redirectUri,
    };
    if (clientSecret.trim().isNotEmpty) {
      tokenBody['client_secret'] = clientSecret.trim();
    }

    final tokenRes = await http
        .post(
          Uri.parse('https://oauth2.googleapis.com/token'),
          headers: {'Content-Type': 'application/x-www-form-urlencoded'},
          body: tokenBody,
        )
        .timeout(const Duration(seconds: 20));

    final tokenJson = jsonDecode(tokenRes.body) as Map<String, dynamic>;
    final accessToken = tokenJson['access_token']?.toString() ?? '';
    if (tokenRes.statusCode != 200 || accessToken.isEmpty) {
      return <String, dynamic>{
        'signedIn': false,
        'error': tokenJson['error_description']?.toString() ??
            tokenJson['error']?.toString() ??
            'Token exchange failed (${tokenRes.statusCode}).',
      };
    }

    final profile = await _fetchUserProfile(accessToken);
    final expiresIn = (tokenJson['expires_in'] as num?)?.toInt() ?? 3500;
    return <String, dynamic>{
      'signedIn': true,
      'email': profile['email'] ?? '',
      'displayName': profile['displayName'] ?? 'Google Account',
      'photoUrl': profile['photoUrl'] ?? '',
      'accessToken': accessToken,
      'refreshToken': tokenJson['refresh_token']?.toString() ?? '',
      'expiresAtMs': DateTime.now().millisecondsSinceEpoch + expiresIn * 1000,
      'authMethod': 'oauth_pkce',
    };
  } catch (e) {
    return <String, dynamic>{
      'signedIn': false,
      'error':
          'Browser loopback sign-in timed out or could not reach local port (on Googlebook, use an Android SHA-1 client or TV/Device OAuth Client ID): $e',
    };
  } finally {
    try {
      await server?.close(force: true);
    } catch (_) {}
  }
}

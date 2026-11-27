import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import '../models/models.dart';

/// On-device Auto iPacket StickerPull (`https://dpapp.autoipacket.com/stickerpull`)
/// + Google Gemini (`gemini-2.5-flash`) Window Sticker service.
class WindowStickerService {
  static const String stickerPullPortalUrl =
      'https://dpapp.autoipacket.com/stickerpull';
  static const String authLoginUrl =
      'https://auth-api.autoipacket.com/api/authn/login';
  static const String authRefreshUrl =
      'https://auth-api.autoipacket.com/api/authn/token/refresh';
  static const String djApiBaseUrl = 'https://djapi.autoipacket.com';
  static const int aipClientId = 5100206;
  static const String aipAppVersion = '1.46.1';

  static const String defaultUsername = 'oonyeador@prestonmotor.com';
  static const String defaultPassword = 'Destiny703!1*';

  static const String vpicDecodeBase =
      'https://vpic.nhtsa.dot.gov/api/vehicles/DecodeVinValuesExtended';
  static const String geminiApiBase =
      'https://generativelanguage.googleapis.com/v1beta/models';

  static const MethodChannel _nativeStickerChannel =
      MethodChannel('com.prestonmotor.scout/window_sticker');

  static String _cachedUsername = '';
  static String _cachedAccessToken = '';
  static String _cachedRefreshToken = '';
  static DateTime? _tokenObtainedAt;

  @visibleForTesting
  static Future<WindowStickerResult> Function(String vin)? mockPullHandler;

  @visibleForTesting
  static Future<List<RecentWindowStickerEntry>> Function()? mockRecentHandler;

  static bool get hasMockPullHandler => mockPullHandler != null;

  static void resetMocksAndCacheForTest() {
    mockPullHandler = null;
    mockRecentHandler = null;
    _cachedUsername = '';
    _cachedAccessToken = '';
    _cachedRefreshToken = '';
    _tokenObtainedAt = null;
  }

  /// Validates a 17-character VIN (or extracts an embedded 17-char VIN from pasted text/URLs).
  static ({bool valid, String vin, String error}) validateAndExtractVin(
    String rawInput,
  ) {
    final upper = rawInput.toUpperCase().trim();
    if (upper.isEmpty) {
      return (
        valid: false,
        vin: '',
        error: 'Please enter a 17-character VIN.',
      );
    }

    final directCleaned = upper.replaceAll(RegExp(r'[\s\-]+'), '');
    if (directCleaned.length == 17) {
      if (RegExp(r'[IOQ]').hasMatch(directCleaned)) {
        return (
          valid: false,
          vin: directCleaned,
          error:
              'Standard 17-character VINs never contain the letters I, O, or Q.',
        );
      }
      if (!RegExp(r'^[A-HJ-NPR-Z0-9]{17}$').hasMatch(directCleaned)) {
        return (
          valid: false,
          vin: directCleaned,
          error:
              'VIN must contain only letters A–Z (excluding I, O, Q) and digits 0–9.',
        );
      }
      return (valid: true, vin: directCleaned, error: '');
    }

    final embedded =
        RegExp(r'\b([A-HJ-NPR-Z0-9]{17})\b').firstMatch(upper)?.group(1);
    if (embedded != null && embedded.length == 17) {
      return (valid: true, vin: embedded, error: '');
    }

    final preview =
        directCleaned.length > 17 ? directCleaned.substring(0, 17) : directCleaned;
    return (
      valid: false,
      vin: preview,
      error:
          'VIN must be exactly 17 characters (currently ${directCleaned.length}).',
    );
  }

  static Map<String, String> _buildAipHeaders(String accessToken) => {
        'Authorization': 'bearer $accessToken',
        'AIP-Application-Type': '3',
        'AIP-Application-Version': aipAppVersion,
        'AIP-Time-Zone': 'America/New_York',
        'Accept': 'application/json',
      };

  static Future<String> _authenticateAutoIPacket({
    required String username,
    required String password,
    bool forceFresh = false,
  }) async {
    final now = DateTime.now();
    if (!forceFresh &&
        _cachedAccessToken.isNotEmpty &&
        _cachedUsername == username &&
        _tokenObtainedAt != null &&
        now.difference(_tokenObtainedAt!).inMinutes < 25) {
      return _cachedAccessToken;
    }

    if (!forceFresh &&
        _cachedRefreshToken.isNotEmpty &&
        _cachedUsername == username) {
      try {
        final refRes = await http
            .post(
              Uri.parse(authRefreshUrl),
              headers: {
                'Authorization': 'bearer $_cachedRefreshToken',
                'Accept': 'application/json',
              },
            )
            .timeout(const Duration(seconds: 12));
        if (refRes.statusCode >= 200 && refRes.statusCode < 300) {
          final refData = jsonDecode(refRes.body) as Map<String, dynamic>;
          final nextAccess = refData['access_token']?.toString() ?? '';
          if (nextAccess.isNotEmpty) {
            _cachedUsername = username;
            _cachedAccessToken = nextAccess;
            final nextRefresh = refData['refresh_token']?.toString() ?? '';
            if (nextRefresh.isNotEmpty) _cachedRefreshToken = nextRefresh;
            _tokenObtainedAt = DateTime.now();
            return _cachedAccessToken;
          }
        }
      } catch (_) {
        // Fall through to full login
      }
    }

    final res = await http
        .post(
          Uri.parse(authLoginUrl),
          headers: const {
            'Accept': 'application/json',
            'Content-Type': 'application/json',
          },
          body: jsonEncode({
            'username': username,
            'password': password,
            'client_id': aipClientId,
          }),
        )
        .timeout(const Duration(seconds: 15));

    Map<String, dynamic> data = const {};
    try {
      data = jsonDecode(res.body) as Map<String, dynamic>;
    } catch (_) {}

    final token = data['access_token']?.toString() ?? '';
    if (res.statusCode < 200 || res.statusCode >= 300 || token.isEmpty) {
      final detail = data['detail']?.toString() ??
          data['error_code']?.toString() ??
          'Auto iPacket login failed (HTTP ${res.statusCode}).';
      throw Exception(
        'Unable to sign in to Auto iPacket StickerPull ($stickerPullPortalUrl): $detail',
      );
    }

    _cachedUsername = username;
    _cachedAccessToken = token;
    _cachedRefreshToken = data['refresh_token']?.toString() ?? '';
    _tokenObtainedAt = DateTime.now();
    return token;
  }

  static Future<({Map<String, dynamic> pollPayload, Uint8List? pdfBytes, Map<String, dynamic>? buildData})>
      _executeStickerPullOnAutoIPacket({
    required String vin,
    required String username,
    required String password,
  }) async {
    var token = await _authenticateAutoIPacket(
      username: username,
      password: password,
    );

    final pullUri = Uri.parse(
      '$djApiBaseUrl/v2/sticker-puller/pull/${Uri.encodeComponent(vin)}',
    );
    var pullRes = await http
        .put(pullUri, headers: _buildAipHeaders(token))
        .timeout(const Duration(seconds: 20));

    if (pullRes.statusCode == 401 || pullRes.statusCode == 403) {
      token = await _authenticateAutoIPacket(
        username: username,
        password: password,
        forceFresh: true,
      );
      pullRes = await http
          .put(pullUri, headers: _buildAipHeaders(token))
          .timeout(const Duration(seconds: 20));
    }

    Map<String, dynamic> pullJson = const {};
    try {
      pullJson = jsonDecode(pullRes.body) as Map<String, dynamic>;
    } catch (_) {}

    final pollId = pullJson['id']?.toString() ?? '';
    if (pullRes.statusCode < 200 || pullRes.statusCode >= 300 || pollId.isEmpty) {
      final detail = pullJson['detail']?.toString() ??
          pullJson['message']?.toString() ??
          'Auto iPacket StickerPull could not start lookup for VIN $vin (HTTP ${pullRes.statusCode}).';
      throw Exception(detail);
    }

    final pollUri = Uri.parse(
      '$djApiBaseUrl/v2/sticker-puller/poll/${Uri.encodeComponent(pollId)}',
    );
    Map<String, dynamic>? finalPayload;

    for (var attempt = 0; attempt < 35; attempt++) {
      await Future<void>.delayed(
        Duration(milliseconds: attempt == 0 ? 900 : 1100),
      );
      final pollRes = await http
          .get(pollUri, headers: _buildAipHeaders(token))
          .timeout(const Duration(seconds: 15));
      Map<String, dynamic> pollJson = const {};
      try {
        pollJson = jsonDecode(pollRes.body) as Map<String, dynamic>;
      } catch (_) {}

      final state = (pollJson['state']?.toString() ?? '').toUpperCase();
      if (state == 'SUCCESS') {
        finalPayload = pollJson;
        break;
      }
      if (state == 'FAILED' || state == 'ERROR') {
        final reason = pollJson['detail']?.toString() ??
            pollJson['error_code']?.toString() ??
            'OEM Window Sticker is not available for VIN $vin on Auto iPacket StickerPull.';
        throw Exception(reason);
      }
    }

    if (finalPayload == null) {
      throw Exception(
        'Timed out waiting for Auto iPacket StickerPull to generate the window sticker for $vin.',
      );
    }

    Uint8List? pdfBytes;
    final pdfUrl = finalPayload['pdf']?.toString() ?? '';
    if (pdfUrl.isNotEmpty) {
      try {
        final pdfRes = await http
            .get(Uri.parse(pdfUrl), headers: _buildAipHeaders(token))
            .timeout(const Duration(seconds: 25));
        if (pdfRes.statusCode >= 200 && pdfRes.statusCode < 300) {
          pdfBytes = pdfRes.bodyBytes;
        }
      } catch (_) {
        pdfBytes = null;
      }
    }

    Map<String, dynamic>? buildData;
    final buildDataUrl = finalPayload['build_data']?.toString() ?? '';
    if (buildDataUrl.isNotEmpty) {
      try {
        final bdRes = await http
            .get(Uri.parse(buildDataUrl))
            .timeout(const Duration(seconds: 12));
        if (bdRes.statusCode >= 200 && bdRes.statusCode < 300) {
          final parsed = jsonDecode(bdRes.body);
          if (parsed is Map) {
            buildData = Map<String, dynamic>.from(parsed);
          }
        }
      } catch (_) {
        buildData = null;
      }
    }

    return (
      pollPayload: finalPayload,
      pdfBytes: pdfBytes,
      buildData: buildData,
    );
  }

  static Future<Map<String, dynamic>?> _decodeVinNhtsaVpic(String vin) async {
    try {
      final res = await http
          .get(Uri.parse('$vpicDecodeBase/${Uri.encodeComponent(vin)}?format=json'))
          .timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) return null;
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final results = data['Results'] as List<dynamic>? ?? const [];
      if (results.isEmpty || results.first is! Map) return null;
      final row = Map<String, dynamic>.from(results.first as Map);
      final yr = int.tryParse((row['ModelYear']?.toString() ?? '').trim());
      final dispL = (row['DisplacementL']?.toString() ?? '').trim();
      final cyl = (row['EngineCylinders']?.toString() ?? '').trim();
      final fuel = (row['FuelTypePrimary']?.toString() ?? '').trim();
      final engineParts = [
        if (dispL.isNotEmpty) '${dispL}L',
        if (cyl.isNotEmpty) '$cyl-Cyl',
        if (fuel.isNotEmpty) fuel,
      ];
      final trimVal = (row['Trim']?.toString() ?? '').trim();
      final seriesVal = (row['Series']?.toString() ?? '').trim();
      return <String, dynamic>{
        'year': yr,
        'make': (row['Make']?.toString() ?? '').trim(),
        'model': (row['Model']?.toString() ?? '').trim(),
        'trim': trimVal.isNotEmpty ? trimVal : seriesVal,
        'bodyStyle': (row['BodyClass']?.toString() ?? '').trim(),
        'drivetrain': (row['DriveType']?.toString() ?? '').trim(),
        'engine': engineParts.join(' '),
        'transmission': (row['TransmissionStyle']?.toString() ?? '').trim(),
      };
    } catch (_) {
      return null;
    }
  }

  /// Pulls the vehicle Window Sticker from `https://dpapp.autoipacket.com/stickerpull`
  /// using Gemini (`gemini-2.5-flash`) tool-calling & multimodal PDF/build-sheet extraction.
  static Future<WindowStickerResult> pullWindowSticker({
    required String rawVin,
    String username = defaultUsername,
    String password = defaultPassword,
    String geminiApiKey = '',
    String geminiModel = 'gemini-2.5-flash',
  }) async {
    final check = validateAndExtractVin(rawVin);
    if (!check.valid) {
      throw Exception(check.error);
    }
    final vin = check.vin;

    if (mockPullHandler != null) {
      return mockPullHandler!(vin);
    }

    final cleanUser =
        username.trim().isEmpty ? defaultUsername : username.trim();
    final cleanPass = password.isEmpty ? defaultPassword : password;
    final cleanKey = geminiApiKey.trim();
    final cleanModel =
        geminiModel.trim().isEmpty ? 'gemini-2.5-flash' : geminiModel.trim();

    final vpicFuture = _decodeVinNhtsaVpic(vin);

    ({
      Map<String, dynamic> pollPayload,
      Uint8List? pdfBytes,
      Map<String, dynamic>? buildData,
    })? bundle;
    bool geminiToolInvoked = false;

    // 1. Let Gemini invoke `pull_autoipacket_window_sticker` tool when API key is configured
    if (cleanKey.isNotEmpty) {
      try {
        final toolUri = Uri.parse(
          '$geminiApiBase/${Uri.encodeComponent(cleanModel)}:generateContent?key=${Uri.encodeComponent(cleanKey)}',
        );
        final toolRes = await http
            .post(
              toolUri,
              headers: const {'Content-Type': 'application/json'},
              body: jsonEncode({
                'systemInstruction': {
                  'parts': [
                    {
                      'text':
                          'You are the Preston Automotive Group Window Sticker Agent. Always call `pull_autoipacket_window_sticker` to retrieve the official OEM window sticker from https://dpapp.autoipacket.com/stickerpull.',
                    },
                  ],
                },
                'contents': [
                  {
                    'role': 'user',
                    'parts': [
                      {
                        'text':
                            'Pull the official vehicle window sticker from https://dpapp.autoipacket.com/stickerpull for VIN $vin.',
                      },
                    ],
                  },
                ],
                'tools': [
                  {
                    'functionDeclarations': [
                      {
                        'name': 'pull_autoipacket_window_sticker',
                        'description':
                            'Authenticates with https://dpapp.autoipacket.com/stickerpull and pulls the official OEM Window Sticker PDF and build data for a 17-character VIN.',
                        'parameters': {
                          'type': 'OBJECT',
                          'properties': {
                            'vin': {
                              'type': 'STRING',
                              'description':
                                  '17-character Vehicle Identification Number (VIN)',
                            },
                          },
                          'required': ['vin'],
                        },
                      },
                    ],
                  },
                ],
                'toolConfig': {
                  'functionCallingConfig': {
                    'mode': 'ANY',
                    'allowedFunctionNames': ['pull_autoipacket_window_sticker'],
                  },
                },
              }),
            )
            .timeout(const Duration(seconds: 15));

        if (toolRes.statusCode == 200) {
          final toolJson = jsonDecode(toolRes.body) as Map<String, dynamic>;
          final candidates = toolJson['candidates'] as List<dynamic>? ?? const [];
          if (candidates.isNotEmpty) {
            final content =
                (candidates.first as Map)['content'] as Map? ?? const {};
            final parts = content['parts'] as List<dynamic>? ?? const [];
            for (final part in parts) {
              if (part is Map && part['functionCall'] is Map) {
                final fnCall = Map<String, dynamic>.from(
                  part['functionCall'] as Map,
                );
                if (fnCall['name'] == 'pull_autoipacket_window_sticker') {
                  final args =
                      Map<String, dynamic>.from(fnCall['args'] as Map? ?? const {});
                  final argVin = validateAndExtractVin(
                    args['vin']?.toString() ?? vin,
                  );
                  bundle = await _executeStickerPullOnAutoIPacket(
                    vin: argVin.valid ? argVin.vin : vin,
                    username: cleanUser,
                    password: cleanPass,
                  );
                  geminiToolInvoked = true;
                  break;
                }
              }
            }
          }
        }
      } catch (_) {
        // Fallback to direct Auto iPacket pull below
      }
    }

    bundle ??= await _executeStickerPullOnAutoIPacket(
      vin: vin,
      username: cleanUser,
      password: cleanPass,
    );

    final vpic = await vpicFuture;

    // 2. Multimodal Gemini analysis of the pulled Window Sticker PDF + build_data JSON
    Map<String, dynamic>? geminiExtracted;
    if (cleanKey.isNotEmpty) {
      try {
        final extractUri = Uri.parse(
          '$geminiApiBase/${Uri.encodeComponent(cleanModel)}:generateContent?key=${Uri.encodeComponent(cleanKey)}',
        );
        final parts = <Map<String, dynamic>>[];
        if (bundle.pdfBytes != null &&
            bundle.pdfBytes!.isNotEmpty &&
            bundle.pdfBytes!.length <= 16 * 1024 * 1024) {
          parts.add({
            'inlineData': {
              'mimeType': 'application/pdf',
              'data': base64Encode(bundle.pdfBytes!),
            },
          });
        }
        parts.add({
          'text':
              'Extract complete window sticker specifications, MSRP pricing breakdown, factory installed packages/options with prices, standard equipment highlights, warranty info, and a concise 2-sentence salesperson summary for VIN $vin pulled from https://dpapp.autoipacket.com/stickerpull.\n\nReference metadata:\n${jsonEncode({
                'vin': vin,
                'autoIPacketVehicleDetails': bundle.pollPayload['vehicle_details'],
                'autoIPacketBuildData': bundle.buildData,
                'nhtsaVpicFactoryDecode': vpic,
              })}',
        });

        final extractRes = await http
            .post(
              extractUri,
              headers: const {'Content-Type': 'application/json'},
              body: jsonEncode({
                'contents': [
                  {'role': 'user', 'parts': parts},
                ],
                'generationConfig': {
                  'temperature': 0.1,
                  'responseMimeType': 'application/json',
                  'responseSchema': {
                    'type': 'OBJECT',
                    'properties': {
                      'year': {'type': 'INTEGER', 'nullable': true},
                      'make': {'type': 'STRING'},
                      'model': {'type': 'STRING'},
                      'trim': {'type': 'STRING'},
                      'bodyStyle': {'type': 'STRING'},
                      'exteriorColor': {'type': 'STRING'},
                      'interiorColor': {'type': 'STRING'},
                      'engine': {'type': 'STRING'},
                      'transmission': {'type': 'STRING'},
                      'drivetrain': {'type': 'STRING'},
                      'cityMpg': {'type': 'INTEGER', 'nullable': true},
                      'highwayMpg': {'type': 'INTEGER', 'nullable': true},
                      'combinedMpg': {'type': 'INTEGER', 'nullable': true},
                      'baseMsrp': {'type': 'NUMBER', 'nullable': true},
                      'optionsTotal': {'type': 'NUMBER', 'nullable': true},
                      'destinationCharge': {'type': 'NUMBER', 'nullable': true},
                      'totalMsrp': {'type': 'NUMBER', 'nullable': true},
                      'packagesAndOptions': {
                        'type': 'ARRAY',
                        'items': {
                          'type': 'OBJECT',
                          'properties': {
                            'code': {'type': 'STRING'},
                            'description': {'type': 'STRING'},
                            'price': {'type': 'NUMBER', 'nullable': true},
                          },
                          'required': ['description'],
                        },
                      },
                      'standardHighlights': {
                        'type': 'ARRAY',
                        'items': {'type': 'STRING'},
                      },
                      'warrantySummary': {'type': 'STRING'},
                      'salesSummary': {'type': 'STRING'},
                    },
                    'required': [
                      'make',
                      'model',
                      'packagesAndOptions',
                      'standardHighlights',
                      'salesSummary',
                    ],
                  },
                },
              }),
            )
            .timeout(const Duration(seconds: 35));

        if (extractRes.statusCode == 200) {
          final extractJson =
              jsonDecode(extractRes.body) as Map<String, dynamic>;
          final candidates =
              extractJson['candidates'] as List<dynamic>? ?? const [];
          if (candidates.isNotEmpty) {
            final content =
                (candidates.first as Map)['content'] as Map? ?? const {};
            final outParts = content['parts'] as List<dynamic>? ?? const [];
            if (outParts.isNotEmpty) {
              final rawText = (outParts.first as Map)['text']?.toString() ?? '';
              if (rawText.isNotEmpty) {
                geminiExtracted =
                    Map<String, dynamic>.from(jsonDecode(rawText) as Map);
              }
            }
          }
        }
      } catch (_) {
        geminiExtracted = null;
      }
    }

    return _normalizeStickerResult(
      vin: vin,
      accountEmail: cleanUser,
      pollPayload: bundle.pollPayload,
      pdfBytes: bundle.pdfBytes,
      buildData: bundle.buildData,
      vpic: vpic,
      geminiExtracted: geminiExtracted,
      geminiToolInvoked: geminiToolInvoked,
    );
  }

  static WindowStickerResult _normalizeStickerResult({
    required String vin,
    required String accountEmail,
    required Map<String, dynamic> pollPayload,
    required Uint8List? pdfBytes,
    required Map<String, dynamic>? buildData,
    required Map<String, dynamic>? vpic,
    required Map<String, dynamic>? geminiExtracted,
    required bool geminiToolInvoked,
  }) {
    final vd =
        Map<String, dynamic>.from(pollPayload['vehicle_details'] as Map? ?? const {});
    final gd =
        Map<String, dynamic>.from(buildData?['generic_details'] as Map? ?? const {});
    final pd =
        Map<String, dynamic>.from(buildData?['pricing_details'] as Map? ?? const {});
    final fe =
        Map<String, dynamic>.from(gd['fuel_economy'] as Map? ?? const {});
    final gx = geminiExtracted ?? const <String, dynamic>{};

    final year = (gx['year'] as num?)?.toInt() ??
        (vd['year'] as num?)?.toInt() ??
        (gd['year'] as num?)?.toInt() ??
        (vpic?['year'] as num?)?.toInt();

    String pickStr(List<dynamic> candidates) {
      for (final c in candidates) {
        final s = (c?.toString() ?? '').trim();
        if (s.isNotEmpty) return s;
      }
      return '';
    }

    final make = pickStr([gx['make'], vd['make'], gd['make'], vpic?['make']]);
    final model =
        pickStr([gx['model'], vd['model'], gd['model'], vpic?['model']]);
    final trim = pickStr([gx['trim'], gd['trim'], vpic?['trim']]);

    final titleParts = <String>[
      if (year != null) '$year',
      if (make.isNotEmpty) make,
      if (model.isNotEmpty) model,
      if (trim.isNotEmpty && !model.toLowerCase().contains(trim.toLowerCase()))
        trim,
    ];
    final vehicleTitle =
        titleParts.isEmpty ? 'VIN $vin' : titleParts.join(' ');

    var packagesAndOptions = <WindowStickerOptionItem>[];
    final gxOpts = gx['packagesAndOptions'] as List<dynamic>?;
    if (gxOpts != null && gxOpts.isNotEmpty) {
      packagesAndOptions = gxOpts
          .whereType<Map>()
          .map((o) => WindowStickerOptionItem.fromJson(Map<String, dynamic>.from(o)))
          .where((o) => o.description.trim().isNotEmpty)
          .toList();
    } else if (buildData?['options'] is List) {
      packagesAndOptions = (buildData!['options'] as List<dynamic>)
          .whereType<Map>()
          .map((raw) {
            final m = Map<String, dynamic>.from(raw);
            return WindowStickerOptionItem(
              code: (m['code']?.toString() ?? '').trim(),
              description: pickStr([m['description'], m['name']]),
              price: (m['price'] as num?)?.toDouble() ??
                  (m['msrp'] as num?)?.toDouble(),
            );
          })
          .where((o) => o.description.isNotEmpty)
          .toList();
    }

    var standardHighlights = <String>[];
    final gxStd = gx['standardHighlights'] as List<dynamic>?;
    if (gxStd != null && gxStd.isNotEmpty) {
      standardHighlights = gxStd
          .map((e) => e.toString().trim())
          .where((s) => s.isNotEmpty)
          .toList();
    } else if (buildData?['standard_equipment'] is List) {
      standardHighlights = (buildData!['standard_equipment'] as List<dynamic>)
          .take(18)
          .map((s) {
            if (s is Map) {
              return pickStr([s['description'], s['name']]);
            }
            return s.toString().trim();
          })
          .where((s) => s.isNotEmpty)
          .toList();
    }

    final baseMsrp =
        (gx['baseMsrp'] as num?)?.toDouble() ?? (pd['base'] as num?)?.toDouble();
    final totalMsrp = (gx['totalMsrp'] as num?)?.toDouble() ??
        (pd['total'] as num?)?.toDouble();
    final destinationCharge = (gx['destinationCharge'] as num?)?.toDouble() ??
        (pd['freight'] as num?)?.toDouble();
    final optionsTotal = (gx['optionsTotal'] as num?)?.toDouble() ??
        ((baseMsrp != null && totalMsrp != null && totalMsrp >= baseMsrp)
            ? (totalMsrp - baseMsrp - (destinationCharge ?? 0))
                .clamp(0, double.maxFinite)
                .toDouble()
            : null);

    final exteriorColor = pickStr([gx['exteriorColor'], gd['exterior_color']]);
    final interiorColor = pickStr([gx['interiorColor'], gd['interior_color']]);
    final engine = pickStr([gx['engine'], gd['engine'], vpic?['engine']]);
    final transmission = pickStr([
      gx['transmission'],
      gd['transmission'],
      vpic?['transmission'],
    ]);
    final drivetrain = pickStr([
      gx['drivetrain'],
      gd['drivetrain'],
      vpic?['drivetrain'],
    ]);
    final bodyStyle = pickStr([
      gx['bodyStyle'],
      gd['body_style'],
      vpic?['bodyStyle'],
    ]);

    final cityMpg =
        (gx['cityMpg'] as num?)?.round() ?? (fe['city'] as num?)?.round();
    final highwayMpg =
        (gx['highwayMpg'] as num?)?.round() ?? (fe['highway'] as num?)?.round();
    final combinedMpg = (gx['combinedMpg'] as num?)?.round() ??
        (fe['combined'] as num?)?.round();

    final currencyFmt = NumberFormat.currency(symbol: '\$', decimalDigits: 0);
    final defaultSummary = <String>[
      'Official OEM Window Sticker pulled from Auto iPacket StickerPull for $vehicleTitle (VIN $vin).',
      if (totalMsrp != null) 'Total MSRP: ${currencyFmt.format(totalMsrp)}.',
      if (exteriorColor.isNotEmpty) 'Exterior: $exteriorColor.',
      if (engine.isNotEmpty) 'Powertrain: $engine.',
    ].join(' ');

    final salesSummary = pickStr([gx['salesSummary'], defaultSummary]);
    final warrantySummary = pickStr([gx['warrantySummary']]);

    final pdfBase64 = (pdfBytes != null &&
            pdfBytes.isNotEmpty &&
            pdfBytes.length <= 12 * 1024 * 1024)
        ? base64Encode(pdfBytes)
        : '';

    return WindowStickerResult(
      vin: vin,
      portalUrl: stickerPullPortalUrl,
      accountEmail: accountEmail,
      pulledAt: DateTime.now().toUtc().toIso8601String(),
      year: year,
      make: make,
      model: model,
      trim: trim,
      vehicleTitle: vehicleTitle,
      bodyStyle: bodyStyle,
      exteriorColor: exteriorColor,
      interiorColor: interiorColor,
      engine: engine,
      transmission: transmission,
      drivetrain: drivetrain,
      cityMpg: cityMpg,
      highwayMpg: highwayMpg,
      combinedMpg: combinedMpg,
      baseMsrp: baseMsrp,
      optionsTotal: optionsTotal,
      destinationCharge: destinationCharge,
      totalMsrp: totalMsrp,
      packagesAndOptions: packagesAndOptions,
      standardHighlights: standardHighlights,
      warrantySummary: warrantySummary,
      salesSummary: salesSummary,
      pdfUrl: pollPayload['pdf']?.toString() ?? '',
      ipacketViewerUrl: pollPayload['ipacket_viewer']?.toString() ?? '',
      buildDataUrl: pollPayload['build_data']?.toString() ?? '',
      fileName: 'WindowSticker-$vin.pdf',
      pdfSizeBytes: pdfBytes?.length ?? 0,
      pdfBase64: pdfBase64,
      geminiAnalyzed: geminiExtracted != null,
      geminiToolInvoked: geminiToolInvoked,
    );
  }

  static Future<List<RecentWindowStickerEntry>> fetchRemoteStickerHistory({
    String username = defaultUsername,
    String password = defaultPassword,
  }) async {
    if (mockRecentHandler != null) {
      return mockRecentHandler!();
    }

    final cleanUser =
        username.trim().isEmpty ? defaultUsername : username.trim();
    final cleanPass = password.isEmpty ? defaultPassword : password;
    try {
      final token = await _authenticateAutoIPacket(
        username: cleanUser,
        password: cleanPass,
      );
      final uri = Uri.parse(
        '$djApiBaseUrl/v1/sticker-puller/history/?success=true&items_per_page=10&page=1',
      );
      final res = await http
          .get(uri, headers: _buildAipHeaders(token))
          .timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) return const [];
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final rows = data['results'] as List<dynamic>? ?? const [];
      final out = <RecentWindowStickerEntry>[];
      for (final raw in rows) {
        if (raw is! Map) continue;
        final vin = (raw['vin']?.toString() ?? '').trim().toUpperCase();
        if (vin.length != 17) continue;
        final yr = (raw['year'] as num?)?.toInt();
        final mk = (raw['make']?.toString() ?? '').trim();
        final md = (raw['model']?.toString() ?? '').trim();
        final ts = (raw['request_ts']?.toString() ?? '').trim();
        out.add(
          RecentWindowStickerEntry(
            vin: vin,
            year: yr,
            make: mk,
            model: md,
            vehicleTitle: [
              if (yr != null) '$yr',
              if (mk.isNotEmpty) mk,
              if (md.isNotEmpty) md,
            ].join(' '),
            pulledAt: ts.isNotEmpty && !ts.endsWith('Z') ? '${ts}Z' : ts,
          ),
        );
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  /// Uses Android's built-in `PdfRenderer` MethodChannel to rasterize PDF pages into PNG images
  /// for crisp pinch-to-zoom viewing right inside `WindowStickerScreen`.
  static Future<List<Uint8List>> renderPdfPagesOnAndroid(
    Uint8List pdfBytes, {
    int maxPages = 4,
    int targetWidth = 1600,
  }) async {
    if (kIsWeb || pdfBytes.isEmpty) return const [];
    try {
      final rawList = await _nativeStickerChannel.invokeMethod<List<dynamic>>(
        'renderPdfPages',
        <String, dynamic>{
          'pdfBytes': pdfBytes,
          'maxPages': maxPages,
          'targetWidth': targetWidth,
        },
      );
      if (rawList == null) return const [];
      return rawList.whereType<Uint8List>().toList();
    } catch (_) {
      return const [];
    }
  }
}

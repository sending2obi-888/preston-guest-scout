import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../models/models.dart';
import 'local_engine.dart';
import 'widget_sync_service.dart';

class ApiService {
  static String _customBaseUrl = const String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: '',
  );
  static String _authBearerToken = '';

  /// When running as a standalone Android / Googlebook APK with no external API_BASE_URL,
  /// use the built-in LocalScoutEngine so the APK works 100% self-contained on-device.
  static bool get _useLocalOnDeviceEngine => !kIsWeb && _customBaseUrl.isEmpty;

  static String get baseUrl {
    if (_customBaseUrl.isNotEmpty) return _customBaseUrl;
    if (kIsWeb) return '';
    return '';
  }

  static void setCustomBaseUrl(String url) {
    _customBaseUrl = url.trim().replaceAll(RegExp(r'/$'), '');
  }

  static void setAuthBearerToken(String token) {
    _authBearerToken = token.trim();
  }

  static Map<String, String> _headers({bool jsonBody = false}) {
    final map = <String, String>{};
    if (jsonBody) map['Content-Type'] = 'application/json';
    if (_authBearerToken.isNotEmpty) {
      map['Authorization'] = 'Bearer $_authBearerToken';
    }
    return map;
  }

  static String resolveVehiclePhotoUrl(String rawUrl) {
    if (rawUrl.isEmpty) return '';
    if (kIsWeb && rawUrl.contains('prestonmotor.com')) {
      return '$baseUrl/api/image-proxy?url=${Uri.encodeComponent(rawUrl)}';
    }
    return rawUrl;
  }

  static Future<SystemStatus> fetchStatus() async {
    if (_useLocalOnDeviceEngine) {
      return LocalScoutEngine.getStatus();
    }
    final res = await http.get(
      Uri.parse('$baseUrl/api/status'),
      headers: _headers(),
    );
    if (res.statusCode != 200) {
      throw Exception('Failed to load system status (${res.statusCode})');
    }
    return SystemStatus.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
  }

  static Future<List<GuestProfile>> fetchAllGuests() async {
    if (_useLocalOnDeviceEngine) {
      return LocalScoutEngine.getAllGuests();
    }
    final res = await http.get(
      Uri.parse('$baseUrl/api/guests'),
      headers: _headers(),
    );
    if (res.statusCode != 200) {
      throw Exception('Failed to load guests (${res.statusCode})');
    }
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    final list = (data['guests'] as List<dynamic>? ?? [])
        .map((e) => GuestProfile.fromJson(e as Map<String, dynamic>))
        .toList();

    final recentTen = list.take(10).map((g) {
      return WidgetGuestEntry(
        id: g.id,
        name: g.name,
        targetSummary: g.targetVehicleLabel,
        matchCount: g.matchCount,
        createdAt: g.createdAt,
      );
    }).toList();
    await WidgetSyncService.syncRecentTenGuests(recentTen);

    return list;
  }

  static Future<List<WidgetGuestEntry>> fetchLauncherWidgetGuests() async {
    if (_useLocalOnDeviceEngine) {
      return LocalScoutEngine.getRecentTenWidgetGuests();
    }
    final res = await http.get(
      Uri.parse('$baseUrl/api/widget/recent-guests'),
      headers: _headers(),
    );
    if (res.statusCode != 200) {
      throw Exception('Failed to load widget guests (${res.statusCode})');
    }
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    final entries = (data['guests'] as List<dynamic>? ?? [])
        .take(10)
        .map((e) => WidgetGuestEntry.fromJson(e as Map<String, dynamic>))
        .toList();
    await WidgetSyncService.syncRecentTenGuests(entries);
    return entries;
  }

  static Future<({GuestProfile guest, int matchesFound, String summary})>
      createGuest({
    required String name,
    String phone = '',
    String email = '',
    String condition = 'Any',
    int? minYear,
    int? maxYear,
    String make = '',
    String model = '',
    String trim = '',
    double? maxPrice,
    int? maxMileage,
    String drivetrain = 'Any',
    String exteriorColor = '',
    List<String> features = const [],
    String notes = '',
  }) async {
    if (_useLocalOnDeviceEngine) {
      return LocalScoutEngine.createGuest(
        name: name,
        phone: phone,
        email: email,
        condition: condition,
        minYear: minYear,
        maxYear: maxYear,
        make: make,
        model: model,
        trim: trim,
        maxPrice: maxPrice,
        maxMileage: maxMileage,
        drivetrain: drivetrain,
        exteriorColor: exteriorColor,
        features: features,
        notes: notes,
      );
    }

    final res = await http.post(
      Uri.parse('$baseUrl/api/guests'),
      headers: _headers(jsonBody: true),
      body: jsonEncode({
        'name': name,
        'phone': phone,
        'email': email,
        'condition': condition,
        'minYear': minYear,
        'maxYear': maxYear,
        'make': make,
        'model': model,
        'trim': trim,
        'maxPrice': maxPrice,
        'maxMileage': maxMileage,
        'drivetrain': drivetrain,
        'exteriorColor': exteriorColor,
        'features': features,
        'notes': notes,
        'runImmediateSearch': true,
      }),
    );

    if (res.statusCode != 201 && res.statusCode != 200) {
      final err = jsonDecode(res.body);
      throw Exception(err['error'] ?? 'Failed to save guest');
    }

    final data = jsonDecode(res.body) as Map<String, dynamic>;
    final createdGuest =
        GuestProfile.fromJson(data['guest'] as Map<String, dynamic>);
    final searchRes = data['searchResult'] as Map<String, dynamic>?;

    await fetchLauncherWidgetGuests();

    return (
      guest: createdGuest,
      matchesFound:
          (searchRes?['matchesFound'] as num?)?.toInt() ?? createdGuest.matchCount,
      summary: searchRes?['summary']?.toString() ??
          'Added to 7:30 AM & 2:00 PM search schedule.',
    );
  }

  static Future<({GuestProfile guest, List<VehicleMatch> matches})>
      fetchGuestWithMatches(String guestId) async {
    if (_useLocalOnDeviceEngine) {
      return LocalScoutEngine.getGuestWithMatches(guestId);
    }
    final res = await http.get(
      Uri.parse('$baseUrl/api/guests/${Uri.encodeComponent(guestId)}/matches'),
      headers: _headers(),
    );
    if (res.statusCode != 200) {
      throw Exception('Guest not found (${res.statusCode})');
    }
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    return (
      guest: GuestProfile.fromJson(data['guest'] as Map<String, dynamic>),
      matches: (data['matches'] as List<dynamic>? ?? [])
          .map((e) => VehicleMatch.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }

  static Future<({GuestProfile guest, List<VehicleMatch> matches, String summary})>
      triggerGuestSearch(String guestId) async {
    if (_useLocalOnDeviceEngine) {
      return LocalScoutEngine.runSearchForSingleGuest(guestId);
    }
    final res = await http.post(
      Uri.parse('$baseUrl/api/guests/${Uri.encodeComponent(guestId)}/search'),
      headers: _headers(),
    );
    if (res.statusCode != 200) {
      throw Exception('Search failed (${res.statusCode})');
    }
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    final result = data['result'] as Map<String, dynamic>?;
    return (
      guest: GuestProfile.fromJson(data['guest'] as Map<String, dynamic>),
      matches: (data['matches'] as List<dynamic>? ?? [])
          .map((e) => VehicleMatch.fromJson(e as Map<String, dynamic>))
          .toList(),
      summary: result?['summary']?.toString() ??
          'Completed live search on prestonmotor.com.',
    );
  }

  static Future<void> triggerSearchAll() async {
    if (_useLocalOnDeviceEngine) {
      await LocalScoutEngine.runSearchForAllGuests(
          slotLabel: 'Manual All-Guests Search');
      return;
    }
    final res = await http.post(
      Uri.parse('$baseUrl/api/search-all'),
      headers: _headers(),
    );
    if (res.statusCode != 200) {
      throw Exception('Batch search failed (${res.statusCode})');
    }
  }

  static Future<({GuestProfile guest, List<VehicleMatch> matches, String summary})>
      addVehicleToGuest({
    required String guestId,
    String condition = 'Any',
    int? minYear,
    int? maxYear,
    String make = '',
    String model = '',
    String trim = '',
    double? maxPrice,
    int? maxMileage,
    String drivetrain = 'Any',
    String exteriorColor = '',
    List<String> features = const [],
    String notes = '',
  }) async {
    if (_useLocalOnDeviceEngine) {
      return LocalScoutEngine.addVehicleTargetToGuest(
        guestId: guestId,
        condition: condition,
        minYear: minYear,
        maxYear: maxYear,
        make: make,
        model: model,
        trim: trim,
        maxPrice: maxPrice,
        maxMileage: maxMileage,
        drivetrain: drivetrain,
        exteriorColor: exteriorColor,
        features: features,
        notes: notes,
      );
    }

    final res = await http.post(
      Uri.parse('$baseUrl/api/guests/${Uri.encodeComponent(guestId)}/vehicles'),
      headers: _headers(jsonBody: true),
      body: jsonEncode({
        'condition': condition,
        'minYear': minYear,
        'maxYear': maxYear,
        'make': make,
        'model': model,
        'trim': trim,
        'maxPrice': maxPrice,
        'maxMileage': maxMileage,
        'drivetrain': drivetrain,
        'exteriorColor': exteriorColor,
        'features': features,
        'notes': notes,
        'runImmediateSearch': true,
      }),
    );

    if (res.statusCode != 201 && res.statusCode != 200) {
      final err = jsonDecode(res.body);
      throw Exception(err['error'] ?? 'Failed to add vehicle to guest');
    }

    final data = jsonDecode(res.body) as Map<String, dynamic>;
    final result = data['result'] as Map<String, dynamic>?;
    await fetchLauncherWidgetGuests();

    return (
      guest: GuestProfile.fromJson(data['guest'] as Map<String, dynamic>),
      matches: (data['matches'] as List<dynamic>? ?? [])
          .map((e) => VehicleMatch.fromJson(e as Map<String, dynamic>))
          .toList(),
      summary: result?['summary']?.toString() ??
          'Added vehicle criteria and searched prestonmotor.com.',
    );
  }

  static Future<({GuestProfile guest, List<VehicleMatch> matches})>
      removeVehicleFromGuest(String guestId, String targetId) async {
    if (_useLocalOnDeviceEngine) {
      return LocalScoutEngine.removeVehicleTargetFromGuest(guestId, targetId);
    }

    final res = await http.delete(
      Uri.parse(
        '$baseUrl/api/guests/${Uri.encodeComponent(guestId)}/vehicles/${Uri.encodeComponent(targetId)}',
      ),
      headers: _headers(),
    );

    if (res.statusCode != 200) {
      final err = jsonDecode(res.body);
      throw Exception(err['error'] ?? 'Failed to remove vehicle target');
    }

    final data = jsonDecode(res.body) as Map<String, dynamic>;
    await fetchLauncherWidgetGuests();

    return (
      guest: GuestProfile.fromJson(data['guest'] as Map<String, dynamic>),
      matches: (data['matches'] as List<dynamic>? ?? [])
          .map((e) => VehicleMatch.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }

  static Future<void> deleteGuest(String guestId) async {
    if (_useLocalOnDeviceEngine) {
      await LocalScoutEngine.deleteGuest(guestId);
      return;
    }
    final res = await http.delete(
      Uri.parse('$baseUrl/api/guests/${Uri.encodeComponent(guestId)}'),
      headers: _headers(),
    );
    if (res.statusCode != 200) {
      throw Exception('Delete failed (${res.statusCode})');
    }
    await fetchLauncherWidgetGuests();
  }

  static Future<Map<String, dynamic>> fetchSettings() async {
    if (_useLocalOnDeviceEngine) {
      return LocalScoutEngine.getSettings();
    }
    final res = await http.get(
      Uri.parse('$baseUrl/api/settings'),
      headers: _headers(),
    );
    if (res.statusCode != 200) {
      throw Exception('Failed to load settings');
    }
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  static Future<void> updateSettings({
    String? geminiApiKey,
    String? geminiModel,
    String? timezone,
    String? googleOAuthClientId,
  }) async {
    if (_useLocalOnDeviceEngine) {
      await LocalScoutEngine.updateSettings(
        geminiApiKey: geminiApiKey,
        geminiModel: geminiModel,
        timezone: timezone,
        googleOAuthClientId: googleOAuthClientId,
      );
      return;
    }
    final payload = <String, dynamic>{};
    if (geminiApiKey != null) payload['geminiApiKey'] = geminiApiKey;
    if (geminiModel != null) payload['geminiModel'] = geminiModel;
    if (timezone != null) payload['timezone'] = timezone;
    if (googleOAuthClientId != null) {
      payload['googleOAuthClientId'] = googleOAuthClientId;
    }

    final res = await http.put(
      Uri.parse('$baseUrl/api/settings'),
      headers: _headers(jsonBody: true),
      body: jsonEncode(payload),
    );
    if (res.statusCode != 200) {
      throw Exception('Failed to save settings');
    }
  }
}

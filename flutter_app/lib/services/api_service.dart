import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../models/models.dart';
import 'calendar_service.dart';
import 'document_picker_service.dart';
import 'local_engine.dart';
import 'match_notification_service.dart';
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
    String doors = '',
    String bedLength = '',
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
        doors: doors,
        bedLength: bedLength,
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
        'doors': doors,
        'bedLength': bedLength,
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
    await fetchCalendarStatus();

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

  static Future<
          ({GuestProfile guest, List<VehicleMatch> matches, VehicleMatch match})>
      setMatchSelectedCandidate({
    required String guestId,
    required String vin,
    required bool selected,
  }) async {
    if (_useLocalOnDeviceEngine) {
      return LocalScoutEngine.setMatchSelectedCandidate(
        guestId: guestId,
        vin: vin,
        selected: selected,
      );
    }
    final res = await http.patch(
      Uri.parse(
        '$baseUrl/api/guests/${Uri.encodeComponent(guestId)}/matches/${Uri.encodeComponent(vin)}',
      ),
      headers: _headers(jsonBody: true),
      body: jsonEncode({'selected': selected}),
    );
    if (res.statusCode != 200) {
      final err = jsonDecode(res.body);
      throw Exception(err['error'] ?? 'Failed to update selected candidate');
    }
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    return (
      guest: GuestProfile.fromJson(data['guest'] as Map<String, dynamic>),
      matches: (data['matches'] as List<dynamic>? ?? [])
          .map((e) => VehicleMatch.fromJson(e as Map<String, dynamic>))
          .toList(),
      match: VehicleMatch.fromJson(data['match'] as Map<String, dynamic>),
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
    await fetchNotifications();
    await fetchCalendarStatus();
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
    await fetchNotifications();
    await fetchCalendarStatus();
  }

  static Future<
      ({
        bool verified,
        int removedCount,
        List<String> removedVins,
      })> verifyWebsiteInventory({bool force = false}) async {
    if (_useLocalOnDeviceEngine) {
      return LocalScoutEngine.verifyStoredMatchesOnWebsite(force: force);
    }
    final res = await http.post(
      Uri.parse('$baseUrl/api/guests/verify-website'),
      headers: _headers(jsonBody: true),
      body: jsonEncode({'force': force}),
    );
    if (res.statusCode != 200) {
      return (verified: false, removedCount: 0, removedVins: const <String>[]);
    }
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    return (
      verified: data['verified'] == true,
      removedCount: (data['removedCount'] as num?)?.toInt() ?? 0,
      removedVins: (data['removedVins'] as List<dynamic>? ?? const [])
          .map((e) => e.toString())
          .toList(),
    );
  }

  static Future<
      ({
        bool verified,
        int removedCount,
        List<String> removedVins,
        GuestProfile guest,
        List<VehicleMatch> matches,
      })> verifyGuestWebsiteInventory(String guestId) async {
    if (_useLocalOnDeviceEngine) {
      final verifyRes = await LocalScoutEngine.verifyStoredMatchesOnWebsite(
        guestId: guestId,
        force: true,
      );
      final latest = await LocalScoutEngine.getGuestWithMatches(guestId);
      return (
        verified: verifyRes.verified,
        removedCount: verifyRes.removedCount,
        removedVins: verifyRes.removedVins,
        guest: latest.guest,
        matches: latest.matches,
      );
    }
    final res = await http.post(
      Uri.parse(
        '$baseUrl/api/guests/${Uri.encodeComponent(guestId)}/verify-website',
      ),
      headers: _headers(jsonBody: true),
      body: jsonEncode(const <String, dynamic>{}),
    );
    if (res.statusCode != 200) {
      throw Exception('Failed to verify website inventory (${res.statusCode})');
    }
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    return (
      verified: data['verified'] == true,
      removedCount: (data['removedCount'] as num?)?.toInt() ?? 0,
      removedVins: (data['removedVins'] as List<dynamic>? ?? const [])
          .map((e) => e.toString())
          .toList(),
      guest: GuestProfile.fromJson(data['guest'] as Map<String, dynamic>),
      matches: (data['matches'] as List<dynamic>? ?? [])
          .map((e) => VehicleMatch.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
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
    String doors = '',
    String bedLength = '',
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
        doors: doors,
        bedLength: bedLength,
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
        'doors': doors,
        'bedLength': bedLength,
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
    await fetchCalendarStatus();

    return (
      guest: GuestProfile.fromJson(data['guest'] as Map<String, dynamic>),
      matches: (data['matches'] as List<dynamic>? ?? [])
          .map((e) => VehicleMatch.fromJson(e as Map<String, dynamic>))
          .toList(),
      summary: result?['summary']?.toString() ??
          'Added vehicle criteria and searched prestonmotor.com.',
    );
  }

  static Future<({GuestProfile guest, List<VehicleMatch> matches, String summary})>
      updateVehicleOnGuest({
    required String guestId,
    required String targetId,
    String condition = 'Any',
    int? minYear,
    int? maxYear,
    String make = '',
    String model = '',
    String trim = '',
    String doors = '',
    String bedLength = '',
    double? maxPrice,
    int? maxMileage,
    String drivetrain = 'Any',
    String exteriorColor = '',
    List<String> features = const [],
    String notes = '',
  }) async {
    if (_useLocalOnDeviceEngine) {
      return LocalScoutEngine.updateVehicleTargetOnGuest(
        guestId: guestId,
        targetId: targetId,
        condition: condition,
        minYear: minYear,
        maxYear: maxYear,
        make: make,
        model: model,
        trim: trim,
        doors: doors,
        bedLength: bedLength,
        maxPrice: maxPrice,
        maxMileage: maxMileage,
        drivetrain: drivetrain,
        exteriorColor: exteriorColor,
        features: features,
        notes: notes,
      );
    }

    final res = await http.put(
      Uri.parse(
        '$baseUrl/api/guests/${Uri.encodeComponent(guestId)}/vehicles/${Uri.encodeComponent(targetId)}',
      ),
      headers: _headers(jsonBody: true),
      body: jsonEncode({
        'condition': condition,
        'minYear': minYear,
        'maxYear': maxYear,
        'make': make,
        'model': model,
        'trim': trim,
        'doors': doors,
        'bedLength': bedLength,
        'maxPrice': maxPrice,
        'maxMileage': maxMileage,
        'drivetrain': drivetrain,
        'exteriorColor': exteriorColor,
        'features': features,
        'notes': notes,
        'runImmediateSearch': true,
      }),
    );

    if (res.statusCode != 200) {
      final err = jsonDecode(res.body);
      throw Exception(err['error'] ?? 'Failed to update search criteria');
    }

    final data = jsonDecode(res.body) as Map<String, dynamic>;
    final result = data['result'] as Map<String, dynamic>?;
    await fetchLauncherWidgetGuests();
    await fetchCalendarStatus();

    return (
      guest: GuestProfile.fromJson(data['guest'] as Map<String, dynamic>),
      matches: (data['matches'] as List<dynamic>? ?? [])
          .map((e) => VehicleMatch.fromJson(e as Map<String, dynamic>))
          .toList(),
      summary: result?['summary']?.toString() ??
          'Updated search criteria and re-searched prestonmotor.com.',
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

  static Future<GuestProfile> updateGuestContactInfo({
    required String guestId,
    required String name,
    String phone = '',
    String email = '',
  }) async {
    if (_useLocalOnDeviceEngine) {
      return LocalScoutEngine.updateGuestContactInfo(
        guestId: guestId,
        name: name,
        phone: phone,
        email: email,
      );
    }

    final res = await http.patch(
      Uri.parse('$baseUrl/api/guests/${Uri.encodeComponent(guestId)}'),
      headers: _headers(jsonBody: true),
      body: jsonEncode({
        'name': name,
        'phone': phone,
        'email': email,
      }),
    );

    if (res.statusCode != 200) {
      final err = jsonDecode(res.body);
      throw Exception(err['error'] ?? 'Failed to update client contact info');
    }

    final data = jsonDecode(res.body) as Map<String, dynamic>;
    final updated = GuestProfile.fromJson(data['guest'] as Map<String, dynamic>);
    await fetchLauncherWidgetGuests();
    await fetchNotifications();
    await fetchCalendarStatus();
    return updated;
  }

  static Future<GuestProfile> addGuestNote({
    required String guestId,
    required String text,
  }) async {
    if (_useLocalOnDeviceEngine) {
      return LocalScoutEngine.addGuestNote(guestId: guestId, text: text);
    }

    final res = await http.post(
      Uri.parse('$baseUrl/api/guests/${Uri.encodeComponent(guestId)}/notes'),
      headers: _headers(jsonBody: true),
      body: jsonEncode({'text': text}),
    );

    if (res.statusCode != 201 && res.statusCode != 200) {
      final err = jsonDecode(res.body);
      throw Exception(err['error'] ?? 'Failed to save client note');
    }

    final data = jsonDecode(res.body) as Map<String, dynamic>;
    return GuestProfile.fromJson(data['guest'] as Map<String, dynamic>);
  }

  static Future<GuestProfile> deleteGuestNote({
    required String guestId,
    required String noteId,
  }) async {
    if (_useLocalOnDeviceEngine) {
      return LocalScoutEngine.deleteGuestNote(guestId: guestId, noteId: noteId);
    }

    final res = await http.delete(
      Uri.parse(
        '$baseUrl/api/guests/${Uri.encodeComponent(guestId)}/notes/${Uri.encodeComponent(noteId)}',
      ),
      headers: _headers(),
    );

    if (res.statusCode != 200) {
      final err = jsonDecode(res.body);
      throw Exception(err['error'] ?? 'Failed to delete client note');
    }

    final data = jsonDecode(res.body) as Map<String, dynamic>;
    return GuestProfile.fromJson(data['guest'] as Map<String, dynamic>);
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
    await fetchCalendarStatus();
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

  static Future<List<MatchAlertNotification>> fetchNotifications() async {
    if (_useLocalOnDeviceEngine) {
      return LocalScoutEngine.getNotifications();
    }
    try {
      final res = await http.get(
        Uri.parse('$baseUrl/api/notifications'),
        headers: _headers(),
      );
      if (res.statusCode != 200) {
        return MatchNotificationService.instance.notifications;
      }
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final list = (data['notifications'] as List<dynamic>? ?? [])
          .map(
              (e) => MatchAlertNotification.fromJson(e as Map<String, dynamic>))
          .toList();
      await MatchNotificationService.instance.syncFromServerList(list);
      return list;
    } catch (_) {
      return MatchNotificationService.instance.notifications;
    }
  }

  static Future<void> markAllNotificationsRead() async {
    if (_useLocalOnDeviceEngine) {
      await LocalScoutEngine.markAllNotificationsRead();
      return;
    }
    MatchNotificationService.instance.markAllReadLocally();
    try {
      await http.post(
        Uri.parse('$baseUrl/api/notifications/mark-read'),
        headers: _headers(jsonBody: true),
        body: jsonEncode(<String, dynamic>{}),
      );
    } catch (_) {}
  }

  static Future<void> clearNotifications() async {
    if (_useLocalOnDeviceEngine) {
      await LocalScoutEngine.clearNotifications();
      return;
    }
    MatchNotificationService.instance.clearAllLocally();
    try {
      await http.delete(
        Uri.parse('$baseUrl/api/notifications'),
        headers: _headers(),
      );
    } catch (_) {}
  }

  static Future<List<CalendarCallEvent>> fetchCalendarStatus() async {
    if (_useLocalOnDeviceEngine) {
      return LocalScoutEngine.getCalendarEvents();
    }
    try {
      final res = await http.get(
        Uri.parse('$baseUrl/api/calendar/status'),
        headers: _headers(),
      );
      if (res.statusCode != 200) {
        return CalendarService.instance.events;
      }
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      CalendarService.instance.syncFromServerStatus(data);
      return CalendarService.instance.events;
    } catch (_) {
      return CalendarService.instance.events;
    }
  }

  static Future<bool> setCalendarPermission(
    bool granted, {
    bool? dismissed,
    String accessToken = '',
  }) async {
    if (_useLocalOnDeviceEngine) {
      await LocalScoutEngine.saveCalendarPermissionState(
        permissionGranted: granted,
        promptDismissed: dismissed ?? (granted ? true : false),
      );
      return granted;
    }
    try {
      final payload = <String, dynamic>{
        'granted': granted,
        'dismissed': ?dismissed,
        if (accessToken.trim().isNotEmpty) 'accessToken': accessToken.trim(),
      };
      final res = await http.post(
        Uri.parse('$baseUrl/api/calendar/permission'),
        headers: _headers(jsonBody: true),
        body: jsonEncode(payload),
      );
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        CalendarService.instance.syncFromServerStatus(data);
        return CalendarService.instance.permissionGranted;
      }
    } catch (_) {}
    return false;
  }

  static Future<void> clearCalendarEvents() async {
    if (_useLocalOnDeviceEngine) {
      await LocalScoutEngine.clearCalendarEvents();
      return;
    }
    CalendarService.instance.clearEventsLocally();
    try {
      await http.delete(
        Uri.parse('$baseUrl/api/calendar/events'),
        headers: _headers(),
      );
    } catch (_) {}
  }

  static Future<List<BackupEntry>> fetchBackups() async {
    if (_useLocalOnDeviceEngine) {
      return LocalScoutEngine.getBackups();
    }
    final res = await http.get(
      Uri.parse('$baseUrl/api/backups'),
      headers: _headers(),
    );
    if (res.statusCode != 200) {
      throw Exception('Failed to load backups (${res.statusCode})');
    }
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    return (data['backups'] as List<dynamic>? ?? [])
        .whereType<Map>()
        .map((e) => BackupEntry.fromJson(Map<String, dynamic>.from(e)))
        .take(5)
        .toList();
  }

  static Future<List<BackupEntry>> createManualBackup({
    String label = 'Manual Backup',
  }) async {
    if (_useLocalOnDeviceEngine) {
      return LocalScoutEngine.createManualBackup(label: label);
    }
    final res = await http.post(
      Uri.parse('$baseUrl/api/backups'),
      headers: _headers(jsonBody: true),
      body: jsonEncode(<String, dynamic>{'label': label}),
    );
    if (res.statusCode != 201 && res.statusCode != 200) {
      final err = jsonDecode(res.body);
      throw Exception(err['error'] ?? 'Failed to create backup');
    }
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    return (data['backups'] as List<dynamic>? ?? [])
        .whereType<Map>()
        .map((e) => BackupEntry.fromJson(Map<String, dynamic>.from(e)))
        .take(5)
        .toList();
  }

  static Future<BackupConflictPreview> inspectBackupConflicts(
    String backupId,
  ) async {
    if (_useLocalOnDeviceEngine) {
      return LocalScoutEngine.inspectBackupConflicts(backupId);
    }
    final res = await http.get(
      Uri.parse(
        '$baseUrl/api/backups/${Uri.encodeComponent(backupId)}/check-conflicts',
      ),
      headers: _headers(),
    );
    if (res.statusCode != 200) {
      final err = jsonDecode(res.body);
      throw Exception(err['error'] ?? 'Failed to inspect backup conflicts');
    }
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    return BackupConflictPreview.fromJson(data);
  }

  static Future<BackupRestoreResult> restoreBackup(
    String backupId, {
    BackupConflictResolution? resolution,
  }) async {
    if (_useLocalOnDeviceEngine) {
      return LocalScoutEngine.restoreBackup(backupId, resolution: resolution);
    }
    final res = await http.post(
      Uri.parse(
        '$baseUrl/api/backups/${Uri.encodeComponent(backupId)}/restore',
      ),
      headers: _headers(jsonBody: true),
      body: jsonEncode(<String, dynamic>{
        'resolution': resolution?.wireValue,
      }),
    );
    if (res.statusCode != 200) {
      final err = jsonDecode(res.body);
      throw Exception(err['error'] ?? 'Failed to restore backup');
    }
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    await fetchLauncherWidgetGuests();
    return BackupRestoreResult.fromJson(
      Map<String, dynamic>.from(data['result'] as Map? ?? const {}),
    );
  }

  static Future<List<RecentVinRecallEntry>> fetchRecentVinRecallChecks() async {
    if (_useLocalOnDeviceEngine) {
      return LocalScoutEngine.getRecentVinRecallChecks();
    }
    try {
      final res = await http.get(
        Uri.parse('$baseUrl/api/recalls/recent'),
        headers: _headers(),
      );
      if (res.statusCode != 200) return const [];
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      return (data['recent'] as List<dynamic>? ?? [])
          .whereType<Map>()
          .map(
              (e) => RecentVinRecallEntry.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  static Future<({VinRecallCheckResult result, List<RecentVinRecallEntry> recent})>
      checkVinRecalls(String vin) async {
    if (_useLocalOnDeviceEngine) {
      return LocalScoutEngine.checkVinRecalls(vin);
    }
    final res = await http.post(
      Uri.parse('$baseUrl/api/recalls/check'),
      headers: _headers(jsonBody: true),
      body: jsonEncode(<String, dynamic>{'vin': vin}),
    );
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    if (res.statusCode != 200) {
      throw Exception(
        data['error']?.toString() ??
            'Unable to check recalls on www.nhtsa.gov/recalls (${res.statusCode})',
      );
    }
    final result = VinRecallCheckResult.fromJson(
      Map<String, dynamic>.from(data['result'] as Map? ?? const {}),
    );
    final recent = (data['recent'] as List<dynamic>? ?? [])
        .whereType<Map>()
        .map((e) => RecentVinRecallEntry.fromJson(Map<String, dynamic>.from(e)))
        .toList();
    return (result: result, recent: recent);
  }

  static Future<({VinRecallCheckResult result, List<RecentVinRecallEntry> recent})>
      updateVinRecallStatus({
    required String vin,
    required String campaignNumber,
    required String status,
  }) async {
    if (_useLocalOnDeviceEngine) {
      return LocalScoutEngine.updateVinRecallStatus(
        vin: vin,
        campaignNumber: campaignNumber,
        status: status,
      );
    }
    final res = await http.post(
      Uri.parse('$baseUrl/api/recalls/status'),
      headers: _headers(jsonBody: true),
      body: jsonEncode(<String, dynamic>{
        'vin': vin,
        'campaignNumber': campaignNumber,
        'status': status,
      }),
    );
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    if (res.statusCode != 200) {
      throw Exception(
        data['error']?.toString() ??
            'Unable to update recall status (${res.statusCode})',
      );
    }
    final result = VinRecallCheckResult.fromJson(
      Map<String, dynamic>.from(data['result'] as Map? ?? const {}),
    );
    final recent = (data['recent'] as List<dynamic>? ?? [])
        .whereType<Map>()
        .map((e) => RecentVinRecallEntry.fromJson(Map<String, dynamic>.from(e)))
        .toList();
    return (result: result, recent: recent);
  }

  static Future<NautilusHybridRecallScanResult>
      fetchRecallFree2026NautilusHybrids({
    bool forceRefresh = false,
  }) async {
    if (_useLocalOnDeviceEngine) {
      return LocalScoutEngine.scan2026NautilusHybridsRecallFree(
        forceRefresh: forceRefresh,
      );
    }
    final uri = Uri.parse(
      '$baseUrl/api/recalls/nautilus-hybrids${forceRefresh ? '?refresh=1' : ''}',
    );
    final res = await http.get(uri, headers: _headers());
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    if (res.statusCode != 200) {
      throw Exception(
        data['error']?.toString() ??
            'Unable to scan 2026 Lincoln Nautilus Hybrid recall-free inventory (${res.statusCode})',
      );
    }
    return NautilusHybridRecallScanResult.fromJson(data);
  }

  static Future<DocumentEquivalentSearchResult>
      findEquivalentVehiclesFromDocument({
    required PickedDocumentFile document,
    String extraNotes = '',
  }) async {
    if (_useLocalOnDeviceEngine) {
      return LocalScoutEngine.findEquivalentVehiclesFromDocument(
        document: document,
        extraNotes: extraNotes,
      );
    }
    final res = await http.post(
      Uri.parse('$baseUrl/api/intake/document-equivalents'),
      headers: _headers(jsonBody: true),
      body: jsonEncode(<String, dynamic>{
        'fileName': document.fileName,
        'mimeType': document.mimeType,
        'base64Data': document.base64Data,
        'extraNotes': extraNotes,
      }),
    );
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    if (res.statusCode != 200) {
      throw Exception(
        data['error']?.toString() ??
            'Unable to analyze document for closest prestonmotor.com vehicles (${res.statusCode})',
      );
    }
    return DocumentEquivalentSearchResult.fromJson(
      Map<String, dynamic>.from(data['result'] as Map? ?? const {}),
    );
  }

  static Future<
      ({
        String portalUrl,
        String accountEmail,
        List<RecentWindowStickerEntry> recent,
      })> fetchRecentWindowStickers() async {
    if (_useLocalOnDeviceEngine) {
      return LocalScoutEngine.getRecentWindowStickers();
    }
    final res = await http.get(
      Uri.parse('$baseUrl/api/window-sticker/recent'),
      headers: _headers(),
    );
    if (res.statusCode != 200) {
      return (
        portalUrl: 'https://dpapp.autoipacket.com/stickerpull',
        accountEmail: 'oonyeador@prestonmotor.com',
        recent: const <RecentWindowStickerEntry>[],
      );
    }
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    final recent = (data['recent'] as List<dynamic>? ?? const [])
        .whereType<Map>()
        .map(
          (e) => RecentWindowStickerEntry.fromJson(
            Map<String, dynamic>.from(e),
          ),
        )
        .toList();
    return (
      portalUrl: data['portalUrl']?.toString() ??
          'https://dpapp.autoipacket.com/stickerpull',
      accountEmail:
          data['accountEmail']?.toString() ?? 'oonyeador@prestonmotor.com',
      recent: recent,
    );
  }

  static Future<
      ({
        WindowStickerResult result,
        List<RecentWindowStickerEntry> recent,
      })> pullWindowSticker(String vin) async {
    if (_useLocalOnDeviceEngine) {
      return LocalScoutEngine.pullWindowSticker(vin);
    }
    final res = await http.post(
      Uri.parse('$baseUrl/api/window-sticker/pull'),
      headers: _headers(jsonBody: true),
      body: jsonEncode(<String, dynamic>{'vin': vin}),
    );
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    if (res.statusCode != 200) {
      throw Exception(
        data['error']?.toString() ??
            'Unable to pull window sticker from Auto iPacket (${res.statusCode})',
      );
    }
    final rawResult =
        Map<String, dynamic>.from(data['result'] as Map? ?? const {});
    final inlineRel = rawResult['inlineServerPdfUrl']?.toString() ?? '';
    if (inlineRel.startsWith('/') && baseUrl.isNotEmpty) {
      rawResult['inlineServerPdfUrl'] = '$baseUrl$inlineRel';
    }
    final result = WindowStickerResult.fromJson(rawResult);
    final recent = (data['recent'] as List<dynamic>? ?? const [])
        .whereType<Map>()
        .map(
          (e) => RecentWindowStickerEntry.fromJson(
            Map<String, dynamic>.from(e),
          ),
        )
        .toList();
    return (result: result, recent: recent);
  }

  static Future<({String portalUrl, String username})>
      saveStickerPullCredentials({
    required String username,
    required String password,
  }) async {
    if (_useLocalOnDeviceEngine) {
      return LocalScoutEngine.saveStickerPullCredentials(
        username: username,
        password: password,
      );
    }
    final res = await http.put(
      Uri.parse('$baseUrl/api/window-sticker/credentials'),
      headers: _headers(jsonBody: true),
      body: jsonEncode(<String, dynamic>{
        'username': username,
        'password': password,
      }),
    );
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    if (res.statusCode != 200) {
      throw Exception(
        data['error']?.toString() ??
            'Unable to save Auto iPacket credentials (${res.statusCode})',
      );
    }
    return (
      portalUrl: data['portalUrl']?.toString() ??
          'https://dpapp.autoipacket.com/stickerpull',
      username: data['username']?.toString() ?? username,
    );
  }
}

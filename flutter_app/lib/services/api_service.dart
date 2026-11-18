import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../models/models.dart';
import 'calendar_service.dart';
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
}

import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import '../models/models.dart';
import 'calendar_service.dart';
import 'document_equivalent_service.dart';
import 'document_picker_service.dart';
import 'match_notification_service.dart';
import 'natural_language_parser.dart';
import 'nhtsa_recall_service.dart';
import 'widget_sync_service.dart';

/// Self-contained on-device engine for the Android / Googlebook APK.
/// Persists unlimited guests & matches locally, queries ALL pages of live prestonmotor.com
/// inventory, invokes the Google Gemini API directly, and enforces twice-daily (7:30 AM & 2:00 PM) scans.
class LocalScoutEngine {
  static const MethodChannel _channel =
      MethodChannel('com.prestonmotor.scout/launcher_widget');
  static const String _prestonHost = 'www.prestonmotor.com';
  static const String _prestonBase = 'https://www.prestonmotor.com';

  static bool _initialized = false;
  static bool _isRunningBatch = false;
  static Timer? _scheduleTimer;

  /// Invoked automatically whenever local guests, matches, or settings mutate
  /// so GoogleDriveSyncService saves the latest search state to Google Drive.
  static void Function()? onDataMutatedForCloudSave;

  static const int maxBackups = 5;

  static List<Map<String, dynamic>> _guests = [];
  static List<Map<String, dynamic>> _matches = [];
  static List<Map<String, dynamic>> _notifications = [];
  static List<Map<String, dynamic>> _calendarEvents = [];
  static List<Map<String, dynamic>> _backups = [];
  static List<Map<String, dynamic>> _recallChecks = [];
  static Map<String, String> _recallStatusOverrides = {};
  static Map<String, Map<String, dynamic>> _recallResultsByVin = {};
  static Map<String, String> _deletedGuestIds = {};
  static Map<String, dynamic> _settings = {
    'geminiApiKey': '',
    'geminiModel': 'gemini-2.5-flash',
    'timezone': 'America/New_York',
    'googleOAuthClientId': '',
    'googleOAuthClientSecret': '',
    'driveSyncFileId': '',
    'calendarPermissionGranted': false,
    'calendarPromptDismissed': false,
    'completedSlots': <String>[],
  };

  static Future<void> ensureInitialized() async {
    if (_initialized || kIsWeb) return;
    _initialized = true;

    try {
      final raw = await _channel.invokeMethod<String>('readLocalStore');
      if (raw != null && raw.trim().isNotEmpty) {
        final decoded = jsonDecode(raw) as Map<String, dynamic>;
        final hadSchedKey = (decoded['guests'] as List<dynamic>? ?? []).any(
          (g) => g is Map && g.containsKey('scheduledCallVins'),
        );
        _guests = (decoded['guests'] as List<dynamic>? ?? [])
            .map((e) => _normalizeGuestMap(Map<String, dynamic>.from(e as Map)))
            .toList();
        _matches = (decoded['matches'] as List<dynamic>? ?? [])
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList();
        if (!hadSchedKey && _matches.isNotEmpty) {
          for (var i = 0; i < _guests.length; i++) {
            final gid = _guests[i]['id']?.toString() ?? '';
            final vins = _matches
                .where((m) => m['guestId']?.toString() == gid)
                .map((m) => m['vin']?.toString() ?? '')
                .where((v) => v.isNotEmpty)
                .toSet()
                .toList();
            if (vins.isNotEmpty) {
              _guests[i] = <String, dynamic>{
                ..._guests[i],
                'scheduledCallVins': vins,
              };
            }
          }
        }
        _notifications = (decoded['notifications'] as List<dynamic>? ?? [])
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList();
        _calendarEvents = (decoded['calendarEvents'] as List<dynamic>? ?? [])
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList();
        _backups = (decoded['backups'] as List<dynamic>? ?? [])
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .take(maxBackups)
            .toList();
        _recallChecks = (decoded['recallChecks'] as List<dynamic>? ?? [])
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .take(15)
            .toList();
        if (decoded['recallStatusOverrides'] is Map) {
          _recallStatusOverrides =
              (decoded['recallStatusOverrides'] as Map).map(
            (k, v) => MapEntry(k.toString(), v.toString()),
          );
        }
        if (decoded['recallResultsByVin'] is Map) {
          final rawMap = decoded['recallResultsByVin'] as Map;
          _recallResultsByVin = <String, Map<String, dynamic>>{};
          for (final entry in rawMap.entries) {
            if (entry.value is Map) {
              _recallResultsByVin[entry.key.toString()] =
                  Map<String, dynamic>.from(entry.value as Map);
            }
          }
        }
        if (decoded['deletedGuestIds'] is Map) {
          _deletedGuestIds = (decoded['deletedGuestIds'] as Map).map(
            (k, v) => MapEntry(k.toString(), v.toString()),
          );
        }
        if (decoded['settings'] is Map) {
          _settings = {
            ..._settings,
            ...Map<String, dynamic>.from(decoded['settings'] as Map),
          };
        }
        if (_guests.isNotEmpty && _backups.isEmpty) {
          _recordBackupSnapshotSync(
            label: 'Initial Data Backup',
            force: true,
          );
        }
        MatchNotificationService.instance.hydratePersistedNotifications(
          _notifications.map(MatchAlertNotification.fromJson).toList(),
        );
        CalendarService.instance.hydratePersistedState(
          events: _calendarEvents.map(CalendarCallEvent.fromJson).toList(),
          permissionGranted: _settings['calendarPermissionGranted'] == true,
          promptDismissed: _settings['calendarPromptDismissed'] == true,
        );
      } else {
        await _seedInitialGuests();
      }
    } catch (_) {
      if (_guests.isEmpty) {
        await _seedInitialGuests();
      }
    }

    _startOnDeviceScheduler();
    await _syncWidget();
    unawaited(_repairZeroScannedGuestsIfNeeded());
  }

  static int _dealerId = 19398;
  static int _newPageId = 1446609;
  static int _usedPageId = 1446611;
  static DateTime? _configFetchedAt;

  static double? _asDouble(Object? raw) {
    if (raw == null) return null;
    if (raw is num) return raw.toDouble();
    final cleaned = raw.toString().replaceAll(RegExp(r'[^0-9.\-]'), '').trim();
    if (cleaned.isEmpty) return null;
    return double.tryParse(cleaned);
  }

  static int? _asInt(Object? raw) {
    if (raw == null) return null;
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    final cleaned = raw.toString().replaceAll(RegExp(r'[^0-9\-]'), '').trim();
    if (cleaned.isEmpty) return null;
    return int.tryParse(cleaned) ?? _asDouble(raw)?.round();
  }

  static bool _isRepairingZeroScannedGuests = false;

  /// Automatically re-runs initial search for any active guest whose previous scan
  /// recorded "Scanned 0 live prestonmotor.com vehicles" due to string-typed Length fields.
  static Future<void> _repairZeroScannedGuestsIfNeeded() async {
    if (kIsWeb || _isRunningBatch || _isRepairingZeroScannedGuests) return;
    final affectedIds = _guests
        .where((g) =>
            g['active'] != false &&
            (g['lastSearchSummary']?.toString() ?? '')
                .startsWith('Scanned 0 live prestonmotor.com vehicles'))
        .map((g) => g['id']?.toString() ?? '')
        .where((id) => id.isNotEmpty)
        .toList();
    if (affectedIds.isEmpty) return;

    _isRepairingZeroScannedGuests = true;
    try {
      for (final gid in affectedIds) {
        if (!_initialized) return;
        try {
          await runSearchForSingleGuest(
            gid,
            slotLabel: 'Inventory Sync Repair',
            isInitialSearch: true,
          );
        } catch (_) {}
      }
    } finally {
      _isRepairingZeroScannedGuests = false;
    }
  }

  /// Reloads the persisted on-device store when the Android app resumes from background
  /// so matches and notifications discovered by NativeBackgroundMatchScanner appear immediately.
  static Future<void> reloadFromDiskOnResume() async {
    if (kIsWeb || !_initialized || _isRunningBatch) return;
    try {
      final raw = await _channel.invokeMethod<String>('readLocalStore');
      if (raw == null || raw.trim().isEmpty) return;
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      _guests = (decoded['guests'] as List<dynamic>? ?? [])
          .map((e) => _normalizeGuestMap(Map<String, dynamic>.from(e as Map)))
          .toList();
      _matches = (decoded['matches'] as List<dynamic>? ?? [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
      _notifications = (decoded['notifications'] as List<dynamic>? ?? [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
      _calendarEvents = (decoded['calendarEvents'] as List<dynamic>? ?? [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
      if (decoded['backups'] is List) {
        _backups = (decoded['backups'] as List<dynamic>)
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .take(maxBackups)
            .toList();
      }
      if (decoded['recallChecks'] is List) {
        _recallChecks = (decoded['recallChecks'] as List<dynamic>)
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .take(15)
            .toList();
      }
      if (decoded['recallStatusOverrides'] is Map) {
        _recallStatusOverrides =
            (decoded['recallStatusOverrides'] as Map).map(
          (k, v) => MapEntry(k.toString(), v.toString()),
        );
      }
      if (decoded['recallResultsByVin'] is Map) {
        final rawMap = decoded['recallResultsByVin'] as Map;
        _recallResultsByVin = <String, Map<String, dynamic>>{};
        for (final entry in rawMap.entries) {
          if (entry.value is Map) {
            _recallResultsByVin[entry.key.toString()] =
                Map<String, dynamic>.from(entry.value as Map);
          }
        }
      }
      MatchNotificationService.instance.hydratePersistedNotifications(
        _notifications.map(MatchAlertNotification.fromJson).toList(),
      );
      CalendarService.instance.hydratePersistedState(
        events: _calendarEvents.map(CalendarCallEvent.fromJson).toList(),
        permissionGranted: _settings['calendarPermissionGranted'] == true,
        promptDismissed: _settings['calendarPromptDismissed'] == true,
      );
    } catch (_) {}
  }

  /// Normalizes structured vehicle criteria AND extracts structured specs (Make, Model like
  /// "F150" -> "F-150", Trim like "XLT", Bed Length like "6.5ft bed", Cab Style, Engine,
  /// Year Range, Max Price, Max Mileage, Condition, Drivetrain, Color) from natural language.
  static Map<String, dynamic> _normalizeTargetMap(
    Map<String, dynamic> raw, {
    required String fallbackId,
    required String fallbackCreatedAt,
  }) {
    final parsed = NaturalLanguageVehicleParser.parseCriteriaMap(raw);
    final rawId = (raw['id']?.toString() ?? '').trim();
    final rawCreated = (raw['createdAt']?.toString() ?? '').trim();
    final rawCriteriaUpd = (raw['criteriaUpdatedAt']?.toString() ?? '').trim();

    return <String, dynamic>{
      'id': rawId.isNotEmpty ? rawId : fallbackId,
      'condition': parsed['condition'],
      'minYear': parsed['minYear'],
      'maxYear': parsed['maxYear'],
      'make': parsed['make'],
      'model': parsed['model'],
      'trim': parsed['trim'],
      'doors': parsed['doors'],
      'bedLength': parsed['bedLength'],
      'cabStyle': parsed['cabStyle'],
      'engineSpec': parsed['engineSpec'],
      'maxPrice': parsed['maxPrice'],
      'maxMileage': parsed['maxMileage'],
      'drivetrain': parsed['drivetrain'],
      'exteriorColor': parsed['exteriorColor'],
      'features': parsed['features'],
      'notes': parsed['notes'],
      'createdAt': rawCreated.isNotEmpty ? rawCreated : fallbackCreatedAt,
      if (rawCriteriaUpd.isNotEmpty) 'criteriaUpdatedAt': rawCriteriaUpd,
    };
  }

  static Map<String, dynamic> _normalizeGuestMap(Map<String, dynamic> raw) {
    final gid = (raw['id']?.toString() ?? '').trim();
    final createdAt = (raw['createdAt']?.toString() ??
            DateTime.now().toUtc().toIso8601String())
        .trim();
    final criteriaUpdatedAt =
        (raw['criteriaUpdatedAt']?.toString() ?? '').trim();

    final normalizedTargets = <Map<String, dynamic>>[];
    final rawTargets = raw['vehicleTargets'];
    if (rawTargets is List && rawTargets.isNotEmpty) {
      for (var i = 0; i < rawTargets.length; i++) {
        final item = rawTargets[i];
        if (item is Map) {
          normalizedTargets.add(
            _normalizeTargetMap(
              Map<String, dynamic>.from(item),
              fallbackId: '${gid.isNotEmpty ? gid : 'guest'}-vt-${i + 1}',
              fallbackCreatedAt: createdAt,
            ),
          );
        }
      }
    }

    if (normalizedTargets.isEmpty) {
      normalizedTargets.add(
        _normalizeTargetMap(
          raw,
          fallbackId: '${gid.isNotEmpty ? gid : 'guest'}-primary',
          fallbackCreatedAt: createdAt,
        ),
      );
    }

    final deletedNoteSet = <String>{
      ...((raw['deletedNoteIds'] as List<dynamic>?)
              ?.map((e) => e.toString()) ??
          const <String>[]),
    };

    final normalizedNotes = <Map<String, dynamic>>[];
    final rawClientNotes = raw['clientNotes'];
    if (rawClientNotes is List) {
      final seenIds = <String>{};
      for (var i = 0; i < rawClientNotes.length; i++) {
        final item = rawClientNotes[i];
        if (item is Map) {
          final text = (item['text']?.toString() ?? '').trim();
          if (text.isEmpty) continue;
          final noteId = (item['id']?.toString() ?? '').isNotEmpty
              ? item['id'].toString()
              : '${gid.isNotEmpty ? gid : 'guest'}-note-${i + 1}';
          if (deletedNoteSet.contains(noteId) || !seenIds.add(noteId)) continue;
          final noteCreated = (item['createdAt']?.toString() ?? '').isNotEmpty
              ? item['createdAt'].toString()
              : createdAt;
          normalizedNotes.add(<String, dynamic>{
            'id': noteId,
            'text': text,
            'createdAt': noteCreated,
          });
        }
      }
    }
    normalizedNotes.sort(
      (a, b) => (b['createdAt'] ?? '')
          .toString()
          .compareTo((a['createdAt'] ?? '').toString()),
    );

    final seenVinSet = <String>{
      ...((raw['seenMatchVins'] as List<dynamic>?)
              ?.map((e) => e.toString().trim())
              .where((s) => s.isNotEmpty) ??
          const <String>[]),
    };
    final scheduledCallSet = <String>{
      ...((raw['scheduledCallVins'] as List<dynamic>?)
              ?.map((e) => e.toString().trim())
              .where((s) => s.isNotEmpty) ??
          const <String>[]),
    };
    final lastSearchedRaw = (raw['lastSearchedAt']?.toString() ?? '').trim();
    final initialDone =
        raw['initialSearchCompleted'] == true || lastSearchedRaw.isNotEmpty;

    final primary = normalizedTargets.first;

    return <String, dynamic>{
      ...raw,
      'condition': primary['condition'],
      'minYear': primary['minYear'],
      'maxYear': primary['maxYear'],
      'make': primary['make'],
      'model': primary['model'],
      'trim': primary['trim'],
      'doors': primary['doors'],
      'bedLength': primary['bedLength'],
      'cabStyle': primary['cabStyle'],
      'engineSpec': primary['engineSpec'],
      'maxPrice': primary['maxPrice'],
      'maxMileage': primary['maxMileage'],
      'drivetrain': primary['drivetrain'],
      'exteriorColor': primary['exteriorColor'],
      'features': primary['features'],
      'notes': primary['notes'],
      'vehicleTargets': normalizedTargets,
      'clientNotes': normalizedNotes,
      'deletedNoteIds': deletedNoteSet.toList(),
      'initialSearchCompleted': initialDone,
      'seenMatchVins': seenVinSet.toList(),
      'scheduledCallVins': scheduledCallSet.toList(),
      if (criteriaUpdatedAt.isNotEmpty) 'criteriaUpdatedAt': criteriaUpdatedAt,
    };
  }

  static Future<void> _persist() async {
    if (kIsWeb) return;
    try {
      final payload = jsonEncode({
        'guests': _guests,
        'matches': _matches,
        'notifications': _notifications,
        'calendarEvents': _calendarEvents,
        'backups': _backups,
        'recallChecks': _recallChecks,
        'recallStatusOverrides': _recallStatusOverrides,
        'recallResultsByVin': _recallResultsByVin,
        'deletedGuestIds': _deletedGuestIds,
        'settings': _settings,
      });
      await _channel.invokeMethod('writeLocalStore', {'storeJson': payload});
    } catch (_) {}
    await _syncWidget();
  }

  static Future<void> _syncWidget() async {
    final sorted = [..._guests]..sort((a, b) => (b['createdAt'] ?? '')
        .toString()
        .compareTo((a['createdAt'] ?? '').toString()));
    final recentTen = sorted.take(10).map((g) {
      final profile = _hydrateGuest(g);
      return WidgetGuestEntry(
        id: profile.id,
        name: profile.name,
        targetSummary: profile.targetVehicleLabel,
        matchCount: profile.matchCount,
        createdAt: profile.createdAt,
      );
    }).toList();
    await WidgetSyncService.syncRecentTenGuests(recentTen);
  }

  static Future<void> _seedInitialGuests() async {
    final now = DateTime.now().toUtc();
    _guests = [
      {
        'id': 'guest-marcus-vance',
        'name': 'Marcus Vance',
        'phone': '(410) 555-0177',
        'email': 'mvance.fleet@example.com',
        'condition': 'New',
        'minYear': 2026,
        'maxYear': 2027,
        'make': 'Ford',
        'model': 'F-250',
        'trim': 'XL',
        'maxPrice': 60000.0,
        'maxMileage': null,
        'drivetrain': '4WD',
        'exteriorColor': 'White',
        'features': ['4WD', 'Bluetooth', 'Tow Hitch', 'Backup Camera'],
        'notes':
            'SuperCab (X2B) 4WD work truck, 7.3L V8 gas preferred, Oxford White exterior.',
        'active': true,
        'lastSearchedAt': null,
        'lastSearchSummary': '',
        'createdAt':
            now.subtract(const Duration(minutes: 20)).toIso8601String(),
      },
      {
        'id': 'guest-devon-brooks',
        'name': 'Devon Brooks',
        'phone': '(410) 555-0192',
        'email': 'dbrooks@example.com',
        'condition': 'New',
        'minYear': 2025,
        'maxYear': 2027,
        'make': 'Ford',
        'model': 'Bronco Sport',
        'trim': 'Big Bend',
        'maxPrice': 33000.0,
        'maxMileage': null,
        'drivetrain': '4WD',
        'exteriorColor': '',
        'features': [
          '4WD/AWD',
          'Apple CarPlay',
          'Android Auto',
          'Blind Spot Monitor',
          'Lane Keep Assist'
        ],
        'notes':
            'Targeting a New Ford Bronco Sport Big Bend 4x4 with SYNC 4 under \$33,000.',
        'active': true,
        'lastSearchedAt': null,
        'lastSearchSummary': '',
        'createdAt': now.subtract(const Duration(hours: 1)).toIso8601String(),
      },
      {
        'id': 'guest-rhonda-vanvorst',
        'name': 'Rhonda Vanvorst',
        'phone': '(302) 555-0148',
        'email': 'rhonda.v@example.com',
        'condition': 'Pre-Owned',
        'minYear': 2020,
        'maxYear': 2024,
        'make': 'Lincoln',
        'model': 'Nautilus',
        'trim': 'Reserve',
        'maxPrice': 30000.0,
        'maxMileage': 95000,
        'drivetrain': 'AWD',
        'exteriorColor': '',
        'features': [
          'Leather Seats',
          'Navigation System',
          'Apple CarPlay',
          'Blind Spot Monitor',
          'Sunroof/Moonroof'
        ],
        'notes':
            'Looking for a clean Pre-Owned or CPO Lincoln Nautilus Reserve with AWD under \$30,000.',
        'active': true,
        'lastSearchedAt': null,
        'lastSearchSummary': '',
        'createdAt': now.subtract(const Duration(hours: 2)).toIso8601String(),
      },
    ];
    await _persist();
    unawaited(
      runSearchForAllGuests(
        slotLabel: 'Initial Googlebook Sync',
        isInitialSearch: true,
        isSeedSearch: true,
      ),
    );
  }

  static void _startOnDeviceScheduler() {
    _scheduleTimer?.cancel();
    _scheduleTimer = Timer.periodic(const Duration(seconds: 25), (_) async {
      final now = DateTime.now();
      final dateKey =
          '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
      final mins = now.hour * 60 + now.minute;
      final completed = List<String>.from(
          (_settings['completedSlots'] as List<dynamic>? ?? [])
              .map((e) => e.toString()));

      // 7:30 AM slot (with wake-up catch-up window through 9:00 AM)
      if (mins >= 7 * 60 + 30 && mins <= 9 * 60) {
        final key = '${dateKey}_07:30';
        if (!completed.contains(key)) {
          completed.add(key);
          _settings['completedSlots'] = completed.length > 30
              ? completed.sublist(completed.length - 30)
              : completed;
          await _persist();
          await runSearchForAllGuests(slotLabel: '7:30 AM Daily Search');
        }
      }

      // 2:00 PM slot (with wake-up catch-up window through 3:30 PM)
      if (mins >= 14 * 60 && mins <= 15 * 60 + 30) {
        final key = '${dateKey}_14:00';
        if (!completed.contains(key)) {
          completed.add(key);
          _settings['completedSlots'] = completed.length > 30
              ? completed.sublist(completed.length - 30)
              : completed;
          await _persist();
          await runSearchForAllGuests(slotLabel: '2:00 PM Daily Search');
        }
      }
    });
  }

  static Map<String, dynamic> _storedMatchToCandidateMap(
    Map<String, dynamic> m,
  ) {
    final matchedFeatures =
        (m['matchedFeatures'] as List<dynamic>? ?? const [])
            .map((e) => e.toString())
            .toList();
    final allHighlights = (m['allHighlights'] as List<dynamic>? ??
            m['highlights'] as List<dynamic>? ??
            const [])
        .map((e) => e.toString())
        .toList();
    final combinedHighlights = <String>{
      ...allHighlights,
      ...matchedFeatures,
    }.toList();
    final featText = matchedFeatures.join(' ');
    final combinedComments = [
      (m['commentsSummary']?.toString() ?? '').trim(),
      (m['agentSummary']?.toString() ?? '').trim(),
      featText,
    ].where((s) => s.isNotEmpty).join(' ');

    int? inferredYear = _asInt(m['year']);
    final titleStr = (m['title']?.toString() ?? '').trim();
    if (inferredYear == null && titleStr.isNotEmpty) {
      final ym = RegExp(r'\b(20\d{2}|19\d{2})\b').firstMatch(titleStr);
      if (ym != null) inferredYear = int.tryParse(ym.group(1)!);
    }

    var inferredDoors = (m['doors']?.toString() ?? '').trim();
    if (inferredDoors.isEmpty && featText.isNotEmpty) {
      final dm = RegExp(r'\b([2345])\s*Doors?\b', caseSensitive: false)
          .firstMatch(featText);
      if (dm != null) inferredDoors = dm.group(1)!;
    }

    var inferredBed = (m['bedLength']?.toString() ?? '').trim();
    if (inferredBed.isEmpty) {
      inferredBed = NaturalLanguageVehicleParser.extractBedLengthFromVehicle(
        <String, dynamic>{
          'title': titleStr,
          'bodyStyle': m['bodyStyle']?.toString() ?? '',
        },
        fullCommentsClean: combinedComments,
      );
    }

    return <String, dynamic>{
      'vin': m['vin']?.toString() ?? '',
      'stockNumber': m['stockNumber']?.toString() ?? '',
      'title': titleStr,
      'year': inferredYear,
      'make': m['make']?.toString() ?? '',
      'model': m['model']?.toString() ?? '',
      'trim': m['trim']?.toString() ?? '',
      'condition': m['condition']?.toString() ?? '',
      'price': _asDouble(m['price']),
      'msrp': _asDouble(m['msrp']),
      'location': m['location']?.toString() ?? '',
      'mileage': m.containsKey('mileage') ? _asInt(m['mileage']) : null,
      'drivetrain': m['drivetrain']?.toString() ?? '',
      'engine': m['engine']?.toString() ?? '',
      'doors': inferredDoors,
      'bedLength': inferredBed,
      'bodyStyle': m['bodyStyle']?.toString() ?? '',
      'exteriorColor': m['exteriorColor']?.toString() ?? '',
      'interiorColor': m['interiorColor']?.toString() ?? '',
      'highlights': combinedHighlights,
      'commentsSummary': combinedComments,
      'fullCommentsSearchText': combinedComments,
    };
  }

  /// Verifies whether a stored/cached vehicle match satisfies a given [VehicleSearchTarget].
  /// Used whenever a search is edited, loaded, or synced across devices so stale vehicles
  /// that no longer match the edited criteria are immediately removed.
  static bool doesStoredMatchSatisfyTarget(
    Map<String, dynamic> matchMap,
    VehicleSearchTarget target, {
    bool strictMissingSpecs = false,
  }) {
    final spec = NaturalLanguageVehicleParser.parseCriteriaMap(target.toJson());
    final v = _storedMatchToCandidateMap(matchMap);

    final targetMake = (spec['make']?.toString() ?? '').trim();
    final targetModel = (spec['model']?.toString() ?? '').trim();
    final targetTrim = (spec['trim']?.toString() ?? '').trim();
    final targetDoors = (spec['doors']?.toString() ?? '').trim();
    final targetBed = (spec['bedLength']?.toString() ?? '').trim();
    final targetCab = (spec['cabStyle']?.toString() ?? '').trim();
    final targetEngine = (spec['engineSpec']?.toString() ?? '').trim();
    final targetDt = (spec['drivetrain']?.toString() ?? 'Any').trim();
    final targetColor = (spec['exteriorColor']?.toString() ?? '').trim();
    final targetCondition = (spec['condition']?.toString() ?? 'Any').trim();
    final minYear = _asInt(spec['minYear']);
    final maxYear = _asInt(spec['maxYear']);
    final maxPrice = _asDouble(spec['maxPrice']);
    final maxMileage = _asInt(spec['maxMileage']);
    final locationHints = (spec['locationHints'] as List<dynamic>? ?? const [])
        .map((e) => e.toString())
        .toList();
    final strictPackages =
        (spec['strictPackages'] as List<dynamic>? ?? const [])
            .map((e) => e.toString())
            .toList();

    if (targetMake.isNotEmpty) {
      final hay = '${v['make'] ?? ''} ${v['title'] ?? ''}'.trim().toLowerCase();
      if (hay.isNotEmpty && !hay.contains(targetMake.toLowerCase())) {
        return false;
      }
    }

    if (targetModel.isNotEmpty &&
        !NaturalLanguageVehicleParser.doesVehicleMatchModel(targetModel, v)) {
      return false;
    }

    if (targetTrim.isNotEmpty &&
        ('${v['trim'] ?? ''}${v['title'] ?? ''}').trim().isNotEmpty &&
        !NaturalLanguageVehicleParser.doesVehicleMatchTrim(targetTrim, v)) {
      return false;
    }

    if (targetBed.isNotEmpty) {
      final normTargetBed = targetBed.replaceAll("'", '');
      final normVBed =
          (v['bedLength']?.toString() ?? '').replaceAll("'", '').trim();
      if (normVBed.isNotEmpty) {
        if (normVBed != normTargetBed) return false;
      } else if (strictMissingSpecs || matchMap.containsKey('bedLength')) {
        return false;
      }
    }

    if (targetCab.isNotEmpty) {
      final hasCabSignal = (v['bodyStyle']?.toString() ?? '').isNotEmpty ||
          RegExp(
            r'\b(?:regular\s+cab|reg\s+cab|single\s+cab|super\s*cab|extended\s+cab|super\s*crew|crew\s+cab|quad\s+cab|mega\s+cab|double\s+cab)\b',
            caseSensitive: false,
          ).hasMatch('${v['title'] ?? ''} ${v['commentsSummary'] ?? ''}');
      if ((hasCabSignal || strictMissingSpecs) &&
          !NaturalLanguageVehicleParser.doesVehicleMatchCabStyle(
            targetCab,
            v,
          )) {
        return false;
      }
    }

    if (targetDoors.isNotEmpty) {
      final hasDoorSignal = (v['doors']?.toString() ?? '').isNotEmpty ||
          (v['bodyStyle']?.toString() ?? '').isNotEmpty ||
          RegExp(
            r'\b(?:[2345][-\s]*door|regular\s+cab|super\s*cab|super\s*crew|crew\s+cab|bronco|wrangler|mustang)\b',
            caseSensitive: false,
          ).hasMatch('${v['title'] ?? ''} ${v['commentsSummary'] ?? ''}');
      if ((hasDoorSignal || strictMissingSpecs) &&
          !NaturalLanguageVehicleParser.doesVehicleMatchDoors(targetDoors, v)) {
        return false;
      }
    }

    if (targetEngine.isNotEmpty) {
      final hasEngineSignal = (v['engine']?.toString() ?? '').isNotEmpty;
      if ((hasEngineSignal || strictMissingSpecs) &&
          !NaturalLanguageVehicleParser.doesVehicleMatchEngine(
            targetEngine,
            v,
          )) {
        return false;
      }
    }

    if (targetDt.isNotEmpty && targetDt != 'Any') {
      final hasDtSignal = (v['drivetrain']?.toString() ?? '').isNotEmpty ||
          RegExp(r'\b(?:4wd|4x4|awd|fwd|rwd|2wd)\b', caseSensitive: false)
              .hasMatch(
                  '${v['title'] ?? ''} ${(v['highlights'] as List).join(' ')}');
      if ((hasDtSignal || strictMissingSpecs) &&
          !NaturalLanguageVehicleParser.doesVehicleMatchDrivetrain(
            targetDt,
            v,
          )) {
        return false;
      }
    }

    if (targetColor.isNotEmpty) {
      final hasColorSignal =
          (v['exteriorColor']?.toString() ?? '').trim().isNotEmpty;
      if ((hasColorSignal || strictMissingSpecs) &&
          !NaturalLanguageVehicleParser.doesVehicleMatchColor(targetColor, v)) {
        return false;
      }
    }

    if (strictPackages.isNotEmpty) {
      final hasComments =
          (matchMap['commentsSummary']?.toString() ?? '').trim().isNotEmpty;
      if ((hasComments || strictMissingSpecs) &&
          !NaturalLanguageVehicleParser.doesVehicleMatchStrictPackages(
            strictPackages,
            v,
          )) {
        return false;
      }
    }

    final yr = _asInt(v['year']);
    if (minYear != null && yr != null && yr < minYear) return false;
    if (maxYear != null && yr != null && yr > maxYear) return false;

    if (maxPrice != null && maxPrice > 0) {
      final pr = _asDouble(v['price']);
      final msrp = _asDouble(v['msrp']);
      final effectivePrice = (pr != null && pr > 0)
          ? pr
          : ((msrp != null && msrp > 0) ? msrp : null);
      if (effectivePrice != null && effectivePrice > maxPrice) {
        return false;
      }
    }

    final mi = _asInt(v['mileage']);
    if (maxMileage != null && mi != null && mi > maxMileage) {
      return false;
    }

    if (targetCondition.isNotEmpty && targetCondition != 'Any') {
      final vc = (v['condition']?.toString() ?? '').trim().toLowerCase();
      if (vc.isNotEmpty) {
        final c = targetCondition.toLowerCase();
        if (c == 'new' && !vc.contains('new')) return false;
        if (c == 'cpo' && !vc.contains('certified')) return false;
        if (c == 'pre-owned' && vc.contains('new') && !vc.contains('pre')) {
          return false;
        }
      }
    }

    if (locationHints.isNotEmpty) {
      final locHay = (v['location']?.toString() ?? '').trim().toLowerCase();
      if (locHay.isNotEmpty &&
          !locationHints.any((hint) => locHay.contains(hint))) {
        return false;
      }
    }

    return true;
  }

  static VehicleSearchTarget? resolveMatchingTargetForStoredMatch(
    Map<String, dynamic> matchMap,
    GuestProfile guest,
  ) {
    final allTargets = guest.effectiveTargets;
    if (allTargets.isEmpty) return null;
    if (allTargets.length == 1) {
      return doesStoredMatchSatisfyTarget(matchMap, allTargets.first)
          ? allTargets.first
          : null;
    }
    final mTid = (matchMap['targetId']?.toString() ?? '').trim();
    if (mTid.isNotEmpty) {
      for (final t in allTargets) {
        if (t.id == mTid && doesStoredMatchSatisfyTarget(matchMap, t)) {
          return t;
        }
      }
    }
    for (final t in allTargets) {
      if (doesStoredMatchSatisfyTarget(matchMap, t)) {
        return t;
      }
    }
    return null;
  }

  /// Filters a list of [VehicleMatch] instances so ONLY vehicles satisfying [guest]'s
  /// current search target(s) remain.
  static List<VehicleMatch> filterMatchesForGuest(
    GuestProfile guest,
    List<VehicleMatch> matches,
  ) {
    final out = <VehicleMatch>[];
    for (final m in matches) {
      final matchedTarget = resolveMatchingTargetForStoredMatch(
        m.toJson(),
        guest,
      );
      if (matchedTarget != null) {
        out.add(m);
      }
    }
    return out;
  }

  static int _pruneNonMatchingMatchesForGuestSync(String guestId) {
    final idx = _guests.indexWhere((g) => g['id']?.toString() == guestId);
    if (idx == -1) return 0;
    final normGuest = GuestProfile.fromJson(_normalizeGuestMap(_guests[idx]));
    int removed = 0;

    final kept = <Map<String, dynamic>>[];
    for (final m in _matches) {
      if (m['guestId']?.toString() != guestId) {
        kept.add(m);
        continue;
      }
      final matchedTarget = resolveMatchingTargetForStoredMatch(m, normGuest);
      if (matchedTarget == null) {
        removed++;
        continue;
      }
      final curTid = (m['targetId']?.toString() ?? '').trim();
      if (curTid.isNotEmpty && curTid != matchedTarget.id) {
        kept.add(<String, dynamic>{
          ...m,
          'targetId': matchedTarget.id,
          'targetLabel': matchedTarget.label,
        });
      } else {
        kept.add(m);
      }
    }
    if (removed > 0 || kept.length != _matches.length) {
      _matches = kept;
    } else {
      _matches = kept;
    }
    return removed;
  }

  static GuestProfile _hydrateGuest(Map<String, dynamic> rawG) {
    final g = _normalizeGuestMap(rawG);
    final gid = g['id']?.toString() ?? '';
    final tempProfile = GuestProfile.fromJson(g);
    int count = 0;
    int selectedCount = 0;
    double? lowest;
    for (final m in _matches) {
      if (m['guestId']?.toString() != gid) continue;
      if (resolveMatchingTargetForStoredMatch(m, tempProfile) == null) {
        continue;
      }
      count++;
      if (m['isSelectedCandidate'] == true || m['isSelectedCandidate'] == 1) {
        selectedCount++;
      }
      final p = (m['price'] as num?)?.toDouble();
      if (p != null && (lowest == null || p < lowest)) {
        lowest = p;
      }
    }
    return GuestProfile.fromJson({
      ...g,
      'matchCount': count,
      'selectedCandidateCount': selectedCount,
      'lowestMatchPrice': lowest,
    });
  }

  static Future<SystemStatus> getStatus() async {
    await ensureInitialized();
    final now = DateTime.now();
    final mins = now.hour * 60 + now.minute;
    String nextLabel;
    if (mins < 7 * 60 + 30) {
      nextLabel = 'Today at 7:30 AM';
    } else if (mins < 14 * 60) {
      nextLabel = 'Today at 2:00 PM';
    } else {
      nextLabel = 'Tomorrow at 7:30 AM';
    }
    final key = (_settings['geminiApiKey']?.toString() ?? '').trim();
    return SystemStatus(
      totalGuests: _guests.length,
      totalMatches: _matches.length,
      nextScheduledRunLabel: nextLabel,
      timeZone: _settings['timezone']?.toString() ?? 'America/New_York',
      isRunning: _isRunningBatch,
      geminiConfigured: key.isNotEmpty,
      geminiModel: _settings['geminiModel']?.toString() ?? 'gemini-2.5-flash',
    );
  }

  static Future<List<GuestProfile>> getAllGuests() async {
    await ensureInitialized();
    final sorted = [..._guests]..sort((a, b) => (b['createdAt'] ?? '')
        .toString()
        .compareTo((a['createdAt'] ?? '').toString()));
    return sorted.map(_hydrateGuest).toList();
  }

  static Future<List<WidgetGuestEntry>> getRecentTenWidgetGuests() async {
    final all = await getAllGuests();
    return all.take(10).map((g) {
      return WidgetGuestEntry(
        id: g.id,
        name: g.name,
        targetSummary: g.targetVehicleLabel,
        matchCount: g.matchCount,
        createdAt: g.createdAt,
      );
    }).toList();
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
    @visibleForTesting List<Map<String, dynamic>>? mockCandidatesOverride,
  }) async {
    await ensureInitialized();
    final id = 'guest-${DateTime.now().microsecondsSinceEpoch}';
    final nowIso = DateTime.now().toUtc().toIso8601String();
    final map = _normalizeGuestMap(<String, dynamic>{
      'id': id,
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
      'active': true,
      'lastSearchedAt': null,
      'lastSearchSummary': '',
      'createdAt': nowIso,
      'updatedAt': nowIso,
    });
    _deletedGuestIds.remove(id);
    _guests.insert(0, map);
    await _persist();

    final searchRes = await runSearchForSingleGuest(
      id,
      slotLabel: 'Initial Intake Search',
      isInitialSearch: true,
      mockCandidatesOverride: mockCandidatesOverride,
    );
    _recordBackupSnapshotSync(label: 'Auto-Backup • Added $name');
    await _persist();
    return (
      guest: searchRes.guest,
      matchesFound: searchRes.matches.length,
      summary: searchRes.summary,
    );
  }

  static Future<({GuestProfile guest, List<VehicleMatch> matches})>
      getGuestWithMatches(String guestId) async {
    await ensureInitialized();
    final pruned = _pruneNonMatchingMatchesForGuestSync(guestId);
    if (pruned > 0) {
      await _persist();
    }
    final raw = _guests.firstWhere(
      (g) => g['id']?.toString() == guestId,
      orElse: () => throw Exception('Guest not found'),
    );
    final guestMatches = _matches
        .where((m) => m['guestId']?.toString() == guestId)
        .map((m) => VehicleMatch.fromJson(m))
        .toList()
      ..sort((a, b) {
        final cmp = b.matchScore.compareTo(a.matchScore);
        if (cmp != 0) return cmp;
        final pa = a.price ?? double.maxFinite;
        final pb = b.price ?? double.maxFinite;
        return pa.compareTo(pb);
      });
    return (guest: _hydrateGuest(raw), matches: guestMatches);
  }

  static Future<
          ({GuestProfile guest, List<VehicleMatch> matches, VehicleMatch match})>
      setMatchSelectedCandidate({
    required String guestId,
    required String vin,
    required bool selected,
  }) async {
    await ensureInitialized();
    final gIdx = _guests.indexWhere((g) => g['id']?.toString() == guestId);
    if (gIdx == -1) throw Exception('Guest not found');

    final cleanVin = vin.trim();
    final mIdx = _matches.indexWhere(
      (m) =>
          m['guestId']?.toString() == guestId &&
          (m['vin']?.toString() == cleanVin || m['id']?.toString() == cleanVin),
    );
    if (mIdx == -1) throw Exception('Vehicle match not found');

    final nowIso = DateTime.now().toUtc().toIso8601String();
    final prev = _matches[mIdx];
    final title = (prev['title']?.toString() ?? '').trim();
    final updatedMap = <String, dynamic>{
      ...prev,
      'isSelectedCandidate': selected,
      'selectedAt': selected ? nowIso : null,
      'selectedUpdatedAt': nowIso,
    };
    _matches[mIdx] = updatedMap;
    _guests[gIdx] = <String, dynamic>{
      ..._guests[gIdx],
      'updatedAt': nowIso,
    };

    _recordBackupSnapshotSync(
      label: selected
          ? 'Auto-Backup • Selected ${title.isNotEmpty ? title : cleanVin}'
          : 'Auto-Backup • Unselected ${title.isNotEmpty ? title : cleanVin}',
    );
    await _persist();
    onDataMutatedForCloudSave?.call();

    final refreshed = await getGuestWithMatches(guestId);
    return (
      guest: refreshed.guest,
      matches: refreshed.matches,
      match: VehicleMatch.fromJson(updatedMap),
    );
  }

  static Future<void> deleteGuest(String guestId) async {
    await ensureInitialized();
    final existingIdx = _guests.indexWhere((g) => g['id']?.toString() == guestId);
    if (existingIdx != -1) {
      final deletedName =
          (_guests[existingIdx]['name']?.toString() ?? 'Guest').trim();
      _recordBackupSnapshotSync(
        label: 'Auto-Backup • Before Deleting $deletedName',
      );
    }
    _deletedGuestIds[guestId] = DateTime.now().toUtc().toIso8601String();
    _guests.removeWhere((g) => g['id']?.toString() == guestId);
    _matches.removeWhere((m) => m['guestId']?.toString() == guestId);
    _notifications.removeWhere((n) => n['guestId']?.toString() == guestId);
    _calendarEvents.removeWhere((e) => e['guestId']?.toString() == guestId);
    MatchNotificationService.instance.hydratePersistedNotifications(
      _notifications.map(MatchAlertNotification.fromJson).toList(),
    );
    CalendarService.instance.hydratePersistedState(
      events: _calendarEvents.map(CalendarCallEvent.fromJson).toList(),
      permissionGranted: _settings['calendarPermissionGranted'] == true,
      promptDismissed: _settings['calendarPromptDismissed'] == true,
    );
    await _persist();
    onDataMutatedForCloudSave?.call();
  }

  static Future<List<MatchAlertNotification>> getNotifications() async {
    await ensureInitialized();
    final list = _notifications.map(MatchAlertNotification.fromJson).toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return list;
  }

  static Future<void> markAllNotificationsRead() async {
    await ensureInitialized();
    for (var i = 0; i < _notifications.length; i++) {
      _notifications[i] = <String, dynamic>{
        ..._notifications[i],
        'read': true,
      };
    }
    MatchNotificationService.instance.markAllReadLocally();
    await _persist();
  }

  static Future<void> clearNotifications() async {
    await ensureInitialized();
    _notifications = [];
    MatchNotificationService.instance.clearAllLocally();
    await _persist();
  }

  static Future<List<CalendarCallEvent>> getCalendarEvents() async {
    await ensureInitialized();
    final list = _calendarEvents.map(CalendarCallEvent.fromJson).toList()
      ..sort((a, b) => b.startAt.compareTo(a.startAt));
    return list;
  }

  static Future<void> saveCalendarPermissionState({
    required bool permissionGranted,
    required bool promptDismissed,
  }) async {
    await ensureInitialized();
    _settings['calendarPermissionGranted'] = permissionGranted;
    _settings['calendarPromptDismissed'] = promptDismissed;
    CalendarService.instance.hydratePersistedState(
      events: _calendarEvents.map(CalendarCallEvent.fromJson).toList(),
      permissionGranted: permissionGranted,
      promptDismissed: promptDismissed,
    );
    await _persist();
  }

  static Future<void> clearCalendarEvents() async {
    await ensureInitialized();
    _calendarEvents = [];
    CalendarService.instance.clearEventsLocally();
    await _persist();
  }

  static Future<Map<String, dynamic>> getSettings() async {
    await ensureInitialized();
    final key = (_settings['geminiApiKey']?.toString() ?? '').trim();
    return {
      'geminiConfigured': key.isNotEmpty,
      'geminiKeyMasked': key.length >= 8
          ? '${key.substring(0, 4)}••••••••${key.substring(key.length - 4)}'
          : (key.isNotEmpty ? '••••' : ''),
      'geminiModel': _settings['geminiModel']?.toString() ?? 'gemini-2.5-flash',
      'timezone': _settings['timezone']?.toString() ?? 'America/New_York',
      'googleOAuthClientId':
          _settings['googleOAuthClientId']?.toString() ?? '',
    };
  }

  static Future<void> updateSettings({
    String? geminiApiKey,
    String? geminiModel,
    String? timezone,
    String? googleOAuthClientId,
  }) async {
    await ensureInitialized();
    if (geminiApiKey != null) _settings['geminiApiKey'] = geminiApiKey.trim();
    if (geminiModel != null && geminiModel.trim().isNotEmpty) {
      _settings['geminiModel'] = geminiModel.trim();
    }
    if (timezone != null && timezone.trim().isNotEmpty) {
      _settings['timezone'] = timezone.trim();
    }
    if (googleOAuthClientId != null) {
      _settings['googleOAuthClientId'] = googleOAuthClientId.trim();
    }
    await _persist();
    onDataMutatedForCloudSave?.call();
  }

  static Future<void> runSearchForAllGuests({
    String slotLabel = 'Scheduled Search',
    bool isInitialSearch = false,
    bool isSeedSearch = false,
  }) async {
    if (_isRunningBatch) return;
    _isRunningBatch = true;
    try {
      for (final g in [..._guests]) {
        if (g['active'] == false) continue;
        final id = g['id']?.toString() ?? '';
        if (id.isEmpty) continue;
        try {
          await runSearchForSingleGuest(
            id,
            slotLabel: slotLabel,
            isInitialSearch: isInitialSearch,
            isSeedSearch: isSeedSearch,
          );
        } catch (_) {}
      }
    } finally {
      _isRunningBatch = false;
      onDataMutatedForCloudSave?.call();
    }
  }

  static GuestProfile _buildSingleTargetGuestSpec(
    GuestProfile parentGuest,
    VehicleSearchTarget target,
  ) {
    return GuestProfile(
      id: parentGuest.id,
      name: parentGuest.name,
      phone: parentGuest.phone,
      email: parentGuest.email,
      condition: target.condition,
      minYear: target.minYear,
      maxYear: target.maxYear,
      make: target.make,
      model: target.model,
      trim: target.trim,
      doors: target.doors,
      bedLength: target.bedLength,
      cabStyle: target.cabStyle,
      engineSpec: target.engineSpec,
      maxPrice: target.maxPrice,
      maxMileage: target.maxMileage,
      drivetrain: target.drivetrain,
      exteriorColor: target.exteriorColor,
      features: target.features,
      notes: target.notes,
      vehicleTargets: [target],
      active: parentGuest.active,
      createdAt: parentGuest.createdAt,
    );
  }

  static Future<
      ({
        GuestProfile guest,
        List<VehicleMatch> matches,
        String summary,
      })> addVehicleTargetToGuest({
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
    @visibleForTesting List<Map<String, dynamic>>? mockCandidatesOverride,
  }) async {
    await ensureInitialized();
    final idx = _guests.indexWhere((g) => g['id']?.toString() == guestId);
    if (idx == -1) throw Exception('Guest not found');

    _guests[idx] = _normalizeGuestMap(_guests[idx]);
    final currentHydrated = _hydrateGuest(_guests[idx]);
    final nowIso = DateTime.now().toUtc().toIso8601String();
    final newTargetId = 'vt-${DateTime.now().microsecondsSinceEpoch}';

    final newTargetMap = _normalizeTargetMap(
      <String, dynamic>{
        'id': newTargetId,
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
        'createdAt': nowIso,
      },
      fallbackId: newTargetId,
      fallbackCreatedAt: nowIso,
    );

    final newTargetModel = VehicleSearchTarget.fromJson(newTargetMap);
    final hasAnyCriteria = newTargetModel.make.isNotEmpty ||
        newTargetModel.model.isNotEmpty ||
        newTargetModel.trim.isNotEmpty ||
        newTargetModel.doors.isNotEmpty ||
        newTargetModel.bedLength.isNotEmpty ||
        newTargetModel.exteriorColor.isNotEmpty ||
        newTargetModel.maxPrice != null ||
        newTargetModel.minYear != null ||
        newTargetModel.maxYear != null ||
        newTargetModel.notes.isNotEmpty ||
        newTargetModel.features.isNotEmpty ||
        newTargetModel.condition != 'Any' ||
        newTargetModel.drivetrain != 'Any';
    if (!hasAnyCriteria) {
      throw Exception(
        'Please enter at least a make, model, budget, color, or requirement for the vehicle.',
      );
    }

    // Backfill targetId/targetLabel on legacy single-vehicle matches before adding 2nd vehicle
    if (currentHydrated.effectiveTargets.length == 1) {
      final primaryTarget = currentHydrated.effectiveTargets.first;
      for (var i = 0; i < _matches.length; i++) {
        if (_matches[i]['guestId']?.toString() == guestId &&
            (_matches[i]['targetId']?.toString() ?? '').isEmpty) {
          _matches[i] = <String, dynamic>{
            ..._matches[i],
            'targetId': primaryTarget.id,
            'targetLabel': primaryTarget.label,
          };
        }
      }
    }

    final existingTargets = List<Map<String, dynamic>>.from(
      (_guests[idx]['vehicleTargets'] as List<dynamic>? ?? [])
          .map((e) => Map<String, dynamic>.from(e as Map)),
    );
    existingTargets.add(newTargetMap);

    _guests[idx] = _normalizeGuestMap(<String, dynamic>{
      ..._guests[idx],
      'vehicleTargets': existingTargets,
      'updatedAt': nowIso,
    });
    await _persist();

    final res = await runSearchForSingleGuest(
      guestId,
      slotLabel: 'Added Vehicle Search (${newTargetModel.label})',
      onlyTargetId: newTargetId,
      isInitialSearch: true,
      mockCandidatesOverride: mockCandidatesOverride,
    );
    _recordBackupSnapshotSync(
      label: 'Auto-Backup • Added Vehicle (${currentHydrated.name})',
    );
    await _persist();
    return res;
  }

  static Future<
      ({
        GuestProfile guest,
        List<VehicleMatch> matches,
        String summary,
      })> updateVehicleTargetOnGuest({
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
    @visibleForTesting List<Map<String, dynamic>>? mockCandidatesOverride,
  }) async {
    await ensureInitialized();
    final idx = _guests.indexWhere((g) => g['id']?.toString() == guestId);
    if (idx == -1) throw Exception('Guest not found');

    _guests[idx] = _normalizeGuestMap(_guests[idx]);
    final currentHydrated = _hydrateGuest(_guests[idx]);
    final existingTargets = List<Map<String, dynamic>>.from(
      (_guests[idx]['vehicleTargets'] as List<dynamic>? ?? [])
          .map((e) => Map<String, dynamic>.from(e as Map)),
    );

    var targetIdx = existingTargets.indexWhere(
      (t) => t['id']?.toString() == targetId,
    );
    if (targetIdx == -1 && existingTargets.length == 1) {
      targetIdx = 0;
    }
    if (targetIdx == -1) {
      throw Exception('Vehicle target not found on guest.');
    }

    final oldTarget = existingTargets[targetIdx];
    final oldTargetModel = VehicleSearchTarget.fromJson(oldTarget);
    final resolvedId = (oldTarget['id']?.toString() ?? '').isNotEmpty
        ? oldTarget['id'].toString()
        : targetId;
    final preservedCreatedAt =
        (oldTarget['createdAt']?.toString() ?? '').isNotEmpty
            ? oldTarget['createdAt'].toString()
            : currentHydrated.createdAt;
    final nowIso = DateTime.now().toUtc().toIso8601String();

    final updatedTargetMap = _normalizeTargetMap(
      <String, dynamic>{
        'id': resolvedId,
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
        'createdAt': preservedCreatedAt,
        'criteriaUpdatedAt': nowIso,
      },
      fallbackId: resolvedId,
      fallbackCreatedAt: preservedCreatedAt,
    );

    final updatedTargetModel = VehicleSearchTarget.fromJson(updatedTargetMap);
    final hasAnyCriteria = updatedTargetModel.make.isNotEmpty ||
        updatedTargetModel.model.isNotEmpty ||
        updatedTargetModel.trim.isNotEmpty ||
        updatedTargetModel.doors.isNotEmpty ||
        updatedTargetModel.bedLength.isNotEmpty ||
        updatedTargetModel.exteriorColor.isNotEmpty ||
        updatedTargetModel.maxPrice != null ||
        updatedTargetModel.minYear != null ||
        updatedTargetModel.maxYear != null ||
        updatedTargetModel.notes.isNotEmpty ||
        updatedTargetModel.features.isNotEmpty ||
        updatedTargetModel.condition != 'Any' ||
        updatedTargetModel.drivetrain != 'Any';
    if (!hasAnyCriteria) {
      throw Exception(
        'Please enter at least a make, model, budget, color, or requirement for the vehicle.',
      );
    }

    existingTargets[targetIdx] = updatedTargetMap;
    final validTargetIds = existingTargets
        .map((t) => (t['id']?.toString() ?? '').trim())
        .where((id) => id.isNotEmpty)
        .toSet();

    // Snapshot previous matches by VIN so surviving vehicles preserve original foundAt & Selected Candidate state
    final preservedMatchesByVin = <String, Map<String, dynamic>>{};
    final removedTargetMatches = <Map<String, dynamic>>[];
    for (final m in _matches) {
      if (m['guestId']?.toString() != guestId) continue;
      final v = (m['vin']?.toString() ?? '').trim();
      if (v.isNotEmpty) {
        preservedMatchesByVin[v] = Map<String, dynamic>.from(m);
      }
      final mTid = (m['targetId']?.toString() ?? '').trim();
      final belongsToEdited = existingTargets.length <= 1 ||
          mTid == resolvedId ||
          mTid == targetId ||
          (targetIdx == 0 && mTid.isEmpty) ||
          (mTid.isNotEmpty && !validTargetIds.contains(mTid));
      if (belongsToEdited) {
        removedTargetMatches.add(Map<String, dynamic>.from(m));
      }
    }

    // Remove all previous matches belonging to the edited target (or all guest matches when single-target)
    _matches.removeWhere((m) {
      if (m['guestId']?.toString() != guestId) return false;
      if (existingTargets.length <= 1) return true;
      final mTid = (m['targetId']?.toString() ?? '').trim();
      if (mTid == resolvedId || mTid == targetId) return true;
      if (targetIdx == 0 && mTid.isEmpty) return true;
      if (mTid.isNotEmpty && !validTargetIds.contains(mTid)) return true;
      return false;
    });

    _guests[idx] = _normalizeGuestMap(<String, dynamic>{
      ..._guests[idx],
      'vehicleTargets': existingTargets,
      'updatedAt': nowIso,
      'criteriaUpdatedAt': nowIso,
    });

    final strictAddedSpec = (updatedTargetModel.doors.isNotEmpty &&
            updatedTargetModel.doors != oldTargetModel.doors) ||
        (updatedTargetModel.bedLength.isNotEmpty &&
            updatedTargetModel.bedLength != oldTargetModel.bedLength) ||
        (updatedTargetModel.cabStyle.isNotEmpty &&
            updatedTargetModel.cabStyle != oldTargetModel.cabStyle) ||
        (updatedTargetModel.engineSpec.isNotEmpty &&
            updatedTargetModel.engineSpec != oldTargetModel.engineSpec);

    final res = await runSearchForSingleGuest(
      guestId,
      slotLabel: 'Edited Search (${updatedTargetModel.label})',
      onlyTargetId: resolvedId,
      isInitialSearch: true,
      preservedMatchesByVin: preservedMatchesByVin,
      offlineFallbackTargetMatches: removedTargetMatches,
      offlineStrictMissingSpecs: strictAddedSpec,
      mockCandidatesOverride: mockCandidatesOverride,
    );
    _recordBackupSnapshotSync(
      label: 'Auto-Backup • Edited Search (${currentHydrated.name})',
    );
    await _persist();
    return res;
  }

  static Future<({GuestProfile guest, List<VehicleMatch> matches})>
      removeVehicleTargetFromGuest(String guestId, String targetId) async {
    await ensureInitialized();
    final idx = _guests.indexWhere((g) => g['id']?.toString() == guestId);
    if (idx == -1) throw Exception('Guest not found');

    _guests[idx] = _normalizeGuestMap(_guests[idx]);
    final existingTargets = List<Map<String, dynamic>>.from(
      (_guests[idx]['vehicleTargets'] as List<dynamic>? ?? [])
          .map((e) => Map<String, dynamic>.from(e as Map)),
    );
    if (existingTargets.length <= 1) {
      throw Exception('A guest must have at least one vehicle target.');
    }

    final remaining = existingTargets
        .where((t) => t['id']?.toString() != targetId)
        .toList();
    if (remaining.length == existingTargets.length) {
      throw Exception('Vehicle target not found on guest.');
    }

    final nowIso = DateTime.now().toUtc().toIso8601String();
    _matches.removeWhere(
      (m) =>
          m['guestId']?.toString() == guestId &&
          m['targetId']?.toString() == targetId,
    );

    _guests[idx] = _normalizeGuestMap(<String, dynamic>{
      ..._guests[idx],
      'vehicleTargets': remaining,
      'updatedAt': nowIso,
      'criteriaUpdatedAt': nowIso,
    });
    _pruneNonMatchingMatchesForGuestSync(guestId);
    _recordBackupSnapshotSync(
      label:
          'Auto-Backup • Removed Vehicle (${_guests[idx]['name'] ?? 'Guest'})',
    );
    await _persist();
    onDataMutatedForCloudSave?.call();

    return getGuestWithMatches(guestId);
  }

  static Future<GuestProfile> addGuestNote({
    required String guestId,
    required String text,
  }) async {
    await ensureInitialized();
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      throw Exception('Note text cannot be empty.');
    }

    final idx = _guests.indexWhere((g) => g['id']?.toString() == guestId);
    if (idx == -1) throw Exception('Guest not found');

    _guests[idx] = _normalizeGuestMap(_guests[idx]);
    final nowIso = DateTime.now().toUtc().toIso8601String();
    final newNote = <String, dynamic>{
      'id': 'note-${DateTime.now().microsecondsSinceEpoch}',
      'text': trimmed,
      'createdAt': nowIso,
    };

    final existingNotes = List<Map<String, dynamic>>.from(
      (_guests[idx]['clientNotes'] as List<dynamic>? ?? [])
          .map((e) => Map<String, dynamic>.from(e as Map)),
    );
    existingNotes.insert(0, newNote);

    _guests[idx] = _normalizeGuestMap(<String, dynamic>{
      ..._guests[idx],
      'clientNotes': existingNotes,
      'updatedAt': nowIso,
    });
    _recordBackupSnapshotSync(
      label: 'Auto-Backup • Added Note (${_guests[idx]['name'] ?? 'Guest'})',
    );
    await _persist();
    onDataMutatedForCloudSave?.call();
    return _hydrateGuest(_guests[idx]);
  }

  static Future<GuestProfile> deleteGuestNote({
    required String guestId,
    required String noteId,
  }) async {
    await ensureInitialized();
    final idx = _guests.indexWhere((g) => g['id']?.toString() == guestId);
    if (idx == -1) throw Exception('Guest not found');

    _guests[idx] = _normalizeGuestMap(_guests[idx]);
    final nowIso = DateTime.now().toUtc().toIso8601String();
    final remainingNotes = List<Map<String, dynamic>>.from(
      (_guests[idx]['clientNotes'] as List<dynamic>? ?? [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .where((n) => n['id']?.toString() != noteId),
    );
    final deletedNoteIds = <String>{
      ...((_guests[idx]['deletedNoteIds'] as List<dynamic>?)
              ?.map((e) => e.toString()) ??
          const <String>[]),
      noteId,
    }.toList();

    _guests[idx] = _normalizeGuestMap(<String, dynamic>{
      ..._guests[idx],
      'clientNotes': remainingNotes,
      'deletedNoteIds': deletedNoteIds,
      'updatedAt': nowIso,
    });
    _recordBackupSnapshotSync(
      label: 'Auto-Backup • Removed Note (${_guests[idx]['name'] ?? 'Guest'})',
    );
    await _persist();
    onDataMutatedForCloudSave?.call();
    return _hydrateGuest(_guests[idx]);
  }

  static Future<
      ({
        GuestProfile guest,
        List<VehicleMatch> matches,
        String summary,
      })> runSearchForSingleGuest(
    String guestId, {
    String slotLabel = 'On-Demand Gemini Search',
    String? onlyTargetId,
    bool isInitialSearch = false,
    bool isSeedSearch = false,
    Map<String, Map<String, dynamic>>? preservedMatchesByVin,
    List<Map<String, dynamic>>? offlineFallbackTargetMatches,
    bool offlineStrictMissingSpecs = false,
    @visibleForTesting List<Map<String, dynamic>>? mockCandidatesOverride,
  }) async {
    await ensureInitialized();
    final idx = _guests.indexWhere((g) => g['id']?.toString() == guestId);
    if (idx == -1) throw Exception('Guest not found');

    // Determine BEFORE updating lastSearchedAt whether this client already completed their initial search.
    // Notifications are ONLY emitted for new VIN matches discovered AFTER the initial search!
    final hadCompletedInitialSearch = !isInitialSearch &&
        ((_guests[idx]['initialSearchCompleted'] == true) ||
            ((_guests[idx]['lastSearchedAt']?.toString() ?? '')
                .trim()
                .isNotEmpty));

    // Ensure normalized specs across all vehicleTargets are persisted
    _guests[idx] = _normalizeGuestMap(_guests[idx]);
    final guest = _hydrateGuest(_guests[idx]);
    final allTargets = guest.effectiveTargets;
    final targetsToRun = onlyTargetId != null
        ? allTargets.where((t) => t.id == onlyTargetId).toList()
        : allTargets;

    if (targetsToRun.isEmpty) {
      final unchanged = await getGuestWithMatches(guestId);
      return (
        guest: unchanged.guest,
        matches: unchanged.matches,
        summary: 'No vehicle criteria found to search.',
      );
    }

    int totalCandidatesScanned = 0;
    final bestByVin = <String, Map<String, dynamic>>{};
    final targetSummaries = <String>[];

    for (final target in targetsToRun) {
      final specGuest = _buildSingleTargetGuestSpec(guest, target);
      final candidates = mockCandidatesOverride ??
          await _fetchPrestonCandidates(specGuest);
      final eval = await _evaluateCandidates(specGuest, candidates);
      totalCandidatesScanned += candidates.length;
      targetSummaries.add('${target.label}: ${eval.matches.length} match(es)');

      for (final item in eval.matches) {
        final v = item['vehicle'] as Map<String, dynamic>;
        final vin = v['vin']?.toString() ?? '';
        if (vin.isEmpty) continue;
        final prev = bestByVin[vin];
        final score = (item['matchScore'] as num?)?.toInt() ?? 85;
        final prevScore = (prev?['matchScore'] as num?)?.toInt() ?? 0;
        if (prev == null || score >= prevScore) {
          bestByVin[vin] = <String, dynamic>{
            ...item,
            'targetId': target.id,
            'targetLabel': target.label,
          };
        }
      }
    }

    final nowIso = DateTime.now().toUtc().toIso8601String();

    // Index existing + preserved matches for O(1) VIN lookup when saving 1,000+ matches
    final existingByVin = <String, Map<String, dynamic>>{
      ...?preservedMatchesByVin,
    };
    for (final m in _matches) {
      if (m['guestId']?.toString() == guestId) {
        final v = m['vin']?.toString() ?? '';
        if (v.isNotEmpty) existingByVin[v] = m;
      }
    }

    final seenSet = <String>{
      ...existingByVin.keys,
      ...((_guests[idx]['seenMatchVins'] as List<dynamic>?)
              ?.map((e) => e.toString().trim())
              .where((s) => s.isNotEmpty) ??
          const <String>[]),
    };
    final scheduledCallSet = <String>{
      ...((_guests[idx]['scheduledCallVins'] as List<dynamic>?)
              ?.map((e) => e.toString().trim())
              .where((s) => s.isNotEmpty) ??
          const <String>[]),
    };
    final existingNotifKeys = <String>{
      for (final n in _notifications)
        '${n['guestId']?.toString() ?? ''}::${n['vin']?.toString() ?? ''}',
    };
    final createdAlerts = <MatchAlertNotification>[];
    final vehiclesNeedingCallEvent = <Map<String, dynamic>>[];
    final calPermGranted = CalendarService.instance.permissionGranted;

    if (totalCandidatesScanned > 0 || mockCandidatesOverride != null) {
      if (onlyTargetId != null) {
        final validTargetIds = allTargets.map((t) => t.id).toSet();
        final isPrimaryTarget =
            allTargets.isNotEmpty && allTargets.first.id == onlyTargetId;
        // Keep matches belonging to the guest's other vehicle targets; replace onlyTargetId's matches & duplicate VINs
        _matches.removeWhere((m) {
          if (m['guestId']?.toString() != guestId) return false;
          if (allTargets.length <= 1) return true;
          final mTarget = (m['targetId']?.toString() ?? '').trim();
          final mVin = m['vin']?.toString() ?? '';
          return mTarget == onlyTargetId ||
              (isPrimaryTarget && mTarget.isEmpty) ||
              (mTarget.isNotEmpty && !validTargetIds.contains(mTarget)) ||
              bestByVin.containsKey(mVin);
        });
      } else {
        // Full scan across all vehicleTargets: rebuild cleanly while preserving original foundAt timestamps
        _matches.removeWhere((m) => m['guestId']?.toString() == guestId);
      }

      int seq = 0;
      for (final item in bestByVin.values) {
        final v = item['vehicle'] as Map<String, dynamic>;
        final vin = v['vin']?.toString() ?? '';
        if (vin.isEmpty) continue;
        seq++;

        final isBrandNewVin = !seenSet.contains(vin);
        seenSet.add(vin);

        final needsCallEvent = !scheduledCallSet.contains(vin);
        scheduledCallSet.add(vin);
        if (!isSeedSearch && calPermGranted && needsCallEvent) {
          vehiclesNeedingCallEvent.add(Map<String, dynamic>.from(v));
        }

        final prev = existingByVin[vin];
        _matches.add({
          'id': prev?['id'] ??
              'match-${DateTime.now().microsecondsSinceEpoch}-$seq-$vin',
          'guestId': guestId,
          'vin': vin,
          'stockNumber': v['stockNumber'] ?? '',
          'title': v['title'] ?? '',
          'year': v['year'],
          'make': v['make'] ?? '',
          'model': v['model'] ?? '',
          'trim': v['trim'] ?? '',
          'condition': v['condition'] ?? '',
          'price': v['price'],
          'msrp': v['msrp'],
          'dealerFee': v['dealerFee'],
          'location': v['location'] ?? 'Preston Automotive Group',
          'mileage': v['mileage'] ?? 0,
          'drivetrain': v['drivetrain'] ?? '',
          'engine': v['engine'] ?? '',
          'doors': v['doors'] ?? '',
          'bedLength': v['bedLength'] ?? '',
          'bodyStyle': v['bodyStyle'] ?? '',
          'commentsSummary': v['commentsSummary'] ?? '',
          'exteriorColor': v['exteriorColor'] ?? '',
          'interiorColor': v['interiorColor'] ?? '',
          'photoUrl': v['photoUrl'] ?? '',
          'listingUrl': v['listingUrl'] ?? _prestonBase,
          'matchedFeatures': item['matchedFeatures'] ?? const <String>[],
          'allHighlights': v['highlights'] ?? const <String>[],
          'agentSummary': item['agentSummary'] ?? '',
          'matchScore': item['matchScore'] ?? 85,
          'foundAt': prev?['foundAt'] ?? nowIso,
          'searchSlot': prev?['searchSlot'] ?? slotLabel,
          'lastSeenAt': nowIso,
          'targetId': item['targetId'] ?? '',
          'targetLabel': item['targetLabel'] ?? '',
          'isSelectedCandidate': prev?['isSelectedCandidate'] == true ||
              prev?['isSelectedCandidate'] == 1,
          'selectedAt': prev?['selectedAt'],
          'selectedUpdatedAt': prev?['selectedUpdatedAt'],
        });

        // Fire OS notification ONLY when a brand-new VIN is discovered AFTER initial search
        final notifKey = '$guestId::$vin';
        if (isBrandNewVin &&
            hadCompletedInitialSearch &&
            existingNotifKeys.add(notifKey)) {
          final makeStr = v['make']?.toString() ?? '';
          final modelStr = v['model']?.toString() ?? '';
          final titleStr = v['title']?.toString() ?? '';
          final modelLabel = MatchAlertNotification.extractVehicleModelLabel(
            make: makeStr,
            model: modelStr,
            title: titleStr,
          );
          final message = MatchAlertNotification.formatMessage(
            clientName: guest.name,
            make: makeStr,
            model: modelStr,
            title: titleStr,
          );
          final alert = MatchAlertNotification(
            id: 'notif-${DateTime.now().microsecondsSinceEpoch}-$seq-$vin',
            guestId: guestId,
            guestName: guest.name,
            guestPhone: guest.phone,
            vin: vin,
            vehicleModel: modelLabel,
            vehicleTitle: titleStr,
            message: message,
            location:
                v['location']?.toString() ?? 'Preston Automotive Group',
            price: (v['price'] as num?)?.toDouble(),
            createdAt: nowIso,
            read: false,
          );
          _notifications.insert(0, alert.toJson());
          createdAlerts.add(alert);
        }
      }
    } else if (offlineFallbackTargetMatches != null &&
        targetsToRun.length == 1) {
      // Device is offline during Edit Search: keep ONLY cached vehicles that still satisfy the edited criteria
      final editedTarget = targetsToRun.first;
      for (final cached in offlineFallbackTargetMatches) {
        if (doesStoredMatchSatisfyTarget(
          cached,
          editedTarget,
          strictMissingSpecs: offlineStrictMissingSpecs,
        )) {
          _matches.add(<String, dynamic>{
            ...cached,
            'targetId': editedTarget.id,
            'targetLabel': editedTarget.label,
            'lastSeenAt': nowIso,
          });
        }
      }
    }

    // Always prune any remaining stored matches that no longer satisfy the guest's current targets
    _pruneNonMatchingMatchesForGuestSync(guestId);

    final activeGuestMatches =
        _matches.where((m) => m['guestId']?.toString() == guestId).toList();
    final locCount = (totalCandidatesScanned > 0 || mockCandidatesOverride != null)
        ? bestByVin.values
            .map((m) => (m['vehicle'] as Map)['location']?.toString() ?? '')
            .toSet()
            .length
        : activeGuestMatches
            .map((m) => m['location']?.toString() ?? '')
            .toSet()
            .length;
    final summaryText = (totalCandidatesScanned == 0 &&
            mockCandidatesOverride == null &&
            offlineFallbackTargetMatches != null)
        ? 'Updated criteria to ${targetsToRun.first.label}; filtered cached matches to ${activeGuestMatches.length} qualifying vehicle(s) across $locCount Preston location(s).'
        : (targetsToRun.length > 1
            ? 'Scanned ${targetsToRun.length} vehicle criteria (${targetSummaries.join(' • ')}) — ${bestByVin.length} match(es) across $locCount Preston location(s).'
            : 'Scanned $totalCandidatesScanned live prestonmotor.com vehicles for ${targetsToRun.first.label}; verified ${bestByVin.length} match(es) across $locCount Preston location(s).');

    _guests[idx] = {
      ..._guests[idx],
      'initialSearchCompleted': true,
      'seenMatchVins': seenSet.toList(),
      'scheduledCallVins': scheduledCallSet.toList(),
      'lastSearchedAt': nowIso,
      'lastSearchSummary': summaryText,
      'updatedAt': nowIso,
    };

    if (!isSeedSearch &&
        calPermGranted &&
        vehiclesNeedingCallEvent.isNotEmpty) {
      final freshGuest = _hydrateGuest(_guests[idx]);
      final todayEventDate =
          CalendarCallEvent.computeSameDaySlot(DateTime.now()).eventDate;
      final alreadyHasTodayEvent = CalendarService.instance.events.any(
        (e) => e.guestId == guestId && e.eventDate == todayEventDate,
      );

      final callSheetVehicles = <Map<String, dynamic>>[
        ...vehiclesNeedingCallEvent,
      ];
      if (alreadyHasTodayEvent) {
        final includedVins = <String>{
          for (final v in callSheetVehicles) v['vin']?.toString() ?? '',
        };
        for (final m in _matches) {
          if (m['guestId']?.toString() != guestId) continue;
          final mVin = m['vin']?.toString() ?? '';
          if (mVin.isEmpty || !includedVins.add(mVin)) continue;
          callSheetVehicles.add(Map<String, dynamic>.from(m));
        }
      }

      await CalendarService.instance.scheduleSameDayCallForGuest(
        guest: freshGuest,
        matchedVehicles: callSheetVehicles,
        timeZone: _settings['timezone']?.toString() ?? 'America/New_York',
      );
      _calendarEvents =
          CalendarService.instance.events.map((e) => e.toJson()).toList();
    }

    await _persist();
    if (createdAlerts.isNotEmpty) {
      await MatchNotificationService.instance
          .dispatchNewNotifications(createdAlerts);
    }
    if (!_isRunningBatch) {
      onDataMutatedForCloudSave?.call();
    }

    final updated = await getGuestWithMatches(guestId);
    return (
      guest: updated.guest,
      matches: updated.matches,
      summary: summaryText,
    );
  }

  static String _cleanKeywordFromNotes(String notes) {
    if (notes.trim().isEmpty) return '';
    return notes
        .split(RegExp(r'[.,;\n]'))
        .first
        .replaceAll(
          RegExp(
            r'\b(?:under|below|max|up\s+to|less\s+than|around|budget(?:\s+of)?)\s*\$?\s*\d+(?:,\d{3})*(?:\.\d+)?\s*(?:k|thousand)?\b',
            caseSensitive: false,
          ),
          ' ',
        )
        .replaceAll(
          RegExp(r'\$\s*\d+(?:,\d{3})*(?:\.\d+)?\s*(?:k|thousand)?\b',
              caseSensitive: false),
          ' ',
        )
        .replaceAll(
          RegExp(
              r'\b(?:looking\s+for|wants?|needs?|targeting|a|an|the|at|in|with)\b',
              caseSensitive: false),
          ' ',
        )
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  static Future<void> _refreshPrestonConfig(
    http.Client client, {
    bool force = false,
  }) async {
    final now = DateTime.now();
    if (!force &&
        _configFetchedAt != null &&
        now.difference(_configFetchedAt!) < const Duration(hours: 6)) {
      return;
    }
    try {
      final results = await Future.wait([
        client
            .get(
              Uri.parse('$_prestonBase/searchnew.aspx'),
              headers: const {
                'User-Agent':
                    'Mozilla/5.0 (X11; CrOS x86_64 14541.0.0) AppleWebKit/537.36',
              },
            )
            .timeout(const Duration(seconds: 10)),
        client
            .get(
              Uri.parse('$_prestonBase/searchused.aspx'),
              headers: const {
                'User-Agent':
                    'Mozilla/5.0 (X11; CrOS x86_64 14541.0.0) AppleWebKit/537.36',
              },
            )
            .timeout(const Duration(seconds: 10)),
      ]);

      Map<String, dynamic>? extractSrpModel(String html) {
        final m = RegExp(
          r'''id=["']dlron-srp-model["'][^>]*>([\s\S]*?)</script>''',
          caseSensitive: false,
        ).firstMatch(html);
        if (m == null) return null;
        final raw = jsonDecode((m.group(1) ?? '').trim());
        return raw is Map ? Map<String, dynamic>.from(raw) : null;
      }

      final newModel =
          results[0].statusCode == 200 ? extractSrpModel(results[0].body) : null;
      final usedModel =
          results[1].statusCode == 200 ? extractSrpModel(results[1].body) : null;

      _dealerId = _asInt(newModel?['DealerId']) ??
          _asInt(usedModel?['DealerId']) ??
          _dealerId;
      _newPageId = _asInt(newModel?['PageId']) ?? _newPageId;
      _usedPageId = _asInt(usedModel?['PageId']) ?? _usedPageId;
      _configFetchedAt = now;
    } catch (_) {
      _configFetchedAt = now;
    }
  }

  static Future<List<Map<String, dynamic>>> _fetchPrestonCandidates(
      GuestProfile guest) async {
    final normalizedSpec = NaturalLanguageVehicleParser.parseCriteriaMap({
      'condition': guest.condition,
      'minYear': guest.minYear,
      'maxYear': guest.maxYear,
      'make': guest.make,
      'model': guest.model,
      'trim': guest.trim,
      'bedLength': guest.bedLength,
      'cabStyle': guest.cabStyle,
      'engineSpec': guest.engineSpec,
      'maxPrice': guest.maxPrice,
      'maxMileage': guest.maxMileage,
      'drivetrain': guest.drivetrain,
      'exteriorColor': guest.exteriorColor,
      'features': guest.features,
      'notes': guest.notes,
    });

    final cond =
        (normalizedSpec['condition']?.toString() ?? 'Any').toLowerCase();
    final byVin = <String, Map<String, dynamic>>{};
    final make = (normalizedSpec['make']?.toString() ?? '').trim();
    final model = (normalizedSpec['model']?.toString() ?? '').trim();
    final trim = (normalizedSpec['trim']?.toString() ?? '').trim();
    final bedLength = (normalizedSpec['bedLength']?.toString() ?? '').trim();
    final maxPrice = _asDouble(normalizedSpec['maxPrice']);
    final variants =
        NaturalLanguageVehicleParser.expandPrestonModelVariants(make, model);
    final bedFacets =
        NaturalLanguageVehicleParser.bedLengthToCosmosFacetValues(bedLength);

    final client = http.Client();
    try {
      await _refreshPrestonConfig(client);

      final pageIds = <int>[];
      if (cond == 'new') {
        pageIds.add(_newPageId);
      } else if (cond == 'pre-owned' ||
          cond == 'used' ||
          cond == 'cpo' ||
          cond == 'certified pre-owned') {
        pageIds.add(_usedPageId);
      } else {
        pageIds.addAll([_newPageId, _usedPageId]);
      }

      for (final pid in pageIds) {
        final batch = <Map<String, dynamic>>[];

        // Strategy 0: Exact DMS BedLength facet query when truck bed length is specified (e.g. "6.5ft bed")
        if (bedFacets.isNotEmpty) {
          final targetModels = variants.isNotEmpty ? variants : const [''];
          for (final mv in targetModels) {
            for (final bedFacet in bedFacets) {
              final facetParams = <String, String>{
                'BedLength': bedFacet,
                if (make.isNotEmpty) 'Make': make,
                if (mv.isNotEmpty) 'Model': mv,
              };
              batch.addAll(await _queryAllCosmosPages(
                client,
                pid,
                facetParams,
                maxPrice: maxPrice,
                facetBedLength: bedLength,
              ));
            }
          }
        }

        // Strategy 1: Exact Make + Model facet query across all pages
        if (make.isNotEmpty && variants.isNotEmpty) {
          for (final mv in variants) {
            batch.addAll(await _queryAllCosmosPages(
              client,
              pid,
              {'Make': make, 'Model': mv},
              maxPrice: maxPrice,
            ));
          }
        }

        // Strategy 2: Make-only (or Make + Trim) full multi-page scan — e.g. "Ford under $60K"
        if (make.isNotEmpty && variants.isEmpty) {
          final params = <String, String>{'Make': make};
          if (trim.isNotEmpty) params['q'] = '$make $trim';
          batch.addAll(await _queryAllCosmosPages(
            client,
            pid,
            params,
            maxPrice: maxPrice,
          ));
          if (batch.isEmpty && trim.isNotEmpty) {
            batch.addAll(await _queryAllCosmosPages(
              client,
              pid,
              {'Make': make},
              maxPrice: maxPrice,
            ));
          }
        }

        // Strategy 3: Keyword fallback when Make+Model returned < 5 units or Make was not specified
        if (batch.length < 5 && (make.isEmpty || model.isNotEmpty)) {
          final kw = [make, model, trim].where((s) => s.isNotEmpty).join(' ');
          final qp = <String, String>{};
          if (make.isNotEmpty) qp['Make'] = make;
          if (kw.isNotEmpty) {
            qp['q'] = kw;
          } else {
            final cleaned = _cleanKeywordFromNotes(guest.notes);
            if (cleaned.isNotEmpty) qp['q'] = cleaned;
          }
          if (qp.isNotEmpty) {
            batch.addAll(await _queryAllCosmosPages(
              client,
              pid,
              qp,
              maxPrice: maxPrice,
            ));
          }
        }

        // Strategy 4: Broad full-catalog fallback
        if (batch.isEmpty) {
          final fallback = make.isNotEmpty
              ? <String, String>{'Make': make}
              : <String, String>{};
          batch.addAll(await _queryAllCosmosPages(
            client,
            pid,
            fallback,
            maxPrice: maxPrice,
          ));
        }

        for (final v in batch) {
          final vin = v['vin']?.toString() ?? '';
          if (vin.isEmpty) continue;
          final existing = byVin[vin];
          if (existing == null) {
            byVin[vin] = v;
          } else if ((existing['bedLength']?.toString() ?? '').isEmpty &&
              (v['bedLength']?.toString() ?? '').isNotEmpty) {
            byVin[vin] = <String, dynamic>{
              ...existing,
              'bedLength': v['bedLength'],
              'highlights': v['highlights'],
            };
          }
        }
      }
    } finally {
      client.close();
    }
    return byVin.values.toList();
  }

  static Future<({List<Map<String, dynamic>> vehicles, int totalPages})>
      _querySingleCosmosPage(
    http.Client client,
    int pageId,
    Map<String, String> params,
    int pageNumber, {
    String facetBedLength = '',
  }) async {
    final queryParams = <String, String>{
      ...params,
      'pn': '96',
      'host': _prestonHost,
      if (pageNumber > 1) 'pt': '$pageNumber',
    };
    final uri = Uri.https(
      _prestonHost,
      '/api/vhcliaa/vehicle-pages/cosmos/srp/vehicles/$_dealerId/$pageId',
      queryParams,
    );

    for (int attempt = 0; attempt < 2; attempt++) {
      try {
        final res = await client.get(uri, headers: {
          'User-Agent':
              'Mozilla/5.0 (X11; CrOS x86_64 14541.0.0) AppleWebKit/537.36',
          'Accept': 'application/json',
        }).timeout(const Duration(seconds: 20));

        if (res.statusCode != 200) {
          if (attempt == 0 && res.statusCode != 400) {
            await Future<void>.delayed(const Duration(milliseconds: 350));
            continue;
          }
          return (vehicles: <Map<String, dynamic>>[], totalPages: 1);
        }

        if (res.body.trim().isEmpty) {
          return (vehicles: <Map<String, dynamic>>[], totalPages: 1);
        }

        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final cards = data['DisplayCards'] as List<dynamic>? ?? [];
        final out = <Map<String, dynamic>>[];
        for (final item in cards) {
          if (item is! Map || item['IsAdCard'] == true) continue;
          final vc = item['VehicleCard'];
          if (vc is! Map) continue;
          try {
            final parsed = _parseVehicleCard(
              Map<String, dynamic>.from(vc),
              facetBedLength: facetBedLength,
            );
            if (parsed != null) out.add(parsed);
          } catch (_) {
            // Isolate individual malformed VehicleCard so remaining vehicles on the page still parse
          }
        }

        final paging =
            (data['Paging'] as Map?)?['PaginationDataModel'] as Map?;
        final totalCount = _asInt(paging?['TotalCount']) ?? out.length;
        final pageSize = _asInt(paging?['PageSize']) ?? 96;
        final computedPages =
            pageSize > 0 ? (totalCount / pageSize).ceil() : 1;
        final rawTotalPages = _asInt(paging?['TotalPages']) ?? computedPages;
        final totalPages = rawTotalPages.clamp(1, 45);

        return (vehicles: out, totalPages: totalPages);
      } catch (_) {
        if (attempt == 0) {
          await Future<void>.delayed(const Duration(milliseconds: 350));
          continue;
        }
      }
    }
    return (vehicles: <Map<String, dynamic>>[], totalPages: 1);
  }

  /// Paginates across ALL result pages (pt = 1 .. totalPages, 96 vehicles/page)
  /// in concurrent batches of 3 so every matching vehicle across every Preston
  /// dealership (including Boulevard Ford in Millsboro, DE) is retrieved.
  static Future<List<Map<String, dynamic>>> _queryAllCosmosPages(
    http.Client client,
    int pageId,
    Map<String, String> params, {
    double? maxPrice,
    String facetBedLength = '',
    int concurrency = 3,
  }) async {
    final first = await _querySingleCosmosPage(
      client,
      pageId,
      params,
      1,
      facetBedLength: facetBedLength,
    );
    final all = <Map<String, dynamic>>[...first.vehicles];
    if (first.totalPages <= 1) return all;

    for (int startPt = 2;
        startPt <= first.totalPages;
        startPt += concurrency) {
      final pageNums = <int>[];
      for (int pt = startPt;
          pt < startPt + concurrency && pt <= first.totalPages;
          pt++) {
        pageNums.add(pt);
      }

      final batchRes = await Future.wait(
        pageNums.map(
          (pt) => _querySingleCosmosPage(
            client,
            pageId,
            params,
            pt,
            facetBedLength: facetBedLength,
          ),
        ),
      );

      bool batchAllOverCap = false;
      for (final page in batchRes) {
        all.addAll(page.vehicles);

        if (maxPrice != null && maxPrice > 0 && page.vehicles.length >= 40) {
          final priced = page.vehicles
              .where((v) => (_asDouble(v['price']) ?? 0) > 0)
              .toList();
          if (priced.length >= 40 &&
              priced.every((v) {
                final p = _asDouble(v['price']) ?? 0.0;
                final m = _asDouble(v['msrp']);
                return p > maxPrice * 1.25 &&
                    (m == null || m > maxPrice * 1.25);
              })) {
            batchAllOverCap = true;
          }
        }
      }

      if (batchAllOverCap) break;
    }

    return all;
  }

  static String _formatDealershipLocation(Map<String, dynamic> vc) {
    final city = (vc['DealerLocatedAtCity']?.toString() ?? '').trim();
    final state = (vc['DealerLocatedAtState']?.toString() ?? '').trim();
    final cityState =
        [city, state].where((s) => s.isNotEmpty).join(', ');
    final branch = (vc['VehicleLocationLabel']?.toString() ??
            vc['VehicleLocation']?.toString() ??
            vc['DealerName']?.toString() ??
            'Preston Automotive Group')
        .trim();

    if (cityState.isEmpty) return branch;
    if (city.isNotEmpty &&
        branch.toLowerCase().contains(city.toLowerCase())) {
      if (state.isNotEmpty &&
          !branch.toLowerCase().contains(', ${state.toLowerCase()}')) {
        return '$branch, $state';
      }
      return branch;
    }
    return '$branch ($cityState)';
  }

  static Map<String, dynamic>? _parseVehicleCard(
    Map<String, dynamic> vc, {
    String facetBedLength = '',
  }) {
    final vin = vc['VehicleVin']?.toString() ?? '';
    if (vin.isEmpty) return null;

    double? finalPrice;
    double? msrp;
    double? dealerFee;
    final b64 = vc['VehiclePriceLibrary']?.toString() ?? '';
    if (b64.isNotEmpty) {
      try {
        final decoded = utf8.decode(base64Decode(b64));
        final kv = <String, double>{};
        for (final entry in decoded.split(';')) {
          final idx = entry.indexOf(':');
          if (idx == -1) continue;
          final k = entry.substring(0, idx).trim();
          final v = double.tryParse(entry.substring(idx + 1).trim());
          if (v != null && v > 0) kv[k] = v;
        }
        msrp = kv['MSRP'] ?? kv['calc_MSRP'];
        finalPrice = kv['calc_FINAL PRICE'] ??
            kv['Internet Price'] ??
            kv['Selling Price'] ??
            kv['calc_INTERNET PRICE'] ??
            msrp;
        dealerFee = kv['Dealer Processing Fee'] ?? kv['calc_Dealer Doc Fee'];
      } catch (_) {}
    }

    final vcInternetPrice = _asDouble(vc['VehicleInternetPrice']);
    final vcMsrp = _asDouble(vc['VehicleMsrp']);
    finalPrice ??= (vcInternetPrice != null && vcInternetPrice > 0)
        ? vcInternetPrice
        : ((vcMsrp != null && vcMsrp > 0) ? vcMsrp : null);
    msrp ??= (vcMsrp != null && vcMsrp > 0) ? vcMsrp : null;

    final rawHighlights =
        ((vc['VehicleHighlightsModel'] as Map?)?['Highlights'] as List?)
                ?.map((e) => e.toString())
                .toList() ??
            <String>[];

    final comments = (vc['VehicleComments']?.toString() ?? '')
        .replaceAll(RegExp(r'<[^>]+>'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();

    final bodyStyle =
        (vc['VehicleBodyStyle'] ?? vc['VehicleBodyType'] ?? '').toString();
    final bodyType = (vc['VehicleBodyType'] ?? '').toString();
    final bedLength = NaturalLanguageVehicleParser.extractBedLengthFromVehicle(
      vc,
      fullCommentsClean: comments,
      facetBedLength: facetBedLength,
    );
    final cabStyle = NaturalLanguageVehicleParser.extractCabStyleFromText(
      '$bodyStyle ${vc['VehicleName'] ?? ''} $comments',
    );
    final doors = NaturalLanguageVehicleParser.extractDoorsFromVehicle(
      vc,
      fullCommentsClean: comments,
    );

    final highlights = <String>[...rawHighlights];
    if (bedLength.isNotEmpty) {
      final bedLabel = NaturalLanguageVehicleParser.formatBedLengthLabel(bedLength);
      if (bedLabel.isNotEmpty &&
          !highlights.any((h) => h.toLowerCase().contains(bedLabel.toLowerCase()))) {
        highlights.insert(0, bedLabel);
      }
    }

    final rawDt =
        '${vc['VehicleDriveTrain'] ?? ''} ${rawHighlights.join(' ')} $comments'
            .toUpperCase();
    String drivetrain = '';
    if (rawDt.contains('4X4') || rawDt.contains('FOUR WHEEL DRIVE')) {
      drivetrain = '4WD';
    } else if (rawDt.contains('ALL WHEEL DRIVE') ||
        rawDt.contains('ALL-WHEEL')) {
      drivetrain = 'AWD';
    } else if (rawDt.contains('4WD/AWD')) {
      drivetrain = 'AWD / 4WD';
    } else if (rawDt.contains('4WD')) {
      drivetrain = '4WD';
    } else if (rawDt.contains('FWD')) {
      drivetrain = 'FWD';
    } else if (rawDt.contains('RWD')) {
      drivetrain = 'RWD';
    }

    final imgModel = vc['VehicleImageModel'] as Map?;
    final carousel = imgModel?['VehicleImageCarouselModel'] as Map?;
    final photoList = carousel?['PhotoList'] as List?;
    final rawPhoto = (photoList != null && photoList.isNotEmpty)
        ? photoList.first.toString()
        : (imgModel?['VehiclePhotoSrc']?.toString() ?? '');
    final photoUrl = rawPhoto.isEmpty
        ? ''
        : (rawPhoto.startsWith('http') ? rawPhoto : '$_prestonBase$rawPhoto');

    final rawDetail = imgModel?['VehicleDetailUrl']?.toString() ?? _prestonBase;
    final listingUrl =
        rawDetail.startsWith('http') ? rawDetail : '$_prestonBase$rawDetail';

    final isCpo = vc['VehicleCpo'] == true ||
        vc['VehicleCpo']?.toString().toLowerCase() == 'true';
    final condition = isCpo
        ? 'Certified Pre-Owned'
        : (vc['VehicleCondition']?.toString() ??
            (vc['VehicleType'] == 'new' ? 'New' : 'Pre-Owned'));

    final parsedYear = _asInt(vc['VehicleYear']);
    final fallbackTitle =
        [parsedYear, vc['VehicleMake'], vc['VehicleModel']]
            .where((x) => x != null && x.toString().trim().isNotEmpty)
            .join(' ')
            .trim();
    final rawTitle = (vc['VehicleName']?.toString() ?? '').trim();

    return {
      'vin': vin,
      'stockNumber': vc['VehicleStockNumber']?.toString() ?? '',
      'modelCode': (vc['VehicleModelCode']?.toString() ?? '').trim(),
      'title': rawTitle.isNotEmpty ? rawTitle : fallbackTitle,
      'year': parsedYear,
      'make': (vc['VehicleMake']?.toString() ?? '').trim(),
      'model': (vc['VehicleModel']?.toString() ?? '').trim(),
      'trim': (vc['VehicleTrim'] ?? vc['VehicleRuleAdjustedTrim'] ?? '')
          .toString()
          .trim(),
      'bodyStyle': bodyStyle,
      'bodyType': bodyType,
      'doors': doors,
      'bedLength': bedLength,
      'cabStyle': cabStyle,
      'vehicleLength': _asDouble(vc['Length']),
      'condition': condition,
      'price': finalPrice,
      'msrp': msrp,
      'dealerFee': dealerFee,
      'location': _formatDealershipLocation(vc),
      'dealerCity': (vc['DealerLocatedAtCity']?.toString() ?? '').trim(),
      'dealerState': (vc['DealerLocatedAtState']?.toString() ?? '').trim(),
      'mileage': _asInt(vc['VehicleMileage']) ?? 0,
      'drivetrain': drivetrain,
      'engine': vc['VehicleEngine']?.toString() ?? '',
      'fuelType': vc['VehicleFuelType']?.toString() ?? '',
      'exteriorColor': vc['ExteriorColorLabel']?.toString() ?? '',
      'interiorColor': vc['InteriorColorLabel']?.toString() ?? '',
      'photoUrl': photoUrl,
      'listingUrl': listingUrl,
      'highlights': highlights,
      'commentsSummary':
          comments.length > 900 ? comments.substring(0, 900) : comments,
      'fullCommentsSearchText':
          comments.length > 3500 ? comments.substring(0, 3500) : comments,
    };
  }

  static Map<String, dynamic> _guestToCriteriaMap(GuestProfile guest) {
    return NaturalLanguageVehicleParser.parseCriteriaMap(<String, dynamic>{
      'condition': guest.condition,
      'minYear': guest.minYear,
      'maxYear': guest.maxYear,
      'make': guest.make,
      'model': guest.model,
      'trim': guest.trim,
      'doors': guest.doors,
      'bedLength': guest.bedLength,
      'cabStyle': guest.cabStyle,
      'engineSpec': guest.engineSpec,
      'maxPrice': guest.maxPrice,
      'maxMileage': guest.maxMileage,
      'drivetrain': guest.drivetrain,
      'exteriorColor': guest.exteriorColor,
      'features': guest.features,
      'notes': guest.notes,
    });
  }

  static List<Map<String, dynamic>> _preFilter(
      GuestProfile guest, List<Map<String, dynamic>> candidates) {
    final spec = _guestToCriteriaMap(guest);
    final targetMake = (spec['make']?.toString() ?? '').trim();
    final targetModel = (spec['model']?.toString() ?? '').trim();
    final targetTrim = (spec['trim']?.toString() ?? '').trim();
    final targetDoors = (spec['doors']?.toString() ?? '').trim();
    final targetBed = (spec['bedLength']?.toString() ?? '').trim();
    final targetCab = (spec['cabStyle']?.toString() ?? '').trim();
    final targetEngine = (spec['engineSpec']?.toString() ?? '').trim();
    final targetDt = (spec['drivetrain']?.toString() ?? 'Any').trim();
    final targetColor = (spec['exteriorColor']?.toString() ?? '').trim();
    final targetCondition = (spec['condition']?.toString() ?? 'Any').trim();
    final minYear = _asInt(spec['minYear']);
    final maxYear = _asInt(spec['maxYear']);
    final maxPrice = _asDouble(spec['maxPrice']);
    final maxMileage = _asInt(spec['maxMileage']);
    final locationHints = (spec['locationHints'] as List<dynamic>? ?? const [])
        .map((e) => e.toString())
        .toList();
    final strictPackages =
        (spec['strictPackages'] as List<dynamic>? ?? const [])
            .map((e) => e.toString())
            .toList();

    return candidates.where((v) {
      if (targetMake.isNotEmpty) {
        final m = targetMake.toLowerCase();
        final hay = '${v['make'] ?? ''} ${v['title'] ?? ''}'.toLowerCase();
        if (!hay.contains(m)) return false;
      }

      if (targetModel.isNotEmpty &&
          !NaturalLanguageVehicleParser.doesVehicleMatchModel(targetModel, v)) {
        return false;
      }

      if (targetTrim.isNotEmpty &&
          !NaturalLanguageVehicleParser.doesVehicleMatchTrim(targetTrim, v)) {
        return false;
      }

      if (targetDoors.isNotEmpty &&
          !NaturalLanguageVehicleParser.doesVehicleMatchDoors(targetDoors, v)) {
        return false;
      }

      if (targetBed.isNotEmpty) {
        final vBed = NaturalLanguageVehicleParser.extractBedLengthFromVehicle(
          v,
          fullCommentsClean:
              (v['fullCommentsSearchText'] ?? v['commentsSummary'] ?? '')
                  .toString(),
        );
        if (vBed.isEmpty ||
            vBed.replaceAll("'", '') != targetBed.replaceAll("'", '')) {
          return false;
        }
      }

      if (targetCab.isNotEmpty &&
          !NaturalLanguageVehicleParser.doesVehicleMatchCabStyle(
            targetCab,
            v,
          )) {
        return false;
      }

      if (targetEngine.isNotEmpty &&
          !NaturalLanguageVehicleParser.doesVehicleMatchEngine(
            targetEngine,
            v,
          )) {
        return false;
      }

      if (targetDt.isNotEmpty &&
          targetDt != 'Any' &&
          !NaturalLanguageVehicleParser.doesVehicleMatchDrivetrain(
            targetDt,
            v,
          )) {
        return false;
      }

      if (targetColor.isNotEmpty &&
          !NaturalLanguageVehicleParser.doesVehicleMatchColor(targetColor, v)) {
        return false;
      }

      if (strictPackages.isNotEmpty &&
          !NaturalLanguageVehicleParser.doesVehicleMatchStrictPackages(
            strictPackages,
            v,
          )) {
        return false;
      }

      final yr = _asInt(v['year']);
      if (minYear != null && yr != null && yr < minYear) {
        return false;
      }
      if (maxYear != null && yr != null && yr > maxYear) {
        return false;
      }

      if (maxPrice != null && maxPrice > 0) {
        final pr = _asDouble(v['price']);
        final msrp = _asDouble(v['msrp']);
        final effectivePrice = (pr != null && pr > 0)
            ? pr
            : ((msrp != null && msrp > 0) ? msrp : null);
        if (effectivePrice == null || effectivePrice > maxPrice) {
          return false;
        }
      }

      final mi = _asInt(v['mileage']) ?? 0;
      if (maxMileage != null && mi > maxMileage) {
        return false;
      }

      if (targetCondition.isNotEmpty && targetCondition != 'Any') {
        final c = targetCondition.toLowerCase();
        final vc = (v['condition']?.toString() ?? '').toLowerCase();
        if (c == 'new' && !vc.contains('new')) return false;
        if (c == 'cpo' && !vc.contains('certified')) return false;
        if (c == 'pre-owned' && vc.contains('new') && !vc.contains('pre')) {
          return false;
        }
      }

      if (locationHints.isNotEmpty) {
        final locHay =
            '${v['location'] ?? ''} ${v['dealerCity'] ?? ''} ${v['dealerState'] ?? ''}'
                .toLowerCase();
        if (!locationHints.any((hint) => locHay.contains(hint))) {
          return false;
        }
      }

      return true;
    }).toList();
  }

  static List<Map<String, dynamic>> _deterministicEvaluate(
      GuestProfile guest, List<Map<String, dynamic>> filtered) {
    final spec = _guestToCriteriaMap(guest);
    final strictFiltered = _preFilter(guest, filtered);
    final targetMake = (spec['make']?.toString() ?? '').trim();
    final targetTrim = (spec['trim']?.toString() ?? '').trim();
    final targetDoors = (spec['doors']?.toString() ?? '').trim();
    final targetBed = (spec['bedLength']?.toString() ?? '').trim();
    final targetCab = (spec['cabStyle']?.toString() ?? '').trim();
    final targetEngine = (spec['engineSpec']?.toString() ?? '').trim();
    final targetDt = (spec['drivetrain']?.toString() ?? 'Any').trim();
    final targetColor = (spec['exteriorColor']?.toString() ?? '').trim();
    final maxPrice = _asDouble(spec['maxPrice']);
    final strictPackages =
        (spec['strictPackages'] as List<dynamic>? ?? const [])
            .map((e) => e.toString())
            .toList();

    final out = <Map<String, dynamic>>[];

    for (final v in strictFiltered) {
      final matched = <String>[];
      int score = 84;

      final vBed = NaturalLanguageVehicleParser.extractBedLengthFromVehicle(
        v,
        fullCommentsClean:
            (v['fullCommentsSearchText'] ?? v['commentsSummary'] ?? '')
                .toString(),
      );

      if (targetBed.isNotEmpty) {
        matched.add(
            '${NaturalLanguageVehicleParser.formatBedLengthLabel(targetBed)} (Verified)');
        score += 6;
      } else if (vBed.isNotEmpty) {
        matched.add(NaturalLanguageVehicleParser.formatBedLengthLabel(vBed));
      }

      final vTrim = (v['trim']?.toString() ?? '').trim();
      if (targetTrim.isNotEmpty) {
        matched.add('${vTrim.isNotEmpty ? vTrim : targetTrim} Trim Package');
        score += 5;
      } else if (vTrim.isNotEmpty) {
        matched.add('$vTrim Trim');
      }

      if (targetDoors.isNotEmpty) {
        matched.add(
            '${NaturalLanguageVehicleParser.formatDoorsLabel(targetDoors)} Configuration');
        score += 4;
      }

      if (targetCab.isNotEmpty) {
        final bStyle = (v['bodyStyle']?.toString() ?? '').trim();
        matched.add(bStyle.isNotEmpty ? bStyle : targetCab);
        score += 3;
      }

      if (targetEngine.isNotEmpty) {
        matched.add('$targetEngine Powertrain');
        score += 3;
      }

      final vDt = (v['drivetrain']?.toString() ?? '').trim();
      if (targetDt.isNotEmpty && targetDt != 'Any') {
        matched.add('${vDt.isNotEmpty ? vDt : targetDt} Drivetrain');
        score += 4;
      } else if (vDt.isNotEmpty) {
        matched.add('$vDt Drivetrain');
      }

      if (targetMake.isNotEmpty && (v['make']?.toString() ?? '').isNotEmpty) {
        matched.add(
            '${v['year'] ?? ''} ${v['make']} ${v['model']} (${v['condition']})'
                .trim());
      }

      final pr = _asDouble(v['price']);
      if (maxPrice != null && pr != null) {
        final diff = (maxPrice - pr).round();
        matched.add(diff > 0
            ? '\$${pr.toStringAsFixed(0)} Preston Price (\$$diff under \$${maxPrice.toStringAsFixed(0)} cap)'
            : 'Within \$${maxPrice.toStringAsFixed(0)} Budget');
        score += 4;
      }

      if (targetColor.isNotEmpty &&
          (v['exteriorColor']?.toString() ?? '').isNotEmpty) {
        matched.add('${v['exteriorColor']} Exterior');
        score += 3;
      }

      for (final pkg in strictPackages) {
        matched.add(pkg);
        score += 3;
      }

      final highlights = (v['highlights'] as List<dynamic>? ?? [])
          .map((e) => e.toString())
          .toList();
      for (final req in guest.features) {
        final hit = highlights.firstWhere(
          (h) => h.toLowerCase().contains(req.toLowerCase()),
          orElse: () => '',
        );
        if (hit.isNotEmpty) {
          matched.add(hit);
          score += 2;
        }
      }
      for (final h in highlights.take(6)) {
        if (matched.length >= 6) break;
        final hLower = h.toLowerCase();
        final alreadyCovered = matched.any(
          (mf) =>
              mf.toLowerCase() == hLower ||
              mf.toLowerCase().contains(hLower) ||
              (hLower == '4wd/awd' && mf.toLowerCase().contains('drivetrain')),
        );
        if (!alreadyCovered) matched.add(h);
      }

      out.add({
        'vehicle': v,
        'matchScore': score.clamp(1, 99),
        'matchedFeatures': matched.toSet().take(8).toList(),
        'agentSummary':
            'Verified match at ${v['location']}: ${v['title']} (${v['condition']}) priced at ${pr != null ? '\$${pr.toStringAsFixed(0)}' : 'Call for Price'} meets ${guest.name}\'s ${guest.targetVehicleLabel} criteria.',
      });
    }

    out.sort((a, b) {
      final sa = _asInt(a['matchScore']) ?? 80;
      final sb = _asInt(b['matchScore']) ?? 80;
      if (sb != sa) return sb.compareTo(sa);
      final pa = _asDouble((a['vehicle'] as Map)['price']) ?? double.maxFinite;
      final pb = _asDouble((b['vehicle'] as Map)['price']) ?? double.maxFinite;
      return pa.compareTo(pb);
    });

    return out;
  }

  static List<Map<String, dynamic>> _sampleAcrossLocations(
      List<Map<String, dynamic>> vehicles, int limit) {
    if (vehicles.length <= limit) return vehicles;
    final byLoc = <String, List<Map<String, dynamic>>>{};
    for (final v in vehicles) {
      final loc = v['location']?.toString() ?? 'Preston Automotive Group';
      byLoc.putIfAbsent(loc, () => []).add(v);
    }
    final picked = <Map<String, dynamic>>[];
    int idx = 0;
    while (picked.length < limit) {
      bool added = false;
      for (final list in byLoc.values) {
        if (idx < list.length) {
          picked.add(list[idx]);
          added = true;
          if (picked.length >= limit) break;
        }
      }
      if (!added) break;
      idx++;
    }
    return picked;
  }

  static Future<({List<Map<String, dynamic>> matches, String summary})>
      _evaluateCandidates(
          GuestProfile guest, List<Map<String, dynamic>> candidates) async {
    final filtered = _preFilter(guest, candidates);
    if (filtered.isEmpty) {
      return (
        matches: <Map<String, dynamic>>[],
        summary:
            'Scanned ${candidates.length} live prestonmotor.com vehicles; 0 met ${guest.targetVehicleLabel} criteria.',
      );
    }

    final fullDeterministic = _deterministicEvaluate(guest, filtered);
    final detByVin = <String, Map<String, dynamic>>{
      for (final dm in fullDeterministic)
        (dm['vehicle'] as Map)['vin'].toString(): dm,
    };
    final apiKey = (_settings['geminiApiKey']?.toString() ?? '').trim();
    final model = _settings['geminiModel']?.toString() ?? 'gemini-2.5-flash';

    if (apiKey.isNotEmpty) {
      try {
        final sampled = _sampleAcrossLocations(filtered, 30);
        final compact = sampled
            .map((v) => {
                  'vin': v['vin'],
                  'title': v['title'],
                  'make': v['make'],
                  'model': v['model'],
                  'trim': v['trim'],
                  'bodyStyle': v['bodyStyle'],
                  'doors': v['doors'],
                  'bedLength': v['bedLength'],
                  'condition': v['condition'],
                  'price': v['price'],
                  'location': v['location'],
                  'mileage': v['mileage'],
                  'drivetrain': v['drivetrain'],
                  'exteriorColor': v['exteriorColor'],
                  'highlights': v['highlights'],
                  'comments': v['commentsSummary'],
                })
            .toList();

        final uri = Uri.parse(
            'https://generativelanguage.googleapis.com/v1beta/models/${Uri.encodeComponent(model)}:generateContent?key=${Uri.encodeComponent(apiKey)}');
        final res = await http
            .post(
              uri,
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({
                'systemInstruction': {
                  'parts': [
                    {
                      'text':
                          'Evaluate live prestonmotor.com vehicles against the guest\'s exact requirements (make, exact model, exact trim, doors, bedLength, cabStyle, drivetrain, exteriorColors — matching ANY listed color when multiple colors are chosen — and budget). Only include vehicles that satisfy every specified criterion. Return JSON with overallSummary and matches (array of {vin, matchScore, matchedFeatures, agentSummary}).'
                    }
                  ]
                },
                'contents': [
                  {
                    'role': 'user',
                    'parts': [
                      {
                        'text': jsonEncode({
                          'guest': {
                            'name': guest.name,
                            'target': guest.targetVehicleLabel,
                            'make': guest.make,
                            'model': guest.model,
                            'trim': guest.trim,
                            'doors': guest.doors,
                            'bedLength': guest.bedLength,
                            'cabStyle': guest.cabStyle,
                            'drivetrain': guest.drivetrain,
                            'exteriorColor': guest.exteriorColor,
                            'exteriorColors': NaturalLanguageVehicleParser
                                .parseExteriorColors(guest.exteriorColor),
                            'maxPrice': guest.maxPrice,
                            'features': guest.features,
                            'notes': guest.notes,
                          },
                          'totalQualifyingCount': filtered.length,
                          'candidatesSample': compact,
                        })
                      }
                    ]
                  }
                ],
                'generationConfig': {
                  'temperature': 0.1,
                  'responseMimeType': 'application/json',
                  'responseSchema': {
                    'type': 'OBJECT',
                    'properties': {
                      'overallSummary': {'type': 'STRING'},
                      'matches': {
                        'type': 'ARRAY',
                        'items': {
                          'type': 'OBJECT',
                          'properties': {
                            'vin': {'type': 'STRING'},
                            'matchScore': {'type': 'INTEGER'},
                            'matchedFeatures': {
                              'type': 'ARRAY',
                              'items': {'type': 'STRING'},
                            },
                            'agentSummary': {'type': 'STRING'},
                          },
                          'required': [
                            'vin',
                            'matchScore',
                            'matchedFeatures',
                            'agentSummary',
                          ],
                        },
                      },
                    },
                    'required': ['overallSummary', 'matches'],
                  },
                }
              }),
            )
            .timeout(const Duration(seconds: 25));

        if (res.statusCode == 200) {
          final body = jsonDecode(res.body) as Map<String, dynamic>;
          final text = body['candidates']?[0]?['content']?['parts']?[0]?['text']
                  ?.toString() ??
              '{}';
          final parsed = jsonDecode(text) as Map<String, dynamic>;
          final byVin = {for (final v in filtered) v['vin'].toString(): v};
          final geminiByVin = <String, Map<String, dynamic>>{};

          for (final m in (parsed['matches'] as List<dynamic>? ?? [])) {
            if (m is! Map) continue;
            final vin = m['vin']?.toString() ?? '';
            final v = byVin[vin];
            if (v == null || !detByVin.containsKey(vin)) continue;
            final detFeatures =
                (detByVin[vin]?['matchedFeatures'] as List<dynamic>? ?? const [])
                    .map((e) => e.toString())
                    .toList();
            final combinedFeatures = <String>{
              if (guest.doors.isNotEmpty)
                '${NaturalLanguageVehicleParser.formatDoorsLabel(guest.doors)} Configuration',
              if (guest.bedLength.isNotEmpty)
                '${NaturalLanguageVehicleParser.formatBedLengthLabel(guest.bedLength)} (Verified)',
              if (guest.trim.isNotEmpty)
                '${(v['trim']?.toString() ?? '').isNotEmpty ? v['trim'] : guest.trim} Trim Package',
              ...((m['matchedFeatures'] as List<dynamic>? ?? const [])
                  .map((e) => e.toString())),
              ...detFeatures,
            }.take(8).toList();

            geminiByVin[vin] = {
              'vehicle': v,
              'matchScore': _asInt(m['matchScore']) ?? 90,
              'matchedFeatures': combinedFeatures,
              'agentSummary': m['agentSummary']?.toString() ??
                  (detByVin[vin]?['agentSummary']?.toString() ?? ''),
            };
          }

          final hasCustomNotes = guest.notes.trim().isNotEmpty;
          List<Map<String, dynamic>> merged;
          if (geminiByVin.isEmpty) {
            merged = fullDeterministic;
          } else if (filtered.length <= 30 && hasCustomNotes) {
            merged = geminiByVin.values.toList();
          } else {
            merged = fullDeterministic.map((dm) {
              final vin = (dm['vehicle'] as Map)['vin'].toString();
              return geminiByVin[vin] ?? dm;
            }).toList();
          }

          final locCount = merged
              .map((m) => (m['vehicle'] as Map)['location']?.toString() ?? '')
              .toSet()
              .length;
          return (
            matches: merged,
            summary:
                'Gemini Agent ($model) scanned ${candidates.length} prestonmotor.com vehicles and verified ${merged.length} match(es) across $locCount Preston location(s).',
          );
        }
      } catch (_) {}
    }

    final locCount = fullDeterministic
        .map((m) => (m['vehicle'] as Map)['location']?.toString() ?? '')
        .toSet()
        .length;
    return (
      matches: fullDeterministic,
      summary:
          'Scanned ${candidates.length} live prestonmotor.com vehicles across all pages; found ${fullDeterministic.length} match(es) across $locCount Preston dealership location(s).',
    );
  }

  // --- Multi-Device Google Drive Cloud Sync & Auth Persistence ---

  static Future<Map<String, dynamic>> getLocalAuthConfig() async {
    await ensureInitialized();
    final session = _settings['googleAuthSession'];
    return <String, dynamic>{
      'googleOAuthClientId':
          _settings['googleOAuthClientId']?.toString() ?? '',
      'googleOAuthClientSecret':
          _settings['googleOAuthClientSecret']?.toString() ?? '',
      'syncServerUrl': _settings['syncServerUrl']?.toString() ?? '',
      'driveSyncFileId': _settings['driveSyncFileId']?.toString() ?? '',
      'session': session is Map
          ? Map<String, dynamic>.from(session)
          : <String, dynamic>{},
    };
  }

  static Future<void> saveLocalAuthConfig({
    String? googleOAuthClientId,
    String? googleOAuthClientSecret,
    String? syncServerUrl,
    String? driveSyncFileId,
    Map<String, dynamic>? session,
  }) async {
    await ensureInitialized();
    if (googleOAuthClientId != null) {
      _settings['googleOAuthClientId'] = googleOAuthClientId.trim();
    }
    if (googleOAuthClientSecret != null) {
      _settings['googleOAuthClientSecret'] = googleOAuthClientSecret.trim();
    }
    if (syncServerUrl != null) {
      _settings['syncServerUrl'] = syncServerUrl.trim();
    }
    if (driveSyncFileId != null) {
      _settings['driveSyncFileId'] = driveSyncFileId.trim();
    }
    if (session != null) {
      _settings['googleAuthSession'] = session;
    }
    await _persist();
  }

  static Future<Map<String, dynamic>> exportCloudSnapshot({
    String deviceLabel = 'Preston Guest Scout Device',
  }) async {
    await ensureInitialized();
    return _buildCloudSnapshotSync(deviceLabel: deviceLabel);
  }

  static Map<String, dynamic> _buildCloudSnapshotSync({
    String deviceLabel = 'Preston Guest Scout Device',
  }) {
    final compactMatches = _matches.map((m) {
      final hl = (m['allHighlights'] as List<dynamic>? ?? [])
          .take(8)
          .map((e) => e.toString())
          .toList();
      return <String, dynamic>{
        ...m,
        'allHighlights': hl,
      };
    }).toList();

    return <String, dynamic>{
      'schemaVersion': 2,
      'updatedAt': DateTime.now().toUtc().toIso8601String(),
      'updatedByDevice': deviceLabel,
      'guests': _guests,
      'deletedGuestIds': Map<String, String>.from(_deletedGuestIds),
      'matches': compactMatches,
      'backups': _backups.take(maxBackups).toList(),
      'settings': <String, dynamic>{
        'geminiModel': _settings['geminiModel']?.toString() ?? 'gemini-2.5-flash',
        'timezone': _settings['timezone']?.toString() ?? 'America/New_York',
        'geminiApiKey': _settings['geminiApiKey']?.toString() ?? '',
        'googleOAuthClientId':
            _settings['googleOAuthClientId']?.toString() ?? '',
      },
    };
  }

  /// Conflict-free multi-device merge of remote Google Drive snapshot into local store.
  /// Preserves guests created/updated on any device, applies delete tombstones across
  /// devices, merges vehicle matches by (guestId, vin) keeping earliest foundAt, and
  /// dispatches Android notifications for brand-new matches found after a guest's initial search.
  static Future<({int totalGuests, int totalMatches, bool localChanged})>
      mergeCloudSnapshot(Map<String, dynamic> remote) async {
    await ensureInitialized();

    // Snapshot pre-merge seen VINs for guests who ALREADY completed their initial search on this device
    final preMergeSeenByGuest = <String, Set<String>>{};
    for (final g in _guests) {
      final gid = g['id']?.toString() ?? '';
      if (gid.isEmpty) continue;
      final initialDone = (g['initialSearchCompleted'] == true) ||
          ((g['lastSearchedAt']?.toString() ?? '').trim().isNotEmpty);
      if (!initialDone) continue;

      final seen = <String>{
        ...((g['seenMatchVins'] as List<dynamic>?)
                ?.map((e) => e.toString().trim())
                .where((s) => s.isNotEmpty) ??
            const <String>[]),
      };
      for (final m in _matches) {
        if (m['guestId']?.toString() == gid) {
          final v = (m['vin']?.toString() ?? '').trim();
          if (v.isNotEmpty) seen.add(v);
        }
      }
      preMergeSeenByGuest[gid] = seen;
    }

    final existingNotifKeys = <String>{
      for (final n in _notifications)
        '${n['guestId']?.toString() ?? ''}::${n['vin']?.toString() ?? ''}',
    };

    final res = _mergeCloudSnapshotSync(remote);

    final cloudAlerts = <MatchAlertNotification>[];
    if (preMergeSeenByGuest.isNotEmpty) {
      final guestById = <String, Map<String, dynamic>>{
        for (final g in _guests) (g['id']?.toString() ?? ''): g,
      };
      final nowIso = DateTime.now().toUtc().toIso8601String();
      int seq = 0;

      for (final m in _matches) {
        final gid = m['guestId']?.toString() ?? '';
        final vin = (m['vin']?.toString() ?? '').trim();
        if (gid.isEmpty || vin.isEmpty) continue;

        final prevSeen = preMergeSeenByGuest[gid];
        if (prevSeen == null || prevSeen.contains(vin)) continue;
        prevSeen.add(vin);

        final notifKey = '$gid::$vin';
        if (!existingNotifKeys.add(notifKey)) continue;

        final gMap = guestById[gid];
        final guestName = (gMap?['name']?.toString() ?? 'Guest').trim();
        final guestPhone = (gMap?['phone']?.toString() ?? '').trim();
        final makeStr = m['make']?.toString() ?? '';
        final modelStr = m['model']?.toString() ?? '';
        final titleStr = m['title']?.toString() ?? '';
        final modelLabel = MatchAlertNotification.extractVehicleModelLabel(
          make: makeStr,
          model: modelStr,
          title: titleStr,
        );
        final message = MatchAlertNotification.formatMessage(
          clientName: guestName,
          make: makeStr,
          model: modelStr,
          title: titleStr,
        );
        seq++;
        final alert = MatchAlertNotification(
          id: 'notif-cloud-${DateTime.now().microsecondsSinceEpoch}-$seq-$vin',
          guestId: gid,
          guestName: guestName,
          guestPhone: guestPhone,
          vin: vin,
          vehicleModel: modelLabel,
          vehicleTitle: titleStr,
          message: message,
          location: m['location']?.toString() ?? 'Preston Automotive Group',
          price: _asDouble(m['price']),
          createdAt: m['foundAt']?.toString() ?? nowIso,
          read: false,
        );
        _notifications.insert(0, alert.toJson());
        cloudAlerts.add(alert);
      }
    }

    if (res.localChanged || cloudAlerts.isNotEmpty) {
      await _persist();
    } else {
      await _syncWidget();
    }
    if (cloudAlerts.isNotEmpty) {
      await MatchNotificationService.instance
          .dispatchNewNotifications(cloudAlerts);
    }
    unawaited(_repairZeroScannedGuestsIfNeeded());
    return res;
  }

  static ({int totalGuests, int totalMatches, bool localChanged})
      _mergeCloudSnapshotSync(Map<String, dynamic> remote) {
    bool localChanged = false;

    // 1. Merge remote deletedGuestIds tombstones
    final remoteDeleted = remote['deletedGuestIds'];
    if (remoteDeleted is Map) {
      remoteDeleted.forEach((key, value) {
        final delId = key?.toString() ?? '';
        final delIso = value?.toString() ?? '';
        if (delId.isEmpty || delIso.isEmpty) return;

        final prevTomb = _deletedGuestIds[delId] ?? '';
        if (delIso.compareTo(prevTomb) > 0) {
          _deletedGuestIds[delId] = delIso;
        }

        final existingIdx =
            _guests.indexWhere((g) => g['id']?.toString() == delId);
        if (existingIdx != -1) {
          final existing = _guests[existingIdx];
          final localStamp = (existing['updatedAt'] ??
                  existing['lastSearchedAt'] ??
                  existing['createdAt'] ??
                  '')
              .toString();
          if (delIso.compareTo(localStamp) >= 0) {
            _guests.removeAt(existingIdx);
            _matches.removeWhere((m) => m['guestId']?.toString() == delId);
            localChanged = true;
          }
        }
      });
    }

    // 2. Merge remote guests
    final localGuestsById = <String, int>{};
    for (var i = 0; i < _guests.length; i++) {
      final id = _guests[i]['id']?.toString() ?? '';
      if (id.isNotEmpty) localGuestsById[id] = i;
    }

    final remoteGuests = remote['guests'];
    if (remoteGuests is List) {
      for (final item in remoteGuests) {
        if (item is! Map) continue;
        final rg = _normalizeGuestMap(Map<String, dynamic>.from(item));
        final id = rg['id']?.toString() ?? '';
        final name = rg['name']?.toString() ?? '';
        if (id.isEmpty || name.isEmpty) continue;

        final rgStamp = (rg['updatedAt'] ??
                rg['lastSearchedAt'] ??
                rg['createdAt'] ??
                DateTime.now().toUtc().toIso8601String())
            .toString();
        rg['updatedAt'] = rgStamp;

        final tomb = _deletedGuestIds[id];
        if (tomb != null && tomb.compareTo(rgStamp) >= 0) continue;

        final existingIdx = localGuestsById[id];
        if (existingIdx == null) {
          _guests.add(rg);
          localGuestsById[id] = _guests.length - 1;
          localChanged = true;
        } else {
          final existing = _normalizeGuestMap(_guests[existingIdx]);
          final localStamp = (existing['updatedAt'] ??
                  existing['lastSearchedAt'] ??
                  existing['createdAt'] ??
                  '')
              .toString();

          // Conflict-free union merge of dated clientNotes + deletedNoteIds across devices
          final mergedDelSet = <String>{
            ...((existing['deletedNoteIds'] as List<dynamic>?)
                    ?.map((e) => e.toString()) ??
                const <String>[]),
            ...((rg['deletedNoteIds'] as List<dynamic>?)
                    ?.map((e) => e.toString()) ??
                const <String>[]),
          };
          final notesById = <String, Map<String, dynamic>>{};
          for (final n in [
            ...(existing['clientNotes'] as List<dynamic>? ?? []),
            ...(rg['clientNotes'] as List<dynamic>? ?? []),
          ]) {
            if (n is! Map) continue;
            final nid = n['id']?.toString() ?? '';
            final ntext = (n['text']?.toString() ?? '').trim();
            if (nid.isEmpty || ntext.isEmpty || mergedDelSet.contains(nid)) {
              continue;
            }
            notesById[nid] = Map<String, dynamic>.from(n);
          }
          final mergedNotesList = notesById.values.toList()
            ..sort((a, b) => (b['createdAt'] ?? '')
                .toString()
                .compareTo((a['createdAt'] ?? '').toString()));

          final mergedSeenVins = <String>{
            ...((existing['seenMatchVins'] as List<dynamic>?)
                    ?.map((e) => e.toString().trim())
                    .where((s) => s.isNotEmpty) ??
                const <String>[]),
            ...((rg['seenMatchVins'] as List<dynamic>?)
                    ?.map((e) => e.toString().trim())
                    .where((s) => s.isNotEmpty) ??
                const <String>[]),
          };
          final mergedScheduledVins = <String>{
            ...((existing['scheduledCallVins'] as List<dynamic>?)
                    ?.map((e) => e.toString().trim())
                    .where((s) => s.isNotEmpty) ??
                const <String>[]),
            ...((rg['scheduledCallVins'] as List<dynamic>?)
                    ?.map((e) => e.toString().trim())
                    .where((s) => s.isNotEmpty) ??
                const <String>[]),
          };
          final mergedInitialDone =
              (existing['initialSearchCompleted'] == true) ||
                  (rg['initialSearchCompleted'] == true);

          if (rgStamp.compareTo(localStamp) > 0) {
            _guests[existingIdx] = _normalizeGuestMap(<String, dynamic>{
              ...rg,
              'clientNotes': mergedNotesList,
              'deletedNoteIds': mergedDelSet.toList(),
              'initialSearchCompleted': mergedInitialDone,
              'seenMatchVins': mergedSeenVins.toList(),
              'scheduledCallVins': mergedScheduledVins.toList(),
            });
            localChanged = true;
          } else {
            final prevNotesLen =
                (existing['clientNotes'] as List<dynamic>? ?? []).length;
            final prevDelLen =
                (existing['deletedNoteIds'] as List<dynamic>? ?? []).length;
            final prevSeenLen =
                (existing['seenMatchVins'] as List<dynamic>? ?? []).length;
            final prevSchedLen =
                (existing['scheduledCallVins'] as List<dynamic>? ?? []).length;
            if (mergedNotesList.length != prevNotesLen ||
                mergedDelSet.length != prevDelLen ||
                mergedSeenVins.length != prevSeenLen ||
                mergedScheduledVins.length != prevSchedLen ||
                mergedInitialDone !=
                    (existing['initialSearchCompleted'] == true)) {
              _guests[existingIdx] = _normalizeGuestMap(<String, dynamic>{
                ...existing,
                'clientNotes': mergedNotesList,
                'deletedNoteIds': mergedDelSet.toList(),
                'initialSearchCompleted': mergedInitialDone,
                'seenMatchVins': mergedSeenVins.toList(),
                'scheduledCallVins': mergedScheduledVins.toList(),
              });
              localChanged = true;
            }
          }
        }
      }
    }

    // Sort guests newest-first by createdAt
    _guests.sort((a, b) => (b['createdAt'] ?? '')
        .toString()
        .compareTo((a['createdAt'] ?? '').toString()));

    // 3. Merge remote matches for active non-deleted guests (rejecting pre-edit or non-matching vehicles)
    final activeGuestsById = <String, GuestProfile>{};
    for (final g in _guests) {
      final gid = (g['id']?.toString() ?? '').trim();
      if (gid.isNotEmpty) {
        activeGuestsById[gid] = GuestProfile.fromJson(_normalizeGuestMap(g));
      }
    }

    final beforePruneLen = _matches.length;
    _matches.removeWhere((m) {
      final gid = (m['guestId']?.toString() ?? '').trim();
      final mergedGuest = activeGuestsById[gid];
      if (mergedGuest == null) return true;
      return resolveMatchingTargetForStoredMatch(m, mergedGuest) == null;
    });
    if (_matches.length != beforePruneLen) {
      localChanged = true;
    }

    final localMatchesByKey = <String, int>{};
    for (var i = 0; i < _matches.length; i++) {
      final gid = _matches[i]['guestId']?.toString() ?? '';
      final vin = _matches[i]['vin']?.toString() ?? '';
      if (gid.isNotEmpty && vin.isNotEmpty) {
        localMatchesByKey['$gid::$vin'] = i;
      }
    }

    final remoteMatches = remote['matches'];
    if (remoteMatches is List) {
      for (final item in remoteMatches) {
        if (item is! Map) continue;
        final rm = Map<String, dynamic>.from(item);
        final gid = rm['guestId']?.toString() ?? '';
        final vin = rm['vin']?.toString() ?? '';
        final mergedGuest = activeGuestsById[gid];
        if (gid.isEmpty || vin.isEmpty || mergedGuest == null) {
          continue;
        }

        final matchedTarget = resolveMatchingTargetForStoredMatch(
          rm,
          mergedGuest,
        );
        if (matchedTarget == null) {
          localChanged = true;
          continue;
        }

        final key = '$gid::$vin';
        final rmSeen = (rm['lastSeenAt'] ?? rm['foundAt'] ?? '').toString();
        final existingIdx = localMatchesByKey[key];

        if (existingIdx == null) {
          final rmTid = (rm['targetId']?.toString() ?? '').trim();
          final guestTargets = mergedGuest.effectiveTargets;
          if (rmTid.isNotEmpty &&
              guestTargets.length > 1 &&
              !guestTargets.any((t) => t.id == rmTid)) {
            localChanged = true;
            continue;
          }
          final targetCutoff =
              (matchedTarget.criteriaUpdatedAt ?? mergedGuest.criteriaUpdatedAt ?? '')
                  .trim();
          if (targetCutoff.isNotEmpty &&
              rmSeen.isNotEmpty &&
              rmSeen.compareTo(targetCutoff) < 0) {
            localChanged = true;
            continue;
          }

          _matches.add(<String, dynamic>{
            ...rm,
            if ((rm['targetId']?.toString() ?? '').trim().isEmpty)
              'targetId': matchedTarget.id,
          });
          localMatchesByKey[key] = _matches.length - 1;
          localChanged = true;
        } else {
          final existing = _matches[existingIdx];
          final localSeen =
              (existing['lastSeenAt'] ?? existing['foundAt'] ?? '').toString();
          final rmSelUpd =
              (rm['selectedUpdatedAt'] ?? rm['selectedAt'] ?? '').toString();
          final locSelUpd =
              (existing['selectedUpdatedAt'] ?? existing['selectedAt'] ?? '')
                  .toString();
          final remoteSelWins = (rmSelUpd.isNotEmpty &&
                  rmSelUpd.compareTo(locSelUpd) >= 0) ||
              (locSelUpd.isEmpty &&
                  (rm['isSelectedCandidate'] == true ||
                      rm['isSelectedCandidate'] == 1));
          final mergedIsSel = remoteSelWins
              ? (rm['isSelectedCandidate'] == true ||
                  rm['isSelectedCandidate'] == 1)
              : (existing['isSelectedCandidate'] == true ||
                  existing['isSelectedCandidate'] == 1);
          final mergedSelAt =
              remoteSelWins ? rm['selectedAt'] : existing['selectedAt'];
          final mergedSelUpd =
              remoteSelWins ? rm['selectedUpdatedAt'] : existing['selectedUpdatedAt'];

          if (rmSeen.compareTo(localSeen) > 0) {
            final localFound = (existing['foundAt'] ?? rmSeen).toString();
            final remoteFound = (rm['foundAt'] ?? rmSeen).toString();
            final earliestFound =
                remoteFound.isNotEmpty && remoteFound.compareTo(localFound) < 0
                    ? remoteFound
                    : localFound;
            _matches[existingIdx] = <String, dynamic>{
              ...existing,
              ...rm,
              'foundAt': earliestFound,
              'isSelectedCandidate': mergedIsSel,
              'selectedAt': mergedSelAt,
              'selectedUpdatedAt': mergedSelUpd,
            };
            localChanged = true;
          } else if (rmSelUpd.isNotEmpty && rmSelUpd.compareTo(locSelUpd) > 0) {
            _matches[existingIdx] = <String, dynamic>{
              ...existing,
              'isSelectedCandidate': mergedIsSel,
              'selectedAt': mergedSelAt,
              'selectedUpdatedAt': mergedSelUpd,
            };
            localChanged = true;
          }
        }
      }
    }

    // Ensure all synced match VINs are recorded in each guest's seenMatchVins and scheduledCallVins
    for (var i = 0; i < _guests.length; i++) {
      final gid = _guests[i]['id']?.toString() ?? '';
      if (gid.isEmpty) continue;
      final seenSet = <String>{
        ...((_guests[i]['seenMatchVins'] as List<dynamic>?)
                ?.map((e) => e.toString().trim())
                .where((s) => s.isNotEmpty) ??
            const <String>[]),
      };
      final schedSet = <String>{
        ...((_guests[i]['scheduledCallVins'] as List<dynamic>?)
                ?.map((e) => e.toString().trim())
                .where((s) => s.isNotEmpty) ??
            const <String>[]),
      };
      final prevSeenLen = seenSet.length;
      final prevSchedLen = schedSet.length;
      for (final m in _matches) {
        if (m['guestId']?.toString() == gid) {
          final v = (m['vin']?.toString() ?? '').trim();
          if (v.isNotEmpty) {
            seenSet.add(v);
            schedSet.add(v);
          }
        }
      }
      if (seenSet.length != prevSeenLen || schedSet.length != prevSchedLen) {
        _guests[i] = <String, dynamic>{
          ..._guests[i],
          'seenMatchVins': seenSet.toList(),
          'scheduledCallVins': schedSet.toList(),
        };
      }
    }

    // 4. Sync shared settings (Gemini API key if empty locally, model, timezone, OAuth client ID)
    final remoteSettings = remote['settings'];
    if (remoteSettings is Map) {
      final localKey = (_settings['geminiApiKey']?.toString() ?? '').trim();
      final remKey = (remoteSettings['geminiApiKey']?.toString() ?? '').trim();
      if (localKey.isEmpty && remKey.isNotEmpty) {
        _settings['geminiApiKey'] = remKey;
        localChanged = true;
      }
      final remModel = (remoteSettings['geminiModel']?.toString() ?? '').trim();
      if (remModel.isNotEmpty && remModel != _settings['geminiModel']) {
        _settings['geminiModel'] = remModel;
        localChanged = true;
      }
      final remTz = (remoteSettings['timezone']?.toString() ?? '').trim();
      if (remTz.isNotEmpty && remTz != _settings['timezone']) {
        _settings['timezone'] = remTz;
        localChanged = true;
      }
      final localOAuth =
          (_settings['googleOAuthClientId']?.toString() ?? '').trim();
      final remOAuth =
          (remoteSettings['googleOAuthClientId']?.toString() ?? '').trim();
      if (localOAuth.isEmpty && remOAuth.isNotEmpty) {
        _settings['googleOAuthClientId'] = remOAuth;
        localChanged = true;
      }
    }

    // 5. Merge remote rolling backups (strictly keep last 5 newest)
    final remoteBackups = remote['backups'];
    if (remoteBackups is List && remoteBackups.isNotEmpty) {
      final byId = <String, Map<String, dynamic>>{
        for (final b in _backups)
          if ((b['id']?.toString() ?? '').isNotEmpty) b['id'].toString(): b,
      };
      for (final item in remoteBackups) {
        if (item is! Map) continue;
        final rb = Map<String, dynamic>.from(item);
        final bid = rb['id']?.toString() ?? '';
        final bCreated = rb['createdAt']?.toString() ?? '';
        if (bid.isEmpty || bCreated.isEmpty) continue;
        if (!byId.containsKey(bid)) {
          byId[bid] = rb;
          localChanged = true;
        }
      }
      final mergedList = byId.values.toList()
        ..sort(
          (a, b) => (b['createdAt'] ?? '')
              .toString()
              .compareTo((a['createdAt'] ?? '').toString()),
        );
      _backups = mergedList.take(maxBackups).toList();
    }

    return (
      totalGuests: _guests.length,
      totalMatches: _matches.length,
      localChanged: localChanged,
    );
  }

  // --- Last 5 Backups, Conflict Detection, & Overwrite / Duplicate Restore ---

  static String _computeBackupSignature(
    List<Map<String, dynamic>> guests,
    List<Map<String, dynamic>> matches,
  ) {
    final gParts = [...guests]
        .map((g) {
          final norm = _normalizeGuestMap(g);
          final targets = (norm['vehicleTargets'] as List<dynamic>? ?? [])
              .whereType<Map>()
              .map(
                (t) =>
                    '${t['condition']}|${t['minYear']}|${t['maxYear']}|${t['make']}|${t['model']}|${t['trim']}|${t['doors']}|${t['bedLength']}|${t['cabStyle']}|${t['maxPrice']}|${t['maxMileage']}|${t['drivetrain']}|${t['exteriorColor']}|${(t['features'] as List<dynamic>? ?? []).join(',')}|${t['notes']}',
              )
              .join(';;');
          final notes = (norm['clientNotes'] as List<dynamic>? ?? [])
              .whereType<Map>()
              .map((n) => '${n['id']}:${n['text']}')
              .join(';;');
          return '${norm['id']}|${norm['name']}|${norm['phone']}|${norm['email']}|$targets|$notes';
        })
        .toList()
      ..sort();

    final mParts = [...matches]
        .map(
          (m) =>
              '${m['guestId']}::${m['vin']}::${m['price']}::${(m['isSelectedCandidate'] == true || m['isSelectedCandidate'] == 1) ? '1' : '0'}',
        )
        .toList()
      ..sort();

    return '${gParts.join('###')}@@@${mParts.join('###')}';
  }

  static String _buildGuestComparableSignature(
    Map<String, dynamic> rawGuest,
    int matchCount,
  ) {
    final g = _normalizeGuestMap(rawGuest);
    final targets = (g['vehicleTargets'] as List<dynamic>? ?? [])
        .whereType<Map>()
        .map(
          (t) =>
              '${t['condition']}|${t['minYear']}|${t['maxYear']}|${t['make']}|${t['model']}|${t['trim']}|${t['doors']}|${t['bedLength']}|${t['cabStyle']}|${t['maxPrice']}|${t['maxMileage']}|${t['drivetrain']}|${t['exteriorColor']}|${(t['features'] as List<dynamic>? ?? []).join(',')}|${t['notes']}',
        )
        .join(';;');
    final notes = (g['clientNotes'] as List<dynamic>? ?? [])
        .whereType<Map>()
        .map((n) => (n['text']?.toString() ?? '').trim())
        .join(';;');
    return '${(g['name'] ?? '').toString().trim()}|${(g['phone'] ?? '').toString().trim()}|${(g['email'] ?? '').toString().trim()}|$targets|$notes|$matchCount';
  }

  static Map<String, dynamic>? _recordBackupSnapshotSync({
    required String label,
    String deviceLabel = 'Android / Googlebook',
    bool force = false,
  }) {
    final copiedGuests = _guests
        .map(
          (g) => jsonDecode(jsonEncode(_normalizeGuestMap(g)))
              as Map<String, dynamic>,
        )
        .toList();
    final copiedMatches = _matches.map((m) {
      final cloned = jsonDecode(jsonEncode(m)) as Map<String, dynamic>;
      final hl = (cloned['allHighlights'] as List<dynamic>? ?? [])
          .take(8)
          .map((e) => e.toString())
          .toList();
      cloned['allHighlights'] = hl;
      return cloned;
    }).toList();

    final signature = _computeBackupSignature(copiedGuests, copiedMatches);
    if (!force &&
        _backups.isNotEmpty &&
        _backups.first['signature']?.toString() == signature) {
      return null;
    }

    final nowIso = DateTime.now().toUtc().toIso8601String();
    final backupMap = <String, dynamic>{
      'id':
          'backup-${DateTime.now().microsecondsSinceEpoch}-${_backups.length + 1}',
      'label': label.trim().isNotEmpty ? label.trim() : 'Data Backup',
      'deviceLabel': deviceLabel,
      'signature': signature,
      'createdAt': nowIso,
      'guests': copiedGuests,
      'matches': copiedMatches,
    };

    _backups.insert(0, backupMap);
    if (_backups.length > maxBackups) {
      _backups = _backups.take(maxBackups).toList();
    }
    return backupMap;
  }

  static BackupEntry _hydrateBackupEntry(Map<String, dynamic> rawBackup) {
    final bGuests = (rawBackup['guests'] as List<dynamic>? ?? [])
        .whereType<Map>()
        .map((e) => _normalizeGuestMap(Map<String, dynamic>.from(e)))
        .toList();
    final bMatches = (rawBackup['matches'] as List<dynamic>? ?? [])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();

    final matchCountsByGuest = <String, int>{};
    for (final m in bMatches) {
      final gid = m['guestId']?.toString() ?? '';
      if (gid.isNotEmpty) {
        matchCountsByGuest[gid] = (matchCountsByGuest[gid] ?? 0) + 1;
      }
    }

    final previews = bGuests.map((g) {
      final gid = g['id']?.toString() ?? '';
      final profile = GuestProfile.fromJson({
        ...g,
        'matchCount': matchCountsByGuest[gid] ?? 0,
      });
      return BackupGuestPreview(
        id: profile.id,
        name: profile.name,
        phone: profile.phone,
        email: profile.email,
        targetSummary: profile.targetVehicleLabel,
        noteCount: profile.clientNotes.length,
        matchCount: matchCountsByGuest[gid] ?? 0,
      );
    }).toList();

    return BackupEntry(
      id: rawBackup['id']?.toString() ?? '',
      createdAt: rawBackup['createdAt']?.toString() ?? '',
      label: rawBackup['label']?.toString() ?? 'Data Backup',
      deviceLabel: rawBackup['deviceLabel']?.toString() ?? '',
      guestCount: bGuests.length,
      matchCount: bMatches.length,
      guestsPreview: previews,
    );
  }

  static Map<String, dynamic>? _findMatchingCurrentGuestMap(
    Map<String, dynamic> backupGuest,
    List<Map<String, dynamic>> currentGuests,
  ) {
    final bgId = (backupGuest['id']?.toString() ?? '').trim();
    final bgNameLower =
        (backupGuest['name']?.toString() ?? '').trim().toLowerCase();
    if (bgId.isNotEmpty) {
      for (final cg in currentGuests) {
        if ((cg['id']?.toString() ?? '').trim() == bgId) return cg;
      }
    }
    if (bgNameLower.isNotEmpty) {
      for (final cg in currentGuests) {
        if ((cg['name']?.toString() ?? '').trim().toLowerCase() ==
            bgNameLower) {
          return cg;
        }
      }
    }
    return null;
  }

  static String _makeUniqueDuplicateName(
    String baseName,
    Set<String> takenLowerNames,
  ) {
    final clean = baseName.trim().isNotEmpty ? baseName.trim() : 'Guest';
    final first = '$clean (Copy)';
    if (takenLowerNames.add(first.toLowerCase())) {
      return first;
    }
    int idx = 2;
    while (idx < 1000) {
      final candidate = '$clean (Copy $idx)';
      if (takenLowerNames.add(candidate.toLowerCase())) {
        return candidate;
      }
      idx++;
    }
    return '$clean (${DateTime.now().millisecondsSinceEpoch})';
  }

  static Future<List<BackupEntry>> getBackups() async {
    await ensureInitialized();
    if (_guests.isNotEmpty && _backups.isEmpty) {
      _recordBackupSnapshotSync(
        label: 'Initial Data Backup',
        force: true,
      );
      await _persist();
    }
    final sorted = [..._backups]
      ..sort(
        (a, b) => (b['createdAt'] ?? '')
            .toString()
            .compareTo((a['createdAt'] ?? '').toString()),
      );
    return sorted.take(maxBackups).map(_hydrateBackupEntry).toList();
  }

  static Future<List<BackupEntry>> createManualBackup({
    String label = 'Manual Backup',
  }) async {
    await ensureInitialized();
    _recordBackupSnapshotSync(
      label: label.trim().isNotEmpty ? label.trim() : 'Manual Backup',
      force: true,
    );
    await _persist();
    onDataMutatedForCloudSave?.call();
    return getBackups();
  }

  static Future<BackupConflictPreview> inspectBackupConflicts(
    String backupId,
  ) async {
    await ensureInitialized();
    final rawBackup = _backups.firstWhere(
      (b) => b['id']?.toString() == backupId,
      orElse: () => throw Exception('Selected backup was not found.'),
    );

    final bGuests = (rawBackup['guests'] as List<dynamic>? ?? [])
        .whereType<Map>()
        .map((e) => _normalizeGuestMap(Map<String, dynamic>.from(e)))
        .toList();
    final bMatches = (rawBackup['matches'] as List<dynamic>? ?? [])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();

    final bMatchCount = <String, int>{};
    for (final m in bMatches) {
      final gid = m['guestId']?.toString() ?? '';
      if (gid.isNotEmpty) bMatchCount[gid] = (bMatchCount[gid] ?? 0) + 1;
    }

    final cMatchCount = <String, int>{};
    for (final m in _matches) {
      final gid = m['guestId']?.toString() ?? '';
      if (gid.isNotEmpty) cMatchCount[gid] = (cMatchCount[gid] ?? 0) + 1;
    }

    final conflictingNames = <String>[];
    final modifiedNames = <String>[];
    final nonConflictingNames = <String>[];

    for (final bg in bGuests) {
      final name = (bg['name']?.toString() ?? '').trim();
      if (name.isEmpty) continue;
      final existing = _findMatchingCurrentGuestMap(bg, _guests);
      if (existing != null) {
        conflictingNames.add(name);
        final bgSig = _buildGuestComparableSignature(
          bg,
          bMatchCount[bg['id']?.toString() ?? ''] ?? 0,
        );
        final cgSig = _buildGuestComparableSignature(
          existing,
          cMatchCount[existing['id']?.toString() ?? ''] ?? 0,
        );
        if (bgSig != cgSig) {
          modifiedNames.add(name);
        }
      } else {
        nonConflictingNames.add(name);
      }
    }

    return BackupConflictPreview(
      backup: _hydrateBackupEntry(rawBackup),
      hasConflicts: conflictingNames.isNotEmpty,
      conflictingGuestNames: conflictingNames,
      modifiedConflictNames: modifiedNames,
      nonConflictingGuestNames: nonConflictingNames,
    );
  }

  static Future<BackupRestoreResult> restoreBackup(
    String backupId, {
    BackupConflictResolution? resolution,
  }) async {
    await ensureInitialized();
    final targetBackup = _backups.firstWhere(
      (b) => b['id']?.toString() == backupId,
      orElse: () => throw Exception('Selected backup was not found.'),
    );

    final bGuests = (targetBackup['guests'] as List<dynamic>? ?? [])
        .whereType<Map>()
        .map(
          (e) => _normalizeGuestMap(
            jsonDecode(jsonEncode(e)) as Map<String, dynamic>,
          ),
        )
        .toList();
    final bMatches = (targetBackup['matches'] as List<dynamic>? ?? [])
        .whereType<Map>()
        .map((e) => jsonDecode(jsonEncode(e)) as Map<String, dynamic>)
        .toList();

    final preRestoreGuests = [..._guests];
    final hasAnyConflict = bGuests.any(
      (bg) => _findMatchingCurrentGuestMap(bg, preRestoreGuests) != null,
    );

    if (hasAnyConflict && resolution == null) {
      throw Exception(
        'Conflicting guest entries exist. Please choose Overwrite or Duplicate.',
      );
    }

    // Preserve pre-restore state in backup history if it differs from newest backup
    if (_guests.isNotEmpty) {
      _recordBackupSnapshotSync(
        label: 'Auto-Backup • Pre-Restore Snapshot',
        force: false,
      );
    }

    final matchesByGuestId = <String, List<Map<String, dynamic>>>{};
    for (final m in bMatches) {
      final gid = m['guestId']?.toString() ?? '';
      if (gid.isEmpty) continue;
      matchesByGuestId.putIfAbsent(gid, () => []).add(m);
    }

    final takenLowerNames = <String>{
      for (final cg in _guests)
        if ((cg['name']?.toString() ?? '').trim().isNotEmpty)
          cg['name'].toString().trim().toLowerCase(),
    };

    final nowIso = DateTime.now().toUtc().toIso8601String();
    int restoredCount = 0;
    int overwrittenCount = 0;
    int duplicatedCount = 0;
    int seq = 0;

    for (final bg in bGuests) {
      final rawName = (bg['name']?.toString() ?? '').trim();
      if (rawName.isEmpty) continue;
      seq++;

      final origId =
          (bg['id']?.toString() ?? '').trim().isNotEmpty
              ? bg['id'].toString().trim()
              : 'guest-restored-${DateTime.now().microsecondsSinceEpoch}-$seq';
      final guestMatches = matchesByGuestId[origId] ?? const [];
      final existing = _findMatchingCurrentGuestMap(bg, preRestoreGuests);

      String targetGuestId = origId;
      String targetName = rawName;
      String createdAtToUse = (bg['createdAt']?.toString() ?? nowIso).trim();
      if (createdAtToUse.isEmpty) createdAtToUse = nowIso;
      final targetIdRemap = <String, String>{};
      final isDuplicate =
          existing != null && resolution == BackupConflictResolution.duplicate;

      if (existing == null) {
        restoredCount++;
        takenLowerNames.add(targetName.toLowerCase());
        _deletedGuestIds.remove(targetGuestId);
      } else if (resolution == BackupConflictResolution.overwrite) {
        overwrittenCount++;
        targetGuestId = existing['id']?.toString() ?? origId;
        _deletedGuestIds.remove(targetGuestId);
        _deletedGuestIds.remove(origId);
        _guests.removeWhere(
          (g) =>
              g['id']?.toString() == targetGuestId ||
              g['id']?.toString() == origId,
        );
        _matches.removeWhere(
          (m) =>
              m['guestId']?.toString() == targetGuestId ||
              m['guestId']?.toString() == origId,
        );
      } else {
        duplicatedCount++;
        targetGuestId =
            'guest-dup-${DateTime.now().microsecondsSinceEpoch}-$seq';
        targetName = _makeUniqueDuplicateName(rawName, takenLowerNames);
        createdAtToUse = nowIso;
      }

      final rawTargets = (bg['vehicleTargets'] as List<dynamic>? ?? [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
      final remappedTargets = <Map<String, dynamic>>[];
      for (var i = 0; i < rawTargets.length; i++) {
        final oldTid =
            (rawTargets[i]['id']?.toString() ?? '$origId-vt-${i + 1}');
        final newTid = isDuplicate ? '$targetGuestId-vt-${i + 1}' : oldTid;
        targetIdRemap[oldTid] = newTid;
        remappedTargets.add(<String, dynamic>{
          ...rawTargets[i],
          'id': newTid,
        });
      }

      final remappedNotes = <Map<String, dynamic>>[];
      final rawNotes = (bg['clientNotes'] as List<dynamic>? ?? [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
      for (var i = 0; i < rawNotes.length; i++) {
        remappedNotes.add(<String, dynamic>{
          ...rawNotes[i],
          'id': isDuplicate
              ? '$targetGuestId-note-${i + 1}'
              : (rawNotes[i]['id']?.toString() ??
                    '$targetGuestId-note-${i + 1}'),
        });
      }

      final matchVins = guestMatches
          .map((m) => (m['vin']?.toString() ?? '').trim())
          .where((v) => v.isNotEmpty)
          .toSet();
      final seenVins = <String>{
        ...((bg['seenMatchVins'] as List<dynamic>? ?? [])
            .map((e) => e.toString().trim())
            .where((s) => s.isNotEmpty)),
        ...matchVins,
      }.toList();
      final schedVins = <String>{
        ...((bg['scheduledCallVins'] as List<dynamic>? ?? [])
            .map((e) => e.toString().trim())
            .where((s) => s.isNotEmpty)),
        ...matchVins,
      }.toList();

      final normalizedRestored = _normalizeGuestMap(<String, dynamic>{
        ...bg,
        'id': targetGuestId,
        'name': targetName,
        'vehicleTargets': remappedTargets,
        'clientNotes': remappedNotes,
        if (isDuplicate) 'deletedNoteIds': <String>[],
        'initialSearchCompleted':
            (bg['initialSearchCompleted'] == true) ||
            ((bg['lastSearchedAt']?.toString() ?? '').isNotEmpty) ||
            matchVins.isNotEmpty,
        'seenMatchVins': seenVins,
        'scheduledCallVins': schedVins,
        'createdAt': createdAtToUse,
        'updatedAt': nowIso,
      });

      _guests.insert(0, normalizedRestored);

      int mSeq = 0;
      for (final m in guestMatches) {
        final vin = (m['vin']?.toString() ?? '').trim();
        if (vin.isEmpty) continue;
        mSeq++;
        final oldTid = m['targetId']?.toString() ?? '';
        final mappedTid = targetIdRemap[oldTid] ?? oldTid;
        _matches.add(<String, dynamic>{
          ...m,
          'id': isDuplicate
              ? 'match-dup-${DateTime.now().microsecondsSinceEpoch}-$seq-$mSeq'
              : (m['id']?.toString() ??
                    'match-${DateTime.now().microsecondsSinceEpoch}-$seq-$mSeq'),
          'guestId': targetGuestId,
          'targetId': mappedTid,
          'lastSeenAt': nowIso,
        });
      }
    }

    _guests.sort(
      (a, b) => (b['createdAt'] ?? '')
          .toString()
          .compareTo((a['createdAt'] ?? '').toString()),
    );

    await _persist();
    onDataMutatedForCloudSave?.call();

    final parts = <String>[];
    if (overwrittenCount > 0) parts.add('$overwrittenCount overwritten');
    if (duplicatedCount > 0) parts.add('$duplicatedCount duplicated');
    if (restoredCount > 0) parts.add('$restoredCount restored');
    final detail = parts.isNotEmpty ? parts.join(', ') : '0 changes';

    return BackupRestoreResult(
      backupId: backupId,
      resolution: hasAnyConflict ? resolution!.wireValue : 'none',
      restoredGuests: restoredCount,
      overwrittenGuests: overwrittenCount,
      duplicatedGuests: duplicatedCount,
      totalGuests: _guests.length,
      totalMatches: _matches.length,
      summary:
          'Backup loaded ($detail) • ${_guests.length} active guest(s), ${_matches.length} match(es).',
    );
  }

  static Future<List<RecentVinRecallEntry>> getRecentVinRecallChecks() async {
    await ensureInitialized();
    final sorted = [..._recallChecks]..sort(
        (a, b) => (b['checkedAt']?.toString() ?? '')
            .compareTo(a['checkedAt']?.toString() ?? ''),
      );
    return sorted
        .take(15)
        .map((r) => RecentVinRecallEntry.fromJson(r))
        .toList();
  }

  static Map<String, String> _getRecallOverridesForVin(String vin) {
    final cleanVin = vin.trim().toUpperCase();
    final prefix = '$cleanVin::';
    final out = <String, String>{};
    for (final entry in _recallStatusOverrides.entries) {
      if (entry.key.startsWith(prefix)) {
        out[entry.key.substring(prefix.length)] = entry.value;
      }
    }
    return out;
  }

  static Future<({VinRecallCheckResult result, List<RecentVinRecallEntry> recent})>
      _saveAndReturnRecallResult(VinRecallCheckResult result) async {
    _recallResultsByVin[result.vin] = result.toJson();

    final entry = RecentVinRecallEntry(
      vin: result.vin,
      vehicleTitle: result.vehicleTitle,
      hasRecalls: result.hasRecalls,
      recallCount: result.recallCount,
      incompleteCount: result.incompleteCount,
      completeCount: result.completeCount,
      verdictHeadline: result.verdictHeadline,
      checkedAt: result.checkedAt,
    ).toJson();

    _recallChecks.removeWhere(
      (r) => (r['vin']?.toString() ?? '').toUpperCase() == result.vin,
    );
    _recallChecks.insert(0, entry);
    if (_recallChecks.length > 15) {
      final keepVins = _recallChecks
          .take(15)
          .map((r) => (r['vin']?.toString() ?? '').toUpperCase())
          .toSet();
      _recallChecks = _recallChecks.take(15).toList();
      _recallResultsByVin.removeWhere((k, _) => !keepVins.contains(k));
    }
    await _persist();

    final recent = _recallChecks
        .map((r) => RecentVinRecallEntry.fromJson(r))
        .toList();
    return (result: result, recent: recent);
  }

  static Future<({VinRecallCheckResult result, List<RecentVinRecallEntry> recent})>
      checkVinRecalls(String rawVin) async {
    await ensureInitialized();
    final validation = NhtsaRecallService.validateAndNormalizeVin(rawVin);
    if (!validation.valid) {
      throw Exception(validation.error);
    }
    final apiKey = (_settings['geminiApiKey']?.toString() ?? '').trim();
    final model = (_settings['geminiModel']?.toString() ?? 'gemini-2.5-flash')
        .trim();
    final manualOverrides = _getRecallOverridesForVin(validation.vin);

    final result = await NhtsaRecallService.checkVinRecalls(
      rawVin: validation.vin,
      geminiApiKey: apiKey,
      geminiModel: model.isNotEmpty ? model : 'gemini-2.5-flash',
      manualOverrides: manualOverrides,
    );

    return _saveAndReturnRecallResult(result);
  }

  static Future<({VinRecallCheckResult result, List<RecentVinRecallEntry> recent})>
      updateVinRecallStatus({
    required String vin,
    required String campaignNumber,
    required String status,
  }) async {
    await ensureInitialized();
    final validation = NhtsaRecallService.validateAndNormalizeVin(vin);
    if (!validation.valid) {
      throw Exception(validation.error);
    }
    final cleanCampaign = campaignNumber.trim();
    final cleanStatus = status.trim().toLowerCase();
    final key = '${validation.vin}::$cleanCampaign';

    if (cleanStatus == 'auto' || cleanStatus == 'reset') {
      _recallStatusOverrides.remove(key);
      _cachedNautilusHybridScan = null;
      _cachedNautilusHybridScanAt = null;
      return checkVinRecalls(validation.vin);
    }

    _recallStatusOverrides[key] = cleanStatus;
    _cachedNautilusHybridScan = null;
    _cachedNautilusHybridScanAt = null;
    final cachedJson = _recallResultsByVin[validation.vin];
    if (cachedJson == null) {
      return checkVinRecalls(validation.vin);
    }

    final current = VinRecallCheckResult.fromJson(cachedJson);
    final updated = NhtsaRecallService.applyManualOverridesToResult(
      current,
      {cleanCampaign: cleanStatus},
    );
    return _saveAndReturnRecallResult(updated);
  }

  static List<Map<String, dynamic>> _cachedFullCatalog = [];
  static DateTime? _cachedFullCatalogAt;
  static NautilusHybridRecallScanResult? _cachedNautilusHybridScan;
  static DateTime? _cachedNautilusHybridScanAt;

  static Future<List<Map<String, dynamic>>> fetchEntirePrestonCatalog({
    bool forceRefresh = false,
  }) async {
    final now = DateTime.now();
    if (!forceRefresh &&
        _cachedFullCatalog.isNotEmpty &&
        _cachedFullCatalogAt != null &&
        now.difference(_cachedFullCatalogAt!) < const Duration(minutes: 5)) {
      return _cachedFullCatalog;
    }

    final client = http.Client();
    try {
      await _refreshPrestonConfig(client);
      final results = await Future.wait([
        _queryAllCosmosPages(
          client,
          _newPageId,
          const {},
          concurrency: 6,
        ),
        _queryAllCosmosPages(
          client,
          _usedPageId,
          const {},
          concurrency: 6,
        ),
      ]);
      final byVin = <String, Map<String, dynamic>>{};
      for (final list in results) {
        for (final v in list) {
          final vin = v['vin']?.toString() ?? '';
          if (vin.isEmpty) continue;
          byVin.putIfAbsent(vin, () => v);
        }
      }
      final merged = byVin.values.toList();
      if (merged.isNotEmpty) {
        _cachedFullCatalog = merged;
        _cachedFullCatalogAt = now;
      }
      return merged;
    } finally {
      client.close();
    }
  }

  static Future<NautilusHybridRecallScanResult>
      scan2026NautilusHybridsRecallFree({
    bool forceRefresh = false,
    @visibleForTesting List<Map<String, dynamic>>? mockInventoryOverride,
    @visibleForTesting
    Future<({DecodedVinVehicle vehicle, VinOpenRecallLookup openCheck})>
            Function(String vin)?
        mockPerVinInspector,
    @visibleForTesting List<NhtsaRecallCampaign>? mockSharedModelRecalls,
  }) async {
    if (NhtsaRecallService.hasMockNautilusHybridScanHandler) {
      return NhtsaRecallService.scan2026NautilusHybridsRecallFree(
        nautilusInventory: const [],
        forceRefresh: forceRefresh,
      );
    }
    await ensureInitialized();

    final now = DateTime.now();
    if (!forceRefresh &&
        mockInventoryOverride == null &&
        _cachedNautilusHybridScan != null &&
        _cachedNautilusHybridScanAt != null &&
        now.difference(_cachedNautilusHybridScanAt!) <
            const Duration(minutes: 3)) {
      return _cachedNautilusHybridScan!;
    }

    List<Map<String, dynamic>> nautilusInv;
    if (mockInventoryOverride != null) {
      nautilusInv = mockInventoryOverride;
    } else {
      final probeGuest = GuestProfile(
        id: 'probe-2026-nautilus-hybrid',
        name: '2026 Lincoln Nautilus Probe',
        condition: 'Any',
        make: 'Lincoln',
        model: 'Nautilus',
        createdAt: DateTime.now().toUtc().toIso8601String(),
      );
      nautilusInv = await _fetchPrestonCandidates(probeGuest);
    }

    final apiKey = (_settings['geminiApiKey']?.toString() ?? '').trim();
    final model =
        (_settings['geminiModel']?.toString() ?? 'gemini-2.5-flash').trim();

    final result = await NhtsaRecallService.scan2026NautilusHybridsRecallFree(
      nautilusInventory: nautilusInv,
      forceRefresh: forceRefresh,
      geminiApiKey: apiKey,
      geminiModel: model.isNotEmpty ? model : 'gemini-2.5-flash',
      getManualOverridesForVin: _getRecallOverridesForVin,
      mockPerVinInspector: mockPerVinInspector,
      mockSharedModelRecalls: mockSharedModelRecalls,
    );

    if (mockInventoryOverride == null && result.total2026NautilusInStock > 0) {
      _cachedNautilusHybridScan = result;
      _cachedNautilusHybridScanAt = DateTime.now();
    }
    return result;
  }

  static Future<DocumentEquivalentSearchResult>
      findEquivalentVehiclesFromDocument({
    required PickedDocumentFile document,
    String extraNotes = '',
    @visibleForTesting List<Map<String, dynamic>>? mockCatalogOverride,
  }) async {
    if (DocumentEquivalentService.hasMockSearchHandler) {
      return DocumentEquivalentService.findClosestEquivalents(
        document: document,
        entireCatalog: const <Map<String, dynamic>>[],
        extraNotes: extraNotes,
      );
    }
    await ensureInitialized();
    final catalog = mockCatalogOverride ?? await fetchEntirePrestonCatalog();
    final apiKey = (_settings['geminiApiKey']?.toString() ?? '').trim();
    final model =
        (_settings['geminiModel']?.toString() ?? 'gemini-2.5-flash').trim();

    return DocumentEquivalentService.findClosestEquivalents(
      document: document,
      entireCatalog: catalog,
      geminiApiKey: apiKey,
      geminiModel: model.isNotEmpty ? model : 'gemini-2.5-flash',
      extraNotes: extraNotes,
    );
  }

  @visibleForTesting
  static void cancelSchedulerForTest() {
    _scheduleTimer?.cancel();
    _scheduleTimer = null;
  }

  @visibleForTesting
  static void resetForTest() {
    _scheduleTimer?.cancel();
    _scheduleTimer = null;
    _initialized = false;
    _isRepairingZeroScannedGuests = false;
    _configFetchedAt = null;
    _cachedFullCatalog = [];
    _cachedFullCatalogAt = null;
    _cachedNautilusHybridScan = null;
    _cachedNautilusHybridScanAt = null;
    _guests = [];
    _matches = [];
    _notifications = [];
    _calendarEvents = [];
    _backups = [];
    _recallChecks = [];
    _recallStatusOverrides = {};
    _recallResultsByVin = {};
    _deletedGuestIds = {};
    _settings['calendarPermissionGranted'] = false;
    _settings['calendarPromptDismissed'] = false;
    MatchNotificationService.instance.resetForTest();
    CalendarService.instance.resetForTest();
  }

  @visibleForTesting
  static Map<String, dynamic>? parseVehicleCardForTest(
    Map<String, dynamic> vc, {
    String facetBedLength = '',
  }) =>
      _parseVehicleCard(vc, facetBedLength: facetBedLength);

  @visibleForTesting
  static Map<String, dynamic> normalizeSpecsForTest(Map<String, dynamic> raw) =>
      _normalizeGuestMap(raw);

  @visibleForTesting
  static List<Map<String, dynamic>> evaluateAllForTest(
    GuestProfile guest,
    List<Map<String, dynamic>> candidates,
  ) =>
      _deterministicEvaluate(guest, _preFilter(guest, candidates));

  @visibleForTesting
  static List<Map<String, dynamic>> evaluateMultiTargetGuestForTest(
    GuestProfile guest,
    List<Map<String, dynamic>> candidates,
  ) {
    final bestByVin = <String, Map<String, dynamic>>{};
    for (final target in guest.effectiveTargets) {
      final specGuest = _buildSingleTargetGuestSpec(guest, target);
      final matched =
          _deterministicEvaluate(specGuest, _preFilter(specGuest, candidates));
      for (final item in matched) {
        final v = item['vehicle'] as Map<String, dynamic>;
        final vin = v['vin']?.toString() ?? '';
        if (vin.isEmpty) continue;
        final prev = bestByVin[vin];
        final score = (item['matchScore'] as num?)?.toInt() ?? 85;
        final prevScore = (prev?['matchScore'] as num?)?.toInt() ?? 0;
        if (prev == null || score >= prevScore) {
          bestByVin[vin] = <String, dynamic>{
            ...item,
            'targetId': target.id,
            'targetLabel': target.label,
          };
        }
      }
    }
    return bestByVin.values.toList();
  }

  @visibleForTesting
  static Map<String, dynamic> simulateMultiDeviceCloudMergeForTest({
    required Map<String, dynamic> deviceASnapshot,
    required Map<String, dynamic> deviceBSnapshot,
  }) {
    _guests = [];
    _matches = [];
    _deletedGuestIds = {};
    _mergeCloudSnapshotSync(deviceASnapshot);
    _mergeCloudSnapshotSync(deviceBSnapshot);
    return _buildCloudSnapshotSync(deviceLabel: 'TestMergedDevice');
  }
}



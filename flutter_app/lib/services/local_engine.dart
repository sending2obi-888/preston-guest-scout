import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import '../models/models.dart';
import 'widget_sync_service.dart';

/// Self-contained on-device engine for the Android / Googlebook APK.
/// Persists unlimited guests & matches locally, queries ALL pages of live prestonmotor.com
/// inventory, invokes the Google Gemini API directly, and enforces twice-daily (7:30 AM & 2:00 PM) scans.
class LocalScoutEngine {
  static const MethodChannel _channel =
      MethodChannel('com.prestonmotor.scout/launcher_widget');
  static const String _prestonHost = 'www.prestonmotor.com';
  static const String _prestonBase = 'https://www.prestonmotor.com';

  static const Map<String, List<String>> _knownMakes = {
    'Ford': ['ford'],
    'Lincoln': ['lincoln'],
    'Hyundai': ['hyundai'],
    'Mazda': ['mazda'],
    'Nissan': ['nissan'],
    'Chevrolet': ['chevrolet', 'chevy'],
    'Jeep': ['jeep'],
    'Ram': ['ram'],
    'Dodge': ['dodge'],
    'Chrysler': ['chrysler'],
    'Toyota': ['toyota'],
    'Honda': ['honda'],
    'GMC': ['gmc'],
    'Kia': ['kia'],
    'Subaru': ['subaru'],
    'Genesis': ['genesis'],
    'Volkswagen': ['volkswagen', 'vw'],
    'BMW': ['bmw'],
    'Mercedes-Benz': ['mercedes-benz', 'mercedes'],
    'Audi': ['audi'],
    'Lexus': ['lexus'],
    'Cadillac': ['cadillac'],
    'Buick': ['buick'],
  };

  static const List<String> _locationKeywords = [
    'millsboro',
    'boulevard ford',
    'boulevard lincoln',
    'lewes',
    'georgetown',
    'hurlock',
    'pittsville',
    'aberdeen',
    'denton',
    'keller',
    'dover',
    'randallstown',
    'wilmington',
    'easton',
    'snow hill',
    'salisbury',
  ];

  static bool _initialized = false;
  static bool _isRunningBatch = false;
  static Timer? _scheduleTimer;

  /// Invoked automatically whenever local guests, matches, or settings mutate
  /// so GoogleDriveSyncService saves the latest search state to Google Drive.
  static void Function()? onDataMutatedForCloudSave;

  static List<Map<String, dynamic>> _guests = [];
  static List<Map<String, dynamic>> _matches = [];
  static Map<String, String> _deletedGuestIds = {};
  static Map<String, dynamic> _settings = {
    'geminiApiKey': '',
    'geminiModel': 'gemini-2.5-flash',
    'timezone': 'America/New_York',
    'googleOAuthClientId': '',
    'googleOAuthClientSecret': '',
    'driveSyncFileId': '',
    'completedSlots': <String>[],
  };

  static Future<void> ensureInitialized() async {
    if (_initialized || kIsWeb) return;
    _initialized = true;

    try {
      final raw = await _channel.invokeMethod<String>('readLocalStore');
      if (raw != null && raw.trim().isNotEmpty) {
        final decoded = jsonDecode(raw) as Map<String, dynamic>;
        _guests = (decoded['guests'] as List<dynamic>? ?? [])
            .map((e) => _normalizeGuestMap(Map<String, dynamic>.from(e as Map)))
            .toList();
        _matches = (decoded['matches'] as List<dynamic>? ?? [])
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList();
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
      } else {
        await _seedInitialGuests();
      }
    } catch (_) {
      if (_guests.isEmpty) {
        await _seedInitialGuests();
      }
    }

    // Listen for native 7:30 AM / 2:00 PM AlarmManager triggers from Kotlin
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'openGuestMatches') {
        WidgetSyncService.dispatchGuestSelection(
            call.arguments?.toString() ?? '');
      } else if (call.method == 'runScheduledDailySearch') {
        final slot = call.arguments?.toString() ?? 'Scheduled Daily Search';
        await runSearchForAllGuests(slotLabel: slot);
      }
    });

    _startOnDeviceScheduler();
    await _syncWidget();
  }

  /// Normalizes structured vehicle criteria AND extracts fallback specs (Make, Max Price
  /// such as "$60K" or shorthand "60" -> 60000, Condition, Drivetrain) from free-form notes.
  static Map<String, dynamic> _normalizeTargetMap(
    Map<String, dynamic> raw, {
    required String fallbackId,
    required String fallbackCreatedAt,
  }) {
    final featuresList = (raw['features'] as List<dynamic>? ?? [])
        .map((e) => e.toString().trim())
        .where((s) => s.isNotEmpty)
        .toList();
    final notesStr = (raw['notes']?.toString() ?? '').trim();
    final combinedText = '$notesStr ${featuresList.join(' ')}'.trim();
    final lowerText = combinedText.toLowerCase();

    String make = (raw['make']?.toString() ?? '').trim();
    if (make.isEmpty && lowerText.isNotEmpty) {
      for (final entry in _knownMakes.entries) {
        final hit = entry.value.any((alias) {
          final pattern = alias.replaceAll('-', r'[-\s]?');
          return RegExp('\\b$pattern\\b', caseSensitive: false)
              .hasMatch(lowerText);
        });
        if (hit) {
          make = entry.key;
          break;
        }
      }
    }

    double? maxPrice = (raw['maxPrice'] as num?)?.toDouble();
    if (maxPrice != null && maxPrice <= 0) maxPrice = null;
    if (maxPrice != null && maxPrice > 0 && maxPrice < 500) {
      maxPrice = maxPrice * 1000.0;
    }
    if (maxPrice == null && combinedText.isNotEmpty) {
      final budgetReg = RegExp(
        r'(?:under|below|max|up\s+to|less\s+than|around|budget(?:\s+of)?|<=?)\s*\$?\s*(\d+(?:,\d{3})*(?:\.\d+)?)\s*(k|thousand)?\b|\$\s*(\d+(?:,\d{3})*(?:\.\d+)?)\s*(k|thousand)\b|\$\s*(\d{1,3}(?:,\d{3})+)\b',
        caseSensitive: false,
      );
      final m = budgetReg.firstMatch(combinedText);
      if (m != null) {
        if (m.group(1) != null) {
          var val =
              double.tryParse(m.group(1)!.replaceAll(',', '')) ?? 0.0;
          if (m.group(2) != null || (val > 0 && val < 500)) val *= 1000.0;
          if (val >= 1000) maxPrice = val;
        } else if (m.group(3) != null) {
          final val =
              (double.tryParse(m.group(3)!.replaceAll(',', '')) ?? 0.0) *
                  1000.0;
          if (val >= 1000) maxPrice = val;
        } else if (m.group(5) != null) {
          final val =
              double.tryParse(m.group(5)!.replaceAll(',', '')) ?? 0.0;
          if (val >= 1000) maxPrice = val;
        }
      }
    }

    String condition = (raw['condition']?.toString() ?? 'Any').trim();
    if (condition.isEmpty) condition = 'Any';
    if (condition == 'Any' && lowerText.isNotEmpty) {
      if (RegExp(r'\bbrand\s+new\b|\bnew\s+only\b').hasMatch(lowerText)) {
        condition = 'New';
      } else if (RegExp(r'\bcpo\b|\bcertified\s+pre-?owned\b')
          .hasMatch(lowerText)) {
        condition = 'CPO';
      } else if (RegExp(r'\bpre-?owned\s+only\b|\bused\s+only\b')
          .hasMatch(lowerText)) {
        condition = 'Pre-Owned';
      }
    }

    String drivetrain = (raw['drivetrain']?.toString() ?? 'Any').trim();
    if (drivetrain.isEmpty) drivetrain = 'Any';
    if (drivetrain == 'Any' && lowerText.isNotEmpty) {
      if (RegExp(r'\b(4wd|4x4|four[\s-]wheel[\s-]drive)\b')
          .hasMatch(lowerText)) {
        drivetrain = '4WD';
      } else if (RegExp(r'\b(awd|all[\s-]wheel[\s-]drive)\b')
          .hasMatch(lowerText)) {
        drivetrain = 'AWD';
      }
    }

    final rawId = (raw['id']?.toString() ?? '').trim();
    final rawCreated = (raw['createdAt']?.toString() ?? '').trim();

    return <String, dynamic>{
      'id': rawId.isNotEmpty ? rawId : fallbackId,
      'condition': condition,
      'minYear': (raw['minYear'] as num?)?.toInt(),
      'maxYear': (raw['maxYear'] as num?)?.toInt(),
      'make': make,
      'model': (raw['model']?.toString() ?? '').trim(),
      'trim': (raw['trim']?.toString() ?? '').trim(),
      'maxPrice': maxPrice,
      'maxMileage': (raw['maxMileage'] as num?)?.toInt(),
      'drivetrain': drivetrain,
      'exteriorColor': (raw['exteriorColor']?.toString() ?? '').trim(),
      'features': featuresList,
      'notes': notesStr,
      'createdAt': rawCreated.isNotEmpty ? rawCreated : fallbackCreatedAt,
    };
  }

  static Map<String, dynamic> _normalizeGuestMap(Map<String, dynamic> raw) {
    final gid = (raw['id']?.toString() ?? '').trim();
    final createdAt = (raw['createdAt']?.toString() ??
            DateTime.now().toUtc().toIso8601String())
        .trim();

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

    final primary = normalizedTargets.first;

    return <String, dynamic>{
      ...raw,
      'condition': primary['condition'],
      'minYear': primary['minYear'],
      'maxYear': primary['maxYear'],
      'make': primary['make'],
      'model': primary['model'],
      'trim': primary['trim'],
      'maxPrice': primary['maxPrice'],
      'maxMileage': primary['maxMileage'],
      'drivetrain': primary['drivetrain'],
      'exteriorColor': primary['exteriorColor'],
      'features': primary['features'],
      'notes': primary['notes'],
      'vehicleTargets': normalizedTargets,
    };
  }

  static List<String> _extractLocationHints(GuestProfile guest) {
    final lower = '${guest.notes} ${guest.features.join(' ')}'.toLowerCase();
    if (lower.trim().isEmpty) return const [];
    return _locationKeywords.where((loc) => lower.contains(loc)).toList();
  }

  static Future<void> _persist() async {
    if (kIsWeb) return;
    try {
      final payload = jsonEncode({
        'guests': _guests,
        'matches': _matches,
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
    unawaited(runSearchForAllGuests(slotLabel: 'Initial Googlebook Sync'));
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

  static GuestProfile _hydrateGuest(Map<String, dynamic> rawG) {
    final g = _normalizeGuestMap(rawG);
    final gid = g['id']?.toString() ?? '';
    int count = 0;
    double? lowest;
    for (final m in _matches) {
      if (m['guestId']?.toString() != gid) continue;
      count++;
      final p = (m['price'] as num?)?.toDouble();
      if (p != null && (lowest == null || p < lowest)) {
        lowest = p;
      }
    }
    return GuestProfile.fromJson({
      ...g,
      'matchCount': count,
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
    double? maxPrice,
    int? maxMileage,
    String drivetrain = 'Any',
    String exteriorColor = '',
    List<String> features = const [],
    String notes = '',
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
    onDataMutatedForCloudSave?.call();

    final searchRes =
        await runSearchForSingleGuest(id, slotLabel: 'Initial Intake Search');
    return (
      guest: searchRes.guest,
      matchesFound: searchRes.matches.length,
      summary: searchRes.summary,
    );
  }

  static Future<({GuestProfile guest, List<VehicleMatch> matches})>
      getGuestWithMatches(String guestId) async {
    await ensureInitialized();
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

  static Future<void> deleteGuest(String guestId) async {
    await ensureInitialized();
    _deletedGuestIds[guestId] = DateTime.now().toUtc().toIso8601String();
    _guests.removeWhere((g) => g['id']?.toString() == guestId);
    _matches.removeWhere((m) => m['guestId']?.toString() == guestId);
    await _persist();
    onDataMutatedForCloudSave?.call();
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
  }) async {
    if (_isRunningBatch) return;
    _isRunningBatch = true;
    try {
      for (final g in [..._guests]) {
        if (g['active'] == false) continue;
        final id = g['id']?.toString() ?? '';
        if (id.isEmpty) continue;
        try {
          await runSearchForSingleGuest(id, slotLabel: slotLabel);
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
    double? maxPrice,
    int? maxMileage,
    String drivetrain = 'Any',
    String exteriorColor = '',
    List<String> features = const [],
    String notes = '',
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
        newTargetModel.maxPrice != null ||
        newTargetModel.minYear != null ||
        newTargetModel.maxYear != null ||
        newTargetModel.notes.isNotEmpty ||
        newTargetModel.features.isNotEmpty ||
        newTargetModel.condition != 'Any' ||
        newTargetModel.drivetrain != 'Any';
    if (!hasAnyCriteria) {
      throw Exception(
        'Please enter at least a make, model, budget, or requirement for the vehicle.',
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
    onDataMutatedForCloudSave?.call();

    return runSearchForSingleGuest(
      guestId,
      slotLabel: 'Added Vehicle Search (${newTargetModel.label})',
      onlyTargetId: newTargetId,
    );
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
    });
    await _persist();
    onDataMutatedForCloudSave?.call();

    return getGuestWithMatches(guestId);
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
  }) async {
    await ensureInitialized();
    final idx = _guests.indexWhere((g) => g['id']?.toString() == guestId);
    if (idx == -1) throw Exception('Guest not found');

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
      final candidates = await _fetchPrestonCandidates(specGuest);
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

    // Index existing matches for O(1) VIN lookup when saving 1,000+ matches
    final existingByVin = <String, Map<String, dynamic>>{};
    for (final m in _matches) {
      if (m['guestId']?.toString() == guestId) {
        final v = m['vin']?.toString() ?? '';
        if (v.isNotEmpty) existingByVin[v] = m;
      }
    }

    if (totalCandidatesScanned > 0) {
      if (onlyTargetId != null) {
        // Keep matches belonging to the guest's other vehicle targets; replace onlyTargetId's matches & duplicate VINs
        _matches.removeWhere((m) {
          if (m['guestId']?.toString() != guestId) return false;
          final mTarget = m['targetId']?.toString() ?? '';
          final mVin = m['vin']?.toString() ?? '';
          return mTarget == onlyTargetId || bestByVin.containsKey(mVin);
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
        });
      }
    }

    final locCount = bestByVin.values
        .map((m) => (m['vehicle'] as Map)['location']?.toString() ?? '')
        .toSet()
        .length;
    final summaryText = targetsToRun.length > 1
        ? 'Scanned ${targetsToRun.length} vehicle criteria (${targetSummaries.join(' • ')}) — ${bestByVin.length} match(es) across $locCount Preston location(s).'
        : 'Scanned $totalCandidatesScanned live prestonmotor.com vehicles for ${targetsToRun.first.label}; verified ${bestByVin.length} match(es) across $locCount Preston location(s).';

    _guests[idx] = {
      ..._guests[idx],
      'lastSearchedAt': nowIso,
      'lastSearchSummary': summaryText,
      'updatedAt': nowIso,
    };
    await _persist();
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

  static Future<List<Map<String, dynamic>>> _fetchPrestonCandidates(
      GuestProfile guest) async {
    final cond = guest.condition.toLowerCase();
    final pageIds = <int>[];
    if (cond == 'new') {
      pageIds.add(1446609);
    } else if (cond == 'pre-owned' ||
        cond == 'used' ||
        cond == 'cpo' ||
        cond == 'certified pre-owned') {
      pageIds.add(1446611);
    } else {
      pageIds.addAll([1446609, 1446611]);
    }

    final byVin = <String, Map<String, dynamic>>{};
    final make = guest.make.trim();
    final model = guest.model.trim();
    final trim = guest.trim.trim();
    final maxPrice = guest.maxPrice;

    final client = http.Client();
    try {
      for (final pid in pageIds) {
        final batch = <Map<String, dynamic>>[];

        // Strategy 1: Exact Make + Model facet query across all pages
        if (make.isNotEmpty && model.isNotEmpty) {
          final variants = <String>[model];
          final sd = RegExp(r'^f-?([234]50)$', caseSensitive: false)
              .firstMatch(model);
          if (sd != null) {
            variants.add('Super Duty F-${sd.group(1)} SRW');
            variants.add('Super Duty F-${sd.group(1)} DRW');
          } else if (RegExp(r'^mach[\s-]?e$', caseSensitive: false)
              .hasMatch(model)) {
            variants.add('Mustang Mach-E');
          }
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
        if (make.isNotEmpty && model.isEmpty) {
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
          final fallback =
              make.isNotEmpty ? <String, String>{'Make': make} : <String, String>{};
          batch.addAll(await _queryAllCosmosPages(
            client,
            pid,
            fallback,
            maxPrice: maxPrice,
          ));
        }

        for (final v in batch) {
          final vin = v['vin']?.toString() ?? '';
          if (vin.isNotEmpty && !byVin.containsKey(vin)) {
            byVin[vin] = v;
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
    int pageNumber,
  ) async {
    final queryParams = <String, String>{
      ...params,
      'pn': '96',
      'host': _prestonHost,
      if (pageNumber > 1) 'pt': '$pageNumber',
    };
    final uri = Uri.https(
      _prestonHost,
      '/api/vhcliaa/vehicle-pages/cosmos/srp/vehicles/19398/$pageId',
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
          if (attempt == 0) {
            await Future<void>.delayed(const Duration(milliseconds: 350));
            continue;
          }
          return (vehicles: <Map<String, dynamic>>[], totalPages: 1);
        }

        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final cards = data['DisplayCards'] as List<dynamic>? ?? [];
        final out = <Map<String, dynamic>>[];
        for (final item in cards) {
          if (item is! Map || item['IsAdCard'] == true) continue;
          final vc = item['VehicleCard'];
          if (vc is! Map) continue;
          final parsed = _parseVehicleCard(Map<String, dynamic>.from(vc));
          if (parsed != null) out.add(parsed);
        }

        final paging =
            (data['Paging'] as Map?)?['PaginationDataModel'] as Map?;
        final totalCount =
            (paging?['TotalCount'] as num?)?.toInt() ?? out.length;
        final pageSize = (paging?['PageSize'] as num?)?.toInt() ?? 96;
        final computedPages =
            pageSize > 0 ? (totalCount / pageSize).ceil() : 1;
        final rawTotalPages =
            (paging?['TotalPages'] as num?)?.toInt() ?? computedPages;
        final totalPages = rawTotalPages.clamp(1, 25);

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
  }) async {
    final first = await _querySingleCosmosPage(client, pageId, params, 1);
    final all = <Map<String, dynamic>>[...first.vehicles];
    if (first.totalPages <= 1) return all;

    const concurrency = 3;
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
        pageNums.map((pt) => _querySingleCosmosPage(client, pageId, params, pt)),
      );

      bool batchAllOverCap = false;
      for (final page in batchRes) {
        all.addAll(page.vehicles);

        if (maxPrice != null && maxPrice > 0 && page.vehicles.length >= 40) {
          final priced = page.vehicles
              .where((v) => ((v['price'] as num?)?.toDouble() ?? 0) > 0)
              .toList();
          if (priced.length >= 40 &&
              priced.every((v) {
                final p = (v['price'] as num).toDouble();
                final m = (v['msrp'] as num?)?.toDouble();
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

  static Map<String, dynamic>? _parseVehicleCard(Map<String, dynamic> vc) {
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

    final vcInternetPrice = (vc['VehicleInternetPrice'] as num?)?.toDouble();
    final vcMsrp = (vc['VehicleMsrp'] as num?)?.toDouble();
    finalPrice ??= (vcInternetPrice != null && vcInternetPrice > 0)
        ? vcInternetPrice
        : ((vcMsrp != null && vcMsrp > 0) ? vcMsrp : null);
    msrp ??= (vcMsrp != null && vcMsrp > 0) ? vcMsrp : null;

    final highlights =
        ((vc['VehicleHighlightsModel'] as Map?)?['Highlights'] as List?)
                ?.map((e) => e.toString())
                .toList() ??
            <String>[];

    final comments = (vc['VehicleComments']?.toString() ?? '')
        .replaceAll(RegExp(r'<[^>]+>'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();

    final rawDt =
        '${vc['VehicleDriveTrain'] ?? ''} ${highlights.join(' ')} $comments'
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

    final isCpo = vc['VehicleCpo'] == true;
    final condition = isCpo
        ? 'Certified Pre-Owned'
        : (vc['VehicleCondition']?.toString() ??
            (vc['VehicleType'] == 'new' ? 'New' : 'Pre-Owned'));

    return {
      'vin': vin,
      'stockNumber': vc['VehicleStockNumber']?.toString() ?? '',
      'title': vc['VehicleName']?.toString() ?? '',
      'year': (vc['VehicleYear'] as num?)?.toInt(),
      'make': vc['VehicleMake']?.toString() ?? '',
      'model': vc['VehicleModel']?.toString() ?? '',
      'trim': vc['VehicleTrim']?.toString() ?? '',
      'condition': condition,
      'price': finalPrice,
      'msrp': msrp,
      'dealerFee': dealerFee,
      'location': _formatDealershipLocation(vc),
      'dealerCity': (vc['DealerLocatedAtCity']?.toString() ?? '').trim(),
      'dealerState': (vc['DealerLocatedAtState']?.toString() ?? '').trim(),
      'mileage': (vc['VehicleMileage'] as num?)?.toInt() ?? 0,
      'drivetrain': drivetrain,
      'engine': vc['VehicleEngine']?.toString() ?? '',
      'exteriorColor': vc['ExteriorColorLabel']?.toString() ?? '',
      'interiorColor': vc['InteriorColorLabel']?.toString() ?? '',
      'photoUrl': photoUrl,
      'listingUrl': listingUrl,
      'highlights': highlights,
      'commentsSummary':
          comments.length > 700 ? comments.substring(0, 700) : comments,
    };
  }

  static List<Map<String, dynamic>> _preFilter(
      GuestProfile guest, List<Map<String, dynamic>> candidates) {
    final locationHints = _extractLocationHints(guest);

    return candidates.where((v) {
      if (guest.make.isNotEmpty) {
        final m = guest.make.toLowerCase();
        final hay = '${v['make']} ${v['title']}'.toLowerCase();
        if (!hay.contains(m)) return false;
      }
      if (guest.model.isNotEmpty) {
        final tokens = guest.model
            .toLowerCase()
            .replaceAll('-', ' ')
            .split(RegExp(r'\s+'))
            .where((t) => t.isNotEmpty)
            .toList();
        final hay = '${v['model']} ${v['title']} ${v['trim']}'
            .toLowerCase()
            .replaceAll('-', ' ');
        if (!tokens.every((t) => hay.contains(t))) return false;
      }
      final yr = v['year'] as int?;
      if (guest.minYear != null && yr != null && yr < guest.minYear!) {
        return false;
      }
      if (guest.maxYear != null && yr != null && yr > guest.maxYear!) {
        return false;
      }

      // Strict maxPrice check: require verified price <= maxPrice (or MSRP <= maxPrice if unpriced)
      if (guest.maxPrice != null && guest.maxPrice! > 0) {
        final pr = (v['price'] as num?)?.toDouble();
        final msrp = (v['msrp'] as num?)?.toDouble();
        final effectivePrice = (pr != null && pr > 0)
            ? pr
            : ((msrp != null && msrp > 0) ? msrp : null);
        if (effectivePrice == null || effectivePrice > guest.maxPrice!) {
          return false;
        }
      }

      final mi = (v['mileage'] as num?)?.toInt() ?? 0;
      if (guest.maxMileage != null && mi > guest.maxMileage!) {
        return false;
      }

      if (guest.condition.isNotEmpty && guest.condition != 'Any') {
        final c = guest.condition.toLowerCase();
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
    final out = <Map<String, dynamic>>[];

    for (final v in filtered) {
      final matched = <String>[];
      int score = 80;
      final vDt = (v['drivetrain']?.toString() ?? '');
      if (guest.drivetrain != 'Any') {
        if (vDt.isNotEmpty &&
            !vDt.toUpperCase().contains(guest.drivetrain.toUpperCase()) &&
            !vDt.contains('AWD / 4WD')) {
          continue;
        }
        matched.add('${vDt.isNotEmpty ? vDt : guest.drivetrain} Drivetrain');
        score += 5;
      } else if (vDt.isNotEmpty) {
        matched.add('$vDt Drivetrain');
      }

      if (guest.trim.isNotEmpty) {
        final hay =
            '${v['trim']} ${v['title']} ${v['commentsSummary']}'.toLowerCase();
        if (!hay.contains(guest.trim.toLowerCase())) continue;
        matched.add('${v['trim']} Trim');
        score += 5;
      } else if ((v['trim']?.toString() ?? '').isNotEmpty) {
        matched.add('${v['trim']} Trim');
      }

      if (guest.make.isNotEmpty && (v['make']?.toString() ?? '').isNotEmpty) {
        matched.add(
            '${v['year'] ?? ''} ${v['make']} ${v['model']} (${v['condition']})'
                .trim());
      }

      final pr = (v['price'] as num?)?.toDouble();
      if (guest.maxPrice != null && pr != null) {
        final diff = (guest.maxPrice! - pr).round();
        matched.add(diff > 0
            ? '\$${pr.toStringAsFixed(0)} Preston Price (\$$diff under \$${guest.maxPrice!.toStringAsFixed(0)} cap)'
            : 'Within \$${guest.maxPrice!.toStringAsFixed(0)} Budget');
        score += 4;
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
          score += 3;
        }
      }
      for (final h in highlights.take(5)) {
        if (matched.length >= 6) break;
        if (!matched.contains(h)) matched.add(h);
      }

      out.add({
        'vehicle': v,
        'matchScore': score.clamp(1, 99),
        'matchedFeatures': matched.toSet().take(8).toList(),
        'agentSummary':
            'Verified match at ${v['location']}: ${v['title']} (${v['condition']}) priced at ${pr != null ? '\$${pr.toStringAsFixed(0)}' : 'Call for Price'} meets ${guest.name}\'s target specs.',
      });
    }

    out.sort((a, b) {
      final sa = (a['matchScore'] as num?)?.toInt() ?? 80;
      final sb = (b['matchScore'] as num?)?.toInt() ?? 80;
      if (sb != sa) return sb.compareTo(sa);
      final pa =
          ((a['vehicle'] as Map)['price'] as num?)?.toDouble() ?? double.maxFinite;
      final pb =
          ((b['vehicle'] as Map)['price'] as num?)?.toDouble() ?? double.maxFinite;
      return pa.compareTo(pb);
    });

    // Return ALL qualifying vehicles across all Preston locations (no 25-item cap!)
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
            'Scanned ${candidates.length} live prestonmotor.com vehicles; 0 met core criteria.',
      );
    }

    final fullDeterministic = _deterministicEvaluate(guest, filtered);
    final apiKey = (_settings['geminiApiKey']?.toString() ?? '').trim();
    final model = _settings['geminiModel']?.toString() ?? 'gemini-2.5-flash';

    if (apiKey.isNotEmpty) {
      try {
        final sampled = _sampleAcrossLocations(filtered, 30);
        final compact = sampled
            .map((v) => {
                  'vin': v['vin'],
                  'title': v['title'],
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
            'https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent?key=$apiKey');
        final res = await http
            .post(
              uri,
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({
                'systemInstruction': {
                  'parts': [
                    {
                      'text':
                          'Evaluate live prestonmotor.com vehicles against the guest requirements. Return JSON with overallSummary and matches (array of {vin, matchScore, matchedFeatures, agentSummary}).'
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
                            'drivetrain': guest.drivetrain,
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
                  'temperature': 0.15,
                  'responseMimeType': 'application/json',
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
          final sampledVins = {
            for (final v in sampled) v['vin'].toString(),
          };
          final geminiByVin = <String, Map<String, dynamic>>{};

          for (final m in (parsed['matches'] as List<dynamic>? ?? [])) {
            if (m is! Map) continue;
            final vin = m['vin']?.toString() ?? '';
            final v = byVin[vin];
            if (v == null) continue;
            geminiByVin[vin] = {
              'vehicle': v,
              'matchScore': (m['matchScore'] as num?)?.toInt() ?? 88,
              'matchedFeatures': (m['matchedFeatures'] as List<dynamic>? ?? [])
                  .map((e) => e.toString())
                  .toList(),
              'agentSummary': m['agentSummary']?.toString() ?? '',
            };
          }

          List<Map<String, dynamic>> merged;
          if (filtered.length <= 30) {
            merged = geminiByVin.values.toList();
          } else {
            merged = [];
            for (final dm in fullDeterministic) {
              final vin = (dm['vehicle'] as Map)['vin'].toString();
              if (geminiByVin.containsKey(vin)) {
                merged.add(geminiByVin[vin]!);
              } else if (!sampledVins.contains(vin)) {
                merged.add(dm);
              }
            }
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
  /// devices, and merges vehicle matches by (guestId, vin) keeping earliest foundAt.
  static Future<({int totalGuests, int totalMatches, bool localChanged})>
      mergeCloudSnapshot(Map<String, dynamic> remote) async {
    await ensureInitialized();
    final res = _mergeCloudSnapshotSync(remote);
    if (res.localChanged) {
      await _persist();
    } else {
      await _syncWidget();
    }
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
          final existing = _guests[existingIdx];
          final localStamp = (existing['updatedAt'] ??
                  existing['lastSearchedAt'] ??
                  existing['createdAt'] ??
                  '')
              .toString();
          if (rgStamp.compareTo(localStamp) > 0) {
            _guests[existingIdx] = rg;
            localChanged = true;
          }
        }
      }
    }

    // Sort guests newest-first by createdAt
    _guests.sort((a, b) => (b['createdAt'] ?? '')
        .toString()
        .compareTo((a['createdAt'] ?? '').toString()));

    // 3. Merge remote matches for active non-deleted guests
    final activeGuestIds = _guests
        .map((g) => g['id']?.toString() ?? '')
        .where((id) => id.isNotEmpty)
        .toSet();

    _matches.removeWhere(
        (m) => !activeGuestIds.contains(m['guestId']?.toString() ?? ''));

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
        if (gid.isEmpty || vin.isEmpty || !activeGuestIds.contains(gid)) {
          continue;
        }

        final key = '$gid::$vin';
        final rmSeen = (rm['lastSeenAt'] ?? rm['foundAt'] ?? '').toString();
        final existingIdx = localMatchesByKey[key];

        if (existingIdx == null) {
          _matches.add(rm);
          localMatchesByKey[key] = _matches.length - 1;
          localChanged = true;
        } else {
          final existing = _matches[existingIdx];
          final localSeen =
              (existing['lastSeenAt'] ?? existing['foundAt'] ?? '').toString();
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
            };
            localChanged = true;
          }
        }
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

    return (
      totalGuests: _guests.length,
      totalMatches: _matches.length,
      localChanged: localChanged,
    );
  }

  @visibleForTesting
  static void cancelSchedulerForTest() {
    _scheduleTimer?.cancel();
    _scheduleTimer = null;
  }

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


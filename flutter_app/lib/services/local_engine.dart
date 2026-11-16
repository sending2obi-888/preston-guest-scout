import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import '../models/models.dart';
import 'widget_sync_service.dart';

/// Self-contained on-device engine for the Android / Googlebook APK.
/// Persists unlimited guests & matches locally, queries live prestonmotor.com inventory,
/// invokes the Google Gemini API directly, and enforces twice-daily (7:30 AM & 2:00 PM) scans.
class LocalScoutEngine {
  static const MethodChannel _channel =
      MethodChannel('com.prestonmotor.scout/launcher_widget');
  static const String _prestonHost = 'www.prestonmotor.com';
  static const String _prestonBase = 'https://www.prestonmotor.com';

  static bool _initialized = false;
  static bool _isRunningBatch = false;
  static Timer? _scheduleTimer;

  static List<Map<String, dynamic>> _guests = [];
  static List<Map<String, dynamic>> _matches = [];
  static Map<String, dynamic> _settings = {
    'geminiApiKey': '',
    'geminiModel': 'gemini-2.5-flash',
    'timezone': 'America/New_York',
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
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList();
        _matches = (decoded['matches'] as List<dynamic>? ?? [])
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList();
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

  static Future<void> _persist() async {
    if (kIsWeb) return;
    try {
      final payload = jsonEncode({
        'guests': _guests,
        'matches': _matches,
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
        'createdAt': now.subtract(const Duration(minutes: 20)).toIso8601String(),
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
          _settings['completedSlots'] =
              completed.length > 30 ? completed.sublist(completed.length - 30) : completed;
          await _persist();
          await runSearchForAllGuests(slotLabel: '7:30 AM Daily Search');
        }
      }

      // 2:00 PM slot (with wake-up catch-up window through 3:30 PM)
      if (mins >= 14 * 60 && mins <= 15 * 60 + 30) {
        final key = '${dateKey}_14:00';
        if (!completed.contains(key)) {
          completed.add(key);
          _settings['completedSlots'] =
              completed.length > 30 ? completed.sublist(completed.length - 30) : completed;
          await _persist();
          await runSearchForAllGuests(slotLabel: '2:00 PM Daily Search');
        }
      }
    });
  }

  static GuestProfile _hydrateGuest(Map<String, dynamic> g) {
    final gid = g['id']?.toString() ?? '';
    final gMatches =
        _matches.where((m) => m['guestId']?.toString() == gid).toList();
    double? lowest;
    for (final m in gMatches) {
      final p = (m['price'] as num?)?.toDouble();
      if (p != null && (lowest == null || p < lowest)) {
        lowest = p;
      }
    }
    return GuestProfile.fromJson({
      ...g,
      'matchCount': gMatches.length,
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
    final map = <String, dynamic>{
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
    };
    _guests.insert(0, map);
    await _persist();

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
      ..sort((a, b) => b.matchScore.compareTo(a.matchScore));
    return (guest: _hydrateGuest(raw), matches: guestMatches);
  }

  static Future<void> deleteGuest(String guestId) async {
    await ensureInitialized();
    _guests.removeWhere((g) => g['id']?.toString() == guestId);
    _matches.removeWhere((m) => m['guestId']?.toString() == guestId);
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
    };
  }

  static Future<void> updateSettings({
    String? geminiApiKey,
    String? geminiModel,
    String? timezone,
  }) async {
    await ensureInitialized();
    if (geminiApiKey != null) _settings['geminiApiKey'] = geminiApiKey.trim();
    if (geminiModel != null && geminiModel.trim().isNotEmpty) {
      _settings['geminiModel'] = geminiModel.trim();
    }
    if (timezone != null && timezone.trim().isNotEmpty) {
      _settings['timezone'] = timezone.trim();
    }
    await _persist();
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
    }
  }

  static Future<({GuestProfile guest, List<VehicleMatch> matches, String summary})>
      runSearchForSingleGuest(
    String guestId, {
    String slotLabel = 'On-Demand Gemini Search',
  }) async {
    await ensureInitialized();
    final idx = _guests.indexWhere((g) => g['id']?.toString() == guestId);
    if (idx == -1) throw Exception('Guest not found');
    final guest = _hydrateGuest(_guests[idx]);

    final candidates = await _fetchPrestonCandidates(guest);
    final eval = await _evaluateCandidates(guest, candidates);
    final nowIso = DateTime.now().toUtc().toIso8601String();

    for (final item in eval.matches) {
      final v = item['vehicle'] as Map<String, dynamic>;
      final vin = v['vin']?.toString() ?? '';
      if (vin.isEmpty) continue;

      final existingIdx = _matches.indexWhere(
        (m) =>
            m['guestId']?.toString() == guestId &&
            m['vin']?.toString() == vin,
      );

      if (existingIdx != -1) {
        final prev = _matches[existingIdx];
        _matches[existingIdx] = {
          ...prev,
          'price': v['price'],
          'msrp': v['msrp'],
          'dealerFee': v['dealerFee'],
          'location': v['location'],
          'mileage': v['mileage'],
          'photoUrl': v['photoUrl'],
          'listingUrl': v['listingUrl'],
          'matchedFeatures': item['matchedFeatures'],
          'allHighlights': v['highlights'],
          'agentSummary': item['agentSummary'],
          'matchScore': item['matchScore'],
          'lastSeenAt': nowIso,
        };
      } else {
        _matches.add({
          'id': 'match-${DateTime.now().microsecondsSinceEpoch}-$vin',
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
          'foundAt': nowIso,
          'searchSlot': slotLabel,
          'lastSeenAt': nowIso,
        });
      }
    }

    _guests[idx] = {
      ..._guests[idx],
      'lastSearchedAt': nowIso,
      'lastSearchSummary': eval.summary,
    };
    await _persist();

    final updated = await getGuestWithMatches(guestId);
    return (
      guest: updated.guest,
      matches: updated.matches,
      summary: eval.summary,
    );
  }

  static Future<List<Map<String, dynamic>>> _fetchPrestonCandidates(
      GuestProfile guest) async {
    final cond = guest.condition.toLowerCase();
    final pageIds = <int>[];
    if (cond == 'new') {
      pageIds.add(1446609);
    } else if (cond == 'pre-owned' || cond == 'cpo') {
      pageIds.add(1446611);
    } else {
      pageIds.addAll([1446609, 1446611]);
    }

    final byVin = <String, Map<String, dynamic>>{};
    final make = guest.make.trim();
    final model = guest.model.trim();
    final trim = guest.trim.trim();

    for (final pid in pageIds) {
      final batch = <Map<String, dynamic>>[];
      if (make.isNotEmpty && model.isNotEmpty) {
        final variants = <String>[model];
        final sd = RegExp(r'^f-?([234]50)$', caseSensitive: false)
            .firstMatch(model);
        if (sd != null) {
          variants.add('Super Duty F-${sd.group(1)} SRW');
          variants.add('Super Duty F-${sd.group(1)} DRW');
        }
        for (final mv in variants) {
          batch.addAll(await _queryCosmos(pid, {'Make': make, 'Model': mv}));
        }
      }
      if (batch.length < 5) {
        final kw = [make, model, trim].where((s) => s.isNotEmpty).join(' ');
        final qp = <String, String>{};
        if (make.isNotEmpty) qp['Make'] = make;
        if (kw.isNotEmpty) {
          qp['q'] = kw;
        } else if (guest.notes.isNotEmpty) {
          qp['q'] = guest.notes.split(RegExp(r'[.,;\n]')).first.trim();
        }
        batch.addAll(await _queryCosmos(pid, qp));
      }
      if (batch.isEmpty && make.isNotEmpty) {
        batch.addAll(await _queryCosmos(pid, {'Make': make}));
      }
      for (final v in batch) {
        final vin = v['vin']?.toString() ?? '';
        if (vin.isNotEmpty && !byVin.containsKey(vin)) {
          byVin[vin] = v;
        }
      }
    }
    return byVin.values.toList();
  }

  static Future<List<Map<String, dynamic>>> _queryCosmos(
      int pageId, Map<String, String> params) async {
    try {
      final uri = Uri.https(
        _prestonHost,
        '/api/vhcliaa/vehicle-pages/cosmos/srp/vehicles/19398/$pageId',
        {...params, 'pn': '96', 'host': _prestonHost},
      );
      final res = await http.get(uri, headers: {
        'User-Agent':
            'Mozilla/5.0 (X11; CrOS x86_64 14541.0.0) AppleWebKit/537.36',
        'Accept': 'application/json',
      }).timeout(const Duration(seconds: 15));
      if (res.statusCode != 200) return [];
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
      return out;
    } catch (_) {
      return [];
    }
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
    } else if (rawDt.contains('ALL WHEEL DRIVE') || rawDt.contains('ALL-WHEEL')) {
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
      'location': vc['VehicleLocationLabel']?.toString() ??
          vc['VehicleLocation']?.toString() ??
          'Preston Automotive Group',
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
      final pr = (v['price'] as num?)?.toDouble();
      if (guest.maxPrice != null && pr != null && pr > guest.maxPrice!) {
        return false;
      }
      final mi = (v['mileage'] as num?)?.toInt() ?? 0;
      if (guest.maxMileage != null && mi > guest.maxMileage!) {
        return false;
      }
      return true;
    }).toList();
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

    final apiKey = (_settings['geminiApiKey']?.toString() ?? '').trim();
    final model = _settings['geminiModel']?.toString() ?? 'gemini-2.5-flash';

    if (apiKey.isNotEmpty) {
      try {
        final compact = filtered.take(30).map((v) => {
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
            }).toList();

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
                          'Evaluate live prestonmotor.com vehicles against the guest requirements. Return matching VINs, matchScore (1-100), 3-7 concrete matchedFeatures satisfying the guest specs, and a concise agentSummary.'
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
                          'candidates': compact,
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
          final out = <Map<String, dynamic>>[];
          for (final m in (parsed['matches'] as List<dynamic>? ?? [])) {
            if (m is! Map) continue;
            final v = byVin[m['vin']?.toString() ?? ''];
            if (v == null) continue;
            out.add({
              'vehicle': v,
              'matchScore': (m['matchScore'] as num?)?.toInt() ?? 88,
              'matchedFeatures': (m['matchedFeatures'] as List<dynamic>? ?? [])
                  .map((e) => e.toString())
                  .toList(),
              'agentSummary': m['agentSummary']?.toString() ?? '',
            });
          }
          return (
            matches: out,
            summary:
                'Gemini Agent ($model) verified ${out.length} match(es) on prestonmotor.com.',
          );
        }
      } catch (_) {}
    }

    // Smart deterministic evaluation fallback
    final out = <Map<String, dynamic>>[];
    for (final v in filtered.take(25)) {
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
      }

      final pr = (v['price'] as num?)?.toDouble();
      if (guest.maxPrice != null && pr != null) {
        final diff = (guest.maxPrice! - pr).round();
        matched.add(diff > 0
            ? '\$${pr.toStringAsFixed(0)} Preston Price (\$$diff under cap)'
            : 'Within \$${guest.maxPrice!.toStringAsFixed(0)} Budget');
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
      for (final h in highlights.take(4)) {
        if (matched.length >= 6) break;
        if (!matched.contains(h)) matched.add(h);
      }

      out.add({
        'vehicle': v,
        'matchScore': score.clamp(1, 99),
        'matchedFeatures': matched,
        'agentSummary':
            'Verified match at ${v['location']}: ${v['title']} (${v['condition']}) meets ${guest.name}\'s target specs.',
      });
    }

    return (
      matches: out,
      summary:
          'Scanned ${candidates.length} live prestonmotor.com vehicles; found ${out.length} match(es).',
    );
  }
}

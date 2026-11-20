import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import '../models/models.dart';

/// On-device NHTSA (`www.nhtsa.gov/recalls`, `vpic.nhtsa.dot.gov`, `api.nhtsa.gov`)
/// + Google Gemini (`gemini-2.5-flash`) VIN Recall Check service.
class NhtsaRecallService {
  static const String vpicBase = 'https://vpic.nhtsa.dot.gov/api/vehicles';
  static const String nhtsaApiBase = 'https://api.nhtsa.gov';
  static const String nhtsaRecallsWebUrl = 'https://www.nhtsa.gov/recalls';

  @visibleForTesting
  static Future<VinRecallCheckResult> Function(String vin)? mockCheckHandler;

  /// Validates and normalizes a standard 17-character VIN (rejecting I, O, Q).
  static ({bool valid, String vin, String error}) validateAndNormalizeVin(
    String rawVin,
  ) {
    final cleaned = rawVin
        .toUpperCase()
        .replaceAll(RegExp(r'[\s\-]+'), '')
        .trim();

    if (cleaned.isEmpty) {
      return (
        valid: false,
        vin: '',
        error: 'Please enter a 17-character VIN.',
      );
    }
    if (cleaned.length != 17) {
      return (
        valid: false,
        vin: cleaned,
        error:
            'VIN must be exactly 17 characters (currently ${cleaned.length}).',
      );
    }
    final invalidMatches = RegExp(r'[IOQ]')
        .allMatches(cleaned)
        .map((m) => m.group(0)!)
        .toSet()
        .toList();
    if (invalidMatches.isNotEmpty) {
      return (
        valid: false,
        vin: cleaned,
        error:
            'Invalid character(s) ${invalidMatches.join(', ')} — standard 17-character VINs never contain I, O, or Q (use 1 or 0 instead).',
      );
    }
    if (!RegExp(r'^[A-HJ-NPR-Z0-9]{17}$').hasMatch(cleaned)) {
      return (
        valid: false,
        vin: cleaned,
        error:
            'VIN must contain only letters A–Z (excluding I, O, Q) and digits 0–9.',
      );
    }
    return (valid: true, vin: cleaned, error: '');
  }

  /// Parses NHTSA's DD/MM/YYYY date format (e.g. "10/05/2024" -> "May 10, 2024" & "2024-05-10").
  static ({String displayDate, String isoDate}) parseNhtsaReportDate(
    String rawDate,
  ) {
    final s = rawDate.trim();
    if (s.isEmpty) return (displayDate: '', isoDate: '');

    final dmy = RegExp(r'^(\d{1,2})/(\d{1,2})/(\d{4})$').firstMatch(s);
    if (dmy != null) {
      final day = int.tryParse(dmy.group(1)!) ?? 0;
      final month = int.tryParse(dmy.group(2)!) ?? 0;
      final year = int.tryParse(dmy.group(3)!) ?? 0;
      if (month >= 1 && month <= 12 && day >= 1 && day <= 31) {
        final dt = DateTime.utc(year, month, day);
        final iso =
            '${year.toString().padLeft(4, '0')}-${month.toString().padLeft(2, '0')}-${day.toString().padLeft(2, '0')}';
        return (
          displayDate: DateFormat('MMM d, yyyy').format(dt),
          isoDate: iso,
        );
      }
    }

    final parsed = DateTime.tryParse(s);
    if (parsed != null) {
      return (
        displayDate: DateFormat('MMM d, yyyy').format(parsed.toLocal()),
        isoDate: parsed.toUtc().toIso8601String().substring(0, 10),
      );
    }
    return (displayDate: s, isoDate: '');
  }

  static String _titleCaseMake(String rawMake) {
    final s = rawMake.trim();
    if (s.isEmpty) return '';
    final upper = s.toUpperCase();
    if (upper == 'RAM') return 'Ram';
    if (upper == 'KIA') return 'Kia';
    if (const ['BMW', 'GMC', 'MINI', 'FIAT'].contains(upper)) return upper;
    if (upper == 'MERCEDES-BENZ') return 'Mercedes-Benz';
    return s
        .toLowerCase()
        .splitMapJoin(
          RegExp(r'(\s+|-)'),
          onMatch: (m) => m.group(0)!,
          onNonMatch: (part) => part.isEmpty
              ? ''
              : '${part[0].toUpperCase()}${part.substring(1)}',
        );
  }

  /// Matches a decoded vPIC model against NHTSA's recall-specific model taxonomy
  /// (e.g., "Bronco" -> ["BRONCO 2DR", "BRONCO 4DR"] without "BRONCO SPORT",
  /// "Escape" -> ["ESCAPE GAS", ...] filtered by fuel type, "F-250" -> ["F-250 SD"]).
  static List<String> selectMatchingNhtsaRecallModels(
    DecodedVinVehicle decodedVehicle,
    List<String> nhtsaModels,
  ) {
    final baseModel = decodedVehicle.model.trim();
    if (baseModel.isEmpty) return const [];

    final candidates = <String>{};
    final lowerBase = baseModel.toLowerCase();
    final compactBase = lowerBase.replaceAll(RegExp(r'[^a-z0-9]+'), '');
    final fuelLower = decodedVehicle.fuelType.toLowerCase();
    final doors = decodedVehicle.doors.trim();

    for (final rawCand in nhtsaModels) {
      final cand = rawCand.trim();
      if (cand.isEmpty) continue;
      final lowerCand = cand.toLowerCase();
      final compactCand = lowerCand.replaceAll(RegExp(r'[^a-z0-9]+'), '');

      if (lowerBase == 'bronco' &&
          RegExp(r'\bbronco\s+sport\b', caseSensitive: false)
              .hasMatch(lowerCand)) {
        continue;
      }
      if (lowerBase == 'mustang' &&
          RegExp(r'\bmach[\s\-]*e\b', caseSensitive: false)
              .hasMatch(lowerCand)) {
        continue;
      }
      if (lowerBase == 'cherokee' &&
          RegExp(r'\bgrand\s+cherokee\b', caseSensitive: false)
              .hasMatch(lowerCand)) {
        continue;
      }
      if (lowerBase == 'wagoneer' &&
          RegExp(r'\bgrand\s+wagoneer\b', caseSensitive: false)
              .hasMatch(lowerCand)) {
        continue;
      }
      if (lowerBase == 'expedition' &&
          RegExp(r'\bexpedition\s+max\b', caseSensitive: false)
              .hasMatch(lowerCand)) {
        continue;
      }
      if (lowerBase == 'navigator' &&
          RegExp(r'\bnavigator\s+l\b', caseSensitive: false)
              .hasMatch(lowerCand)) {
        continue;
      }
      if (lowerBase == 'corolla' &&
          RegExp(r'\bcorolla\s+cross\b', caseSensitive: false)
              .hasMatch(lowerCand)) {
        continue;
      }
      if (lowerBase == 'highlander' &&
          RegExp(r'\bgrand\s+highlander\b', caseSensitive: false)
              .hasMatch(lowerCand)) {
        continue;
      }
      if (RegExp(r'^f[\s\-]*150$', caseSensitive: false).hasMatch(baseModel) &&
          RegExp(r'\blightning\b', caseSensitive: false).hasMatch(lowerCand)) {
        continue;
      }

      if (doors == '2' &&
          RegExp(r'\b4\s*dr\b', caseSensitive: false).hasMatch(lowerCand)) {
        continue;
      }
      if (doors == '4' &&
          RegExp(r'\b2\s*dr\b', caseSensitive: false).hasMatch(lowerCand)) {
        continue;
      }

      final isPlugIn =
          RegExp(r'plug[\s\-]*in|phev', caseSensitive: false).hasMatch(fuelLower);
      final isHybrid = !isPlugIn &&
          RegExp(r'hybrid|hev', caseSensitive: false).hasMatch(fuelLower);
      final isElectric =
          RegExp(r'electric|bev', caseSensitive: false).hasMatch(fuelLower) &&
              !RegExp(r'hybrid|hev', caseSensitive: false).hasMatch(fuelLower);

      if (!isPlugIn &&
          RegExp(r'\bphev\b|plug[\s\-]*in', caseSensitive: false)
              .hasMatch(lowerCand)) {
        continue;
      }
      if (!isHybrid &&
          RegExp(r'\bhev\b', caseSensitive: false).hasMatch(lowerCand) &&
          !RegExp(r'\bphev\b', caseSensitive: false).hasMatch(lowerCand)) {
        continue;
      }
      if (!isElectric &&
          RegExp(r'\bbev\b|\belectric\b|\blightning\b|\bev\b',
                  caseSensitive: false)
              .hasMatch(lowerCand)) {
        continue;
      }
      if ((isPlugIn || isHybrid || isElectric) &&
          RegExp(r'\bgas\b', caseSensitive: false).hasMatch(lowerCand)) {
        continue;
      }

      final fMatch =
          RegExp(r'^f[\s\-]*(\d{3})$', caseSensitive: false).firstMatch(baseModel);
      if (fMatch != null) {
        final digits = fMatch.group(1)!;
        if (RegExp('\\bf[\\s\\-]*$digits\\b', caseSensitive: false)
            .hasMatch(lowerCand)) {
          candidates.add(cand);
        }
        continue;
      }

      final baseWords = lowerBase
          .replaceAll(RegExp(r'[\-+]'), ' ')
          .split(RegExp(r'\s+'))
          .where((w) => w.isNotEmpty)
          .toList();
      final candWords = lowerCand.replaceAll(RegExp(r'[\-+]'), ' ');
      final allTokensMatch = baseWords.every(
        (w) => RegExp('\\b${RegExp.escape(w)}\\b', caseSensitive: false)
            .hasMatch(candWords),
      );

      if (allTokensMatch || compactCand == compactBase) {
        candidates.add(cand);
      }
    }

    candidates.add(baseModel);
    return candidates.toList();
  }

  static Future<({DecodedVinVehicle vehicle, String errorText})> _decodeVinViaVpic(
    String vin,
  ) async {
    final uri = Uri.parse(
      '$vpicBase/DecodeVinValues/${Uri.encodeComponent(vin)}?format=json',
    );
    final res = await http
        .get(
          uri,
          headers: const {
            'Accept': 'application/json',
            'User-Agent': 'PrestonGuestScout/1.9 (NHTSA VIN Recall Checker)',
          },
        )
        .timeout(const Duration(seconds: 15));

    if (res.statusCode != 200) {
      throw Exception('NHTSA vPIC VIN decoder returned HTTP ${res.statusCode}');
    }

    final data = jsonDecode(res.body) as Map<String, dynamic>;
    final results = data['Results'] as List<dynamic>? ?? const [];
    final row = results.isNotEmpty && results.first is Map
        ? Map<String, dynamic>.from(results.first as Map)
        : <String, dynamic>{};

    final yearNum = int.tryParse(row['ModelYear']?.toString() ?? '');
    final make = _titleCaseMake(row['Make']?.toString() ?? '');
    final model = (row['Model']?.toString() ?? '').trim();
    final trimRaw = (row['Trim']?.toString() ?? '').trim();
    final series1 = (row['Series']?.toString() ?? '').trim();
    final series2 = (row['Series2']?.toString() ?? '').trim();
    final trim = trimRaw.isNotEmpty ? trimRaw : series1;
    final series = [series1, series2].where((s) => s.isNotEmpty).join(' • ');

    final bodyClass = [
      row['BodyClass']?.toString() ?? '',
      row['BodyCabType']?.toString() ?? '',
    ]
        .map((x) => x.trim())
        .where((x) => x.isNotEmpty && !x.toLowerCase().contains('not applicable'))
        .join(' • ');

    final dispDouble = double.tryParse(row['DisplacementL']?.toString() ?? '');
    final dispStr = dispDouble != null ? '${dispDouble.toStringAsFixed(1)}L' : '';
    final cylRaw = (row['EngineCylinders']?.toString() ?? '').trim();
    final cylStr = cylRaw.isNotEmpty ? '$cylRaw-Cyl' : '';
    final fuel = (row['FuelTypePrimary']?.toString() ?? '').trim();
    final elec = (row['ElectrificationLevel']?.toString() ?? '').trim();
    final turbo = (row['Turbo']?.toString() ?? '').toLowerCase() == 'yes'
        ? 'Turbo'
        : '';
    final engine = [dispStr, cylStr, turbo, fuel]
        .where((s) => s.isNotEmpty)
        .join(' ')
        .trim();

    final plant = [
      row['PlantCity']?.toString() ?? '',
      row['PlantState']?.toString() ?? '',
      row['PlantCountry']?.toString() ?? '',
    ].map((x) => x.trim()).where((x) => x.isNotEmpty).join(', ');

    final decoded = DecodedVinVehicle(
      vin: vin,
      year: yearNum,
      make: make,
      model: model,
      trim: trim,
      series: series,
      bodyClass: bodyClass,
      driveType: (row['DriveType']?.toString() ?? '').trim(),
      engine: engine,
      displacementL: (row['DisplacementL']?.toString() ?? '').trim(),
      cylinders: cylRaw,
      fuelType: [fuel, elec].where((s) => s.isNotEmpty).join(' • '),
      doors: (row['Doors']?.toString() ?? '').trim(),
      plant: plant,
      manufacturer: (row['Manufacturer']?.toString() ?? '').trim(),
    );

    return (
      vehicle: decoded,
      errorText: (row['ErrorText']?.toString() ?? '').trim(),
    );
  }

  static Future<
      ({
        List<NhtsaRecallCampaign> recalls,
        List<String> queriedModels,
        bool nhtsaSiteReachable,
      })> _fetchNhtsaRecallsForVehicle(DecodedVinVehicle decoded) async {
    if (decoded.year == null || decoded.make.isEmpty || decoded.model.isEmpty) {
      return (
        recalls: const <NhtsaRecallCampaign>[],
        queriedModels: const <String>[],
        nhtsaSiteReachable: false,
      );
    }

    final nhtsaVinPageUri = Uri.parse(
      '$nhtsaRecallsWebUrl?vin=${Uri.encodeComponent(decoded.vin)}',
    );
    final modelsUri = Uri.parse(
      '$nhtsaApiBase/products/vehicle/models?modelYear=${Uri.encodeComponent('${decoded.year}')}&make=${Uri.encodeComponent(decoded.make)}&issueType=r',
    );

    bool siteReachable = false;
    final taxonomyModels = <String>[];

    await Future.wait([
      () async {
        try {
          final r = await http
              .get(
                nhtsaVinPageUri,
                headers: const {'Accept': 'text/html,application/xhtml+xml'},
              )
              .timeout(const Duration(seconds: 10));
          siteReachable = r.statusCode >= 200 && r.statusCode < 400;
        } catch (_) {
          siteReachable = false;
        }
      }(),
      () async {
        try {
          final r = await http
              .get(
                modelsUri,
                headers: const {
                  'Accept': 'application/json',
                  'User-Agent': 'PrestonGuestScout/1.9',
                },
              )
              .timeout(const Duration(seconds: 12));
          if (r.statusCode == 200) {
            final mj = jsonDecode(r.body) as Map<String, dynamic>;
            for (final item in (mj['results'] as List<dynamic>? ?? const [])) {
              if (item is Map && item['model'] != null) {
                final m = item['model'].toString().trim();
                if (m.isNotEmpty) taxonomyModels.add(m);
              }
            }
          }
        } catch (_) {}
      }(),
    ]);

    final modelsToQuery = selectMatchingNhtsaRecallModels(
      decoded,
      taxonomyModels,
    );
    final byCampaign = <String, NhtsaRecallCampaign>{};

    await Future.wait(
      modelsToQuery.map((modelName) async {
        try {
          final uri = Uri.parse('$nhtsaApiBase/recalls/recallsByVehicle').replace(
            queryParameters: {
              'make': decoded.make,
              'model': modelName,
              'modelYear': '${decoded.year}',
            },
          );
          final r = await http
              .get(
                uri,
                headers: const {
                  'Accept': 'application/json',
                  'User-Agent': 'PrestonGuestScout/1.9',
                },
              )
              .timeout(const Duration(seconds: 15));
          if (r.statusCode != 200) return;
          final j = jsonDecode(r.body) as Map<String, dynamic>;
          final items = (j['results'] ?? j['Results']) as List<dynamic>? ?? const [];
          for (final rawItem in items) {
            if (rawItem is! Map) continue;
            final item = Map<String, dynamic>.from(rawItem);
            final campaign =
                (item['NHTSACampaignNumber']?.toString() ?? '').trim();
            if (campaign.isEmpty || byCampaign.containsKey(campaign)) continue;
            final dates = parseNhtsaReportDate(
              item['ReportReceivedDate']?.toString() ?? '',
            );
            byCampaign[campaign] = NhtsaRecallCampaign(
              campaignNumber: campaign,
              manufacturer: (item['Manufacturer']?.toString() ??
                      decoded.manufacturer)
                  .trim(),
              component:
                  (item['Component']?.toString() ?? 'Vehicle Safety System')
                      .trim(),
              reportDate: dates.displayDate,
              reportIsoDate: dates.isoDate,
              summary: (item['Summary']?.toString() ?? '')
                  .replaceAll(RegExp(r'\s+'), ' ')
                  .trim(),
              consequence: (item['Consequence']?.toString() ?? '')
                  .replaceAll(RegExp(r'\s+'), ' ')
                  .trim(),
              remedy: (item['Remedy']?.toString() ?? '')
                  .replaceAll(RegExp(r'\s+'), ' ')
                  .trim(),
              notes: (item['Notes']?.toString() ?? '')
                  .replaceAll(RegExp(r'\s+'), ' ')
                  .trim(),
              parkIt: item['parkIt'] == true,
              parkOutSide: item['parkOutSide'] == true,
              overTheAirUpdate: item['overTheAirUpdate'] == true,
              nhtsaModelMatched:
                  (item['Model']?.toString() ?? modelName).trim(),
              applicability: 'Matches Decoded Vehicle',
            );
          }
        } catch (_) {}
      }),
    );

    final recalls = byCampaign.values.toList()
      ..sort((a, b) => b.reportIsoDate.compareTo(a.reportIsoDate));

    return (
      recalls: recalls,
      queriedModels: modelsToQuery,
      nhtsaSiteReachable: siteReachable,
    );
  }

  static List<NhtsaRecallCampaign> _annotateDeterministically(
    DecodedVinVehicle decoded,
    List<NhtsaRecallCampaign> recalls,
  ) {
    final dispVal = double.tryParse(decoded.displacementL);
    final vDisp = dispVal != null ? dispVal.toStringAsFixed(1) : '';
    final vFuel = decoded.fuelType.toLowerCase();

    return recalls.map((rec) {
      final text = '${rec.summary} ${rec.component}'.toLowerCase();
      final mentionedDisps = RegExp(
        r'\b(\d\.\d)\s*-?\s*l(?:iter)?\b',
        caseSensitive: false,
      )
          .allMatches(text)
          .map((m) => double.tryParse(m.group(1)!)?.toStringAsFixed(1) ?? '')
          .where((s) => s.isNotEmpty)
          .toSet()
          .toList();

      if (vDisp.isNotEmpty &&
          mentionedDisps.isNotEmpty &&
          !mentionedDisps.contains(vDisp)) {
        return NhtsaRecallCampaign(
          campaignNumber: rec.campaignNumber,
          manufacturer: rec.manufacturer,
          component: rec.component,
          reportDate: rec.reportDate,
          reportIsoDate: rec.reportIsoDate,
          summary: rec.summary,
          consequence: rec.consequence,
          remedy: rec.remedy,
          notes: rec.notes,
          parkIt: rec.parkIt,
          parkOutSide: rec.parkOutSide,
          overTheAirUpdate: rec.overTheAirUpdate,
          nhtsaModelMatched: rec.nhtsaModelMatched,
          applicability: 'Other Engine / Equipment Variant',
          geminiNote:
              'Campaign specifically references ${mentionedDisps.join('/')}L engine; this VIN decoded with ${vDisp}L.',
        );
      }

      if (RegExp(r'\bhybrid\b', caseSensitive: false).hasMatch(text) &&
          vFuel.isNotEmpty &&
          !vFuel.contains('hybrid') &&
          !vFuel.contains('electric')) {
        return NhtsaRecallCampaign(
          campaignNumber: rec.campaignNumber,
          manufacturer: rec.manufacturer,
          component: rec.component,
          reportDate: rec.reportDate,
          reportIsoDate: rec.reportIsoDate,
          summary: rec.summary,
          consequence: rec.consequence,
          remedy: rec.remedy,
          notes: rec.notes,
          parkIt: rec.parkIt,
          parkOutSide: rec.parkOutSide,
          overTheAirUpdate: rec.overTheAirUpdate,
          nhtsaModelMatched: rec.nhtsaModelMatched,
          applicability: 'Other Powertrain Variant',
          geminiNote:
              'Campaign targets Hybrid powertrain; this VIN decoded as ${decoded.fuelType}.',
        );
      }

      return NhtsaRecallCampaign(
        campaignNumber: rec.campaignNumber,
        manufacturer: rec.manufacturer,
        component: rec.component,
        reportDate: rec.reportDate,
        reportIsoDate: rec.reportIsoDate,
        summary: rec.summary,
        consequence: rec.consequence,
        remedy: rec.remedy,
        notes: rec.notes,
        parkIt: rec.parkIt,
        parkOutSide: rec.parkOutSide,
        overTheAirUpdate: rec.overTheAirUpdate,
        nhtsaModelMatched: rec.nhtsaModelMatched,
        applicability: 'Matches Decoded Vehicle',
        geminiNote:
            'Matches this VIN\'s decoded model year, make, model, and powertrain.',
      );
    }).toList();
  }

  /// Checks `www.nhtsa.gov/recalls` + official NHTSA vPIC/Recalls APIs and analyzes
  /// recall applicability with Gemini (`gemini-2.5-flash`).
  static Future<VinRecallCheckResult> checkVinRecalls({
    required String rawVin,
    String geminiApiKey = '',
    String geminiModel = 'gemini-2.5-flash',
  }) async {
    final validation = validateAndNormalizeVin(rawVin);
    if (!validation.valid) {
      throw Exception(validation.error);
    }

    final vin = validation.vin;
    if (mockCheckHandler != null) {
      return mockCheckHandler!(vin);
    }

    final nhtsaUrl = '$nhtsaRecallsWebUrl?vin=${Uri.encodeComponent(vin)}';
    final (:vehicle, :errorText) = await _decodeVinViaVpic(vin);

    if (vehicle.make.isEmpty || vehicle.year == null) {
      throw Exception(
        'Unable to decode a valid vehicle from VIN "$vin" via NHTSA vPIC (${errorText.isNotEmpty ? errorText : 'unrecognized WMI/model year'}). Double-check all 17 characters.',
      );
    }

    final fetched = await _fetchNhtsaRecallsForVehicle(vehicle);
    final annotated = _annotateDeterministically(vehicle, fetched.recalls);
    final matchingRecalls =
        annotated.where((r) => !r.isOtherVariant).toList();

    final vehicleTitle = [
      if (vehicle.year != null) '${vehicle.year}',
      vehicle.make,
      vehicle.model,
      vehicle.trim,
    ].where((s) => s.trim().isNotEmpty).join(' ');

    final urgentParkIt = annotated.any((r) => r.parkIt);
    final urgentParkOutside = annotated.any((r) => r.parkOutSide);

    final fallbackSummary = annotated.isEmpty
        ? 'Checked NHTSA ($nhtsaRecallsWebUrl) for VIN $vin ($vehicleTitle): 0 safety recall campaigns are on file for this vehicle.'
        : matchingRecalls.isNotEmpty
            ? 'Checked NHTSA ($nhtsaRecallsWebUrl) for VIN $vin ($vehicleTitle): found ${matchingRecalls.length} matching NHTSA safety recall campaign(s)${annotated.length > matchingRecalls.length ? ' (${annotated.length} total on the ${vehicle.year} ${vehicle.make} ${vehicle.model} line)' : ''}. Confirm VIN-specific repair completion status on NHTSA.gov/recalls or with an authorized ${vehicle.make} service department.'
            : 'Found ${annotated.length} recall campaign(s) on the ${vehicle.year} ${vehicle.make} ${vehicle.model} model line, though they appear specific to different engine/equipment variants than this VIN (${vehicle.engine.isNotEmpty ? vehicle.engine : 'decoded build'}). Verify exact VIN status on NHTSA.gov/recalls.';

    final fallbackAction = annotated.isEmpty
        ? 'No open NHTSA model-level safety recalls found. You can still tap "Verify on www.nhtsa.gov/recalls" anytime before delivery.'
        : urgentParkIt
            ? 'URGENT — DO NOT DRIVE warning present on at least one campaign. Verify immediately on www.nhtsa.gov/recalls and schedule authorized dealer repair before driving.'
            : urgentParkOutside
                ? 'IMPORTANT — Park Outside advisory present. Verify VIN repair history on www.nhtsa.gov/recalls and schedule free recall remedy with service.'
                : 'Verify whether each campaign remedy has already been completed for VIN $vin on www.nhtsa.gov/recalls or in ${vehicle.make} warranty/OASIS history.';

    final cleanKey = geminiApiKey.trim();
    final cleanModel =
        geminiModel.trim().isNotEmpty ? geminiModel.trim() : 'gemini-2.5-flash';

    String agentMode = 'nhtsa-smart-analyzer';
    bool finalHasRecalls = matchingRecalls.isNotEmpty;
    int finalCount = matchingRecalls.length;
    String verdictHeadline = finalHasRecalls
        ? '$finalCount NHTSA Recall Campaign(s) Found for $vehicleTitle'
        : 'No Matching NHTSA Recalls Found for $vehicleTitle';
    String geminiSummary = fallbackSummary;
    String recommendedAction = fallbackAction;
    List<NhtsaRecallCampaign> finalRecalls = annotated;

    if (cleanKey.isNotEmpty) {
      final promptPayload = {
        'referenceWebsite': nhtsaUrl,
        'vin': vin,
        'decodedVehicleFromNhtsaVpic': vehicle.toJson(),
        'nhtsaRecallCampaignsOnFile': annotated
            .map(
              (r) => {
                'campaignNumber': r.campaignNumber,
                'reportDate': r.reportDate,
                'component': r.component,
                'parkItDoNotDrive': r.parkIt,
                'parkOutsideWarning': r.parkOutSide,
                'overTheAirUpdate': r.overTheAirUpdate,
                'summary': r.summary,
                'consequence': r.consequence,
                'remedy': r.remedy,
                'initialSpecCheck': r.applicability,
              },
            )
            .toList(),
      };

      const systemPrompt =
          'You are the Preston Automotive Group Gemini NHTSA Recall Inspector. '
          'Check NHTSA recall data from www.nhtsa.gov/recalls and NHTSA\'s official vPIC + Recalls database for a specific 17-character VIN and determine whether the vehicle has any recalls. '
          'Cross-reference each NHTSA recall campaign against the VIN\'s decoded factory specifications (Model Year, Make, Model, Trim/Series, Body Class, Engine displacement/cylinders/fuel, Drivetrain, Assembly Plant). '
          'Classify each campaign\'s applicability as "Matches Decoded Vehicle", "Verify Build Date / Equipment", or "Other Engine / Equipment Variant" with a concise 1-sentence geminiNote, and provide verdictHeadline, geminiSummary referencing www.nhtsa.gov/recalls, and recommendedAction.';

      final endpoint = Uri.parse(
        'https://generativelanguage.googleapis.com/v1beta/models/${Uri.encodeComponent(cleanModel)}:generateContent?key=${Uri.encodeComponent(cleanKey)}',
      );

      Map<String, dynamic>? parsed;
      bool usedGrounded = false;

      // Attempt 1: Grounded urlContext check on https://www.nhtsa.gov/recalls?vin=<VIN>
      try {
        final r1 = await http
            .post(
              endpoint,
              headers: const {'Content-Type': 'application/json'},
              body: jsonEncode({
                'systemInstruction': {
                  'parts': [
                    {'text': systemPrompt}
                  ],
                },
                'tools': [
                  {'urlContext': <String, dynamic>{}}
                ],
                'contents': [
                  {
                    'role': 'user',
                    'parts': [
                      {
                        'text':
                            'Check $nhtsaUrl and analyze these official NHTSA recall records for VIN $vin. Return ONLY valid JSON with keys: hasRecalls (boolean), applicableCount (integer), verdictHeadline (string), geminiSummary (string), recommendedAction (string), campaignAssessments (array of {campaignNumber, applicability, geminiNote}).\n\nData:\n${jsonEncode(promptPayload)}',
                      }
                    ],
                  }
                ],
                'generationConfig': {'temperature': 0.1},
              }),
            )
            .timeout(const Duration(seconds: 25));

        if (r1.statusCode == 200) {
          final d1 = jsonDecode(r1.body) as Map<String, dynamic>;
          final parts = ((d1['candidates'] as List?)?.firstOrNull
                  as Map?)?['content']?['parts'] as List? ??
              const [];
          final rawText = parts
              .map((p) => (p as Map?)?['text']?.toString() ?? '')
              .join('\n')
              .trim();
          final match = RegExp(r'\{[\s\S]*\}').firstMatch(rawText);
          if (match != null) {
            parsed = jsonDecode(match.group(0)!) as Map<String, dynamic>;
            usedGrounded = true;
          }
        }
      } catch (_) {}

      // Attempt 2: Guaranteed structured responseSchema JSON
      if (parsed == null) {
        try {
          final r2 = await http
              .post(
                endpoint,
                headers: const {'Content-Type': 'application/json'},
                body: jsonEncode({
                  'systemInstruction': {
                    'parts': [
                      {'text': systemPrompt}
                    ],
                  },
                  'contents': [
                    {
                      'role': 'user',
                      'parts': [
                        {'text': jsonEncode(promptPayload)}
                      ],
                    }
                  ],
                  'generationConfig': {
                    'temperature': 0.1,
                    'responseMimeType': 'application/json',
                    'responseSchema': {
                      'type': 'OBJECT',
                      'properties': {
                        'hasRecalls': {'type': 'BOOLEAN'},
                        'applicableCount': {'type': 'INTEGER'},
                        'verdictHeadline': {'type': 'STRING'},
                        'geminiSummary': {'type': 'STRING'},
                        'recommendedAction': {'type': 'STRING'},
                        'campaignAssessments': {
                          'type': 'ARRAY',
                          'items': {
                            'type': 'OBJECT',
                            'properties': {
                              'campaignNumber': {'type': 'STRING'},
                              'applicability': {'type': 'STRING'},
                              'geminiNote': {'type': 'STRING'},
                            },
                            'required': [
                              'campaignNumber',
                              'applicability',
                              'geminiNote',
                            ],
                          },
                        },
                      },
                      'required': [
                        'hasRecalls',
                        'applicableCount',
                        'verdictHeadline',
                        'geminiSummary',
                        'recommendedAction',
                        'campaignAssessments',
                      ],
                    },
                  },
                }),
              )
              .timeout(const Duration(seconds: 25));

          if (r2.statusCode == 200) {
            final d2 = jsonDecode(r2.body) as Map<String, dynamic>;
            final raw2 = (((d2['candidates'] as List?)?.firstOrNull
                            as Map?)?['content']?['parts'] as List?)
                        ?.firstOrNull?['text']
                        ?.toString() ??
                    '{}';
            parsed = jsonDecode(raw2) as Map<String, dynamic>;
          }
        } catch (_) {}
      }

      if (parsed != null) {
        final assessMap = <String, Map<String, dynamic>>{};
        for (final item
            in (parsed['campaignAssessments'] as List<dynamic>? ?? const [])) {
          if (item is Map && item['campaignNumber'] != null) {
            assessMap[item['campaignNumber'].toString().trim()] =
                Map<String, dynamic>.from(item);
          }
        }

        finalRecalls = annotated.map((r) {
          final a = assessMap[r.campaignNumber];
          if (a == null) return r;
          return NhtsaRecallCampaign(
            campaignNumber: r.campaignNumber,
            manufacturer: r.manufacturer,
            component: r.component,
            reportDate: r.reportDate,
            reportIsoDate: r.reportIsoDate,
            summary: r.summary,
            consequence: r.consequence,
            remedy: r.remedy,
            notes: r.notes,
            parkIt: r.parkIt,
            parkOutSide: r.parkOutSide,
            overTheAirUpdate: r.overTheAirUpdate,
            nhtsaModelMatched: r.nhtsaModelMatched,
            applicability:
                (a['applicability']?.toString() ?? r.applicability).trim(),
            geminiNote: (a['geminiNote']?.toString() ?? r.geminiNote).trim(),
          );
        }).toList();

        finalCount = finalRecalls.where((r) => !r.isOtherVariant).length;
        finalHasRecalls = finalRecalls.isEmpty
            ? false
            : (parsed['hasRecalls'] == true || finalCount > 0);
        agentMode = usedGrounded
            ? 'gemini-url-context ($cleanModel)'
            : 'gemini ($cleanModel)';
        final rawHeadline =
            (parsed['verdictHeadline']?.toString() ?? '').trim();
        verdictHeadline = rawHeadline.isNotEmpty
            ? rawHeadline
            : (finalHasRecalls
                ? '$finalCount NHTSA Recall Campaign(s) Found for $vehicleTitle'
                : 'No Matching NHTSA Recalls Found for $vehicleTitle');
        final rawSummary = (parsed['geminiSummary']?.toString() ?? '').trim();
        if (rawSummary.isNotEmpty) geminiSummary = rawSummary;
        final rawAction =
            (parsed['recommendedAction']?.toString() ?? '').trim();
        if (rawAction.isNotEmpty) recommendedAction = rawAction;
      }
    }

    final checkedAt = DateTime.now().toUtc().toIso8601String();
    return VinRecallCheckResult(
      id: 'recall-${DateTime.now().microsecondsSinceEpoch}',
      vin: vin,
      nhtsaUrl: nhtsaUrl,
      nhtsaSiteReachable: fetched.nhtsaSiteReachable,
      checkedAt: checkedAt,
      agentMode: agentMode,
      vehicleTitle: vehicleTitle,
      vehicle: vehicle,
      queriedModels: fetched.queriedModels,
      hasRecalls: finalHasRecalls,
      recallCount: finalCount,
      totalModelRecalls: finalRecalls.length,
      parkItUrgent: urgentParkIt,
      parkOutsideWarning: urgentParkOutside,
      verdictHeadline: verdictHeadline,
      geminiSummary: geminiSummary,
      recommendedAction: recommendedAction,
      recalls: finalRecalls,
    );
  }
}

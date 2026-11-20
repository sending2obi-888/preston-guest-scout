import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import '../models/models.dart';

class VinOpenRecallRecord {
  final String recallDate;
  final String recallType;
  final String nhtsaPrefix;
  final String oemRecallNumber;
  final String description;
  final String statusText;

  const VinOpenRecallRecord({
    this.recallDate = '',
    this.recallType = '',
    this.nhtsaPrefix = '',
    this.oemRecallNumber = '',
    this.description = '',
    this.statusText = '',
  });
}

class VinOpenRecallLookup {
  final bool verified;
  final int? openRecallCount;
  final List<VinOpenRecallRecord> openRecalls;

  const VinOpenRecallLookup({
    required this.verified,
    this.openRecallCount,
    this.openRecalls = const [],
  });
}

/// On-device NHTSA (`www.nhtsa.gov/recalls`, `vpic.nhtsa.dot.gov`, `api.nhtsa.gov`)
/// + Live Per-VIN Open Recall Status + Google Gemini (`gemini-2.5-flash`) VIN Recall Check service.
class NhtsaRecallService {
  static const String vpicBase = 'https://vpic.nhtsa.dot.gov/api/vehicles';
  static const String nhtsaApiBase = 'https://api.nhtsa.gov';
  static const String nhtsaRecallsWebUrl = 'https://www.nhtsa.gov/recalls';
  static const String prestonAutoCheckUrl =
      'https://www.prestonmotor.com/autocheck.aspx';
  static const String prestonAutoCheckAccount = 'NQAyADAAOAA2ADYAOAA%3d';

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

  /// Encodes a 17-character VIN as UTF-16LE Base64 (matching Node `Buffer.from(vin, 'utf16le').toString('base64')`).
  static String encodeVinUtf16LeBase64(String vin) {
    final normalized = vin.trim().toUpperCase();
    final bytes = Uint8List(normalized.length * 2);
    for (var i = 0; i < normalized.length; i++) {
      final code = normalized.codeUnitAt(i);
      bytes[i * 2] = code & 0xff;
      bytes[i * 2 + 1] = (code >> 8) & 0xff;
    }
    return base64Encode(bytes);
  }

  /// Normalizes an NHTSA campaign identifier to its 6-character core prefix (e.g. "25V347000" -> "25V347").
  static String normalizeNhtsaPrefix(String rawCampaign) {
    final cleaned = rawCampaign
        .toUpperCase()
        .replaceAll(RegExp(r'[\s\-]+'), '')
        .trim();
    if (cleaned.isEmpty || cleaned == 'NA' || cleaned == 'N/A') return '';
    if (RegExp(r'^\d{2}[A-Z]\d{3}000$').hasMatch(cleaned)) {
      return cleaned.substring(0, 6);
    }
    return cleaned;
  }

  /// Extracts manufacturer / OEM recall code from NHTSA Remedy / Summary / Notes text
  /// (e.g. "Ford's number for this recall is 25S53." -> "25S53").
  static String extractOemRecallNumber(List<String> texts) {
    final combined = texts
        .map((t) => t.trim())
        .where((t) => t.isNotEmpty)
        .join(' ');
    if (combined.isEmpty) return '';

    final patterns = <RegExp>[
      RegExp(
        r'(?:number\s+for\s+this\s+recall\s+is|recall\s+number\s+(?:for\s+this\s+recall\s+)?is|campaign\s+number\s+is)\s+([A-Z0-9][A-Z0-9\-]{1,14})',
        caseSensitive: false,
      ),
      RegExp(
        r"manufacturer(?:'s)?\s+recall\s+(?:number|code|id)\s*[:#]?\s*([A-Z0-9][A-Z0-9\-]{1,14})",
        caseSensitive: false,
      ),
    ];

    for (final re in patterns) {
      final m = re.firstMatch(combined);
      if (m != null && m.group(1) != null) {
        final candidate = m
            .group(1)!
            .replaceAll(RegExp(r'[.,;:]+$'), '')
            .toUpperCase()
            .trim();
        if (RegExp(r'\d').hasMatch(candidate) && candidate.length >= 2) {
          return candidate;
        }
      }
    }
    return '';
  }

  static bool isRemedyUnavailableText(List<String> texts) {
    final combined = texts
        .map((t) => t.trim())
        .where((t) => t.isNotEmpty)
        .join(' ');
    return RegExp(
      r'remedy\s+(?:is\s+)?not\s+(?:yet\s+)?available|remedy\s+(?:is\s+)?currently\s+under\s+development|remedy\s+under\s+development|parts\s+are\s+not\s+(?:yet\s+)?available',
      caseSensitive: false,
    ).hasMatch(combined);
  }

  static String _stripHtmlAndDecodeEntities(String rawHtml) {
    return rawHtml
        .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), ' | ')
        .replaceAll(RegExp(r'<[^>]+>'), ' ')
        .replaceAll(RegExp(r'&nbsp;', caseSensitive: false), ' ')
        .replaceAll(RegExp(r'&amp;', caseSensitive: false), '&')
        .replaceAll(RegExp(r'&quot;', caseSensitive: false), '"')
        .replaceAll(RegExp(r'&#39;', caseSensitive: false), "'")
        .replaceAll(RegExp(r'&lt;', caseSensitive: false), '<')
        .replaceAll(RegExp(r'&gt;', caseSensitive: false), '>')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  static ({String displayDate, String isoDate}) _parseUsMonthDayYearDate(
    String rawDate,
  ) {
    final s = rawDate.trim();
    final mdy = RegExp(r'^(\d{1,2})/(\d{1,2})/(\d{4})$').firstMatch(s);
    if (mdy != null) {
      final month = int.tryParse(mdy.group(1)!) ?? 0;
      final day = int.tryParse(mdy.group(2)!) ?? 0;
      final year = int.tryParse(mdy.group(3)!) ?? 0;
      if (month >= 1 && month <= 12 && day >= 1 && day <= 31) {
        final dt = DateTime.utc(year, month, day);
        return (
          displayDate: DateFormat('MMM d, yyyy').format(dt),
          isoDate:
              '${year.toString().padLeft(4, '0')}-${month.toString().padLeft(2, '0')}-${day.toString().padLeft(2, '0')}',
        );
      }
    }
    return parseNhtsaReportDate(s);
  }

  /// Parses live VIN-specific Open Recall HTML from Preston's AutoCheck report
  /// so we differentiate Incomplete (Open) vs Complete (Closed) recalls per VIN.
  static VinOpenRecallLookup parseVinOpenRecallHtml(String html) {
    if (html.isEmpty ||
        (!RegExp(r'Open\s+Recall\s+Check', caseSensitive: false)
                .hasMatch(html) &&
            !html.contains('id="recallSection"'))) {
      return const VinOpenRecallLookup(verified: false);
    }

    int? declaredCount;
    if (RegExp(r'\bNo\s+Open\s+Recalls\b', caseSensitive: false)
            .hasMatch(html) ||
        RegExp(r'AutoCheck\s+found\s+no\s+open\s+recalls', caseSensitive: false)
            .hasMatch(html)) {
      declaredCount = 0;
    } else {
      final m = RegExp(
            r'AutoCheck\s+found\s*<span[^>]*>\s*(\d+)\s*</span>\s*open\s+recall',
            caseSensitive: false,
          ).firstMatch(html) ??
          RegExp(
            r'<p[^>]*>\s*Open\s+Recall\s+Check\s*</p>[\s\S]{0,1400}?(\d+)\s+Open\s+Recall',
            caseSensitive: false,
          ).firstMatch(html) ??
          RegExp(
            r'Open\s+Recall\s+Check[\s\S]{0,1600}?(\d+)\s+Open\s+Recall',
            caseSensitive: false,
          ).firstMatch(html);
      if (m != null && m.group(1) != null) {
        declaredCount = int.tryParse(m.group(1)!);
      }
    }

    final openRecalls = <VinOpenRecallRecord>[];
    final secIdx = html.indexOf('id="recallSection"');
    if (secIdx >= 0) {
      final afterSec = html.substring(secIdx);
      final bodyStart = afterSec.indexOf('<div class="rTableBody">');
      final mobileMarker = afterSec.indexOf('<!-- Mobile -->');
      final serviceMarker = afterSec.indexOf('id="serviceHistorySummary"');
      final endBound = mobileMarker > bodyStart && mobileMarker != -1
          ? mobileMarker
          : (serviceMarker > bodyStart && serviceMarker != -1
              ? serviceMarker
              : (afterSec.length < 16000 ? afterSec.length : 16000));

      if (bodyStart >= 0 && endBound > bodyStart) {
        final tableBodyHtml = afterSec.substring(bodyStart, endBound);
        final rowChunks = tableBodyHtml
            .split(RegExp(r'<div\s+class="rTableRow">', caseSensitive: false));
        for (var rIdx = 1; rIdx < rowChunks.length; rIdx++) {
          final chunk = rowChunks[rIdx];
          final cells = RegExp(
            r'<div\s+class="rTableCell[^"]*">([\s\S]*?)</div>',
            caseSensitive: false,
          )
              .allMatches(chunk)
              .map((m) => _stripHtmlAndDecodeEntities(m.group(1) ?? ''))
              .toList();
          if (cells.length < 3) continue;

          final recallDateRaw =
              cells[0].replaceAll(RegExp(r'\s*\|\s*'), ' ').trim();
          final recallType =
              cells[1].replaceAll(RegExp(r'\s*\|\s*'), ' ').trim();
          final idsRaw =
              cells[2].replaceAll(RegExp(r'\s*\|\s*'), ' ').trim();
          final descRaw = cells.length > 3 ? cells[3] : '';

          final idParts = idsRaw.split('/').map((p) => p.trim()).toList();
          final rawNhtsa = idParts.isNotEmpty ? idParts[0] : '';
          final rawOem = idParts.length > 1 ? idParts[1] : '';
          final nhtsaPrefix = normalizeNhtsaPrefix(rawNhtsa);
          final oemRecallNumber = rawOem.isNotEmpty &&
                  rawOem.toUpperCase() != 'N/A' &&
                  rawOem.toUpperCase() != 'NA'
              ? rawOem.toUpperCase().replaceAll(RegExp(r'\s+'), '')
              : '';

          final descParts = descRaw
              .split('|')
              .map((p) => p.trim())
              .where((p) => p.isNotEmpty)
              .toList();
          String statusText = '';
          final descSegments = <String>[];
          for (final seg in descParts) {
            final stMatch =
                RegExp(r'^Status:\s*(.+)$', caseSensitive: false).firstMatch(seg);
            if (stMatch != null) {
              statusText = (stMatch.group(1) ?? '').trim();
            } else {
              descSegments.add(seg);
            }
          }

          openRecalls.add(
            VinOpenRecallRecord(
              recallDate: recallDateRaw,
              recallType: recallType,
              nhtsaPrefix: nhtsaPrefix,
              oemRecallNumber: oemRecallNumber,
              description: descSegments.isNotEmpty
                  ? descSegments.join(' — ')
                  : descRaw,
              statusText: statusText,
            ),
          );
        }
      }
    }

    final resolvedCount = declaredCount ??
        (openRecalls.isNotEmpty ? openRecalls.length : null);
    return VinOpenRecallLookup(
      verified: resolvedCount != null || openRecalls.isNotEmpty,
      openRecallCount: resolvedCount ?? openRecalls.length,
      openRecalls: openRecalls,
    );
  }

  static Future<VinOpenRecallLookup> _fetchVinSpecificOpenRecalls(
    String vin,
  ) async {
    if (kIsWeb) {
      return const VinOpenRecallLookup(verified: false);
    }
    try {
      final sv = Uri.encodeComponent(encodeVinUtf16LeBase64(vin));
      final uri = Uri.parse(
        '$prestonAutoCheckUrl?sv=$sv&ac=$prestonAutoCheckAccount',
      );
      final res = await http
          .get(
            uri,
            headers: const {
              'User-Agent':
                  'Mozilla/5.0 (X11; CrOS x86_64 14541.0.0) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36',
              'Accept': 'text/html,application/xhtml+xml',
            },
          )
          .timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) {
        return const VinOpenRecallLookup(verified: false);
      }
      return parseVinOpenRecallHtml(res.body);
    } catch (_) {
      return const VinOpenRecallLookup(verified: false);
    }
  }

  static int _completionSortRank(String status) {
    switch (status) {
      case 'incomplete':
        return 0;
      case 'incomplete_no_remedy':
        return 1;
      case 'unverified':
        return 2;
      case 'complete':
        return 3;
      case 'not_applicable':
        return 4;
      default:
        return 5;
    }
  }

  static String buildVerdictHeadline({
    required String vehicleTitle,
    required int incompleteCount,
    required int completeCount,
    required bool vinCompletionVerified,
  }) {
    if (incompleteCount == 0 && completeCount == 0) {
      return 'No Open or Historical Recalls Found for $vehicleTitle';
    }
    if (incompleteCount == 0 && completeCount > 0) {
      return '0 Incomplete Recalls • $completeCount Complete Recall${completeCount == 1 ? '' : 's'} for $vehicleTitle';
    }
    if (incompleteCount > 0 && completeCount > 0) {
      return '$incompleteCount Incomplete Recall${incompleteCount == 1 ? '' : 's'} • $completeCount Complete Recall${completeCount == 1 ? '' : 's'} for $vehicleTitle';
    }
    if (vinCompletionVerified) {
      return '$incompleteCount Incomplete Recall${incompleteCount == 1 ? '' : 's'} • 0 Complete for $vehicleTitle';
    }
    return '$incompleteCount Unverified / Incomplete Recall${incompleteCount == 1 ? '' : 's'} for $vehicleTitle';
  }

  /// Reconciles NHTSA model-level recall campaigns with live per-VIN open-recall status
  /// and dealership manual overrides (`'complete'` / `'incomplete'`).
  static ({
    List<NhtsaRecallCampaign> recalls,
    int incompleteCount,
    int completeCount,
    bool vinCompletionVerified,
  }) reconcileVinRecallCompletion({
    required DecodedVinVehicle decoded,
    required List<NhtsaRecallCampaign> recalls,
    required VinOpenRecallLookup vinOpenCheck,
    Map<String, String> manualOverrides = const {},
  }) {
    final openList = vinOpenCheck.openRecalls;
    final matchedOpenIndices = <int>{};

    final reconciled = recalls.map((rec) {
      final recPrefix = normalizeNhtsaPrefix(rec.campaignNumber);
      final recOem = (rec.oemRecallNumber.isNotEmpty
              ? rec.oemRecallNumber
              : extractOemRecallNumber([rec.remedy, rec.summary, rec.notes]))
          .toUpperCase()
          .trim();

      VinOpenRecallRecord? matchedOpen;
      for (var i = 0; i < openList.length; i++) {
        final openItem = openList[i];
        final prefixMatches = recPrefix.isNotEmpty &&
            openItem.nhtsaPrefix.isNotEmpty &&
            recPrefix == openItem.nhtsaPrefix;
        final oemMatches = recOem.isNotEmpty &&
            openItem.oemRecallNumber.isNotEmpty &&
            recOem == openItem.oemRecallNumber;
        if (prefixMatches || oemMatches) {
          matchedOpen = openItem;
          matchedOpenIndices.add(i);
          break;
        }
      }

      final finalOem =
          recOem.isNotEmpty ? recOem : (matchedOpen?.oemRecallNumber ?? '');
      final isOther = RegExp(
        r'other\s+(?:engine|powertrain)',
        caseSensitive: false,
      ).hasMatch(rec.applicability);
      final manualStatus = manualOverrides[rec.campaignNumber];
      final noRemedy = isRemedyUnavailableText([
            rec.remedy,
            matchedOpen?.statusText ?? '',
          ]) ||
          !rec.remedyAvailable;

      if (manualStatus == 'complete') {
        return rec.copyWith(
          oemRecallNumber: finalOem,
          remedyAvailable: !noRemedy,
          completionStatus: 'complete',
          completionSource: 'dealer_override',
          vinStatusNote:
              'Marked Complete by Dealership Service (remedy verified repaired on VIN).',
        );
      }

      if (manualStatus == 'incomplete') {
        return rec.copyWith(
          oemRecallNumber: finalOem,
          remedyAvailable: !noRemedy,
          completionStatus: noRemedy ? 'incomplete_no_remedy' : 'incomplete',
          completionSource: 'dealer_override',
          vinStatusNote: noRemedy
              ? 'Marked Incomplete by Dealership Service • Manufacturer remedy not yet available.'
              : 'Marked Incomplete (Open) by Dealership Service — requires recall repair.',
        );
      }

      if (matchedOpen != null) {
        final openNoRemedy =
            isRemedyUnavailableText([rec.remedy, matchedOpen.statusText]);
        final statusDetail = matchedOpen.statusText.isNotEmpty
            ? ' (${matchedOpen.statusText})'
            : '';
        return rec.copyWith(
          oemRecallNumber: finalOem,
          applicability: 'Confirmed Open on This VIN',
          remedyAvailable: !openNoRemedy,
          completionStatus:
              openNoRemedy ? 'incomplete_no_remedy' : 'incomplete',
          completionSource: 'vin_live_lookup',
          vinStatusNote: openNoRemedy
              ? 'Confirmed INCOMPLETE on this VIN$statusDetail — manufacturer remedy/parts not yet available.'
              : 'Confirmed INCOMPLETE (Open) on this VIN$statusDetail — schedule free dealer recall repair.',
        );
      }

      if (isOther) {
        return rec.copyWith(
          oemRecallNumber: finalOem,
          remedyAvailable: !noRemedy,
          completionStatus: 'not_applicable',
          completionSource: 'powertrain_mismatch',
          vinStatusNote:
              'Applies to a different engine/powertrain configuration than this VIN.',
        );
      }

      if (vinOpenCheck.verified) {
        return rec.copyWith(
          oemRecallNumber: finalOem,
          remedyAvailable: true,
          completionStatus: 'complete',
          completionSource: 'vin_live_lookup',
          vinStatusNote:
              'Confirmed COMPLETE / CLOSED on this VIN (0 open recall status on VIN record).',
        );
      }

      return rec.copyWith(
        oemRecallNumber: finalOem,
        remedyAvailable: !noRemedy,
        completionStatus: 'unverified',
        completionSource: 'model_lookup_only',
        vinStatusNote:
            'VIN-specific completion status could not be verified automatically — confirm repair history in OEM warranty/OASIS or on www.nhtsa.gov/recalls.',
      );
    }).toList();

    for (var i = 0; i < openList.length; i++) {
      if (matchedOpenIndices.contains(i)) continue;
      final openItem = openList[i];
      final campaignNumber = openItem.nhtsaPrefix.isNotEmpty
          ? '${openItem.nhtsaPrefix}000'
          : (openItem.oemRecallNumber.isNotEmpty
              ? 'OEM-${openItem.oemRecallNumber}'
              : 'OPEN-${i + 1}');
      final manualStatus = manualOverrides[campaignNumber];
      final dates = _parseUsMonthDayYearDate(openItem.recallDate);
      final openNoRemedy = isRemedyUnavailableText([
        openItem.statusText,
        openItem.description,
      ]);
      final completionStatus = manualStatus == 'complete'
          ? 'complete'
          : (openNoRemedy ? 'incomplete_no_remedy' : 'incomplete');

      reconciled.add(
        NhtsaRecallCampaign(
          campaignNumber: campaignNumber,
          oemRecallNumber: openItem.oemRecallNumber,
          manufacturer: decoded.manufacturer.isNotEmpty
              ? decoded.manufacturer
              : (decoded.make.isNotEmpty ? decoded.make : 'Manufacturer'),
          component: openItem.description.isNotEmpty
              ? openItem.description
              : '${openItem.recallType.isNotEmpty ? openItem.recallType : 'Safety'} Recall Campaign',
          reportDate: dates.displayDate,
          reportIsoDate: dates.isoDate,
          summary: openItem.description.isNotEmpty
              ? openItem.description
              : 'Open manufacturer recall reported for this specific VIN.',
          remedy: openItem.statusText.isNotEmpty
              ? 'Manufacturer Recall Status: ${openItem.statusText}. Contact an authorized ${decoded.make.isNotEmpty ? decoded.make : 'OEM'} service department for free recall remedy.'
              : 'Contact an authorized ${decoded.make.isNotEmpty ? decoded.make : 'OEM'} service department for free recall remedy.',
          nhtsaModelMatched: decoded.model,
          applicability: 'Confirmed Open on This VIN',
          geminiNote:
              'Directly reported as an active open recall on VIN ${decoded.vin}.',
          completionStatus: completionStatus,
          completionSource:
              manualStatus != null ? 'dealer_override' : 'vin_live_lookup',
          remedyAvailable: !openNoRemedy,
          vinStatusNote: completionStatus == 'complete'
              ? 'Marked Complete by Dealership Service (remedy verified repaired on VIN).'
              : (openNoRemedy
                  ? 'Confirmed INCOMPLETE on this VIN (${openItem.statusText.isNotEmpty ? openItem.statusText : 'Remedy Not Available'}).'
                  : 'Confirmed INCOMPLETE (Open) on this VIN${openItem.statusText.isNotEmpty ? ' (${openItem.statusText})' : ''}.'),
        ),
      );
    }

    reconciled.sort((a, b) {
      final rankDiff = _completionSortRank(a.completionStatus) -
          _completionSortRank(b.completionStatus);
      if (rankDiff != 0) return rankDiff;
      return b.reportIsoDate.compareTo(a.reportIsoDate);
    });

    final incompleteCount = reconciled.where((r) => r.isIncomplete).length;
    final completeCount = reconciled.where((r) => r.isComplete).length;

    return (
      recalls: reconciled,
      incompleteCount: incompleteCount,
      completeCount: completeCount,
      vinCompletionVerified: vinOpenCheck.verified,
    );
  }

  /// Applies a manual `'complete'` or `'incomplete'` override to an existing result in memory.
  static VinRecallCheckResult applyManualOverridesToResult(
    VinRecallCheckResult current,
    Map<String, String> overridesForVin,
  ) {
    final updatedRecalls = current.recalls.map((rec) {
      final manualStatus = overridesForVin[rec.campaignNumber];
      if (manualStatus == null) return rec;
      final noRemedy =
          isRemedyUnavailableText([rec.remedy]) && !rec.remedyAvailable;
      if (manualStatus == 'complete') {
        return rec.copyWith(
          completionStatus: 'complete',
          completionSource: 'dealer_override',
          vinStatusNote:
              'Marked Complete by Dealership Service (remedy verified repaired on VIN).',
        );
      }
      return rec.copyWith(
        completionStatus: noRemedy ? 'incomplete_no_remedy' : 'incomplete',
        completionSource: 'dealer_override',
        vinStatusNote: noRemedy
            ? 'Marked Incomplete by Dealership Service • Manufacturer remedy not yet available.'
            : 'Marked Incomplete (Open) by Dealership Service — requires recall repair.',
      );
    }).toList()
      ..sort((a, b) {
        final rankDiff = _completionSortRank(a.completionStatus) -
            _completionSortRank(b.completionStatus);
        if (rankDiff != 0) return rankDiff;
        return b.reportIsoDate.compareTo(a.reportIsoDate);
      });

    final incompleteCount = updatedRecalls.where((r) => r.isIncomplete).length;
    final completeCount = updatedRecalls.where((r) => r.isComplete).length;
    final openRecalls = updatedRecalls.where((r) => r.isIncomplete).toList();

    return VinRecallCheckResult(
      id: current.id,
      vin: current.vin,
      nhtsaUrl: current.nhtsaUrl,
      nhtsaSiteReachable: current.nhtsaSiteReachable,
      vinCompletionVerified: current.vinCompletionVerified,
      checkedAt: DateTime.now().toUtc().toIso8601String(),
      agentMode: current.agentMode,
      vehicleTitle: current.vehicleTitle,
      vehicle: current.vehicle,
      queriedModels: current.queriedModels,
      hasRecalls: incompleteCount > 0,
      recallCount: incompleteCount,
      incompleteCount: incompleteCount,
      completeCount: completeCount,
      totalModelRecalls: updatedRecalls.length,
      parkItUrgent: openRecalls.any((r) => r.parkIt),
      parkOutsideWarning: openRecalls.any((r) => r.parkOutSide),
      verdictHeadline: buildVerdictHeadline(
        vehicleTitle: current.vehicleTitle,
        incompleteCount: incompleteCount,
        completeCount: completeCount,
        vinCompletionVerified: current.vinCompletionVerified,
      ),
      geminiSummary: current.geminiSummary,
      recommendedAction: current.recommendedAction,
      recalls: updatedRecalls,
    );
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

  /// Matches a decoded vPIC model against NHTSA's recall-specific model taxonomy.
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

  static Future<({DecodedVinVehicle vehicle, String errorText})>
      _decodeVinViaVpic(String vin) async {
    final uri = Uri.parse(
      '$vpicBase/DecodeVinValues/${Uri.encodeComponent(vin)}?format=json',
    );
    final res = await http
        .get(
          uri,
          headers: const {
            'Accept': 'application/json',
            'User-Agent': 'PrestonGuestScout/1.11 (NHTSA VIN Recall Checker)',
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
    final dispStr =
        dispDouble != null ? '${dispDouble.toStringAsFixed(1)}L' : '';
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
                  'User-Agent': 'PrestonGuestScout/1.11',
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
          final uri =
              Uri.parse('$nhtsaApiBase/recalls/recallsByVehicle').replace(
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
                  'User-Agent': 'PrestonGuestScout/1.11',
                },
              )
              .timeout(const Duration(seconds: 15));
          if (r.statusCode != 200) return;
          final j = jsonDecode(r.body) as Map<String, dynamic>;
          final items =
              (j['results'] ?? j['Results']) as List<dynamic>? ?? const [];
          for (final rawItem in items) {
            if (rawItem is! Map) continue;
            final item = Map<String, dynamic>.from(rawItem);
            final campaign =
                (item['NHTSACampaignNumber']?.toString() ?? '').trim();
            if (campaign.isEmpty || byCampaign.containsKey(campaign)) continue;
            final dates = parseNhtsaReportDate(
              item['ReportReceivedDate']?.toString() ?? '',
            );
            final summary = (item['Summary']?.toString() ?? '')
                .replaceAll(RegExp(r'\s+'), ' ')
                .trim();
            final consequence = (item['Consequence']?.toString() ?? '')
                .replaceAll(RegExp(r'\s+'), ' ')
                .trim();
            final remedy = (item['Remedy']?.toString() ?? '')
                .replaceAll(RegExp(r'\s+'), ' ')
                .trim();
            final notes = (item['Notes']?.toString() ?? '')
                .replaceAll(RegExp(r'\s+'), ' ')
                .trim();
            final oemCode = extractOemRecallNumber([remedy, summary, notes]);

            byCampaign[campaign] = NhtsaRecallCampaign(
              campaignNumber: campaign,
              oemRecallNumber: oemCode,
              manufacturer: (item['Manufacturer']?.toString() ??
                      decoded.manufacturer)
                  .trim(),
              component:
                  (item['Component']?.toString() ?? 'Vehicle Safety System')
                      .trim(),
              reportDate: dates.displayDate,
              reportIsoDate: dates.isoDate,
              summary: summary,
              consequence: consequence,
              remedy: remedy,
              notes: notes,
              parkIt: item['parkIt'] == true,
              parkOutSide: item['parkOutSide'] == true,
              overTheAirUpdate: item['overTheAirUpdate'] == true,
              nhtsaModelMatched:
                  (item['Model']?.toString() ?? modelName).trim(),
              applicability: 'Matches Decoded Vehicle',
              completionStatus: 'unverified',
              completionSource: 'model_lookup_only',
              remedyAvailable: !isRemedyUnavailableText([remedy]),
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
        return rec.copyWith(
          applicability: 'Other Engine / Equipment Variant',
          geminiNote:
              'Campaign specifically references ${mentionedDisps.join('/')}L engine; this VIN decoded with ${vDisp}L.',
        );
      }

      if (RegExp(r'\bhybrid\b', caseSensitive: false).hasMatch(text) &&
          vFuel.isNotEmpty &&
          !vFuel.contains('hybrid') &&
          !vFuel.contains('electric')) {
        return rec.copyWith(
          applicability: 'Other Powertrain Variant',
          geminiNote:
              'Campaign targets Hybrid powertrain; this VIN decoded as ${decoded.fuelType}.',
        );
      }

      return rec.copyWith(
        applicability: 'Matches Decoded Vehicle',
        geminiNote:
            "Matches this VIN's decoded model year, make, model, and powertrain.",
      );
    }).toList();
  }

  /// Checks `www.nhtsa.gov/recalls`, official NHTSA vPIC/Recalls APIs, and live VIN-specific
  /// recall completion status, then analyzes Complete vs. Incomplete recalls with Gemini.
  static Future<VinRecallCheckResult> checkVinRecalls({
    required String rawVin,
    String geminiApiKey = '',
    String geminiModel = 'gemini-2.5-flash',
    Map<String, String> manualOverrides = const {},
  }) async {
    final validation = validateAndNormalizeVin(rawVin);
    if (!validation.valid) {
      throw Exception(validation.error);
    }

    final vin = validation.vin;
    if (mockCheckHandler != null) {
      final mocked = await mockCheckHandler!(vin);
      if (manualOverrides.isNotEmpty) {
        return applyManualOverridesToResult(mocked, manualOverrides);
      }
      return mocked;
    }

    final nhtsaUrl = '$nhtsaRecallsWebUrl?vin=${Uri.encodeComponent(vin)}';

    late ({DecodedVinVehicle vehicle, String errorText}) decodedWrap;
    late VinOpenRecallLookup vinOpenCheck;
    await Future.wait([
      () async {
        decodedWrap = await _decodeVinViaVpic(vin);
      }(),
      () async {
        vinOpenCheck = await _fetchVinSpecificOpenRecalls(vin);
      }(),
    ]);

    final vehicle = decodedWrap.vehicle;
    final errorText = decodedWrap.errorText;

    if (vehicle.make.isEmpty || vehicle.year == null) {
      throw Exception(
        'Unable to decode a valid vehicle from VIN "$vin" via NHTSA vPIC (${errorText.isNotEmpty ? errorText : 'unrecognized WMI/model year'}). Double-check all 17 characters.',
      );
    }

    final fetched = await _fetchNhtsaRecallsForVehicle(vehicle);
    final annotated = _annotateDeterministically(vehicle, fetched.recalls);
    var reconciled = reconcileVinRecallCompletion(
      decoded: vehicle,
      recalls: annotated,
      vinOpenCheck: vinOpenCheck,
      manualOverrides: manualOverrides,
    );

    final vehicleTitle = [
      if (vehicle.year != null) '${vehicle.year}',
      vehicle.make,
      vehicle.model,
      vehicle.trim,
    ].where((s) => s.trim().isNotEmpty).join(' ');

    ({String summary, String action}) buildFallbackTexts(
      List<NhtsaRecallCampaign> list,
      int incCount,
      int compCount,
      bool verified,
    ) {
      final openRecs = list.where((r) => r.isIncomplete).toList();
      final openParkIt = openRecs.any((r) => r.parkIt);
      final openParkOut = openRecs.any((r) => r.parkOutSide);
      final noRemedyCount =
          openRecs.where((r) => r.isRemedyUnavailable).length;

      String summary;
      if (incCount == 0 && compCount == 0) {
        summary =
            'Checked NHTSA ($nhtsaRecallsWebUrl) and VIN-specific recall status for VIN $vin ($vehicleTitle): 0 incomplete (open) recalls and 0 completed recall campaigns are on file.';
      } else if (incCount == 0 && compCount > 0) {
        summary =
            'Good news for VIN $vin ($vehicleTitle): 0 incomplete (open) recalls remain on this vehicle, and $compCount historical NHTSA recall campaign${compCount == 1 ? ' is' : 's are'} confirmed COMPLETE / closed on this VIN.';
      } else if (verified) {
        summary =
            'VIN $vin ($vehicleTitle) has $incCount INCOMPLETE (open) recall${incCount == 1 ? '' : 's'}${noRemedyCount > 0 ? ' ($noRemedyCount awaiting manufacturer remedy availability)' : ''} and $compCount COMPLETE (closed) recall${compCount == 1 ? '' : 's'} verified against NHTSA ($nhtsaRecallsWebUrl) and live VIN recall records.';
      } else {
        summary =
            'Found $incCount matching NHTSA safety recall campaign${incCount == 1 ? '' : 's'} on file for VIN $vin ($vehicleTitle) via $nhtsaRecallsWebUrl. Verify per-VIN repair completion in ${vehicle.make} warranty history or mark completed campaigns below.';
      }

      String action;
      if (incCount == 0) {
        action = compCount > 0
            ? 'All $compCount applicable NHTSA recall campaign${compCount == 1 ? ' has' : 's have'} been completed/closed for VIN $vin. Ready for guest delivery.'
            : 'No open safety recalls require service action on this VIN.';
      } else if (openParkIt) {
        action =
            'URGENT — DO NOT DRIVE warning on an INCOMPLETE recall! Hold vehicle immediately and schedule authorized dealer recall repair before driving or delivery.';
      } else if (openParkOut) {
        action =
            'IMPORTANT — Park Outside advisory on an INCOMPLETE recall. Park away from structures and schedule authorized dealer recall repair immediately.';
      } else if (noRemedyCount == incCount) {
        action =
            'Open recall remedy is not yet available from ${vehicle.make}. Advise the guest of the open recall notice and monitor www.nhtsa.gov/recalls for parts release.';
      } else {
        action =
            'Schedule free recall repair with ${vehicle.make} Service for the $incCount INCOMPLETE recall${incCount == 1 ? '' : 's'} before delivery, then tap "Mark Complete" once repaired.';
      }
      return (summary: summary, action: action);
    }

    final cleanKey = geminiApiKey.trim();
    final cleanModel =
        geminiModel.trim().isNotEmpty ? geminiModel.trim() : 'gemini-2.5-flash';

    String agentMode = reconciled.vinCompletionVerified
        ? 'nhtsa+vin-live-status'
        : 'nhtsa-smart-analyzer';
    final fb0 = buildFallbackTexts(
      reconciled.recalls,
      reconciled.incompleteCount,
      reconciled.completeCount,
      reconciled.vinCompletionVerified,
    );
    String geminiSummary = fb0.summary;
    String recommendedAction = fb0.action;

    if (cleanKey.isNotEmpty) {
      final promptPayload = {
        'referenceWebsite': nhtsaUrl,
        'vin': vin,
        'decodedVehicleFromNhtsaVpic': vehicle.toJson(),
        'vinCompletionVerified': reconciled.vinCompletionVerified,
        'incompleteRecallCount': reconciled.incompleteCount,
        'completeRecallCount': reconciled.completeCount,
        'recallCampaignsOnFile': reconciled.recalls
            .map(
              (r) => {
                'campaignNumber': r.campaignNumber,
                'oemRecallNumber': r.oemRecallNumber,
                'completionStatus': r.completionStatus,
                'remedyAvailable': r.remedyAvailable,
                'reportDate': r.reportDate,
                'component': r.component,
                'parkItDoNotDrive': r.parkIt,
                'parkOutsideWarning': r.parkOutSide,
                'summary': r.summary,
                'remedy': r.remedy,
                'initialSpecCheck': r.applicability,
              },
            )
            .toList(),
      };

      const systemPrompt =
          'You are the Preston Automotive Group Gemini NHTSA Recall Inspector. '
          'Inspect a specific 17-character VIN against www.nhtsa.gov/recalls, official NHTSA vPIC + Recalls records, and live per-VIN recall completion data, clearly differentiating INCOMPLETE (open/unrepaired) recalls from COMPLETE (closed/repaired) recalls. '
          'Explicitly mention both the INCOMPLETE (open) recall count and the COMPLETE (closed) recall count in geminiSummary. '
          'Classify each campaign\'s applicability as "Confirmed Open on This VIN", "Matches Decoded Vehicle", or "Other Engine / Equipment Variant" with a concise 1-sentence geminiNote, plus recommendedAction.';

      final endpoint = Uri.parse(
        'https://generativelanguage.googleapis.com/v1beta/models/${Uri.encodeComponent(cleanModel)}:generateContent?key=${Uri.encodeComponent(cleanKey)}',
      );

      Map<String, dynamic>? parsed;
      bool usedGrounded = false;

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
                            'Check $nhtsaUrl and analyze Complete vs. Incomplete recall status for VIN $vin. Return ONLY valid JSON with keys: geminiSummary (string), recommendedAction (string), campaignAssessments (array of {campaignNumber, applicability, geminiNote}).\n\nData:\n${jsonEncode(promptPayload)}',
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

        final enrichedAnnotated = annotated.map((r) {
          final a = assessMap[r.campaignNumber];
          if (a == null) return r;
          return r.copyWith(
            applicability:
                (a['applicability']?.toString() ?? r.applicability).trim(),
            geminiNote: (a['geminiNote']?.toString() ?? r.geminiNote).trim(),
          );
        }).toList();

        reconciled = reconcileVinRecallCompletion(
          decoded: vehicle,
          recalls: enrichedAnnotated,
          vinOpenCheck: vinOpenCheck,
          manualOverrides: manualOverrides,
        );

        final finalWithNotes = reconciled.recalls.map((r) {
          final a = assessMap[r.campaignNumber];
          final gn = (a?['geminiNote']?.toString() ?? '').trim();
          if (gn.isEmpty) return r;
          return r.copyWith(geminiNote: gn);
        }).toList();

        reconciled = (
          recalls: finalWithNotes,
          incompleteCount: reconciled.incompleteCount,
          completeCount: reconciled.completeCount,
          vinCompletionVerified: reconciled.vinCompletionVerified,
        );

        agentMode = usedGrounded
            ? 'gemini-url-context ($cleanModel)'
            : 'gemini ($cleanModel)';

        final fb1 = buildFallbackTexts(
          reconciled.recalls,
          reconciled.incompleteCount,
          reconciled.completeCount,
          reconciled.vinCompletionVerified,
        );
        final rawSummary = (parsed['geminiSummary']?.toString() ?? '').trim();
        geminiSummary = rawSummary.isNotEmpty ? rawSummary : fb1.summary;
        final rawAction =
            (parsed['recommendedAction']?.toString() ?? '').trim();
        recommendedAction = rawAction.isNotEmpty ? rawAction : fb1.action;
      }
    }

    final openRecallsOnly =
        reconciled.recalls.where((r) => r.isIncomplete).toList();
    final checkedAt = DateTime.now().toUtc().toIso8601String();

    return VinRecallCheckResult(
      id: 'recall-${DateTime.now().microsecondsSinceEpoch}',
      vin: vin,
      nhtsaUrl: nhtsaUrl,
      nhtsaSiteReachable: fetched.nhtsaSiteReachable,
      vinCompletionVerified: reconciled.vinCompletionVerified,
      checkedAt: checkedAt,
      agentMode: agentMode,
      vehicleTitle: vehicleTitle,
      vehicle: vehicle,
      queriedModels: fetched.queriedModels,
      hasRecalls: reconciled.incompleteCount > 0,
      recallCount: reconciled.incompleteCount,
      incompleteCount: reconciled.incompleteCount,
      completeCount: reconciled.completeCount,
      totalModelRecalls: reconciled.recalls.length,
      parkItUrgent: openRecallsOnly.any((r) => r.parkIt),
      parkOutsideWarning: openRecallsOnly.any((r) => r.parkOutSide),
      verdictHeadline: buildVerdictHeadline(
        vehicleTitle: vehicleTitle,
        incompleteCount: reconciled.incompleteCount,
        completeCount: reconciled.completeCount,
        vinCompletionVerified: reconciled.vinCompletionVerified,
      ),
      geminiSummary: geminiSummary,
      recommendedAction: recommendedAction,
      recalls: reconciled.recalls,
    );
  }
}

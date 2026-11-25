import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../models/models.dart';
import 'document_picker_service.dart';
import 'natural_language_parser.dart';

class DocumentEquivalentService {
  static const String _vpicBase = 'https://vpic.nhtsa.dot.gov/api/vehicles';

  static const Set<String> _geminiInlineMimeTypes = {
    'application/pdf',
    'image/png',
    'image/jpeg',
    'image/jpg',
    'image/webp',
    'image/heic',
    'image/heif',
    'image/gif',
    'text/plain',
    'text/csv',
    'text/html',
  };

  @visibleForTesting
  static Future<DocumentEquivalentSearchResult> Function({
    required PickedDocumentFile document,
    String extraNotes,
  })? mockSearchHandler;

  static bool get hasMockSearchHandler => mockSearchHandler != null;

  static String inferMimeType(String fileName, String rawMimeType) {
    final cleanMime = rawMimeType.trim().toLowerCase();
    if (cleanMime.isNotEmpty && cleanMime != 'application/octet-stream') {
      return cleanMime == 'image/jpg' ? 'image/jpeg' : cleanMime;
    }
    final dotIdx = fileName.lastIndexOf('.');
    final ext =
        dotIdx >= 0 ? fileName.substring(dotIdx + 1).toLowerCase() : '';
    switch (ext) {
      case 'pdf':
        return 'application/pdf';
      case 'png':
        return 'image/png';
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'webp':
        return 'image/webp';
      case 'heic':
        return 'image/heic';
      case 'gif':
        return 'image/gif';
      case 'csv':
        return 'text/csv';
      case 'html':
      case 'htm':
        return 'text/html';
      case 'docx':
        return 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
      case 'txt':
      case 'md':
      case 'tsv':
      case 'json':
      case 'xml':
        return 'text/plain';
      default:
        return cleanMime.isNotEmpty ? cleanMime : 'application/octet-stream';
    }
  }

  static String extractReadableTextFromBytes(
    Uint8List bytes,
    String fileName,
    String mimeType,
  ) {
    if (bytes.isEmpty) return '';
    final dotIdx = fileName.lastIndexOf('.');
    final ext =
        dotIdx >= 0 ? fileName.substring(dotIdx + 1).toLowerCase() : '';

    if (mimeType.startsWith('text/') ||
        const ['txt', 'csv', 'tsv', 'md', 'json', 'html', 'htm', 'xml']
            .contains(ext)) {
      final raw = utf8.decode(bytes, allowMalformed: true);
      final cleaned = raw
          .replaceAll(
            RegExp(r'<script[\s\S]*?</script>', caseSensitive: false),
            ' ',
          )
          .replaceAll(
            RegExp(r'<style[\s\S]*?</style>', caseSensitive: false),
            ' ',
          )
          .replaceAll(RegExp(r'<[^>]+>'), ' ')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      return cleaned.length > 14000 ? cleaned.substring(0, 14000) : cleaned;
    }

    if (mimeType == 'application/pdf' || ext == 'pdf') {
      final latin = latin1.decode(bytes, allowInvalid: true);
      final runs = RegExp(r'\(([^\x00-\x1f\\()]{3,120})\)')
          .allMatches(latin)
          .map((m) => (m.group(1) ?? '').trim())
          .where((s) => RegExp(r'[A-Za-z0-9]').hasMatch(s))
          .take(400)
          .join(' ');
      return runs.length > 10000 ? runs.substring(0, 10000) : runs;
    }

    return '';
  }

  static String extractFirstValidVinFromText(String text) {
    final matches =
        RegExp(r'\b[A-HJ-NPR-Z0-9]{17}\b').allMatches(text.toUpperCase());
    for (final m in matches) {
      final cand = m.group(0) ?? '';
      final digitCount = RegExp(r'\d').allMatches(cand).length;
      if (digitCount >= 4) return cand;
    }
    return '';
  }

  static Future<Map<String, dynamic>?> _decodeVinHint(String vin) async {
    if (vin.isEmpty) return null;
    try {
      final res = await http
          .get(
            Uri.parse(
              '$_vpicBase/DecodeVinValues/${Uri.encodeComponent(vin)}?format=json',
            ),
            headers: const {'Accept': 'application/json'},
          )
          .timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) return null;
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final results = data['Results'] as List<dynamic>? ?? const [];
      if (results.isEmpty || results.first is! Map) return null;
      final row = Map<String, dynamic>.from(results.first as Map);
      final make = (row['Make']?.toString() ?? '').trim();
      final yr = int.tryParse(row['ModelYear']?.toString() ?? '');
      if (make.isEmpty || yr == null) return null;
      final disp = double.tryParse(row['DisplacementL']?.toString() ?? '');
      return <String, dynamic>{
        'vin': vin,
        'year': yr,
        'make': make,
        'model': (row['Model']?.toString() ?? '').trim(),
        'trim': (row['Trim'] ?? row['Series'] ?? '').toString().trim(),
        'bodyClass': (row['BodyClass']?.toString() ?? '').trim(),
        'driveType': (row['DriveType']?.toString() ?? '').trim(),
        'doors': (row['Doors']?.toString() ?? '').trim(),
        'fuelType': [
          row['FuelTypePrimary']?.toString() ?? '',
          row['ElectrificationLevel']?.toString() ?? '',
        ].map((s) => s.trim()).where((s) => s.isNotEmpty).join(' • '),
        'displacementL': disp != null ? '${disp.toStringAsFixed(1)}L' : '',
      };
    } catch (_) {
      return null;
    }
  }

  static String classifyBodyCategory(String text) {
    final s = text.toLowerCase();
    if (RegExp(
      r'\b(?:f-?150|f-?250|f-?350|f-?450|super\s*duty|ranger|maverick|silverado|sierra|colorado|canyon|ram\s*1500|ram\s*2500|ram\s*3500|tundra|tacoma|frontier|titan|santa\s*cruz|gladiator|ridgeline|pickup|truck|crew\s*cab|supercab|regular\s*cab)\b',
      caseSensitive: false,
    ).hasMatch(s)) {
      return 'Pickup Truck';
    }
    if (RegExp(
      r'\b(?:transit|savana|express|sprinter|promaster|cargo\s*van|passenger\s*van|minivan|odyssey|sienna|pacifica|carnival)\b',
      caseSensitive: false,
    ).hasMatch(s)) {
      return 'Van / Minivan';
    }
    if (RegExp(
      r'\b(?:expedition|navigator|tahoe|suburban|yukon|escalade|wagoneer|sequoia|armada|qx80)\b',
      caseSensitive: false,
    ).hasMatch(s)) {
      return 'Full-Size 3-Row SUV';
    }
    if (RegExp(
      r'\b(?:explorer|aviator|palisade|telluride|cx-?90|cx-?9|highlander|grand\s*highlander|pilot|pathfinder|traverse|enclave|acadia|atlas|ascent|mdx|3rd[\s\-]*row|three[\s\-]*row|7[\s\-]*passenger|8[\s\-]*passenger)\b',
      caseSensitive: false,
    ).hasMatch(s)) {
      return '3-Row SUV';
    }
    if (RegExp(
      r'\b(?:nautilus|corsair|gv70|gv80|rx\s*350|nx\s*350|x3|x5|q5|q7|glc|gle|xt5|xt6|xc60|xc90|rdx|luxury\s*suv)\b',
      caseSensitive: false,
    ).hasMatch(s)) {
      return 'Luxury SUV';
    }
    if (RegExp(
      r'\b(?:bronco(?!\s*sport)|wrangler|4runner|land\s*cruiser|defender)\b',
      caseSensitive: false,
    ).hasMatch(s)) {
      return 'Off-Road SUV';
    }
    if (RegExp(
      r'\b(?:santa\s*fe|cx-?70|murano|edge|blazer|passport|outback|grand\s*cherokee|crown\s*signia|venza|midsize\s*suv)\b',
      caseSensitive: false,
    ).hasMatch(s)) {
      return 'Midsize SUV';
    }
    if (RegExp(
      r'\b(?:escape|bronco\s*sport|tucson|kona|venue|cx-?50|cx-?5|cx-?30|rogue|kicks|equinox|trailblazer|trax|rav4|cr-?v|hr-?v|forester|crosstrek|sportage|seltos|compass|cherokee|terrain|encore|compact\s*suv|suv|crossover|sport\s*utility)\b',
      caseSensitive: false,
    ).hasMatch(s)) {
      return 'Compact / Midsize SUV';
    }
    if (RegExp(
      r'\b(?:mustang(?!\s*mach)|corvette|camaro|challenger|miata|mx-?5|supra|brz|gr86|coupe|convertible)\b',
      caseSensitive: false,
    ).hasMatch(s)) {
      return 'Sports Car / Coupe';
    }
    if (RegExp(
      r'\b(?:elantra|sonata|mazda3|altima|sentra|versa|malibu|camry|corolla|accord|civic|prius|jetta|k4|k5|sedan|hatchback)\b',
      caseSensitive: false,
    ).hasMatch(s)) {
      return 'Sedan / Hatchback';
    }
    return 'SUV / Crossover';
  }

  static String _classifyTrimTier(String trim) {
    final s = trim.toLowerCase();
    if (s.isEmpty) return '';
    if (RegExp(
      r'\b(?:black\s*label|platinum|king\s*ranch|limited|calligraphy|signature|turbo\s*s|turbo\s*premium\s*plus|high\s*country|premier|denali|reserve|summit|overland|autobiography|touring|prestige)\b',
    ).hasMatch(s)) {
      return 'luxury';
    }
    if (RegExp(
      r'\b(?:lariat|st-?line|st|xlt|sel|preferred|lt|rst|z71|tremor|badlands|outer\s*banks|big\s*bend|rock\s*creek|carbon\s*edition|n\s*line|sv|ex-?l|ex|sport)\b',
    ).hasMatch(s)) {
      return 'mid';
    }
    if (RegExp(r'\b(?:xl|se|s|base|wt|work\s*truck|ls|lx|le|select)\b')
        .hasMatch(s)) {
      return 'entry';
    }
    return 'mid';
  }

  static List<Map<String, String>> _defaultCrossBrandEquivalents(
    String make,
    String model,
    String bodyCategory,
    String powertrain,
  ) {
    final key = '$make $model'.toLowerCase();
    final isHyb =
        RegExp(r'hybrid|hev|phev', caseSensitive: false).hasMatch(powertrain);
    if (RegExp(r'highlander|pilot|telluride|atlas|ascent|traverse|mdx')
            .hasMatch(key) ||
        bodyCategory == '3-Row SUV') {
      return [
        {'make': 'Ford', 'model': 'Explorer'},
        {'make': 'Hyundai', 'model': isHyb ? 'Santa Fe' : 'Palisade'},
        {'make': 'Mazda', 'model': 'CX-90'},
        {'make': 'Lincoln', 'model': 'Aviator'},
        {'make': 'Chevrolet', 'model': 'Traverse'},
        {'make': 'Nissan', 'model': 'Pathfinder'},
      ];
    }
    if (RegExp(r'nautilus|rx|x5|gle|q7|gv80|xc90|mdx|xt5|xt6').hasMatch(key) ||
        bodyCategory == 'Luxury SUV') {
      return [
        {'make': 'Lincoln', 'model': 'Nautilus'},
        {'make': 'Lincoln', 'model': 'Aviator'},
        {'make': 'Lincoln', 'model': 'Corsair'},
        {'make': 'Mazda', 'model': 'CX-70'},
        {'make': 'Mazda', 'model': 'CX-90'},
        {'make': 'Hyundai', 'model': 'Palisade'},
      ];
    }
    if (RegExp(r'rav4|cr-?v|forester|sportage|rogue|tucson|cx-?5|equinox|escape')
        .hasMatch(key)) {
      return [
        {'make': 'Mazda', 'model': 'CX-50'},
        {'make': 'Mazda', 'model': 'CX-5'},
        {'make': 'Hyundai', 'model': 'Tucson'},
        {'make': 'Ford', 'model': 'Escape'},
        {'make': 'Ford', 'model': 'Bronco Sport'},
        {'make': 'Chevrolet', 'model': 'Equinox'},
        {'make': 'Nissan', 'model': 'Rogue'},
      ];
    }
    if (bodyCategory == 'Pickup Truck') {
      if (RegExp(r'2500|3500|f-?250|f-?350|hd').hasMatch(key)) {
        return [
          {'make': 'Ford', 'model': 'F-250'},
          {'make': 'Ford', 'model': 'F-350'},
          {'make': 'Chevrolet', 'model': 'Silverado 2500HD'},
        ];
      }
      if (RegExp(r'tacoma|colorado|canyon|frontier|ranger|maverick')
          .hasMatch(key)) {
        return [
          {'make': 'Ford', 'model': 'Ranger'},
          {'make': 'Ford', 'model': 'Maverick'},
          {'make': 'Chevrolet', 'model': 'Colorado'},
          {'make': 'Nissan', 'model': 'Frontier'},
        ];
      }
      return [
        {'make': 'Ford', 'model': 'F-150'},
        {'make': 'Chevrolet', 'model': 'Silverado 1500'},
        {'make': 'Ram', 'model': '1500'},
        {'make': 'GMC', 'model': 'Sierra 1500'},
      ];
    }
    if (bodyCategory == 'Full-Size 3-Row SUV') {
      return [
        {'make': 'Ford', 'model': 'Expedition'},
        {'make': 'Lincoln', 'model': 'Navigator'},
        {'make': 'Chevrolet', 'model': 'Tahoe'},
        {'make': 'Chevrolet', 'model': 'Suburban'},
      ];
    }
    if (bodyCategory == 'Sedan / Hatchback') {
      return [
        {'make': 'Hyundai', 'model': 'Sonata'},
        {'make': 'Hyundai', 'model': 'Elantra'},
        {'make': 'Mazda', 'model': 'Mazda3'},
        {'make': 'Nissan', 'model': 'Altima'},
        {'make': 'Nissan', 'model': 'Sentra'},
      ];
    }
    return const [];
  }

  static ({
    String documentSummary,
    String extractedGuestName,
    DocumentExtractedVehicleProfile profile,
  }) buildFallbackProfile({
    required String fileName,
    required String readableText,
    Map<String, dynamic>? vinDecoded,
    String extraNotes = '',
  }) {
    final combinedText = [readableText, extraNotes]
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .join('\n');

    final nlParsed = NaturalLanguageVehicleParser.parseCriteriaMap({
      'make': vinDecoded?['make']?.toString() ?? '',
      'model': vinDecoded?['model']?.toString() ?? '',
      'trim': vinDecoded?['trim']?.toString() ?? '',
      'doors': vinDecoded?['doors']?.toString() ?? '',
      'minYear': vinDecoded?['year'],
      'maxYear': vinDecoded?['year'],
      'notes': combinedText,
    });

    final make = (nlParsed['make']?.toString() ??
            vinDecoded?['make']?.toString() ??
            '')
        .trim();
    final model = (nlParsed['model']?.toString() ??
            vinDecoded?['model']?.toString() ??
            '')
        .trim();
    final trim = (nlParsed['trim']?.toString() ??
            vinDecoded?['trim']?.toString() ??
            '')
        .trim();
    final year = (vinDecoded?['year'] as num?)?.toInt() ??
        (nlParsed['minYear'] as num?)?.toInt() ??
        (nlParsed['maxYear'] as num?)?.toInt();

    final powertrainText =
        '$combinedText ${vinDecoded?['fuelType'] ?? ''} ${nlParsed['engineSpec'] ?? ''}';
    String powertrain = 'Any';
    if (RegExp(r'plug[\s\-]*in|\bphev\b', caseSensitive: false)
        .hasMatch(powertrainText)) {
      powertrain = 'Plug-In Hybrid';
    } else if (RegExp(r'\bhybrid\b|\bfhev\b|\bhev\b', caseSensitive: false)
        .hasMatch(powertrainText)) {
      powertrain = 'Hybrid';
    } else if (RegExp(
      r'\belectric\b|\bbev\b|\blightning\b|\bmach-?e\b|\bioniq\b',
      caseSensitive: false,
    ).hasMatch(powertrainText)) {
      powertrain = 'Electric';
    } else if (RegExp(r'\bdiesel\b|power\s*stroke|duramax', caseSensitive: false)
        .hasMatch(powertrainText)) {
      powertrain = 'Diesel';
    } else if (RegExp(r'\bv8\b|5\.0l|7\.3l|6\.2l', caseSensitive: false)
        .hasMatch(powertrainText)) {
      powertrain = 'V8';
    } else if (RegExp(r'ecoboost|turbo', caseSensitive: false)
        .hasMatch(powertrainText)) {
      powertrain = 'Turbo / EcoBoost';
    }

    final bodyCategory = classifyBodyCategory(
      '$make $model $trim ${vinDecoded?['bodyClass'] ?? ''} $combinedText',
    );

    double? targetPrice = (nlParsed['maxPrice'] as num?)?.toDouble();
    if (targetPrice == null && combinedText.isNotEmpty) {
      final prices = RegExp(r'\$\s*(\d{2,3},\d{3}(?:\.\d{2})?|\d{5,6})\b')
          .allMatches(combinedText)
          .map((m) => double.tryParse((m.group(1) ?? '').replaceAll(',', '')))
          .whereType<double>()
          .where((n) => n >= 8000 && n <= 250000)
          .toList();
      if (prices.isNotEmpty) {
        prices.sort();
        targetPrice = prices.last;
      }
    }

    String drivetrain = (nlParsed['drivetrain']?.toString() ?? 'Any').trim();
    final vinDt = (vinDecoded?['driveType']?.toString() ?? '').toLowerCase();
    if (drivetrain == 'Any' && vinDt.isNotEmpty) {
      if (RegExp(r'4wd|4x4|four').hasMatch(vinDt)) {
        drivetrain = '4WD';
      } else if (RegExp(r'awd|all').hasMatch(vinDt)) {
        drivetrain = 'AWD';
      } else if (RegExp(r'fwd|front').hasMatch(vinDt)) {
        drivetrain = 'FWD';
      } else if (RegExp(r'rwd|rear').hasMatch(vinDt)) {
        drivetrain = 'RWD';
      }
    }

    final keyFeatures = <String>[
      ...((nlParsed['features'] as List<dynamic>? ?? const [])
          .map((e) => e.toString())),
      ...((nlParsed['strictPackages'] as List<dynamic>? ?? const [])
          .map((e) => e.toString())),
    ];
    final featChecks = <(String, RegExp)>[
      ('Leather Seats', RegExp(r'\bleather\b', caseSensitive: false)),
      (
        'Sunroof/Moonroof',
        RegExp(r'\b(?:sunroof|moonroof|panoramic|vista\s*roof)\b',
            caseSensitive: false)
      ),
      (
        'Navigation System',
        RegExp(r'\b(?:navigation|nav)\b', caseSensitive: false)
      ),
      ('Apple CarPlay', RegExp(r'\bcarplay\b', caseSensitive: false)),
      ('Android Auto', RegExp(r'\bandroid\s*auto\b', caseSensitive: false)),
      (
        'Blind Spot Monitor',
        RegExp(r'\b(?:blind\s*spot|blis)\b', caseSensitive: false)
      ),
      (
        'Heated Seats',
        RegExp(r'\bheated\s*(?:front\s*)?seats\b', caseSensitive: false)
      ),
      (
        '3rd Row Seating',
        RegExp(
            r'\b(?:3rd[\s\-]*row|third[\s\-]*row|7[\s\-]*passenger|8[\s\-]*passenger)\b',
            caseSensitive: false)
      ),
      (
        'Tow Hitch',
        RegExp(r'\b(?:tow\s*(?:package|hitch|haul)|max\s*trailer)\b',
            caseSensitive: false)
      ),
      (
        '360 Camera',
        RegExp(r'\b(?:360[\s°\-]*camera|surround\s*view)\b',
            caseSensitive: false)
      ),
      ('Remote Start', RegExp(r'\bremote\s*start\b', caseSensitive: false)),
    ];
    for (final entry in featChecks) {
      if (entry.$2.hasMatch(combinedText) && !keyFeatures.contains(entry.$1)) {
        keyFeatures.add(entry.$1);
      }
    }

    final cond = (nlParsed['condition']?.toString() ?? 'Any').trim();
    final labelParts = <String>[
      if (cond.isNotEmpty && cond != 'Any') cond,
      if (year != null) '$year',
      if (make.isNotEmpty) make,
      if (model.isNotEmpty) model,
      if (trim.isNotEmpty) trim,
      if (powertrain != 'Any' &&
          !RegExp(r'hybrid', caseSensitive: false).hasMatch('$model $trim'))
        powertrain,
    ];
    final label = labelParts.join(' ');
    final summary = label.isNotEmpty
        ? 'Extracted target specifications from "$fileName": $label${targetPrice != null ? ' (~\$${targetPrice.toStringAsFixed(0)})' : ''}.'
        : 'Analyzed "$fileName" for vehicle class ($bodyCategory), budget, and equipment preferences.';

    return (
      documentSummary: summary,
      extractedGuestName: '',
      profile: DocumentExtractedVehicleProfile(
        condition: cond.isNotEmpty ? cond : 'Any',
        year: year,
        minYear: (nlParsed['minYear'] as num?)?.toInt() ??
            (year != null ? year - 2 : null),
        maxYear: (nlParsed['maxYear'] as num?)?.toInt() ??
            (year != null ? year + 1 : null),
        make: make,
        model: model,
        trim: trim,
        bodyCategory: bodyCategory,
        doors: (nlParsed['doors']?.toString() ??
                vinDecoded?['doors']?.toString() ??
                '')
            .trim(),
        cabStyle: (nlParsed['cabStyle']?.toString() ?? '').trim(),
        bedLength: (nlParsed['bedLength']?.toString() ?? '')
            .replaceAll("'", '')
            .trim(),
        drivetrain: drivetrain,
        powertrain: powertrain,
        engineSpec: (nlParsed['engineSpec']?.toString() ??
                vinDecoded?['displacementL']?.toString() ??
                '')
            .trim(),
        targetPrice: targetPrice,
        maxMileage: (nlParsed['maxMileage'] as num?)?.toInt(),
        exteriorColor: (nlParsed['exteriorColor']?.toString() ?? '').trim(),
        keyFeatures: keyFeatures.take(10).toList(),
        equivalentPrestonModels: _defaultCrossBrandEquivalents(
          make,
          model,
          bodyCategory,
          powertrain,
        ),
      ),
    );
  }

  /// Scores EVERY vehicle in the entire `prestonmotor.com` catalog by closeness/equivalence
  /// to [ref], never hard-rejecting close alternatives when an exact twin is unavailable.
  static List<EquivalentVehicleMatch> scoreInventoryEquivalence(
    DocumentExtractedVehicleProfile ref,
    List<Map<String, dynamic>> catalogVehicles,
  ) {
    final refMake = ref.make.trim().toLowerCase();
    final refModel = ref.model.trim();
    final refTrim = ref.trim.trim();
    final refTrimTier = _classifyTrimTier(refTrim);
    final refBody = ref.bodyCategory.trim().isNotEmpty
        ? ref.bodyCategory.trim()
        : classifyBodyCategory('${ref.make} ${ref.model} ${ref.trim}');
    final refPowertrain = ref.powertrain.trim().toLowerCase();
    final refDt = ref.drivetrain.trim().toUpperCase();
    final refPrice =
        (ref.targetPrice != null && ref.targetPrice! > 0) ? ref.targetPrice : null;
    final refYear = ref.year;
    final refCond = ref.condition.trim().toLowerCase();
    final refColor = ref.exteriorColor.trim();
    final refBed = ref.bedLength.replaceAll("'", '').trim();
    final refCab = ref.cabStyle.trim().toLowerCase();
    final refDoors = ref.doors.trim();

    final scored = <({int rawPoints, EquivalentVehicleMatch match})>[];

    for (final v in catalogVehicles) {
      int points = 32;
      final matchingHighlights = <String>[];
      final keyDifferences = <String>[];

      final vMake = (v['make']?.toString() ?? '').trim();
      final vModel = (v['model']?.toString() ?? '').trim();
      final vTrim = (v['trim']?.toString() ?? '').trim();
      final vCond = (v['condition']?.toString() ?? '').trim();
      final vTitle = (v['title']?.toString() ?? '').trim();
      final vLocation =
          (v['location']?.toString() ?? 'Preston Automotive Group').trim();

      final sameMake = refMake.isNotEmpty && vMake.toLowerCase() == refMake;
      final sameModel = refModel.isNotEmpty &&
          NaturalLanguageVehicleParser.doesVehicleMatchModel(refModel, v);

      final isSuggestedEquivModel = !sameModel &&
          ref.equivalentPrestonModels.any((em) {
            final emMake = (em['make'] ?? '').trim().toLowerCase();
            final emModel = (em['model'] ?? '').trim();
            return (emMake.isEmpty || emMake == vMake.toLowerCase()) &&
                emModel.isNotEmpty &&
                NaturalLanguageVehicleParser.doesVehicleMatchModel(emModel, v);
          });

      final vBody = classifyBodyCategory(
        '$vMake $vModel $vTrim ${v['bodyStyle'] ?? ''} ${v['bodyType'] ?? ''} ${v['commentsSummary'] ?? ''}',
      );

      String matchTier = 'Closest Segment Alternative';
      if (sameMake && sameModel) {
        points += 30;
        matchingHighlights.add('Same $vMake $vModel Model');
        matchTier = 'Same Model • Closest Spec';
      } else if (isSuggestedEquivModel) {
        points += 21;
        matchingHighlights.add('Direct $refBody Equivalent ($vMake $vModel)');
        if (refMake.isNotEmpty && refModel.isNotEmpty) {
          keyDifferences.add('$vMake $vModel equivalent to ${ref.make} $refModel');
        }
        matchTier = 'Closest Cross-Brand Equivalent';
      } else if (vBody == refBody) {
        points += 15;
        matchingHighlights.add('Matching $vBody Segment');
        if (refMake.isNotEmpty && refModel.isNotEmpty) {
          keyDifferences.add('$vMake $vModel in same $vBody class');
        }
        matchTier =
            sameMake ? 'Same Brand • Closest Segment' : 'Closest Cross-Brand Equivalent';
      } else if (refBody.contains('SUV') && vBody.contains('SUV')) {
        points += 7;
        keyDifferences.add('$vBody vs. $refBody');
      } else {
        points -= 28;
        keyDifferences.add('$vBody body style');
      }

      if (refTrim.isNotEmpty &&
          NaturalLanguageVehicleParser.doesVehicleMatchTrim(refTrim, v)) {
        points += 11;
        matchingHighlights.add('${vTrim.isNotEmpty ? vTrim : refTrim} Trim');
        if (sameMake && sameModel) {
          matchTier = 'Exact / Near-Identical Match';
        }
      } else if (refTrimTier.isNotEmpty &&
          vTrim.isNotEmpty &&
          _classifyTrimTier(vTrim) == refTrimTier) {
        points += 6;
        matchingHighlights.add('Comparable $vTrim Equipment Tier');
        if (refTrim.isNotEmpty && sameModel) {
          keyDifferences.add('$vTrim trim vs. $refTrim');
        }
      } else if (refTrim.isNotEmpty && vTrim.isNotEmpty && sameModel) {
        keyDifferences.add('$vTrim trim vs. $refTrim');
      }

      final vPowerText =
          '${v['fuelType'] ?? ''} ${v['engine'] ?? ''} $vTitle ${v['commentsSummary'] ?? ''}'
              .toLowerCase();
      final vIsHybrid =
          RegExp(r'hybrid|\bfhev\b|\bhev\b|gas/electric').hasMatch(vPowerText);
      final vIsPhev = RegExp(r'plug[\s\-]*in|\bphev\b').hasMatch(vPowerText);
      final vIsElectric =
          RegExp(r'\belectric\b|\bbev\b|\blightning\b|\bmach-?e\b|\bioniq\b')
                  .hasMatch(vPowerText) &&
              !vIsHybrid;
      final vIsDiesel =
          RegExp(r'\bdiesel\b|power\s*stroke|duramax').hasMatch(vPowerText);

      if (refPowertrain.isNotEmpty && refPowertrain != 'any') {
        if (refPowertrain.contains('plug') && vIsPhev) {
          points += 10;
          matchingHighlights.add('Plug-In Hybrid Powertrain');
        } else if (refPowertrain.contains('hybrid') && (vIsHybrid || vIsPhev)) {
          points += 10;
          matchingHighlights.add('Hybrid Powertrain');
        } else if (refPowertrain.contains('electric') && vIsElectric) {
          points += 10;
          matchingHighlights.add('All-Electric Powertrain');
        } else if (refPowertrain.contains('diesel') && vIsDiesel) {
          points += 10;
          matchingHighlights.add('Diesel Powertrain');
        } else if (refPowertrain.contains('v8') &&
            RegExp(r'\bv8\b|5\.0l|7\.3l|6\.2l').hasMatch(vPowerText)) {
          points += 8;
          matchingHighlights.add('${v['engine'] ?? 'V8'} Engine');
        } else if (refPowertrain.contains('turbo') &&
            RegExp(r'ecoboost|turbo').hasMatch(vPowerText)) {
          points += 7;
          matchingHighlights.add('Turbocharged Engine');
        } else if (refPowertrain.contains('gas') &&
            !vIsElectric &&
            !vIsDiesel) {
          points += 5;
        } else if (refPowertrain.contains('hybrid') && !vIsHybrid) {
          points -= 4;
          keyDifferences.add('${v['fuelType'] ?? 'Gasoline'} vs. Hybrid');
        }
      }

      final vDt = (v['drivetrain']?.toString() ?? '').toUpperCase();
      if (refDt.isNotEmpty && refDt != 'ANY') {
        if (vDt.contains(refDt)) {
          points += 9;
          matchingHighlights.add('${v['drivetrain'] ?? refDt} Drivetrain');
        } else if ((refDt == '4WD' && vDt.contains('AWD')) ||
            (refDt == 'AWD' && vDt.contains('4WD'))) {
          points += 7;
          matchingHighlights.add('${v['drivetrain']} All-Weather Traction');
        } else if (vDt.isNotEmpty) {
          points -= 4;
          keyDifferences.add('${v['drivetrain']} vs. $refDt');
        }
      } else if (vDt.isNotEmpty) {
        matchingHighlights.add('${v['drivetrain']} Drivetrain');
      }

      final pr = (v['price'] as num?)?.toDouble();
      final msrp = (v['msrp'] as num?)?.toDouble();
      final effectivePrice = (pr != null && pr > 0)
          ? pr
          : ((msrp != null && msrp > 0) ? msrp : null);
      if (refPrice != null && effectivePrice != null) {
        final diff = effectivePrice - refPrice;
        final pctDiff = diff.abs() / refPrice;
        if (pctDiff <= 0.08) {
          points += 12;
          matchingHighlights.add(
            diff <= 0
                ? '\$${effectivePrice.toStringAsFixed(0)} (\$${diff.abs().toStringAsFixed(0)} under target)'
                : '\$${effectivePrice.toStringAsFixed(0)} (Within 8% of target)',
          );
        } else if (pctDiff <= 0.18) {
          points += 8;
          if (diff < 0) {
            matchingHighlights.add(
              '\$${diff.abs().toStringAsFixed(0)} below target price',
            );
          } else {
            keyDifferences.add(
              '\$${diff.toStringAsFixed(0)} above document price',
            );
          }
        } else if (pctDiff <= 0.30) {
          points += 3;
          keyDifferences.add(
            diff > 0
                ? '\$${diff.toStringAsFixed(0)} higher price tier'
                : '\$${diff.abs().toStringAsFixed(0)} lower price tier',
          );
        } else {
          final penalty = ((pctDiff - 0.30) * 24).round().clamp(0, 14);
          points -= penalty;
        }
      }

      final vcLower = vCond.toLowerCase();
      if (refCond.isNotEmpty && refCond != 'any') {
        if ((refCond == 'new' && vcLower.contains('new')) ||
            (refCond == 'cpo' && vcLower.contains('certified')) ||
            (refCond == 'pre-owned' && !vcLower.contains('new'))) {
          points += 5;
        } else if (vCond.isNotEmpty) {
          keyDifferences.add('$vCond condition');
        }
      }

      final vYear = (v['year'] as num?)?.toInt();
      if (refYear != null && vYear != null) {
        final yrDiff = (vYear - refYear).abs();
        if (yrDiff == 0) {
          points += 5;
        } else if (yrDiff <= 1) {
          points += 3;
        } else if (yrDiff <= 3) {
          points += 1;
        } else {
          points -= (yrDiff * 2).clamp(0, 8);
        }
      }

      if (refBed.isNotEmpty) {
        final vBed = NaturalLanguageVehicleParser.extractBedLengthFromVehicle(
          v,
          fullCommentsClean:
              (v['fullCommentsSearchText'] ?? v['commentsSummary'] ?? '')
                  .toString(),
        ).replaceAll("'", '').trim();
        if (vBed.isNotEmpty && vBed == refBed) {
          points += 7;
          matchingHighlights.add(
            NaturalLanguageVehicleParser.formatBedLengthLabel(vBed),
          );
        } else if (vBed.isNotEmpty) {
          keyDifferences.add(
            '${NaturalLanguageVehicleParser.formatBedLengthLabel(vBed)} vs. ${NaturalLanguageVehicleParser.formatBedLengthLabel(refBed)}',
          );
        }
      }

      final vCab = (v['cabStyle']?.toString() ?? '').trim();
      if (refCab.isNotEmpty && vCab.isNotEmpty) {
        if (vCab.toLowerCase() == refCab) {
          points += 5;
          matchingHighlights.add(vCab);
        } else {
          keyDifferences.add('$vCab vs. ${ref.cabStyle}');
        }
      }

      if (refDoors.isNotEmpty && (v['doors']?.toString() ?? '') == refDoors) {
        points += 3;
      }

      final vColor = (v['exteriorColor']?.toString() ?? '').trim();
      if (refColor.isNotEmpty && vColor.isNotEmpty) {
        if (NaturalLanguageVehicleParser.doesVehicleMatchColor(refColor, v)) {
          points += 5;
          matchingHighlights.add('$vColor Exterior');
        } else {
          keyDifferences.add('$vColor exterior');
        }
      }

      final vHighlights = (v['highlights'] as List<dynamic>? ?? const [])
          .map((e) => e.toString())
          .toList();
      final fullHay =
          '${vHighlights.join(' | ')} | ${v['engine'] ?? ''} | $vColor | ${v['interiorColor'] ?? ''} | ${v['fullCommentsSearchText'] ?? v['commentsSummary'] ?? ''}'
              .toLowerCase();

      int featHits = 0;
      for (final feat in ref.keyFeatures) {
        final words = feat
            .toLowerCase()
            .replaceAll(RegExp(r'[^a-z0-9\s]'), ' ')
            .split(RegExp(r'\s+'))
            .where((w) => w.length >= 3)
            .toList();
        if (words.isNotEmpty && words.any((w) => fullHay.contains(w))) {
          featHits++;
          if (matchingHighlights.length < 6) {
            matchingHighlights.add(feat);
          }
        }
      }
      points += (featHits * 2).clamp(0, 10);

      if (matchingHighlights.length < 4) {
        for (final h in vHighlights.take(4)) {
          if (!matchingHighlights
              .any((mh) => mh.toLowerCase().contains(h.toLowerCase()))) {
            matchingHighlights.add(h);
          }
          if (matchingHighlights.length >= 5) break;
        }
      }

      final maxAllowedScore = (sameMake && sameModel) ? 99 : 94;
      final similarityScore = points.clamp(35, maxAllowedScore);
      final priceLabel = effectivePrice != null
          ? '\$${effectivePrice.toStringAsFixed(0)}'
          : 'Call for Price';

      final whyEquivalent = (sameMake && sameModel)
          ? 'In-stock $vCond $vTitle at $vLocation ($priceLabel) closely matches the uploaded ${ref.make} ${ref.model} spec${keyDifferences.isNotEmpty ? ' (${keyDifferences.take(2).join('; ')})' : ''}.'
          : 'Closest ${vBody.toLowerCase()} equivalent at $vLocation: $vCond $vTitle ($priceLabel) aligns on ${matchingHighlights.take(3).join(', ')}.';

      scored.add((
        rawPoints: points,
        match: EquivalentVehicleMatch(
          vin: v['vin']?.toString() ?? '',
          stockNumber: v['stockNumber']?.toString() ?? '',
          title: vTitle,
          year: vYear,
          make: vMake,
          model: vModel,
          trim: vTrim,
          condition: vCond,
          price: pr,
          msrp: msrp,
          location: vLocation,
          mileage: (v['mileage'] as num?)?.toInt() ?? 0,
          drivetrain: v['drivetrain']?.toString() ?? '',
          engine: v['engine']?.toString() ?? '',
          fuelType: v['fuelType']?.toString() ?? '',
          exteriorColor: vColor,
          interiorColor: v['interiorColor']?.toString() ?? '',
          photoUrl: v['photoUrl']?.toString() ?? '',
          listingUrl:
              v['listingUrl']?.toString() ?? 'https://www.prestonmotor.com',
          similarityScore: similarityScore,
          matchTier: matchTier,
          whyEquivalent: whyEquivalent,
          matchingHighlights: matchingHighlights.toSet().take(6).toList(),
          keyDifferences: keyDifferences.toSet().take(3).toList(),
        ),
      ));
    }

    scored.sort((a, b) {
      final cmp = b.match.similarityScore.compareTo(a.match.similarityScore);
      if (cmp != 0) return cmp;
      final rawCmp = b.rawPoints.compareTo(a.rawPoints);
      if (rawCmp != 0) return rawCmp;
      final pa = a.match.price ?? double.maxFinite;
      final pb = b.match.price ?? double.maxFinite;
      if (refPrice != null &&
          pa != double.maxFinite &&
          pb != double.maxFinite) {
        return (pa - refPrice).abs().compareTo((pb - refPrice).abs());
      }
      return pa.compareTo(pb);
    });

    return scored.map((s) => s.match).toList();
  }

  /// Full on-device pipeline: extracts specs from [document] with Gemini,
  /// evaluates [entireCatalog] across all Preston stores, and ranks the closest equivalents.
  static Future<DocumentEquivalentSearchResult> findClosestEquivalents({
    required PickedDocumentFile document,
    required List<Map<String, dynamic>> entireCatalog,
    String geminiApiKey = '',
    String geminiModel = 'gemini-2.5-flash',
    String extraNotes = '',
  }) async {
    if (mockSearchHandler != null) {
      return mockSearchHandler!(document: document, extraNotes: extraNotes);
    }

    final cleanB64 = document.base64Data
        .replaceFirst(RegExp(r'^data:[^;]+;base64,'), '')
        .replaceAll(RegExp(r'\s+'), '');
    final resolvedMime = inferMimeType(document.fileName, document.mimeType);
    Uint8List bytes = Uint8List(0);
    try {
      if (cleanB64.isNotEmpty) {
        bytes = base64Decode(cleanB64);
      }
    } catch (_) {}

    final readableText =
        extractReadableTextFromBytes(bytes, document.fileName, resolvedMime);
    final detectedVin =
        extractFirstValidVinFromText('$readableText $extraNotes');
    final vinDecoded =
        detectedVin.isNotEmpty ? await _decodeVinHint(detectedVin) : null;

    final fallback = buildFallbackProfile(
      fileName: document.fileName,
      readableText: readableText,
      vinDecoded: vinDecoded,
      extraNotes: extraNotes,
    );

    final cleanKey = geminiApiKey.trim();
    final cleanModel =
        geminiModel.trim().isNotEmpty ? geminiModel.trim() : 'gemini-2.5-flash';

    String docSummary = fallback.documentSummary;
    String extractedGuestName = fallback.extractedGuestName;
    DocumentExtractedVehicleProfile refProfile = fallback.profile;

    if (cleanKey.isNotEmpty) {
      final endpoint = Uri.parse(
        'https://generativelanguage.googleapis.com/v1beta/models/${Uri.encodeComponent(cleanModel)}:generateContent?key=${Uri.encodeComponent(cleanKey)}',
      );

      final userParts = <Map<String, dynamic>>[];
      if (cleanB64.isNotEmpty && _geminiInlineMimeTypes.contains(resolvedMime)) {
        userParts.add({
          'inlineData': {
            'mimeType': resolvedMime,
            'data': cleanB64,
          },
        });
      }
      userParts.add({
        'text':
            'Inspect this uploaded guest/vehicle document ("${document.fileName}") and extract target vehicle specifications plus 3 to 6 closest equivalent Preston Automotive Group models (Ford, Lincoln, Hyundai, Mazda, Nissan, Chevrolet, GMC, Jeep, Ram, Toyota, Honda) in case an identical vehicle is not in stock.\n\nContext:\n${jsonEncode({
                  'uploadedFileName': document.fileName,
                  'decodedVinFromDocumentIfFound': vinDecoded,
                  if (readableText.isNotEmpty)
                    'extractedReadableTextPreview': readableText.length > 10000
                        ? readableText.substring(0, 10000)
                        : readableText,
                  if (extraNotes.trim().isNotEmpty)
                    'salespersonExtraNotes': extraNotes.trim(),
                })}',
      });

      try {
        final res1 = await http
            .post(
              endpoint,
              headers: const {'Content-Type': 'application/json'},
              body: jsonEncode({
                'systemInstruction': {
                  'parts': [
                    {
                      'text':
                          'You are the Preston Automotive Group Gemini Document & Window-Sticker Analyst. Extract target vehicle specs and suggest 3-6 closest equivalent Preston models.'
                    }
                  ],
                },
                'contents': [
                  {'role': 'user', 'parts': userParts}
                ],
                'generationConfig': {
                  'temperature': 0.1,
                  'responseMimeType': 'application/json',
                  'responseSchema': {
                    'type': 'OBJECT',
                    'properties': {
                      'documentSummary': {'type': 'STRING'},
                      'extractedGuestName': {'type': 'STRING'},
                      'condition': {'type': 'STRING'},
                      'year': {'type': 'INTEGER', 'nullable': true},
                      'make': {'type': 'STRING'},
                      'model': {'type': 'STRING'},
                      'trim': {'type': 'STRING'},
                      'bodyCategory': {'type': 'STRING'},
                      'doors': {'type': 'STRING'},
                      'cabStyle': {'type': 'STRING'},
                      'bedLength': {'type': 'STRING'},
                      'drivetrain': {'type': 'STRING'},
                      'powertrain': {'type': 'STRING'},
                      'engineSpec': {'type': 'STRING'},
                      'targetPrice': {'type': 'NUMBER', 'nullable': true},
                      'maxMileage': {'type': 'INTEGER', 'nullable': true},
                      'exteriorColor': {'type': 'STRING'},
                      'interiorColor': {'type': 'STRING'},
                      'keyFeatures': {
                        'type': 'ARRAY',
                        'items': {'type': 'STRING'}
                      },
                      'equivalentPrestonModels': {
                        'type': 'ARRAY',
                        'items': {
                          'type': 'OBJECT',
                          'properties': {
                            'make': {'type': 'STRING'},
                            'model': {'type': 'STRING'},
                          },
                          'required': ['make', 'model'],
                        },
                      },
                    },
                    'required': [
                      'documentSummary',
                      'condition',
                      'make',
                      'model',
                      'trim',
                      'bodyCategory',
                      'drivetrain',
                      'powertrain',
                      'keyFeatures',
                      'equivalentPrestonModels',
                    ],
                  },
                },
              }),
            )
            .timeout(const Duration(seconds: 30));

        if (res1.statusCode == 200) {
          final d1 = jsonDecode(res1.body) as Map<String, dynamic>;
          final raw1 = (((d1['candidates'] as List?)?.firstOrNull
                          as Map?)?['content']?['parts'] as List?)
                      ?.firstOrNull?['text']
                      ?.toString() ??
                  '{}';
          final parsed = jsonDecode(raw1) as Map<String, dynamic>;
          final yr = (parsed['year'] as num?)?.toInt() ?? refProfile.year;
          final parsedCond = (parsed['condition']?.toString() ?? '').trim();
          final parsedDt =
              (parsed['drivetrain']?.toString() ?? '').trim().toUpperCase();
          final mergedEquiv = <Map<String, String>>[
            ...((parsed['equivalentPrestonModels'] as List<dynamic>? ?? const [])
                .whereType<Map>()
                .map(
                  (m) => {
                    'make': (m['make']?.toString() ?? '').trim(),
                    'model': (m['model']?.toString() ?? '').trim(),
                  },
                )),
            ...refProfile.equivalentPrestonModels,
          ];

          docSummary =
              (parsed['documentSummary']?.toString() ?? docSummary).trim();
          extractedGuestName =
              (parsed['extractedGuestName']?.toString() ?? '').trim();
          refProfile = DocumentExtractedVehicleProfile(
            condition: const ['New', 'Pre-Owned', 'CPO', 'Any']
                    .contains(parsedCond)
                ? parsedCond
                : refProfile.condition,
            year: yr,
            minYear: yr != null ? yr - 2 : refProfile.minYear,
            maxYear: yr != null ? yr + 1 : refProfile.maxYear,
            make: (parsed['make']?.toString() ?? refProfile.make).trim(),
            model: (parsed['model']?.toString() ?? refProfile.model).trim(),
            trim: (parsed['trim']?.toString() ?? refProfile.trim).trim(),
            bodyCategory: (parsed['bodyCategory']?.toString() ?? '').trim().isNotEmpty
                ? parsed['bodyCategory'].toString().trim()
                : refProfile.bodyCategory,
            doors: (parsed['doors']?.toString() ?? refProfile.doors)
                .replaceAll(RegExp(r'[^0-9]'), ''),
            cabStyle:
                (parsed['cabStyle']?.toString() ?? refProfile.cabStyle).trim(),
            bedLength: (parsed['bedLength']?.toString() ?? refProfile.bedLength)
                .replaceAll(RegExp(r'[^0-9.]'), '')
                .trim(),
            drivetrain: const ['4WD', 'AWD', 'FWD', 'RWD', 'ANY']
                    .contains(parsedDt)
                ? (parsedDt == 'ANY' ? 'Any' : parsedDt)
                : refProfile.drivetrain,
            powertrain:
                (parsed['powertrain']?.toString() ?? refProfile.powertrain)
                    .trim(),
            engineSpec:
                (parsed['engineSpec']?.toString() ?? refProfile.engineSpec)
                    .trim(),
            targetPrice: ((parsed['targetPrice'] as num?)?.toDouble() ?? 0) > 0
                ? (parsed['targetPrice'] as num).toDouble()
                : refProfile.targetPrice,
            maxMileage: ((parsed['maxMileage'] as num?)?.toInt() ?? 0) > 0
                ? (parsed['maxMileage'] as num).toInt()
                : refProfile.maxMileage,
            exteriorColor: (parsed['exteriorColor']?.toString() ??
                    refProfile.exteriorColor)
                .trim(),
            interiorColor: (parsed['interiorColor']?.toString() ?? '').trim(),
            keyFeatures: <String>{
              ...((parsed['keyFeatures'] as List<dynamic>? ?? const [])
                  .map((e) => e.toString().trim())
                  .where((s) => s.isNotEmpty)),
              ...refProfile.keyFeatures,
            }.take(10).toList(),
            equivalentPrestonModels: mergedEquiv.take(8).toList(),
          );
        }
      } catch (_) {}
    }

    final rankedAll = scoreInventoryEquivalence(refProfile, entireCatalog);
    final topShortlist = rankedAll.take(32).toList();
    List<EquivalentVehicleMatch> finalEquivalents = rankedAll.take(15).toList();
    String overallSummary = docSummary;
    String agentMode =
        cleanKey.isNotEmpty ? 'gemini ($cleanModel)' : 'smart-equivalence-engine';

    if (cleanKey.isNotEmpty && topShortlist.isNotEmpty) {
      final endpoint = Uri.parse(
        'https://generativelanguage.googleapis.com/v1beta/models/${Uri.encodeComponent(cleanModel)}:generateContent?key=${Uri.encodeComponent(cleanKey)}',
      );
      try {
        final res2 = await http
            .post(
              endpoint,
              headers: const {'Content-Type': 'application/json'},
              body: jsonEncode({
                'systemInstruction': {
                  'parts': [
                    {
                      'text':
                          'You are the Preston Automotive Group Gemini Equivalent-Vehicle Matchmaker. Select and rank the 10 to 15 CLOSEST EQUIVALENT vehicles on prestonmotor.com to the guest\'s uploaded document. Matching vehicles do NOT need to be identical — rank the closest available equivalents and note both matchingHighlights and keyDifferences.'
                    }
                  ],
                },
                'contents': [
                  {
                    'role': 'user',
                    'parts': [
                      {
                        'text': jsonEncode({
                          'documentSummary': docSummary,
                          'targetReferenceVehicle': refProfile.toJson(),
                          'totalPrestonInventoryScanned': entireCatalog.length,
                          'shortlistedCandidates': topShortlist
                              .map(
                                (m) => {
                                  'vin': m.vin,
                                  'title': m.title,
                                  'year': m.year,
                                  'make': m.make,
                                  'model': m.model,
                                  'trim': m.trim,
                                  'condition': m.condition,
                                  'price': m.price,
                                  'location': m.location,
                                  'mileage': m.mileage,
                                  'drivetrain': m.drivetrain,
                                  'engine': m.engine,
                                  'fuelType': m.fuelType,
                                  'exteriorColor': m.exteriorColor,
                                  'baselineScore': m.similarityScore,
                                },
                              )
                              .toList(),
                        }),
                      }
                    ],
                  }
                ],
                'generationConfig': {
                  'temperature': 0.15,
                  'responseMimeType': 'application/json',
                  'responseSchema': {
                    'type': 'OBJECT',
                    'properties': {
                      'overallSummary': {'type': 'STRING'},
                      'equivalents': {
                        'type': 'ARRAY',
                        'items': {
                          'type': 'OBJECT',
                          'properties': {
                            'vin': {'type': 'STRING'},
                            'similarityScore': {'type': 'INTEGER'},
                            'matchTier': {'type': 'STRING'},
                            'whyEquivalent': {'type': 'STRING'},
                            'matchingHighlights': {
                              'type': 'ARRAY',
                              'items': {'type': 'STRING'}
                            },
                            'keyDifferences': {
                              'type': 'ARRAY',
                              'items': {'type': 'STRING'}
                            },
                          },
                          'required': [
                            'vin',
                            'similarityScore',
                            'matchTier',
                            'whyEquivalent',
                            'matchingHighlights',
                            'keyDifferences',
                          ],
                        },
                      },
                    },
                    'required': ['overallSummary', 'equivalents'],
                  },
                },
              }),
            )
            .timeout(const Duration(seconds: 30));

        if (res2.statusCode == 200) {
          final d2 = jsonDecode(res2.body) as Map<String, dynamic>;
          final raw2 = (((d2['candidates'] as List?)?.firstOrNull
                          as Map?)?['content']?['parts'] as List?)
                      ?.firstOrNull?['text']
                      ?.toString() ??
                  '{}';
          final parsed2 = jsonDecode(raw2) as Map<String, dynamic>;
          final byVin = {for (final m in topShortlist) m.vin: m};
          final picked = <EquivalentVehicleMatch>[];
          for (final rawEq
              in (parsed2['equivalents'] as List<dynamic>? ?? const [])) {
            if (rawEq is! Map) continue;
            final base = byVin[rawEq['vin']?.toString() ?? ''];
            if (base == null) continue;
            picked.add(
              EquivalentVehicleMatch(
                vin: base.vin,
                stockNumber: base.stockNumber,
                title: base.title,
                year: base.year,
                make: base.make,
                model: base.model,
                trim: base.trim,
                condition: base.condition,
                price: base.price,
                msrp: base.msrp,
                location: base.location,
                mileage: base.mileage,
                drivetrain: base.drivetrain,
                engine: base.engine,
                fuelType: base.fuelType,
                exteriorColor: base.exteriorColor,
                interiorColor: base.interiorColor,
                photoUrl: base.photoUrl,
                listingUrl: base.listingUrl,
                similarityScore: ((rawEq['similarityScore'] as num?)?.toInt() ??
                        base.similarityScore)
                    .clamp(35, 99),
                matchTier:
                    (rawEq['matchTier']?.toString() ?? base.matchTier).trim(),
                whyEquivalent:
                    (rawEq['whyEquivalent']?.toString() ?? base.whyEquivalent)
                        .trim(),
                matchingHighlights: <String>{
                  ...((rawEq['matchingHighlights'] as List<dynamic>? ?? const [])
                      .map((e) => e.toString())
                      .where((s) => s.isNotEmpty)),
                  ...base.matchingHighlights,
                }.take(6).toList(),
                keyDifferences: <String>{
                  ...((rawEq['keyDifferences'] as List<dynamic>? ?? const [])
                      .map((e) => e.toString())
                      .where((s) => s.isNotEmpty)),
                  ...base.keyDifferences,
                }.take(3).toList(),
              ),
            );
          }
          if (picked.isNotEmpty) {
            picked.sort((a, b) => b.similarityScore.compareTo(a.similarityScore));
            finalEquivalents = picked.take(15).toList();
            final s = (parsed2['overallSummary']?.toString() ?? '').trim();
            if (s.isNotEmpty) overallSummary = s;
          }
        }
      } catch (_) {
        agentMode = 'gemini-fallback ($cleanModel)';
      }
    } else {
      final locCount = finalEquivalents.map((e) => e.location).toSet().length;
      overallSummary =
          '$docSummary Scanned all ${entireCatalog.length} live prestonmotor.com vehicles and ranked the ${finalEquivalents.length} closest equivalent vehicle(s) across $locCount Preston dealership location(s).';
    }

    return DocumentEquivalentSearchResult(
      fileName: document.fileName,
      mimeType: resolvedMime,
      analyzedAt: DateTime.now().toUtc().toIso8601String(),
      agentMode: agentMode,
      totalInventoryScanned: entireCatalog.length,
      documentSummary: docSummary,
      overallSummary: overallSummary,
      extractedGuestName: extractedGuestName,
      referenceVehicle: refProfile,
      equivalents: finalEquivalents,
    );
  }
}

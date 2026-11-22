import '../services/natural_language_parser.dart';

class VehicleSearchTarget {
  final String id;
  final String condition;
  final int? minYear;
  final int? maxYear;
  final String make;
  final String model;
  final String trim;
  final String doors;
  final String bedLength;
  final String cabStyle;
  final String engineSpec;
  final double? maxPrice;
  final int? maxMileage;
  final String drivetrain;
  final String exteriorColor;
  final List<String> features;
  final String notes;
  final String createdAt;

  const VehicleSearchTarget({
    required this.id,
    this.condition = 'Any',
    this.minYear,
    this.maxYear,
    this.make = '',
    this.model = '',
    this.trim = '',
    this.doors = '',
    this.bedLength = '',
    this.cabStyle = '',
    this.engineSpec = '',
    this.maxPrice,
    this.maxMileage,
    this.drivetrain = 'Any',
    this.exteriorColor = '',
    this.features = const [],
    this.notes = '',
    this.createdAt = '',
  });

  factory VehicleSearchTarget.fromJson(Map<String, dynamic> json) {
    final norm = NaturalLanguageVehicleParser.parseCriteriaMap(json);
    return VehicleSearchTarget(
      id: json['id']?.toString() ?? '',
      condition: norm['condition']?.toString() ?? 'Any',
      minYear: (norm['minYear'] as num?)?.toInt(),
      maxYear: (norm['maxYear'] as num?)?.toInt(),
      make: norm['make']?.toString() ?? '',
      model: norm['model']?.toString() ?? '',
      trim: norm['trim']?.toString() ?? '',
      doors: norm['doors']?.toString() ?? '',
      bedLength: norm['bedLength']?.toString() ?? '',
      cabStyle: norm['cabStyle']?.toString() ?? '',
      engineSpec: norm['engineSpec']?.toString() ?? '',
      maxPrice: (norm['maxPrice'] as num?)?.toDouble(),
      maxMileage: (norm['maxMileage'] as num?)?.toInt(),
      drivetrain: norm['drivetrain']?.toString() ?? 'Any',
      exteriorColor: norm['exteriorColor']?.toString() ?? '',
      features: (norm['features'] as List<dynamic>?)
              ?.map((e) => e.toString())
              .toList() ??
          const [],
      notes: norm['notes']?.toString() ?? '',
      createdAt: json['createdAt']?.toString() ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'condition': condition,
        'minYear': minYear,
        'maxYear': maxYear,
        'make': make,
        'model': model,
        'trim': trim,
        'doors': doors,
        'bedLength': bedLength,
        'cabStyle': cabStyle,
        'engineSpec': engineSpec,
        'maxPrice': maxPrice,
        'maxMileage': maxMileage,
        'drivetrain': drivetrain,
        'exteriorColor': exteriorColor,
        'features': features,
        'notes': notes,
        'createdAt': createdAt,
      };

  String get label {
    final parts = <String>[];
    if (condition != 'Any' && condition.isNotEmpty) parts.add(condition);
    if (minYear != null && maxYear != null) {
      parts.add(minYear == maxYear ? '$minYear' : '$minYear–$maxYear');
    } else if (minYear != null) {
      parts.add('$minYear+');
    } else if (maxYear != null) {
      parts.add('Up to $maxYear');
    }
    if (make.isNotEmpty) parts.add(make);
    if (model.isNotEmpty) parts.add(model);
    if (trim.isNotEmpty) parts.add(trim);

    final qualifiers = <String>[];
    if (doors.isNotEmpty) {
      qualifiers.add(NaturalLanguageVehicleParser.formatDoorsLabel(doors));
    }
    if (cabStyle.isNotEmpty) qualifiers.add(cabStyle);
    if (bedLength.isNotEmpty) {
      qualifiers.add(NaturalLanguageVehicleParser.formatBedLengthLabel(bedLength));
    }

    if (parts.isEmpty && qualifiers.isEmpty) {
      if (maxPrice != null) {
        return 'Vehicles under \$${maxPrice!.toStringAsFixed(0)}';
      }
      if (notes.trim().isNotEmpty) {
        final trimmed = notes.trim();
        return trimmed.length > 42 ? '${trimmed.substring(0, 42)}…' : trimmed;
      }
      return 'Custom Vehicle Requirements';
    }

    final base = parts.join(' ');
    if (qualifiers.isEmpty) return base;
    if (base.isEmpty) return qualifiers.join(' • ');
    return '$base • ${qualifiers.join(' • ')}';
  }
}

class GuestNote {
  final String id;
  final String text;
  final String createdAt;

  const GuestNote({
    required this.id,
    required this.text,
    required this.createdAt,
  });

  factory GuestNote.fromJson(Map<String, dynamic> json) {
    return GuestNote(
      id: json['id']?.toString() ?? '',
      text: json['text']?.toString() ?? '',
      createdAt: json['createdAt']?.toString() ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'text': text,
        'createdAt': createdAt,
      };
}

class GuestProfile {
  final String id;
  final String name;
  final String phone;
  final String email;
  final String condition;
  final int? minYear;
  final int? maxYear;
  final String make;
  final String model;
  final String trim;
  final String doors;
  final String bedLength;
  final String cabStyle;
  final String engineSpec;
  final double? maxPrice;
  final int? maxMileage;
  final String drivetrain;
  final String exteriorColor;
  final List<String> features;
  final String notes;
  final List<VehicleSearchTarget> vehicleTargets;
  final List<GuestNote> clientNotes;
  final bool initialSearchCompleted;
  final List<String> seenMatchVins;
  final List<String> scheduledCallVins;
  final bool active;
  final String? lastSearchedAt;
  final String lastSearchSummary;
  final String createdAt;
  final int matchCount;
  final double? lowestMatchPrice;

  const GuestProfile({
    required this.id,
    required this.name,
    this.phone = '',
    this.email = '',
    this.condition = 'Any',
    this.minYear,
    this.maxYear,
    this.make = '',
    this.model = '',
    this.trim = '',
    this.doors = '',
    this.bedLength = '',
    this.cabStyle = '',
    this.engineSpec = '',
    this.maxPrice,
    this.maxMileage,
    this.drivetrain = 'Any',
    this.exteriorColor = '',
    this.features = const [],
    this.notes = '',
    this.vehicleTargets = const [],
    this.clientNotes = const [],
    this.initialSearchCompleted = false,
    this.seenMatchVins = const [],
    this.scheduledCallVins = const [],
    this.active = true,
    this.lastSearchedAt,
    this.lastSearchSummary = '',
    required this.createdAt,
    this.matchCount = 0,
    this.lowestMatchPrice,
  });

  factory GuestProfile.fromJson(Map<String, dynamic> json) {
    final guestId = json['id']?.toString() ?? '';
    final createdAtStr = json['createdAt']?.toString() ?? '';
    final primaryFeatures = (json['features'] as List<dynamic>?)
            ?.map((e) => e.toString())
            .toList() ??
        const <String>[];

    final rawTargets = json['vehicleTargets'];
    final parsedTargets = <VehicleSearchTarget>[];
    if (rawTargets is List) {
      for (var i = 0; i < rawTargets.length; i++) {
        final item = rawTargets[i];
        if (item is Map) {
          final map = Map<String, dynamic>.from(item);
          if ((map['id']?.toString() ?? '').isEmpty) {
            map['id'] = '$guestId-vt-${i + 1}';
          }
          if ((map['createdAt']?.toString() ?? '').isEmpty) {
            map['createdAt'] = createdAtStr;
          }
          parsedTargets.add(VehicleSearchTarget.fromJson(map));
        }
      }
    }

    if (parsedTargets.isEmpty) {
      parsedTargets.add(
        VehicleSearchTarget.fromJson(<String, dynamic>{
          'id': guestId.isNotEmpty ? '$guestId-primary' : 'primary',
          'condition': json['condition']?.toString() ?? 'Any',
          'minYear': json['minYear'],
          'maxYear': json['maxYear'],
          'make': json['make']?.toString() ?? '',
          'model': json['model']?.toString() ?? '',
          'trim': json['trim']?.toString() ?? '',
          'doors': json['doors']?.toString() ?? '',
          'bedLength': json['bedLength']?.toString() ?? '',
          'cabStyle': json['cabStyle']?.toString() ?? '',
          'engineSpec': json['engineSpec']?.toString() ?? '',
          'maxPrice': json['maxPrice'],
          'maxMileage': json['maxMileage'],
          'drivetrain': json['drivetrain']?.toString() ?? 'Any',
          'exteriorColor': json['exteriorColor']?.toString() ?? '',
          'features': primaryFeatures,
          'notes': json['notes']?.toString() ?? '',
          'createdAt': createdAtStr,
        }),
      );
    }

    final deletedNoteIds = (json['deletedNoteIds'] as List<dynamic>?)
            ?.map((e) => e.toString())
            .toSet() ??
        const <String>{};

    final rawClientNotes = json['clientNotes'];
    final parsedNotes = <GuestNote>[];
    if (rawClientNotes is List) {
      for (var i = 0; i < rawClientNotes.length; i++) {
        final item = rawClientNotes[i];
        if (item is Map) {
          final map = Map<String, dynamic>.from(item);
          final text = (map['text']?.toString() ?? '').trim();
          if (text.isEmpty) continue;
          final noteId = (map['id']?.toString() ?? '').isNotEmpty
              ? map['id'].toString()
              : '$guestId-note-${i + 1}';
          if (deletedNoteIds.contains(noteId)) continue;
          parsedNotes.add(
            GuestNote(
              id: noteId,
              text: text,
              createdAt: (map['createdAt']?.toString() ?? '').isNotEmpty
                  ? map['createdAt'].toString()
                  : createdAtStr,
            ),
          );
        }
      }
    }
    parsedNotes.sort((a, b) => b.createdAt.compareTo(a.createdAt));

    final seenVins = (json['seenMatchVins'] as List<dynamic>?)
            ?.map((e) => e.toString().trim())
            .where((s) => s.isNotEmpty)
            .toSet()
            .toList() ??
        const <String>[];

    final scheduledVins = (json['scheduledCallVins'] as List<dynamic>?)
            ?.map((e) => e.toString().trim())
            .where((s) => s.isNotEmpty)
            .toSet()
            .toList() ??
        const <String>[];

    final lastSearchedStr = json['lastSearchedAt']?.toString();
    final hasCompletedInitial = json['initialSearchCompleted'] == true ||
        (lastSearchedStr != null && lastSearchedStr.isNotEmpty);

    final first = parsedTargets.first;

    return GuestProfile(
      id: guestId,
      name: json['name']?.toString() ?? '',
      phone: json['phone']?.toString() ?? '',
      email: json['email']?.toString() ?? '',
      condition: first.condition,
      minYear: first.minYear,
      maxYear: first.maxYear,
      make: first.make,
      model: first.model,
      trim: first.trim,
      doors: first.doors,
      bedLength: first.bedLength,
      cabStyle: first.cabStyle,
      engineSpec: first.engineSpec,
      maxPrice: first.maxPrice,
      maxMileage: first.maxMileage,
      drivetrain: first.drivetrain,
      exteriorColor: first.exteriorColor,
      features: first.features,
      notes: first.notes,
      vehicleTargets: parsedTargets,
      clientNotes: parsedNotes,
      initialSearchCompleted: hasCompletedInitial,
      seenMatchVins: seenVins,
      scheduledCallVins: scheduledVins,
      active: json['active'] != false,
      lastSearchedAt: lastSearchedStr,
      lastSearchSummary: json['lastSearchSummary']?.toString() ?? '',
      createdAt: createdAtStr,
      matchCount: (json['matchCount'] as num?)?.toInt() ?? 0,
      lowestMatchPrice: (json['lowestMatchPrice'] as num?)?.toDouble(),
    );
  }

  GuestNote? get latestClientNote =>
      clientNotes.isNotEmpty ? clientNotes.first : null;

  List<VehicleSearchTarget> get effectiveTargets {
    if (vehicleTargets.isNotEmpty) return vehicleTargets;
    return [
      VehicleSearchTarget.fromJson(<String, dynamic>{
        'id': id.isNotEmpty ? '$id-primary' : 'primary',
        'condition': condition,
        'minYear': minYear,
        'maxYear': maxYear,
        'make': make,
        'model': model,
        'trim': trim,
        'doors': doors,
        'bedLength': bedLength,
        'cabStyle': cabStyle,
        'engineSpec': engineSpec,
        'maxPrice': maxPrice,
        'maxMileage': maxMileage,
        'drivetrain': drivetrain,
        'exteriorColor': exteriorColor,
        'features': features,
        'notes': notes,
        'createdAt': createdAt,
      }),
    ];
  }

  String get targetVehicleLabel {
    final targets = effectiveTargets;
    if (targets.length == 1) {
      return targets.first.label;
    }
    if (targets.length == 2) {
      return '${targets[0].label}  +  ${targets[1].label}';
    }
    return '${targets[0].label}  +  ${targets[1].label}  (+${targets.length - 2} more)';
  }

  String get allSearchableSpecsText {
    final buf = StringBuffer(name);
    for (final t in effectiveTargets) {
      buf
        ..write(' ')
        ..write(t.condition)
        ..write(' ')
        ..write(t.make)
        ..write(' ')
        ..write(t.model)
        ..write(' ')
        ..write(t.trim)
        ..write(' ')
        ..write(t.doors.isNotEmpty ? '${t.doors} doors' : '')
        ..write(' ')
        ..write(t.bedLength)
        ..write(' ')
        ..write(t.cabStyle)
        ..write(' ')
        ..write(t.drivetrain)
        ..write(' ')
        ..write(t.exteriorColor)
        ..write(' ')
        ..write(t.notes)
        ..write(' ')
        ..write(t.features.join(' '));
    }
    for (final n in clientNotes) {
      buf
        ..write(' ')
        ..write(n.text);
    }
    return buf.toString().toLowerCase();
  }

  String get initials {
    final words =
        name.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    if (words.isEmpty) return '?';
    if (words.length == 1) return words.first.substring(0, 1).toUpperCase();
    return '${words.first[0]}${words.last[0]}'.toUpperCase();
  }
}

class VehicleMatch {
  final String id;
  final String guestId;
  final String vin;
  final String stockNumber;
  final String title;
  final int? year;
  final String make;
  final String model;
  final String trim;
  final String condition;
  final double? price;
  final double? msrp;
  final double? dealerFee;
  final String location;
  final int mileage;
  final String drivetrain;
  final String engine;
  final String exteriorColor;
  final String interiorColor;
  final String photoUrl;
  final String listingUrl;
  final List<String> matchedFeatures;
  final List<String> allHighlights;
  final String agentSummary;
  final int matchScore;
  final String foundAt;
  final String searchSlot;
  final String lastSeenAt;
  final String targetId;
  final String targetLabel;

  const VehicleMatch({
    required this.id,
    required this.guestId,
    required this.vin,
    this.stockNumber = '',
    required this.title,
    this.year,
    this.make = '',
    this.model = '',
    this.trim = '',
    this.condition = '',
    this.price,
    this.msrp,
    this.dealerFee,
    required this.location,
    this.mileage = 0,
    this.drivetrain = '',
    this.engine = '',
    this.exteriorColor = '',
    this.interiorColor = '',
    this.photoUrl = '',
    this.listingUrl = '',
    this.matchedFeatures = const [],
    this.allHighlights = const [],
    this.agentSummary = '',
    this.matchScore = 85,
    required this.foundAt,
    this.searchSlot = 'Scheduled Search',
    required this.lastSeenAt,
    this.targetId = '',
    this.targetLabel = '',
  });

  factory VehicleMatch.fromJson(Map<String, dynamic> json) {
    return VehicleMatch(
      id: json['id']?.toString() ?? '',
      guestId: json['guestId']?.toString() ?? '',
      vin: json['vin']?.toString() ?? '',
      stockNumber: json['stockNumber']?.toString() ?? '',
      title: json['title']?.toString() ?? '',
      year: (json['year'] as num?)?.toInt(),
      make: json['make']?.toString() ?? '',
      model: json['model']?.toString() ?? '',
      trim: json['trim']?.toString() ?? '',
      condition: json['condition']?.toString() ?? '',
      price: (json['price'] as num?)?.toDouble(),
      msrp: (json['msrp'] as num?)?.toDouble(),
      dealerFee: (json['dealerFee'] as num?)?.toDouble(),
      location: json['location']?.toString() ?? 'Preston Automotive Group',
      mileage: (json['mileage'] as num?)?.toInt() ?? 0,
      drivetrain: json['drivetrain']?.toString() ?? '',
      engine: json['engine']?.toString() ?? '',
      exteriorColor: json['exteriorColor']?.toString() ?? '',
      interiorColor: json['interiorColor']?.toString() ?? '',
      photoUrl: json['photoUrl']?.toString() ?? '',
      listingUrl: json['listingUrl']?.toString() ?? '',
      matchedFeatures: (json['matchedFeatures'] as List<dynamic>?)
              ?.map((e) => e.toString())
              .toList() ??
          const [],
      allHighlights: (json['allHighlights'] as List<dynamic>?)
              ?.map((e) => e.toString())
              .toList() ??
          const [],
      agentSummary: json['agentSummary']?.toString() ?? '',
      matchScore: (json['matchScore'] as num?)?.toInt() ?? 85,
      foundAt: json['foundAt']?.toString() ?? '',
      searchSlot: json['searchSlot']?.toString() ?? 'Scheduled Search',
      lastSeenAt: json['lastSeenAt']?.toString() ?? '',
      targetId: json['targetId']?.toString() ?? '',
      targetLabel: json['targetLabel']?.toString() ?? '',
    );
  }
}

class WidgetGuestEntry {
  final String id;
  final String name;
  final String targetSummary;
  final int matchCount;
  final String createdAt;

  const WidgetGuestEntry({
    required this.id,
    required this.name,
    required this.targetSummary,
    required this.matchCount,
    required this.createdAt,
  });

  factory WidgetGuestEntry.fromJson(Map<String, dynamic> json) {
    return WidgetGuestEntry(
      id: json['id']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      targetSummary: json['targetSummary']?.toString() ?? '',
      matchCount: (json['matchCount'] as num?)?.toInt() ?? 0,
      createdAt: json['createdAt']?.toString() ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'targetSummary': targetSummary,
        'matchCount': matchCount,
        'createdAt': createdAt,
      };
}

class SystemStatus {
  final int totalGuests;
  final int totalMatches;
  final String nextScheduledRunLabel;
  final String timeZone;
  final bool isRunning;
  final bool geminiConfigured;
  final String geminiModel;

  const SystemStatus({
    this.totalGuests = 0,
    this.totalMatches = 0,
    this.nextScheduledRunLabel = 'Today at 2:00 PM',
    this.timeZone = 'America/New_York',
    this.isRunning = false,
    this.geminiConfigured = false,
    this.geminiModel = 'gemini-2.5-flash',
  });

  factory SystemStatus.fromJson(Map<String, dynamic> json) {
    return SystemStatus(
      totalGuests: (json['totalGuests'] as num?)?.toInt() ?? 0,
      totalMatches: (json['totalMatches'] as num?)?.toInt() ?? 0,
      nextScheduledRunLabel:
          json['nextScheduledRunLabel']?.toString() ?? '7:30 AM & 2:00 PM Daily',
      timeZone: json['timeZone']?.toString() ?? 'America/New_York',
      isRunning: json['isRunning'] == true,
      geminiConfigured: json['geminiConfigured'] == true,
      geminiModel: json['geminiModel']?.toString() ?? 'gemini-2.5-flash',
    );
  }
}

class MatchAlertNotification {
  final String id;
  final String guestId;
  final String guestName;
  final String guestPhone;
  final String vin;
  final String vehicleModel;
  final String vehicleTitle;
  final String message;
  final String location;
  final double? price;
  final String createdAt;
  final bool read;

  const MatchAlertNotification({
    required this.id,
    required this.guestId,
    required this.guestName,
    this.guestPhone = '',
    required this.vin,
    required this.vehicleModel,
    this.vehicleTitle = '',
    required this.message,
    this.location = '',
    this.price,
    required this.createdAt,
    this.read = false,
  });

  /// Extracts a clean model label (e.g., "Ford F-250", "Lincoln Nautilus", "Ford Mustang")
  /// for the OS notification text: `"Client Name - Match Found - <Model>"`.
  static String extractVehicleModelLabel({
    String make = '',
    String model = '',
    String title = '',
  }) {
    final cleanMake = make.trim();
    final cleanModel = model.trim();
    if (cleanMake.isNotEmpty && cleanModel.isNotEmpty) {
      if (cleanModel.toLowerCase().startsWith(cleanMake.toLowerCase())) {
        return cleanModel;
      }
      return '$cleanMake $cleanModel';
    }
    if (cleanModel.isNotEmpty) return cleanModel;

    final cleanTitle = title.trim();
    if (cleanTitle.isNotEmpty) {
      final stripped = cleanTitle
          .replaceFirst(
            RegExp(
              r'^(?:new|used|pre-owned|certified(?:\s+pre-owned)?|cpo)\s+',
              caseSensitive: false,
            ),
            '',
          )
          .replaceFirst(RegExp(r'^\d{4}\s+'), '')
          .trim();
      if (stripped.isNotEmpty) return stripped;
      return cleanTitle;
    }

    if (cleanMake.isNotEmpty) return cleanMake;
    return 'Vehicle';
  }

  /// Formats the exact post-initial-search notification string:
  /// `"Client Name - Match Found - <Model of vehicle>"`
  static String formatMessage({
    required String clientName,
    String make = '',
    String model = '',
    String title = '',
  }) {
    final cleanClient =
        clientName.trim().isNotEmpty ? clientName.trim() : 'Client';
    final modelLabel = extractVehicleModelLabel(
      make: make,
      model: model,
      title: title,
    );
    return '$cleanClient - Match Found - $modelLabel';
  }

  factory MatchAlertNotification.fromJson(Map<String, dynamic> json) {
    final gName = json['guestName']?.toString() ?? 'Client';
    final vModel = json['vehicleModel']?.toString() ?? 'Vehicle';
    final rawMsg = (json['message']?.toString() ?? '').trim();
    return MatchAlertNotification(
      id: json['id']?.toString() ?? '',
      guestId: json['guestId']?.toString() ?? '',
      guestName: gName,
      guestPhone: json['guestPhone']?.toString() ?? '',
      vin: json['vin']?.toString() ?? '',
      vehicleModel: vModel,
      vehicleTitle: json['vehicleTitle']?.toString() ?? '',
      message: rawMsg.isNotEmpty
          ? rawMsg
          : '$gName - Match Found - $vModel',
      location: json['location']?.toString() ?? '',
      price: (json['price'] as num?)?.toDouble(),
      createdAt: json['createdAt']?.toString() ?? '',
      read: json['read'] == true,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'guestId': guestId,
        'guestName': guestName,
        'guestPhone': guestPhone,
        'vin': vin,
        'vehicleModel': vehicleModel,
        'vehicleTitle': vehicleTitle,
        'message': message,
        'location': location,
        'price': price,
        'createdAt': createdAt,
        'read': read,
      };

  MatchAlertNotification copyWith({bool? read}) {
    return MatchAlertNotification(
      id: id,
      guestId: guestId,
      guestName: guestName,
      guestPhone: guestPhone,
      vin: vin,
      vehicleModel: vehicleModel,
      vehicleTitle: vehicleTitle,
      message: message,
      location: location,
      price: price,
      createdAt: createdAt,
      read: read ?? this.read,
    );
  }
}

class CalendarCallEvent {
  final String id;
  final String guestId;
  final String guestName;
  final String guestPhone;
  final String eventDate;
  final String startAt;
  final String endAt;
  final String title;
  final String description;
  final String location;
  final String vehicleSummary;
  final String externalEventId;
  final String calendarLink;
  final String provider;
  final String createdAt;

  const CalendarCallEvent({
    required this.id,
    required this.guestId,
    required this.guestName,
    this.guestPhone = '',
    required this.eventDate,
    required this.startAt,
    required this.endAt,
    required this.title,
    this.description = '',
    this.location = '',
    this.vehicleSummary = '',
    this.externalEventId = '',
    this.calendarLink = '',
    this.provider = 'local',
    required this.createdAt,
  });

  /// Computes a same-day `"Call Guest"` slot strictly on [now]'s calendar day:
  /// - Early morning (`< 9:30 AM`, e.g. `7:30 AM` scan): `10:00 AM – 10:30 AM` today
  /// - Business hours (`9:30 AM – 5:00 PM`, e.g. `2:00 PM` scan): `now + 30 min` rounded up to 15 min
  /// - Evening (`5:00 PM – 11:15 PM`): `now + 15 min` rounded up to 5 min
  /// - Late night (`11:15 PM – 11:59 PM`): clamped strictly before `23:58` on the same day
  static ({String eventDate, DateTime startLocal, DateTime endLocal})
      computeSameDaySlot(DateTime now) {
    final local = now.toLocal();
    final dateStr =
        '${local.year.toString().padLeft(4, '0')}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')}';
    final nowMin = local.hour * 60 + local.minute;

    int startMin;
    int durationMin = 30;
    if (nowMin < 9 * 60 + 30) {
      startMin = 10 * 60; // 10:00 AM same day
    } else if (nowMin <= 17 * 60) {
      final plus30 = nowMin + 30;
      startMin = ((plus30 + 14) ~/ 15) * 15;
    } else if (nowMin <= 23 * 60 + 15) {
      final plus15 = nowMin + 15;
      startMin = ((plus15 + 4) ~/ 5) * 5;
    } else {
      startMin = nowMin + 1 <= 23 * 60 + 45 ? nowMin + 1 : 23 * 60 + 45;
      final remaining = (23 * 60 + 58) - startMin;
      durationMin = remaining >= 10 ? remaining : 10;
    }

    final startLocal = DateTime(
      local.year,
      local.month,
      local.day,
      startMin ~/ 60,
      startMin % 60,
    );
    final rawEnd = startLocal.add(Duration(minutes: durationMin));
    final maxSameDayEnd = DateTime(local.year, local.month, local.day, 23, 58);
    final endLocal =
        rawEnd.isAfter(maxSameDayEnd) ? maxSameDayEnd : rawEnd;

    return (
      eventDate: dateStr,
      startLocal: startLocal,
      endLocal: endLocal,
    );
  }

  static String buildCallTitle({
    required String clientName,
    required List<Map<String, dynamic>> matchedVehicles,
  }) {
    final cleanName =
        clientName.trim().isNotEmpty ? clientName.trim() : 'Client';
    final first =
        matchedVehicles.isNotEmpty ? matchedVehicles.first : const <String, dynamic>{};
    final primaryModel = MatchAlertNotification.extractVehicleModelLabel(
      make: first['make']?.toString() ?? '',
      model: first['model']?.toString() ?? '',
      title: first['title']?.toString() ?? '',
    );
    if (matchedVehicles.length > 1) {
      return 'Call $cleanName — ${matchedVehicles.length} Vehicle Matches Found ($primaryModel)';
    }
    return 'Call $cleanName — Match Found: $primaryModel';
  }

  static String buildCallDescription({
    required GuestProfile guest,
    required List<Map<String, dynamic>> matchedVehicles,
  }) {
    final lines = <String>[
      'Same-day follow-up call scheduled automatically by Preston Motor Guest Scout.',
      '',
      'Client: ${guest.name}',
      if (guest.phone.trim().isNotEmpty) 'Phone: ${guest.phone.trim()}',
      if (guest.email.trim().isNotEmpty) 'Email: ${guest.email.trim()}',
      if (guest.latestClientNote != null)
        'Latest Client Note: ${guest.latestClientNote!.text}',
      '',
      'Matched Vehicle(s) Found Today (${matchedVehicles.length}):',
    ];
    for (final v in matchedVehicles.take(8)) {
      final p = (v['price'] as num?)?.toDouble();
      final priceStr =
          p != null && p > 0 ? '\$${p.toStringAsFixed(0)}' : 'Call for Price';
      final loc = (v['location']?.toString() ?? '').trim().isNotEmpty
          ? v['location'].toString().trim()
          : 'Preston Automotive Group';
      final titleStr = (v['title']?.toString() ?? '').trim().isNotEmpty
          ? v['title'].toString().trim()
          : MatchAlertNotification.extractVehicleModelLabel(
              make: v['make']?.toString() ?? '',
              model: v['model']?.toString() ?? '',
            );
      lines.add('• $titleStr — $priceStr at $loc');
      final url = (v['listingUrl']?.toString() ?? '').trim();
      if (url.isNotEmpty) {
        lines.add('  $url');
      }
    }
    return lines.join('\n');
  }

  factory CalendarCallEvent.fromJson(Map<String, dynamic> json) {
    return CalendarCallEvent(
      id: json['id']?.toString() ?? '',
      guestId: json['guestId']?.toString() ?? '',
      guestName: json['guestName']?.toString() ?? 'Client',
      guestPhone: json['guestPhone']?.toString() ?? '',
      eventDate: json['eventDate']?.toString() ?? '',
      startAt: json['startAt']?.toString() ?? '',
      endAt: json['endAt']?.toString() ?? '',
      title: json['title']?.toString() ?? 'Call Guest — Vehicle Match Found',
      description: json['description']?.toString() ?? '',
      location: json['location']?.toString() ?? '',
      vehicleSummary: json['vehicleSummary']?.toString() ?? '',
      externalEventId: json['externalEventId']?.toString() ?? '',
      calendarLink: json['calendarLink']?.toString() ?? '',
      provider: json['provider']?.toString() ?? 'local',
      createdAt: json['createdAt']?.toString() ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'guestId': guestId,
        'guestName': guestName,
        'guestPhone': guestPhone,
        'eventDate': eventDate,
        'startAt': startAt,
        'endAt': endAt,
        'title': title,
        'description': description,
        'location': location,
        'vehicleSummary': vehicleSummary,
        'externalEventId': externalEventId,
        'calendarLink': calendarLink,
        'provider': provider,
        'createdAt': createdAt,
      };

  CalendarCallEvent copyWith({
    String? title,
    String? description,
    String? location,
    String? vehicleSummary,
  }) {
    return CalendarCallEvent(
      id: id,
      guestId: guestId,
      guestName: guestName,
      guestPhone: guestPhone,
      eventDate: eventDate,
      startAt: startAt,
      endAt: endAt,
      title: title ?? this.title,
      description: description ?? this.description,
      location: location ?? this.location,
      vehicleSummary: vehicleSummary ?? this.vehicleSummary,
      externalEventId: externalEventId,
      calendarLink: calendarLink,
      provider: provider,
      createdAt: createdAt,
    );
  }
}

enum BackupConflictResolution {
  overwrite,
  duplicate;

  String get wireValue => name;

  static BackupConflictResolution? fromWire(String? raw) {
    final lower = (raw ?? '').trim().toLowerCase();
    if (lower == 'overwrite') return BackupConflictResolution.overwrite;
    if (lower == 'duplicate') return BackupConflictResolution.duplicate;
    return null;
  }
}

class BackupGuestPreview {
  final String id;
  final String name;
  final String phone;
  final String email;
  final String targetSummary;
  final int noteCount;
  final int matchCount;

  const BackupGuestPreview({
    required this.id,
    required this.name,
    this.phone = '',
    this.email = '',
    this.targetSummary = '',
    this.noteCount = 0,
    this.matchCount = 0,
  });

  factory BackupGuestPreview.fromJson(Map<String, dynamic> json) {
    return BackupGuestPreview(
      id: json['id']?.toString() ?? '',
      name: json['name']?.toString() ?? 'Guest',
      phone: json['phone']?.toString() ?? '',
      email: json['email']?.toString() ?? '',
      targetSummary: json['targetSummary']?.toString() ?? '',
      noteCount: (json['noteCount'] as num?)?.toInt() ?? 0,
      matchCount: (json['matchCount'] as num?)?.toInt() ?? 0,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'phone': phone,
        'email': email,
        'targetSummary': targetSummary,
        'noteCount': noteCount,
        'matchCount': matchCount,
      };
}

class BackupEntry {
  final String id;
  final String createdAt;
  final String label;
  final String deviceLabel;
  final int guestCount;
  final int matchCount;
  final List<BackupGuestPreview> guestsPreview;

  const BackupEntry({
    required this.id,
    required this.createdAt,
    required this.label,
    this.deviceLabel = '',
    this.guestCount = 0,
    this.matchCount = 0,
    this.guestsPreview = const [],
  });

  factory BackupEntry.fromJson(Map<String, dynamic> json) {
    return BackupEntry(
      id: json['id']?.toString() ?? '',
      createdAt: json['createdAt']?.toString() ?? '',
      label: json['label']?.toString() ?? 'Data Backup',
      deviceLabel: json['deviceLabel']?.toString() ?? '',
      guestCount: (json['guestCount'] as num?)?.toInt() ?? 0,
      matchCount: (json['matchCount'] as num?)?.toInt() ?? 0,
      guestsPreview: (json['guestsPreview'] as List<dynamic>? ?? [])
          .whereType<Map>()
          .map((e) => BackupGuestPreview.fromJson(Map<String, dynamic>.from(e)))
          .toList(),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'createdAt': createdAt,
        'label': label,
        'deviceLabel': deviceLabel,
        'guestCount': guestCount,
        'matchCount': matchCount,
        'guestsPreview': guestsPreview.map((g) => g.toJson()).toList(),
      };
}

class BackupConflictPreview {
  final BackupEntry backup;
  final bool hasConflicts;
  final List<String> conflictingGuestNames;
  final List<String> modifiedConflictNames;
  final List<String> nonConflictingGuestNames;

  const BackupConflictPreview({
    required this.backup,
    required this.hasConflicts,
    this.conflictingGuestNames = const [],
    this.modifiedConflictNames = const [],
    this.nonConflictingGuestNames = const [],
  });

  factory BackupConflictPreview.fromJson(Map<String, dynamic> json) {
    return BackupConflictPreview(
      backup: BackupEntry.fromJson(
        Map<String, dynamic>.from(json['backup'] as Map? ?? const {}),
      ),
      hasConflicts: json['hasConflicts'] == true,
      conflictingGuestNames:
          (json['conflictingGuestNames'] as List<dynamic>? ?? [])
              .map((e) => e.toString())
              .where((s) => s.isNotEmpty)
              .toList(),
      modifiedConflictNames:
          (json['modifiedConflictNames'] as List<dynamic>? ?? [])
              .map((e) => e.toString())
              .where((s) => s.isNotEmpty)
              .toList(),
      nonConflictingGuestNames:
          (json['nonConflictingGuestNames'] as List<dynamic>? ?? [])
              .map((e) => e.toString())
              .where((s) => s.isNotEmpty)
              .toList(),
    );
  }

  Map<String, dynamic> toJson() => {
        'backup': backup.toJson(),
        'hasConflicts': hasConflicts,
        'conflictingGuestNames': conflictingGuestNames,
        'modifiedConflictNames': modifiedConflictNames,
        'nonConflictingGuestNames': nonConflictingGuestNames,
      };
}

class BackupRestoreResult {
  final String backupId;
  final String resolution;
  final int restoredGuests;
  final int overwrittenGuests;
  final int duplicatedGuests;
  final int totalGuests;
  final int totalMatches;
  final String summary;

  const BackupRestoreResult({
    required this.backupId,
    required this.resolution,
    this.restoredGuests = 0,
    this.overwrittenGuests = 0,
    this.duplicatedGuests = 0,
    this.totalGuests = 0,
    this.totalMatches = 0,
    this.summary = '',
  });

  factory BackupRestoreResult.fromJson(Map<String, dynamic> json) {
    return BackupRestoreResult(
      backupId: json['backupId']?.toString() ?? '',
      resolution: json['resolution']?.toString() ?? 'none',
      restoredGuests: (json['restoredGuests'] as num?)?.toInt() ?? 0,
      overwrittenGuests: (json['overwrittenGuests'] as num?)?.toInt() ?? 0,
      duplicatedGuests: (json['duplicatedGuests'] as num?)?.toInt() ?? 0,
      totalGuests: (json['totalGuests'] as num?)?.toInt() ?? 0,
      totalMatches: (json['totalMatches'] as num?)?.toInt() ?? 0,
      summary: json['summary']?.toString() ?? 'Backup loaded.',
    );
  }

  Map<String, dynamic> toJson() => {
        'backupId': backupId,
        'resolution': resolution,
        'restoredGuests': restoredGuests,
        'overwrittenGuests': overwrittenGuests,
        'duplicatedGuests': duplicatedGuests,
        'totalGuests': totalGuests,
        'totalMatches': totalMatches,
        'summary': summary,
      };
}

class DecodedVinVehicle {
  final String vin;
  final int? year;
  final String make;
  final String model;
  final String trim;
  final String series;
  final String bodyClass;
  final String driveType;
  final String engine;
  final String displacementL;
  final String cylinders;
  final String fuelType;
  final String doors;
  final String plant;
  final String manufacturer;

  const DecodedVinVehicle({
    required this.vin,
    this.year,
    this.make = '',
    this.model = '',
    this.trim = '',
    this.series = '',
    this.bodyClass = '',
    this.driveType = '',
    this.engine = '',
    this.displacementL = '',
    this.cylinders = '',
    this.fuelType = '',
    this.doors = '',
    this.plant = '',
    this.manufacturer = '',
  });

  factory DecodedVinVehicle.fromJson(Map<String, dynamic> json) {
    return DecodedVinVehicle(
      vin: json['vin']?.toString() ?? '',
      year: (json['year'] as num?)?.toInt(),
      make: json['make']?.toString() ?? '',
      model: json['model']?.toString() ?? '',
      trim: json['trim']?.toString() ?? '',
      series: json['series']?.toString() ?? '',
      bodyClass: json['bodyClass']?.toString() ?? '',
      driveType: json['driveType']?.toString() ?? '',
      engine: json['engine']?.toString() ?? '',
      displacementL: json['displacementL']?.toString() ?? '',
      cylinders: json['cylinders']?.toString() ?? '',
      fuelType: json['fuelType']?.toString() ?? '',
      doors: json['doors']?.toString() ?? '',
      plant: json['plant']?.toString() ?? '',
      manufacturer: json['manufacturer']?.toString() ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
        'vin': vin,
        'year': year,
        'make': make,
        'model': model,
        'trim': trim,
        'series': series,
        'bodyClass': bodyClass,
        'driveType': driveType,
        'engine': engine,
        'displacementL': displacementL,
        'cylinders': cylinders,
        'fuelType': fuelType,
        'doors': doors,
        'plant': plant,
        'manufacturer': manufacturer,
      };
}

class NhtsaRecallCampaign {
  final String campaignNumber;
  final String oemRecallNumber;
  final String manufacturer;
  final String component;
  final String reportDate;
  final String reportIsoDate;
  final String summary;
  final String consequence;
  final String remedy;
  final String notes;
  final bool parkIt;
  final bool parkOutSide;
  final bool overTheAirUpdate;
  final String nhtsaModelMatched;
  final String applicability;
  final String geminiNote;
  final String completionStatus;
  final String completionSource;
  final bool remedyAvailable;
  final String vinStatusNote;

  const NhtsaRecallCampaign({
    required this.campaignNumber,
    this.oemRecallNumber = '',
    this.manufacturer = '',
    this.component = 'Vehicle Safety System',
    this.reportDate = '',
    this.reportIsoDate = '',
    this.summary = '',
    this.consequence = '',
    this.remedy = '',
    this.notes = '',
    this.parkIt = false,
    this.parkOutSide = false,
    this.overTheAirUpdate = false,
    this.nhtsaModelMatched = '',
    this.applicability = 'Matches Decoded Vehicle',
    this.geminiNote = '',
    this.completionStatus = 'incomplete',
    this.completionSource = 'vin_live_lookup',
    this.remedyAvailable = true,
    this.vinStatusNote = '',
  });

  bool get isOtherVariant =>
      completionStatus == 'not_applicable' ||
      RegExp(r'other\s+(?:engine|powertrain)', caseSensitive: false)
          .hasMatch(applicability);

  bool get isComplete => completionStatus == 'complete';

  bool get isIncomplete =>
      !isComplete &&
      !isOtherVariant &&
      (completionStatus == 'incomplete' ||
          completionStatus == 'incomplete_no_remedy' ||
          completionStatus == 'unverified');

  bool get isRemedyUnavailable =>
      completionStatus == 'incomplete_no_remedy' || !remedyAvailable;

  bool get isManualOverride => completionSource == 'dealer_override';

  String get completionBadgeLabel {
    if (isComplete) return 'COMPLETE • CLOSED ON VIN';
    if (isOtherVariant) return 'OTHER POWERTRAIN VARIANT';
    if (completionStatus == 'incomplete_no_remedy') {
      return 'INCOMPLETE • REMEDY NOT AVAILABLE';
    }
    if (completionStatus == 'unverified') {
      return 'INCOMPLETE • VERIFY ON VIN';
    }
    return 'INCOMPLETE • OPEN RECALL';
  }

  NhtsaRecallCampaign copyWith({
    String? oemRecallNumber,
    String? applicability,
    String? geminiNote,
    String? completionStatus,
    String? completionSource,
    bool? remedyAvailable,
    String? vinStatusNote,
  }) {
    return NhtsaRecallCampaign(
      campaignNumber: campaignNumber,
      oemRecallNumber: oemRecallNumber ?? this.oemRecallNumber,
      manufacturer: manufacturer,
      component: component,
      reportDate: reportDate,
      reportIsoDate: reportIsoDate,
      summary: summary,
      consequence: consequence,
      remedy: remedy,
      notes: notes,
      parkIt: parkIt,
      parkOutSide: parkOutSide,
      overTheAirUpdate: overTheAirUpdate,
      nhtsaModelMatched: nhtsaModelMatched,
      applicability: applicability ?? this.applicability,
      geminiNote: geminiNote ?? this.geminiNote,
      completionStatus: completionStatus ?? this.completionStatus,
      completionSource: completionSource ?? this.completionSource,
      remedyAvailable: remedyAvailable ?? this.remedyAvailable,
      vinStatusNote: vinStatusNote ?? this.vinStatusNote,
    );
  }

  factory NhtsaRecallCampaign.fromJson(Map<String, dynamic> json) {
    final applicabilityStr =
        json['applicability']?.toString() ?? 'Matches Decoded Vehicle';
    final isOther = RegExp(
      r'other\s+(?:engine|powertrain)',
      caseSensitive: false,
    ).hasMatch(applicabilityStr);
    final rawStatus = (json['completionStatus']?.toString() ?? '').trim();
    final resolvedStatus = rawStatus.isNotEmpty
        ? rawStatus
        : (isOther ? 'not_applicable' : 'incomplete');

    return NhtsaRecallCampaign(
      campaignNumber: json['campaignNumber']?.toString() ?? '',
      oemRecallNumber: json['oemRecallNumber']?.toString() ?? '',
      manufacturer: json['manufacturer']?.toString() ?? '',
      component: json['component']?.toString() ?? 'Vehicle Safety System',
      reportDate: json['reportDate']?.toString() ?? '',
      reportIsoDate: json['reportIsoDate']?.toString() ?? '',
      summary: json['summary']?.toString() ?? '',
      consequence: json['consequence']?.toString() ?? '',
      remedy: json['remedy']?.toString() ?? '',
      notes: json['notes']?.toString() ?? '',
      parkIt: json['parkIt'] == true,
      parkOutSide: json['parkOutSide'] == true,
      overTheAirUpdate: json['overTheAirUpdate'] == true,
      nhtsaModelMatched: json['nhtsaModelMatched']?.toString() ?? '',
      applicability: applicabilityStr,
      geminiNote: json['geminiNote']?.toString() ?? '',
      completionStatus: resolvedStatus,
      completionSource:
          json['completionSource']?.toString() ?? 'vin_live_lookup',
      remedyAvailable: json['remedyAvailable'] != false,
      vinStatusNote: json['vinStatusNote']?.toString() ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
        'campaignNumber': campaignNumber,
        'oemRecallNumber': oemRecallNumber,
        'manufacturer': manufacturer,
        'component': component,
        'reportDate': reportDate,
        'reportIsoDate': reportIsoDate,
        'summary': summary,
        'consequence': consequence,
        'remedy': remedy,
        'notes': notes,
        'parkIt': parkIt,
        'parkOutSide': parkOutSide,
        'overTheAirUpdate': overTheAirUpdate,
        'nhtsaModelMatched': nhtsaModelMatched,
        'applicability': applicability,
        'geminiNote': geminiNote,
        'completionStatus': completionStatus,
        'completionSource': completionSource,
        'remedyAvailable': remedyAvailable,
        'vinStatusNote': vinStatusNote,
      };
}

class VinRecallCheckResult {
  final String id;
  final String vin;
  final String nhtsaUrl;
  final bool nhtsaSiteReachable;
  final bool vinCompletionVerified;
  final String checkedAt;
  final String agentMode;
  final String vehicleTitle;
  final DecodedVinVehicle vehicle;
  final List<String> queriedModels;
  final bool hasRecalls;
  final int recallCount;
  final int incompleteCount;
  final int completeCount;
  final int totalModelRecalls;
  final bool parkItUrgent;
  final bool parkOutsideWarning;
  final String verdictHeadline;
  final String geminiSummary;
  final String recommendedAction;
  final List<NhtsaRecallCampaign> recalls;

  VinRecallCheckResult({
    required this.id,
    required this.vin,
    required this.nhtsaUrl,
    this.nhtsaSiteReachable = true,
    this.vinCompletionVerified = true,
    required this.checkedAt,
    this.agentMode = 'gemini',
    required this.vehicleTitle,
    required this.vehicle,
    this.queriedModels = const [],
    required this.hasRecalls,
    required this.recallCount,
    int? incompleteCount,
    int? completeCount,
    this.totalModelRecalls = 0,
    this.parkItUrgent = false,
    this.parkOutsideWarning = false,
    required this.verdictHeadline,
    required this.geminiSummary,
    required this.recommendedAction,
    this.recalls = const [],
  })  : incompleteCount = incompleteCount ??
            (recalls.isNotEmpty
                ? recalls.where((r) => r.isIncomplete).length
                : (hasRecalls ? recallCount : 0)),
        completeCount = completeCount ??
            recalls.where((r) => r.isComplete).length;

  factory VinRecallCheckResult.fromJson(Map<String, dynamic> json) {
    final recallsRaw = (json['recalls'] as List<dynamic>? ?? [])
        .whereType<Map>()
        .map((e) => NhtsaRecallCampaign.fromJson(Map<String, dynamic>.from(e)))
        .toList();
    final vinStr = json['vin']?.toString() ?? '';
    final computedInc = recallsRaw.where((r) => r.isIncomplete).length;
    final computedComp = recallsRaw.where((r) => r.isComplete).length;
    final incCount = (json['incompleteCount'] as num?)?.toInt() ??
        (recallsRaw.isNotEmpty
            ? computedInc
            : ((json['hasRecalls'] == true)
                ? ((json['recallCount'] as num?)?.toInt() ?? 0)
                : 0));
    final compCount = (json['completeCount'] as num?)?.toInt() ?? computedComp;
    final openRecalls = recallsRaw.where((r) => r.isIncomplete).toList();

    return VinRecallCheckResult(
      id: json['id']?.toString() ?? '',
      vin: vinStr,
      nhtsaUrl: json['nhtsaUrl']?.toString() ??
          'https://www.nhtsa.gov/recalls?vin=${Uri.encodeComponent(vinStr)}',
      nhtsaSiteReachable: json['nhtsaSiteReachable'] != false,
      vinCompletionVerified: json['vinCompletionVerified'] != false,
      checkedAt: json['checkedAt']?.toString() ?? '',
      agentMode: json['agentMode']?.toString() ?? 'gemini',
      vehicleTitle: json['vehicleTitle']?.toString() ?? vinStr,
      vehicle: DecodedVinVehicle.fromJson(
        Map<String, dynamic>.from(json['vehicle'] as Map? ?? {'vin': vinStr}),
      ),
      queriedModels: (json['queriedModels'] as List<dynamic>? ?? [])
          .map((e) => e.toString())
          .where((s) => s.isNotEmpty)
          .toList(),
      hasRecalls: json['hasRecalls'] != null
          ? json['hasRecalls'] == true
          : incCount > 0,
      recallCount: (json['recallCount'] as num?)?.toInt() ?? incCount,
      incompleteCount: incCount,
      completeCount: compCount,
      totalModelRecalls:
          (json['totalModelRecalls'] as num?)?.toInt() ?? recallsRaw.length,
      parkItUrgent: json['parkItUrgent'] == true ||
          openRecalls.any((r) => r.parkIt),
      parkOutsideWarning: json['parkOutsideWarning'] == true ||
          openRecalls.any((r) => r.parkOutSide),
      verdictHeadline: json['verdictHeadline']?.toString() ?? '',
      geminiSummary: json['geminiSummary']?.toString() ?? '',
      recommendedAction: json['recommendedAction']?.toString() ?? '',
      recalls: recallsRaw,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'vin': vin,
        'nhtsaUrl': nhtsaUrl,
        'nhtsaSiteReachable': nhtsaSiteReachable,
        'vinCompletionVerified': vinCompletionVerified,
        'checkedAt': checkedAt,
        'agentMode': agentMode,
        'vehicleTitle': vehicleTitle,
        'vehicle': vehicle.toJson(),
        'queriedModels': queriedModels,
        'hasRecalls': hasRecalls,
        'recallCount': recallCount,
        'incompleteCount': incompleteCount,
        'completeCount': completeCount,
        'totalModelRecalls': totalModelRecalls,
        'parkItUrgent': parkItUrgent,
        'parkOutsideWarning': parkOutsideWarning,
        'verdictHeadline': verdictHeadline,
        'geminiSummary': geminiSummary,
        'recommendedAction': recommendedAction,
        'recalls': recalls.map((r) => r.toJson()).toList(),
      };
}

class RecentVinRecallEntry {
  final String vin;
  final String vehicleTitle;
  final bool hasRecalls;
  final int recallCount;
  final int incompleteCount;
  final int completeCount;
  final String verdictHeadline;
  final String checkedAt;

  const RecentVinRecallEntry({
    required this.vin,
    required this.vehicleTitle,
    required this.hasRecalls,
    required this.recallCount,
    int? incompleteCount,
    this.completeCount = 0,
    this.verdictHeadline = '',
    required this.checkedAt,
  }) : incompleteCount = incompleteCount ?? (hasRecalls ? recallCount : 0);

  factory RecentVinRecallEntry.fromJson(Map<String, dynamic> json) {
    final vinStr = json['vin']?.toString() ?? '';
    final hasRec = json['hasRecalls'] == true;
    final recCount = (json['recallCount'] as num?)?.toInt() ?? 0;
    return RecentVinRecallEntry(
      vin: vinStr,
      vehicleTitle: json['vehicleTitle']?.toString() ?? vinStr,
      hasRecalls: hasRec,
      recallCount: recCount,
      incompleteCount:
          (json['incompleteCount'] as num?)?.toInt() ?? (hasRec ? recCount : 0),
      completeCount: (json['completeCount'] as num?)?.toInt() ?? 0,
      verdictHeadline: json['verdictHeadline']?.toString() ?? '',
      checkedAt: json['checkedAt']?.toString() ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
        'vin': vin,
        'vehicleTitle': vehicleTitle,
        'hasRecalls': hasRecalls,
        'recallCount': recallCount,
        'incompleteCount': incompleteCount,
        'completeCount': completeCount,
        'verdictHeadline': verdictHeadline,
        'checkedAt': checkedAt,
      };
}


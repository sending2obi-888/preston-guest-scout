class VehicleSearchTarget {
  final String id;
  final String condition;
  final int? minYear;
  final int? maxYear;
  final String make;
  final String model;
  final String trim;
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
    this.maxPrice,
    this.maxMileage,
    this.drivetrain = 'Any',
    this.exteriorColor = '',
    this.features = const [],
    this.notes = '',
    this.createdAt = '',
  });

  factory VehicleSearchTarget.fromJson(Map<String, dynamic> json) {
    return VehicleSearchTarget(
      id: json['id']?.toString() ?? '',
      condition: json['condition']?.toString() ?? 'Any',
      minYear: (json['minYear'] as num?)?.toInt(),
      maxYear: (json['maxYear'] as num?)?.toInt(),
      make: json['make']?.toString() ?? '',
      model: json['model']?.toString() ?? '',
      trim: json['trim']?.toString() ?? '',
      maxPrice: (json['maxPrice'] as num?)?.toDouble(),
      maxMileage: (json['maxMileage'] as num?)?.toInt(),
      drivetrain: json['drivetrain']?.toString() ?? 'Any',
      exteriorColor: json['exteriorColor']?.toString() ?? '',
      features: (json['features'] as List<dynamic>?)
              ?.map((e) => e.toString())
              .toList() ??
          const [],
      notes: json['notes']?.toString() ?? '',
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
    if (parts.isEmpty) {
      if (maxPrice != null) {
        return 'Vehicles under \$${maxPrice!.toStringAsFixed(0)}';
      }
      if (notes.trim().isNotEmpty) {
        final trimmed = notes.trim();
        return trimmed.length > 42 ? '${trimmed.substring(0, 42)}…' : trimmed;
      }
      return 'Custom Vehicle Requirements';
    }
    return parts.join(' ');
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
  final double? maxPrice;
  final int? maxMileage;
  final String drivetrain;
  final String exteriorColor;
  final List<String> features;
  final String notes;
  final List<VehicleSearchTarget> vehicleTargets;
  final List<GuestNote> clientNotes;
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
    this.maxPrice,
    this.maxMileage,
    this.drivetrain = 'Any',
    this.exteriorColor = '',
    this.features = const [],
    this.notes = '',
    this.vehicleTargets = const [],
    this.clientNotes = const [],
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
        VehicleSearchTarget(
          id: guestId.isNotEmpty ? '$guestId-primary' : 'primary',
          condition: json['condition']?.toString() ?? 'Any',
          minYear: (json['minYear'] as num?)?.toInt(),
          maxYear: (json['maxYear'] as num?)?.toInt(),
          make: json['make']?.toString() ?? '',
          model: json['model']?.toString() ?? '',
          trim: json['trim']?.toString() ?? '',
          maxPrice: (json['maxPrice'] as num?)?.toDouble(),
          maxMileage: (json['maxMileage'] as num?)?.toInt(),
          drivetrain: json['drivetrain']?.toString() ?? 'Any',
          exteriorColor: json['exteriorColor']?.toString() ?? '',
          features: primaryFeatures,
          notes: json['notes']?.toString() ?? '',
          createdAt: createdAtStr,
        ),
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
      maxPrice: first.maxPrice,
      maxMileage: first.maxMileage,
      drivetrain: first.drivetrain,
      exteriorColor: first.exteriorColor,
      features: first.features,
      notes: first.notes,
      vehicleTargets: parsedTargets,
      clientNotes: parsedNotes,
      active: json['active'] != false,
      lastSearchedAt: json['lastSearchedAt']?.toString(),
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
      VehicleSearchTarget(
        id: id.isNotEmpty ? '$id-primary' : 'primary',
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
        createdAt: createdAt,
      ),
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

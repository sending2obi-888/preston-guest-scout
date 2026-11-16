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
    this.active = true,
    this.lastSearchedAt,
    this.lastSearchSummary = '',
    required this.createdAt,
    this.matchCount = 0,
    this.lowestMatchPrice,
  });

  factory GuestProfile.fromJson(Map<String, dynamic> json) {
    return GuestProfile(
      id: json['id']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      phone: json['phone']?.toString() ?? '',
      email: json['email']?.toString() ?? '',
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
      active: json['active'] != false,
      lastSearchedAt: json['lastSearchedAt']?.toString(),
      lastSearchSummary: json['lastSearchSummary']?.toString() ?? '',
      createdAt: json['createdAt']?.toString() ?? '',
      matchCount: (json['matchCount'] as num?)?.toInt() ?? 0,
      lowestMatchPrice: (json['lowestMatchPrice'] as num?)?.toDouble(),
    );
  }

  String get targetVehicleLabel {
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
    if (parts.isEmpty) return 'Custom Vehicle Requirements';
    return parts.join(' ');
  }

  String get initials {
    final words = name.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
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

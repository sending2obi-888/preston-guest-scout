import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:preston_guest_scout/models/models.dart';
import 'package:preston_guest_scout/screens/match_detail_screen.dart';
import 'package:preston_guest_scout/services/google_drive_sync_service.dart';
import 'package:preston_guest_scout/services/local_engine.dart';

void main() {
  test('GuestProfile targetVehicleLabel formats year range, make, model, and trim', () {
    const guest = GuestProfile(
      id: 'g-1',
      name: 'Rhonda Vanvorst',
      condition: 'Pre-Owned',
      minYear: 2022,
      maxYear: 2024,
      make: 'Lincoln',
      model: 'Nautilus',
      trim: 'Reserve',
      createdAt: '2026-11-14T12:00:00Z',
    );
    expect(guest.targetVehicleLabel, 'Pre-Owned 2022–2024 Lincoln Nautilus Reserve');
    expect(guest.initials, 'RV');
  });

  test('LocalScoutEngine normalizes Ford under \$60K and preserves all Millsboro matches without 25-cap', () {
    final fromNotes = LocalScoutEngine.normalizeSpecsForTest({
      'notes': 'Ford under \$60K',
    });
    expect(fromNotes['make'], 'Ford');
    expect(fromNotes['maxPrice'], 60000.0);

    final fromShorthand = LocalScoutEngine.normalizeSpecsForTest({
      'make': 'Ford',
      'maxPrice': 60,
    });
    expect(fromShorthand['maxPrice'], 60000.0);

    const guest = GuestProfile(
      id: 'g-ford',
      name: 'Test Ford Guest',
      make: 'Ford',
      maxPrice: 60000,
      createdAt: '2026-11-16T00:00:00Z',
    );

    final candidates = List.generate(120, (i) {
      final isMillsboro = i >= 80;
      return <String, dynamic>{
        'vin': '1FTFW1E50TFA${i.toString().padLeft(5, '0')}',
        'title': '2026 Ford F-150 XLT',
        'year': 2026,
        'make': 'Ford',
        'model': 'F-150',
        'trim': 'XLT',
        'condition': 'New',
        'price': 48500.0 + i * 50,
        'msrp': 52000.0,
        'location': isMillsboro
            ? 'Boulevard Ford Lewes (Millsboro, DE)'
            : 'Preston Ford Hurlock, MD',
        'dealerCity': isMillsboro ? 'Millsboro' : 'Hurlock',
        'dealerState': isMillsboro ? 'DE' : 'MD',
        'mileage': 12,
        'drivetrain': '4WD',
        'highlights': ['Apple CarPlay', 'Backup Camera', 'Tow Hitch'],
        'commentsSummary': 'Available now.',
      };
    });

    final matches = LocalScoutEngine.evaluateAllForTest(guest, candidates);
    expect(matches.length, 120);
    final millsboroMatches = matches.where((m) =>
        ((m['vehicle'] as Map)['location'] as String).contains('Millsboro'));
    expect(millsboroMatches.length, 40);
  });

  testWidgets('MatchDetailScreen displays Price, Location, Date Found, and Matched Features',
      (WidgetTester tester) async {
    const guest = GuestProfile(
      id: 'g-1',
      name: 'Rhonda Vanvorst',
      condition: 'Pre-Owned',
      make: 'Lincoln',
      model: 'Nautilus',
      createdAt: '2026-11-14T12:00:00Z',
    );

    const match = VehicleMatch(
      id: 'm-1',
      guestId: 'g-1',
      vin: '2LMPJ8KP3LBL00851',
      stockNumber: 'GLM26149A',
      title: '2020 Lincoln Nautilus Reserve',
      price: 19500,
      location: 'Boulevard Ford of Millsboro',
      foundAt: '2026-11-14T15:30:00Z',
      searchSlot: '7:30 AM Daily Search',
      lastSeenAt: '2026-11-14T15:30:00Z',
      matchedFeatures: [
        'AWD Drivetrain',
        'Reserve Trim Package',
        'Apple CarPlay & Navigation',
      ],
      agentSummary: 'Verified match at Boulevard Ford of Millsboro.',
    );

    await tester.pumpWidget(
      const MaterialApp(
        home: MatchDetailScreen(match: match, guest: guest),
      ),
    );

    expect(find.text('\$19,500'), findsOneWidget);
    expect(find.text('Boulevard Ford of Millsboro'), findsOneWidget);
    expect(find.textContaining('7:30 AM Daily Search'), findsOneWidget);
    expect(find.text('AWD Drivetrain'), findsOneWidget);
    expect(find.text('Reserve Trim Package'), findsOneWidget);
    expect(find.text('Apple CarPlay & Navigation'), findsOneWidget);
  });

  test('Multi-device Google Drive sync merges guests, matches, and delete tombstones cleanly', () {
    final deviceA = <String, dynamic>{
      'schemaVersion': 2,
      'guests': [
        {
          'id': 'guest-a',
          'name': 'Alex Chromebook',
          'make': 'Ford',
          'maxPrice': 60000.0,
          'createdAt': '2026-11-16T08:00:00Z',
          'updatedAt': '2026-11-16T08:00:00Z',
        },
        {
          'id': 'guest-deleted-later',
          'name': 'Old Guest',
          'make': 'Mazda',
          'createdAt': '2026-11-16T07:00:00Z',
          'updatedAt': '2026-11-16T07:00:00Z',
        },
      ],
      'deletedGuestIds': <String, String>{},
      'matches': [
        {
          'id': 'm-a1',
          'guestId': 'guest-a',
          'vin': '1FTFW1E50TFA00001',
          'title': '2026 Ford F-150 XLT',
          'price': 51900.0,
          'location': 'Boulevard Ford of Millsboro',
          'foundAt': '2026-11-16T08:05:00Z',
          'lastSeenAt': '2026-11-16T08:05:00Z',
        },
      ],
    };

    final deviceB = <String, dynamic>{
      'schemaVersion': 2,
      'guests': [
        {
          'id': 'guest-b',
          'name': 'Brianna Android',
          'make': 'Lincoln',
          'model': 'Nautilus',
          'createdAt': '2026-11-16T09:00:00Z',
          'updatedAt': '2026-11-16T09:00:00Z',
        },
      ],
      'deletedGuestIds': <String, String>{
        'guest-deleted-later': '2026-11-16T09:10:00Z',
      },
      'matches': [
        {
          'id': 'm-a1-updated',
          'guestId': 'guest-a',
          'vin': '1FTFW1E50TFA00001',
          'title': '2026 Ford F-150 XLT',
          'price': 49995.0,
          'location': 'Boulevard Ford of Millsboro',
          'foundAt': '2026-11-16T09:15:00Z',
          'lastSeenAt': '2026-11-16T09:15:00Z',
        },
        {
          'id': 'm-b1',
          'guestId': 'guest-b',
          'vin': '2LMPJ8KP3LBL00999',
          'title': '2024 Lincoln Nautilus Reserve',
          'price': 46500.0,
          'location': 'Boulevard Lincoln Lewes',
          'foundAt': '2026-11-16T09:05:00Z',
          'lastSeenAt': '2026-11-16T09:05:00Z',
        },
      ],
    };

    final merged = LocalScoutEngine.simulateMultiDeviceCloudMergeForTest(
      deviceASnapshot: deviceA,
      deviceBSnapshot: deviceB,
    );

    final guests = merged['guests'] as List<dynamic>;
    final guestIds = guests.map((g) => (g as Map)['id']).toSet();
    expect(guestIds, {'guest-a', 'guest-b'});
    expect(guestIds.contains('guest-deleted-later'), isFalse);

    final matches = merged['matches'] as List<dynamic>;
    expect(matches.length, 2);
    final fordMatch = matches.firstWhere(
      (m) => (m as Map)['vin'] == '1FTFW1E50TFA00001',
    ) as Map;
    // Price updated from newer scan on Device B, while original earliest foundAt from Device A is preserved!
    expect(fordMatch['price'], 49995.0);
    expect(fordMatch['foundAt'], '2026-11-16T08:05:00Z');
  });

  test('Guest with multiple vehicle makes/models evaluates each target independently and syncs across devices', () {
    final multiGuest = GuestProfile.fromJson({
      'id': 'guest-multi',
      'name': 'Jordan Taylor',
      'createdAt': '2026-11-16T10:00:00Z',
      'vehicleTargets': [
        {
          'id': 'vt-expedition',
          'condition': 'New',
          'minYear': 2025,
          'maxYear': 2026,
          'make': 'Ford',
          'model': 'Expedition',
          'maxPrice': 78000,
          'drivetrain': '4WD',
          'features': ['3rd Row Seating'],
        },
        {
          'id': 'vt-navigator',
          'condition': 'Pre-Owned',
          'minYear': 2022,
          'maxYear': 2024,
          'make': 'Lincoln',
          'model': 'Navigator',
          'maxPrice': 62000,
          'drivetrain': '4WD',
          'features': ['Leather Seats'],
        },
      ],
    });

    expect(multiGuest.effectiveTargets.length, 2);
    expect(multiGuest.targetVehicleLabel, contains('Ford Expedition'));
    expect(multiGuest.targetVehicleLabel, contains('Lincoln Navigator'));
    expect(multiGuest.allSearchableSpecsText.contains('navigator'), isTrue);

    final sampleInventory = <Map<String, dynamic>>[
      {
        'vin': '1FMJU1J80TEA00011',
        'title': '2026 Ford Expedition XLT 4WD',
        'year': 2026,
        'make': 'Ford',
        'model': 'Expedition',
        'trim': 'XLT',
        'condition': 'New',
        'price': 72900.0,
        'location': 'Boulevard Ford of Millsboro',
        'mileage': 8,
        'drivetrain': '4WD',
        'highlights': ['3rd Row Seating', 'Apple CarPlay'],
        'commentsSummary': 'New Expedition 4WD in stock.',
      },
      {
        'vin': '5LMJJ2LG4PEL00022',
        'title': '2023 Lincoln Navigator Reserve 4WD',
        'year': 2023,
        'make': 'Lincoln',
        'model': 'Navigator',
        'trim': 'Reserve',
        'condition': 'Pre-Owned',
        'price': 58900.0,
        'location': 'Boulevard Lincoln Lewes',
        'mileage': 24500,
        'drivetrain': '4WD',
        'highlights': ['Leather Seats', 'Panoramic Vista Roof'],
        'commentsSummary': 'Clean 1-owner Lincoln Navigator.',
      },
      {
        'vin': '5LMJJ2LG4PEL99999',
        'title': '2024 Lincoln Navigator Black Label 4WD',
        'year': 2024,
        'make': 'Lincoln',
        'model': 'Navigator',
        'trim': 'Black Label',
        'condition': 'Pre-Owned',
        'price': 84000.0, // Exceeds Navigator $62K cap (even though Expedition cap is $78K!)
        'location': 'Boulevard Lincoln Lewes',
        'mileage': 9000,
        'drivetrain': '4WD',
        'highlights': ['Leather Seats'],
        'commentsSummary': 'Above Navigator budget.',
      },
    ];

    final matched = LocalScoutEngine.evaluateMultiTargetGuestForTest(
      multiGuest,
      sampleInventory,
    );
    expect(matched.length, 2);

    final matchedVins =
        matched.map((m) => (m['vehicle'] as Map)['vin']).toSet();
    expect(matchedVins, {'1FMJU1J80TEA00011', '5LMJJ2LG4PEL00022'});

    final navMatch = matched.firstWhere(
      (m) => (m['vehicle'] as Map)['vin'] == '5LMJJ2LG4PEL00022',
    );
    expect(navMatch['targetId'], 'vt-navigator');
    expect(navMatch['targetLabel'], contains('Lincoln Navigator'));

    // Verify cloud sync updates single-vehicle guest on Device A to 2-vehicle guest added on Device B
    final merged = LocalScoutEngine.simulateMultiDeviceCloudMergeForTest(
      deviceASnapshot: {
        'schemaVersion': 2,
        'guests': [
          {
            'id': 'guest-multi',
            'name': 'Jordan Taylor',
            'make': 'Ford',
            'model': 'Expedition',
            'createdAt': '2026-11-16T10:00:00Z',
            'updatedAt': '2026-11-16T10:00:00Z',
          },
        ],
        'matches': [],
      },
      deviceBSnapshot: {
        'schemaVersion': 2,
        'guests': [
          {
            'id': 'guest-multi',
            'name': 'Jordan Taylor',
            'make': 'Ford',
            'model': 'Expedition',
            'createdAt': '2026-11-16T10:00:00Z',
            'updatedAt': '2026-11-16T11:30:00Z',
            'vehicleTargets': multiGuest.effectiveTargets
                .map((t) => t.toJson())
                .toList(),
          },
        ],
        'matches': [],
      },
    );

    final syncedGuest = GuestProfile.fromJson(
      Map<String, dynamic>.from((merged['guests'] as List).first as Map),
    );
    expect(syncedGuest.effectiveTargets.length, 2);
  });

  testWidgets(
      'GoogleDriveSyncService handles unregistered Android OAuth without falsely reporting Google Sign-In was canceled',
      (WidgetTester tester) async {
    const authChannel = MethodChannel('com.prestonmotor.scout/google_auth');
    const storeChannel = MethodChannel('com.prestonmotor.scout/launcher_widget');

    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      storeChannel,
      (call) async {
        if (call.method == 'readLocalStore') return '{}';
        return true;
      },
    );

    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      authChannel,
      (call) async {
        if (call.method == 'getSigningInfo') {
          return <String, dynamic>{
            'packageName': 'com.prestonmotor.preston_guest_scout',
            'sha1': 'D3:F4:84:4D:1F:42:5F:3A:89:F7:DE:13:A3:31:89:05:00:93:BC:8C',
            'savedEmail': '',
          };
        }
        if (call.method == 'silentSignIn') {
          return <String, dynamic>{'signedIn': false};
        }
        if (call.method == 'signInWithGoogle') {
          return <String, dynamic>{
            'signedIn': false,
            'needsOAuthClientSetup': true,
            'selectedEmail': 'sales@prestonmotor.com',
            'packageName': 'com.prestonmotor.preston_guest_scout',
            'sha1': 'D3:F4:84:4D:1F:42:5F:3A:89:F7:DE:13:A3:31:89:05:00:93:BC:8C',
          };
        }
        return null;
      },
    );

    final svc = GoogleDriveSyncService.instance;
    final ok = await svc.signInWithGoogle();
    expect(ok, isFalse);
    expect(svc.pendingSelectedEmail, 'sales@prestonmotor.com');
    expect(svc.needsOAuthSetup, isTrue);
    expect(svc.lastError ?? '', isNot(contains('Google Sign-In was canceled')));
    expect(svc.lastError ?? '', contains('sales@prestonmotor.com'));
    LocalScoutEngine.cancelSchedulerForTest();
  });
}


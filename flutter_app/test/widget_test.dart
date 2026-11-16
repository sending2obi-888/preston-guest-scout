import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:preston_guest_scout/models/models.dart';
import 'package:preston_guest_scout/screens/match_detail_screen.dart';
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
}


import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:preston_guest_scout/models/models.dart';
import 'package:preston_guest_scout/screens/match_detail_screen.dart';

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
}

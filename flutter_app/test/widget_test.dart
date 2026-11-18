import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:preston_guest_scout/models/models.dart';
import 'package:preston_guest_scout/screens/guest_matches_screen.dart';
import 'package:preston_guest_scout/screens/match_detail_screen.dart';
import 'package:preston_guest_scout/services/calendar_service.dart';
import 'package:preston_guest_scout/services/google_drive_sync_service.dart';
import 'package:preston_guest_scout/services/local_engine.dart';
import 'package:preston_guest_scout/services/match_notification_service.dart';
import 'package:preston_guest_scout/widgets/calendar_events_dialog.dart';
import 'package:preston_guest_scout/widgets/match_notifications_dialog.dart';
import 'package:preston_guest_scout/widgets/settings_and_chromebook_dialog.dart';

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
    LocalScoutEngine.resetForTest();
  });

  test('Client notes sort newest-first and union-merge across devices without loss', () {
    final guest = GuestProfile.fromJson({
      'id': 'guest-notes-1',
      'name': 'Rhonda Vanvorst',
      'make': 'Lincoln',
      'model': 'Nautilus',
      'createdAt': '2026-11-14T12:00:00Z',
      'clientNotes': [
        {
          'id': 'note-older',
          'text': 'Prefers white or silver exterior.',
          'createdAt': '2026-11-15T09:00:00Z',
        },
        {
          'id': 'note-newer',
          'text': 'Called Tuesday — ready to test drive this weekend.',
          'createdAt': '2026-11-16T14:30:00Z',
        },
      ],
    });

    expect(guest.clientNotes.length, 2);
    expect(guest.latestClientNote?.id, 'note-newer');
    expect(
      guest.latestClientNote?.text,
      'Called Tuesday — ready to test drive this weekend.',
    );

    final merged = LocalScoutEngine.simulateMultiDeviceCloudMergeForTest(
      deviceASnapshot: {
        'schemaVersion': 2,
        'guests': [
          {
            'id': 'guest-notes-1',
            'name': 'Rhonda Vanvorst',
            'make': 'Lincoln',
            'model': 'Nautilus',
            'createdAt': '2026-11-14T12:00:00Z',
            'updatedAt': '2026-11-16T10:00:00Z',
            'clientNotes': [
              {
                'id': 'note-chromebook',
                'text': 'Added on Googlebook: trading in 2019 Edge.',
                'createdAt': '2026-11-16T10:00:00Z',
              },
            ],
          },
        ],
        'matches': [],
      },
      deviceBSnapshot: {
        'schemaVersion': 2,
        'guests': [
          {
            'id': 'guest-notes-1',
            'name': 'Rhonda Vanvorst',
            'make': 'Lincoln',
            'model': 'Nautilus',
            'createdAt': '2026-11-14T12:00:00Z',
            'updatedAt': '2026-11-16T11:15:00Z',
            'clientNotes': [
              {
                'id': 'note-phone',
                'text': 'Added on Android phone: pre-approved financing.',
                'createdAt': '2026-11-16T11:15:00Z',
              },
            ],
          },
        ],
        'matches': [],
      },
    );

    final syncedGuest = GuestProfile.fromJson(
      Map<String, dynamic>.from((merged['guests'] as List).first as Map),
    );
    expect(syncedGuest.clientNotes.length, 2);
    expect(syncedGuest.latestClientNote?.id, 'note-phone');
    expect(
      syncedGuest.clientNotes.map((n) => n.id).toList(),
      ['note-phone', 'note-chromebook'],
    );
  });

  testWidgets(
      'GuestMatchesScreen renders Client Notes dropdown above Target Vehicles, shows most recent note without opening dropdown, and displays saved notes with date inside dropdown',
      (WidgetTester tester) async {
    LocalScoutEngine.resetForTest();
    const storeChannel = MethodChannel('com.prestonmotor.scout/launcher_widget');

    String persistedJson = jsonEncode({
      'guests': [
        {
          'id': 'guest-rhonda-test',
          'name': 'Rhonda Vanvorst',
          'condition': 'Pre-Owned',
          'minYear': 2022,
          'maxYear': 2024,
          'make': 'Lincoln',
          'model': 'Nautilus',
          'createdAt': '2026-11-14T12:00:00Z',
          'updatedAt': '2026-11-15T10:00:00Z',
          'clientNotes': [
            {
              'id': 'note-initial-1',
              'text': 'Initial note: prefers panoramic roof.',
              'createdAt': '2026-11-15T10:00:00Z',
            },
          ],
        },
      ],
      'matches': [],
    });

    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      storeChannel,
      (call) async {
        if (call.method == 'readLocalStore') return persistedJson;
        if (call.method == 'writeLocalStore') {
          final args = call.arguments as Map?;
          if (args != null && args['json'] is String) {
            persistedJson = args['json'] as String;
          }
          return true;
        }
        return true;
      },
    );

    await tester.pumpWidget(
      MaterialApp(
        home: GuestMatchesScreen(
          guestId: 'guest-rhonda-test',
          onDataChanged: () {},
          onSelectMatch: (_, _) {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    final dropdownToggle =
        find.byKey(const ValueKey('client_notes_dropdown_toggle'));
    final targetSectionHeader =
        find.textContaining('Target Vehicles for Rhonda Vanvorst');

    expect(dropdownToggle, findsOneWidget);
    expect(targetSectionHeader, findsOneWidget);

    // 1. Dropdown is placed directly ABOVE the Target Vehicle section
    expect(
      tester.getTopLeft(dropdownToggle).dy,
      lessThan(tester.getTopLeft(targetSectionHeader).dy),
    );

    // 2. Most recent note is visible WITHOUT selecting/opening the dropdown
    expect(
      find.byKey(const ValueKey('client_notes_dropdown_list')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('most_recent_client_note_preview')),
      findsOneWidget,
    );
    expect(
      find.text('Initial note: prefers panoramic roof.'),
      findsOneWidget,
    );

    // 3. Enter and save a new note — updates visible most recent note immediately
    await tester.enterText(
      find.byKey(const ValueKey('new_client_note_input')),
      'Spoke on phone — coming in Saturday at 11 AM.',
    );
    await tester.tap(find.byKey(const ValueKey('save_client_note_button')));
    await tester.pumpAndSettle();

    // Dropdown is still closed, yet the new note is visible as the Most Recent Note
    expect(
      find.byKey(const ValueKey('client_notes_dropdown_list')),
      findsNothing,
    );
    expect(
      find.text('Spoke on phone — coming in Saturday at 11 AM.'),
      findsOneWidget,
    );

    // 4. Open dropdown — both saved notes are displayed inside the dropdown with the date added
    await tester.tap(dropdownToggle);
    await tester.pumpAndSettle();

    final dropdownList =
        find.byKey(const ValueKey('client_notes_dropdown_list'));
    expect(dropdownList, findsOneWidget);
    expect(
      find.descendant(
        of: dropdownList,
        matching: find.text('Spoke on phone — coming in Saturday at 11 AM.'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: dropdownList,
        matching: find.text('Initial note: prefers panoramic roof.'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: dropdownList,
        matching: find.textContaining('Added '),
      ),
      findsNWidgets(2),
    );

    LocalScoutEngine.resetForTest();
  });

  test('MatchAlertNotification formats exact Client Name - Match Found - Model message', () {
    expect(
      MatchAlertNotification.formatMessage(
        clientName: 'Rhonda Vanvorst',
        make: 'Lincoln',
        model: 'Nautilus',
        title: '2023 Lincoln Nautilus Reserve AWD',
      ),
      'Rhonda Vanvorst - Match Found - Lincoln Nautilus',
    );

    expect(
      MatchAlertNotification.formatMessage(
        clientName: 'Marcus Vance',
        make: 'Ford',
        model: 'Ford F-250',
      ),
      'Marcus Vance - Match Found - Ford F-250',
    );

    expect(
      MatchAlertNotification.formatMessage(
        clientName: 'Devon Brooks',
        title: 'New 2026 Bronco Sport Big Bend',
      ),
      'Devon Brooks - Match Found - Bronco Sport Big Bend',
    );
  });

  testWidgets(
      'Post-initial-search new matches send OS notification saying Client Name - Match Found - Model while initial search sends 0 notifications',
      (WidgetTester tester) async {
    LocalScoutEngine.resetForTest();

    const storeChannel = MethodChannel('com.prestonmotor.scout/launcher_widget');
    const notifChannel = MethodChannel('com.prestonmotor.scout/notifications');

    String persistedStore = '{"guests":[],"matches":[],"notifications":[]}';
    final dispatchedOsNotifications = <Map<String, dynamic>>[];

    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      storeChannel,
      (call) async {
        if (call.method == 'readLocalStore') return persistedStore;
        if (call.method == 'writeLocalStore') {
          final args = call.arguments as Map?;
          if (args != null && args['storeJson'] is String) {
            persistedStore = args['storeJson'] as String;
          }
          return true;
        }
        return true;
      },
    );

    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      notifChannel,
      (call) async {
        if (call.method == 'requestNotificationPermission' ||
            call.method == 'areNotificationsEnabled') {
          return true;
        }
        if (call.method == 'showMatchNotification') {
          final args = Map<String, dynamic>.from(call.arguments as Map);
          dispatchedOsNotifications.add(args);
          return true;
        }
        return null;
      },
    );

    final initialInventory = <Map<String, dynamic>>[
      {
        'vin': '1FA6P8CF0R5100001',
        'title': '2025 Ford Mustang GT Fastback',
        'year': 2025,
        'make': 'Ford',
        'model': 'Mustang',
        'trim': 'GT',
        'condition': 'New',
        'price': 46900.0,
        'location': 'Boulevard Ford of Millsboro',
        'mileage': 12,
        'drivetrain': 'RWD',
        'highlights': ['Apple CarPlay', 'Backup Camera'],
      },
    ];

    // 1. Initial Search when creating a new client: finds 1 match, MUST send 0 notifications!
    final created = await LocalScoutEngine.createGuest(
      name: 'Alex Carter',
      phone: '302-555-0142',
      make: 'Ford',
      model: 'Mustang',
      maxPrice: 55000,
      mockCandidatesOverride: initialInventory,
    );
    expect(created.matchesFound, 1);
    expect(created.guest.initialSearchCompleted, isTrue);
    expect(created.guest.seenMatchVins, contains('1FA6P8CF0R5100001'));
    expect(dispatchedOsNotifications, isEmpty);
    expect(MatchNotificationService.instance.notifications, isEmpty);

    // 2. Adding a second vehicle target to the client: its initial search MUST ALSO send 0 notifications!
    final addedTarget = await LocalScoutEngine.addVehicleTargetToGuest(
      guestId: created.guest.id,
      make: 'Ford',
      model: 'Explorer',
      maxPrice: 52000,
      mockCandidatesOverride: [
        {
          'vin': '1FMSK8DH0RGA20002',
          'title': '2025 Ford Explorer XLT 4WD',
          'year': 2025,
          'make': 'Ford',
          'model': 'Explorer',
          'trim': 'XLT',
          'condition': 'New',
          'price': 44500.0,
          'location': 'Preston Ford of Hurlock',
          'mileage': 9,
          'drivetrain': '4WD',
          'highlights': ['3rd Row Seating'],
        },
      ],
    );
    expect(addedTarget.matches.length, 2);
    expect(dispatchedOsNotifications, isEmpty);

    // 3. Subsequent search (e.g. 7:30 AM / 2:00 PM / Search Now) finds a NEW Mustang VIN:
    // MUST send a full Android notification with guest's name and model of vehicle found!
    final updatedInventory = <Map<String, dynamic>>[
      ...initialInventory,
      {
        'vin': '1FMSK8DH0RGA20002',
        'title': '2025 Ford Explorer XLT 4WD',
        'year': 2025,
        'make': 'Ford',
        'model': 'Explorer',
        'trim': 'XLT',
        'condition': 'New',
        'price': 44500.0,
        'location': 'Preston Ford of Hurlock',
        'mileage': 9,
        'drivetrain': '4WD',
        'highlights': ['3rd Row Seating'],
      },
      {
        'vin': '1FA6P8CF9S5300099',
        'title': '2026 Ford Mustang EcoBoost Premium',
        'year': 2026,
        'make': 'Ford',
        'model': 'Mustang',
        'trim': 'EcoBoost Premium',
        'condition': 'New',
        'price': 38995.0,
        'location': 'Boulevard Ford of Millsboro',
        'mileage': 5,
        'drivetrain': 'RWD',
        'highlights': ['Heated Seats'],
      },
    ];

    final secondRun = await LocalScoutEngine.runSearchForSingleGuest(
      created.guest.id,
      slotLabel: '7:30 AM Daily Search',
      mockCandidatesOverride: updatedInventory,
    );
    expect(secondRun.matches.length, 3);
    expect(dispatchedOsNotifications.length, 1);
    expect(
      dispatchedOsNotifications.first['title'],
      'Alex Carter - Match Found - Ford Mustang',
    );
    expect(dispatchedOsNotifications.first['guestName'], 'Alex Carter');
    expect(dispatchedOsNotifications.first['guestPhone'], '302-555-0142');
    expect(dispatchedOsNotifications.first['vehicleModel'], 'Ford Mustang');
    expect(
      dispatchedOsNotifications.first['vehicleTitle'],
      '2026 Ford Mustang EcoBoost Premium',
    );
    expect(dispatchedOsNotifications.first['price'], 38995.0);
    expect(
      dispatchedOsNotifications.first['location'],
      'Boulevard Ford of Millsboro',
    );
    expect(
      dispatchedOsNotifications.first['guestId'],
      created.guest.id,
    );
    expect(MatchNotificationService.instance.unreadCount, 1);

    // 4. Another subsequent search with no new VINs MUST send 0 duplicate notifications!
    await LocalScoutEngine.runSearchForSingleGuest(
      created.guest.id,
      slotLabel: '2:00 PM Daily Search',
      mockCandidatesOverride: updatedInventory,
    );
    expect(dispatchedOsNotifications.length, 1);

    // 5. Post-initial-search Google Drive cloud sync delivering a brand-new Explorer VIN
    // for an existing guest who already completed their initial search MUST ALSO send an Android notification!
    await LocalScoutEngine.mergeCloudSnapshot({
      'guests': [
        {
          'id': created.guest.id,
          'name': created.guest.name,
          'phone': created.guest.phone,
          'createdAt': created.guest.createdAt,
          'updatedAt': DateTime.now().toUtc().toIso8601String(),
          'initialSearchCompleted': true,
          'seenMatchVins': [
            '1FA6P8CF0R5100001',
            '1FMSK8DH0RGA20002',
            '1FA6P8CF9S5300099',
            '1FMSK8FH2SGA99999',
          ],
        },
      ],
      'matches': [
        {
          'id': 'match-cloud-explorer-1',
          'guestId': created.guest.id,
          'vin': '1FMSK8FH2SGA99999',
          'title': '2026 Ford Explorer ST-Line 4WD',
          'year': 2026,
          'make': 'Ford',
          'model': 'Explorer',
          'trim': 'ST-Line',
          'condition': 'New',
          'price': 48250.0,
          'location': 'Preston Ford of Keller',
          'foundAt': DateTime.now().toUtc().toIso8601String(),
          'lastSeenAt': DateTime.now().toUtc().toIso8601String(),
        },
      ],
    });
    expect(dispatchedOsNotifications.length, 2);
    expect(
      dispatchedOsNotifications[1]['title'],
      'Alex Carter - Match Found - Ford Explorer',
    );
    expect(dispatchedOsNotifications[1]['guestName'], 'Alex Carter');
    expect(dispatchedOsNotifications[1]['vehicleModel'], 'Ford Explorer');

    // 6. Verify MatchNotificationsDialog renders guest name + vehicle model, Test Alert button, & navigates on tap
    String? tappedGuestId;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MatchNotificationsDialog(
            onSelectGuest: (gid) => tappedGuestId = gid,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.text('Alex Carter - Match Found - Ford Mustang'),
      findsOneWidget,
    );
    expect(
      find.text('Alex Carter - Match Found - Ford Explorer'),
      findsOneWidget,
    );
    expect(find.text('Android Settings'), findsOneWidget);
    expect(find.text('Test Alert'), findsOneWidget);

    await tester.tap(find.text('Test Alert'));
    await tester.pumpAndSettle();
    expect(dispatchedOsNotifications.length, 3);
    expect(dispatchedOsNotifications[2]['guestName'], 'Sample Guest');
    expect(dispatchedOsNotifications[2]['vehicleModel'], 'Ford Bronco');
    expect(
      dispatchedOsNotifications[2]['title'],
      'Sample Guest - Match Found - Ford Bronco',
    );

    await tester.tap(find.text('Alex Carter - Match Found - Ford Mustang'));
    await tester.pumpAndSettle();
    expect(tappedGuestId, created.guest.id);

    // Drain 700ms GoogleDriveSyncService.scheduleAutoSave timer
    await tester.pump(const Duration(seconds: 1));

    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(storeChannel, null);
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(notifChannel, null);
    LocalScoutEngine.resetForTest();
  });

  test(
      'CalendarCallEvent.computeSameDaySlot schedules strictly on the same calendar day across morning, afternoon, and late night',
      () {
    // 1. 7:30 AM morning scan -> 10:00 AM - 10:30 AM same day
    final morning =
        CalendarCallEvent.computeSameDaySlot(DateTime(2026, 11, 17, 7, 30));
    expect(morning.eventDate, '2026-11-17');
    expect(morning.startLocal, DateTime(2026, 11, 17, 10, 0));
    expect(morning.endLocal, DateTime(2026, 11, 17, 10, 30));

    // 2. 2:00 PM afternoon scan -> 2:30 PM - 3:00 PM same day
    final afternoon =
        CalendarCallEvent.computeSameDaySlot(DateTime(2026, 11, 17, 14, 0));
    expect(afternoon.eventDate, '2026-11-17');
    expect(afternoon.startLocal, DateTime(2026, 11, 17, 14, 30));
    expect(afternoon.endLocal, DateTime(2026, 11, 17, 15, 0));

    // 3. 11:50 PM late night -> clamped before 23:58 on the exact same calendar day
    final lateNight =
        CalendarCallEvent.computeSameDaySlot(DateTime(2026, 11, 17, 23, 50));
    expect(lateNight.eventDate, '2026-11-17');
    expect(lateNight.startLocal.year, 2026);
    expect(lateNight.startLocal.month, 11);
    expect(lateNight.startLocal.day, 17);
    expect(lateNight.endLocal.day, 17);
    expect(lateNight.endLocal.hour, 23);
    expect(lateNight.endLocal.minute, lessThanOrEqualTo(58));
    expect(lateNight.endLocal.isAfter(lateNight.startLocal), isTrue);

    expect(
      CalendarCallEvent.buildCallTitle(
        clientName: 'Rhonda Vanvorst',
        matchedVehicles: const [
          {'make': 'Lincoln', 'model': 'Nautilus'},
        ],
      ),
      'Call Rhonda Vanvorst — Match Found: Lincoln Nautilus',
    );
    expect(
      CalendarCallEvent.buildCallTitle(
        clientName: 'Rhonda Vanvorst',
        matchedVehicles: const [
          {'make': 'Lincoln', 'model': 'Nautilus'},
          {'make': 'Lincoln', 'model': 'Corsair'},
        ],
      ),
      'Call Rhonda Vanvorst — 2 Vehicle Matches Found (Lincoln Nautilus)',
    );
  });

  testWidgets(
      'App asks for calendar permission and automatically creates a same-day Call Guest calendar event when a match is found',
      (WidgetTester tester) async {
    LocalScoutEngine.resetForTest();

    const storeChannel = MethodChannel('com.prestonmotor.scout/launcher_widget');
    const notifChannel = MethodChannel('com.prestonmotor.scout/notifications');
    const calChannel = MethodChannel('com.prestonmotor.scout/calendar');

    String persistedStore =
        '{"guests":[],"matches":[],"notifications":[],"calendarEvents":[]}';
    final dispatchedOsNotifications = <Map<String, dynamic>>[];
    final createdDeviceCalendarEvents = <Map<String, dynamic>>[];
    int permissionRequestsCount = 0;

    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      storeChannel,
      (call) async {
        if (call.method == 'readLocalStore') return persistedStore;
        if (call.method == 'writeLocalStore') {
          final args = call.arguments as Map?;
          if (args != null && args['storeJson'] is String) {
            persistedStore = args['storeJson'] as String;
          }
          return true;
        }
        return true;
      },
    );

    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      notifChannel,
      (call) async {
        if (call.method == 'requestNotificationPermission' ||
            call.method == 'areNotificationsEnabled') {
          return true;
        }
        if (call.method == 'showMatchNotification') {
          dispatchedOsNotifications
              .add(Map<String, dynamic>.from(call.arguments as Map));
          return true;
        }
        return null;
      },
    );

    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      calChannel,
      (call) async {
        if (call.method == 'hasCalendarPermission') {
          return permissionRequestsCount > 0;
        }
        if (call.method == 'requestCalendarPermission') {
          permissionRequestsCount++;
          return true;
        }
        if (call.method == 'createSameDayCallEvent') {
          final args = Map<String, dynamic>.from(call.arguments as Map);
          createdDeviceCalendarEvents.add(args);
          return <String, dynamic>{
            'created': true,
            'eventId': 'android-cal-${createdDeviceCalendarEvents.length}',
            'provider': 'android_calendar_provider',
            'startEpochMs': args['startEpochMs'],
            'endEpochMs': args['endEpochMs'],
          };
        }
        return null;
      },
    );

    // 1. Startup asks for calendar permission automatically
    await CalendarService.instance.initialize();
    expect(permissionRequestsCount, 1);
    expect(CalendarService.instance.permissionGranted, isTrue);

    // 2. Creating a guest whose search finds a match automatically creates a SAME-DAY call event
    // while keeping initial-search OS notifications at 0!
    final now = DateTime.now();
    final todayStr =
        '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';

    final created = await LocalScoutEngine.createGuest(
      name: 'Jordan Blake',
      phone: '(302) 555-0199',
      make: 'Ford',
      model: 'Bronco',
      maxPrice: 58000,
      mockCandidatesOverride: [
        {
          'vin': '1FMDE5BH0SLA10001',
          'title': '2025 Ford Bronco Big Bend 4WD',
          'year': 2025,
          'make': 'Ford',
          'model': 'Bronco',
          'trim': 'Big Bend',
          'condition': 'New',
          'price': 45990.0,
          'location': 'Boulevard Ford of Millsboro',
          'mileage': 8,
          'drivetrain': '4WD',
          'highlights': ['4WD', 'Apple CarPlay'],
        },
      ],
    );

    expect(created.matchesFound, 1);
    expect(dispatchedOsNotifications, isEmpty);
    expect(createdDeviceCalendarEvents.length, 1);
    expect(
      createdDeviceCalendarEvents.first['title'],
      'Call Jordan Blake — Match Found: Ford Bronco',
    );
    expect(
      createdDeviceCalendarEvents.first['description'].toString(),
      contains('(302) 555-0199'),
    );
    expect(
      createdDeviceCalendarEvents.first['description'].toString(),
      contains('Boulevard Ford of Millsboro'),
    );

    final startDt = DateTime.fromMillisecondsSinceEpoch(
      createdDeviceCalendarEvents.first['startEpochMs'] as int,
    );
    final endDt = DateTime.fromMillisecondsSinceEpoch(
      createdDeviceCalendarEvents.first['endEpochMs'] as int,
    );
    expect(startDt.year, now.year);
    expect(startDt.month, now.month);
    expect(startDt.day, now.day);
    expect(endDt.day, now.day);

    expect(CalendarService.instance.events.length, 1);
    expect(CalendarService.instance.events.first.eventDate, todayStr);

    // 3. Subsequent search finding a new VIN on the same day updates today's call sheet
    // (without creating a duplicate calendar event) AND fires the OS notification!
    await LocalScoutEngine.runSearchForSingleGuest(
      created.guest.id,
      slotLabel: '2:00 PM Daily Search',
      mockCandidatesOverride: [
        {
          'vin': '1FMDE5BH0SLA10001',
          'title': '2025 Ford Bronco Big Bend 4WD',
          'year': 2025,
          'make': 'Ford',
          'model': 'Bronco',
          'trim': 'Big Bend',
          'condition': 'New',
          'price': 45990.0,
          'location': 'Boulevard Ford of Millsboro',
          'mileage': 8,
          'drivetrain': '4WD',
          'highlights': ['4WD', 'Apple CarPlay'],
        },
        {
          'vin': '1FMDE5BH9SLA20002',
          'title': '2026 Ford Bronco Outer Banks 4WD',
          'year': 2026,
          'make': 'Ford',
          'model': 'Bronco',
          'trim': 'Outer Banks',
          'condition': 'New',
          'price': 51400.0,
          'location': 'Preston Ford of Hurlock',
          'mileage': 4,
          'drivetrain': '4WD',
          'highlights': ['Leather Seats'],
        },
      ],
    );

    expect(CalendarService.instance.events.length, 1);
    expect(createdDeviceCalendarEvents.length, 1);
    expect(
      CalendarService.instance.events.first.title,
      'Call Jordan Blake — 2 Vehicle Matches Found (Ford Bronco)',
    );
    expect(dispatchedOsNotifications.length, 1);
    expect(
      dispatchedOsNotifications.first['title'],
      'Jordan Blake - Match Found - Ford Bronco',
    );

    await tester.pump(const Duration(seconds: 1));

    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(storeChannel, null);
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(notifChannel, null);
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(calChannel, null);
    LocalScoutEngine.resetForTest();
  });

  testWidgets(
      'CalendarPermissionPromptDialog requests calendar access and CalendarEventsDialog displays scheduled same-day guest calls',
      (WidgetTester tester) async {
    LocalScoutEngine.resetForTest();

    const storeChannel = MethodChannel('com.prestonmotor.scout/launcher_widget');
    const calChannel = MethodChannel('com.prestonmotor.scout/calendar');

    int explicitPromptRequests = 0;

    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      storeChannel,
      (call) async {
        if (call.method == 'readLocalStore') {
          return '{"guests":[],"matches":[],"notifications":[],"calendarEvents":[]}';
        }
        return true;
      },
    );

    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      calChannel,
      (call) async {
        if (call.method == 'hasCalendarPermission') return false;
        if (call.method == 'requestCalendarPermission') {
          explicitPromptRequests++;
          return true;
        }
        return null;
      },
    );

    String? selectedGuestId;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  FilledButton(
                    onPressed: () {
                      showDialog<bool>(
                        context: context,
                        builder: (_) => const CalendarPermissionPromptDialog(),
                      );
                    },
                    child: const Text('Ask Calendar'),
                  ),
                  FilledButton(
                    onPressed: () {
                      showDialog<void>(
                        context: context,
                        builder: (_) => CalendarEventsDialog(
                          onSelectGuest: (gid) => selectedGuestId = gid,
                        ),
                      );
                    },
                    child: const Text('Open Calendar Log'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Ask Calendar'));
    await tester.pumpAndSettle();

    expect(find.text('Allow Calendar Access?'), findsOneWidget);
    expect(find.text('Allow Calendar Access'), findsOneWidget);

    await tester.tap(find.text('Allow Calendar Access'));
    await tester.pumpAndSettle();

    expect(explicitPromptRequests, 1);
    expect(CalendarService.instance.permissionGranted, isTrue);

    // Seed a scheduled same-day call event and verify CalendarEventsDialog displays & navigates
    CalendarService.instance.hydratePersistedState(
      permissionGranted: true,
      promptDismissed: true,
      events: const [
        CalendarCallEvent(
          id: 'cal-test-1',
          guestId: 'guest-jordan',
          guestName: 'Jordan Blake',
          guestPhone: '(302) 555-0199',
          eventDate: '2026-11-17',
          startAt: '2026-11-17T14:30:00',
          endAt: '2026-11-17T15:00:00',
          title: 'Call Jordan Blake — Match Found: Ford Bronco',
          location: 'Boulevard Ford of Millsboro',
          vehicleSummary: 'Ford Bronco',
          provider: 'android_calendar_provider',
          createdAt: '2026-11-17T14:00:00Z',
        ),
      ],
    );

    await tester.tap(find.text('Open Calendar Log'));
    await tester.pumpAndSettle();

    expect(find.text('Same-Day Guest Call Calendar'), findsOneWidget);
    expect(
      find.text('Call Jordan Blake — Match Found: Ford Bronco'),
      findsOneWidget,
    );
    expect(find.textContaining('(302) 555-0199'), findsOneWidget);
    expect(find.textContaining('Boulevard Ford of Millsboro'), findsOneWidget);

    await tester.tap(find.text('Call Jordan Blake — Match Found: Ford Bronco'));
    await tester.pumpAndSettle();
    expect(selectedGuestId, 'guest-jordan');

    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(storeChannel, null);
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(calChannel, null);
    LocalScoutEngine.resetForTest();
  });

  testWidgets(
      'LocalScoutEngine retains strictly the last 5 backups and supports Overwrite vs Duplicate conflict resolution',
      (WidgetTester tester) async {
    LocalScoutEngine.resetForTest();
    const storeChannel = MethodChannel('com.prestonmotor.scout/launcher_widget');
    String persistedStore = '{"guests":[],"matches":[],"notifications":[],"backups":[]}';

    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      storeChannel,
      (call) async {
        if (call.method == 'readLocalStore') return persistedStore;
        if (call.method == 'writeLocalStore') {
          final args = call.arguments as Map?;
          if (args != null && args['storeJson'] is String) {
            persistedStore = args['storeJson'] as String;
          }
          return true;
        }
        return true;
      },
    );

    final mockInv = <Map<String, dynamic>>[
      {
        'vin': '1FT8W2BA0TED90001',
        'title': '2026 Ford F-250 XL SuperCab 4WD',
        'year': 2026,
        'make': 'Ford',
        'model': 'F-250',
        'trim': 'XL',
        'condition': 'New',
        'price': 54990.0,
        'location': 'Preston Ford of Hurlock',
        'mileage': 8,
        'drivetrain': '4WD',
        'highlights': ['Tow Hitch'],
      },
    ];

    final createdA = await LocalScoutEngine.createGuest(
      name: 'Taylor Morgan',
      phone: '302-555-0188',
      make: 'Ford',
      model: 'F-250',
      maxPrice: 60000,
      mockCandidatesOverride: mockInv,
    );
    await LocalScoutEngine.addGuestNote(
      guestId: createdA.guest.id,
      text: 'Original note from backup #1',
    );

    final createdB = await LocalScoutEngine.createGuest(
      name: 'Casey Rivera',
      make: 'Ford',
      model: 'F-250',
      maxPrice: 60000,
      mockCandidatesOverride: mockInv,
    );

    // Create 6 manual backups to verify strict cap of 5 newest backups
    for (var i = 1; i <= 6; i++) {
      await LocalScoutEngine.createManualBackup(label: 'Checkpoint #$i');
    }

    final backups = await LocalScoutEngine.getBackups();
    expect(backups.length, 5);
    expect(backups.first.label, 'Checkpoint #6');
    expect(backups.last.label, 'Checkpoint #2');

    final checkpointId = backups.first.id;

    // Modify Taylor Morgan's notes AND delete Casey Rivera
    await LocalScoutEngine.addGuestNote(
      guestId: createdA.guest.id,
      text: 'Edited note after backup',
    );
    await LocalScoutEngine.deleteGuest(createdB.guest.id);

    // Inspect conflicts for Checkpoint #6: Taylor Morgan conflicts (and differs), Casey Rivera is non-conflicting
    final conflictPreview =
        await LocalScoutEngine.inspectBackupConflicts(checkpointId);
    expect(conflictPreview.hasConflicts, isTrue);
    expect(conflictPreview.conflictingGuestNames, contains('Taylor Morgan'));
    expect(conflictPreview.modifiedConflictNames, contains('Taylor Morgan'));
    expect(conflictPreview.nonConflictingGuestNames, contains('Casey Rivera'));

    // 1. Restore with OVERWRITE: Taylor Morgan reverts to 1 note ("Original note from backup #1"), Casey Rivera is restored
    final overwriteRes = await LocalScoutEngine.restoreBackup(
      checkpointId,
      resolution: BackupConflictResolution.overwrite,
    );
    expect(overwriteRes.overwrittenGuests, 1);
    expect(overwriteRes.restoredGuests, 1);
    expect(overwriteRes.duplicatedGuests, 0);

    final afterOverwrite = await LocalScoutEngine.getAllGuests();
    expect(afterOverwrite.length, 2);
    final taylorAfterOverwrite =
        afterOverwrite.firstWhere((g) => g.name == 'Taylor Morgan');
    expect(taylorAfterOverwrite.clientNotes.length, 1);
    expect(
      taylorAfterOverwrite.latestClientNote?.text,
      'Original note from backup #1',
    );

    // 2. Restore Checkpoint #6 again with DUPLICATE: both Taylor Morgan and Casey Rivera now conflict -> creates "(Copy)" entries!
    final duplicateRes = await LocalScoutEngine.restoreBackup(
      checkpointId,
      resolution: BackupConflictResolution.duplicate,
    );
    expect(duplicateRes.duplicatedGuests, 2);
    expect(duplicateRes.overwrittenGuests, 0);

    final afterDuplicate = await LocalScoutEngine.getAllGuests();
    expect(afterDuplicate.length, 4);
    expect(
      afterDuplicate.map((g) => g.name),
      containsAll([
        'Taylor Morgan',
        'Taylor Morgan (Copy)',
        'Casey Rivera',
        'Casey Rivera (Copy)',
      ]),
    );
    final taylorCopy =
        afterDuplicate.firstWhere((g) => g.name == 'Taylor Morgan (Copy)');
    expect(taylorCopy.matchCount, 1);
    expect(taylorCopy.clientNotes.length, 1);

    await tester.pump(const Duration(seconds: 1));
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(storeChannel, null);
    LocalScoutEngine.resetForTest();
  });

  testWidgets(
      'SettingsAndChromebookDialog displays last 5 backups, expands backup details, and prompts Overwrite or Duplicate on conflict',
      (WidgetTester tester) async {
    LocalScoutEngine.resetForTest();
    const storeChannel = MethodChannel('com.prestonmotor.scout/launcher_widget');
    String persistedStore = '{"guests":[],"matches":[],"notifications":[],"backups":[]}';

    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      storeChannel,
      (call) async {
        if (call.method == 'readLocalStore') return persistedStore;
        if (call.method == 'writeLocalStore') {
          final args = call.arguments as Map?;
          if (args != null && args['storeJson'] is String) {
            persistedStore = args['storeJson'] as String;
          }
          return true;
        }
        return true;
      },
    );

    await LocalScoutEngine.createGuest(
      name: 'Morgan Steele',
      make: 'Ford',
      model: 'Bronco',
      maxPrice: 50000,
      mockCandidatesOverride: [
        {
          'vin': '1FMDE5BH0SLA55555',
          'title': '2026 Ford Bronco Big Bend 4WD',
          'year': 2026,
          'make': 'Ford',
          'model': 'Bronco',
          'trim': 'Big Bend',
          'condition': 'New',
          'price': 43990.0,
          'location': 'Boulevard Ford of Millsboro',
          'mileage': 6,
          'drivetrain': '4WD',
          'highlights': ['4WD'],
        },
      ],
    );
    await LocalScoutEngine.createManualBackup(label: 'Morning Backup');

    int onSavedCalls = 0;
    await tester.binding.setSurfaceSize(const Size(1024, 900));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SettingsAndChromebookDialog(
            onSaved: () => onSavedCalls++,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Last 5 Backups'), findsOneWidget);
    expect(find.text('Morning Backup'), findsOneWidget);

    // Expand backup details via "View Backup"
    await tester.tap(find.text('View Backup').first);
    await tester.pumpAndSettle();
    expect(find.textContaining('Morgan Steele —'), findsOneWidget);

    // Tap "Load Backup" -> conflicts with existing Morgan Steele -> shows Overwrite / Duplicate dialog
    await tester.tap(find.text('Load Backup').first);
    await tester.pumpAndSettle();

    expect(find.text('Conflicting Data Detected'), findsOneWidget);
    expect(find.text('Overwrite Entries'), findsOneWidget);
    expect(find.text('Duplicate Entries'), findsOneWidget);

    // Choose "Duplicate Entries"
    await tester.tap(find.text('Duplicate Entries'));
    await tester.pumpAndSettle();

    expect(onSavedCalls, 1);
    final guests = await LocalScoutEngine.getAllGuests();
    expect(guests.length, 2);
    expect(
      guests.map((g) => g.name),
      containsAll(['Morgan Steele', 'Morgan Steele (Copy)']),
    );

    await tester.pump(const Duration(seconds: 1));
    await tester.binding.setSurfaceSize(null);
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(storeChannel, null);
    LocalScoutEngine.resetForTest();
  });
}

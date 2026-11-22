import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:preston_guest_scout/main.dart';
import 'package:preston_guest_scout/models/models.dart';
import 'package:preston_guest_scout/screens/guest_list_screen.dart';
import 'package:preston_guest_scout/screens/guest_matches_screen.dart';
import 'package:preston_guest_scout/screens/home_intake_screen.dart';
import 'package:preston_guest_scout/screens/match_detail_screen.dart';
import 'package:preston_guest_scout/screens/vin_recall_screen.dart';
import 'package:preston_guest_scout/services/calendar_service.dart';
import 'package:preston_guest_scout/services/google_drive_sync_service.dart';
import 'package:preston_guest_scout/services/local_engine.dart';
import 'package:preston_guest_scout/services/match_notification_service.dart';
import 'package:preston_guest_scout/services/natural_language_parser.dart';
import 'package:preston_guest_scout/services/nhtsa_recall_service.dart';
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

  test(
      'Natural-language query "Ford F150. 6.5ft bed. XLT." parses Ford F-150 XLT 6.5ft bed and returns ONLY matching vehicles',
      () {
    final normalized = LocalScoutEngine.normalizeSpecsForTest({
      'id': 'guest-nl-f150',
      'name': 'Chris Miller',
      'notes': 'Ford F150. 6.5ft bed. XLT.',
      'createdAt': '2026-11-19T12:00:00Z',
    });

    expect(normalized['make'], 'Ford');
    expect(normalized['model'], 'F-150');
    expect(normalized['trim'], 'XLT');
    expect(normalized['bedLength'], "6.5'");

    final guest = GuestProfile.fromJson(normalized);
    expect(guest.make, 'Ford');
    expect(guest.model, 'F-150');
    expect(guest.trim, 'XLT');
    expect(guest.bedLength, "6.5'");
    expect(guest.targetVehicleLabel, 'Ford F-150 XLT • 6.5 ft Bed');

    final mixedInventory = <Map<String, dynamic>>[
      // 1. SHOULD MATCH: New 2026 Ford F-150 XLT with DMS-verified 6.5' bed
      {
        'vin': '1FTFW3L81TKE78366',
        'title': '2026 Ford F-150 XLT',
        'year': 2026,
        'make': 'Ford',
        'model': 'F-150',
        'trim': 'XLT',
        'bedLength': "6.5'",
        'bodyStyle': 'SuperCrew Cab',
        'condition': 'New',
        'price': 50509.0,
        'location': 'Preston Ford Aberdeen, MD',
        'drivetrain': '4WD',
        'highlights': ['6.5 ft Bed', '4WD/AWD', 'Blind Spot Monitor'],
        'commentsSummary': 'New 2026 Ford F-150 XLT in Oxford White.',
      },
      // 2. SHOULD MATCH: Pre-Owned 2024 Ford F-150 XLT whose build comments specify 6.5' bed
      {
        'vin': '1FTFW3L87RKF38272',
        'title': '2024 Ford F-150 XLT',
        'year': 2024,
        'make': 'Ford',
        'model': 'F-150',
        'trim': 'XLT',
        'bedLength': '',
        'bodyStyle': 'SuperCrew Cab',
        'condition': 'Pre-Owned',
        'price': 39700.0,
        'location': 'Preston Ford Hurlock, MD',
        'drivetrain': '4WD',
        'highlights': ['Remote Start', 'Tow Hitch'],
        'commentsSummary':
            "2024 Ford F-150 XLT SuperCrew 4x4 3.5L EcoBoost FX4 6.5' Bed 36-Gallon Tank.",
      },
      // 3. MUST REJECT: Ford F-150 XLT with 5.5-ft bed
      {
        'vin': '1FTFW1E51PKF81199',
        'title': '2023 Ford F-150 XLT',
        'year': 2023,
        'make': 'Ford',
        'model': 'F-150',
        'trim': 'XLT',
        'bedLength': "5.5'",
        'bodyStyle': 'SuperCrew Cab',
        'condition': 'Pre-Owned',
        'price': 36900.0,
        'location': 'Preston Ford Hurlock, MD',
        'drivetrain': '4WD',
        'highlights': ['4WD'],
        'commentsSummary': '145-inch wheelbase SuperCrew with 5.5-foot bed.',
      },
      // 4. MUST REJECT: Ford F-150 XLT with unverified/unknown bed
      {
        'vin': '1FTFW3L80TKD99999',
        'title': '2026 Ford F-150 XLT',
        'year': 2026,
        'make': 'Ford',
        'model': 'F-150',
        'trim': 'XLT',
        'bedLength': '',
        'bodyStyle': 'SuperCrew Cab',
        'condition': 'New',
        'price': 49200.0,
        'location': 'Preston Ford Denton, MD',
        'drivetrain': '4WD',
        'highlights': ['4WD'],
        'commentsSummary': 'New 2026 Ford F-150 XLT SuperCrew.',
      },
      // 5. MUST REJECT: Ford F-150 XL (wrong trim!) even though it has 6.5' bed
      {
        'vin': '1FTEX1KP0TKE11111',
        'title': '2026 Ford F-150 XL',
        'year': 2026,
        'make': 'Ford',
        'model': 'F-150',
        'trim': 'XL',
        'bedLength': "6.5'",
        'bodyStyle': 'SuperCab',
        'condition': 'New',
        'price': 42500.0,
        'location': 'Preston Ford Hurlock, MD',
        'drivetrain': '4WD',
        'highlights': ['6.5 ft Bed'],
        'commentsSummary': 'SuperCab 6.5ft bed XL work truck.',
      },
      // 6. MUST REJECT: Ford F-150 Lariat (wrong trim!) even though it has 6.5' bed
      {
        'vin': '1FTFW5L80TKE22222',
        'title': '2026 Ford F-150 LARIAT',
        'year': 2026,
        'make': 'Ford',
        'model': 'F-150',
        'trim': 'LARIAT',
        'bedLength': "6.5'",
        'bodyStyle': 'SuperCrew Cab',
        'condition': 'New',
        'price': 64900.0,
        'location': 'Boulevard Ford of Millsboro',
        'drivetrain': '4WD',
        'highlights': ['6.5 ft Bed'],
        'commentsSummary': 'Lariat 6.5ft box.',
      },
      // 7. MUST REJECT: Ford F-250 XLT (wrong model!)
      {
        'vin': '1FT7X2BT0TEC33333',
        'title': '2026 Ford Super Duty F-250 SRW XLT',
        'year': 2026,
        'make': 'Ford',
        'model': 'Super Duty F-250 SRW',
        'trim': 'XLT',
        'bedLength': "6.5'",
        'bodyStyle': 'SuperCab',
        'condition': 'New',
        'price': 55900.0,
        'location': 'Preston Ford Hurlock, MD',
        'drivetrain': '4WD',
        'highlights': ['4WD'],
        'commentsSummary': 'Super Duty XLT.',
      },
    ];

    final matches = LocalScoutEngine.evaluateAllForTest(guest, mixedInventory);
    expect(matches.length, 2);
    final matchedVins =
        matches.map((m) => (m['vehicle'] as Map)['vin'].toString()).toSet();
    expect(matchedVins, {'1FTFW3L81TKE78366', '1FTFW3L87RKF38272'});

    for (final m in matches) {
      final feats = (m['matchedFeatures'] as List).cast<String>();
      expect(feats, contains('6.5 ft Bed (Verified)'));
      expect(feats, contains('XLT Trim Package'));
    }

    // Word-boundary trim check: searching "Ford F150. XL." must NOT match XLT!
    final xlGuest = GuestProfile.fromJson(
      LocalScoutEngine.normalizeSpecsForTest({
        'id': 'guest-xl-only',
        'name': 'XL Buyer',
        'notes': 'Ford F150. XL.',
        'createdAt': '2026-11-19T12:00:00Z',
      }),
    );
    final xlMatches =
        LocalScoutEngine.evaluateAllForTest(xlGuest, mixedInventory);
    expect(xlMatches.length, 1);
    expect((xlMatches.first['vehicle'] as Map)['vin'], '1FTEX1KP0TKE11111');

    // Model disambiguation check: searching "Ford Bronco" must NOT match "Bronco Sport"!
    expect(
      NaturalLanguageVehicleParser.doesVehicleMatchModel(
        'Bronco',
        {'model': 'Bronco Sport', 'title': '2026 Ford Bronco Sport Big Bend'},
      ),
      isFalse,
    );
    expect(
      NaturalLanguageVehicleParser.doesVehicleMatchModel(
        'Bronco',
        {'model': 'Bronco', 'title': '2026 Ford Bronco Badlands'},
      ),
      isTrue,
    );
  });

  testWidgets(
      'HomeIntakeScreen displays live Understood Search Criteria chips when entering "Ford F150. 6.5ft bed. XLT." in natural-language field',
      (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1024, 1100));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HomeIntakeScreen(
            status: const SystemStatus(
              totalGuests: 3,
              totalMatches: 42,
              nextScheduledRunLabel: 'Today at 2:00 PM',
              timeZone: 'America/New_York',
              isRunning: false,
              geminiConfigured: true,
              geminiModel: 'gemini-2.5-flash',
            ),
            onGuestCreated: () {},
            onOpenGuestMatches: (_) {},
            onOpenSettings: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('parsed_natural_language_summary')),
      findsNothing,
    );

    await tester.enterText(
      find.byKey(const ValueKey('natural_language_search_input')),
      'Ford F150. 6.5ft bed. XLT.',
    );
    await tester.pumpAndSettle();

    final summaryBox =
        find.byKey(const ValueKey('parsed_natural_language_summary'));
    expect(summaryBox, findsOneWidget);
    expect(
      find.descendant(of: summaryBox, matching: find.text('Make: Ford')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: summaryBox, matching: find.text('Model: F-150')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: summaryBox, matching: find.text('Trim: XLT')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: summaryBox, matching: find.text('Bed: 6.5 ft Bed')),
      findsOneWidget,
    );

    await tester.binding.setSurfaceSize(null);
  });

  test(
      'NhtsaRecallService validates 17-character VINs, parses DD/MM/YYYY NHTSA dates, and disambiguates NHTSA recall model taxonomy',
      () {
    final ok = NhtsaRecallService.validateAndNormalizeVin('1ftfw3l87rkf38272');
    expect(ok.valid, isTrue);
    expect(ok.vin, '1FTFW3L87RKF38272');

    final shortVin = NhtsaRecallService.validateAndNormalizeVin('1FTFW3L87');
    expect(shortVin.valid, isFalse);
    expect(shortVin.error, contains('17 characters'));

    final badLetter =
        NhtsaRecallService.validateAndNormalizeVin('1FTFW3L87RKFO8272');
    expect(badLetter.valid, isFalse);
    expect(badLetter.error, contains('I, O, or Q'));

    final parsedDate = NhtsaRecallService.parseNhtsaReportDate('10/05/2024');
    expect(parsedDate.isoDate, '2024-05-10');
    expect(parsedDate.displayDate, 'May 10, 2024');

    const decodedBronco4Dr = DecodedVinVehicle(
      vin: '1FMDE5BH0SLA10001',
      year: 2025,
      make: 'Ford',
      model: 'Bronco',
      doors: '4',
      fuelType: 'Gasoline',
    );
    final broncoModels = NhtsaRecallService.selectMatchingNhtsaRecallModels(
      decodedBronco4Dr,
      const ['BRONCO 2DR', 'BRONCO 4DR', 'BRONCO SPORT'],
    );
    expect(broncoModels, contains('BRONCO 4DR'));
    expect(broncoModels, isNot(contains('BRONCO 2DR')));
    expect(broncoModels, isNot(contains('BRONCO SPORT')));
  });

  testWidgets(
      'MainShellScreen exposes Page 3 (VIN Recall Check) and VinRecallScreen checks www.nhtsa.gov/recalls via Gemini',
      (WidgetTester tester) async {
    LocalScoutEngine.resetForTest();
    const storeChannel = MethodChannel('com.prestonmotor.scout/launcher_widget');
    String persistedStore = jsonEncode({
      'guests': [],
      'matches': [],
      'recallChecks': [],
      'settings': {'calendarPromptDismissed': true},
    });

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

    NhtsaRecallService.mockCheckHandler = (vin) async {
      if (vin == '1FTFW3L87RKF38272') {
        return VinRecallCheckResult(
          id: 'test-recall-1',
          vin: vin,
          nhtsaUrl: 'https://www.nhtsa.gov/recalls?vin=$vin',
          nhtsaSiteReachable: true,
          checkedAt: '2026-11-20T15:00:00Z',
          agentMode: 'gemini (gemini-2.5-flash)',
          vehicleTitle: '2024 Ford F-150 XLT',
          vehicle: DecodedVinVehicle(
            vin: vin,
            year: 2024,
            make: 'Ford',
            model: 'F-150',
            trim: 'XLT',
            bodyClass: 'Pickup • Crew Cab',
            driveType: '4WD',
            engine: '5.0L 8-Cyl Gasoline',
            fuelType: 'Gasoline',
            plant: 'Dearborn, Michigan, United States',
          ),
          queriedModels: const ['F-150'],
          hasRecalls: true,
          recallCount: 1,
          totalModelRecalls: 1,
          verdictHeadline: '1 NHTSA Recall Campaign Found for 2024 Ford F-150 XLT',
          geminiSummary:
              'Gemini checked www.nhtsa.gov/recalls for VIN 1FTFW3L87RKF38272 and identified 1 applicable NHTSA safety recall campaign.',
          recommendedAction:
              'Verify VIN repair completion on www.nhtsa.gov/recalls or with Ford service.',
          recalls: const [
            NhtsaRecallCampaign(
              campaignNumber: '25V011000',
              manufacturer: 'Ford Motor Company',
              component: 'ELECTRICAL SYSTEM: INSTRUMENT CLUSTER',
              reportDate: 'Jan 15, 2025',
              reportIsoDate: '2025-01-15',
              summary: 'Instrument panel cluster software may blank out while driving.',
              consequence: 'Loss of speedometer display increases risk of a crash.',
              remedy: 'Dealers will update the IPC software free of charge.',
              overTheAirUpdate: true,
              applicability: 'Matches Decoded Vehicle',
              geminiNote: 'Applies to 2024 Ford F-150 XLT builds.',
            ),
          ],
        );
      }
      return VinRecallCheckResult(
        id: 'test-recall-clean',
        vin: vin,
        nhtsaUrl: 'https://www.nhtsa.gov/recalls?vin=$vin',
        nhtsaSiteReachable: true,
        checkedAt: '2026-11-20T15:05:00Z',
        agentMode: 'gemini (gemini-2.5-flash)',
        vehicleTitle: '2026 Ford F-250 XL',
        vehicle: DecodedVinVehicle(
          vin: vin,
          year: 2026,
          make: 'Ford',
          model: 'F-250',
          trim: 'XL',
        ),
        queriedModels: const ['F-250 SD'],
        hasRecalls: false,
        recallCount: 0,
        totalModelRecalls: 0,
        verdictHeadline: 'No Matching NHTSA Recalls Found for 2026 Ford F-250 XL',
        geminiSummary:
            'Checked www.nhtsa.gov/recalls for VIN $vin: 0 safety recall campaigns are on file.',
        recommendedAction: 'No open NHTSA recalls found.',
        recalls: const [],
      );
    };

    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1200, 1100);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      MaterialApp(
        home: MainShellScreen(
          themeMode: ThemeMode.light,
          onToggleTheme: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Verify Page 3 navigation tab exists and switches to VinRecallScreen
    expect(find.text('VIN Recall Check'), findsOneWidget);
    await tester.tap(find.text('VIN Recall Check'));
    await tester.pumpAndSettle();

    expect(find.byType(VinRecallScreen), findsOneWidget);
    expect(find.text('Gemini NHTSA VIN Recall Checker'), findsOneWidget);
    expect(find.byKey(const ValueKey('vin_recall_input')), findsOneWidget);

    // 1. Check a VIN that has an active NHTSA recall campaign
    await tester.enterText(
      find.byKey(const ValueKey('vin_recall_input')),
      '1ftfw3l87rkf38272',
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('check_vin_recalls_button')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('vin_recall_verdict_card')), findsOneWidget);
    expect(find.text('1 INCOMPLETE RECALL FOUND'), findsOneWidget);
    expect(
      find.text('1 NHTSA Recall Campaign Found for 2024 Ford F-150 XLT'),
      findsOneWidget,
    );
    expect(find.text('NHTSA #25V011000'), findsOneWidget);
    expect(
      find.text('ELECTRICAL SYSTEM: INSTRUMENT CLUSTER'),
      findsOneWidget,
    );

    // 2. Check a VIN with 0 recalls
    await tester.enterText(
      find.byKey(const ValueKey('vin_recall_input')),
      '1FT7X2BA0TED12345',
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('check_vin_recalls_button')));
    await tester.pumpAndSettle();

    expect(find.text('0 MATCHING NHTSA RECALLS'), findsOneWidget);
    expect(
      find.text('No Matching NHTSA Recalls Found for 2026 Ford F-250 XL'),
      findsOneWidget,
    );

    NhtsaRecallService.mockCheckHandler = null;
    LocalScoutEngine.cancelSchedulerForTest();
    LocalScoutEngine.resetForTest();
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(storeChannel, null);
  });

  testWidgets(
      'Clicking a VIN number or Stock number immediately copies the clean value to clipboard with one click',
      (WidgetTester tester) async {
    LocalScoutEngine.resetForTest();
    const storeChannel = MethodChannel('com.prestonmotor.scout/launcher_widget');
    String clipboardText = '';

    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          final args = call.arguments as Map?;
          clipboardText = args?['text']?.toString() ?? '';
          return null;
        }
        if (call.method == 'Clipboard.getData') {
          return <String, dynamic>{'text': clipboardText};
        }
        return null;
      },
    );

    final persistedStore = jsonEncode({
      'guests': [
        {
          'id': 'guest-copy-1',
          'name': 'Taylor Reed',
          'make': 'Ford',
          'model': 'F-150',
          'createdAt': '2026-11-20T12:00:00Z',
          'initialSearchCompleted': true,
        }
      ],
      'matches': [
        {
          'id': 'match-copy-1',
          'guestId': 'guest-copy-1',
          'vin': '1FTFW3L87RKF38272',
          'stockNumber': 'K60421',
          'title': '2024 Ford F-150 XLT',
          'price': 48990.0,
          'location': 'Preston Ford of Hurlock',
          'mileage': 15,
          'condition': 'New',
          'foundAt': '2026-11-20T12:05:00Z',
          'lastSeenAt': '2026-11-20T12:05:00Z',
        }
      ],
      'settings': {'calendarPromptDismissed': true},
    });

    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      storeChannel,
      (call) async {
        if (call.method == 'readLocalStore') return persistedStore;
        return true;
      },
    );

    int cardOpenCount = 0;
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1100, 900);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    // 1. Test 1-click copy on GuestMatchesScreen match card without triggering card open
    await tester.pumpWidget(
      MaterialApp(
        home: GuestMatchesScreen(
          guestId: 'guest-copy-1',
          onDataChanged: () {},
          onSelectMatch: (_, _) => cardOpenCount++,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('VIN: 1FTFW3L87RKF38272'), findsOneWidget);
    expect(find.text('Stock #K60421'), findsOneWidget);

    await tester.tap(find.text('VIN: 1FTFW3L87RKF38272'));
    await tester.pump();
    expect(clipboardText, '1FTFW3L87RKF38272');
    expect(cardOpenCount, 0);
    expect(
      find.text('Copied VIN to clipboard: 1FTFW3L87RKF38272'),
      findsOneWidget,
    );

    await tester.tap(find.text('Stock #K60421'));
    await tester.pump();
    expect(clipboardText, 'K60421');
    expect(cardOpenCount, 0);
    expect(
      find.text('Copied Stock # to clipboard: K60421'),
      findsOneWidget,
    );

    // Drain badge reset timer
    await tester.pump(const Duration(seconds: 3));

    // 2. Test 1-click copy on MatchDetailScreen
    const guest = GuestProfile(
      id: 'guest-copy-1',
      name: 'Taylor Reed',
      createdAt: '2026-11-20T12:00:00Z',
    );
    const detailMatch = VehicleMatch(
      id: 'match-copy-2',
      guestId: 'guest-copy-1',
      vin: '2LMPJ8KP3LBL00851',
      stockNumber: 'GLM26149A',
      title: '2020 Lincoln Nautilus Reserve',
      price: 19500,
      location: 'Boulevard Ford of Millsboro',
      foundAt: '2026-11-20T12:05:00Z',
      lastSeenAt: '2026-11-20T12:05:00Z',
    );

    await tester.pumpWidget(
      const MaterialApp(
        home: MatchDetailScreen(match: detailMatch, guest: guest),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('VIN: 2LMPJ8KP3LBL00851'));
    await tester.pump();
    expect(clipboardText, '2LMPJ8KP3LBL00851');

    await tester.tap(find.text('Stock #GLM26149A'));
    await tester.pump();
    expect(clipboardText, 'GLM26149A');

    await tester.pump(const Duration(seconds: 3));

    LocalScoutEngine.cancelSchedulerForTest();
    LocalScoutEngine.resetForTest();
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(storeChannel, null);
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  testWidgets(
      'HomeIntakeScreen allows choosing multiple colors on initial search and matches vehicles in any selected color',
      (WidgetTester tester) async {
    LocalScoutEngine.resetForTest();

    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1100, 1200);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HomeIntakeScreen(
            status: const SystemStatus(geminiConfigured: true),
            onGuestCreated: () {},
            onOpenGuestMatches: (_) {},
            onOpenSettings: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Exterior Colors section is tucked under a collapsed dropdown by default
    expect(
      find.byKey(const ValueKey('dropdown_exterior_colors')),
      findsOneWidget,
    );
    expect(find.text('Any Color'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('multi_exterior_color_selector')),
      findsNothing,
    );

    // Expand the Exterior Colors dropdown
    await tester.tap(find.byKey(const ValueKey('dropdown_exterior_colors')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('multi_exterior_color_selector')),
      findsOneWidget,
    );

    // Select 3 colors: White, Blue, and Gray
    await tester.tap(find.byKey(const ValueKey('color_chip_white')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('color_chip_blue')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('color_chip_gray')));
    await tester.pumpAndSettle();

    expect(find.text('3 selected (matches any)'), findsOneWidget);
    expect(find.text('3 selected: White, Blue +1'), findsOneWidget);
    expect(find.text('Colors: White, Blue, Gray'), findsOneWidget);

    // Also add a custom OEM paint color ("Rapid Red")
    await tester.enterText(
      find.byKey(const ValueKey('custom_exterior_color_input')),
      'Rapid Red',
    );
    await tester.tap(find.byKey(const ValueKey('add_custom_color_button')));
    await tester.pumpAndSettle();

    expect(find.text('4 selected (matches any)'), findsOneWidget);
    expect(find.text('Colors: White, Blue, Gray, Rapid Red'), findsOneWidget);

    // Verify engine evaluation matches ANY of the chosen colors (including OEM paint names
    // like Oxford White, Velocity Blue, Carbonized Gray Metallic, Rapid Red) and excludes Black/Green
    final multiColorGuest = GuestProfile.fromJson(
      LocalScoutEngine.normalizeSpecsForTest({
        'id': 'guest-multicolor',
        'name': 'Casey Morgan',
        'make': 'Ford',
        'model': 'F-150',
        'exteriorColor': 'White, Blue, Gray, Rapid Red',
        'createdAt': '2026-11-20T16:00:00Z',
      }),
    );

    final sampleInventory = <Map<String, dynamic>>[
      {
        'vin': '1FTFW1E50TFA10001',
        'title': '2026 Ford F-150 XLT',
        'year': 2026,
        'make': 'Ford',
        'model': 'F-150',
        'trim': 'XLT',
        'condition': 'New',
        'price': 51000.0,
        'location': 'Preston Ford of Hurlock',
        'exteriorColor': 'Oxford White',
      },
      {
        'vin': '1FTFW1E50TFA10002',
        'title': '2026 Ford F-150 XLT',
        'year': 2026,
        'make': 'Ford',
        'model': 'F-150',
        'trim': 'XLT',
        'condition': 'New',
        'price': 52000.0,
        'location': 'Boulevard Ford of Millsboro',
        'exteriorColor': 'Antimatter Blue Metallic',
      },
      {
        'vin': '1FTFW1E50TFA10003',
        'title': '2026 Ford F-150 Lariat',
        'year': 2026,
        'make': 'Ford',
        'model': 'F-150',
        'trim': 'Lariat',
        'condition': 'New',
        'price': 56000.0,
        'location': 'Preston Ford of Denton',
        'exteriorColor': 'Carbonized Gray Metallic',
      },
      {
        'vin': '1FTFW1E50TFA10004',
        'title': '2026 Ford F-150 Lariat',
        'year': 2026,
        'make': 'Ford',
        'model': 'F-150',
        'trim': 'Lariat',
        'condition': 'New',
        'price': 56500.0,
        'location': 'Preston Ford of Keller',
        'exteriorColor': 'Rapid Red Metallic Tinted Clearcoat',
      },
      {
        'vin': '1FTFW1E50TFA10005',
        'title': '2026 Ford F-150 XLT',
        'year': 2026,
        'make': 'Ford',
        'model': 'F-150',
        'trim': 'XLT',
        'condition': 'New',
        'price': 50500.0,
        'location': 'Preston Ford of Hurlock',
        'exteriorColor': 'Agate Black Metallic',
      },
      {
        'vin': '1FTFW1E50TFA10006',
        'title': '2026 Ford F-150 XLT',
        'year': 2026,
        'make': 'Ford',
        'model': 'F-150',
        'trim': 'XLT',
        'condition': 'New',
        'price': 50900.0,
        'location': 'Preston Ford of Hurlock',
        'exteriorColor': 'Eruption Green Metallic',
      },
    ];

    final matches =
        LocalScoutEngine.evaluateAllForTest(multiColorGuest, sampleInventory);
    final matchedVins =
        matches.map((m) => (m['vehicle'] as Map)['vin'].toString()).toSet();

    expect(matches.length, 4);
    expect(matchedVins, containsAll([
      '1FTFW1E50TFA10001',
      '1FTFW1E50TFA10002',
      '1FTFW1E50TFA10003',
      '1FTFW1E50TFA10004',
    ]));
    expect(matchedVins, isNot(contains('1FTFW1E50TFA10005')));
    expect(matchedVins, isNot(contains('1FTFW1E50TFA10006')));

    LocalScoutEngine.resetForTest();
  });

  testWidgets(
      'Search criteria can be edited inside the Vehicle Matches page after initial search, clearing stale matches and re-evaluating',
      (WidgetTester tester) async {
    LocalScoutEngine.resetForTest();
    const storeChannel = MethodChannel('com.prestonmotor.scout/launcher_widget');
    String persistedStore = jsonEncode({
      'guests': [],
      'matches': [],
      'settings': {'calendarPromptDismissed': true},
    });

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

    final mockInventory = <Map<String, dynamic>>[
      {
        'vin': '1FTFW3L87RKF10001',
        'stockNumber': 'K1001',
        'title': '2025 Ford F-150 XLT',
        'year': 2025,
        'make': 'Ford',
        'model': 'F-150',
        'trim': 'XLT',
        'bedLength': '5.5',
        'condition': 'New',
        'price': 49900.0,
        'location': 'Preston Ford of Hurlock',
        'drivetrain': '4WD',
        'exteriorColor': 'Oxford White',
      },
      {
        'vin': '1FTFW5L89RKF20002',
        'stockNumber': 'K2002',
        'title': '2025 Ford F-150 Lariat',
        'year': 2025,
        'make': 'Ford',
        'model': 'F-150',
        'trim': 'Lariat',
        'bedLength': '6.5',
        'condition': 'New',
        'price': 59500.0,
        'location': 'Boulevard Ford of Millsboro',
        'drivetrain': '4WD',
        'exteriorColor': 'Antimatter Blue Metallic',
      },
    ];

    // 1. Run initial search for Ford F-150 XLT under $55,000 -> matches ONLY K1001 (XLT)
    final initial = await LocalScoutEngine.createGuest(
      name: 'Morgan Hayes',
      make: 'Ford',
      model: 'F-150',
      trim: 'XLT',
      maxPrice: 55000,
      exteriorColor: 'White',
      mockCandidatesOverride: mockInventory,
    );
    expect(initial.matchesFound, 1);

    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1200, 1000);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    // 2. Open GuestMatchesScreen after initial search and verify Edit Search buttons & pre-populated dialog
    await tester.pumpWidget(
      MaterialApp(
        home: GuestMatchesScreen(
          guestId: initial.guest.id,
          onDataChanged: () {},
          onSelectMatch: (_, _) {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('appbar_edit_search_button')), findsOneWidget);
    final targetId = initial.guest.effectiveTargets.first.id;
    final cardEditBtn = find.byKey(ValueKey('edit_vehicle_target_$targetId'));
    expect(cardEditBtn, findsOneWidget);
    expect(find.text('2025 Ford F-150 XLT'), findsOneWidget);

    // Tap Edit Search inside the Vehicle Matches page
    await tester.tap(cardEditBtn);
    await tester.pumpAndSettle();

    expect(
      find.text('Edit Search Criteria for Morgan Hayes'),
      findsOneWidget,
    );
    expect(find.text('Save Changes & Re-Search'), findsOneWidget);

    // Verify existing criteria are pre-populated in the Edit Search dialog
    final trimField = tester.widget<TextField>(
      find.byKey(const ValueKey('dialog_trim_input')),
    );
    expect(trimField.controller?.text, 'XLT');
    expect(find.text('1 selected (matches any)'), findsOneWidget);

    // Close dialog cleanly, then verify engine updateVehicleTargetOnGuest replaces XLT with Lariat 6.5ft Blue
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    final updated = await LocalScoutEngine.updateVehicleTargetOnGuest(
      guestId: initial.guest.id,
      targetId: targetId,
      condition: 'New',
      make: 'Ford',
      model: 'F-150',
      trim: 'Lariat',
      bedLength: '6.5',
      maxPrice: 62000,
      drivetrain: '4WD',
      exteriorColor: 'Blue, Gray',
      mockCandidatesOverride: mockInventory,
    );

    // Stale XLT match (1FTFW3L87RKF10001) is removed; only Lariat 6.5ft Blue (1FTFW5L89RKF20002) remains!
    expect(updated.guest.trim, 'Lariat');
    expect(updated.guest.bedLength, '6.5');
    expect(updated.guest.exteriorColor, 'Blue, Gray');
    expect(updated.matches.length, 1);
    expect(updated.matches.first.vin, '1FTFW5L89RKF20002');
    expect(updated.matches.first.title, '2025 Ford F-150 Lariat');

    // Drain 700ms GoogleDriveSyncService.scheduleAutoSave debounce timer
    await tester.pump(const Duration(seconds: 1));

    LocalScoutEngine.cancelSchedulerForTest();
    LocalScoutEngine.resetForTest();
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(storeChannel, null);
  });

  test(
      'NhtsaRecallService differentiates Complete vs. Incomplete recalls per VIN (UTF-16LE Base64, OEM recall extraction, HTML parsing, and reconciliation)',
      () {
    // 1. UTF-16LE Base64 VIN encoding matches Node Buffer.from(vin, 'utf16le').toString('base64')
    expect(
      NhtsaRecallService.encodeVinUtf16LeBase64('1FM5K8B80HGA84949'),
      'MQBGAE0ANQBLADgAQgA4ADAAaABnAGEAOAA0ADkANAA5AA=='
          .replaceAll('aABnAGEA', 'SABHAEEA'),
    );
    expect(
      NhtsaRecallService.extractOemRecallNumber([
        "Dealers will inspect and replace the molding. Ford's number for this recall is 25S53.",
      ]),
      '25S53',
    );
    expect(NhtsaRecallService.normalizeNhtsaPrefix('25V347000'), '25V347');

    // 2. Parse 0-open-recall HTML vs 1-open-recall HTML
    final cleanParsed = NhtsaRecallService.parseVinOpenRecallHtml('''
      <!-- Open Recall Check-->
      <div class="card"><p class="large-title">Open Recall Check</p>
      <div class="card-footer"><span>No Open Recalls</span></div></div>
    ''');
    expect(cleanParsed.verified, isTrue);
    expect(cleanParsed.openRecallCount, 0);
    expect(cleanParsed.openRecalls, isEmpty);

    final openParsed = NhtsaRecallService.parseVinOpenRecallHtml('''
      <p class="large-title">Open Recall Check</p>
      <span>1 Open Recall</span>
      <div id="recallSection">
        <div class="rTableBody">
          <div class="rTableRow">
            <div class="rTableCell"><span>05/27/2025</span></div>
            <div class="rTableCell"><span>Safety</span></div>
            <div class="rTableCell"><span>25V347 / 25S53</span></div>
            <div class="rTableCell w-40">
              <span>Safety Recall: EXTERIOR B-PILLAR APPLIQUE MOLDING INSPECTION</span><br/><span>Status: Remedy Not Available</span>
            </div>
          </div>
        </div>
        <!-- Mobile -->
        <div class="rTableRow"><div class="rTableCell">Duplicate mobile row ignored</div></div>
      </div>
    ''');
    expect(openParsed.verified, isTrue);
    expect(openParsed.openRecallCount, 1);
    expect(openParsed.openRecalls.length, 1);
    expect(openParsed.openRecalls.first.nhtsaPrefix, '25V347');
    expect(openParsed.openRecalls.first.oemRecallNumber, '25S53');
    expect(openParsed.openRecalls.first.statusText, 'Remedy Not Available');

    // 3. Reconcile 3 model-level NHTSA recalls against the 1 open VIN recall -> 1 Incomplete + 2 Complete
    const decoded = DecodedVinVehicle(
      vin: '1FM5K8B80HGA84949',
      year: 2017,
      make: 'Ford',
      model: 'Explorer',
    );
    final reconciled = NhtsaRecallService.reconcileVinRecallCompletion(
      decoded: decoded,
      vinOpenCheck: openParsed,
      recalls: const [
        NhtsaRecallCampaign(
          campaignNumber: '24V100000',
          component: 'REAR SUSPENSION TOE LINK',
          reportDate: 'Feb 12, 2024',
          reportIsoDate: '2024-02-12',
          remedy: "Dealers will replace toe links. Ford's number for this recall is 24S11.",
        ),
        NhtsaRecallCampaign(
          campaignNumber: '25V347000',
          component: 'EXTERIOR B-PILLAR APPLIQUE MOLDING',
          reportDate: 'May 27, 2025',
          reportIsoDate: '2025-05-27',
          remedy: "Remedy is currently under development. Ford's number for this recall is 25S53.",
        ),
        NhtsaRecallCampaign(
          campaignNumber: '23V200000',
          component: 'REAR VIEW CAMERA',
          reportDate: 'Mar 10, 2023',
          reportIsoDate: '2023-03-10',
          remedy: "Dealers will update software. Ford's number for this recall is 23S22.",
        ),
      ],
    );

    expect(reconciled.vinCompletionVerified, isTrue);
    expect(reconciled.incompleteCount, 1);
    expect(reconciled.completeCount, 2);
    // Incomplete recall is sorted first
    expect(reconciled.recalls.first.campaignNumber, '25V347000');
    expect(reconciled.recalls.first.oemRecallNumber, '25S53');
    expect(reconciled.recalls.first.completionStatus, 'incomplete_no_remedy');
    expect(reconciled.recalls.first.isIncomplete, isTrue);
    expect(reconciled.recalls[1].isComplete, isTrue);
    expect(reconciled.recalls[2].isComplete, isTrue);
  });

  testWidgets(
      'VinRecallScreen differentiates Incomplete vs. Complete recalls, filters by status, and toggles Mark Complete / Mark Incomplete',
      (WidgetTester tester) async {
    LocalScoutEngine.resetForTest();
    const storeChannel = MethodChannel('com.prestonmotor.scout/launcher_widget');
    String persistedStore = jsonEncode({
      'guests': [],
      'matches': [],
      'recallChecks': [],
      'recallStatusOverrides': {},
      'recallResultsByVin': {},
      'settings': {'calendarPromptDismissed': true},
    });

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

    NhtsaRecallService.mockCheckHandler = (vin) async {
      return VinRecallCheckResult(
        id: 'recall-explorer-mix',
        vin: vin,
        nhtsaUrl: 'https://www.nhtsa.gov/recalls?vin=$vin',
        nhtsaSiteReachable: true,
        vinCompletionVerified: true,
        checkedAt: '2026-11-20T16:30:00Z',
        agentMode: 'gemini (gemini-2.5-flash)',
        vehicleTitle: '2017 Ford Explorer Base',
        vehicle: DecodedVinVehicle(
          vin: vin,
          year: 2017,
          make: 'Ford',
          model: 'Explorer',
          trim: 'Base',
        ),
        queriedModels: const ['EXPLORER'],
        hasRecalls: true,
        recallCount: 1,
        incompleteCount: 1,
        completeCount: 2,
        totalModelRecalls: 3,
        verdictHeadline:
            '1 Incomplete Recall • 2 Complete Recalls for 2017 Ford Explorer Base',
        geminiSummary:
            'VIN $vin has 1 INCOMPLETE (open) recall and 2 COMPLETE (closed) recalls.',
        recommendedAction:
            'Schedule Ford Service repair for open campaign 25V347000.',
        recalls: const [
          NhtsaRecallCampaign(
            campaignNumber: '25V347000',
            oemRecallNumber: '25S53',
            manufacturer: 'Ford Motor Company',
            component: 'STRUCTURE: BODY: EXTERIOR MOLDING',
            reportDate: 'May 27, 2025',
            reportIsoDate: '2025-05-27',
            summary: 'B-pillar exterior applique trim may detach.',
            remedy: 'Dealers will inspect and replace B-pillar molding.',
            completionStatus: 'incomplete_no_remedy',
            completionSource: 'vin_live_lookup',
            remedyAvailable: false,
            vinStatusNote:
                'Confirmed INCOMPLETE on this VIN (Remedy Not Available).',
          ),
          NhtsaRecallCampaign(
            campaignNumber: '24V100000',
            oemRecallNumber: '24S11',
            manufacturer: 'Ford Motor Company',
            component: 'SUSPENSION: REAR TOE LINK',
            reportDate: 'Feb 12, 2024',
            reportIsoDate: '2024-02-12',
            summary: 'Rear toe link fracture inspection.',
            remedy: 'Dealers replaced rear suspension toe links.',
            completionStatus: 'complete',
            completionSource: 'vin_live_lookup',
            remedyAvailable: true,
            vinStatusNote: 'Confirmed COMPLETE / CLOSED on this VIN.',
          ),
          NhtsaRecallCampaign(
            campaignNumber: '23V200000',
            oemRecallNumber: '23S22',
            manufacturer: 'Ford Motor Company',
            component: 'BACK OVER PREVENTION: CAMERA',
            reportDate: 'Mar 10, 2023',
            reportIsoDate: '2023-03-10',
            summary: 'Rear view camera image blue screen.',
            remedy: 'Software update completed.',
            completionStatus: 'complete',
            completionSource: 'vin_live_lookup',
            remedyAvailable: true,
            vinStatusNote: 'Confirmed COMPLETE / CLOSED on this VIN.',
          ),
        ],
      );
    };

    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1200, 1400);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: VinRecallScreen(
            initialVin: '1FM5K8B80HGA84949',
            autoCheckOnInit: true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Verify Complete vs. Incomplete KPI cards & badges
    expect(find.text('1 INCOMPLETE RECALL FOUND'), findsOneWidget);
    expect(find.text('1 Incomplete (Open)'), findsOneWidget);
    expect(find.text('2 Complete (Closed)'), findsOneWidget);
    expect(find.text('INCOMPLETE • REMEDY NOT AVAILABLE'), findsOneWidget);
    expect(find.text('OEM #25S53'), findsOneWidget);
    expect(find.text('COMPLETE • CLOSED ON VIN'), findsNWidgets(2));
    expect(find.text('1 incomplete • 2 complete'), findsOneWidget);

    // Filter to Incomplete (1) only
    await tester.tap(find.byKey(const ValueKey('filter_incomplete_recalls_chip')));
    await tester.pumpAndSettle();
    expect(find.text('NHTSA #25V347000'), findsOneWidget);
    expect(find.text('NHTSA #24V100000'), findsNothing);

    // Filter to Complete (2) only
    await tester.tap(find.byKey(const ValueKey('filter_complete_recalls_chip')));
    await tester.pumpAndSettle();
    expect(find.text('NHTSA #25V347000'), findsNothing);
    expect(find.text('NHTSA #24V100000'), findsOneWidget);
    expect(find.text('NHTSA #23V200000'), findsOneWidget);

    // Switch back to All (3) and click "Mark Complete" on 25V347000
    await tester.tap(find.byKey(const ValueKey('filter_all_recalls_chip')));
    await tester.pumpAndSettle();
    final markCompleteBtn =
        find.byKey(const ValueKey('toggle_recall_status_25V347000'));
    await tester.ensureVisible(markCompleteBtn);
    await tester.tap(markCompleteBtn);
    await tester.pumpAndSettle();

    // Counts immediately update to 0 Incomplete + 3 Complete!
    expect(find.text('0 INCOMPLETE RECALLS • 3 COMPLETE'), findsOneWidget);
    expect(find.text('0 Incomplete (Open)'), findsOneWidget);
    expect(find.text('3 Complete (Closed)'), findsOneWidget);
    expect(find.text('0 incomplete • 3 complete'), findsOneWidget);

    NhtsaRecallService.mockCheckHandler = null;
    LocalScoutEngine.cancelSchedulerForTest();
    LocalScoutEngine.resetForTest();
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(storeChannel, null);
  });

  test(
      'F-150 search parses live DealerOn string-typed Length fields, resolves F-150 across Make/Model/Notes, and returns all 105+ matching F-150s instead of 0',
      () async {
    LocalScoutEngine.resetForTest();
    const storeChannel = MethodChannel('com.prestonmotor.scout/launcher_widget');
    String persistedStore = jsonEncode({
      'guests': [],
      'matches': [],
      'settings': {'calendarPromptDismissed': true},
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
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

    // 1. Real prestonmotor.com DealerOn VehicleCard payload where "Length": "227.7" is a JSON String
    final liveF150RegularCabCard = <String, dynamic>{
      'VehicleVin': '1FTMF1KP4TKD16220',
      'VehicleStockNumber': 'K60110',
      'VehicleYear': '2026',
      'VehicleMake': 'Ford',
      'VehicleModel': 'F-150',
      'VehicleTrim': 'XL',
      'VehicleName': '2026 Ford F-150 XL',
      'VehicleBodyStyle': 'Regular Cab Pickup',
      'VehicleCondition': 'New',
      'VehicleInternetPrice': '41290',
      'VehicleMsrp': '44185',
      'VehicleMileage': '8',
      'Length': '227.7',
      'VehicleLocationLabel': 'Preston Ford of Hurlock',
      'DealerLocatedAtCity': 'Hurlock',
      'DealerLocatedAtState': 'MD',
      'VehicleDriveTrain': '4WD',
      'VehicleEngine': '2.7L V6 EcoBoost',
      'ExteriorColorLabel': 'Oxford White',
      'InteriorColorLabel': 'Medium Dark Slate',
      'VehicleComments': '2026 Ford F-150 XL Regular Cab 4x4 141WB 8ft Box.',
    };

    final parsedCard =
        LocalScoutEngine.parseVehicleCardForTest(liveF150RegularCabCard);
    expect(parsedCard, isNotNull);
    expect(parsedCard!['vin'], '1FTMF1KP4TKD16220');
    expect(parsedCard['make'], 'Ford');
    expect(parsedCard['model'], 'F-150');
    expect(parsedCard['year'], 2026);
    expect(parsedCard['price'], 41290.0);
    expect(parsedCard['vehicleLength'], 227.7);
    expect(parsedCard['bedLength'], "8'");

    // 2. Verify F-150 input variations (in Model, Make, or Notes) all resolve to Make=Ford, Model=F-150
    for (final rawInput in <Map<String, dynamic>>[
      {'make': 'Ford', 'model': 'F-150'},
      {'make': 'ford', 'model': 'F150'},
      {'make': '', 'model': 'F-150'},
      {'make': 'F-150', 'model': ''},
      {'make': 'Ford F-150', 'model': ''},
      {'make': '', 'model': '', 'notes': 'F-150'},
    ]) {
      final norm = NaturalLanguageVehicleParser.parseCriteriaMap(rawInput);
      expect(norm['make'], 'Ford', reason: 'Failed make for $rawInput');
      expect(norm['model'], 'F-150', reason: 'Failed model for $rawInput');
    }

    // 3. Bed-length facet & comparison normalization handles both '6.5' (chip) and "6.5'" (parser)
    expect(
      NaturalLanguageVehicleParser.bedLengthToCosmosFacetValues('6.5'),
      equals(const ["6-1/2' Box"]),
    );
    expect(
      NaturalLanguageVehicleParser.bedLengthToCosmosFacetValues("6.5'"),
      equals(const ["6-1/2' Box"]),
    );

    // 4. Searching for "F-150" across 105 live-format F-150s returns all 105 matches (never 0, never capped at 30)
    final stores = const [
      'Preston Ford of Hurlock',
      'Preston Ford of Denton',
      'Preston Ford of Keller',
      'Preston Ford West',
      'Boulevard Ford of Millsboro',
      'Boulevard Ford of Lewes',
    ];
    final trims = const ['XL', 'STX', 'XLT', 'Lariat', 'King Ranch', 'Platinum'];
    final live105F150Cards = List<Map<String, dynamic>>.generate(105, (i) {
      final vinSuffix = (100000 + i).toString();
      final card = <String, dynamic>{
        'VehicleVin': '1FTFW3L87TK$vinSuffix',
        'VehicleStockNumber': 'F${6000 + i}',
        'VehicleYear': 2025 + (i % 2),
        'VehicleMake': 'Ford',
        'VehicleModel': 'F-150',
        'VehicleTrim': trims[i % trims.length],
        'VehicleName':
            '${2025 + (i % 2)} Ford F-150 ${trims[i % trims.length]}',
        'VehicleBodyStyle': 'SuperCrew',
        'VehicleCondition': i < 85 ? 'New' : 'Pre-Owned',
        'VehicleInternetPrice': '${43500 + (i * 250)}',
        'VehicleMsrp': '${46500 + (i * 250)}',
        'VehicleMileage': i < 85 ? '12' : '${18400 + i * 100}',
        'Length': i % 3 == 0 ? '243.5' : '231.7',
        'VehicleLocationLabel': stores[i % stores.length],
        'DealerLocatedAtCity': 'Hurlock',
        'DealerLocatedAtState': 'MD',
        'VehicleDriveTrain': '4WD',
        'ExteriorColorLabel': i % 2 == 0 ? 'Oxford White' : 'Carbonized Gray',
      };
      return LocalScoutEngine.parseVehicleCardForTest(card)!;
    });

    final created = await LocalScoutEngine.createGuest(
      name: 'F-150 Shopper',
      make: '',
      model: 'F-150',
      mockCandidatesOverride: live105F150Cards,
    );

    expect(created.guest.make, 'Ford');
    expect(created.guest.model, 'F-150');
    expect(created.matchesFound, 105);
    expect(created.guest.matchCount, 105);

    LocalScoutEngine.cancelSchedulerForTest();
    LocalScoutEngine.resetForTest();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(storeChannel, null);
  });

  testWidgets(
      'HomeIntakeScreen ("Guest & Vehicle" input page) exposes Number of Doors field and shows live Doors preview chip',
      (WidgetTester tester) async {
    LocalScoutEngine.resetForTest();
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1200, 1100);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HomeIntakeScreen(
            status: const SystemStatus(geminiConfigured: true),
            onGuestCreated: () {},
            onOpenGuestMatches: (_) {},
            onOpenSettings: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final specsDropdown = find.byKey(const ValueKey('dropdown_vehicle_specs'));
    expect(specsDropdown, findsOneWidget);
    expect(find.byKey(const ValueKey('number_of_doors_field')), findsNothing);

    await tester.tap(specsDropdown);
    await tester.pumpAndSettle();

    final doorsField = find.byKey(const ValueKey('number_of_doors_field'));
    expect(doorsField, findsOneWidget);
    expect(find.text('Number of Doors'), findsOneWidget);
    expect(find.text('Any Doors'), findsOneWidget);

    // Open dropdown and select "2 Doors"
    await tester.tap(doorsField);
    await tester.pumpAndSettle();
    await tester.tap(find.text('2 Doors').last);
    await tester.pumpAndSettle();

    final summaryBox =
        find.byKey(const ValueKey('parsed_natural_language_summary'));
    expect(summaryBox, findsOneWidget);
    expect(
      find.descendant(of: summaryBox, matching: find.text('Doors: 2 Doors')),
      findsOneWidget,
    );

    LocalScoutEngine.resetForTest();
  });

  test(
      'Number of Doors accurately filters 2-Door vs 4-Door vehicles (including Bronco E6A/E7B with "2-door Intelligent Access" and F-150 Regular Cab vs SuperCrew)',
      () async {
    LocalScoutEngine.resetForTest();
    const storeChannel = MethodChannel('com.prestonmotor.scout/launcher_widget');
    String persistedStore = jsonEncode({
      'guests': [],
      'matches': [],
      'settings': {'calendarPromptDismissed': true},
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
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

    final bronco2Door = LocalScoutEngine.parseVehicleCardForTest({
      'VehicleVin': '1FMDE6AH5TLB91567',
      'VehicleModelCode': 'E6A',
      'VehicleYear': '2026',
      'VehicleMake': 'Ford',
      'VehicleModel': 'Bronco',
      'VehicleTrim': 'Base',
      'VehicleName': '2026 Ford Bronco Base',
      'VehicleBodyStyle': 'Sport Utility',
      'VehicleBodyType': 'SUV',
      'VehicleCondition': 'New',
      'VehicleInternetPrice': '41500',
      'Length': '173.7',
      'VehicleLocationLabel': 'Preston Ford of Hurlock',
    })!;

    // Real 4-Door Bronco Big Bend whose Equipment Group 222A mentions "2-door Intelligent Access"
    final bronco4Door = LocalScoutEngine.parseVehicleCardForTest({
      'VehicleVin': '1FMDE7BHXTLB59525',
      'VehicleModelCode': 'E7B',
      'VehicleYear': '2026',
      'VehicleMake': 'Ford',
      'VehicleModel': 'Bronco',
      'VehicleTrim': 'Big Bend',
      'VehicleName': '2026 Ford Bronco Big Bend',
      'VehicleBodyStyle': 'Sport Utility',
      'VehicleBodyType': 'SUV',
      'VehicleCondition': 'New',
      'VehicleInternetPrice': '46900',
      'Length': '189.4',
      'VehicleLocationLabel': 'Preston Ford Aberdeen',
      'VehicleComments':
          'Includes Equipment Group 222A, 2-door Intelligent Access, dual-zone climate control.',
    })!;

    final f150RegCab2Door = LocalScoutEngine.parseVehicleCardForTest({
      'VehicleVin': '1FTMF1KP4TKD16220',
      'VehicleYear': '2026',
      'VehicleMake': 'Ford',
      'VehicleModel': 'F-150',
      'VehicleTrim': 'XL',
      'VehicleName': '2026 Ford F-150 XL',
      'VehicleBodyStyle': 'Regular Cab Pickup',
      'VehicleCondition': 'New',
      'VehicleInternetPrice': '41290',
      'Length': '227.7',
      'VehicleLocationLabel': 'Boulevard Ford of Millsboro',
    })!;

    final f150SuperCrew4Door = LocalScoutEngine.parseVehicleCardForTest({
      'VehicleVin': '1FTFW3L87TKE99999',
      'VehicleYear': '2026',
      'VehicleMake': 'Ford',
      'VehicleModel': 'F-150',
      'VehicleTrim': 'XLT',
      'VehicleName': '2026 Ford F-150 XLT',
      'VehicleBodyStyle': 'SuperCrew',
      'VehicleCondition': 'New',
      'VehicleInternetPrice': '52400',
      'Length': '231.7',
      'VehicleLocationLabel': 'Preston Ford of Denton',
    })!;

    expect(bronco2Door['doors'], '2');
    expect(bronco4Door['doors'], '4');
    expect(f150RegCab2Door['doors'], '2');
    expect(f150SuperCrew4Door['doors'], '4');

    final inventory = [
      bronco2Door,
      bronco4Door,
      f150RegCab2Door,
      f150SuperCrew4Door,
    ];

    // Guest looking specifically for a 2-Door Ford Bronco -> matches ONLY 1FMDE6AH5TLB91567
    final twoDoorBroncoRes = await LocalScoutEngine.createGuest(
      name: 'Alex Carter',
      make: 'Ford',
      model: 'Bronco',
      doors: '2',
      mockCandidatesOverride: inventory,
    );
    expect(twoDoorBroncoRes.guest.doors, '2');
    expect(twoDoorBroncoRes.guest.targetVehicleLabel, 'Ford Bronco • 2 Doors');
    expect(twoDoorBroncoRes.matchesFound, 1);

    final twoDoorMatches = await LocalScoutEngine.getGuestWithMatches(
      twoDoorBroncoRes.guest.id,
    );
    expect(twoDoorMatches.matches.single.vin, '1FMDE6AH5TLB91567');
    expect(
      twoDoorMatches.matches.single.matchedFeatures,
      contains('2 Doors Configuration'),
    );

    // Updating the search to 4 Doors -> switches match to 1FMDE7BHXTLB59525
    final updatedFourDoor = await LocalScoutEngine.updateVehicleTargetOnGuest(
      guestId: twoDoorBroncoRes.guest.id,
      targetId: twoDoorBroncoRes.guest.effectiveTargets.first.id,
      make: 'Ford',
      model: 'Bronco',
      doors: '4',
      mockCandidatesOverride: inventory,
    );
    expect(updatedFourDoor.guest.doors, '4');
    expect(updatedFourDoor.matches.length, 1);
    expect(updatedFourDoor.matches.single.vin, '1FMDE7BHXTLB59525');

    LocalScoutEngine.cancelSchedulerForTest();
    LocalScoutEngine.resetForTest();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(storeChannel, null);
  });

  testWidgets(
      'Search page places secondary elements under clean dropdowns to reduce clutter, supports Brand & Condition dropdowns, and toggles Expand/Collapse All with live summary badges',
      (WidgetTester tester) async {
    LocalScoutEngine.resetForTest();
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1200, 1100);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HomeIntakeScreen(
            status: const SystemStatus(geminiConfigured: true),
            onGuestCreated: () {},
            onOpenGuestMatches: (_) {},
            onOpenSettings: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 1. Core quick-search controls are visible immediately
    expect(find.text('Quick Guest & Vehicle Search'), findsOneWidget);
    expect(find.byKey(const ValueKey('condition_dropdown_field')), findsOneWidget);
    expect(find.byKey(const ValueKey('make_brand_dropdown_button')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('natural_language_search_input')),
      findsOneWidget,
    );

    // 2. Secondary clutter-heavy sections are tucked neatly under collapsed dropdowns
    expect(find.byKey(const ValueKey('dropdown_guest_contact')), findsOneWidget);
    expect(find.byKey(const ValueKey('dropdown_vehicle_specs')), findsOneWidget);
    expect(find.byKey(const ValueKey('dropdown_exterior_colors')), findsOneWidget);
    expect(find.byKey(const ValueKey('dropdown_features')), findsOneWidget);

    expect(find.text('Phone (Optional)'), findsNothing);
    expect(find.text('Trim / Cab / Series'), findsNothing);
    expect(find.byKey(const ValueKey('drivetrain_dropdown_field')), findsNothing);
    expect(find.byKey(const ValueKey('bed_length_dropdown_field')), findsNothing);
    expect(
      find.byKey(const ValueKey('multi_exterior_color_selector')),
      findsNothing,
    );
    expect(find.text('Leather Seats'), findsNothing);

    // 3. Quick Brand dropdown menu populates Make without 8-chip clutter
    await tester.tap(find.byKey(const ValueKey('make_brand_dropdown_button')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Lincoln').last);
    await tester.pumpAndSettle();
    expect(find.text('Lincoln'), findsOneWidget);

    // 4. Expand All opens every collapsible dropdown; selections remain visible on header badges after Collapse All
    await tester.tap(find.byKey(const ValueKey('toggle_all_dropdowns_button')));
    await tester.pumpAndSettle();

    expect(find.text('Collapse All'), findsOneWidget);
    expect(find.text('Phone (Optional)'), findsOneWidget);
    expect(find.text('Trim / Cab / Series'), findsOneWidget);
    expect(find.byKey(const ValueKey('drivetrain_dropdown_field')), findsOneWidget);
    expect(find.byKey(const ValueKey('bed_length_dropdown_field')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('multi_exterior_color_selector')),
      findsOneWidget,
    );
    expect(find.text('Leather Seats'), findsOneWidget);

    // Select a feature & drivetrain, then Collapse All -> clutter disappears while live summary badges remain!
    await tester.ensureVisible(find.text('Leather Seats'));
    await tester.tap(find.text('Leather Seats'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.byKey(const ValueKey('drivetrain_dropdown_field')),
    );
    await tester.tap(find.byKey(const ValueKey('drivetrain_dropdown_field')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('AWD').last);
    await tester.pumpAndSettle();

    await tester.ensureVisible(
      find.byKey(const ValueKey('toggle_all_dropdowns_button')),
    );
    await tester.tap(find.byKey(const ValueKey('toggle_all_dropdowns_button')));
    await tester.pumpAndSettle();

    expect(find.text('Expand All'), findsOneWidget);
    expect(find.text('Phone (Optional)'), findsNothing);
    expect(find.text('1 selected: Leather Seats'), findsOneWidget);
    expect(find.text('AWD'), findsOneWidget);

    LocalScoutEngine.resetForTest();
  });

  testWidgets(
      'Specific vehicles can be marked as Selected Candidates, filtered in GuestMatchesScreen, toggled in MatchDetailScreen, badged on GuestListScreen, and preserved across re-scans & cloud sync',
      (WidgetTester tester) async {
    LocalScoutEngine.resetForTest();
    const storeChannel = MethodChannel('com.prestonmotor.scout/launcher_widget');
    String persistedStore = jsonEncode({
      'guests': [],
      'matches': [],
      'settings': {'calendarPromptDismissed': true},
    });

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

    final mockInventory = <Map<String, dynamic>>[
      {
        'vin': '1FTFW3L87TKA90001',
        'stockNumber': 'S9001',
        'title': '2026 Ford F-150 XLT',
        'year': 2026,
        'make': 'Ford',
        'model': 'F-150',
        'trim': 'XLT',
        'condition': 'New',
        'price': 51500.0,
        'location': 'Preston Ford of Hurlock',
        'drivetrain': '4WD',
        'exteriorColor': 'Oxford White',
      },
      {
        'vin': '1FTFW5L89TKA90002',
        'stockNumber': 'S9002',
        'title': '2026 Ford F-150 Lariat',
        'year': 2026,
        'make': 'Ford',
        'model': 'F-150',
        'trim': 'Lariat',
        'condition': 'New',
        'price': 58900.0,
        'location': 'Boulevard Ford of Millsboro',
        'drivetrain': '4WD',
        'exteriorColor': 'Antimatter Blue',
      },
    ];

    final created = await LocalScoutEngine.createGuest(
      name: 'Jordan Vance',
      make: 'Ford',
      model: 'F-150',
      mockCandidatesOverride: mockInventory,
    );
    expect(created.matchesFound, 2);
    expect(created.guest.selectedCandidateCount, 0);

    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1200, 1700);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    // 1. Open GuestMatchesScreen and mark the Lariat (1FTFW5L89TKA90002) as a Selected Candidate
    await tester.pumpWidget(
      MaterialApp(
        home: GuestMatchesScreen(
          guestId: created.guest.id,
          onDataChanged: () {},
          onSelectMatch: (_, _) {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('All Matches (2)'), findsOneWidget);
    expect(find.text('Selected Candidates (0)'), findsOneWidget);
    expect(find.text('SELECTED CANDIDATE'), findsNothing);

    final lariatToggle = find.byKey(
      const ValueKey('toggle_selected_candidate_1FTFW5L89TKA90002'),
    );
    await tester.ensureVisible(lariatToggle);
    await tester.tap(lariatToggle);
    await tester.pumpAndSettle();

    expect(find.text('Selected Candidates (1)'), findsOneWidget);
    expect(find.text('SELECTED CANDIDATE'), findsOneWidget);
    expect(find.text('Selected Candidate'), findsOneWidget);

    // 2. Filter to Selected Candidates (1) -> shows ONLY the Lariat and hides the XLT
    await tester.ensureVisible(
      find.byKey(const ValueKey('filter_selected_candidates_chip')),
    );
    await tester.tap(
      find.byKey(const ValueKey('filter_selected_candidates_chip')),
    );
    await tester.pumpAndSettle();

    expect(find.text('2026 Ford F-150 Lariat'), findsOneWidget);
    expect(find.text('2026 Ford F-150 XLT'), findsNothing);

    // Switch back to All Matches (2)
    await tester.tap(find.byKey(const ValueKey('filter_all_matches_chip')));
    await tester.pumpAndSettle();
    expect(find.text('2026 Ford F-150 XLT'), findsOneWidget);
    expect(find.text('2026 Ford F-150 Lariat'), findsOneWidget);

    // 3. Re-running live search preserves Selected Candidate status on 1FTFW5L89TKA90002!
    final rescanned = await LocalScoutEngine.runSearchForSingleGuest(
      created.guest.id,
      mockCandidatesOverride: mockInventory,
    );
    expect(rescanned.guest.selectedCandidateCount, 1);
    final lariatAfterRescan = rescanned.matches.firstWhere(
      (m) => m.vin == '1FTFW5L89TKA90002',
    );
    final xltAfterRescan = rescanned.matches.firstWhere(
      (m) => m.vin == '1FTFW3L87TKA90001',
    );
    expect(lariatAfterRescan.isSelectedCandidate, isTrue);
    expect(xltAfterRescan.isSelectedCandidate, isFalse);

    // 4. MatchDetailScreen also allows marking/unmarking a vehicle as a Selected Candidate
    await tester.pumpWidget(
      MaterialApp(
        home: MatchDetailScreen(
          match: xltAfterRescan,
          guest: rescanned.guest,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Mark as Selected Candidate'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey('detail_toggle_selected_candidate')),
    );
    await tester.pumpAndSettle();

    expect(find.text('SELECTED CANDIDATE'), findsOneWidget);
    expect(find.text('Selected Candidate'), findsOneWidget);

    // 5. GuestListScreen displays "2 Selected" badge for Jordan Vance
    final allGuests = await LocalScoutEngine.getAllGuests();
    expect(allGuests.single.selectedCandidateCount, 2);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: GuestListScreen(
            guests: allGuests,
            isLoading: false,
            onRefresh: () {},
            onSelectGuest: (_) {},
            onSwitchToIntake: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(
        ValueKey('guest_selected_candidates_badge_${created.guest.id}'),
      ),
      findsOneWidget,
    );
    expect(find.text('2 Selected'), findsOneWidget);

    // Drain any auto-save debounce timer
    await tester.pump(const Duration(seconds: 1));

    LocalScoutEngine.cancelSchedulerForTest();
    LocalScoutEngine.resetForTest();
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(storeChannel, null);
  });

  testWidgets(
      'GuestMatchesScreen renders Marked Vehicles dropdown showing marked vehicles, opens match details on tap, and supports unmarking inside dropdown',
      (WidgetTester tester) async {
    LocalScoutEngine.resetForTest();
    const storeChannel = MethodChannel('com.prestonmotor.scout/launcher_widget');
    String persistedStore = jsonEncode({
      'guests': [],
      'matches': [],
      'settings': {'calendarPromptDismissed': true},
    });

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

    final mockInventory = <Map<String, dynamic>>[
      {
        'vin': '5LM5J7XC6RGL11111',
        'stockNumber': 'L1111',
        'title': '2024 Lincoln Nautilus Reserve',
        'year': 2024,
        'make': 'Lincoln',
        'model': 'Nautilus',
        'trim': 'Reserve',
        'condition': 'Pre-Owned',
        'price': 47990.0,
        'location': 'Preston Lincoln',
        'drivetrain': 'AWD',
        'exteriorColor': 'White Platinum',
      },
      {
        'vin': '5LM5J9XC8RGL22222',
        'stockNumber': 'L2222',
        'title': '2024 Lincoln Nautilus Black Label',
        'year': 2024,
        'make': 'Lincoln',
        'model': 'Nautilus',
        'trim': 'Black Label',
        'condition': 'Pre-Owned',
        'price': 56490.0,
        'location': 'Boulevard Lincoln of Lewes',
        'drivetrain': 'AWD',
        'exteriorColor': 'Infinite Black',
      },
    ];

    final created = await LocalScoutEngine.createGuest(
      name: 'Taylor Brooks',
      make: 'Lincoln',
      model: 'Nautilus',
      mockCandidatesOverride: mockInventory,
    );

    VehicleMatch? tappedFromDropdown;
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1200, 1700);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      MaterialApp(
        home: GuestMatchesScreen(
          guestId: created.guest.id,
          onDataChanged: () {},
          onSelectMatch: (match, _) {
            tappedFromDropdown = match;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 1. Marked Vehicles dropdown starts collapsed showing "0 Marked"
    final dropdownToggle =
        find.byKey(const ValueKey('marked_vehicles_dropdown_toggle'));
    expect(dropdownToggle, findsOneWidget);
    expect(find.text('Marked Vehicles'), findsOneWidget);
    expect(find.text('0 Marked'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('marked_vehicles_dropdown_list')),
      findsNothing,
    );

    // 2. Mark the Black Label (5LM5J9XC8RGL22222) -> dropdown header immediately updates to "1 Marked"
    await tester.tap(
      find.byKey(const ValueKey('toggle_selected_candidate_5LM5J9XC8RGL22222')),
    );
    await tester.pumpAndSettle();
    expect(find.text('1 Marked'), findsOneWidget);

    // 3. Open the Marked Vehicles dropdown -> displays ONLY the marked Black Label inside marked_vehicles_dropdown_list
    await tester.tap(dropdownToggle);
    await tester.pumpAndSettle();

    final dropdownList =
        find.byKey(const ValueKey('marked_vehicles_dropdown_list'));
    expect(dropdownList, findsOneWidget);
    expect(find.text('Hide Marked'), findsOneWidget);
    expect(
      find.descendant(
        of: dropdownList,
        matching: find.text('2024 Lincoln Nautilus Black Label'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: dropdownList,
        matching: find.text('2024 Lincoln Nautilus Reserve'),
      ),
      findsNothing,
    );

    // 4. Tapping the marked vehicle row inside the dropdown invokes onSelectMatch
    await tester.tap(
      find.byKey(const ValueKey('marked_dropdown_item_5LM5J9XC8RGL22222')),
    );
    await tester.pumpAndSettle();
    expect(tappedFromDropdown?.vin, '5LM5J9XC8RGL22222');

    // 5. Tapping the star button inside the Marked Vehicles dropdown unmarks it -> updates to "0 Marked"
    await tester.tap(
      find.byKey(const ValueKey('unmark_dropdown_button_5LM5J9XC8RGL22222')),
    );
    await tester.pumpAndSettle();
    expect(find.text('0 Marked'), findsOneWidget);
    expect(
      find.textContaining('No marked vehicles yet for Taylor Brooks'),
      findsOneWidget,
    );

    // Drain auto-save debounce timer
    await tester.pump(const Duration(seconds: 1));

    LocalScoutEngine.cancelSchedulerForTest();
    LocalScoutEngine.resetForTest();
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(storeChannel, null);
  });
}





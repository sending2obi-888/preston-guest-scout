import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import '../models/models.dart';
import 'api_service.dart';
import 'google_drive_sync_service.dart';
import 'local_engine.dart';

/// Manages Calendar Permissions and automatically creates same-day `"Call <Guest>"`
/// calendar events whenever a matching vehicle is found for a client.
class CalendarService extends ChangeNotifier {
  CalendarService._();
  static final CalendarService instance = CalendarService._();

  static const MethodChannel _channel =
      MethodChannel('com.prestonmotor.scout/calendar');

  bool _initialized = false;
  bool _hasLoadedInitialServerList = false;
  bool _permissionGranted = false;
  bool _promptDismissed = false;
  bool _gcalendarConnected = false;
  List<CalendarCallEvent> _events = <CalendarCallEvent>[];
  final Set<String> _seenEventIds = <String>{};

  /// Optional foreground callback invoked when a new same-day call event is created.
  void Function(CalendarCallEvent event)? onCalendarEventCreated;

  bool get isInitialized => _initialized;
  bool get permissionGranted => _permissionGranted;
  bool get promptDismissed => _promptDismissed;
  bool get gcalendarConnected => _gcalendarConnected;
  List<CalendarCallEvent> get events => List.unmodifiable(_events);

  /// True when the app should present the Calendar Permission request dialog.
  bool get shouldShowPermissionDialog =>
      _initialized && !_permissionGranted && !_promptDismissed;

  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;

    if (kIsWeb) {
      await ApiService.fetchCalendarStatus();
      notifyListeners();
      return;
    }

    _channel.setMethodCallHandler(_handleNativeMethodCall);

    try {
      final hasPerm =
          await _channel.invokeMethod<bool>('hasCalendarPermission') ?? false;
      if (hasPerm) {
        _permissionGranted = true;
        _promptDismissed = true;
      } else {
        // Proactively ask for OS Calendar permission on startup
        final granted =
            await _channel.invokeMethod<bool>('requestCalendarPermission') ??
                false;
        _permissionGranted = granted;
        if (granted) {
          _promptDismissed = true;
        }
      }
      await LocalScoutEngine.saveCalendarPermissionState(
        permissionGranted: _permissionGranted,
        promptDismissed: _promptDismissed,
      );
    } catch (_) {}

    notifyListeners();
  }

  Future<dynamic> _handleNativeMethodCall(MethodCall call) async {
    if (call.method == 'onCalendarPermissionChanged') {
      final granted = call.arguments == true;
      if (_permissionGranted != granted) {
        _permissionGranted = granted;
        if (granted) {
          _promptDismissed = true;
        }
        unawaited(
          LocalScoutEngine.saveCalendarPermissionState(
            permissionGranted: _permissionGranted,
            promptDismissed: _promptDismissed,
          ),
        );
        notifyListeners();
      }
    }
    return null;
  }

  /// Explicitly requests Calendar Permission when the user taps "Allow Calendar Access".
  Future<bool> requestCalendarPermission() async {
    if (kIsWeb) {
      final ok = await ApiService.setCalendarPermission(
        true,
        accessToken: GoogleDriveSyncService.instance.accessToken,
      );
      return ok;
    }

    try {
      final granted =
          await _channel.invokeMethod<bool>('requestCalendarPermission') ??
              false;
      _permissionGranted = granted;
      if (granted) {
        _promptDismissed = true;
      }
      await LocalScoutEngine.saveCalendarPermissionState(
        permissionGranted: _permissionGranted,
        promptDismissed: _promptDismissed,
      );
      notifyListeners();
      return granted;
    } catch (_) {
      return false;
    }
  }

  /// Marks the startup Calendar Permission prompt as dismissed ("Not Now") while still
  /// allowing the user to enable Calendar Permission anytime from the Calendar button.
  Future<void> dismissPermissionPrompt() async {
    _promptDismissed = true;
    notifyListeners();
    if (kIsWeb) {
      await ApiService.setCalendarPermission(
        _permissionGranted,
        dismissed: true,
      );
    } else {
      await LocalScoutEngine.saveCalendarPermissionState(
        permissionGranted: _permissionGranted,
        promptDismissed: true,
      );
    }
  }

  void hydratePersistedState({
    required List<CalendarCallEvent> events,
    bool permissionGranted = false,
    bool promptDismissed = false,
  }) {
    _events = [...events]..sort((a, b) => b.startAt.compareTo(a.startAt));
    for (final ev in _events) {
      if (ev.id.isNotEmpty) _seenEventIds.add(ev.id);
    }
    if (permissionGranted) {
      _permissionGranted = true;
    }
    _promptDismissed = promptDismissed;
    notifyListeners();
  }

  void syncFromServerStatus(Map<String, dynamic> data) {
    final wasLoaded = _hasLoadedInitialServerList;
    _hasLoadedInitialServerList = true;

    _permissionGranted = data['permissionGranted'] == true;
    _promptDismissed = data['promptDismissed'] == true;
    _gcalendarConnected = data['gcalendarConnected'] == true;

    final rawEvents = data['events'];
    if (rawEvents is List) {
      final parsed = rawEvents
          .whereType<Map>()
          .map((m) => CalendarCallEvent.fromJson(Map<String, dynamic>.from(m)))
          .toList()
        ..sort((a, b) => b.startAt.compareTo(a.startAt));

      CalendarCallEvent? newlyCreated;
      for (final ev in parsed) {
        if (ev.id.isNotEmpty && _seenEventIds.add(ev.id) && wasLoaded) {
          newlyCreated ??= ev;
        }
      }
      _events = parsed;
      if (newlyCreated != null) {
        onCalendarEventCreated?.call(newlyCreated);
      }
    }
    notifyListeners();
  }

  /// Automatically creates (or updates if already scheduled earlier today) a same-day
  /// calendar event to call [guest] on the exact day a match is found.
  Future<CalendarCallEvent?> scheduleSameDayCallForGuest({
    required GuestProfile guest,
    required List<Map<String, dynamic>> matchedVehicles,
    String timeZone = 'America/New_York',
  }) async {
    if (!_permissionGranted || matchedVehicles.isEmpty) {
      return null;
    }

    final now = DateTime.now();
    final slot = CalendarCallEvent.computeSameDaySlot(now);
    final title = CalendarCallEvent.buildCallTitle(
      clientName: guest.name,
      matchedVehicles: matchedVehicles,
    );
    final description = CalendarCallEvent.buildCallDescription(
      guest: guest,
      matchedVehicles: matchedVehicles,
    );
    final primaryVehicle = matchedVehicles.first;
    final location =
        (primaryVehicle['location']?.toString() ?? '').trim().isNotEmpty
            ? primaryVehicle['location'].toString().trim()
            : 'Preston Automotive Group';
    final primaryModel = MatchAlertNotification.extractVehicleModelLabel(
      make: primaryVehicle['make']?.toString() ?? '',
      model: primaryVehicle['model']?.toString() ?? '',
      title: primaryVehicle['title']?.toString() ?? '',
    );
    final vehicleSummary = matchedVehicles.length > 1
        ? '$primaryModel (+${matchedVehicles.length - 1} more)'
        : primaryModel;

    // Deduplicate per (guestId, eventDate) so multiple matches on the same day
    // update the same-day call sheet instead of spamming duplicate events.
    final existingIdx = _events.indexWhere(
      (e) => e.guestId == guest.id && e.eventDate == slot.eventDate,
    );
    if (existingIdx != -1) {
      final updated = _events[existingIdx].copyWith(
        title: title,
        description: description,
        location: location,
        vehicleSummary: vehicleSummary,
      );
      _events[existingIdx] = updated;
      notifyListeners();
      return updated;
    }

    String externalEventId = '';
    String calendarLink = '';
    String provider = 'in_app_calendar';
    DateTime finalStartLocal = slot.startLocal;
    DateTime finalEndLocal = slot.endLocal;

    if (!kIsWeb) {
      var createdOnDevice = false;
      try {
        final rawRes = await _channel.invokeMethod<dynamic>(
          'createSameDayCallEvent',
          <String, dynamic>{
            'title': title,
            'description': description,
            'location': location,
            'startEpochMs': slot.startLocal.millisecondsSinceEpoch,
            'endEpochMs': slot.endLocal.millisecondsSinceEpoch,
            'timeZone': timeZone,
          },
        );
        if (rawRes is Map && rawRes['created'] == true) {
          createdOnDevice = true;
          externalEventId = rawRes['eventId']?.toString() ?? '';
          provider =
              rawRes['provider']?.toString() ?? 'android_calendar_provider';
          final adjStart = (rawRes['startEpochMs'] as num?)?.toInt();
          final adjEnd = (rawRes['endEpochMs'] as num?)?.toInt();
          if (adjStart != null) {
            finalStartLocal =
                DateTime.fromMillisecondsSinceEpoch(adjStart).toLocal();
          }
          if (adjEnd != null) {
            finalEndLocal =
                DateTime.fromMillisecondsSinceEpoch(adjEnd).toLocal();
          }
        }
      } catch (_) {}

      // Fallback to Google Calendar REST API if signed in via Google SSO and no local device calendar account was writable
      final oauthToken = GoogleDriveSyncService.instance.accessToken.trim();
      if (!createdOnDevice && oauthToken.isNotEmpty) {
        try {
          final res = await http.post(
            Uri.parse(
              'https://www.googleapis.com/calendar/v3/calendars/primary/events?sendUpdates=none',
            ),
            headers: <String, String>{
              'Authorization': 'Bearer $oauthToken',
              'Content-Type': 'application/json',
            },
            body: jsonEncode(<String, dynamic>{
              'summary': title,
              'description': description,
              'location': location,
              'start': <String, dynamic>{
                'dateTime': finalStartLocal.toUtc().toIso8601String(),
                'timeZone': timeZone,
              },
              'end': <String, dynamic>{
                'dateTime': finalEndLocal.toUtc().toIso8601String(),
                'timeZone': timeZone,
              },
              'reminders': <String, dynamic>{
                'useDefault': false,
                'overrides': <Map<String, dynamic>>[
                  <String, dynamic>{'method': 'popup', 'minutes': 15},
                ],
              },
            }),
          );
          if (res.statusCode == 200 || res.statusCode == 201) {
            final data = jsonDecode(res.body) as Map<String, dynamic>;
            externalEventId = data['id']?.toString() ?? '';
            calendarLink = data['htmlLink']?.toString() ?? '';
            provider = 'google_calendar_oauth';
          }
        } catch (_) {}
      }
    }

    final event = CalendarCallEvent(
      id: 'cal-${now.microsecondsSinceEpoch}-${guest.id}',
      guestId: guest.id,
      guestName: guest.name,
      guestPhone: guest.phone,
      eventDate: slot.eventDate,
      startAt: finalStartLocal.toIso8601String(),
      endAt: finalEndLocal.toIso8601String(),
      title: title,
      description: description,
      location: location,
      vehicleSummary: vehicleSummary,
      externalEventId: externalEventId,
      calendarLink: calendarLink,
      provider: provider,
      createdAt: now.toUtc().toIso8601String(),
    );

    _seenEventIds.add(event.id);
    _events = <CalendarCallEvent>[event, ..._events];
    onCalendarEventCreated?.call(event);
    notifyListeners();
    return event;
  }

  void clearEventsLocally() {
    _events = <CalendarCallEvent>[];
    _seenEventIds.clear();
    notifyListeners();
  }

  void resetForTest() {
    _initialized = false;
    _hasLoadedInitialServerList = false;
    _permissionGranted = false;
    _promptDismissed = false;
    _gcalendarConnected = false;
    _events = <CalendarCallEvent>[];
    _seenEventIds.clear();
    onCalendarEventCreated = null;
  }
}

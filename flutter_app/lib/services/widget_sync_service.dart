import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../models/models.dart';

/// Bridges Flutter with the native Android / Chromebook Launcher AppWidget.
/// Strictly persists ONLY the last 10 guests input and listens for widget tap deep-links.
class WidgetSyncService {
  static const MethodChannel _channel =
      MethodChannel('com.prestonmotor.scout/launcher_widget');

  static void Function(String guestId)? _onGuestSelectedFromWidget;

  static void dispatchGuestSelection(String guestId) {
    if (guestId.isNotEmpty) {
      _onGuestSelectedFromWidget?.call(guestId);
    }
  }

  static void initialize({required void Function(String guestId) onSelectGuest}) {
    _onGuestSelectedFromWidget = onSelectGuest;
    if (kIsWeb) return;

    _channel.setMethodCallHandler((call) async {
      if (call.method == 'openGuestMatches') {
        dispatchGuestSelection(call.arguments?.toString() ?? '');
      }
    });

    // Check if the app was cold-launched from tapping a guest in the Launcher Widget
    _channel.invokeMethod<String>('getInitialLaunchGuestId').then((guestId) {
      if (guestId != null && guestId.isNotEmpty) {
        dispatchGuestSelection(guestId);
      }
    }).catchError((_) {});
  }

  static Future<void> syncRecentTenGuests(List<WidgetGuestEntry> guests) async {
    final cappedTen = guests.take(10).map((e) => e.toJson()).toList();
    if (kIsWeb) return;
    try {
      await _channel.invokeMethod('updateWidgetGuests', {
        'guestsJson': jsonEncode(cappedTen),
      });
    } catch (_) {
      // Safe no-op on unsupported desktop runners
    }
  }
}

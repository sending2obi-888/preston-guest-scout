import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'models/models.dart';
import 'screens/guest_list_screen.dart';
import 'screens/guest_matches_screen.dart';
import 'screens/home_intake_screen.dart';
import 'screens/match_detail_screen.dart';
import 'services/api_service.dart';
import 'services/google_drive_sync_service.dart';
import 'services/match_notification_service.dart';
import 'services/widget_sync_service.dart';
import 'theme/app_theme.dart';
import 'widgets/google_account_sync_dialog.dart';
import 'widgets/launcher_widget_sheet.dart';
import 'widgets/match_notifications_dialog.dart';
import 'widgets/settings_and_chromebook_dialog.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const PrestonGuestScoutApp());
}

class PrestonGuestScoutApp extends StatefulWidget {
  const PrestonGuestScoutApp({super.key});

  @override
  State<PrestonGuestScoutApp> createState() => _PrestonGuestScoutAppState();
}

class _PrestonGuestScoutAppState extends State<PrestonGuestScoutApp> {
  final GlobalKey<NavigatorState> _navKey = GlobalKey<NavigatorState>();
  ThemeMode _themeMode = ThemeMode.light;

  void _toggleTheme() {
    setState(() {
      _themeMode =
          _themeMode == ThemeMode.light ? ThemeMode.dark : ThemeMode.light;
    });
  }

  Future<void> _navigateToGuestMatches(String guestId) async {
    if (guestId.isEmpty) return;
    // Query Google Drive first when opening from the Launcher Widget or OS Notification so matches are fresh
    unawaited(GoogleDriveSyncService.instance.queryDriveOnAppOpen());
    final nav = _navKey.currentState;
    if (nav == null) return;
    nav.push(
      MaterialPageRoute(
        builder: (_) => GuestMatchesScreen(
          guestId: guestId,
          onDataChanged: () {},
          onSelectMatch: (match, guest) {
            nav.push(
              MaterialPageRoute(
                builder: (_) => MatchDetailScreen(match: match, guest: guest),
              ),
            );
          },
        ),
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    WidgetSyncService.initialize(onSelectGuest: _navigateToGuestMatches);
    unawaited(
      MatchNotificationService.instance.initialize(
        onTapNotification: _navigateToGuestMatches,
      ),
    );

    // Handle initial Web URL deep-link from ChromeOS Extension Widget or Notification (e.g. ?guestId=... or #/guest/...)
    if (kIsWeb) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final uri = Uri.base;
        String? deepGuestId = uri.queryParameters['guestId'];
        if ((deepGuestId == null || deepGuestId.isEmpty) &&
            uri.fragment.startsWith('/guest/')) {
          deepGuestId = Uri.decodeComponent(
              uri.fragment.substring('/guest/'.length).split('/').first);
        }
        if (deepGuestId != null && deepGuestId.isNotEmpty) {
          _navigateToGuestMatches(deepGuestId);
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: _navKey,
      title: 'Preston Guest Scout • Gemini Inventory Agent',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: _themeMode,
      home: MainShellScreen(
        themeMode: _themeMode,
        onToggleTheme: _toggleTheme,
      ),
    );
  }
}

class MainShellScreen extends StatefulWidget {
  final ThemeMode themeMode;
  final VoidCallback onToggleTheme;

  const MainShellScreen({
    super.key,
    required this.themeMode,
    required this.onToggleTheme,
  });

  @override
  State<MainShellScreen> createState() => _MainShellScreenState();
}

class _MainShellScreenState extends State<MainShellScreen>
    with WidgetsBindingObserver {
  int _selectedPageIndex =
      0; // 0 = Page 1 (Home Intake), 1 = Page 2 (Guests List)
  SystemStatus _status = const SystemStatus();
  List<GuestProfile> _guests = [];
  bool _loadingGuests = true;
  Timer? _pollTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    GoogleDriveSyncService.instance.addCloudMergeListener(_handleCloudMerged);
    MatchNotificationService.instance.onForegroundBanner =
        _showNewMatchSnackBar;

    // Load local/cached data immediately and query Google Drive on app open
    _initializeAndQueryDriveOnOpen();

    // Keep status and twice-daily match counts & notifications fresh automatically
    _pollTimer = Timer.periodic(const Duration(seconds: 25), (_) {
      _refreshAll(silent: true);
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    GoogleDriveSyncService.instance
        .removeCloudMergeListener(_handleCloudMerged);
    if (MatchNotificationService.instance.onForegroundBanner ==
        _showNewMatchSnackBar) {
      MatchNotificationService.instance.onForegroundBanner = null;
    }
    _pollTimer?.cancel();
    super.dispose();
  }

  void _showNewMatchSnackBar(MatchAlertNotification alert) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    messenger.showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 7),
        content: Row(
          children: [
            const Icon(
              Icons.notifications_active_rounded,
              color: Colors.white,
              size: 20,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                alert.message,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
        action: SnackBarAction(
          label: 'View',
          onPressed: () {
            ApiService.markAllNotificationsRead();
            _openGuestMatches(alert.guestId);
          },
        ),
      ),
    );
  }

  /// Automatically queries Google Drive every time the app is opened or foregrounded
  /// on any device so search requirements and matches are always up to date.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _queryDriveAndRefresh();
    }
  }

  void _handleCloudMerged() {
    if (!mounted) return;
    _refreshAll(silent: true);
  }

  Future<void> _initializeAndQueryDriveOnOpen() async {
    await _refreshAll();
    await _queryDriveAndRefresh();
  }

  Future<void> _queryDriveAndRefresh() async {
    final synced = await GoogleDriveSyncService.instance.queryDriveOnAppOpen();
    if (synced && mounted) {
      await _refreshAll(silent: true);
    }
  }

  Future<void> _refreshAll({bool silent = false}) async {
    if (!silent) {
      setState(() => _loadingGuests = true);
    }
    try {
      final results = await Future.wait([
        ApiService.fetchStatus(),
        ApiService.fetchAllGuests(),
        ApiService.fetchNotifications(),
      ]);
      if (!mounted) return;
      setState(() {
        _status = results[0] as SystemStatus;
        _guests = results[1] as List<GuestProfile>;
        _loadingGuests = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadingGuests = false);
    }
  }

  void _openGuestMatches(String guestId) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => GuestMatchesScreen(
          guestId: guestId,
          onDataChanged: _refreshAll,
          onSelectMatch: (match, guest) {
            Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => MatchDetailScreen(match: match, guest: guest),
              ),
            );
          },
        ),
      ),
    );
  }

  void _openGoogleAccountSyncDialog() {
    showDialog(
      context: context,
      builder: (_) => GoogleAccountSyncDialog(
        onSynced: () => _refreshAll(silent: true),
      ),
    );
  }

  void _openLauncherWidgetPreview() {
    showDialog(
      context: context,
      builder: (_) => LauncherWidgetDialog(
        onSelectGuest: _openGuestMatches,
      ),
    );
  }

  void _openMatchNotificationsDialog() {
    showDialog(
      context: context,
      builder: (_) => MatchNotificationsDialog(
        onSelectGuest: _openGuestMatches,
      ),
    );
  }

  void _openSettingsDialog() {
    showDialog(
      context: context,
      builder: (_) => SettingsAndChromebookDialog(
        onSaved: _refreshAll,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final screenWidth = MediaQuery.of(context).size.width;
    final wideChromebook = screenWidth >= 820;
    final compactMobile = screenWidth < 520;

    final pages = [
      HomeIntakeScreen(
        status: _status,
        onGuestCreated: _refreshAll,
        onOpenGuestMatches: _openGuestMatches,
        onOpenSettings: _openSettingsDialog,
      ),
      GuestListScreen(
        guests: _guests,
        isLoading: _loadingGuests,
        onRefresh: _queryDriveAndRefresh,
        onSelectGuest: _openGuestMatches,
        onSwitchToIntake: () => setState(() => _selectedPageIndex = 0),
      ),
    ];

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(7),
              decoration: BoxDecoration(
                color: scheme.primaryContainer,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(
                Icons.directions_car_filled_rounded,
                color: scheme.onPrimaryContainer,
                size: 20,
              ),
            ),
            const SizedBox(width: 10),
            const Flexible(
              child: Text(
                'Preston Motor Guest Scout',
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        actions: [
          // Google Single Sign-On & Multi-Device Google Drive Sync Button
          ListenableBuilder(
            listenable: GoogleDriveSyncService.instance,
            builder: (context, _) {
              final sync = GoogleDriveSyncService.instance;
              final signedIn = sync.isSignedIn;
              final syncing = sync.isSyncing || sync.isSigningIn;

              if (!signedIn) {
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: compactMobile
                      ? IconButton.filledTonal(
                          tooltip: 'Sign in with Google & Sync Drive',
                          onPressed: _openGoogleAccountSyncDialog,
                          icon: const Icon(Icons.login_rounded, size: 18),
                        )
                      : OutlinedButton.icon(
                          onPressed: _openGoogleAccountSyncDialog,
                          icon: const Icon(Icons.account_circle_outlined,
                              size: 18),
                          label: const Text('Sign in with Google'),
                        ),
                );
              }

              final shortName = sync.userDisplayName.trim().isNotEmpty
                  ? sync.userDisplayName.trim().split(' ').first
                  : 'Drive Synced';

              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: FilledButton.tonalIcon(
                  onPressed: _openGoogleAccountSyncDialog,
                  icon: syncing
                      ? const SizedBox(
                          width: 15,
                          height: 15,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.cloud_done_outlined, size: 18),
                  label: Text(
                    wideChromebook
                        ? '$shortName • Drive Synced'
                        : (compactMobile ? 'Synced' : shortName),
                  ),
                ),
              );
            },
          ),
          const SizedBox(width: 6),
          // Launcher Widget Preview Button (Strictly Last 10 Guests Input)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: compactMobile
                ? IconButton.filledTonal(
                    tooltip: 'Launcher Widget (Last 10 Guests)',
                    onPressed: _openLauncherWidgetPreview,
                    icon: const Icon(Icons.widgets_outlined, size: 18),
                  )
                : FilledButton.tonalIcon(
                    onPressed: _openLauncherWidgetPreview,
                    icon: const Icon(Icons.widgets_outlined, size: 18),
                    label: Text(
                        wideChromebook ? 'Launcher Widget (Last 10)' : 'Widget'),
                  ),
          ),
          const SizedBox(width: 4),
          // New Match Notifications Bell (Post-Initial-Search Alerts)
          ListenableBuilder(
            listenable: MatchNotificationService.instance,
            builder: (context, _) {
              final unread = MatchNotificationService.instance.unreadCount;
              return IconButton(
                tooltip: unread > 0
                    ? 'New Match Notifications ($unread unread)'
                    : 'New Match Notifications',
                onPressed: _openMatchNotificationsDialog,
                icon: Badge(
                  isLabelVisible: unread > 0,
                  label: Text('$unread'),
                  child: Icon(
                    unread > 0
                        ? Icons.notifications_active_rounded
                        : Icons.notifications_outlined,
                  ),
                ),
              );
            },
          ),
          IconButton(
            tooltip: 'Gemini Agent & Googlebook Startup Settings',
            onPressed: _openSettingsDialog,
            icon: const Icon(Icons.settings_outlined),
          ),
          IconButton(
            tooltip: widget.themeMode == ThemeMode.light
                ? 'Switch to Dark Mode'
                : 'Switch to Light Mode',
            onPressed: widget.onToggleTheme,
            icon: Icon(
              widget.themeMode == ThemeMode.light
                  ? Icons.dark_mode_outlined
                  : Icons.light_mode_outlined,
            ),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: wideChromebook
          ? Row(
              children: [
                NavigationRail(
                  extended: MediaQuery.of(context).size.width >= 1120,
                  selectedIndex: _selectedPageIndex,
                  onDestinationSelected: (idx) {
                    setState(() => _selectedPageIndex = idx);
                    if (idx == 1) _queryDriveAndRefresh();
                  },
                  destinations: [
                    const NavigationRailDestination(
                      icon: Icon(Icons.person_add_outlined),
                      selectedIcon: Icon(Icons.person_add),
                      label: Text('Guest & Vehicle Input'),
                    ),
                    NavigationRailDestination(
                      icon: Badge(
                        isLabelVisible: _guests.isNotEmpty,
                        label: Text('${_guests.length}'),
                        child: const Icon(Icons.fact_check_outlined),
                      ),
                      selectedIcon: Badge(
                        isLabelVisible: _guests.isNotEmpty,
                        label: Text('${_guests.length}'),
                        child: const Icon(Icons.fact_check),
                      ),
                      label: const Text('Monitored Guests'),
                    ),
                  ],
                ),
                VerticalDivider(
                    width: 1, thickness: 1, color: scheme.outlineVariant),
                Expanded(child: pages[_selectedPageIndex]),
              ],
            )
          : pages[_selectedPageIndex],
      bottomNavigationBar: wideChromebook
          ? null
          : NavigationBar(
              selectedIndex: _selectedPageIndex,
              onDestinationSelected: (idx) {
                setState(() => _selectedPageIndex = idx);
                if (idx == 1) _queryDriveAndRefresh();
              },
              destinations: [
                const NavigationDestination(
                  icon: Icon(Icons.person_add_outlined),
                  selectedIcon: Icon(Icons.person_add),
                  label: 'Guest & Specs Input',
                ),
                NavigationDestination(
                  icon: Badge(
                    isLabelVisible: _guests.isNotEmpty,
                    label: Text('${_guests.length}'),
                    child: const Icon(Icons.fact_check_outlined),
                  ),
                  selectedIcon: Badge(
                    isLabelVisible: _guests.isNotEmpty,
                    label: Text('${_guests.length}'),
                    child: const Icon(Icons.fact_check),
                  ),
                  label: 'Monitored Guests',
                ),
              ],
            ),
    );
  }
}

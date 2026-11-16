import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'models/models.dart';
import 'screens/guest_list_screen.dart';
import 'screens/guest_matches_screen.dart';
import 'screens/home_intake_screen.dart';
import 'screens/match_detail_screen.dart';
import 'services/api_service.dart';
import 'services/widget_sync_service.dart';
import 'theme/app_theme.dart';
import 'widgets/launcher_widget_sheet.dart';
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

  void _navigateToGuestMatches(String guestId) {
    final nav = _navKey.currentState;
    if (nav == null || guestId.isEmpty) return;
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

    // Handle initial Web URL deep-link from ChromeOS Extension Widget (e.g. ?guestId=... or #/guest/...)
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

class _MainShellScreenState extends State<MainShellScreen> {
  int _selectedPageIndex = 0; // 0 = Page 1 (Home Intake), 1 = Page 2 (Guests List)
  SystemStatus _status = const SystemStatus();
  List<GuestProfile> _guests = [];
  bool _loadingGuests = true;
  Timer? _pollTimer;

  @override
  void initState() {
    super.initState();
    _refreshAll();
    // Keep status and twice-daily match counts fresh automatically
    _pollTimer = Timer.periodic(const Duration(seconds: 25), (_) {
      _refreshAll(silent: true);
    });
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  Future<void> _refreshAll({bool silent = false}) async {
    if (!silent) {
      setState(() => _loadingGuests = true);
    }
    try {
      final results = await Future.wait([
        ApiService.fetchStatus(),
        ApiService.fetchAllGuests(),
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

  void _openLauncherWidgetPreview() {
    showDialog(
      context: context,
      builder: (_) => LauncherWidgetDialog(
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
    final wideChromebook = MediaQuery.of(context).size.width >= 820;

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
        onRefresh: _refreshAll,
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
          // Launcher Widget Preview Button (Strictly Last 10 Guests Input)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: FilledButton.tonalIcon(
              onPressed: _openLauncherWidgetPreview,
              icon: const Icon(Icons.widgets_outlined, size: 18),
              label: Text(wideChromebook ? 'Launcher Widget (Last 10)' : 'Widget'),
            ),
          ),
          const SizedBox(width: 6),
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
                    if (idx == 1) _refreshAll(silent: true);
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
                if (idx == 1) _refreshAll(silent: true);
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

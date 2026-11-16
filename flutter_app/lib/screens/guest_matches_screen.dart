import 'package:material_ui/material_ui.dart';
import 'package:intl/intl.dart';
import '../models/models.dart';
import '../services/api_service.dart';

class GuestMatchesScreen extends StatefulWidget {
  final String guestId;
  final VoidCallback onDataChanged;
  final void Function(VehicleMatch match, GuestProfile guest) onSelectMatch;

  const GuestMatchesScreen({
    super.key,
    required this.guestId,
    required this.onDataChanged,
    required this.onSelectMatch,
  });

  @override
  State<GuestMatchesScreen> createState() => _GuestMatchesScreenState();
}

class _GuestMatchesScreenState extends State<GuestMatchesScreen> {
  static const String _allLocationsFilter = '__ALL__';
  static const String _allMillsboroFilter = '__MILLSBORO__';

  GuestProfile? _guest;
  List<VehicleMatch> _matches = [];
  bool _loading = true;
  bool _searchingNow = false;
  String? _error;

  String _selectedLocation = _allLocationsFilter;
  String _sortBy = 'score';
  String _searchQuery = '';
  final TextEditingController _searchCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadData() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await ApiService.fetchGuestWithMatches(widget.guestId);
      if (!mounted) return;
      setState(() {
        _guest = res.guest;
        _matches = res.matches;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _runLiveGeminiSearch() async {
    setState(() => _searchingNow = true);
    try {
      final res = await ApiService.triggerGuestSearch(widget.guestId);
      widget.onDataChanged();
      if (!mounted) return;
      setState(() {
        _guest = res.guest;
        _matches = res.matches;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(res.summary)),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Search error: $e')),
      );
    } finally {
      if (mounted) setState(() => _searchingNow = false);
    }
  }

  String _formatFoundDate(String iso) {
    final dt = DateTime.tryParse(iso)?.toLocal();
    if (dt == null) return iso;
    return DateFormat('MMM d, yyyy • h:mm a').format(dt);
  }

  List<MapEntry<String, int>> _computeLocationCounts() {
    final counts = <String, int>{};
    for (final m in _matches) {
      final loc = m.location.trim().isEmpty
          ? 'Preston Automotive Group'
          : m.location.trim();
      counts[loc] = (counts[loc] ?? 0) + 1;
    }
    final entries = counts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return entries;
  }

  int _computeMillsboroCount() {
    int c = 0;
    for (final m in _matches) {
      final lower = m.location.toLowerCase();
      if (lower.contains('millsboro') || lower.contains('boulevard')) {
        c++;
      }
    }
    return c;
  }

  List<VehicleMatch> _computeFilteredMatches() {
    final q = _searchQuery.trim().toLowerCase();
    final filtered = _matches.where((m) {
      if (_selectedLocation == _allMillsboroFilter) {
        final lowerLoc = m.location.toLowerCase();
        if (!lowerLoc.contains('millsboro') &&
            !lowerLoc.contains('boulevard')) {
          return false;
        }
      } else if (_selectedLocation != _allLocationsFilter) {
        if (m.location.trim() != _selectedLocation) return false;
      }

      if (q.isNotEmpty) {
        final hay =
            '${m.title} ${m.make} ${m.model} ${m.trim} ${m.location} ${m.exteriorColor} ${m.vin} ${m.stockNumber} ${m.drivetrain}'
                .toLowerCase();
        final tokens = q.split(RegExp(r'\s+')).where((t) => t.isNotEmpty);
        if (!tokens.every((t) => hay.contains(t))) return false;
      }
      return true;
    }).toList();

    switch (_sortBy) {
      case 'price_asc':
        filtered.sort((a, b) =>
            (a.price ?? double.maxFinite).compareTo(b.price ?? double.maxFinite));
        break;
      case 'price_desc':
        filtered.sort((a, b) => (b.price ?? 0).compareTo(a.price ?? 0));
        break;
      case 'year_desc':
        filtered.sort((a, b) => (b.year ?? 0).compareTo(a.year ?? 0));
        break;
      default:
        filtered.sort((a, b) {
          final cmp = b.matchScore.compareTo(a.matchScore);
          if (cmp != 0) return cmp;
          return (a.price ?? double.maxFinite)
              .compareTo(b.price ?? double.maxFinite);
        });
    }
    return filtered;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final currencyFmt = NumberFormat.currency(symbol: '\$', decimalDigits: 0);
    final numberFmt = NumberFormat.decimalPattern();

    final locationCounts = _computeLocationCounts();
    final millsboroCount = _computeMillsboroCount();
    final visibleMatches = _computeFilteredMatches();

    return Scaffold(
      appBar: AppBar(
        title: Text(_guest != null
            ? '${_guest!.name} • Vehicle Matches'
            : 'Guest Vehicle Matches'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: FilledButton.tonalIcon(
              onPressed: _searchingNow ? null : _runLiveGeminiSearch,
              icon: _searchingNow
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.auto_awesome, size: 18),
              label: Text(_searchingNow
                  ? 'Searching All Pages...'
                  : 'Search prestonmotor.com Now'),
            ),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.error_outline,
                            size: 48, color: scheme.error),
                        const SizedBox(height: 12),
                        Text('Unable to load guest matches: $_error'),
                        const SizedBox(height: 12),
                        FilledButton(
                          onPressed: _loadData,
                          child: const Text('Retry'),
                        ),
                      ],
                    ),
                  ),
                )
              : Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 980),
                    child: RefreshIndicator(
                      onRefresh: _loadData,
                      child: CustomScrollView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        slivers: [
                          SliverPadding(
                            padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
                            sliver: SliverToBoxAdapter(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  if (_guest != null)
                                    _buildRequirementsCard(
                                        scheme, textTheme, currencyFmt),
                                  const SizedBox(height: 20),
                                  Wrap(
                                    spacing: 12,
                                    runSpacing: 6,
                                    alignment: WrapAlignment.spaceBetween,
                                    crossAxisAlignment:
                                        WrapCrossAlignment.center,
                                    children: [
                                      Text(
                                        visibleMatches.length == _matches.length
                                            ? 'Found Matches (${numberFmt.format(_matches.length)})'
                                            : 'Showing ${numberFmt.format(visibleMatches.length)} of ${numberFmt.format(_matches.length)} Matches',
                                        style: textTheme.titleLarge?.copyWith(
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                      Text(
                                        'Select any vehicle for price, dealership location, date & matched features',
                                        style: textTheme.bodySmall?.copyWith(
                                          color: scheme.onSurfaceVariant,
                                        ),
                                      ),
                                    ],
                                  ),
                                  if (_matches.isNotEmpty) ...[
                                    const SizedBox(height: 12),
                                    _buildFilterAndSortBar(
                                      scheme,
                                      textTheme,
                                      numberFmt,
                                      locationCounts,
                                      millsboroCount,
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ),
                          if (_matches.isEmpty)
                            SliverPadding(
                              padding:
                                  const EdgeInsets.fromLTRB(20, 0, 20, 40),
                              sliver: SliverToBoxAdapter(
                                child:
                                    _buildZeroMatchesCard(scheme, textTheme),
                              ),
                            )
                          else if (visibleMatches.isEmpty)
                            SliverPadding(
                              padding:
                                  const EdgeInsets.fromLTRB(20, 0, 20, 40),
                              sliver: SliverToBoxAdapter(
                                child: Card(
                                  child: Padding(
                                    padding: const EdgeInsets.all(24),
                                    child: Column(
                                      children: [
                                        Icon(Icons.filter_alt_off_outlined,
                                            size: 40,
                                            color: scheme.onSurfaceVariant),
                                        const SizedBox(height: 8),
                                        Text(
                                          'No vehicles match the active location/keyword filter.',
                                          style: textTheme.titleSmall,
                                        ),
                                        const SizedBox(height: 10),
                                        TextButton.icon(
                                          onPressed: () {
                                            _searchCtrl.clear();
                                            setState(() {
                                              _selectedLocation =
                                                  _allLocationsFilter;
                                              _searchQuery = '';
                                            });
                                          },
                                          icon: const Icon(Icons.clear_all),
                                          label: const Text('Reset Filters'),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            )
                          else
                            SliverPadding(
                              padding:
                                  const EdgeInsets.fromLTRB(20, 0, 20, 40),
                              sliver: SliverList.builder(
                                itemCount: visibleMatches.length,
                                itemBuilder: (context, index) {
                                  final m = visibleMatches[index];
                                  return Padding(
                                    padding: const EdgeInsets.only(bottom: 12),
                                    child: _buildMatchCard(
                                        m, scheme, textTheme, currencyFmt),
                                  );
                                },
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
    );
  }

  Widget _buildFilterAndSortBar(
    ColorScheme scheme,
    TextTheme textTheme,
    NumberFormat numberFmt,
    List<MapEntry<String, int>> locationCounts,
    int millsboroCount,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _searchCtrl,
                onChanged: (v) => setState(() => _searchQuery = v),
                decoration: InputDecoration(
                  isDense: true,
                  hintText:
                      'Filter by model, trim, city, dealership (e.g. Millsboro, F-150, Bronco)...',
                  prefixIcon: const Icon(Icons.search, size: 20),
                  suffixIcon: _searchQuery.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.clear, size: 18),
                          onPressed: () {
                            _searchCtrl.clear();
                            setState(() => _searchQuery = '');
                          },
                        )
                      : null,
                ),
              ),
            ),
            const SizedBox(width: 10),
            PopupMenuButton<String>(
              tooltip: 'Sort Matches',
              initialValue: _sortBy,
              onSelected: (v) => setState(() => _sortBy = v),
              itemBuilder: (_) => const [
                PopupMenuItem(
                    value: 'score', child: Text('Best Match & Lowest Price')),
                PopupMenuItem(
                    value: 'price_asc', child: Text('Price: Low to High')),
                PopupMenuItem(
                    value: 'price_desc', child: Text('Price: High to Low')),
                PopupMenuItem(
                    value: 'year_desc', child: Text('Model Year: Newest')),
              ],
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: scheme.outlineVariant),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.sort, size: 18, color: scheme.primary),
                    const SizedBox(width: 6),
                    Text(
                      'Sort',
                      style: textTheme.labelLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
        if (locationCounts.length > 1) ...[
          const SizedBox(height: 10),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: FilterChip(
                    label: Text(
                        'All Locations (${numberFmt.format(_matches.length)})'),
                    selected: _selectedLocation == _allLocationsFilter,
                    onSelected: (_) =>
                        setState(() => _selectedLocation = _allLocationsFilter),
                  ),
                ),
                if (millsboroCount > 0)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: FilterChip(
                      avatar: const Icon(Icons.place_outlined, size: 16),
                      label: Text(
                          'Boulevard / Millsboro, DE (${numberFmt.format(millsboroCount)})'),
                      selected: _selectedLocation == _allMillsboroFilter,
                      onSelected: (sel) => setState(() => _selectedLocation =
                          sel ? _allMillsboroFilter : _allLocationsFilter),
                    ),
                  ),
                ...locationCounts.map((entry) {
                  final selected = _selectedLocation == entry.key;
                  return Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: FilterChip(
                      label: Text(
                          '${entry.key} (${numberFmt.format(entry.value)})'),
                      selected: selected,
                      onSelected: (sel) => setState(() => _selectedLocation =
                          sel ? entry.key : _allLocationsFilter),
                    ),
                  );
                }),
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildRequirementsCard(
      ColorScheme scheme, TextTheme textTheme, NumberFormat currencyFmt) {
    final g = _guest!;
    return Card(
      color: scheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 10,
              runSpacing: 8,
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircleAvatar(
                      backgroundColor: scheme.primary,
                      foregroundColor: scheme.onPrimary,
                      child: Text(g.initials),
                    ),
                    const SizedBox(width: 12),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Target Requirements for ${g.name}',
                          style: textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        Text(
                          'Monitored daily at 7:30 AM & 2:00 PM on prestonmotor.com',
                          style: textTheme.labelMedium?.copyWith(
                            color: scheme.primary,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
                if (g.phone.isNotEmpty || g.email.isNotEmpty)
                  Text(
                    [
                      if (g.phone.isNotEmpty) g.phone,
                      if (g.email.isNotEmpty) g.email
                    ].join(' • '),
                    style: textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _specChip(
                    Icons.directions_car_outlined, g.targetVehicleLabel, scheme),
                if (g.drivetrain != 'Any')
                  _specChip(Icons.settings_outlined, g.drivetrain, scheme),
                if (g.maxPrice != null)
                  _specChip(Icons.attach_money,
                      'Max ${currencyFmt.format(g.maxPrice)}', scheme),
                if (g.maxMileage != null)
                  _specChip(
                      Icons.speed_outlined,
                      'Under ${NumberFormat.decimalPattern().format(g.maxMileage)} mi',
                      scheme),
                if (g.exteriorColor.isNotEmpty)
                  _specChip(Icons.palette_outlined, '${g.exteriorColor} Ext.',
                      scheme),
                ...g.features
                    .map((f) => _specChip(Icons.check_circle_outline, f, scheme)),
              ],
            ),
            if (g.notes.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(
                'Notes: ${g.notes}',
                style: textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
            if (g.lastSearchSummary.isNotEmpty) ...[
              const Divider(height: 20),
              Row(
                children: [
                  Icon(Icons.auto_awesome, size: 15, color: scheme.primary),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      g.lastSearchSummary,
                      style: textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _specChip(IconData icon, String label, ColorScheme scheme) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: scheme.primary),
          const SizedBox(width: 5),
          Text(
            label,
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              color: scheme.onSurface,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildZeroMatchesCard(ColorScheme scheme, TextTheme textTheme) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          children: [
            Icon(Icons.manage_search_rounded,
                size: 52, color: scheme.onSurfaceVariant),
            const SizedBox(height: 12),
            Text(
              'No Matching Vehicles in Stock Right Now',
              style:
                  textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            Text(
              'Our Gemini Agent will continue checking prestonmotor.com automatically at 7:30 AM and 2:00 PM every day and record new arrivals here.',
              textAlign: TextAlign.center,
              style: textTheme.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMatchCard(VehicleMatch match, ColorScheme scheme,
      TextTheme textTheme, NumberFormat currencyFmt) {
    final photoUrl = ApiService.resolveVehiclePhotoUrl(match.photoUrl);

    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () {
          if (_guest != null) {
            widget.onSelectMatch(match, _guest!);
          }
        },
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final wide = constraints.maxWidth > 620;
              final imageWidget = ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Container(
                  width: wide ? 210 : double.infinity,
                  height: wide ? 145 : 185,
                  color: scheme.surfaceContainerHighest,
                  child: photoUrl.isNotEmpty
                      ? Image.network(
                          photoUrl,
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) => Icon(
                            Icons.directions_car,
                            size: 48,
                            color: scheme.onSurfaceVariant,
                          ),
                        )
                      : Icon(
                          Icons.directions_car,
                          size: 48,
                          color: scheme.onSurfaceVariant,
                        ),
                ),
              );

              final infoWidget = Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              match.title,
                              style: textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Row(
                              children: [
                                Icon(Icons.location_on_outlined,
                                    size: 15, color: scheme.primary),
                                const SizedBox(width: 4),
                                Expanded(
                                  child: Text(
                                    match.location,
                                    style: textTheme.bodySmall?.copyWith(
                                      fontWeight: FontWeight.w600,
                                      color: scheme.onSurfaceVariant,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text(
                            match.price != null
                                ? currencyFmt.format(match.price)
                                : 'Call for Price',
                            style: textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.w800,
                              color: scheme.primary,
                            ),
                          ),
                          Text(
                            'Found ${_formatFoundDate(match.foundAt)}',
                            style: textTheme.labelSmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: match.matchedFeatures.take(4).map((feat) {
                      return Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: const Color(0xFFC4EED0),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.check_circle,
                                size: 13, color: Color(0xFF0F5223)),
                            const SizedBox(width: 4),
                            Flexible(
                              child: Text(
                                feat,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w600,
                                  color: Color(0xFF0F5223),
                                ),
                              ),
                            ),
                          ],
                        ),
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Flexible(
                        child: Text(
                          [
                            if (match.stockNumber.isNotEmpty)
                              'Stock #${match.stockNumber}',
                            if (match.mileage > 0)
                              '${NumberFormat.decimalPattern().format(match.mileage)} mi',
                            if (match.condition.isNotEmpty) match.condition,
                          ].join(' • '),
                          overflow: TextOverflow.ellipsis,
                          style: textTheme.labelSmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            'View Match Details',
                            style: textTheme.labelMedium?.copyWith(
                              color: scheme.primary,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(width: 4),
                          Icon(Icons.arrow_forward,
                              size: 16, color: scheme.primary),
                        ],
                      ),
                    ],
                  ),
                ],
              );

              if (wide) {
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    imageWidget,
                    const SizedBox(width: 18),
                    Expanded(child: infoWidget),
                  ],
                );
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  imageWidget,
                  const SizedBox(height: 14),
                  infoWidget,
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

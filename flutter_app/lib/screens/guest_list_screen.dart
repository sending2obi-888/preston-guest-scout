import 'package:material_ui/material_ui.dart';
import 'package:intl/intl.dart';
import '../models/models.dart';
import '../services/api_service.dart';
import '../widgets/edit_client_contact_dialog.dart';

class GuestListScreen extends StatefulWidget {
  final List<GuestProfile> guests;
  final bool isLoading;
  final VoidCallback onRefresh;
  final void Function(String guestId) onSelectGuest;
  final VoidCallback onSwitchToIntake;

  const GuestListScreen({
    super.key,
    required this.guests,
    required this.isLoading,
    required this.onRefresh,
    required this.onSelectGuest,
    required this.onSwitchToIntake,
  });

  @override
  State<GuestListScreen> createState() => _GuestListScreenState();
}

class _GuestListScreenState extends State<GuestListScreen> {
  final _searchCtrl = TextEditingController();
  String _query = '';
  bool _isSearchingAll = false;
  final Set<String> _searchingGuestIds = {};

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  String _formatLastChecked(String? iso) {
    if (iso == null || iso.isEmpty) return 'Pending initial scan';
    final dt = DateTime.tryParse(iso)?.toLocal();
    if (dt == null) return iso;
    return DateFormat('MMM d • h:mm a').format(dt);
  }

  Future<void> _runAllSearches() async {
    setState(() => _isSearchingAll = true);
    try {
      await ApiService.triggerSearchAll();
      widget.onRefresh();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
              'Completed live Gemini Agent search across all monitored guests on prestonmotor.com.'),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Batch search error: $e')),
      );
    } finally {
      if (mounted) setState(() => _isSearchingAll = false);
    }
  }

  Future<void> _runSingleGuestSearch(GuestProfile guest) async {
    setState(() => _searchingGuestIds.add(guest.id));
    try {
      final res = await ApiService.triggerGuestSearch(guest.id);
      widget.onRefresh();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${guest.name}: ${res.summary}'),
          action: SnackBarAction(
            label: 'Open',
            onPressed: () => widget.onSelectGuest(guest.id),
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Search failed: $e')),
      );
    } finally {
      if (mounted) setState(() => _searchingGuestIds.remove(guest.id));
    }
  }

  Future<void> _openEditContactDialog(GuestProfile guest) async {
    final updated = await showDialog<GuestProfile>(
      context: context,
      builder: (_) => EditClientContactDialog(guest: guest),
    );
    if (updated == null || !mounted) return;
    widget.onRefresh();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Updated contact info for ${updated.name}.'),
      ),
    );
  }

  Future<void> _confirmDelete(GuestProfile guest) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove Monitored Guest?'),
        content: Text(
            'Stop twice-daily prestonmotor.com searches for ${guest.name} and delete saved matches?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    await ApiService.deleteGuest(guest.id);
    widget.onRefresh();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final currencyFmt = NumberFormat.currency(symbol: '\$', decimalDigits: 0);

    final filtered = widget.guests.where((g) {
      if (_query.isEmpty) return true;
      final q = _query.toLowerCase();
      return g.allSearchableSpecsText.contains(q);
    }).toList();

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 980),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Header Toolbar
              Wrap(
                spacing: 12,
                runSpacing: 12,
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Monitored Guests (${widget.guests.length})',
                        style: textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Searched daily at 7:30 AM & 2:00 PM on prestonmotor.com • Tap any guest to view matches or add another vehicle',
                        style: textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                  Wrap(
                    spacing: 8,
                    children: [
                      FilledButton.tonalIcon(
                        onPressed: _isSearchingAll ? null : _runAllSearches,
                        icon: _isSearchingAll
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.sync),
                        label: Text(
                            _isSearchingAll ? 'Scanning...' : 'Search All Now'),
                      ),
                      FilledButton.icon(
                        onPressed: widget.onSwitchToIntake,
                        icon: const Icon(Icons.person_add_alt_1),
                        label: const Text('Add Guest'),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 14),

              // Search / Filter Input for Unlimited Guests
              TextField(
                controller: _searchCtrl,
                onChanged: (v) => setState(() => _query = v.trim()),
                decoration: InputDecoration(
                  hintText:
                      'Filter guests by name, phone, email, make/model, trim, or notes...',
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: _query.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.clear),
                          onPressed: () {
                            _searchCtrl.clear();
                            setState(() => _query = '');
                          },
                        )
                      : null,
                ),
              ),
              const SizedBox(height: 14),

              // Virtualized Guest List (scales to unlimited guests)
              Expanded(
                child: widget.isLoading && widget.guests.isEmpty
                    ? const Center(child: CircularProgressIndicator())
                    : filtered.isEmpty
                        ? _buildEmptyState(scheme, textTheme)
                        : RefreshIndicator(
                            onRefresh: () async => widget.onRefresh(),
                            child: ListView.separated(
                              padding: const EdgeInsets.only(bottom: 32),
                              itemCount: filtered.length,
                              separatorBuilder: (_, _) =>
                                  const SizedBox(height: 10),
                              itemBuilder: (context, index) {
                                final guest = filtered[index];
                                final isSearchingThis =
                                    _searchingGuestIds.contains(guest.id);
                                final hasMatches = guest.matchCount > 0;
                                final vehicleCount =
                                    guest.effectiveTargets.length;

                                return Card(
                                  clipBehavior: Clip.antiAlias,
                                  child: InkWell(
                                    onTap: () => widget.onSelectGuest(guest.id),
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 18, vertical: 16),
                                      child: Row(
                                        children: [
                                          CircleAvatar(
                                            radius: 24,
                                            backgroundColor: hasMatches
                                                ? scheme.primaryContainer
                                                : scheme.surfaceContainerHighest,
                                            foregroundColor: hasMatches
                                                ? scheme.onPrimaryContainer
                                                : scheme.onSurfaceVariant,
                                            child: Text(
                                              guest.initials,
                                              style: const TextStyle(
                                                fontWeight: FontWeight.w700,
                                              ),
                                            ),
                                          ),
                                          const SizedBox(width: 16),
                                          Expanded(
                                            child: Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                Wrap(
                                                  spacing: 8,
                                                  runSpacing: 6,
                                                  crossAxisAlignment:
                                                      WrapCrossAlignment.center,
                                                  children: [
                                                    Text(
                                                      guest.name,
                                                      style: textTheme
                                                          .titleMedium
                                                          ?.copyWith(
                                                        fontWeight:
                                                            FontWeight.w700,
                                                      ),
                                                    ),
                                                    if (vehicleCount > 1)
                                                      Container(
                                                        padding:
                                                            const EdgeInsets
                                                                .symmetric(
                                                          horizontal: 8,
                                                          vertical: 3,
                                                        ),
                                                        decoration:
                                                            BoxDecoration(
                                                          color: scheme
                                                              .secondaryContainer,
                                                          borderRadius:
                                                              BorderRadius
                                                                  .circular(20),
                                                        ),
                                                        child: Text(
                                                          '$vehicleCount Vehicles',
                                                          style: textTheme
                                                              .labelSmall
                                                              ?.copyWith(
                                                            color: scheme
                                                                .onSecondaryContainer,
                                                            fontWeight:
                                                                FontWeight.w700,
                                                          ),
                                                        ),
                                                      ),
                                                    Container(
                                                      padding: const EdgeInsets
                                                          .symmetric(
                                                          horizontal: 10,
                                                          vertical: 3),
                                                      decoration: BoxDecoration(
                                                        color: hasMatches
                                                            ? const Color(
                                                                0xFFC4EED0)
                                                            : scheme
                                                                .surfaceContainerHighest,
                                                        borderRadius:
                                                            BorderRadius
                                                                .circular(20),
                                                      ),
                                                      child: Text(
                                                        hasMatches
                                                            ? '${guest.matchCount} ${guest.matchCount == 1 ? 'Match' : 'Matches'}${guest.lowestMatchPrice != null ? ' • From ${currencyFmt.format(guest.lowestMatchPrice)}' : ''}'
                                                            : '0 Matches Yet',
                                                        style: textTheme
                                                            .labelSmall
                                                            ?.copyWith(
                                                          color: hasMatches
                                                              ? const Color(
                                                                  0xFF0F5223)
                                                              : scheme
                                                                  .onSurfaceVariant,
                                                          fontWeight:
                                                              FontWeight.w700,
                                                        ),
                                                      ),
                                                    ),
                                                    if (guest
                                                            .selectedCandidateCount >
                                                        0)
                                                      Container(
                                                        key: ValueKey(
                                                          'guest_selected_candidates_badge_${guest.id}',
                                                        ),
                                                        padding:
                                                            const EdgeInsets
                                                                .symmetric(
                                                          horizontal: 9,
                                                          vertical: 3,
                                                        ),
                                                        decoration:
                                                            BoxDecoration(
                                                          color: const Color(
                                                              0xFFFFF0C2),
                                                          borderRadius:
                                                              BorderRadius
                                                                  .circular(20),
                                                          border: Border.all(
                                                            color: const Color(
                                                                0xFFD99B00),
                                                          ),
                                                        ),
                                                        child: Row(
                                                          mainAxisSize:
                                                              MainAxisSize.min,
                                                          children: [
                                                            const Icon(
                                                              Icons
                                                                  .star_rounded,
                                                              size: 13,
                                                              color: Color(
                                                                  0xFF7A5200),
                                                            ),
                                                            const SizedBox(
                                                                width: 3),
                                                            Text(
                                                              '${guest.selectedCandidateCount} Selected',
                                                              style: textTheme
                                                                  .labelSmall
                                                                  ?.copyWith(
                                                                color: const Color(
                                                                    0xFF7A5200),
                                                                fontWeight:
                                                                    FontWeight
                                                                        .w800,
                                                              ),
                                                            ),
                                                          ],
                                                        ),
                                                      ),
                                                  ],
                                                ),
                                                const SizedBox(height: 5),
                                                Text(
                                                  vehicleCount > 1
                                                      ? guest.targetVehicleLabel
                                                      : [
                                                          guest
                                                              .targetVehicleLabel,
                                                          if (guest
                                                                  .drivetrain !=
                                                              'Any')
                                                            guest.drivetrain,
                                                          if (guest.maxPrice !=
                                                              null)
                                                            'Max ${currencyFmt.format(guest.maxPrice)}',
                                                          if (guest
                                                                  .maxMileage !=
                                                              null)
                                                            'Under ${NumberFormat.decimalPattern().format(guest.maxMileage)} mi',
                                                        ].join(' • '),
                                                  style: textTheme.bodyMedium
                                                      ?.copyWith(
                                                    color: scheme.onSurface
                                                        .withValues(alpha: 0.88),
                                                  ),
                                                ),
                                                if (guest.phone.isNotEmpty ||
                                                    guest.email.isNotEmpty) ...[
                                                  const SizedBox(height: 4),
                                                  Wrap(
                                                    spacing: 12,
                                                    runSpacing: 2,
                                                    crossAxisAlignment:
                                                        WrapCrossAlignment
                                                            .center,
                                                    children: [
                                                      if (guest
                                                          .phone.isNotEmpty)
                                                        Row(
                                                          mainAxisSize:
                                                              MainAxisSize.min,
                                                          children: [
                                                            Icon(
                                                              Icons
                                                                  .phone_outlined,
                                                              size: 13,
                                                              color: scheme
                                                                  .onSurfaceVariant,
                                                            ),
                                                            const SizedBox(
                                                                width: 4),
                                                            Text(
                                                              guest.phone,
                                                              style: textTheme
                                                                  .bodySmall
                                                                  ?.copyWith(
                                                                color: scheme
                                                                    .onSurfaceVariant,
                                                                fontWeight:
                                                                    FontWeight
                                                                        .w500,
                                                              ),
                                                            ),
                                                          ],
                                                        ),
                                                      if (guest
                                                          .email.isNotEmpty)
                                                        Row(
                                                          mainAxisSize:
                                                              MainAxisSize.min,
                                                          children: [
                                                            Icon(
                                                              Icons
                                                                  .email_outlined,
                                                              size: 13,
                                                              color: scheme
                                                                  .onSurfaceVariant,
                                                            ),
                                                            const SizedBox(
                                                                width: 4),
                                                            Text(
                                                              guest.email,
                                                              style: textTheme
                                                                  .bodySmall
                                                                  ?.copyWith(
                                                                color: scheme
                                                                    .onSurfaceVariant,
                                                                fontWeight:
                                                                    FontWeight
                                                                        .w500,
                                                              ),
                                                            ),
                                                          ],
                                                        ),
                                                    ],
                                                  ),
                                                ],
                                                const SizedBox(height: 6),
                                                Wrap(
                                                  spacing: 12,
                                                  runSpacing: 4,
                                                  crossAxisAlignment:
                                                      WrapCrossAlignment.center,
                                                  children: [
                                                    Row(
                                                      mainAxisSize:
                                                          MainAxisSize.min,
                                                      children: [
                                                        Icon(
                                                          Icons.schedule,
                                                          size: 14,
                                                          color: scheme.primary,
                                                        ),
                                                        const SizedBox(width: 4),
                                                        Text(
                                                          '7:30 AM & 2:00 PM Daily',
                                                          style: textTheme
                                                              .labelSmall
                                                              ?.copyWith(
                                                            color:
                                                                scheme.primary,
                                                            fontWeight:
                                                                FontWeight.w600,
                                                          ),
                                                        ),
                                                      ],
                                                    ),
                                                    Text(
                                                      'Last scan: ${_formatLastChecked(guest.lastSearchedAt)}',
                                                      style: textTheme
                                                          .labelSmall
                                                          ?.copyWith(
                                                        color: scheme
                                                            .onSurfaceVariant,
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ],
                                            ),
                                          ),
                                          const SizedBox(width: 8),
                                          IconButton(
                                            key: ValueKey(
                                              'guest_list_edit_contact_${guest.id}',
                                            ),
                                            tooltip: 'Edit Client Contact Info',
                                            onPressed: () =>
                                                _openEditContactDialog(guest),
                                            icon: Icon(
                                              Icons.contact_phone_outlined,
                                              color: scheme.onSurfaceVariant,
                                            ),
                                          ),
                                          IconButton(
                                            tooltip:
                                                'Run Gemini Search Now on prestonmotor.com',
                                            onPressed: isSearchingThis
                                                ? null
                                                : () => _runSingleGuestSearch(
                                                    guest),
                                            icon: isSearchingThis
                                                ? const SizedBox(
                                                    width: 18,
                                                    height: 18,
                                                    child:
                                                        CircularProgressIndicator(
                                                      strokeWidth: 2,
                                                    ),
                                                  )
                                                : const Icon(
                                                    Icons.travel_explore),
                                          ),
                                          IconButton(
                                            tooltip: 'Delete Guest',
                                            onPressed: () =>
                                                _confirmDelete(guest),
                                            icon: Icon(
                                              Icons.delete_outline,
                                              color: scheme.onSurfaceVariant,
                                            ),
                                          ),
                                          const Icon(Icons.chevron_right),
                                        ],
                                      ),
                                    ),
                                  ),
                                );
                              },
                            ),
                          ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyState(ColorScheme scheme, TextTheme textTheme) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.people_outline, size: 56, color: scheme.outline),
          const SizedBox(height: 12),
          Text(
            _query.isNotEmpty
                ? 'No monitored guests match "$_query"'
                : 'No guests being monitored yet',
            style: textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          FilledButton.tonalIcon(
            onPressed: widget.onSwitchToIntake,
            icon: const Icon(Icons.add),
            label: const Text('Input First Guest & Vehicle Specs'),
          ),
        ],
      ),
    );
  }
}

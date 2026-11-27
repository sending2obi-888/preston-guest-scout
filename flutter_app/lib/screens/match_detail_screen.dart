import 'package:material_ui/material_ui.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/models.dart';
import '../services/api_service.dart';
import '../widgets/copyable_identifier_badge.dart';
import '../widgets/edit_client_contact_dialog.dart';
import 'vin_recall_screen.dart';

class MatchDetailScreen extends StatefulWidget {
  final VehicleMatch match;
  final GuestProfile guest;
  final VoidCallback? onDataChanged;

  const MatchDetailScreen({
    super.key,
    required this.match,
    required this.guest,
    this.onDataChanged,
  });

  @override
  State<MatchDetailScreen> createState() => _MatchDetailScreenState();
}

class _MatchDetailScreenState extends State<MatchDetailScreen> {
  late VehicleMatch _match;
  late GuestProfile _guest;
  bool _togglingCandidate = false;

  @override
  void initState() {
    super.initState();
    _match = widget.match;
    _guest = widget.guest;
  }

  Future<void> _openEditContactDialog() async {
    final updated = await showDialog<GuestProfile>(
      context: context,
      builder: (_) => EditClientContactDialog(guest: _guest),
    );
    if (updated == null || !mounted) return;
    widget.onDataChanged?.call();
    setState(() {
      _guest = updated;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Updated contact info for ${updated.name}.'),
      ),
    );
  }

  String _formatFullDate(String iso) {
    final dt = DateTime.tryParse(iso)?.toLocal();
    if (dt == null) return iso;
    return DateFormat('EEEE, MMMM d, yyyy • h:mm a').format(dt);
  }

  Future<void> _toggleSelectedCandidate() async {
    if (_togglingCandidate) return;
    final nextSelected = !_match.isSelectedCandidate;
    final previous = _match;
    final nowIso = DateTime.now().toUtc().toIso8601String();

    setState(() {
      _togglingCandidate = true;
      _match = _match.copyWith(
        isSelectedCandidate: nextSelected,
        selectedAt: nextSelected ? nowIso : null,
        clearSelectedAt: !nextSelected,
        selectedUpdatedAt: nowIso,
      );
    });

    try {
      final res = await ApiService.setMatchSelectedCandidate(
        guestId: _guest.id,
        vin: _match.vin.isNotEmpty ? _match.vin : _match.id,
        selected: nextSelected,
      );
      widget.onDataChanged?.call();
      if (!mounted) return;
      setState(() {
        _match = res.match;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            nextSelected
                ? 'Marked ${_match.title} as a Selected Candidate for ${_guest.name}.'
                : 'Removed ${_match.title} from Selected Candidates.',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _match = previous;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not update candidate status: $e')),
      );
    } finally {
      if (mounted) setState(() => _togglingCandidate = false);
    }
  }

  void _openVinRecallCheck(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => Scaffold(
          appBar: AppBar(
            title: Text('NHTSA Recall Check • ${_match.vin}'),
          ),
          body: VinRecallScreen(
            initialVin: _match.vin,
            autoCheckOnInit: true,
          ),
        ),
      ),
    );
  }

  Future<void> _openPrestonListing(BuildContext context) async {
    final urlStr = _match.listingUrl.isNotEmpty
        ? _match.listingUrl
        : 'https://www.prestonmotor.com';
    final uri = Uri.tryParse(urlStr);
    if (uri == null) return;
    final launched =
        await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!launched && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Listing URL: $urlStr')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final currencyFmt = NumberFormat.currency(symbol: '\$', decimalDigits: 0);
    final photoUrl = ApiService.resolveVehiclePhotoUrl(_match.photoUrl);

    return Scaffold(
      appBar: AppBar(
        title: Text(_match.title),
        actions: [
          if (MediaQuery.sizeOf(context).width >= 900)
            IconButton(
              tooltip: 'Edit Client Contact Info',
              onPressed: _openEditContactDialog,
              icon: const Icon(Icons.contact_phone_outlined),
            ),
          if (_match.vin.trim().length == 17)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: FilledButton.tonalIcon(
                onPressed: () => _openVinRecallCheck(context),
                icon: const Icon(Icons.verified_user_outlined, size: 18),
                label: const Text('Check NHTSA Recalls'),
              ),
            ),
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: FilledButton.icon(
              onPressed: () => _openPrestonListing(context),
              icon: const Icon(Icons.open_in_new, size: 18),
              label: const Text('Open on prestonmotor.com'),
            ),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 48),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 960),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Hero Vehicle Card
                Card(
                  clipBehavior: Clip.antiAlias,
                  shape: _match.isSelectedCandidate
                      ? RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                          side: BorderSide(color: scheme.primary, width: 2),
                        )
                      : null,
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final wide = constraints.maxWidth > 680;
                      final photoPane = Container(
                        width: wide ? 380 : double.infinity,
                        height: wide ? 260 : 220,
                        color: scheme.surfaceContainerHighest,
                        child: photoUrl.isNotEmpty
                            ? Image.network(
                                photoUrl,
                                fit: BoxFit.cover,
                                errorBuilder: (_, _, _) => Icon(
                                  Icons.directions_car,
                                  size: 64,
                                  color: scheme.onSurfaceVariant,
                                ),
                              )
                            : Icon(
                                Icons.directions_car,
                                size: 64,
                                color: scheme.onSurfaceVariant,
                              ),
                      );

                      final summaryPane = Padding(
                        padding: const EdgeInsets.all(22),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                if (_match.isSelectedCandidate)
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 10,
                                      vertical: 4,
                                    ),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFFFFF0C2),
                                      borderRadius: BorderRadius.circular(20),
                                      border: Border.all(
                                        color: const Color(0xFFD99B00),
                                      ),
                                    ),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        const Icon(
                                          Icons.star_rounded,
                                          size: 15,
                                          color: Color(0xFF7A5200),
                                        ),
                                        const SizedBox(width: 4),
                                        Text(
                                          'SELECTED CANDIDATE',
                                          style: textTheme.labelSmall?.copyWith(
                                            color: const Color(0xFF7A5200),
                                            fontWeight: FontWeight.w800,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                Tooltip(
                                  message: 'Edit Client Contact Info',
                                  child: Material(
                                    color: scheme.primaryContainer,
                                    borderRadius: BorderRadius.circular(20),
                                    child: InkWell(
                                      key: const ValueKey(
                                        'match_detail_edit_contact_button',
                                      ),
                                      borderRadius: BorderRadius.circular(20),
                                      onTap: _openEditContactDialog,
                                      child: Padding(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 10,
                                          vertical: 4,
                                        ),
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Flexible(
                                              child: Text(
                                                [
                                                  'Matched for ${_guest.name}',
                                                  if (_guest.phone.isNotEmpty)
                                                    _guest.phone,
                                                  if (_guest.email.isNotEmpty)
                                                    _guest.email,
                                                ].join(' • '),
                                                style: textTheme.labelSmall
                                                    ?.copyWith(
                                                  color:
                                                      scheme.onPrimaryContainer,
                                                  fontWeight: FontWeight.w700,
                                                ),
                                              ),
                                            ),
                                            const SizedBox(width: 5),
                                            Icon(
                                              Icons.edit_outlined,
                                              size: 13,
                                              color: scheme.onPrimaryContainer,
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                                if (_match.condition.isNotEmpty)
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 10, vertical: 4),
                                    decoration: BoxDecoration(
                                      color: scheme.secondaryContainer,
                                      borderRadius: BorderRadius.circular(20),
                                    ),
                                    child: Text(
                                      _match.condition,
                                      style: textTheme.labelSmall?.copyWith(
                                        color: scheme.onSecondaryContainer,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ),
                                if (_match.targetLabel.isNotEmpty)
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 10, vertical: 4),
                                    decoration: BoxDecoration(
                                      color: scheme.tertiaryContainer,
                                      borderRadius: BorderRadius.circular(20),
                                    ),
                                    child: Text(
                                      'Criteria: ${_match.targetLabel}',
                                      style: textTheme.labelSmall?.copyWith(
                                        color: scheme.onTertiaryContainer,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            Text(
                              _match.title,
                              style: textTheme.headlineSmall?.copyWith(
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            if (_match.vin.isNotEmpty ||
                                _match.stockNumber.isNotEmpty) ...[
                              const SizedBox(height: 10),
                              Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children: [
                                  if (_match.vin.isNotEmpty)
                                    CopyableIdentifierBadge.vin(_match.vin),
                                  if (_match.stockNumber.isNotEmpty)
                                    CopyableIdentifierBadge.stock(
                                      _match.stockNumber,
                                    ),
                                ],
                              ),
                            ],
                            const SizedBox(height: 14),
                            Wrap(
                              spacing: 12,
                              runSpacing: 8,
                              children: [
                                if (_match.mileage > 0)
                                  _metaBadge(
                                      Icons.speed_outlined,
                                      '${NumberFormat.decimalPattern().format(_match.mileage)} miles',
                                      scheme),
                                if (_match.drivetrain.isNotEmpty)
                                  _metaBadge(Icons.settings_outlined,
                                      _match.drivetrain, scheme),
                                if (_match.exteriorColor.isNotEmpty)
                                  _metaBadge(Icons.palette_outlined,
                                      _match.exteriorColor, scheme),
                                if (_match.engine.isNotEmpty)
                                  _metaBadge(Icons.engineering_outlined,
                                      _match.engine, scheme),
                              ],
                            ),
                            const SizedBox(height: 16),
                            _match.isSelectedCandidate
                                ? FilledButton.tonalIcon(
                                    key: const ValueKey(
                                      'detail_toggle_selected_candidate',
                                    ),
                                    onPressed: _togglingCandidate
                                        ? null
                                        : _toggleSelectedCandidate,
                                    icon: const Icon(
                                      Icons.star_rounded,
                                      size: 19,
                                    ),
                                    label: const Text('Selected Candidate'),
                                  )
                                : OutlinedButton.icon(
                                    key: const ValueKey(
                                      'detail_toggle_selected_candidate',
                                    ),
                                    onPressed: _togglingCandidate
                                        ? null
                                        : _toggleSelectedCandidate,
                                    icon: const Icon(
                                      Icons.star_border_rounded,
                                      size: 19,
                                    ),
                                    label: const Text(
                                      'Mark as Selected Candidate',
                                    ),
                                  ),
                          ],
                        ),
                      );

                      if (wide) {
                        return Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            photoPane,
                            Expanded(child: summaryPane),
                          ],
                        );
                      }
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          photoPane,
                          summaryPane,
                        ],
                      );
                    },
                  ),
                ),
                const SizedBox(height: 18),

                // Core Required Key Details: Price, Location, Date Match Was Found
                LayoutBuilder(
                  builder: (context, constraints) {
                    final wide = constraints.maxWidth > 680;
                    final priceCard = _KeyHighlightCard(
                      icon: Icons.sell_outlined,
                      label: 'VEHICLE PRICE',
                      primaryValue: _match.price != null
                          ? currencyFmt.format(_match.price)
                          : 'Contact Dealer',
                      secondaryValue: [
                        if (_match.msrp != null && _match.msrp! > 0)
                          'MSRP ${currencyFmt.format(_match.msrp)}',
                        if (_match.dealerFee != null)
                          '+\$${_match.dealerFee!.toStringAsFixed(0)} Dealer Fee',
                      ].join(' • '),
                      accentColor: scheme.primary,
                    );

                    final locationCard = _KeyHighlightCard(
                      icon: Icons.location_on_outlined,
                      label: 'DEALERSHIP LOCATION',
                      primaryValue: _match.location,
                      secondaryValue: 'Preston Automotive Group Network',
                      accentColor: scheme.tertiary,
                    );

                    final dateFoundCard = _KeyHighlightCard(
                      icon: Icons.event_available_outlined,
                      label: 'DATE MATCH WAS FOUND',
                      primaryValue: _formatFullDate(_match.foundAt),
                      secondaryValue: 'Discovered via: ${_match.searchSlot}',
                      accentColor: scheme.secondary,
                    );

                    if (wide) {
                      return Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(child: priceCard),
                          const SizedBox(width: 12),
                          Expanded(child: locationCard),
                          const SizedBox(width: 12),
                          Expanded(child: dateFoundCard),
                        ],
                      );
                    }
                    return Column(
                      children: [
                        priceCard,
                        const SizedBox(height: 12),
                        locationCard,
                        const SizedBox(height: 12),
                        dateFoundCard,
                      ],
                    );
                  },
                ),
                const SizedBox(height: 18),

                // Core Required Section: Specific Features Meeting Previously Input Requirements
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(22),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                color: const Color(0xFFC4EED0),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: const Icon(
                                Icons.verified_outlined,
                                color: Color(0xFF0F5223),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Specific Features Meeting ${_guest.name}\'s Requirements',
                                    style: textTheme.titleMedium?.copyWith(
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                  Text(
                                    'Verified against previously input target specs (${_guest.targetVehicleLabel})',
                                    style: textTheme.bodySmall?.copyWith(
                                      color: scheme.onSurfaceVariant,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        if (_match.matchedFeatures.isEmpty)
                          Text(
                            'Matches core Year, Make, and Model specifications.',
                            style: textTheme.bodyMedium,
                          )
                        else
                          Wrap(
                            spacing: 10,
                            runSpacing: 10,
                            children: _match.matchedFeatures.map((feature) {
                              return Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 14, vertical: 10),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFC4EED0)
                                      .withValues(alpha: 0.65),
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(
                                    color: const Color(0xFF146C2E)
                                        .withValues(alpha: 0.35),
                                  ),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Icon(
                                      Icons.check_circle,
                                      size: 18,
                                      color: Color(0xFF146C2E),
                                    ),
                                    const SizedBox(width: 8),
                                    Flexible(
                                      child: Text(
                                        feature,
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w700,
                                          color: Color(0xFF0A3818),
                                          fontSize: 13.5,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              );
                            }).toList(),
                          ),
                        if (_match.agentSummary.isNotEmpty) ...[
                          const SizedBox(height: 18),
                          Container(
                            padding: const EdgeInsets.all(14),
                            decoration: BoxDecoration(
                              color: scheme.surfaceContainerLow,
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: scheme.outlineVariant),
                            ),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Icon(Icons.auto_awesome,
                                    size: 18, color: scheme.primary),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        'Gemini Agent Match Assessment',
                                        style: textTheme.labelMedium?.copyWith(
                                          fontWeight: FontWeight.w700,
                                          color: scheme.primary,
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        _match.agentSummary,
                                        style: textTheme.bodyMedium,
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 18),

                // Additional Equipped Factory Highlights from prestonmotor.com
                if (_match.allHighlights.isNotEmpty)
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'All Equipped Highlights on Vehicle',
                            style: textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 12),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: _match.allHighlights.map((h) {
                              return Chip(
                                visualDensity: VisualDensity.compact,
                                label: Text(h),
                              );
                            }).toList(),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _metaBadge(IconData icon, String text, ColorScheme scheme) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: scheme.primary),
          const SizedBox(width: 6),
          Text(
            text,
            style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}

class _KeyHighlightCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final String primaryValue;
  final String secondaryValue;
  final Color accentColor;

  const _KeyHighlightCard({
    required this.icon,
    required this.label,
    required this.primaryValue,
    required this.secondaryValue,
    required this.accentColor,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 18, color: accentColor),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.6,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              primaryValue,
              style: textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
            if (secondaryValue.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                secondaryValue,
                style: textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

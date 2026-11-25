import 'dart:async';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/models.dart';
import '../services/api_service.dart';
import '../services/nhtsa_recall_service.dart';
import '../widgets/copyable_identifier_badge.dart';

class _UppercaseVinFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final cleaned = newValue.text
        .toUpperCase()
        .replaceAll(RegExp(r'[\s\-]+'), '');
    final truncated =
        cleaned.length > 17 ? cleaned.substring(0, 17) : cleaned;
    return TextEditingValue(
      text: truncated,
      selection: TextSelection.collapsed(offset: truncated.length),
    );
  }
}

class VinRecallScreen extends StatefulWidget {
  final SystemStatus status;
  final VoidCallback? onOpenSettings;
  final String? initialVin;
  final bool autoCheckOnInit;

  const VinRecallScreen({
    super.key,
    this.status = const SystemStatus(),
    this.onOpenSettings,
    this.initialVin,
    this.autoCheckOnInit = false,
  });

  @override
  State<VinRecallScreen> createState() => _VinRecallScreenState();
}

class _VinRecallScreenState extends State<VinRecallScreen> {
  late final TextEditingController _vinController;
  bool _isChecking = false;
  String? _updatingCampaign;
  String _statusFilter = 'all'; // 'all' | 'incomplete' | 'complete'
  String? _errorMessage;
  VinRecallCheckResult? _result;
  List<RecentVinRecallEntry> _recentChecks = const [];
  NautilusHybridRecallScanResult? _nautilusHybridScan;
  bool _loadingNautilusHybrids = false;
  String? _nautilusHybridError;
  bool _showExcludedNautilusHybrids = false;

  @override
  void initState() {
    super.initState();
    final initVin = (widget.initialVin ?? '')
        .toUpperCase()
        .replaceAll(RegExp(r'[\s\-]+'), '')
        .trim();
    _vinController = TextEditingController(text: initVin);
    _vinController.addListener(_onVinTextChanged);
    unawaited(_loadRecentChecks());
    unawaited(_loadNautilusHybridScan());
    if (widget.autoCheckOnInit && initVin.length == 17) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _runRecallCheck();
      });
    }
  }

  @override
  void dispose() {
    _vinController.removeListener(_onVinTextChanged);
    _vinController.dispose();
    super.dispose();
  }

  void _onVinTextChanged() {
    if (!mounted) return;
    setState(() {
      if (_errorMessage != null) {
        _errorMessage = null;
      }
    });
  }

  Future<void> _loadRecentChecks() async {
    final recent = await ApiService.fetchRecentVinRecallChecks();
    if (!mounted) return;
    setState(() => _recentChecks = recent);
  }

  Future<void> _loadNautilusHybridScan({bool forceRefresh = false}) async {
    if (_loadingNautilusHybrids) return;
    setState(() {
      _loadingNautilusHybrids = true;
      _nautilusHybridError = null;
    });
    try {
      final scan = await ApiService.fetchRecallFree2026NautilusHybrids(
        forceRefresh: forceRefresh,
      );
      if (!mounted) return;
      setState(() {
        _nautilusHybridScan = scan;
        _loadingNautilusHybrids = false;
      });
    } catch (err) {
      if (!mounted) return;
      setState(() {
        _nautilusHybridError =
            err.toString().replaceFirst(RegExp(r'^Exception:\s*'), '');
        _loadingNautilusHybrids = false;
      });
    }
  }

  Future<void> _openListingUrl(String urlStr) async {
    final uri = Uri.tryParse(urlStr.trim());
    if (uri == null) return;
    final launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!launched && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Vehicle Listing URL: $urlStr')),
      );
    }
  }

  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final raw = data?.text ?? '';
    if (raw.trim().isEmpty) return;
    final cleaned = raw
        .toUpperCase()
        .replaceAll(RegExp(r'[\s\-]+'), '')
        .trim();
    final clipped =
        cleaned.length > 17 ? cleaned.substring(0, 17) : cleaned;
    setState(() {
      _vinController.text = clipped;
      _vinController.selection =
          TextSelection.collapsed(offset: clipped.length);
      _errorMessage = null;
    });
  }

  Future<void> _openNhtsaWebsite([String? vinOverride]) async {
    final targetVin = (vinOverride ?? _result?.vin ?? _vinController.text)
        .toUpperCase()
        .replaceAll(RegExp(r'[\s\-]+'), '')
        .trim();
    final urlStr = targetVin.length == 17
        ? 'https://www.nhtsa.gov/recalls?vin=${Uri.encodeComponent(targetVin)}'
        : 'https://www.nhtsa.gov/recalls';
    final uri = Uri.tryParse(urlStr);
    if (uri == null) return;
    final launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!launched && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('NHTSA Recalls URL: $urlStr')),
      );
    }
  }

  Future<void> _runRecallCheck([String? vinOverride]) async {
    if (_isChecking) return;
    if (vinOverride != null) {
      _vinController.text = vinOverride;
      _vinController.selection =
          TextSelection.collapsed(offset: vinOverride.length);
    }

    final validation =
        NhtsaRecallService.validateAndNormalizeVin(_vinController.text);
    if (!validation.valid) {
      setState(() => _errorMessage = validation.error);
      return;
    }

    FocusScope.of(context).unfocus();
    setState(() {
      _isChecking = true;
      _errorMessage = null;
      _statusFilter = 'all';
    });

    try {
      final response = await ApiService.checkVinRecalls(validation.vin);
      if (!mounted) return;
      setState(() {
        _result = response.result;
        _recentChecks = response.recent;
        _isChecking = false;
      });
    } catch (err) {
      if (!mounted) return;
      setState(() {
        _errorMessage =
            err.toString().replaceFirst(RegExp(r'^Exception:\s*'), '');
        _isChecking = false;
      });
    }
  }

  Future<void> _toggleCampaignStatus(
    VinRecallCheckResult res,
    NhtsaRecallCampaign rec,
    String nextStatus,
  ) async {
    if (_updatingCampaign != null) return;
    setState(() => _updatingCampaign = rec.campaignNumber);
    try {
      final updated = await ApiService.updateVinRecallStatus(
        vin: res.vin,
        campaignNumber: rec.campaignNumber,
        status: nextStatus,
      );
      if (!mounted) return;
      setState(() {
        _result = updated.result;
        _recentChecks = updated.recent;
        _updatingCampaign = null;
      });
      if (res.vehicle.year == 2026 &&
          res.vehicle.model.toLowerCase().contains('nautilus')) {
        unawaited(_loadNautilusHybridScan(forceRefresh: true));
      }
      final actionWord = nextStatus == 'complete'
          ? 'Marked Complete'
          : (nextStatus == 'incomplete'
              ? 'Marked Incomplete'
              : 'Reset to live VIN status');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 2),
          content: Text('Recall ${rec.campaignNumber}: $actionWord'),
        ),
      );
    } catch (err) {
      if (!mounted) return;
      setState(() => _updatingCampaign = null);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            err.toString().replaceFirst(RegExp(r'^Exception:\s*'), ''),
          ),
        ),
      );
    }
  }

  String _formatCheckedTimestamp(String iso) {
    final dt = DateTime.tryParse(iso)?.toLocal();
    if (dt == null) return iso;
    return DateFormat('MMM d, yyyy • h:mm a').format(dt);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final currentVin = _vinController.text.trim();
    final liveValidation = currentVin.isEmpty
        ? null
        : NhtsaRecallService.validateAndNormalizeVin(currentVin);

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 56),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 960),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Top Gemini + NHTSA.gov/recalls Status Banner
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      scheme.primaryContainer,
                      scheme.secondaryContainer.withValues(alpha: 0.7),
                    ],
                  ),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: scheme.primary.withValues(alpha: 0.2),
                  ),
                ),
                child: Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 12,
                  runSpacing: 10,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          padding: const EdgeInsets.all(9),
                          decoration: BoxDecoration(
                            color: scheme.primary,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Icon(
                            Icons.verified_user_rounded,
                            color: scheme.onPrimary,
                            size: 20,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Flexible(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Gemini NHTSA VIN Recall Checker',
                                style: textTheme.titleSmall?.copyWith(
                                  fontWeight: FontWeight.w800,
                                  color: scheme.onPrimaryContainer,
                                ),
                              ),
                              Text(
                                'Differentiates Incomplete (Open) vs. Complete (Closed) recalls per VIN via www.nhtsa.gov/recalls & ${widget.status.geminiModel}',
                                style: textTheme.bodySmall?.copyWith(
                                  color: scheme.onPrimaryContainer
                                      .withValues(alpha: 0.85),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        OutlinedButton.icon(
                          onPressed: () => _openNhtsaWebsite(),
                          icon: const Icon(Icons.open_in_new, size: 16),
                          label: const Text('www.nhtsa.gov/recalls'),
                        ),
                        if (widget.onOpenSettings != null &&
                            !widget.status.geminiConfigured)
                          FilledButton.tonalIcon(
                            onPressed: widget.onOpenSettings,
                            icon: const Icon(Icons.key_outlined, size: 16),
                            label: const Text('Configure Gemini Key'),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 18),

              // VIN Entry Card
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(22),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.qr_code_scanner_rounded,
                              color: scheme.primary, size: 22),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              'Enter 17-Character Vehicle Identification Number (VIN)',
                              style: textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: currentVin.length == 17 &&
                                      (liveValidation?.valid ?? false)
                                  ? const Color(0xFFC4EED0)
                                  : scheme.surfaceContainerHighest,
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Text(
                              '${currentVin.length} / 17',
                              style: textTheme.labelSmall?.copyWith(
                                fontWeight: FontWeight.w800,
                                fontFamily: 'monospace',
                                color: currentVin.length == 17 &&
                                        (liveValidation?.valid ?? false)
                                    ? const Color(0xFF0F5223)
                                    : scheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'Enter any vehicle VIN to decode its factory build and verify which safety recalls are still Incomplete (Open) vs. Complete (Closed).',
                        style: textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 16),
                      TextField(
                        key: const ValueKey('vin_recall_input'),
                        controller: _vinController,
                        enabled: !_isChecking,
                        textCapitalization: TextCapitalization.characters,
                        inputFormatters: [_UppercaseVinFormatter()],
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 1.4,
                        ),
                        onSubmitted: (_) => _runRecallCheck(),
                        decoration: InputDecoration(
                          labelText: '17-Character VIN',
                          hintText: 'e.g. 1FTFW3L87RKF38272',
                          prefixIcon: const Icon(Icons.tag_rounded),
                          suffixIcon: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (currentVin.isNotEmpty)
                                IconButton(
                                  tooltip: 'Copy VIN to clipboard',
                                  onPressed: () =>
                                      CopyableIdentifierBadge.copyToClipboard(
                                    context,
                                    kindLabel: 'VIN',
                                    rawValue: currentVin,
                                  ),
                                  icon: const Icon(Icons.content_copy_rounded,
                                      size: 18),
                                ),
                              IconButton(
                                tooltip: 'Paste VIN from clipboard',
                                onPressed:
                                    _isChecking ? null : _pasteFromClipboard,
                                icon: const Icon(Icons.content_paste_rounded,
                                    size: 19),
                              ),
                              if (currentVin.isNotEmpty)
                                IconButton(
                                  tooltip: 'Clear VIN',
                                  onPressed: _isChecking
                                      ? null
                                      : () {
                                          setState(() {
                                            _vinController.clear();
                                            _errorMessage = null;
                                          });
                                        },
                                  icon: const Icon(Icons.clear_rounded,
                                      size: 19),
                                ),
                            ],
                          ),
                          errorText: _errorMessage ??
                              (currentVin.isNotEmpty &&
                                      RegExp(r'[IOQ]').hasMatch(currentVin)
                                  ? liveValidation?.error
                                  : null),
                        ),
                      ),
                      const SizedBox(height: 16),
                      Wrap(
                        spacing: 12,
                        runSpacing: 10,
                        alignment: WrapAlignment.spaceBetween,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          FilledButton.icon(
                            key: const ValueKey('check_vin_recalls_button'),
                            onPressed:
                                _isChecking ? null : () => _runRecallCheck(),
                            icon: _isChecking
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2.2,
                                    ),
                                  )
                                : const Icon(Icons.auto_awesome),
                            label: Text(
                              _isChecking
                                  ? 'Checking Incomplete vs. Complete Recalls…'
                                  : 'Check Recalls with Gemini',
                            ),
                          ),
                          Text(
                            'Standard VINs exclude letters I, O, and Q',
                            style: textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),

              if (_isChecking) ...[
                const SizedBox(height: 18),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Row(
                      children: [
                        const SizedBox(
                          width: 28,
                          height: 28,
                          child: CircularProgressIndicator(strokeWidth: 3),
                        ),
                        const SizedBox(width: 18),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Inspecting VIN ${_vinController.text.trim()} for Incomplete vs. Complete Recalls…',
                                style: textTheme.titleSmall?.copyWith(
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                '1. Decoding 17-digit VIN via NHTSA vPIC • 2. Checking live VIN Open Recall completion • 3. Reconciling NHTSA campaigns with Gemini',
                                style: textTheme.bodySmall?.copyWith(
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],

              if (_result != null && !_isChecking) ...[
                const SizedBox(height: 18),
                _buildVerdictCard(context, _result!),
                const SizedBox(height: 16),
                _buildDecodedSpecsCard(context, _result!),
                if (_result!.recalls.isNotEmpty) ...[
                  const SizedBox(height: 18),
                  _buildRecallCampaignsSection(context, _result!),
                ],
              ],

              const SizedBox(height: 20),
              _buildNautilusHybridRecallFreeSection(context),

              if (_recentChecks.isNotEmpty) ...[
                const SizedBox(height: 22),
                _buildRecentChecksCard(context),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildVerdictCard(BuildContext context, VinRecallCheckResult res) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    final hasIncomplete = res.incompleteCount > 0;
    final isUrgent =
        hasIncomplete && (res.parkItUrgent || res.parkOutsideWarning);

    final Color bgTint = !hasIncomplete
        ? const Color(0xFFC4EED0).withValues(alpha: 0.55)
        : isUrgent
            ? scheme.errorContainer.withValues(alpha: 0.75)
            : const Color(0xFFFFE8B3).withValues(alpha: 0.7);
    final Color borderTint = !hasIncomplete
        ? const Color(0xFF146C2E).withValues(alpha: 0.45)
        : isUrgent
            ? scheme.error
            : const Color(0xFFB06000).withValues(alpha: 0.55);
    final Color badgeBg = !hasIncomplete
        ? const Color(0xFF146C2E)
        : isUrgent
            ? scheme.error
            : const Color(0xFFB06000);
    final IconData statusIcon = !hasIncomplete
        ? Icons.verified_rounded
        : isUrgent
            ? Icons.report_rounded
            : Icons.warning_amber_rounded;

    final String topBadgeText = !hasIncomplete
        ? (res.completeCount > 0
            ? '0 INCOMPLETE RECALLS • ${res.completeCount} COMPLETE'
            : '0 MATCHING NHTSA RECALLS')
        : '${res.incompleteCount} INCOMPLETE RECALL${res.incompleteCount == 1 ? '' : 'S'} FOUND';

    return Card(
      key: const ValueKey('vin_recall_verdict_card'),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: borderTint, width: 1.5),
      ),
      child: Container(
        decoration: BoxDecoration(
          color: bgTint,
          borderRadius: BorderRadius.circular(16),
        ),
        padding: const EdgeInsets.all(22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                  decoration: BoxDecoration(
                    color: badgeBg,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(statusIcon, size: 16, color: Colors.white),
                      const SizedBox(width: 6),
                      Text(
                        topBadgeText,
                        style: textTheme.labelSmall?.copyWith(
                          color: Colors.white,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.5,
                        ),
                      ),
                    ],
                  ),
                ),
                if (res.parkItUrgent)
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: const Color(0xFFB3261E),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      'URGENT: DO NOT DRIVE',
                      style: textTheme.labelSmall?.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                if (res.parkOutsideWarning)
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: const Color(0xFF8C1D18),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      'PARK OUTSIDE ADVISORY',
                      style: textTheme.labelSmall?.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: scheme.surface.withValues(alpha: 0.85),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    'Analyzed via ${res.agentMode}',
                    style: textTheme.labelSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Text(
              res.verdictHeadline,
              style: textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 10,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                CopyableIdentifierBadge.vin(res.vin),
                Text(
                  'Checked ${_formatCheckedTimestamp(res.checkedAt)}',
                  style: textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),

            // Side-by-side Incomplete vs. Complete Recall KPI Summary Strip
            Wrap(
              key: const ValueKey('recall_completion_summary_strip'),
              spacing: 12,
              runSpacing: 12,
              children: [
                _buildCompletionKpiCard(
                  context,
                  cardKey: const ValueKey('incomplete_recalls_kpi_card'),
                  count: res.incompleteCount,
                  title: 'Incomplete (Open)',
                  subtitle: res.incompleteCount == 0
                      ? '0 unrepaired recalls on VIN'
                      : 'Action required — open on VIN',
                  icon: res.incompleteCount == 0
                      ? Icons.check_circle_rounded
                      : Icons.error_outline_rounded,
                  accentColor: res.incompleteCount == 0
                      ? const Color(0xFF146C2E)
                      : const Color(0xFFB06000),
                  bgColor: res.incompleteCount == 0
                      ? const Color(0xFFE6F4EA)
                      : const Color(0xFFFFF3DA),
                  onTap: res.recalls.isNotEmpty
                      ? () => setState(() => _statusFilter = 'incomplete')
                      : null,
                ),
                _buildCompletionKpiCard(
                  context,
                  cardKey: const ValueKey('complete_recalls_kpi_card'),
                  count: res.completeCount,
                  title: 'Complete (Closed)',
                  subtitle: res.completeCount == 0
                      ? 'No closed campaigns on VIN'
                      : 'Verified closed / repaired on VIN',
                  icon: Icons.task_alt_rounded,
                  accentColor: const Color(0xFF146C2E),
                  bgColor: const Color(0xFFE6F4EA),
                  onTap: res.recalls.isNotEmpty
                      ? () => setState(() => _statusFilter = 'complete')
                      : null,
                ),
              ],
            ),

            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: scheme.surface.withValues(alpha: 0.92),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: scheme.outlineVariant),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.auto_awesome,
                          size: 18, color: scheme.primary),
                      const SizedBox(width: 8),
                      Text(
                        'Gemini Recall Assessment (www.nhtsa.gov/recalls)',
                        style: textTheme.labelMedium?.copyWith(
                          fontWeight: FontWeight.w800,
                          color: scheme.primary,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(res.geminiSummary, style: textTheme.bodyMedium),
                  if (res.recommendedAction.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(Icons.task_alt_rounded,
                            size: 17, color: scheme.secondary),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            res.recommendedAction,
                            style: textTheme.bodySmall?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 12,
              runSpacing: 10,
              children: [
                FilledButton.icon(
                  key: const ValueKey('open_nhtsa_recalls_button'),
                  onPressed: () => _openNhtsaWebsite(res.vin),
                  icon: const Icon(Icons.open_in_new, size: 17),
                  label: const Text('Verify VIN on www.nhtsa.gov/recalls'),
                ),
                OutlinedButton.icon(
                  onPressed: () => _runRecallCheck(res.vin),
                  icon: const Icon(Icons.refresh_rounded, size: 17),
                  label: const Text('Re-Check Now'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCompletionKpiCard(
    BuildContext context, {
    required Key cardKey,
    required int count,
    required String title,
    required String subtitle,
    required IconData icon,
    required Color accentColor,
    required Color bgColor,
    VoidCallback? onTap,
  }) {
    final textTheme = Theme.of(context).textTheme;
    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 230, maxWidth: 320),
      child: Material(
        key: cardKey,
        color: bgColor,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: accentColor.withValues(alpha: 0.45)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: accentColor,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(icon, size: 20, color: Colors.white),
                ),
                const SizedBox(width: 12),
                Flexible(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '$count $title',
                        style: textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w800,
                          color: const Color(0xFF1B1F23),
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        style: textTheme.labelSmall?.copyWith(
                          color: const Color(0xFF3C4043),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDecodedSpecsCard(BuildContext context, VinRecallCheckResult res) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final v = res.vehicle;

    final specPairs = <(String, String)>[
      if (v.year != null) ('Model Year', '${v.year}'),
      if (v.make.isNotEmpty) ('Make', v.make),
      if (v.model.isNotEmpty) ('Model', v.model),
      if (v.trim.isNotEmpty) ('Trim / Series', v.trim),
      if (v.bodyClass.isNotEmpty) ('Body & Cab', v.bodyClass),
      if (v.driveType.isNotEmpty) ('Drivetrain', v.driveType),
      if (v.engine.isNotEmpty) ('Engine', v.engine),
      if (v.fuelType.isNotEmpty) ('Fuel Type', v.fuelType),
      if (v.plant.isNotEmpty) ('Assembly Plant', v.plant),
    ];

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.directions_car_outlined,
                    size: 20, color: scheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Decoded Factory VIN Specifications — ${res.vehicleTitle}',
                    style: textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: specPairs.map((pair) {
                return Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: scheme.outlineVariant),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        pair.$1.toUpperCase(),
                        style: textTheme.labelSmall?.copyWith(
                          fontSize: 10.5,
                          color: scheme.onSurfaceVariant,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        pair.$2,
                        style: textTheme.bodySmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                );
              }).toList(),
            ),
            if (res.queriedModels.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(
                'NHTSA Recall Vehicle Line(s) Checked: ${res.queriedModels.join(', ')}',
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

  Widget _buildRecallCampaignsSection(
    BuildContext context,
    VinRecallCheckResult res,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    final filteredRecalls = res.recalls.where((rec) {
      if (_statusFilter == 'incomplete') return rec.isIncomplete;
      if (_statusFilter == 'complete') return rec.isComplete;
      return true;
    }).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Wrap(
            spacing: 12,
            runSpacing: 10,
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                'NHTSA & Manufacturer Recall Campaigns (${res.recalls.length})',
                style: textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
              Wrap(
                key: const ValueKey('recall_status_filter_bar'),
                spacing: 8,
                runSpacing: 6,
                children: [
                  ChoiceChip(
                    key: const ValueKey('filter_all_recalls_chip'),
                    label: Text('All (${res.recalls.length})'),
                    selected: _statusFilter == 'all',
                    onSelected: (_) => setState(() => _statusFilter = 'all'),
                  ),
                  ChoiceChip(
                    key: const ValueKey('filter_incomplete_recalls_chip'),
                    label: Text('Incomplete (${res.incompleteCount})'),
                    selected: _statusFilter == 'incomplete',
                    onSelected: (_) =>
                        setState(() => _statusFilter = 'incomplete'),
                  ),
                  ChoiceChip(
                    key: const ValueKey('filter_complete_recalls_chip'),
                    label: Text('Complete (${res.completeCount})'),
                    selected: _statusFilter == 'complete',
                    onSelected: (_) =>
                        setState(() => _statusFilter = 'complete'),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        if (filteredRecalls.isEmpty)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(22),
              child: Row(
                children: [
                  Icon(
                    _statusFilter == 'incomplete'
                        ? Icons.verified_rounded
                        : Icons.info_outline_rounded,
                    color: _statusFilter == 'incomplete'
                        ? const Color(0xFF146C2E)
                        : scheme.primary,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      _statusFilter == 'incomplete'
                          ? '0 Incomplete Recalls — All applicable recall campaigns on VIN ${res.vin} are Complete!'
                          : '0 Complete Recalls in this view. Switch to "All" or "Incomplete" to inspect open campaigns.',
                      style: textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          )
        else
          ...filteredRecalls.map(
            (rec) => _buildSingleCampaignCard(context, res, rec),
          ),
      ],
    );
  }

  Widget _buildSingleCampaignCard(
    BuildContext context,
    VinRecallCheckResult res,
    NhtsaRecallCampaign rec,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    final isComplete = rec.isComplete;
    final isIncomplete = rec.isIncomplete;
    final isOther = rec.isOtherVariant;
    final isUpdatingThis = _updatingCampaign == rec.campaignNumber;

    final Color borderColor = isComplete
        ? const Color(0xFF146C2E).withValues(alpha: 0.45)
        : isIncomplete
            ? ((rec.parkIt || rec.parkOutSide)
                ? const Color(0xFFB3261E)
                : const Color(0xFFB06000).withValues(alpha: 0.65))
            : scheme.outlineVariant;

    final Color statusPillBg = isComplete
        ? const Color(0xFF146C2E)
        : isIncomplete
            ? (rec.isRemedyUnavailable
                ? const Color(0xFF8C1D18)
                : const Color(0xFFB06000))
            : scheme.surfaceContainerHighest;

    final Color statusPillFg =
        isOther ? scheme.onSurfaceVariant : Colors.white;

    final IconData statusPillIcon = isComplete
        ? Icons.task_alt_rounded
        : isIncomplete
            ? Icons.warning_amber_rounded
            : Icons.remove_circle_outline_rounded;

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Card(
        key: ValueKey('recall_card_${rec.campaignNumber}'),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(
            color: borderColor,
            width: isIncomplete ? 1.6 : 1.2,
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 8,
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      // Primary Complete vs. Incomplete Status Badge
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 5,
                        ),
                        decoration: BoxDecoration(
                          color: statusPillBg,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(statusPillIcon, size: 14, color: statusPillFg),
                            const SizedBox(width: 5),
                            Text(
                              rec.completionBadgeLabel,
                              style: textTheme.labelSmall?.copyWith(
                                color: statusPillFg,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 0.3,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: scheme.primaryContainer,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          'NHTSA #${rec.campaignNumber}',
                          style: textTheme.labelSmall?.copyWith(
                            fontFamily: 'monospace',
                            fontWeight: FontWeight.w800,
                            color: scheme.onPrimaryContainer,
                          ),
                        ),
                      ),
                      if (rec.oemRecallNumber.isNotEmpty)
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 9,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: scheme.secondaryContainer,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            'OEM #${rec.oemRecallNumber}',
                            style: textTheme.labelSmall?.copyWith(
                              fontFamily: 'monospace',
                              fontWeight: FontWeight.w800,
                              color: scheme.onSecondaryContainer,
                            ),
                          ),
                        ),
                      if (rec.reportDate.isNotEmpty)
                        Text(
                          'Reported ${rec.reportDate}',
                          style: textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      if (rec.parkIt && isIncomplete)
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 9,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xFFB3261E),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(
                            'DO NOT DRIVE',
                            style: textTheme.labelSmall?.copyWith(
                              color: Colors.white,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                      if (rec.parkOutSide && isIncomplete)
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 9,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xFF8C1D18),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(
                            'PARK OUTSIDE',
                            style: textTheme.labelSmall?.copyWith(
                              color: Colors.white,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                      if (rec.overTheAirUpdate)
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 9,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: scheme.secondaryContainer,
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(
                            'OTA Software Remedy',
                            style: textTheme.labelSmall?.copyWith(
                              color: scheme.onSecondaryContainer,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                    ],
                  ),
                  if (!isOther)
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        if (isIncomplete)
                          FilledButton.tonalIcon(
                            key: ValueKey(
                              'toggle_recall_status_${rec.campaignNumber}',
                            ),
                            onPressed: _updatingCampaign != null
                                ? null
                                : () => _toggleCampaignStatus(
                                      res,
                                      rec,
                                      'complete',
                                    ),
                            icon: isUpdatingThis
                                ? const SizedBox(
                                    width: 14,
                                    height: 14,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(
                                    Icons.check_circle_outline_rounded,
                                    size: 16,
                                  ),
                            label: const Text('Mark Complete'),
                          )
                        else
                          OutlinedButton.icon(
                            key: ValueKey(
                              'toggle_recall_status_${rec.campaignNumber}',
                            ),
                            onPressed: _updatingCampaign != null
                                ? null
                                : () => _toggleCampaignStatus(
                                      res,
                                      rec,
                                      'incomplete',
                                    ),
                            icon: isUpdatingThis
                                ? const SizedBox(
                                    width: 14,
                                    height: 14,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.replay_rounded, size: 16),
                            label: const Text('Mark Incomplete'),
                          ),
                        if (rec.isManualOverride)
                          TextButton(
                            key: ValueKey(
                              'reset_recall_status_${rec.campaignNumber}',
                            ),
                            onPressed: _updatingCampaign != null
                                ? null
                                : () => _toggleCampaignStatus(res, rec, 'auto'),
                            child: const Text('Reset'),
                          ),
                      ],
                    ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                rec.component,
                style: textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
              if (rec.vinStatusNote.isNotEmpty) ...[
                const SizedBox(height: 6),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                  decoration: BoxDecoration(
                    color: isComplete
                        ? const Color(0xFFE6F4EA)
                        : isIncomplete
                            ? const Color(0xFFFFF3DA)
                            : scheme.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        isComplete
                            ? Icons.verified_rounded
                            : Icons.fact_check_outlined,
                        size: 15,
                        color: isComplete
                            ? const Color(0xFF146C2E)
                            : const Color(0xFF7A4100),
                      ),
                      const SizedBox(width: 7),
                      Expanded(
                        child: Text(
                          rec.vinStatusNote,
                          style: textTheme.bodySmall?.copyWith(
                            fontWeight: FontWeight.w700,
                            color: isComplete
                                ? const Color(0xFF0F5223)
                                : const Color(0xFF5F3200),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              if (rec.geminiNote.isNotEmpty) ...[
                const SizedBox(height: 6),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.auto_awesome, size: 15, color: scheme.primary),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        rec.geminiNote,
                        style: textTheme.bodySmall?.copyWith(
                          color: scheme.primary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
              if (rec.summary.isNotEmpty) ...[
                const SizedBox(height: 10),
                _campaignDetailBlock(
                  context,
                  label: 'Summary',
                  body: rec.summary,
                ),
              ],
              if (rec.consequence.isNotEmpty) ...[
                const SizedBox(height: 8),
                _campaignDetailBlock(
                  context,
                  label: 'Safety Risk',
                  body: rec.consequence,
                ),
              ],
              if (rec.remedy.isNotEmpty) ...[
                const SizedBox(height: 8),
                _campaignDetailBlock(
                  context,
                  label: 'Dealer Remedy',
                  body: rec.remedy,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _campaignDetailBlock(
    BuildContext context, {
    required String label,
    required String body,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return RichText(
      text: TextSpan(
        style: textTheme.bodySmall?.copyWith(
          color: scheme.onSurface,
          height: 1.4,
        ),
        children: [
          TextSpan(
            text: '$label: ',
            style: const TextStyle(fontWeight: FontWeight.w800),
          ),
          TextSpan(text: body),
        ],
      ),
    );
  }

  Widget _buildRecentChecksCard(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.history_rounded, size: 20, color: scheme.primary),
                const SizedBox(width: 8),
                Text(
                  'Recent VIN Recall Checks',
                  style: textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            ..._recentChecks.take(8).map((entry) {
              final hasOpen = entry.incompleteCount > 0;
              return ListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                leading: CircleAvatar(
                  radius: 17,
                  backgroundColor: hasOpen
                      ? const Color(0xFFFFE8B3)
                      : const Color(0xFFC4EED0),
                  child: Icon(
                    hasOpen
                        ? Icons.warning_amber_rounded
                        : Icons.verified_rounded,
                    size: 18,
                    color: hasOpen
                        ? const Color(0xFF7A4100)
                        : const Color(0xFF146C2E),
                  ),
                ),
                title: Text(
                  entry.vehicleTitle,
                  style: textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                subtitle: Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      CopyableIdentifierBadge.vin(entry.vin, compact: true),
                      Text(
                        '${entry.incompleteCount} incomplete • ${entry.completeCount} complete',
                        style: textTheme.bodySmall?.copyWith(
                          color: hasOpen
                              ? const Color(0xFF7A4100)
                              : const Color(0xFF146C2E),
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
                trailing: TextButton.icon(
                  onPressed:
                      _isChecking ? null : () => _runRecallCheck(entry.vin),
                  icon: const Icon(Icons.search_rounded, size: 16),
                  label: const Text('Check'),
                ),
                onTap: _isChecking ? null : () => _runRecallCheck(entry.vin),
              );
            }),
          ],
        ),
      ),
    );
  }

  Widget _buildNautilusHybridRecallFreeSection(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final scan = _nautilusHybridScan;
    final currencyFmt = NumberFormat.currency(symbol: '\$', decimalDigits: 0);

    return Card(
      key: const ValueKey('nautilus_hybrid_recall_free_section'),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: const Color(0xFF146C2E).withValues(alpha: 0.38),
          width: 1.4,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 12,
              runSpacing: 10,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(9),
                      decoration: BoxDecoration(
                        color: const Color(0xFFE6F4EA),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Icon(
                        Icons.electric_car_rounded,
                        color: Color(0xFF146C2E),
                        size: 22,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Flexible(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '2026 Lincoln Nautilus Hybrid — In-Stock Without Active Recall',
                            style: textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'Live prestonmotor.com inventory cross-referenced per VIN via Gemini & www.nhtsa.gov/recalls',
                            style: textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilledButton.tonalIcon(
                      key: const ValueKey('refresh_nautilus_hybrid_scan_button'),
                      onPressed: _loadingNautilusHybrids
                          ? null
                          : () => _loadNautilusHybridScan(forceRefresh: true),
                      icon: _loadingNautilusHybrids
                          ? const SizedBox(
                              width: 15,
                              height: 15,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.refresh_rounded, size: 17),
                      label: Text(
                        _loadingNautilusHybrids
                            ? 'Scanning Hybrids…'
                            : 'Refresh Scan',
                      ),
                    ),
                  ],
                ),
              ],
            ),

            if (_loadingNautilusHybrids && scan == null) ...[
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2.5),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Text(
                        'Scanning live 2026 Lincoln Nautilus Hybrid VINs on prestonmotor.com and checking www.nhtsa.gov/recalls with Gemini…',
                        style: textTheme.bodySmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ] else if (_nautilusHybridError != null && scan == null) ...[
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: scheme.errorContainer.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    Icon(Icons.error_outline_rounded,
                        color: scheme.error, size: 20),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        _nautilusHybridError!,
                        style: textTheme.bodySmall?.copyWith(
                          color: scheme.onErrorContainer,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ] else if (scan != null) ...[
              const SizedBox(height: 14),
              Wrap(
                spacing: 10,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  _buildNautilusScanStatPill(
                    context,
                    label:
                        '${scan.recallFreeCount} Recall-Free Ready',
                    icon: Icons.verified_rounded,
                    fg: const Color(0xFF0F5223),
                    bg: const Color(0xFFE6F4EA),
                  ),
                  _buildNautilusScanStatPill(
                    context,
                    label:
                        '${scan.totalHybridsInStock} Hybrids Scanned on prestonmotor.com',
                    icon: Icons.directions_car_filled_outlined,
                    fg: scheme.onSecondaryContainer,
                    bg: scheme.secondaryContainer,
                  ),
                  if (scan.excludedActiveRecallCount > 0)
                    _buildNautilusScanStatPill(
                      context,
                      label:
                          '${scan.excludedActiveRecallCount} Excluded (Active Recall)',
                      icon: Icons.block_rounded,
                      fg: const Color(0xFF7A4100),
                      bg: const Color(0xFFFFF3DA),
                    ),
                  if (scan.checkedAt.isNotEmpty)
                    Text(
                      'Updated ${_formatCheckedTimestamp(scan.checkedAt)} • ${scan.agentMode}',
                      style: textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
              if (scan.geminiSummary.isNotEmpty) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: scheme.outlineVariant),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.auto_awesome,
                          size: 17, color: scheme.primary),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          scan.geminiSummary,
                          style: textTheme.bodySmall?.copyWith(height: 1.4),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 14),
              if (scan.recallFreeVehicles.isEmpty)
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: scheme.outlineVariant),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.info_outline_rounded,
                        color: scheme.primary,
                        size: 20,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          scan.totalHybridsInStock == 0
                              ? 'No in-stock 2026 Lincoln Nautilus Hybrid vehicles were returned from prestonmotor.com right now. Tap "Refresh Scan" to check live inventory.'
                              : 'All ${scan.totalHybridsInStock} in-stock 2026 Lincoln Nautilus Hybrid unit(s) currently have an active/incomplete recall on file at www.nhtsa.gov/recalls.',
                          style: textTheme.bodySmall?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                )
              else
                ...scan.recallFreeVehicles.map(
                  (vehicle) => _buildRecallFreeNautilusCard(
                    context,
                    vehicle,
                    currencyFmt,
                  ),
                ),
              if (scan.excludedActiveRecallVins.isNotEmpty) ...[
                const SizedBox(height: 6),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    key: const ValueKey(
                      'toggle_excluded_nautilus_hybrids_button',
                    ),
                    onPressed: () => setState(
                      () => _showExcludedNautilusHybrids =
                          !_showExcludedNautilusHybrids,
                    ),
                    icon: Icon(
                      _showExcludedNautilusHybrids
                          ? Icons.expand_less_rounded
                          : Icons.expand_more_rounded,
                      size: 18,
                    ),
                    label: Text(
                      _showExcludedNautilusHybrids
                          ? 'Hide ${scan.excludedActiveRecallCount} Excluded Hybrid(s) With Active Recall'
                          : 'View ${scan.excludedActiveRecallCount} Excluded Hybrid(s) Held by Active Recall',
                    ),
                  ),
                ),
                if (_showExcludedNautilusHybrids)
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFFF8EB),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: const Color(0xFFB06000).withValues(alpha: 0.35),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: scan.excludedActiveRecallVins.map((ex) {
                        final campaigns = ex.activeCampaigns.isNotEmpty
                            ? ex.activeCampaigns.join(', ')
                            : '${ex.incompleteCount} open recall(s)';
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Wrap(
                            spacing: 8,
                            runSpacing: 4,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              const Icon(
                                Icons.warning_amber_rounded,
                                size: 15,
                                color: Color(0xFFB06000),
                              ),
                              Text(
                                ex.trim.isNotEmpty
                                    ? '2026 Nautilus ${ex.trim} Hybrid'
                                    : ex.title,
                                style: textTheme.bodySmall?.copyWith(
                                  fontWeight: FontWeight.w700,
                                  color: const Color(0xFF3C2400),
                                ),
                              ),
                              CopyableIdentifierBadge.vin(
                                ex.vin,
                                compact: true,
                              ),
                              if (ex.stockNumber.isNotEmpty)
                                CopyableIdentifierBadge.stock(
                                  ex.stockNumber,
                                  compact: true,
                                ),
                              Text(
                                'Excluded: $campaigns',
                                style: textTheme.labelSmall?.copyWith(
                                  color: const Color(0xFF7A4100),
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ),
                        );
                      }).toList(),
                    ),
                  ),
              ],
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildNautilusScanStatPill(
    BuildContext context, {
    required String label,
    required IconData icon,
    required Color fg,
    required Color bg,
  }) {
    final textTheme = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: fg),
          const SizedBox(width: 6),
          Text(
            label,
            style: textTheme.labelSmall?.copyWith(
              color: fg,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRecallFreeNautilusCard(
    BuildContext context,
    RecallFreeNautilusHybridVehicle v,
    NumberFormat currencyFmt,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final resolvedPhoto = ApiService.resolveVehiclePhotoUrl(v.photoUrl);

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Container(
        key: ValueKey('recall_free_nautilus_${v.vin}'),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerLowest,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: const Color(0xFF146C2E).withValues(alpha: 0.45),
            width: 1.3,
          ),
        ),
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (resolvedPhoto.isNotEmpty) ...[
                  ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: Image.network(
                      resolvedPhoto,
                      width: 112,
                      height: 82,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => Container(
                        width: 112,
                        height: 82,
                        color: scheme.surfaceContainerHighest,
                        child: Icon(
                          Icons.directions_car_filled_rounded,
                          color: scheme.primary,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 14),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        spacing: 8,
                        runSpacing: 6,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 9,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: const Color(0xFF146C2E),
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(
                                  Icons.verified_rounded,
                                  size: 13,
                                  color: Colors.white,
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  '0 ACTIVE RECALLS • READY',
                                  style: textTheme.labelSmall?.copyWith(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w800,
                                    fontSize: 10.5,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color: scheme.primaryContainer,
                              borderRadius: BorderRadius.circular(16),
                            ),
                            child: Text(
                              v.condition,
                              style: textTheme.labelSmall?.copyWith(
                                color: scheme.onPrimaryContainer,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(
                        v.title,
                        style: textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Wrap(
                        spacing: 12,
                        runSpacing: 4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text(
                            v.price != null
                                ? currencyFmt.format(v.price)
                                : 'Call for Price',
                            style: textTheme.titleSmall?.copyWith(
                              color: scheme.primary,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.location_on_outlined,
                                size: 15,
                                color: scheme.onSurfaceVariant,
                              ),
                              const SizedBox(width: 3),
                              Text(
                                v.location,
                                style: textTheme.bodySmall?.copyWith(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                CopyableIdentifierBadge.vin(v.vin),
                if (v.stockNumber.isNotEmpty)
                  CopyableIdentifierBadge.stock(v.stockNumber),
                if (v.drivetrain.isNotEmpty)
                  _specTagChip(context, v.drivetrain),
                if (v.engine.isNotEmpty) _specTagChip(context, v.engine),
                if (v.exteriorColor.isNotEmpty)
                  _specTagChip(context, v.exteriorColor),
              ],
            ),
            if (v.geminiVerificationNote.isNotEmpty) ...[
              const SizedBox(height: 10),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(
                  color: const Color(0xFFE6F4EA).withValues(alpha: 0.65),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(
                      Icons.auto_awesome,
                      size: 15,
                      color: Color(0xFF146C2E),
                    ),
                    const SizedBox(width: 7),
                    Expanded(
                      child: Text(
                        v.geminiVerificationNote,
                        style: textTheme.bodySmall?.copyWith(
                          color: const Color(0xFF0F5223),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.tonalIcon(
                  key: ValueKey('inspect_nautilus_vin_${v.vin}'),
                  onPressed:
                      _isChecking ? null : () => _runRecallCheck(v.vin),
                  icon: const Icon(Icons.policy_outlined, size: 16),
                  label: const Text('Inspect Full Recall Report'),
                ),
                OutlinedButton.icon(
                  onPressed: () => _openNhtsaWebsite(v.vin),
                  icon: const Icon(Icons.open_in_new, size: 15),
                  label: const Text('Verify on NHTSA.gov'),
                ),
                if (v.listingUrl.isNotEmpty)
                  OutlinedButton.icon(
                    onPressed: () => _openListingUrl(v.listingUrl),
                    icon: const Icon(Icons.directions_car_outlined, size: 16),
                    label: const Text('View on prestonmotor.com'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _specTagChip(BuildContext context, String text) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.65),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        text,
        style: textTheme.labelSmall?.copyWith(
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

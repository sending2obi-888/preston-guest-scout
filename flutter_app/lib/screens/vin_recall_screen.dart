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
  String? _errorMessage;
  VinRecallCheckResult? _result;
  List<RecentVinRecallEntry> _recentChecks = const [];

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
        _errorMessage = err.toString().replaceFirst(RegExp(r'^Exception:\s*'), '');
        _isChecking = false;
      });
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
                                'Decodes any 17-digit VIN & checks www.nhtsa.gov/recalls with ${widget.status.geminiModel}',
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
                        'Enter any vehicle VIN to decode its factory build and have Gemini check www.nhtsa.gov/recalls for safety recalls.',
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
                                  ? 'Checking www.nhtsa.gov/recalls with Gemini…'
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
                                'Inspecting VIN ${_vinController.text.trim()} on NHTSA…',
                                style: textTheme.titleSmall?.copyWith(
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                '1. Decoding 17-digit VIN via NHTSA vPIC • 2. Querying www.nhtsa.gov/recalls safety campaigns • 3. Evaluating applicability with Gemini',
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

    final isUrgent = res.parkItUrgent || res.parkOutsideWarning;
    final Color bgTint = !res.hasRecalls
        ? const Color(0xFFC4EED0).withValues(alpha: 0.55)
        : isUrgent
            ? scheme.errorContainer.withValues(alpha: 0.75)
            : const Color(0xFFFFE8B3).withValues(alpha: 0.7);
    final Color borderTint = !res.hasRecalls
        ? const Color(0xFF146C2E).withValues(alpha: 0.45)
        : isUrgent
            ? scheme.error
            : const Color(0xFFB06000).withValues(alpha: 0.55);
    final Color badgeBg = !res.hasRecalls
        ? const Color(0xFF146C2E)
        : isUrgent
            ? scheme.error
            : const Color(0xFFB06000);
    final IconData statusIcon = !res.hasRecalls
        ? Icons.verified_rounded
        : isUrgent
            ? Icons.report_rounded
            : Icons.warning_amber_rounded;

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
                        !res.hasRecalls
                            ? '0 MATCHING NHTSA RECALLS'
                            : '${res.recallCount} NHTSA RECALL${res.recallCount == 1 ? '' : 'S'} FOUND',
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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Text(
            'NHTSA Safety Recall Campaigns (${res.recalls.length})',
            style: textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
        const SizedBox(height: 10),
        ...res.recalls.map((rec) {
          final isOther = rec.isOtherVariant;
          return Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
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
                        if (rec.reportDate.isNotEmpty)
                          Text(
                            'Reported ${rec.reportDate}',
                            style: textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: isOther
                                ? scheme.surfaceContainerHighest
                                : const Color(0xFFFFE8B3),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(
                            rec.applicability,
                            style: textTheme.labelSmall?.copyWith(
                              fontWeight: FontWeight.w700,
                              color: isOther
                                  ? scheme.onSurfaceVariant
                                  : const Color(0xFF7A4100),
                            ),
                          ),
                        ),
                        if (rec.parkIt)
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
                        if (rec.parkOutSide)
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
                    const SizedBox(height: 10),
                    Text(
                      rec.component,
                      style: textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    if (rec.geminiNote.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(Icons.auto_awesome,
                              size: 15, color: scheme.primary),
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
        }),
      ],
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
              return ListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                leading: CircleAvatar(
                  radius: 17,
                  backgroundColor: entry.hasRecalls
                      ? const Color(0xFFFFE8B3)
                      : const Color(0xFFC4EED0),
                  child: Icon(
                    entry.hasRecalls
                        ? Icons.warning_amber_rounded
                        : Icons.verified_rounded,
                    size: 18,
                    color: entry.hasRecalls
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
                        entry.hasRecalls
                            ? '${entry.recallCount} recall(s)'
                            : '0 recalls',
                        style: textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                          fontWeight: FontWeight.w600,
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
}

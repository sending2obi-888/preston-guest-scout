import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/models.dart';
import '../services/api_service.dart';
import '../services/window_sticker_service.dart';
import '../widgets/copyable_identifier_badge.dart';
import '../widgets/window_sticker_web_embed.dart';
import 'vin_recall_screen.dart';

class _UppercaseStickerVinFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final upper = newValue.text.toUpperCase();
    // If user pastes a block of text or URL containing a 17-char VIN, extract it cleanly
    final embedded =
        RegExp(r'\b([A-HJ-NPR-Z0-9]{17})\b').firstMatch(upper)?.group(1);
    final cleaned =
        embedded ?? upper.replaceAll(RegExp(r'[\s\-]+'), '');
    final truncated =
        cleaned.length > 17 ? cleaned.substring(0, 17) : cleaned;
    return TextEditingValue(
      text: truncated,
      selection: TextSelection.collapsed(offset: truncated.length),
    );
  }
}

class WindowStickerScreen extends StatefulWidget {
  final SystemStatus status;
  final VoidCallback? onOpenSettings;
  final String? initialVin;
  final bool autoPullOnInit;

  const WindowStickerScreen({
    super.key,
    this.status = const SystemStatus(),
    this.onOpenSettings,
    this.initialVin,
    this.autoPullOnInit = false,
  });

  @override
  State<WindowStickerScreen> createState() => _WindowStickerScreenState();
}

class _WindowStickerScreenState extends State<WindowStickerScreen> {
  late final TextEditingController _vinController;
  bool _isPulling = false;
  String? _errorMessage;
  WindowStickerResult? _result;
  Uint8List? _pdfBytes;
  List<Uint8List> _androidRenderedPages = const [];
  bool _renderingAndroidPages = false;

  String _portalUrl = WindowStickerService.stickerPullPortalUrl;
  String _accountEmail = WindowStickerService.defaultUsername;
  List<RecentWindowStickerEntry> _recentStickers = const [];

  @override
  void initState() {
    super.initState();
    final initVin = (widget.initialVin ?? '')
        .toUpperCase()
        .replaceAll(RegExp(r'[\s\-]+'), '')
        .trim();
    _vinController = TextEditingController(text: initVin);
    _vinController.addListener(_onVinChanged);
    unawaited(_loadRecentStickers());
    if (widget.autoPullOnInit && initVin.length == 17) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _runWindowStickerPull();
      });
    }
  }

  @override
  void dispose() {
    _vinController.removeListener(_onVinChanged);
    _vinController.dispose();
    super.dispose();
  }

  void _onVinChanged() {
    if (!mounted) return;
    setState(() {
      if (_errorMessage != null) _errorMessage = null;
    });
  }

  Future<void> _loadRecentStickers() async {
    try {
      final info = await ApiService.fetchRecentWindowStickers();
      if (!mounted) return;
      setState(() {
        _portalUrl = info.portalUrl;
        _accountEmail = info.accountEmail;
        _recentStickers = info.recent;
      });
    } catch (_) {}
  }

  Future<void> _pasteVinFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final raw = (data?.text ?? '').trim();
    if (raw.isEmpty) return;
    final check = WindowStickerService.validateAndExtractVin(raw);
    final nextText = check.vin;
    _vinController.value = TextEditingValue(
      text: nextText,
      selection: TextSelection.collapsed(offset: nextText.length),
    );
  }

  Future<void> _runWindowStickerPull([String? overrideVin]) async {
    if (_isPulling) return;
    final rawInput = (overrideVin ?? _vinController.text).trim();
    final check = WindowStickerService.validateAndExtractVin(rawInput);
    if (!check.valid) {
      setState(() {
        _errorMessage = check.error;
      });
      return;
    }

    if (_vinController.text != check.vin) {
      _vinController.value = TextEditingValue(
        text: check.vin,
        selection: TextSelection.collapsed(offset: check.vin.length),
      );
    }

    FocusScope.of(context).unfocus();
    setState(() {
      _isPulling = true;
      _errorMessage = null;
    });

    try {
      final response = await ApiService.pullWindowSticker(check.vin);
      if (!mounted) return;

      Uint8List? decodedBytes;
      if (response.result.pdfBase64.isNotEmpty) {
        try {
          decodedBytes = base64Decode(response.result.pdfBase64);
        } catch (_) {
          decodedBytes = null;
        }
      }

      setState(() {
        _result = response.result;
        _pdfBytes = decodedBytes;
        _androidRenderedPages = const [];
        _recentStickers = response.recent;
        _accountEmail = response.result.accountEmail;
        _isPulling = false;
      });

      if (!kIsWeb && decodedBytes != null && decodedBytes.isNotEmpty) {
        unawaited(_rasterizePdfForAndroid(decodedBytes));
      }
    } catch (err) {
      if (!mounted) return;
      setState(() {
        _errorMessage =
            err.toString().replaceFirst(RegExp(r'^Exception:\s*'), '');
        _isPulling = false;
      });
    }
  }

  Future<void> _rasterizePdfForAndroid(Uint8List bytes) async {
    setState(() => _renderingAndroidPages = true);
    final pages = await WindowStickerService.renderPdfPagesOnAndroid(bytes);
    if (!mounted) return;
    setState(() {
      _androidRenderedPages = pages;
      _renderingAndroidPages = false;
    });
  }

  Future<void> _downloadOrOpenWindowStickerPdf(
    WindowStickerResult result,
  ) async {
    final fileName =
        result.fileName.isNotEmpty ? result.fileName : 'WindowSticker-${result.vin}.pdf';

    if (kIsWeb && _pdfBytes != null && _pdfBytes!.isNotEmpty) {
      final triggered = triggerWebPdfDownload(
        pdfBytes: _pdfBytes!,
        fileName: fileName,
      );
      if (triggered) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Downloading $fileName...')),
          );
        }
        return;
      }
    }

    final targetUrl = result.pdfUrl.isNotEmpty
        ? result.pdfUrl
        : (result.inlineServerPdfUrl.isNotEmpty
            ? '${result.inlineServerPdfUrl}?download=1'
            : result.ipacketViewerUrl);

    if (targetUrl.isEmpty) return;
    final uri = Uri.tryParse(targetUrl);
    if (uri == null) return;
    final launched =
        await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!launched && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Window Sticker URL: $targetUrl')),
      );
    }
  }

  Future<void> _openExternalUrl(String urlStr) async {
    if (urlStr.trim().isEmpty) return;
    final uri = Uri.tryParse(urlStr.trim());
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  void _openNhtsaRecallCheck(String vin) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => Scaffold(
          appBar: AppBar(title: Text('NHTSA Recall Check • $vin')),
          body: VinRecallScreen(
            status: widget.status,
            onOpenSettings: widget.onOpenSettings,
            initialVin: vin,
            autoCheckOnInit: true,
          ),
        ),
      ),
    );
  }

  Future<void> _openCredentialsDialog() async {
    final userCtrl = TextEditingController(text: _accountEmail);
    final passCtrl =
        TextEditingController(text: WindowStickerService.defaultPassword);
    bool obscure = true;
    bool saving = false;
    String? dialogError;

    final updatedEmail = await showDialog<String>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            final scheme = Theme.of(ctx).colorScheme;
            final textTheme = Theme.of(ctx).textTheme;
            return AlertDialog(
              title: const Text('Auto iPacket StickerPull Account'),
              content: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 440),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'Portal: $_portalUrl',
                      style: textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 14),
                    if (dialogError != null) ...[
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: scheme.errorContainer,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          dialogError!,
                          style: textTheme.bodySmall?.copyWith(
                            color: scheme.onErrorContainer,
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                    ],
                    TextField(
                      key: const ValueKey('stickerpull_username_input'),
                      controller: userCtrl,
                      keyboardType: TextInputType.emailAddress,
                      decoration: const InputDecoration(
                        labelText: 'Auto iPacket Username / Email',
                        prefixIcon: Icon(Icons.alternate_email),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      key: const ValueKey('stickerpull_password_input'),
                      controller: passCtrl,
                      obscureText: obscure,
                      decoration: InputDecoration(
                        labelText: 'Password',
                        prefixIcon: const Icon(Icons.lock_outline),
                        suffixIcon: IconButton(
                          onPressed: () =>
                              setDialogState(() => obscure = !obscure),
                          icon: Icon(
                            obscure
                                ? Icons.visibility_outlined
                                : Icons.visibility_off_outlined,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: saving ? null : () => Navigator.pop(ctx),
                  child: const Text('Cancel'),
                ),
                FilledButton.icon(
                  key: const ValueKey('save_stickerpull_credentials_button'),
                  onPressed: saving
                      ? null
                      : () async {
                          setDialogState(() {
                            saving = true;
                            dialogError = null;
                          });
                          try {
                            final saved =
                                await ApiService.saveStickerPullCredentials(
                              username: userCtrl.text.trim(),
                              password: passCtrl.text,
                            );
                            if (ctx.mounted) {
                              Navigator.pop(ctx, saved.username);
                            }
                          } catch (e) {
                            setDialogState(() {
                              saving = false;
                              dialogError = e
                                  .toString()
                                  .replaceFirst('Exception: ', '');
                            });
                          }
                        },
                  icon: const Icon(Icons.check_circle_outline, size: 18),
                  label: const Text('Save Account'),
                ),
              ],
            );
          },
        );
      },
    );

    userCtrl.dispose();
    passCtrl.dispose();

    if (updatedEmail != null && mounted) {
      setState(() => _accountEmail = updatedEmail);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Updated Auto iPacket StickerPull account to $updatedEmail.',
          ),
        ),
      );
      unawaited(_loadRecentStickers());
    }
  }

  String _formatFileSize(int bytes) {
    if (bytes <= 0) return '';
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
    }
    return '${(bytes / 1024).toStringAsFixed(0)} KB';
  }

  String _formatPulledTime(String iso) {
    if (iso.trim().isEmpty) return '';
    final dt = DateTime.tryParse(iso)?.toLocal();
    if (dt == null) return iso;
    return DateFormat('MMM d, yyyy • h:mm a').format(dt);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final currencyFmt = NumberFormat.currency(symbol: '\$', decimalDigits: 0);
    final vinLen = _vinController.text.trim().length;

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 48),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1020),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Top Hero & VIN Input Card
              Card(
                elevation: 0,
                color: scheme.surfaceContainerLow,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20),
                  side: BorderSide(color: scheme.outlineVariant),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(22),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        spacing: 12,
                        runSpacing: 10,
                        alignment: WrapAlignment.spaceBetween,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(
                                padding: const EdgeInsets.all(10),
                                decoration: BoxDecoration(
                                  color: scheme.primaryContainer,
                                  borderRadius: BorderRadius.circular(14),
                                ),
                                child: Icon(
                                  Icons.receipt_long_rounded,
                                  color: scheme.onPrimaryContainer,
                                  size: 24,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Flexible(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      'Vehicle OEM Window Sticker Lookup',
                                      style: textTheme.titleLarge?.copyWith(
                                        fontWeight: FontWeight.w800,
                                      ),
                                    ),
                                    Text(
                                      'Powered by Gemini + Auto iPacket StickerPull (dpapp.autoipacket.com/stickerpull)',
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
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              ActionChip(
                                key: const ValueKey(
                                  'stickerpull_account_chip',
                                ),
                                avatar: Icon(
                                  Icons.verified_outlined,
                                  size: 16,
                                  color: scheme.primary,
                                ),
                                label: Text(
                                  _accountEmail,
                                  style: textTheme.labelSmall?.copyWith(
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                tooltip:
                                    'Configure Auto iPacket StickerPull credentials',
                                onPressed: _openCredentialsDialog,
                              ),
                              IconButton(
                                tooltip: 'Open dpapp.autoipacket.com/stickerpull',
                                onPressed: () => _openExternalUrl(_portalUrl),
                                icon: const Icon(Icons.open_in_new, size: 19),
                              ),
                            ],
                          ),
                        ],
                      ),
                      const SizedBox(height: 18),

                      // VIN Entry Row
                      LayoutBuilder(
                        builder: (context, constraints) {
                          final wide = constraints.maxWidth >= 640;
                          final vinField = TextField(
                            key: const ValueKey('window_sticker_vin_input'),
                            controller: _vinController,
                            inputFormatters: [_UppercaseStickerVinFormatter()],
                            textCapitalization: TextCapitalization.characters,
                            textInputAction: TextInputAction.search,
                            onSubmitted: (_) => _runWindowStickerPull(),
                            style: const TextStyle(
                              fontFamily: 'monospace',
                              fontWeight: FontWeight.w700,
                              letterSpacing: 1.1,
                            ),
                            decoration: InputDecoration(
                              labelText: '17-Character Vehicle VIN',
                              hintText: 'e.g. 1FTFW3L87RKF38272',
                              prefixIcon: const Icon(Icons.qr_code_rounded),
                              counterText: '',
                              suffixIcon: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 7,
                                      vertical: 3,
                                    ),
                                    decoration: BoxDecoration(
                                      color: vinLen == 17
                                          ? const Color(0xFFC4EED0)
                                          : scheme.surfaceContainerHighest,
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: Text(
                                      '$vinLen/17',
                                      style: textTheme.labelSmall?.copyWith(
                                        fontWeight: FontWeight.w800,
                                        color: vinLen == 17
                                            ? const Color(0xFF0F5223)
                                            : scheme.onSurfaceVariant,
                                      ),
                                    ),
                                  ),
                                  IconButton(
                                    tooltip: 'Paste VIN from clipboard',
                                    onPressed: _isPulling
                                        ? null
                                        : _pasteVinFromClipboard,
                                    icon: const Icon(
                                      Icons.content_paste_rounded,
                                      size: 18,
                                    ),
                                  ),
                                  if (_vinController.text.isNotEmpty)
                                    IconButton(
                                      tooltip: 'Clear VIN',
                                      onPressed: _isPulling
                                          ? null
                                          : () => _vinController.clear(),
                                      icon: const Icon(Icons.clear, size: 18),
                                    ),
                                ],
                              ),
                            ),
                          );

                          final pullButton = FilledButton.icon(
                            key: const ValueKey('pull_window_sticker_button'),
                            onPressed:
                                _isPulling ? null : () => _runWindowStickerPull(),
                            style: FilledButton.styleFrom(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 22,
                                vertical: 16,
                              ),
                            ),
                            icon: _isPulling
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.auto_awesome_rounded),
                            label: Text(
                              _isPulling
                                  ? 'Pulling Sticker...'
                                  : 'Pull Window Sticker',
                            ),
                          );

                          if (wide) {
                            return Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(child: vinField),
                                const SizedBox(width: 12),
                                pullButton,
                              ],
                            );
                          }
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              vinField,
                              const SizedBox(height: 12),
                              pullButton,
                            ],
                          );
                        },
                      ),

                      if (_errorMessage != null) ...[
                        const SizedBox(height: 14),
                        Container(
                          key: const ValueKey('window_sticker_error_banner'),
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: scheme.errorContainer,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Row(
                            children: [
                              Icon(
                                Icons.error_outline_rounded,
                                color: scheme.onErrorContainer,
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  _errorMessage!,
                                  style: textTheme.bodyMedium?.copyWith(
                                    color: scheme.onErrorContainer,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],

                      if (_isPulling) ...[
                        const SizedBox(height: 14),
                        Container(
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: scheme.secondaryContainer.withValues(
                              alpha: 0.65,
                            ),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Row(
                            children: [
                              const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text(
                                  'Gemini is authenticating with dpapp.autoipacket.com/stickerpull and pulling the official OEM Window Sticker for ${_vinController.text.trim()}...',
                                  style: textTheme.bodySmall?.copyWith(
                                    color: scheme.onSecondaryContainer,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],

                      if (_recentStickers.isNotEmpty) ...[
                        const SizedBox(height: 16),
                        Text(
                          'Recent Window Sticker Pulls',
                          style: textTheme.labelMedium?.copyWith(
                            color: scheme.onSurfaceVariant,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: _recentStickers.take(6).map((entry) {
                            return ActionChip(
                              key: ValueKey('recent_sticker_chip_${entry.vin}'),
                              avatar: const Icon(
                                Icons.description_outlined,
                                size: 15,
                              ),
                              label: Text(
                                '${entry.displayTitle} • ${entry.vin.substring(entry.vin.length - 6)}',
                                style: textTheme.labelSmall?.copyWith(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              tooltip:
                                  'Pull Window Sticker for ${entry.displayTitle} (${entry.vin})',
                              onPressed: _isPulling
                                  ? null
                                  : () => _runWindowStickerPull(entry.vin),
                            );
                          }).toList(),
                        ),
                      ],
                    ],
                  ),
                ),
              ),

              if (_result != null) ...[
                const SizedBox(height: 18),
                _buildResultSummaryHeaderCard(
                  _result!,
                  scheme,
                  textTheme,
                  currencyFmt,
                ),
                const SizedBox(height: 16),
                _buildInlineStickerDocumentCard(_result!, scheme, textTheme),
                const SizedBox(height: 16),
                _buildGeminiBreakdownCard(
                  _result!,
                  scheme,
                  textTheme,
                  currencyFmt,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildResultSummaryHeaderCard(
    WindowStickerResult res,
    ColorScheme scheme,
    TextTheme textTheme,
    NumberFormat currencyFmt,
  ) {
    final sizeLabel = _formatFileSize(res.pdfSizeBytes);
    final pulledTime = _formatPulledTime(res.pulledAt);

    return Card(
      key: const ValueKey('window_sticker_result_card'),
      child: Padding(
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
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFFC4EED0),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.check_circle_rounded,
                        size: 14,
                        color: Color(0xFF0F5223),
                      ),
                      const SizedBox(width: 5),
                      Text(
                        'OEM WINDOW STICKER PULLED',
                        style: textTheme.labelSmall?.copyWith(
                          color: const Color(0xFF0F5223),
                          fontWeight: FontWeight.w800,
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
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    res.geminiAnalyzed
                        ? 'Gemini + Auto iPacket StickerPull'
                        : 'Auto iPacket StickerPull',
                    style: textTheme.labelSmall?.copyWith(
                      color: scheme.onPrimaryContainer,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                if (sizeLabel.isNotEmpty)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: scheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      'PDF • $sizeLabel',
                      style: textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              res.displayTitle,
              style: textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 10,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                CopyableIdentifierBadge.vin(res.vin),
                if (res.totalMsrp != null)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      color: scheme.tertiaryContainer,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      'Total MSRP: ${currencyFmt.format(res.totalMsrp)}',
                      style: textTheme.labelMedium?.copyWith(
                        color: scheme.onTertiaryContainer,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                if (pulledTime.isNotEmpty)
                  Text(
                    'Pulled $pulledTime',
                    style: textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
            if (res.salesSummary.isNotEmpty) ...[
              const SizedBox(height: 14),
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
                    Icon(
                      Icons.auto_awesome_outlined,
                      size: 19,
                      color: scheme.primary,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        res.salesSummary,
                        style: textTheme.bodyMedium?.copyWith(height: 1.4),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 16),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                if (res.pdfUrl.isNotEmpty ||
                    res.pdfBase64.isNotEmpty ||
                    res.inlineServerPdfUrl.isNotEmpty)
                  FilledButton.icon(
                    key: const ValueKey('download_window_sticker_pdf_button'),
                    onPressed: () => _downloadOrOpenWindowStickerPdf(res),
                    icon: const Icon(Icons.picture_as_pdf_outlined, size: 18),
                    label: Text(
                      kIsWeb ? 'Download Window Sticker PDF' : 'Open / Save PDF',
                    ),
                  ),
                if (res.pdfUrl.isNotEmpty)
                  FilledButton.tonalIcon(
                    onPressed: () => _openExternalUrl(res.pdfUrl),
                    icon: const Icon(Icons.open_in_new_rounded, size: 18),
                    label: const Text('Open Original Auto iPacket PDF'),
                  ),
                if (res.ipacketViewerUrl.isNotEmpty)
                  OutlinedButton.icon(
                    key: const ValueKey('open_ipacket_viewer_button'),
                    onPressed: () => _openExternalUrl(res.ipacketViewerUrl),
                    icon: const Icon(Icons.web_asset_outlined, size: 18),
                    label: const Text('Interactive Sticker Viewer'),
                  ),
                OutlinedButton.icon(
                  key: const ValueKey('sticker_check_recalls_button'),
                  onPressed: () => _openNhtsaRecallCheck(res.vin),
                  icon: const Icon(Icons.verified_user_outlined, size: 18),
                  label: const Text('Check NHTSA Recalls'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInlineStickerDocumentCard(
    WindowStickerResult res,
    ColorScheme scheme,
    TextTheme textTheme,
  ) {
    return Card(
      key: const ValueKey('window_sticker_inline_preview_card'),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.article_outlined, color: scheme.primary),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Official Window Sticker Document (${res.fileName.isNotEmpty ? res.fileName : '${res.vin}.pdf'})',
                        style: textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      Text(
                        kIsWeb
                            ? 'Embedded OEM Window Sticker preview — scroll or use browser PDF controls to zoom & print'
                            : 'Pinch or double-tap to zoom the rendered OEM Window Sticker below, or tap Open / Save PDF',
                        style: textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            if (kIsWeb &&
                ((_pdfBytes != null && _pdfBytes!.isNotEmpty) ||
                    res.inlineServerPdfUrl.isNotEmpty ||
                    res.ipacketViewerUrl.isNotEmpty))
              Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: scheme.outlineVariant),
                ),
                child: buildWebWindowStickerEmbed(
                  vin: res.vin,
                  pdfBytes: _pdfBytes,
                  inlineServerUrl: res.inlineServerPdfUrl,
                  ipacketViewerUrl: res.ipacketViewerUrl,
                  height: 700,
                ),
              )
            else if (_renderingAndroidPages)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 36),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_androidRenderedPages.isNotEmpty)
              Column(
                children: _androidRenderedPages.asMap().entries.map((entry) {
                  final idx = entry.key;
                  final pngBytes = entry.value;
                  return Padding(
                    padding: EdgeInsets.only(
                      bottom: idx == _androidRenderedPages.length - 1 ? 0 : 14,
                    ),
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: scheme.outlineVariant),
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: InteractiveViewer(
                        minScale: 1.0,
                        maxScale: 5.0,
                        child: Image.memory(
                          pngBytes,
                          fit: BoxFit.contain,
                        ),
                      ),
                    ),
                  );
                }).toList(),
              )
            else
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: scheme.outlineVariant),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.picture_as_pdf_rounded,
                      size: 36,
                      color: scheme.primary,
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            res.fileName.isNotEmpty
                                ? res.fileName
                                : 'WindowSticker-${res.vin}.pdf',
                            style: textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            'Ready from Auto iPacket StickerPull • Tap "Open / Save PDF" above to view or print full screen.',
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
          ],
        ),
      ),
    );
  }

  Widget _buildGeminiBreakdownCard(
    WindowStickerResult res,
    ColorScheme scheme,
    TextTheme textTheme,
    NumberFormat currencyFmt,
  ) {
    final specItems = <(String, String, IconData)>[
      if (res.exteriorColor.isNotEmpty)
        ('Exterior Color', res.exteriorColor, Icons.palette_outlined),
      if (res.interiorColor.isNotEmpty)
        ('Interior', res.interiorColor, Icons.event_seat_outlined),
      if (res.engine.isNotEmpty)
        ('Engine', res.engine, Icons.engineering_outlined),
      if (res.transmission.isNotEmpty)
        ('Transmission', res.transmission, Icons.settings_suggest_outlined),
      if (res.drivetrain.isNotEmpty)
        ('Drivetrain', res.drivetrain, Icons.alt_route_rounded),
      if (res.bodyStyle.isNotEmpty)
        ('Body Style', res.bodyStyle, Icons.directions_car_outlined),
      if (res.hasFuelEconomy)
        (
          'Fuel Economy (MPG)',
          [
            if (res.cityMpg != null) '${res.cityMpg} City',
            if (res.highwayMpg != null) '${res.highwayMpg} Hwy',
            if (res.combinedMpg != null) '${res.combinedMpg} Comb',
          ].join(' / '),
          Icons.local_gas_station_outlined,
        ),
    ];

    if (!res.hasPricingBreakdown &&
        specItems.isEmpty &&
        res.packagesAndOptions.isEmpty &&
        res.standardHighlights.isEmpty &&
        res.warrantySummary.isEmpty) {
      return const SizedBox.shrink();
    }

    return Card(
      key: const ValueKey('window_sticker_specs_card'),
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.analytics_outlined, color: scheme.primary),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Extracted Window Sticker Specifications & Equipment',
                    style: textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ],
            ),

            if (res.hasPricingBreakdown) ...[
              const SizedBox(height: 16),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  if (res.baseMsrp != null)
                    _buildMsrpTile(
                      label: 'Base MSRP',
                      value: currencyFmt.format(res.baseMsrp),
                      scheme: scheme,
                      textTheme: textTheme,
                    ),
                  if (res.optionsTotal != null)
                    _buildMsrpTile(
                      label: 'Factory Options',
                      value: currencyFmt.format(res.optionsTotal),
                      scheme: scheme,
                      textTheme: textTheme,
                    ),
                  if (res.destinationCharge != null)
                    _buildMsrpTile(
                      label: 'Destination & Delivery',
                      value: currencyFmt.format(res.destinationCharge),
                      scheme: scheme,
                      textTheme: textTheme,
                    ),
                  if (res.totalMsrp != null)
                    _buildMsrpTile(
                      label: 'Total MSRP',
                      value: currencyFmt.format(res.totalMsrp),
                      scheme: scheme,
                      textTheme: textTheme,
                      highlight: true,
                    ),
                ],
              ),
            ],

            if (specItems.isNotEmpty) ...[
              const SizedBox(height: 18),
              Wrap(
                spacing: 12,
                runSpacing: 10,
                children: specItems.map((item) {
                  return Container(
                    constraints: const BoxConstraints(minWidth: 200),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: scheme.surfaceContainerLow,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: scheme.outlineVariant),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(item.$3, size: 18, color: scheme.primary),
                        const SizedBox(width: 10),
                        Flexible(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                item.$1,
                                style: textTheme.labelSmall?.copyWith(
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
                              Text(
                                item.$2,
                                style: textTheme.bodyMedium?.copyWith(
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  );
                }).toList(),
              ),
            ],

            if (res.packagesAndOptions.isNotEmpty) ...[
              const SizedBox(height: 20),
              Text(
                'Factory Installed Packages & Optional Equipment (${res.packagesAndOptions.length})',
                style: textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 10),
              Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: scheme.outlineVariant),
                ),
                child: Column(
                  children: res.packagesAndOptions
                      .asMap()
                      .entries
                      .map((entry) {
                    final idx = entry.key;
                    final opt = entry.value;
                    return Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        border: idx == res.packagesAndOptions.length - 1
                            ? null
                            : Border(
                                bottom: BorderSide(
                                  color: scheme.outlineVariant,
                                ),
                              ),
                      ),
                      child: Row(
                        children: [
                          if (opt.code.isNotEmpty) ...[
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 7,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: scheme.secondaryContainer,
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                opt.code,
                                style: textTheme.labelSmall?.copyWith(
                                  fontFamily: 'monospace',
                                  fontWeight: FontWeight.w800,
                                  color: scheme.onSecondaryContainer,
                                ),
                              ),
                            ),
                            const SizedBox(width: 10),
                          ],
                          Expanded(
                            child: Text(
                              opt.description,
                              style: textTheme.bodyMedium?.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          if (opt.price != null)
                            Text(
                              opt.price == 0
                                  ? 'Included'
                                  : currencyFmt.format(opt.price),
                              style: textTheme.bodyMedium?.copyWith(
                                fontWeight: FontWeight.w800,
                                color: scheme.primary,
                              ),
                            ),
                        ],
                      ),
                    );
                  }).toList(),
                ),
              ),
            ],

            if (res.standardHighlights.isNotEmpty) ...[
              const SizedBox(height: 20),
              Text(
                'Standard Equipment Highlights',
                style: textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: res.standardHighlights.map((feat) {
                  return Chip(
                    visualDensity: VisualDensity.compact,
                    avatar: Icon(
                      Icons.check_circle_outline,
                      size: 16,
                      color: scheme.primary,
                    ),
                    label: Text(feat),
                  );
                }).toList(),
              ),
            ],

            if (res.warrantySummary.isNotEmpty) ...[
              const SizedBox(height: 18),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.shield_outlined,
                      size: 18,
                      color: scheme.primary,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Warranty: ${res.warrantySummary}',
                        style: textTheme.bodySmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildMsrpTile({
    required String label,
    required String value,
    required ColorScheme scheme,
    required TextTheme textTheme,
    bool highlight = false,
  }) {
    return Container(
      constraints: const BoxConstraints(minWidth: 165),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: highlight ? scheme.primaryContainer : scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: highlight ? scheme.primary : scheme.outlineVariant,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: textTheme.labelSmall?.copyWith(
              color: highlight
                  ? scheme.onPrimaryContainer
                  : scheme.onSurfaceVariant,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: textTheme.titleMedium?.copyWith(
              color: highlight ? scheme.onPrimaryContainer : scheme.onSurface,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

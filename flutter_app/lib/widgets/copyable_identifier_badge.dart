import 'dart:async';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

/// One-click copyable badge for Vehicle Identification Numbers (VINs) and Stock Numbers.
/// Copies ONLY the clean raw identifier (without "VIN:" or "Stock #" prefix) to the
/// system clipboard immediately on tap and shows visual confirmation.
class CopyableIdentifierBadge extends StatefulWidget {
  final String kindLabel;
  final String displayPrefix;
  final String value;
  final bool compact;

  const CopyableIdentifierBadge({
    super.key,
    required this.kindLabel,
    required this.displayPrefix,
    required this.value,
    this.compact = false,
  });

  factory CopyableIdentifierBadge.vin(
    String vin, {
    Key? key,
    bool compact = false,
  }) {
    final clean = vin.trim();
    return CopyableIdentifierBadge(
      key: key ?? ValueKey('copy_vin_$clean'),
      kindLabel: 'VIN',
      displayPrefix: 'VIN: ',
      value: clean,
      compact: compact,
    );
  }

  factory CopyableIdentifierBadge.stock(
    String stockNumber, {
    Key? key,
    bool compact = false,
  }) {
    final clean = stockNumber.trim().replaceFirst(RegExp(r'^#+'), '');
    return CopyableIdentifierBadge(
      key: key ?? ValueKey('copy_stock_$clean'),
      kindLabel: 'Stock #',
      displayPrefix: 'Stock #',
      value: clean,
      compact: compact,
    );
  }

  /// Copies [rawValue] to the clipboard with a floating confirmation SnackBar.
  static Future<void> copyToClipboard(
    BuildContext context, {
    required String kindLabel,
    required String rawValue,
  }) async {
    final clean = rawValue.trim();
    if (clean.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: clean));
    if (!context.mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
        content: Row(
          children: [
            const Icon(Icons.check_circle_rounded, color: Colors.white, size: 18),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Copied $kindLabel to clipboard: $clean',
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontFamily: 'monospace',
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  State<CopyableIdentifierBadge> createState() =>
      _CopyableIdentifierBadgeState();
}

class _CopyableIdentifierBadgeState extends State<CopyableIdentifierBadge> {
  bool _justCopied = false;
  Timer? _resetTimer;

  @override
  void dispose() {
    _resetTimer?.cancel();
    super.dispose();
  }

  Future<void> _handleTap() async {
    final clean = widget.value.trim();
    if (clean.isEmpty) return;

    await CopyableIdentifierBadge.copyToClipboard(
      context,
      kindLabel: widget.kindLabel,
      rawValue: clean,
    );

    if (!mounted) return;
    _resetTimer?.cancel();
    setState(() => _justCopied = true);
    _resetTimer = Timer(const Duration(milliseconds: 1600), () {
      if (mounted) {
        setState(() => _justCopied = false);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final clean = widget.value.trim();
    if (clean.isEmpty) return const SizedBox.shrink();

    final scheme = Theme.of(context).colorScheme;
    final bgColor = _justCopied
        ? const Color(0xFFC4EED0)
        : scheme.surfaceContainerHighest.withValues(alpha: 0.75);
    final borderColor = _justCopied
        ? const Color(0xFF146C2E)
        : scheme.outlineVariant;
    final fgColor = _justCopied
        ? const Color(0xFF0F5223)
        : scheme.onSurface;
    final iconColor = _justCopied
        ? const Color(0xFF146C2E)
        : scheme.primary;

    return Tooltip(
      message: 'Click to copy ${widget.kindLabel} ($clean)',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: _handleTap,
          borderRadius: BorderRadius.circular(8),
          mouseCursor: SystemMouseCursors.click,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            padding: EdgeInsets.symmetric(
              horizontal: widget.compact ? 8 : 10,
              vertical: widget.compact ? 3.5 : 5,
            ),
            decoration: BoxDecoration(
              color: bgColor,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: borderColor),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(
                    '${widget.displayPrefix}$clean',
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: widget.compact ? 11.5 : 12.5,
                      fontWeight: FontWeight.w700,
                      color: fgColor,
                    ),
                  ),
                ),
                const SizedBox(width: 5),
                Icon(
                  _justCopied
                      ? Icons.check_rounded
                      : Icons.content_copy_rounded,
                  size: widget.compact ? 12.5 : 14,
                  color: iconColor,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

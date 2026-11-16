import 'package:material_ui/material_ui.dart';
import '../models/models.dart';
import '../services/api_service.dart';

/// Material Design 3 Launcher Widget Component.
/// Strictly displays ONLY the names of the last 10 guests input.
/// Selecting a guest's name opens directly to the corresponding vehicle list for that guest.
class LauncherWidgetDialog extends StatefulWidget {
  final void Function(String guestId) onSelectGuest;

  const LauncherWidgetDialog({
    super.key,
    required this.onSelectGuest,
  });

  @override
  State<LauncherWidgetDialog> createState() => _LauncherWidgetDialogState();
}

class _LauncherWidgetDialogState extends State<LauncherWidgetDialog> {
  List<WidgetGuestEntry> _recentTen = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadRecentTen();
  }

  Future<void> _loadRecentTen() async {
    try {
      final list = await ApiService.fetchLauncherWidgetGuests();
      if (!mounted) return;
      setState(() {
        _recentTen = list.take(10).toList();
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 28),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400, maxHeight: 600),
        child: Container(
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(28),
            border: Border.all(
              color: scheme.outlineVariant,
              width: 1.2,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.22),
                blurRadius: 28,
                offset: const Offset(0, 14),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // M3 AppWidget Header
              Container(
                padding: const EdgeInsets.fromLTRB(20, 18, 14, 14),
                decoration: BoxDecoration(
                  color: scheme.primaryContainer,
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(27),
                  ),
                ),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: scheme.primary,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(
                        Icons.widgets_rounded,
                        size: 20,
                        color: scheme.onPrimary,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Preston Scout Widget',
                            style: textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w800,
                              color: scheme.onPrimaryContainer,
                            ),
                          ),
                          Text(
                            'Last 10 Guests Input (${_recentTen.length}/10)',
                            style: textTheme.labelSmall?.copyWith(
                              color: scheme.onPrimaryContainer
                                  .withValues(alpha: 0.85),
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: 'Close Widget',
                      onPressed: () => Navigator.pop(context),
                      icon: Icon(
                        Icons.close,
                        color: scheme.onPrimaryContainer,
                      ),
                    ),
                  ],
                ),
              ),

              // Strictly Last 10 Guest Names List
              Flexible(
                child: _loading
                    ? const Padding(
                        padding: EdgeInsets.all(36),
                        child: Center(child: CircularProgressIndicator()),
                      )
                    : _recentTen.isEmpty
                        ? Padding(
                            padding: const EdgeInsets.all(32),
                            child: Text(
                              'No guests input yet.',
                              textAlign: TextAlign.center,
                              style: textTheme.bodyMedium,
                            ),
                          )
                        : ListView.separated(
                            shrinkWrap: true,
                            padding: const EdgeInsets.all(12),
                            itemCount: _recentTen.length,
                            separatorBuilder: (_, _) =>
                                const SizedBox(height: 6),
                            itemBuilder: (context, idx) {
                              final entry = _recentTen[idx];
                              return Material(
                                color: scheme.surface,
                                borderRadius: BorderRadius.circular(14),
                                child: InkWell(
                                  borderRadius: BorderRadius.circular(14),
                                  onTap: () {
                                    Navigator.pop(context);
                                    widget.onSelectGuest(entry.id);
                                  },
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 14,
                                      vertical: 12,
                                    ),
                                    child: Row(
                                      children: [
                                        Container(
                                          width: 26,
                                          height: 26,
                                          alignment: Alignment.center,
                                          decoration: BoxDecoration(
                                            color: scheme.secondaryContainer,
                                            shape: BoxShape.circle,
                                          ),
                                          child: Text(
                                            '${idx + 1}',
                                            style: textTheme.labelSmall
                                                ?.copyWith(
                                              fontWeight: FontWeight.w800,
                                              color:
                                                  scheme.onSecondaryContainer,
                                            ),
                                          ),
                                        ),
                                        const SizedBox(width: 12),
                                        Expanded(
                                          child: Text(
                                            entry.name,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style:
                                                textTheme.bodyLarge?.copyWith(
                                              fontWeight: FontWeight.w700,
                                            ),
                                          ),
                                        ),
                                        if (entry.matchCount > 0)
                                          Container(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 8,
                                              vertical: 2,
                                            ),
                                            decoration: BoxDecoration(
                                              color: const Color(0xFFC4EED0),
                                              borderRadius:
                                                  BorderRadius.circular(12),
                                            ),
                                            child: Text(
                                              '${entry.matchCount}',
                                              style: const TextStyle(
                                                fontSize: 11.5,
                                                fontWeight: FontWeight.w800,
                                                color: Color(0xFF0F5223),
                                              ),
                                            ),
                                          ),
                                        const SizedBox(width: 6),
                                        Icon(
                                          Icons.open_in_new_rounded,
                                          size: 16,
                                          color: scheme.primary,
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
              ),

              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
                child: Text(
                  'Tap a guest\'s name to jump straight to their prestonmotor.com vehicle list.',
                  textAlign: TextAlign.center,
                  style: textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

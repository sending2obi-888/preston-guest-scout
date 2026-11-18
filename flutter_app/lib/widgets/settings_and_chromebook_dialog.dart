import 'package:material_ui/material_ui.dart';
import '../models/models.dart';
import '../services/api_service.dart';

class SettingsAndChromebookDialog extends StatefulWidget {
  final VoidCallback onSaved;

  const SettingsAndChromebookDialog({
    super.key,
    required this.onSaved,
  });

  @override
  State<SettingsAndChromebookDialog> createState() =>
      _SettingsAndChromebookDialogState();
}

class _SettingsAndChromebookDialogState
    extends State<SettingsAndChromebookDialog> {
  final _apiKeyCtrl = TextEditingController();
  String _model = 'gemini-2.5-flash';
  String _timezone = 'America/New_York';
  String _maskedKey = '';
  bool _geminiConfigured = false;
  bool _loading = true;
  bool _saving = false;

  List<BackupEntry> _backups = const [];
  bool _creatingBackup = false;
  String? _restoringBackupId;
  String? _expandedBackupId;
  String? _backupStatusBanner;

  static const List<String> _models = [
    'gemini-2.5-flash',
    'gemini-2.5-pro',
    'gemini-2.0-flash',
  ];

  static const List<String> _timezones = [
    'America/New_York',
    'America/Chicago',
    'America/Denver',
    'America/Los_Angeles',
  ];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _apiKeyCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final results = await Future.wait<dynamic>([
        ApiService.fetchSettings(),
        ApiService.fetchBackups().catchError((_) => <BackupEntry>[]),
      ]);
      if (!mounted) return;
      final s = results[0] as Map<String, dynamic>;
      final loadedBackups = (results[1] as List<BackupEntry>).take(5).toList();
      setState(() {
        _geminiConfigured = s['geminiConfigured'] == true;
        _maskedKey = s['geminiKeyMasked']?.toString() ?? '';
        final loadedModel = s['geminiModel']?.toString() ?? 'gemini-2.5-flash';
        _model = _models.contains(loadedModel) ? loadedModel : _models.first;
        final loadedTz = s['timezone']?.toString() ?? 'America/New_York';
        _timezone =
            _timezones.contains(loadedTz) ? loadedTz : _timezones.first;
        _backups = loadedBackups;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  String _formatBackupTimestamp(String rawIso) {
    final parsed = DateTime.tryParse(rawIso)?.toLocal();
    if (parsed == null) return rawIso;
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    final month = months[parsed.month - 1];
    final hour12 = parsed.hour % 12 == 0 ? 12 : parsed.hour % 12;
    final min = parsed.minute.toString().padLeft(2, '0');
    final ampm = parsed.hour >= 12 ? 'PM' : 'AM';
    return '$month ${parsed.day}, ${parsed.year} • $hour12:$min $ampm';
  }

  Future<void> _handleCreateManualBackup() async {
    if (_creatingBackup) return;
    setState(() {
      _creatingBackup = true;
      _backupStatusBanner = null;
    });
    try {
      final updated = await ApiService.createManualBackup(
        label: 'Manual Backup',
      );
      if (!mounted) return;
      setState(() {
        _backups = updated.take(5).toList();
        _backupStatusBanner = 'Saved new backup snapshot (${_backups.length}/5).';
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to create backup: $e')),
      );
    } finally {
      if (mounted) setState(() => _creatingBackup = false);
    }
  }

  Future<void> _handleSelectAndLoadBackup(BackupEntry backup) async {
    if (_restoringBackupId != null) return;
    setState(() {
      _backupStatusBanner = null;
    });

    try {
      final preview = await ApiService.inspectBackupConflicts(backup.id);
      if (!mounted) return;

      BackupConflictResolution? resolution;
      if (preview.hasConflicts) {
        resolution = await showDialog<BackupConflictResolution>(
          context: context,
          builder: (_) => BackupConflictResolutionDialog(preview: preview),
        );
        if (resolution == null || !mounted) {
          return;
        }
      } else {
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            icon: const Icon(Icons.restore_rounded),
            title: const Text('Load Selected Backup?'),
            content: Text(
              'Restore ${backup.guestCount} guest(s) and ${backup.matchCount} vehicle match(es) from "${backup.label}" (${_formatBackupTimestamp(backup.createdAt)})?\n\nNo conflicting entries were found in your current guest list.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel'),
              ),
              FilledButton.icon(
                onPressed: () => Navigator.pop(ctx, true),
                icon: const Icon(Icons.download_done_rounded, size: 18),
                label: const Text('Load Data'),
              ),
            ],
          ),
        );
        if (confirmed != true || !mounted) {
          return;
        }
      }

      setState(() => _restoringBackupId = backup.id);

      final result = await ApiService.restoreBackup(
        backup.id,
        resolution: resolution,
      );
      final refreshedBackups =
          await ApiService.fetchBackups().catchError((_) => _backups);
      widget.onSaved();
      if (!mounted) return;

      setState(() {
        _backups = refreshedBackups.take(5).toList();
        _backupStatusBanner = result.summary;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(result.summary)),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to load backup: $e')),
      );
    } finally {
      if (mounted) setState(() => _restoringBackupId = null);
    }
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await ApiService.updateSettings(
        geminiApiKey:
            _apiKeyCtrl.text.trim().isNotEmpty ? _apiKeyCtrl.text.trim() : null,
        geminiModel: _model,
        timezone: _timezone,
      );
      widget.onSaved();
      if (!mounted) return;
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Gemini Agent & Schedule settings updated.'),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to save settings: $e')),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _buildBackupTile(
    BuildContext context,
    BackupEntry backup,
    int index,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final isExpanded = _expandedBackupId == backup.id;
    final isRestoring = _restoringBackupId == backup.id;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: isExpanded ? scheme.surfaceContainer : scheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isExpanded ? scheme.primary : scheme.outlineVariant,
          width: isExpanded ? 1.4 : 1.0,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () {
              setState(() {
                _expandedBackupId = isExpanded ? null : backup.id;
              });
            },
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: index == 0
                              ? scheme.primaryContainer
                              : scheme.secondaryContainer,
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          index == 0 ? '#1 Latest' : '#${index + 1}',
                          style: textTheme.labelSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                            color: index == 0
                                ? scheme.onPrimaryContainer
                                : scheme.onSecondaryContainer,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              backup.label,
                              style: textTheme.bodyMedium?.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              '${_formatBackupTimestamp(backup.createdAt)}  •  ${backup.guestCount} Guest${backup.guestCount == 1 ? '' : 's'}  •  ${backup.matchCount} Match${backup.matchCount == 1 ? '' : 'es'}',
                              style: textTheme.bodySmall?.copyWith(
                                color: scheme.onSurfaceVariant,
                              ),
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
                    alignment: WrapAlignment.spaceBetween,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      TextButton.icon(
                        onPressed: () {
                          setState(() {
                            _expandedBackupId = isExpanded ? null : backup.id;
                          });
                        },
                        icon: Icon(
                          isExpanded
                              ? Icons.expand_less_rounded
                              : Icons.visibility_outlined,
                          size: 17,
                        ),
                        label: Text(isExpanded ? 'Hide Details' : 'View Backup'),
                      ),
                      FilledButton.tonalIcon(
                        onPressed: _restoringBackupId != null
                            ? null
                            : () => _handleSelectAndLoadBackup(backup),
                        icon: isRestoring
                            ? const SizedBox(
                                width: 15,
                                height: 15,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.restore_rounded, size: 17),
                        label: Text(
                          isRestoring ? 'Loading...' : 'Load Backup',
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          if (isExpanded) ...[
            Divider(height: 1, color: scheme.outlineVariant),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
              child: backup.guestsPreview.isEmpty
                  ? Text(
                      'This backup contains 0 guest entries.',
                      style: textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Included Guests (${backup.guestsPreview.length}):',
                          style: textTheme.labelMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                            color: scheme.primary,
                          ),
                        ),
                        const SizedBox(height: 6),
                        ...backup.guestsPreview.map(
                          (g) => Padding(
                            padding: const EdgeInsets.only(bottom: 6),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Icon(
                                  Icons.person_outline_rounded,
                                  size: 16,
                                  color: scheme.onSurfaceVariant,
                                ),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: Text(
                                    '${g.name} — ${g.targetSummary.isNotEmpty ? g.targetSummary : 'Vehicle Requirements'} (${g.matchCount} match${g.matchCount == 1 ? '' : 'es'}${g.noteCount > 0 ? ', ${g.noteCount} note${g.noteCount == 1 ? '' : 's'}' : ''})',
                                    style: textTheme.bodySmall,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
            ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 620),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: _loading
              ? const SizedBox(
                  height: 180,
                  child: Center(child: CircularProgressIndicator()),
                )
              : SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.settings_suggest_rounded,
                              color: scheme.primary),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              'Settings, Backups & Googlebook Setup',
                              style: textTheme.titleLarge?.copyWith(
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                          IconButton(
                            onPressed: () => Navigator.pop(context),
                            icon: const Icon(Icons.close),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),

                      // Gemini API Key
                      Text(
                        'Gemini Agent Configuration',
                        style: textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: _apiKeyCtrl,
                        obscureText: true,
                        decoration: InputDecoration(
                          labelText: _geminiConfigured
                              ? 'Replace Gemini API Key (Active: $_maskedKey)'
                              : 'Enter Gemini API Key',
                          hintText: 'AIzaSy...',
                          prefixIcon: const Icon(Icons.key_outlined),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: DropdownButtonFormField<String>(
                              isExpanded: true,
                              initialValue: _model,
                              decoration: const InputDecoration(
                                labelText: 'Gemini Model',
                              ),
                              items: _models
                                  .map(
                                    (m) => DropdownMenuItem(
                                      value: m,
                                      child: Text(
                                        m,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  )
                                  .toList(),
                              onChanged: (v) {
                                if (v != null) setState(() => _model = v);
                              },
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: DropdownButtonFormField<String>(
                              isExpanded: true,
                              initialValue: _timezone,
                              decoration: const InputDecoration(
                                labelText: '7:30a & 2:00p Timezone',
                              ),
                              items: _timezones
                                  .map(
                                    (tz) => DropdownMenuItem(
                                      value: tz,
                                      child: Text(
                                        tz,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  )
                                  .toList(),
                              onChanged: (v) {
                                if (v != null) setState(() => _timezone = v);
                              },
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 20),

                      // Last 5 Backups Section
                      Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: scheme.surfaceContainerLow,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: scheme.outlineVariant),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              alignment: WrapAlignment.spaceBetween,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      Icons.settings_backup_restore_rounded,
                                      color: scheme.primary,
                                      size: 20,
                                    ),
                                    const SizedBox(width: 8),
                                    Text(
                                      'Last 5 Backups',
                                      style: textTheme.titleSmall?.copyWith(
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 8,
                                        vertical: 2,
                                      ),
                                      decoration: BoxDecoration(
                                        color: scheme.secondaryContainer,
                                        borderRadius:
                                            BorderRadius.circular(999),
                                      ),
                                      child: Text(
                                        '${_backups.length}/5',
                                        style: textTheme.labelSmall?.copyWith(
                                          fontWeight: FontWeight.w700,
                                          color: scheme.onSecondaryContainer,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                OutlinedButton.icon(
                                  onPressed: _creatingBackup
                                      ? null
                                      : _handleCreateManualBackup,
                                  icon: _creatingBackup
                                      ? const SizedBox(
                                          width: 15,
                                          height: 15,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                          ),
                                        )
                                      : const Icon(
                                          Icons.backup_outlined,
                                          size: 17,
                                        ),
                                  label: Text(
                                    _creatingBackup
                                        ? 'Saving...'
                                        : 'Back Up Now',
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            Text(
                              'View and select any of the last 5 backups to restore guest & match data. If conflicting entries exist, you can choose to overwrite or duplicate them.',
                              style: textTheme.bodySmall?.copyWith(
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                            if (_backupStatusBanner != null) ...[
                              const SizedBox(height: 10),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 8,
                                ),
                                decoration: BoxDecoration(
                                  color: scheme.primaryContainer,
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Row(
                                  children: [
                                    Icon(
                                      Icons.check_circle_outline_rounded,
                                      size: 18,
                                      color: scheme.onPrimaryContainer,
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        _backupStatusBanner!,
                                        style: textTheme.bodySmall?.copyWith(
                                          color: scheme.onPrimaryContainer,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                            const SizedBox(height: 12),
                            if (_backups.isEmpty)
                              Padding(
                                padding:
                                    const EdgeInsets.symmetric(vertical: 8),
                                child: Text(
                                  'No backups saved yet. Tap "Back Up Now" or add a guest to create your first backup.',
                                  style: textTheme.bodySmall?.copyWith(
                                    color: scheme.onSurfaceVariant,
                                  ),
                                ),
                              )
                            else
                              ...List.generate(
                                _backups.length,
                                (idx) => _buildBackupTile(
                                  context,
                                  _backups[idx],
                                  idx,
                                ),
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),

                      // Googlebook Startup & Launcher Widget Status Card
                      Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: scheme.surfaceContainerLow,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: scheme.outlineVariant),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Icon(
                                  Icons.laptop_chromebook,
                                  color: scheme.primary,
                                  size: 20,
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    'Googlebook (Chromebook) Startup & Widget',
                                    style: textTheme.titleSmall?.copyWith(
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            Text(
                              '• Android Subsystem (ARCVM): Includes native BootCompletedReceiver (RECEIVE_BOOT_COMPLETED) to auto-start on boot + PrestonGuestWidgetProvider AppWidget showing the last 10 guests.\n'
                              '• ChromeOS Browser / PWA: Load chromeos_extension/ at chrome://extensions to auto-launch at Chromebook login (chrome.runtime.onStartup) and pin the Last-10-Guests Launcher Widget to the shelf/toolbar.\n'
                              '• Twice-Daily Schedule: Runs automatically at 7:30 AM and 2:00 PM daily with wake-up catch-up if the Googlebook lid was closed.',
                              style: textTheme.bodySmall?.copyWith(
                                color: scheme.onSurfaceVariant,
                                height: 1.45,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 20),

                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          TextButton(
                            onPressed: () => Navigator.pop(context),
                            child: const Text('Close'),
                          ),
                          const SizedBox(width: 8),
                          FilledButton.icon(
                            onPressed: _saving ? null : _save,
                            icon: const Icon(Icons.save_outlined),
                            label: Text(
                              _saving ? 'Saving...' : 'Save Settings',
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
        ),
      ),
    );
  }
}

class BackupConflictResolutionDialog extends StatelessWidget {
  final BackupConflictPreview preview;

  const BackupConflictResolutionDialog({
    super.key,
    required this.preview,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final conflicts = preview.conflictingGuestNames;
    final nonConflicts = preview.nonConflictingGuestNames;

    return AlertDialog(
      icon: Icon(Icons.warning_amber_rounded, color: scheme.primary, size: 30),
      title: const Text('Conflicting Data Detected'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${conflicts.length} guest entr${conflicts.length == 1 ? 'y' : 'ies'} in "${preview.backup.label}" already exist in your current guest list:',
                style: textTheme.bodyMedium,
              ),
              const SizedBox(height: 10),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ...conflicts.map(
                      (name) => Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Row(
                          children: [
                            Icon(
                              Icons.merge_type_rounded,
                              size: 16,
                              color: scheme.primary,
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                preview.modifiedConflictNames.contains(name)
                                    ? '$name (differs from current entry)'
                                    : name,
                                style: textTheme.bodySmall?.copyWith(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    if (nonConflicts.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(
                        '+ ${nonConflicts.length} non-conflicting guest(s) (${nonConflicts.join(', ')}) will also be restored.',
                        style: textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 14),
              Text(
                'How would you like to handle conflicting entries?',
                style: textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                '• Overwrite Entries: Replaces matching guests, target vehicles, notes, and matches with this backup.\n'
                '• Duplicate Entries: Keeps your existing guests and imports conflicting backup guests as separate "(Copy)" entries.',
                style: textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                  height: 1.4,
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, null),
          child: const Text('Cancel'),
        ),
        OutlinedButton.icon(
          onPressed: () => Navigator.pop(
            context,
            BackupConflictResolution.duplicate,
          ),
          icon: const Icon(Icons.copy_all_rounded, size: 18),
          label: const Text('Duplicate Entries'),
        ),
        FilledButton.icon(
          onPressed: () => Navigator.pop(
            context,
            BackupConflictResolution.overwrite,
          ),
          icon: const Icon(Icons.published_with_changes_rounded, size: 18),
          label: const Text('Overwrite Entries'),
        ),
      ],
    );
  }
}

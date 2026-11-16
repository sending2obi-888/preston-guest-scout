import 'package:material_ui/material_ui.dart';
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
      final s = await ApiService.fetchSettings();
      if (!mounted) return;
      setState(() {
        _geminiConfigured = s['geminiConfigured'] == true;
        _maskedKey = s['geminiKeyMasked']?.toString() ?? '';
        final loadedModel = s['geminiModel']?.toString() ?? 'gemini-2.5-flash';
        _model = _models.contains(loadedModel) ? loadedModel : _models.first;
        final loadedTz = s['timezone']?.toString() ?? 'America/New_York';
        _timezone =
            _timezones.contains(loadedTz) ? loadedTz : _timezones.first;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
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
            content: Text('Gemini Agent & Schedule settings updated.')),
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

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 580),
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
                          Icon(Icons.auto_awesome, color: scheme.primary),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              'Gemini Agent & Googlebook Setup',
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
                              initialValue: _model,
                              decoration: const InputDecoration(
                                labelText: 'Gemini Model',
                              ),
                              items: _models
                                  .map((m) => DropdownMenuItem(
                                      value: m, child: Text(m)))
                                  .toList(),
                              onChanged: (v) {
                                if (v != null) setState(() => _model = v);
                              },
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: DropdownButtonFormField<String>(
                              initialValue: _timezone,
                              decoration: const InputDecoration(
                                labelText: '7:30a & 2:00p Timezone',
                              ),
                              items: _timezones
                                  .map((tz) => DropdownMenuItem(
                                      value: tz, child: Text(tz)))
                                  .toList(),
                              onChanged: (v) {
                                if (v != null) setState(() => _timezone = v);
                              },
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 20),

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
                                Icon(Icons.laptop_chromebook,
                                    color: scheme.primary, size: 20),
                                const SizedBox(width: 8),
                                Text(
                                  'Googlebook (Chromebook) Startup & Widget',
                                  style: textTheme.titleSmall?.copyWith(
                                    fontWeight: FontWeight.w700,
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
                            child: const Text('Cancel'),
                          ),
                          const SizedBox(width: 8),
                          FilledButton.icon(
                            onPressed: _saving ? null : _save,
                            icon: const Icon(Icons.save_outlined),
                            label: Text(_saving ? 'Saving...' : 'Save Settings'),
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

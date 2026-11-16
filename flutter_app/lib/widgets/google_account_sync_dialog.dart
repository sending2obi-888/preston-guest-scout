import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/google_drive_sync_service.dart';

class GoogleAccountSyncDialog extends StatefulWidget {
  final VoidCallback onSynced;

  const GoogleAccountSyncDialog({
    super.key,
    required this.onSynced,
  });

  @override
  State<GoogleAccountSyncDialog> createState() =>
      _GoogleAccountSyncDialogState();
}

class _GoogleAccountSyncDialogState extends State<GoogleAccountSyncDialog> {
  final GoogleDriveSyncService _sync = GoogleDriveSyncService.instance;
  late final TextEditingController _clientIdCtrl;
  late final TextEditingController _clientSecretCtrl;
  late final TextEditingController _syncServerCtrl;
  bool _savingConfig = false;

  @override
  void initState() {
    super.initState();
    _clientIdCtrl = TextEditingController(text: _sync.customOAuthClientId);
    _clientSecretCtrl =
        TextEditingController(text: _sync.customOAuthClientSecret);
    _syncServerCtrl = TextEditingController(text: _sync.syncServerUrl);
  }

  @override
  void dispose() {
    _clientIdCtrl.dispose();
    _clientSecretCtrl.dispose();
    _syncServerCtrl.dispose();
    super.dispose();
  }

  String _formatStamp(DateTime? dt) {
    if (dt == null) return 'Pending first sync';
    return DateFormat('MMM d, yyyy • h:mm:ss a').format(dt.toLocal());
  }

  String _authMethodLabel(String method) {
    switch (method) {
      case 'native_google_sso':
        return 'Android / Googlebook OS SSO';
      case 'oauth_pkce':
        return 'Google OAuth 2.0 SSO';
      case 'web_gis_sso':
        return 'Google Identity Services SSO';
      case 'connected_drive':
        return 'Connected Google Drive Account';
      case 'server_drive_relay':
        return 'Connected Sync Server Drive';
      default:
        return 'Google Single Sign-On';
    }
  }

  Future<void> _syncInputsBeforeAuth() async {
    if (_clientIdCtrl.text.trim() != _sync.customOAuthClientId ||
        _clientSecretCtrl.text.trim() != _sync.customOAuthClientSecret ||
        _syncServerCtrl.text.trim() != _sync.syncServerUrl) {
      await _sync.saveOAuthClientConfig(
        clientId: _clientIdCtrl.text.trim(),
        clientSecret: _clientSecretCtrl.text.trim(),
        syncServerUrl: _syncServerCtrl.text.trim(),
      );
    }
  }

  Future<void> _handleSignIn({
    bool preferPkce = false,
    bool preferDeviceFlow = false,
    bool useConnectedWebDrive = false,
  }) async {
    await _syncInputsBeforeAuth();
    final ok = await _sync.signInWithGoogle(
      preferBrowserPkce: preferPkce,
      preferDeviceFlow: preferDeviceFlow,
      useConnectedWebDrive: useConnectedWebDrive,
    );
    if (!mounted) return;
    if (ok) {
      widget.onSynced();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Signed in as ${_sync.userEmail.isNotEmpty ? _sync.userEmail : _sync.userDisplayName} — synced with Google Drive!',
          ),
        ),
      );
    }
  }

  Future<void> _handleQueryNow() async {
    final ok = await _sync.queryAndSyncDrive(pushAfterMerge: true);
    if (!mounted) return;
    if (ok) {
      widget.onSynced();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Google Drive queried & synced — all devices are up to date.',
          ),
        ),
      );
    }
  }

  Future<void> _handleSaveOAuthConfig() async {
    setState(() => _savingConfig = true);
    try {
      await _sync.saveOAuthClientConfig(
        clientId: _clientIdCtrl.text.trim(),
        clientSecret: _clientSecretCtrl.text.trim(),
        syncServerUrl: _syncServerCtrl.text.trim(),
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Google SSO & Sync settings saved.')),
      );
    } finally {
      if (mounted) setState(() => _savingConfig = false);
    }
  }

  void _copyValue(String label, String value) {
    Clipboard.setData(ClipboardData(text: value));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$label copied to clipboard.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return ListenableBuilder(
      listenable: _sync,
      builder: (context, _) {
        final signedIn = _sync.isSignedIn;
        final busy = _sync.isSigningIn || _sync.isSyncing;
        final hasDeviceCode = _sync.deviceUserCode.trim().isNotEmpty;

        return Dialog(
          insetPadding:
              const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 620),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: scheme.primaryContainer,
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: Icon(
                            Icons.add_to_drive_rounded,
                            color: scheme.onPrimaryContainer,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Google SSO & Multi-Device Drive Sync',
                                style: textTheme.titleLarge?.copyWith(
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              Text(
                                'Automatic Google Drive save & query on every app open',
                                style: textTheme.bodySmall?.copyWith(
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          onPressed: () => Navigator.pop(context),
                          icon: const Icon(Icons.close),
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),

                    // 1. Account / SSO Section
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: signedIn
                            ? scheme.secondaryContainer.withValues(alpha: 0.45)
                            : scheme.surfaceContainerHighest
                                .withValues(alpha: 0.5),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: signedIn
                              ? scheme.primary.withValues(alpha: 0.35)
                              : scheme.outlineVariant,
                        ),
                      ),
                      child: signedIn
                          ? Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    CircleAvatar(
                                      radius: 22,
                                      backgroundColor: scheme.primary,
                                      foregroundImage:
                                          _sync.userPhotoUrl.isNotEmpty
                                              ? NetworkImage(_sync.userPhotoUrl)
                                              : null,
                                      child: Text(
                                        (_sync.userDisplayName.isNotEmpty
                                                ? _sync.userDisplayName[0]
                                                : 'G')
                                            .toUpperCase(),
                                        style: TextStyle(
                                          color: scheme.onPrimary,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            _sync.userDisplayName,
                                            style: textTheme.titleMedium
                                                ?.copyWith(
                                              fontWeight: FontWeight.w700,
                                            ),
                                          ),
                                          if (_sync.userEmail.isNotEmpty)
                                            Text(
                                              _sync.userEmail,
                                              style:
                                                  textTheme.bodySmall?.copyWith(
                                                color: scheme.onSurfaceVariant,
                                              ),
                                            ),
                                          const SizedBox(height: 4),
                                          Container(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 8,
                                              vertical: 3,
                                            ),
                                            decoration: BoxDecoration(
                                              color: scheme.primaryContainer,
                                              borderRadius:
                                                  BorderRadius.circular(999),
                                            ),
                                            child: Text(
                                              _authMethodLabel(_sync.authMethod),
                                              style: textTheme.labelSmall
                                                  ?.copyWith(
                                                color:
                                                    scheme.onPrimaryContainer,
                                                fontWeight: FontWeight.w600,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    OutlinedButton.icon(
                                      onPressed: busy
                                          ? null
                                          : () async {
                                              await _sync.signOut();
                                            },
                                      icon: const Icon(Icons.logout_rounded,
                                          size: 18),
                                      label: const Text('Sign Out'),
                                    ),
                                  ],
                                ),
                                if (kIsWeb &&
                                    _sync.authMethod == 'connected_drive' &&
                                    _clientIdCtrl.text.trim().isNotEmpty) ...[
                                  const SizedBox(height: 12),
                                  OutlinedButton.icon(
                                    onPressed:
                                        busy ? null : () => _handleSignIn(),
                                    icon: const Icon(
                                        Icons.account_circle_outlined,
                                        size: 18),
                                    label: const Text(
                                        'Sign in with another Google Account (SSO Popup)'),
                                  ),
                                ],
                              ],
                            )
                          : Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Sign in with Google Single Sign-On',
                                  style: textTheme.titleMedium?.copyWith(
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  'Connect your Google account so your guest vehicle searches, multi-vehicle criteria, and daily matches sync automatically across your Googlebook, Android phone, and Web browser.',
                                  style: textTheme.bodySmall?.copyWith(
                                    color: scheme.onSurfaceVariant,
                                  ),
                                ),
                                if (!kIsWeb &&
                                    _sync.pendingSelectedEmail.isNotEmpty) ...[
                                  const SizedBox(height: 8),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 10,
                                      vertical: 6,
                                    ),
                                    decoration: BoxDecoration(
                                      color: scheme.primaryContainer
                                          .withValues(alpha: 0.65),
                                      borderRadius: BorderRadius.circular(10),
                                    ),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(
                                          Icons.account_circle_rounded,
                                          size: 16,
                                          color: scheme.onPrimaryContainer,
                                        ),
                                        const SizedBox(width: 6),
                                        Flexible(
                                          child: Text(
                                            'OS Account Selected: ${_sync.pendingSelectedEmail}',
                                            style:
                                                textTheme.labelMedium?.copyWith(
                                              color: scheme.onPrimaryContainer,
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                                const SizedBox(height: 14),
                                Wrap(
                                  spacing: 10,
                                  runSpacing: 10,
                                  children: [
                                    FilledButton.icon(
                                      onPressed: busy
                                          ? null
                                          : () => _handleSignIn(),
                                      icon: _sync.isSigningIn
                                          ? const SizedBox(
                                              width: 16,
                                              height: 16,
                                              child: CircularProgressIndicator(
                                                strokeWidth: 2,
                                              ),
                                            )
                                          : const Icon(Icons.login_rounded,
                                              size: 18),
                                      label: const Text('Sign in with Google'),
                                    ),
                                    if (!kIsWeb)
                                      FilledButton.tonalIcon(
                                        onPressed: busy
                                            ? null
                                            : () => _handleSignIn(
                                                  preferDeviceFlow: true,
                                                ),
                                        icon: const Icon(
                                            Icons.phonelink_lock_rounded,
                                            size: 18),
                                        label: const Text(
                                            'Googlebook Verification Code SSO'),
                                      ),
                                    if (!kIsWeb)
                                      OutlinedButton.icon(
                                        onPressed: busy
                                            ? null
                                            : () => _handleSignIn(
                                                  preferPkce: true,
                                                ),
                                        icon: const Icon(
                                            Icons.open_in_browser_rounded,
                                            size: 18),
                                        label: const Text(
                                            'Desktop PKCE Sign-In'),
                                      ),
                                    if (kIsWeb && _sync.connectedDriveAvailable)
                                      FilledButton.tonalIcon(
                                        onPressed: busy
                                            ? null
                                            : () => _handleSignIn(
                                                  useConnectedWebDrive: true,
                                                ),
                                        icon: const Icon(
                                            Icons.cloud_done_rounded,
                                            size: 18),
                                        label: const Text(
                                            'Use Connected Google Drive'),
                                      ),
                                  ],
                                ),
                              ],
                            ),
                    ),

                    // Active Googlebook / Device Verification Code Card
                    if (hasDeviceCode) ...[
                      const SizedBox(height: 12),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: scheme.primaryContainer,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: scheme.primary),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Icon(Icons.verified_user_rounded,
                                    color: scheme.onPrimaryContainer),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    'Enter Code at google.com/device (Copied!)',
                                    style: textTheme.titleSmall?.copyWith(
                                      color: scheme.onPrimaryContainer,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            SelectableText(
                              _sync.deviceUserCode,
                              style: textTheme.headlineSmall?.copyWith(
                                fontFamily: 'monospace',
                                fontWeight: FontWeight.w800,
                                letterSpacing: 2,
                                color: scheme.onPrimaryContainer,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                FilledButton.icon(
                                  onPressed: () {
                                    final url =
                                        _sync.deviceVerificationUrl.isNotEmpty
                                            ? _sync.deviceVerificationUrl
                                            : 'https://www.google.com/device';
                                    launchUrl(
                                      Uri.parse(url),
                                      mode: LaunchMode.externalApplication,
                                    );
                                  },
                                  icon: const Icon(Icons.open_in_new_rounded,
                                      size: 16),
                                  label: const Text('Open google.com/device'),
                                ),
                                OutlinedButton.icon(
                                  onPressed: () => _copyValue(
                                      'Verification Code',
                                      _sync.deviceUserCode),
                                  icon:
                                      const Icon(Icons.copy_rounded, size: 16),
                                  label: const Text('Copy Code'),
                                ),
                                TextButton(
                                  onPressed: _sync.cancelActiveSignIn,
                                  child: const Text('Cancel'),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],

                    if (_sync.lastError != null &&
                        _sync.lastError!.trim().isNotEmpty) ...[
                      const SizedBox(height: 12),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: _sync.needsOAuthSetup
                              ? scheme.tertiaryContainer
                              : scheme.errorContainer,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(
                              _sync.needsOAuthSetup
                                  ? Icons.vpn_key_rounded
                                  : Icons.info_outline_rounded,
                              size: 18,
                              color: _sync.needsOAuthSetup
                                  ? scheme.onTertiaryContainer
                                  : scheme.onErrorContainer,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                _sync.lastError!,
                                style: textTheme.bodySmall?.copyWith(
                                  color: _sync.needsOAuthSetup
                                      ? scheme.onTertiaryContainer
                                      : scheme.onErrorContainer,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],

                    const SizedBox(height: 16),

                    // 2. Google Drive Multi-Device Sync Status Card
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: scheme.surfaceContainerLow,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: scheme.outlineVariant),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(Icons.cloud_sync_rounded,
                                  size: 20, color: scheme.primary),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  'Google Drive Multi-Device Storage',
                                  style: textTheme.titleSmall?.copyWith(
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                              if (_sync.isSyncing)
                                const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child:
                                      CircularProgressIndicator(strokeWidth: 2),
                                ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          _SyncMetaRow(
                            label: 'Drive Sync File',
                            value: GoogleDriveSyncService.driveSyncFileName,
                          ),
                          _SyncMetaRow(
                            label: 'Auto-Save Mode',
                            value:
                                'Enabled (saves every new guest, vehicle & search)',
                          ),
                          _SyncMetaRow(
                            label: 'Auto-Query Mode',
                            value:
                                'Enabled (queries Google Drive every time app opens)',
                          ),
                          _SyncMetaRow(
                            label: 'Last Queried',
                            value: _formatStamp(_sync.lastQueriedAt),
                          ),
                          _SyncMetaRow(
                            label: 'Last Auto-Saved',
                            value: _formatStamp(_sync.lastSavedAt),
                          ),
                          const SizedBox(height: 12),
                          SizedBox(
                            width: double.infinity,
                            child: FilledButton.tonalIcon(
                              onPressed: (!signedIn || busy)
                                  ? null
                                  : _handleQueryNow,
                              icon: const Icon(Icons.sync_rounded, size: 18),
                              label: Text(
                                _sync.isSyncing
                                    ? 'Querying & Syncing Google Drive...'
                                    : 'Query & Sync Google Drive Now',
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 12),

                    // 3. One-Time Google Cloud OAuth / Sync Setup Helper
                    ExpansionTile(
                      key: ValueKey<bool>(_sync.needsOAuthSetup),
                      initiallyExpanded: _sync.needsOAuthSetup,
                      tilePadding: const EdgeInsets.symmetric(horizontal: 4),
                      title: Text(
                        '1-Time Google Cloud OAuth Setup (Multi-Device APK)',
                        style: textTheme.labelLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      subtitle: Text(
                        kIsWeb
                            ? 'Configure a Web OAuth Client ID for browser Google SSO popup'
                            : 'Register Android Package & SHA-1 for 1-tap OS SSO, or paste a TV/Desktop Client ID',
                        style: textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(top: 8, bottom: 8),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (!kIsWeb) ...[
                                Container(
                                  width: double.infinity,
                                  padding: const EdgeInsets.all(12),
                                  decoration: BoxDecoration(
                                    color: scheme.surfaceContainerHighest
                                        .withValues(alpha: 0.45),
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: Text(
                                    'Option A (Recommended — 1-Tap Native OS SSO on Googlebook & Phone):\n'
                                    '1. In console.cloud.google.com, enable the "Google Drive API".\n'
                                    '2. Go to Credentials → Create Credentials → OAuth client ID → Android.\n'
                                    '3. Copy the Package Name & SHA-1 below, click Create, then tap "Sign in with Google" above!',
                                    style: textTheme.bodySmall?.copyWith(
                                      height: 1.4,
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 8),
                                _CopyableFieldTile(
                                  label: 'Android Package Name',
                                  value: _sync.signingPackageName,
                                  onCopy: () => _copyValue(
                                    'Package Name',
                                    _sync.signingPackageName,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                _CopyableFieldTile(
                                  label: 'APK Signing Certificate SHA-1',
                                  value: _sync.signingSha1,
                                  onCopy: () => _copyValue(
                                    'Signing SHA-1',
                                    _sync.signingSha1,
                                  ),
                                ),
                                const SizedBox(height: 14),
                                Text(
                                  'Option B — Paste a "TVs and Limited Input devices" (best for Googlebook!) or "Desktop app" OAuth Client ID:',
                                  style: textTheme.labelMedium?.copyWith(
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const SizedBox(height: 8),
                              ],
                              TextField(
                                controller: _clientIdCtrl,
                                decoration: InputDecoration(
                                  labelText: kIsWeb
                                      ? 'Web Google OAuth Client ID (.apps.googleusercontent.com)'
                                      : 'Google OAuth Client ID (TV/Device or Desktop .apps.googleusercontent.com)',
                                  hintText:
                                      '1234567890-abcdef.apps.googleusercontent.com',
                                  border: const OutlineInputBorder(),
                                  isDense: true,
                                ),
                              ),
                              if (!kIsWeb) ...[
                                const SizedBox(height: 10),
                                TextField(
                                  controller: _clientSecretCtrl,
                                  obscureText: true,
                                  decoration: const InputDecoration(
                                    labelText:
                                        'OAuth Client Secret (for TV/Device or Desktop client)',
                                    border: OutlineInputBorder(),
                                    isDense: true,
                                  ),
                                ),
                                const SizedBox(height: 10),
                                TextField(
                                  controller: _syncServerCtrl,
                                  decoration: const InputDecoration(
                                    labelText:
                                        'Optional Preston Sync Server URL (Zero-OAuth Relay)',
                                    hintText: 'https://your-preston-server.example.com',
                                    border: OutlineInputBorder(),
                                    isDense: true,
                                  ),
                                ),
                              ],
                              const SizedBox(height: 10),
                              Align(
                                alignment: Alignment.centerRight,
                                child: OutlinedButton.icon(
                                  onPressed: _savingConfig
                                      ? null
                                      : _handleSaveOAuthConfig,
                                  icon: const Icon(Icons.save_outlined,
                                      size: 18),
                                  label: const Text('Save SSO Settings'),
                                ),
                              ),
                            ],
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
      },
    );
  }
}

class _SyncMetaRow extends StatelessWidget {
  final String label;
  final String value;

  const _SyncMetaRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 125,
            child: Text(
              label,
              style: textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: textTheme.bodySmall?.copyWith(
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CopyableFieldTile extends StatelessWidget {
  final String label;
  final String value;
  final VoidCallback onCopy;

  const _CopyableFieldTile({
    required this.label,
    required this.value,
    required this.onCopy,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                SelectableText(
                  value,
                  style: textTheme.bodySmall?.copyWith(
                    fontFamily: 'monospace',
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Copy $label',
            onPressed: onCopy,
            icon: const Icon(Icons.copy_rounded, size: 18),
          ),
        ],
      ),
    );
  }
}

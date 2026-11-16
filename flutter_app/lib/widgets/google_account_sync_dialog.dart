import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';
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
  bool _savingConfig = false;

  @override
  void initState() {
    super.initState();
    _clientIdCtrl = TextEditingController(text: _sync.customOAuthClientId);
    _clientSecretCtrl =
        TextEditingController(text: _sync.customOAuthClientSecret);
  }

  @override
  void dispose() {
    _clientIdCtrl.dispose();
    _clientSecretCtrl.dispose();
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
        return 'Google OAuth 2.0 PKCE SSO';
      case 'web_gis_sso':
        return 'Google Identity Services SSO';
      case 'connected_drive':
        return 'Connected Google Drive Account';
      default:
        return 'Google Single Sign-On';
    }
  }

  Future<void> _handleSignIn({bool preferPkce = false}) async {
    if (_clientIdCtrl.text.trim() != _sync.customOAuthClientId ||
        _clientSecretCtrl.text.trim() != _sync.customOAuthClientSecret) {
      await _sync.saveOAuthClientConfig(
        clientId: _clientIdCtrl.text.trim(),
        clientSecret: _clientSecretCtrl.text.trim(),
      );
    }
    final ok = await _sync.signInWithGoogle(preferBrowserPkce: preferPkce);
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
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Google OAuth Client settings saved.')),
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

        return Dialog(
          insetPadding:
              const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 600),
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
                                  'Connect your Google account so your guest vehicle searches, daily matches, and requirements sync automatically across your Googlebook, Android phone, and Web browser.',
                                  style: textTheme.bodySmall?.copyWith(
                                    color: scheme.onSurfaceVariant,
                                  ),
                                ),
                                const SizedBox(height: 14),
                                Wrap(
                                  spacing: 10,
                                  runSpacing: 10,
                                  children: [
                                    FilledButton.icon(
                                      onPressed: busy
                                          ? null
                                          : () => _handleSignIn(
                                                preferPkce: false,
                                              ),
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
                                                  preferPkce: true,
                                                ),
                                        icon: const Icon(
                                            Icons.open_in_browser_rounded,
                                            size: 18),
                                        label: const Text(
                                            'Browser OAuth PKCE Sign-In'),
                                      ),
                                  ],
                                ),
                              ],
                            ),
                    ),

                    if (_sync.lastError != null &&
                        _sync.lastError!.trim().isNotEmpty) ...[
                      const SizedBox(height: 12),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: scheme.errorContainer,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(
                              Icons.info_outline_rounded,
                              size: 18,
                              color: scheme.onErrorContainer,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                _sync.lastError!,
                                style: textTheme.bodySmall?.copyWith(
                                  color: scheme.onErrorContainer,
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
                                'Enabled (saves every new guest, delete & search)',
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

                    // 3. Multi-Device OAuth Configuration Helper
                    ExpansionTile(
                      tilePadding: const EdgeInsets.symmetric(horizontal: 4),
                      title: Text(
                        'Google Cloud OAuth Client Setup (Optional / Multi-Device)',
                        style: textTheme.labelLarge?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      subtitle: Text(
                        kIsWeb
                            ? 'Configure a Web OAuth Client ID for browser Google SSO popup'
                            : '1-tap copy Package Name & SHA-1, or paste a Desktop OAuth Client ID',
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
                                const SizedBox(height: 12),
                              ],
                              TextField(
                                controller: _clientIdCtrl,
                                decoration: InputDecoration(
                                  labelText: kIsWeb
                                      ? 'Web Google OAuth Client ID (.apps.googleusercontent.com)'
                                      : 'Google OAuth Client ID (Desktop or Web .apps.googleusercontent.com)',
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
                                        'Desktop OAuth Client Secret (only if required by client)',
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
                                  label: const Text('Save OAuth Client Config'),
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

import 'package:material_ui/material_ui.dart';
import '../models/models.dart';
import '../services/api_service.dart';

class EditClientContactDialog extends StatefulWidget {
  final GuestProfile guest;

  const EditClientContactDialog({
    super.key,
    required this.guest,
  });

  @override
  State<EditClientContactDialog> createState() =>
      _EditClientContactDialogState();
}

class _EditClientContactDialogState extends State<EditClientContactDialog> {
  late final TextEditingController _nameCtrl;
  late final TextEditingController _phoneCtrl;
  late final TextEditingController _emailCtrl;
  bool _submitting = false;
  String? _errorText;

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController(text: widget.guest.name);
    _phoneCtrl = TextEditingController(text: widget.guest.phone);
    _emailCtrl = TextEditingController(text: widget.guest.email);
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _phoneCtrl.dispose();
    _emailCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_submitting) return;
    final cleanName = _nameCtrl.text.trim();
    final cleanPhone = _phoneCtrl.text.trim();
    final cleanEmail = _emailCtrl.text.trim();

    if (cleanName.isEmpty) {
      setState(() {
        _errorText = 'Client name is required.';
      });
      return;
    }

    if (cleanEmail.isNotEmpty &&
        !RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(cleanEmail)) {
      setState(() {
        _errorText = 'Please enter a valid email address or leave it blank.';
      });
      return;
    }

    setState(() {
      _submitting = true;
      _errorText = null;
    });

    try {
      final updatedGuest = await ApiService.updateGuestContactInfo(
        guestId: widget.guest.id,
        name: cleanName,
        phone: cleanPhone,
        email: cleanEmail,
      );
      if (!mounted) return;
      Navigator.of(context).pop(updatedGuest);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _errorText = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.fromLTRB(22, 18, 14, 16),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerLow,
                borderRadius:
                    const BorderRadius.vertical(top: Radius.circular(24)),
                border: Border(
                  bottom: BorderSide(color: scheme.outlineVariant),
                ),
              ),
              child: Row(
                children: [
                  CircleAvatar(
                    backgroundColor: scheme.primaryContainer,
                    foregroundColor: scheme.onPrimaryContainer,
                    child: const Icon(Icons.contact_phone_outlined),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Edit Client Contact Info',
                          style: textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        Text(
                          'Update name, phone number, or email address without disturbing saved matches',
                          style: textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'Close',
                    onPressed:
                        _submitting ? null : () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(22, 18, 22, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (_errorText != null) ...[
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: scheme.errorContainer,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          _errorText!,
                          style: textTheme.bodySmall?.copyWith(
                            color: scheme.onErrorContainer,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      const SizedBox(height: 14),
                    ],
                    TextField(
                      key: const ValueKey('dialog_contact_name_input'),
                      controller: _nameCtrl,
                      textCapitalization: TextCapitalization.words,
                      textInputAction: TextInputAction.next,
                      onChanged: (_) => setState(() {}),
                      decoration: const InputDecoration(
                        labelText: 'Client Name *',
                        hintText: 'e.g. Jordan Taylor',
                        prefixIcon: Icon(Icons.person_outline),
                      ),
                    ),
                    const SizedBox(height: 14),
                    TextField(
                      key: const ValueKey('dialog_contact_phone_input'),
                      controller: _phoneCtrl,
                      keyboardType: TextInputType.phone,
                      textInputAction: TextInputAction.next,
                      onChanged: (_) => setState(() {}),
                      decoration: InputDecoration(
                        labelText: 'Phone Number',
                        hintText: 'e.g. (410) 555-0192',
                        prefixIcon: const Icon(Icons.phone_outlined),
                        suffixIcon: _phoneCtrl.text.isNotEmpty
                            ? IconButton(
                                tooltip: 'Clear phone number',
                                onPressed: () =>
                                    setState(() => _phoneCtrl.clear()),
                                icon: const Icon(Icons.clear, size: 18),
                              )
                            : null,
                      ),
                    ),
                    const SizedBox(height: 14),
                    TextField(
                      key: const ValueKey('dialog_contact_email_input'),
                      controller: _emailCtrl,
                      keyboardType: TextInputType.emailAddress,
                      textInputAction: TextInputAction.done,
                      onChanged: (_) => setState(() {}),
                      onSubmitted: (_) => _submit(),
                      decoration: InputDecoration(
                        labelText: 'Email Address',
                        hintText: 'e.g. client@example.com',
                        prefixIcon: const Icon(Icons.email_outlined),
                        suffixIcon: _emailCtrl.text.isNotEmpty
                            ? IconButton(
                                tooltip: 'Clear email address',
                                onPressed: () =>
                                    setState(() => _emailCtrl.clear()),
                                icon: const Icon(Icons.clear, size: 18),
                              )
                            : null,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Container(
              padding: const EdgeInsets.fromLTRB(22, 12, 22, 16),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerLow,
                borderRadius:
                    const BorderRadius.vertical(bottom: Radius.circular(24)),
                border: Border(
                  top: BorderSide(color: scheme.outlineVariant),
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed:
                        _submitting ? null : () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 10),
                  FilledButton.icon(
                    key: const ValueKey('dialog_save_contact_button'),
                    onPressed: _submitting ? null : _submit,
                    icon: _submitting
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.check_rounded, size: 18),
                    label: Text(
                      _submitting ? 'Saving...' : 'Save Contact Info',
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
}

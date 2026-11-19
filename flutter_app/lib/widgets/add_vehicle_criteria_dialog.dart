import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import '../models/models.dart';
import '../services/api_service.dart';
import '../services/natural_language_parser.dart';

class AddVehicleCriteriaDialog extends StatefulWidget {
  final GuestProfile guest;

  const AddVehicleCriteriaDialog({
    super.key,
    required this.guest,
  });

  @override
  State<AddVehicleCriteriaDialog> createState() =>
      _AddVehicleCriteriaDialogState();
}

class _AddVehicleCriteriaDialogState extends State<AddVehicleCriteriaDialog> {
  final _minYearCtrl = TextEditingController();
  final _maxYearCtrl = TextEditingController();
  final _makeCtrl = TextEditingController();
  final _modelCtrl = TextEditingController();
  final _trimCtrl = TextEditingController();
  final _maxPriceCtrl = TextEditingController();
  final _maxMileageCtrl = TextEditingController();
  final _exteriorColorCtrl = TextEditingController();
  final _customFeatureCtrl = TextEditingController();
  final _notesCtrl = TextEditingController();

  String _condition = 'Any';
  String _drivetrain = 'Any';
  final Set<String> _selectedFeatures = {};
  bool _submitting = false;
  String? _errorText;

  static const List<String> _prestonMakes = [
    'Ford',
    'Lincoln',
    'Hyundai',
    'Mazda',
    'Nissan',
    'Chevrolet',
    'Jeep',
    'Ram',
  ];

  static const List<String> _commonFeatures = [
    'Leather Seats',
    'Sunroof/Moonroof',
    'Navigation System',
    'Apple CarPlay',
    'Android Auto',
    'Blind Spot Monitor',
    'Lane Keep Assist',
    'Heated Seats',
    'Remote Start',
    'Tow Hitch',
    '3rd Row Seating',
    'Backup Camera',
    'Power Tailgate/Liftgate',
  ];

  @override
  void dispose() {
    _minYearCtrl.dispose();
    _maxYearCtrl.dispose();
    _makeCtrl.dispose();
    _modelCtrl.dispose();
    _trimCtrl.dispose();
    _maxPriceCtrl.dispose();
    _maxMileageCtrl.dispose();
    _exteriorColorCtrl.dispose();
    _customFeatureCtrl.dispose();
    _notesCtrl.dispose();
    super.dispose();
  }

  void _addCustomFeature() {
    final val = _customFeatureCtrl.text.trim();
    if (val.isEmpty) return;
    setState(() {
      _selectedFeatures.add(val);
      _customFeatureCtrl.clear();
    });
  }

  double? _parseMaxPrice(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;
    final hasK = RegExp(r'[kK]\b').hasMatch(trimmed);
    final numeric = trimmed.replaceAll(RegExp(r'[^0-9.]'), '');
    final parsed = double.tryParse(numeric);
    if (parsed == null || parsed <= 0) return null;
    if (hasK || parsed < 500) {
      return parsed * 1000.0;
    }
    return parsed;
  }

  Future<void> _submit() async {
    final make = _makeCtrl.text.trim();
    final model = _modelCtrl.text.trim();
    final trim = _trimCtrl.text.trim();
    final notes = _notesCtrl.text.trim();
    final minYear = int.tryParse(_minYearCtrl.text.trim());
    final maxYear = int.tryParse(_maxYearCtrl.text.trim());
    final maxPrice = _parseMaxPrice(_maxPriceCtrl.text);
    final maxMileage =
        int.tryParse(_maxMileageCtrl.text.replaceAll(',', '').trim());

    final hasAnyCriteria = make.isNotEmpty ||
        model.isNotEmpty ||
        trim.isNotEmpty ||
        notes.isNotEmpty ||
        maxPrice != null ||
        minYear != null ||
        maxYear != null ||
        _selectedFeatures.isNotEmpty ||
        _condition != 'Any' ||
        _drivetrain != 'Any';

    if (!hasAnyCriteria) {
      setState(() {
        _errorText =
            'Enter a make, model, max budget, or requirement for the additional vehicle.';
      });
      return;
    }

    setState(() {
      _submitting = true;
      _errorText = null;
    });

    try {
      final res = await ApiService.addVehicleToGuest(
        guestId: widget.guest.id,
        condition: _condition,
        minYear: minYear,
        maxYear: maxYear,
        make: make,
        model: model,
        trim: trim,
        maxPrice: maxPrice,
        maxMileage: maxMileage,
        drivetrain: _drivetrain,
        exteriorColor: _exteriorColorCtrl.text.trim(),
        features: _selectedFeatures.toList(),
        notes: notes,
      );
      if (!mounted) return;
      Navigator.of(context).pop(res);
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
    final existingTargets = widget.guest.effectiveTargets;

    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 680, maxHeight: 780),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Dialog Header
            Container(
              padding: const EdgeInsets.fromLTRB(22, 18, 14, 14),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerLow,
                borderRadius:
                    const BorderRadius.vertical(top: Radius.circular(28)),
                border: Border(
                  bottom: BorderSide(color: scheme.outlineVariant),
                ),
              ),
              child: Row(
                children: [
                  CircleAvatar(
                    backgroundColor: scheme.primaryContainer,
                    foregroundColor: scheme.onPrimaryContainer,
                    child: const Icon(Icons.add_road_rounded),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Add Another Vehicle for ${widget.guest.name}',
                          style: textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        Text(
                          'Searches prestonmotor.com immediately & at 7:30 AM and 2:00 PM daily alongside existing criteria',
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

            // Scrollable Form Body
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(22, 16, 22, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Existing Vehicles Context Banner
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: scheme.secondaryContainer.withValues(alpha: 0.45),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: scheme.outlineVariant,
                        ),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(Icons.directions_car_filled_outlined,
                              size: 18, color: scheme.primary),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Currently monitoring (${existingTargets.length}): ${existingTargets.map((t) => t.label).join('  •  ')}',
                              style: textTheme.labelMedium?.copyWith(
                                color: scheme.onSurface,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),

                    if (_errorText != null) ...[
                      const SizedBox(height: 12),
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
                    ],

                    const SizedBox(height: 16),
                    Text(
                      'Condition',
                      style: textTheme.labelLarge
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 8),
                    SegmentedButton<String>(
                      segments: const [
                        ButtonSegment(value: 'Any', label: Text('Any')),
                        ButtonSegment(value: 'New', label: Text('New')),
                        ButtonSegment(
                            value: 'Pre-Owned', label: Text('Pre-Owned')),
                        ButtonSegment(value: 'CPO', label: Text('CPO')),
                      ],
                      selected: {_condition},
                      onSelectionChanged: (s) =>
                          setState(() => _condition = s.first),
                    ),

                    const SizedBox(height: 16),
                    Text(
                      'Quick-Select Preston Automotive Make',
                      style: textTheme.labelLarge
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: _prestonMakes.map((make) {
                        final selected = _makeCtrl.text.trim().toLowerCase() ==
                            make.toLowerCase();
                        return ChoiceChip(
                          label: Text(make),
                          selected: selected,
                          onSelected: (sel) {
                            setState(() {
                              _makeCtrl.text = sel ? make : '';
                            });
                          },
                        );
                      }).toList(),
                    ),

                    const SizedBox(height: 14),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _makeCtrl,
                            onChanged: (_) => setState(() {}),
                            decoration: const InputDecoration(
                              labelText: 'Make (e.g. Lincoln, Ford, Mazda)',
                              prefixIcon: Icon(Icons.directions_car_outlined),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: TextField(
                            controller: _modelCtrl,
                            decoration: const InputDecoration(
                              labelText: 'Model (e.g. Navigator, Explorer)',
                              prefixIcon: Icon(Icons.badge_outlined),
                            ),
                          ),
                        ),
                      ],
                    ),

                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          flex: 2,
                          child: TextField(
                            controller: _trimCtrl,
                            decoration: const InputDecoration(
                              labelText: 'Trim (Optional, e.g. Reserve, XLT)',
                              prefixIcon: Icon(Icons.tune_outlined),
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: TextField(
                            controller: _minYearCtrl,
                            keyboardType: TextInputType.number,
                            inputFormatters: [
                              FilteringTextInputFormatter.digitsOnly
                            ],
                            decoration: const InputDecoration(
                              labelText: 'Min Year',
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: TextField(
                            controller: _maxYearCtrl,
                            keyboardType: TextInputType.number,
                            inputFormatters: [
                              FilteringTextInputFormatter.digitsOnly
                            ],
                            decoration: const InputDecoration(
                              labelText: 'Max Year',
                            ),
                          ),
                        ),
                      ],
                    ),

                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _maxPriceCtrl,
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(
                              labelText: 'Max Price Budget',
                              prefixText: '\$ ',
                              hintText: 'e.g. 65000',
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: TextField(
                            controller: _maxMileageCtrl,
                            keyboardType: TextInputType.number,
                            inputFormatters: [
                              FilteringTextInputFormatter.digitsOnly
                            ],
                            decoration: const InputDecoration(
                              labelText: 'Max Mileage (Optional)',
                              suffixText: 'mi',
                            ),
                          ),
                        ),
                      ],
                    ),

                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: DropdownButtonFormField<String>(
                            initialValue: _drivetrain,
                            decoration: const InputDecoration(
                              labelText: 'Drivetrain',
                              prefixIcon: Icon(Icons.settings_outlined),
                            ),
                            items: const [
                              DropdownMenuItem(
                                  value: 'Any', child: Text('Any Drivetrain')),
                              DropdownMenuItem(
                                  value: '4WD', child: Text('4WD / 4x4')),
                              DropdownMenuItem(
                                  value: 'AWD', child: Text('AWD')),
                              DropdownMenuItem(
                                  value: 'FWD', child: Text('FWD')),
                              DropdownMenuItem(
                                  value: 'RWD', child: Text('RWD')),
                            ],
                            onChanged: (v) {
                              if (v != null) setState(() => _drivetrain = v);
                            },
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: TextField(
                            controller: _exteriorColorCtrl,
                            decoration: const InputDecoration(
                              labelText: 'Exterior Color (Optional)',
                              prefixIcon: Icon(Icons.palette_outlined),
                            ),
                          ),
                        ),
                      ],
                    ),

                    const SizedBox(height: 16),
                    Text(
                      'Must-Have Features for This Vehicle',
                      style: textTheme.labelLarge
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        ..._commonFeatures.map((feat) {
                          final selected = _selectedFeatures.contains(feat);
                          return FilterChip(
                            label: Text(feat),
                            selected: selected,
                            onSelected: (sel) {
                              setState(() {
                                if (sel) {
                                  _selectedFeatures.add(feat);
                                } else {
                                  _selectedFeatures.remove(feat);
                                }
                              });
                            },
                          );
                        }),
                        ..._selectedFeatures
                            .where((f) => !_commonFeatures.contains(f))
                            .map((custom) {
                          return InputChip(
                            label: Text(custom),
                            selected: true,
                            onDeleted: () => setState(
                              () => _selectedFeatures.remove(custom),
                            ),
                          );
                        }),
                      ],
                    ),

                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _customFeatureCtrl,
                            onSubmitted: (_) => _addCustomFeature(),
                            decoration: const InputDecoration(
                              isDense: true,
                              labelText:
                                  'Add custom package or feature (e.g. Max Tow, Captain Chairs)',
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        FilledButton.tonalIcon(
                          onPressed: _addCustomFeature,
                          icon: const Icon(Icons.add, size: 18),
                          label: const Text('Add'),
                        ),
                      ],
                    ),

                    const SizedBox(height: 14),
                    TextField(
                      key: const ValueKey('dialog_natural_language_search_input'),
                      controller: _notesCtrl,
                      maxLines: 2,
                      onChanged: (_) => setState(() {}),
                      decoration: const InputDecoration(
                        labelText:
                            'Natural-Language Search / Additional Criteria (Optional)',
                        hintText:
                            'e.g. Ford F150. 6.5ft bed. XLT. — or describe cab/box, engine, trim, budget...',
                        alignLabelWithHint: true,
                      ),
                    ),
                    if (_notesCtrl.text.trim().isNotEmpty) ...[
                      const SizedBox(height: 10),
                      Builder(
                        builder: (context) {
                          final chips =
                              NaturalLanguageVehicleParser.buildPreviewChips({
                            'condition': _condition,
                            'minYear': int.tryParse(_minYearCtrl.text.trim()),
                            'maxYear': int.tryParse(_maxYearCtrl.text.trim()),
                            'make': _makeCtrl.text.trim(),
                            'model': _modelCtrl.text.trim(),
                            'trim': _trimCtrl.text.trim(),
                            'maxPrice': _parseMaxPrice(_maxPriceCtrl.text),
                            'maxMileage': int.tryParse(
                              _maxMileageCtrl.text.replaceAll(',', '').trim(),
                            ),
                            'drivetrain': _drivetrain,
                            'exteriorColor': _exteriorColorCtrl.text.trim(),
                            'features': _selectedFeatures.toList(),
                            'notes': _notesCtrl.text.trim(),
                          });
                          if (chips.isEmpty) return const SizedBox.shrink();
                          return Container(
                            key: const ValueKey(
                              'dialog_parsed_natural_language_summary',
                            ),
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: scheme.secondaryContainer
                                  .withValues(alpha: 0.45),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: scheme.primary.withValues(alpha: 0.25),
                              ),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Icon(
                                      Icons.verified_outlined,
                                      size: 15,
                                      color: scheme.primary,
                                    ),
                                    const SizedBox(width: 6),
                                    Expanded(
                                      child: Text(
                                        'Understood Search Criteria',
                                        style: textTheme.labelSmall?.copyWith(
                                          fontWeight: FontWeight.w700,
                                          color: scheme.onSecondaryContainer,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 6),
                                Wrap(
                                  spacing: 6,
                                  runSpacing: 6,
                                  children: chips
                                      .map(
                                        (c) => Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 8,
                                            vertical: 3,
                                          ),
                                          decoration: BoxDecoration(
                                            color: scheme.surface,
                                            borderRadius:
                                                BorderRadius.circular(16),
                                            border: Border.all(
                                              color: scheme.outlineVariant,
                                            ),
                                          ),
                                          child: Text(
                                            c,
                                            style:
                                                textTheme.labelSmall?.copyWith(
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                        ),
                                      )
                                      .toList(),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                    ],
                  ],
                ),
              ),
            ),

            // Footer Actions
            Container(
              padding: const EdgeInsets.fromLTRB(22, 12, 22, 16),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerLow,
                borderRadius:
                    const BorderRadius.vertical(bottom: Radius.circular(28)),
                border: Border(
                  top: BorderSide(color: scheme.outlineVariant),
                ),
              ),
              child: Wrap(
                alignment: WrapAlignment.end,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 10,
                runSpacing: 8,
                children: [
                  TextButton(
                    onPressed:
                        _submitting ? null : () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                  FilledButton.icon(
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
                        : const Icon(Icons.auto_awesome),
                    label: Text(
                      _submitting
                          ? 'Searching prestonmotor.com...'
                          : 'Add Vehicle & Search Now',
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

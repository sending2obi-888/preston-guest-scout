import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import '../models/models.dart';
import '../services/api_service.dart';
import '../services/natural_language_parser.dart';
import 'exterior_color_selector.dart';

class AddVehicleCriteriaDialog extends StatefulWidget {
  final GuestProfile guest;
  final VehicleSearchTarget? existingTarget;

  const AddVehicleCriteriaDialog({
    super.key,
    required this.guest,
    this.existingTarget,
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
  String _doors = '';
  String _bedLength = '';
  List<String> _selectedColors = [];
  final Set<String> _selectedFeatures = {};
  bool _submitting = false;
  String? _errorText;

  String _lastNoteSyncedMake = '';
  String _lastNoteSyncedModel = '';
  String _lastNoteSyncedTrim = '';
  String _lastNoteSyncedDoors = '';
  String _lastNoteSyncedBed = '';
  String _lastNoteSyncedMaxPrice = '';
  String _lastNoteSyncedMinYear = '';
  String _lastNoteSyncedMaxYear = '';
  String _lastNoteSyncedCondition = 'Any';
  String _lastNoteSyncedDrivetrain = 'Any';

  bool get _isEditing => widget.existingTarget != null;

  static const List<(String, String)> _doorOptions = [
    ('', 'Any Doors'),
    ('2', '2 Doors'),
    ('3', '3 Doors'),
    ('4', '4 Doors'),
    ('5', '5 Doors'),
  ];

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

  static const List<(String, String)> _bedLengthOptions = [
    ('', 'Any Bed'),
    ('5.5', '5.5 ft Bed'),
    ('6.5', '6.5 ft Bed'),
    ('6.75', '6.75 ft Bed'),
    ('8', '8 ft Bed'),
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
  void initState() {
    super.initState();
    final t = widget.existingTarget;
    if (t != null) {
      const validConditions = {'Any', 'New', 'Pre-Owned', 'CPO'};
      const validDrivetrains = {'Any', '4WD', 'AWD', 'FWD', 'RWD'};
      const validDoors = {'', '2', '3', '4', '5'};
      _condition = validConditions.contains(t.condition) ? t.condition : 'Any';
      _drivetrain =
          validDrivetrains.contains(t.drivetrain) ? t.drivetrain : 'Any';
      final normDoors = NaturalLanguageVehicleParser.normalizeDoorsInput(t.doors);
      _doors = validDoors.contains(normDoors) ? normDoors : '';
      _bedLength = t.bedLength;
      _makeCtrl.text = t.make;
      _modelCtrl.text = t.model;
      _trimCtrl.text = t.trim;
      if (t.minYear != null) _minYearCtrl.text = '${t.minYear}';
      if (t.maxYear != null) _maxYearCtrl.text = '${t.maxYear}';
      if (t.maxPrice != null) {
        _maxPriceCtrl.text = t.maxPrice!.toStringAsFixed(0);
      }
      if (t.maxMileage != null) _maxMileageCtrl.text = '${t.maxMileage}';
      _selectedColors =
          NaturalLanguageVehicleParser.parseExteriorColors(t.exteriorColor);
      _selectedFeatures.addAll(t.features);
      _notesCtrl.text = t.notes;

      if (t.notes.trim().isNotEmpty) {
        final noteParsed = NaturalLanguageVehicleParser.parseCriteriaMap({
          'notes': t.notes,
        });
        _lastNoteSyncedMake = noteParsed['make']?.toString() ?? '';
        _lastNoteSyncedModel = noteParsed['model']?.toString() ?? '';
        _lastNoteSyncedTrim = noteParsed['trim']?.toString() ?? '';
        _lastNoteSyncedDoors = noteParsed['doors']?.toString() ?? '';
        _lastNoteSyncedBed = noteParsed['bedLength']?.toString() ?? '';
        final pMax = (noteParsed['maxPrice'] as num?)?.toDouble();
        _lastNoteSyncedMaxPrice = pMax != null ? pMax.toStringAsFixed(0) : '';
        final pMinYr = (noteParsed['minYear'] as num?)?.toInt();
        _lastNoteSyncedMinYear = pMinYr != null ? '$pMinYr' : '';
        final pMaxYr = (noteParsed['maxYear'] as num?)?.toInt();
        _lastNoteSyncedMaxYear = pMaxYr != null ? '$pMaxYr' : '';
        _lastNoteSyncedCondition =
            noteParsed['condition']?.toString() ?? 'Any';
        _lastNoteSyncedDrivetrain =
            noteParsed['drivetrain']?.toString() ?? 'Any';
      }
    }
  }

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

  void _handleNotesChanged(String val) {
    if (_isEditing) {
      final noteParsed = NaturalLanguageVehicleParser.parseCriteriaMap({
        'notes': val,
      });
      final newMake = noteParsed['make']?.toString() ?? '';
      final newModel = noteParsed['model']?.toString() ?? '';
      final newTrim = noteParsed['trim']?.toString() ?? '';
      final newDoors = noteParsed['doors']?.toString() ?? '';
      final newBed = noteParsed['bedLength']?.toString() ?? '';
      final pMax = (noteParsed['maxPrice'] as num?)?.toDouble();
      final newMaxPrice = pMax != null ? pMax.toStringAsFixed(0) : '';
      final pMinYr = (noteParsed['minYear'] as num?)?.toInt();
      final newMinYr = pMinYr != null ? '$pMinYr' : '';
      final pMaxYr = (noteParsed['maxYear'] as num?)?.toInt();
      final newMaxYr = pMaxYr != null ? '$pMaxYr' : '';
      final newCond = noteParsed['condition']?.toString() ?? 'Any';
      final newDt = noteParsed['drivetrain']?.toString() ?? 'Any';

      if (_makeCtrl.text.trim() == _lastNoteSyncedMake && newMake.isNotEmpty) {
        _makeCtrl.text = newMake;
        _lastNoteSyncedMake = newMake;
      }
      if (_modelCtrl.text.trim() == _lastNoteSyncedModel &&
          newModel.isNotEmpty) {
        _modelCtrl.text = newModel;
        _lastNoteSyncedModel = newModel;
      }
      if (_trimCtrl.text.trim() == _lastNoteSyncedTrim &&
          newTrim != _lastNoteSyncedTrim) {
        _trimCtrl.text = newTrim;
        _lastNoteSyncedTrim = newTrim;
      }
      if (_doors == _lastNoteSyncedDoors && newDoors != _lastNoteSyncedDoors) {
        _doors = newDoors;
        _lastNoteSyncedDoors = newDoors;
      }
      if (_bedLength == _lastNoteSyncedBed && newBed != _lastNoteSyncedBed) {
        _bedLength = newBed;
        _lastNoteSyncedBed = newBed;
      }
      if (_maxPriceCtrl.text.trim() == _lastNoteSyncedMaxPrice &&
          newMaxPrice != _lastNoteSyncedMaxPrice) {
        _maxPriceCtrl.text = newMaxPrice;
        _lastNoteSyncedMaxPrice = newMaxPrice;
      }
      if (_minYearCtrl.text.trim() == _lastNoteSyncedMinYear &&
          newMinYr != _lastNoteSyncedMinYear) {
        _minYearCtrl.text = newMinYr;
        _lastNoteSyncedMinYear = newMinYr;
      }
      if (_maxYearCtrl.text.trim() == _lastNoteSyncedMaxYear &&
          newMaxYr != _lastNoteSyncedMaxYear) {
        _maxYearCtrl.text = newMaxYr;
        _lastNoteSyncedMaxYear = newMaxYr;
      }
      if (_condition == _lastNoteSyncedCondition &&
          newCond != _lastNoteSyncedCondition) {
        _condition = newCond;
        _lastNoteSyncedCondition = newCond;
      }
      if (_drivetrain == _lastNoteSyncedDrivetrain &&
          newDt != _lastNoteSyncedDrivetrain) {
        _drivetrain = newDt;
        _lastNoteSyncedDrivetrain = newDt;
      }
    }
    setState(() {});
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
    var notes = _notesCtrl.text.trim();
    final minYear = int.tryParse(_minYearCtrl.text.trim());
    final maxYear = int.tryParse(_maxYearCtrl.text.trim());
    final maxPrice = _parseMaxPrice(_maxPriceCtrl.text);
    final maxMileage =
        int.tryParse(_maxMileageCtrl.text.replaceAll(',', '').trim());

    final combinedColors = ExteriorColorSelector.combineSelectedAndTyped(
      _selectedColors,
      _exteriorColorCtrl.text,
    );

    // When editing an existing target, if the user explicitly cleared any structured field,
    // strip the old token from raw notes so natural-language parsing doesn't re-apply it.
    if (_isEditing && notes.isNotEmpty) {
      final prev = widget.existingTarget!;
      if (model.isEmpty && prev.model.isNotEmpty) {
        final escapedModel = RegExp.escape(prev.model)
            .replaceAll(RegExp(r'[\s\\-]+'), r'[\s+-]*');
        notes = notes
            .replaceAll(
              RegExp('\\b$escapedModel\\b[.,;]*', caseSensitive: false),
              ' ',
            )
            .replaceAll(RegExp(r'\s+'), ' ')
            .trim();
      }
      if (trim.isEmpty && prev.trim.isNotEmpty) {
        notes = notes
            .replaceAll(
              RegExp('\\b${RegExp.escape(prev.trim)}\\b[.,;]*',
                  caseSensitive: false),
              ' ',
            )
            .replaceAll(RegExp(r'\s+'), ' ')
            .trim();
      }
      if (_doors.isEmpty && prev.doors.isNotEmpty) {
        notes = notes
            .replaceAll(
              RegExp(
                r'\b(?:[2345]|two|three|four|five)[-\s]*(?:doors?|dr\.?)[.,;]*',
                caseSensitive: false,
              ),
              ' ',
            )
            .replaceAll(RegExp(r'\s+'), ' ')
            .trim();
      }
      if (_bedLength.isEmpty && prev.bedLength.isNotEmpty) {
        notes = notes
            .replaceAll(
              RegExp(
                r'\b(?:5\.5|5\s*1/2|6\.5|6\s*1/2|6\.75|6\s*3/4|8(?:\.0)?)\s*(?:ft|foot|feet|\x27)\s*(?:bed|box)?[.,;]*',
                caseSensitive: false,
              ),
              ' ',
            )
            .replaceAll(RegExp(r'\s+'), ' ')
            .trim();
      }
      if (maxPrice == null && prev.maxPrice != null) {
        notes = notes
            .replaceAll(
              RegExp(
                r'(?:under|below|max|up\s+to|less\s+than|around|budget(?:\s+of)?|<=?)\s*\$?\s*\d+(?:,\d{3})*(?:\.\d+)?\s*(?:k|thousand)?\b[.,;]*|\$\s*\d+(?:,\d{3})*(?:\.\d+)?\s*(?:k|thousand)?\b[.,;]*',
                caseSensitive: false,
              ),
              ' ',
            )
            .replaceAll(RegExp(r'\s+'), ' ')
            .trim();
      }
      if (minYear == null &&
          maxYear == null &&
          (prev.minYear != null || prev.maxYear != null)) {
        notes = notes
            .replaceAll(
              RegExp(
                r'\b20[12]\d(?:\s*(?:-|–|—|to|through|thru)\s*20[12]\d|\s*(?:\+|or\s+newer|and\s+newer|and\s+up|up))?\b[.,;]*',
                caseSensitive: false,
              ),
              ' ',
            )
            .replaceAll(RegExp(r'\s+'), ' ')
            .trim();
      }
      if (maxMileage == null && prev.maxMileage != null) {
        notes = notes
            .replaceAll(
              RegExp(
                r'(?:under|below|less\s+than|max|up\s+to|<=?)?\s*\d{1,3}(?:,\d{3})*\s*k?\s*(?:miles?|mi\.?)\b[.,;]*',
                caseSensitive: false,
              ),
              ' ',
            )
            .replaceAll(RegExp(r'\s+'), ' ')
            .trim();
      }
      if (_condition == 'Any' && prev.condition != 'Any') {
        notes = notes
            .replaceAll(
              RegExp(
                r'\b(?:certified\s+pre-?owned|pre-?owned|cpo|used|new)\b[.,;]*',
                caseSensitive: false,
              ),
              ' ',
            )
            .replaceAll(RegExp(r'\s+'), ' ')
            .trim();
      }
      if (_drivetrain == 'Any' && prev.drivetrain != 'Any') {
        notes = notes
            .replaceAll(
              RegExp(
                r'\b(?:4wd|4x4|four[\s-]wheel[\s-]drive|4[\s-]wheel[\s-]drive|awd|all[\s-]wheel[\s-]drive|rwd|2wd|4x2|rear[\s-]wheel[\s-]drive|fwd|front[\s-]wheel[\s-]drive)\b[.,;]*',
                caseSensitive: false,
              ),
              ' ',
            )
            .replaceAll(RegExp(r'\s+'), ' ')
            .trim();
      }
      if (combinedColors.isEmpty && prev.exteriorColor.isNotEmpty) {
        final prevColors =
            NaturalLanguageVehicleParser.parseExteriorColors(prev.exteriorColor);
        for (final c in prevColors) {
          notes = notes.replaceAll(
            RegExp(
              '\\b(?:[a-z]+\\s+)?${RegExp.escape(c)}(?:\\s+exterior|\\s+ext\\.?|\\s+metallic|\\s+pearl)?\\b[.,;]*',
              caseSensitive: false,
            ),
            ' ',
          );
        }
        notes = notes.replaceAll(RegExp(r'\s+'), ' ').trim();
      }
    }

    final hasAnyCriteria = make.isNotEmpty ||
        model.isNotEmpty ||
        trim.isNotEmpty ||
        _doors.isNotEmpty ||
        _bedLength.isNotEmpty ||
        notes.isNotEmpty ||
        combinedColors.isNotEmpty ||
        maxPrice != null ||
        minYear != null ||
        maxYear != null ||
        _selectedFeatures.isNotEmpty ||
        _condition != 'Any' ||
        _drivetrain != 'Any';

    if (!hasAnyCriteria) {
      setState(() {
        _errorText =
            'Enter a make, model, max budget, color, or requirement for the vehicle.';
      });
      return;
    }

    setState(() {
      _submitting = true;
      _errorText = null;
    });

    try {
      final ({GuestProfile guest, List<VehicleMatch> matches, String summary})
          res;
      if (_isEditing) {
        res = await ApiService.updateVehicleOnGuest(
          guestId: widget.guest.id,
          targetId: widget.existingTarget!.id,
          condition: _condition,
          minYear: minYear,
          maxYear: maxYear,
          make: make,
          model: model,
          trim: trim,
          doors: _doors,
          bedLength: _bedLength,
          maxPrice: maxPrice,
          maxMileage: maxMileage,
          drivetrain: _drivetrain,
          exteriorColor: combinedColors,
          features: _selectedFeatures.toList(),
          notes: notes,
        );
      } else {
        res = await ApiService.addVehicleToGuest(
          guestId: widget.guest.id,
          condition: _condition,
          minYear: minYear,
          maxYear: maxYear,
          make: make,
          model: model,
          trim: trim,
          doors: _doors,
          bedLength: _bedLength,
          maxPrice: maxPrice,
          maxMileage: maxMileage,
          drivetrain: _drivetrain,
          exteriorColor: combinedColors,
          features: _selectedFeatures.toList(),
          notes: notes,
        );
      }
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
        constraints: const BoxConstraints(maxWidth: 700, maxHeight: 800),
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
                    child: Icon(
                      _isEditing ? Icons.edit_road_rounded : Icons.add_road_rounded,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _isEditing
                              ? 'Edit Search Criteria for ${widget.guest.name}'
                              : 'Add Another Vehicle for ${widget.guest.name}',
                          style: textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        Text(
                          _isEditing
                              ? 'Update vehicle specs, colors, budget, or natural-language criteria and re-search prestonmotor.com immediately'
                              : 'Searches prestonmotor.com immediately & at 7:30 AM and 2:00 PM daily alongside existing criteria',
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
                    // Existing Vehicles / Active Edit Context Banner
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
                          Icon(
                            _isEditing
                                ? Icons.tune_rounded
                                : Icons.directions_car_filled_outlined,
                            size: 18,
                            color: scheme.primary,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              _isEditing
                                  ? 'Editing active search: ${widget.existingTarget!.label}'
                                  : 'Currently monitoring (${existingTargets.length}): ${existingTargets.map((t) => t.label).join('  •  ')}',
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
                            key: const ValueKey('dialog_make_input'),
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
                            key: const ValueKey('dialog_model_input'),
                            controller: _modelCtrl,
                            onChanged: (_) => setState(() {}),
                            decoration: const InputDecoration(
                              labelText: 'Model (e.g. F-150, Navigator, Explorer)',
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
                            key: const ValueKey('dialog_trim_input'),
                            controller: _trimCtrl,
                            onChanged: (_) => setState(() {}),
                            decoration: const InputDecoration(
                              labelText: 'Trim (Optional, e.g. Reserve, XLT, Lariat)',
                              prefixIcon: Icon(Icons.tune_outlined),
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: TextField(
                            key: const ValueKey('dialog_min_year_input'),
                            controller: _minYearCtrl,
                            keyboardType: TextInputType.number,
                            onChanged: (_) => setState(() {}),
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
                            key: const ValueKey('dialog_max_year_input'),
                            controller: _maxYearCtrl,
                            keyboardType: TextInputType.number,
                            onChanged: (_) => setState(() {}),
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
                            key: const ValueKey('dialog_max_price_input'),
                            controller: _maxPriceCtrl,
                            keyboardType: TextInputType.number,
                            onChanged: (_) => setState(() {}),
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
                            key: const ValueKey('dialog_max_mileage_input'),
                            controller: _maxMileageCtrl,
                            keyboardType: TextInputType.number,
                            onChanged: (_) => setState(() {}),
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
                            isExpanded: true,
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
                              DropdownMenuItem(value: 'AWD', child: Text('AWD')),
                              DropdownMenuItem(value: 'FWD', child: Text('FWD')),
                              DropdownMenuItem(value: 'RWD', child: Text('RWD')),
                            ],
                            onChanged: (v) {
                              if (v != null) setState(() => _drivetrain = v);
                            },
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: DropdownButtonFormField<String>(
                            key: const ValueKey('dialog_doors_dropdown'),
                            isExpanded: true,
                            initialValue: _doors,
                            decoration: const InputDecoration(
                              labelText: 'Number of Doors',
                              prefixIcon: Icon(Icons.sensor_door_outlined),
                            ),
                            items: _doorOptions
                                .map(
                                  (opt) => DropdownMenuItem<String>(
                                    value: opt.$1,
                                    child: Text(
                                      opt.$2,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                )
                                .toList(),
                            onChanged: (v) {
                              setState(() => _doors = v ?? '');
                            },
                          ),
                        ),
                      ],
                    ),

                    const SizedBox(height: 12),
                    Text(
                      'Truck Bed Length (Optional)',
                      style: textTheme.labelLarge
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: _bedLengthOptions.map((opt) {
                        final selected = _bedLength.replaceAll("'", '') ==
                            opt.$1.replaceAll("'", '');
                        return ChoiceChip(
                          key: ValueKey(
                            'dialog_bed_chip_${opt.$1.isEmpty ? 'any' : opt.$1}',
                          ),
                          label: Text(opt.$2),
                          selected: selected,
                          onSelected: (_) =>
                              setState(() => _bedLength = opt.$1),
                        );
                      }).toList(),
                    ),

                    const SizedBox(height: 14),
                    ExteriorColorSelector(
                      selectedColors: _selectedColors,
                      customColorController: _exteriorColorCtrl,
                      compact: true,
                      onChanged: (colors) {
                        setState(() => _selectedColors = colors);
                      },
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
                      onChanged: _handleNotesChanged,
                      decoration: const InputDecoration(
                        labelText:
                            'Natural-Language Search / Additional Criteria (Optional)',
                        hintText:
                            'e.g. Ford F150. 6.5ft bed. XLT. — or describe cab/box, engine, trim, budget...',
                        alignLabelWithHint: true,
                      ),
                    ),
                    if (_notesCtrl.text.trim().isNotEmpty ||
                        _selectedColors.isNotEmpty ||
                        _doors.isNotEmpty ||
                        _isEditing) ...[
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
                            'doors': _doors,
                            'bedLength': _bedLength,
                            'maxPrice': _parseMaxPrice(_maxPriceCtrl.text),
                            'maxMileage': int.tryParse(
                              _maxMileageCtrl.text.replaceAll(',', '').trim(),
                            ),
                            'drivetrain': _drivetrain,
                            'exteriorColor':
                                ExteriorColorSelector.combineSelectedAndTyped(
                              _selectedColors,
                              _exteriorColorCtrl.text,
                            ),
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
                    key: const ValueKey('submit_vehicle_criteria_button'),
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
                        : Icon(
                            _isEditing
                                ? Icons.save_as_rounded
                                : Icons.auto_awesome,
                          ),
                    label: Text(
                      _submitting
                          ? 'Searching prestonmotor.com...'
                          : (_isEditing
                              ? 'Save Changes & Re-Search'
                              : 'Add Vehicle & Search Now'),
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

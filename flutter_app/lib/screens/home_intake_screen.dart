import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import '../models/models.dart';
import '../services/api_service.dart';
import '../services/natural_language_parser.dart';
import '../widgets/exterior_color_selector.dart';

class HomeIntakeScreen extends StatefulWidget {
  final SystemStatus status;
  final VoidCallback onGuestCreated;
  final void Function(String guestId) onOpenGuestMatches;
  final VoidCallback onOpenSettings;

  const HomeIntakeScreen({
    super.key,
    required this.status,
    required this.onGuestCreated,
    required this.onOpenGuestMatches,
    required this.onOpenSettings,
  });

  @override
  State<HomeIntakeScreen> createState() => _HomeIntakeScreenState();
}

class _HomeIntakeScreenState extends State<HomeIntakeScreen> {
  final _formKey = GlobalKey<FormState>();

  final _guestNameCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();
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
  List<String> _selectedColors = [];
  final Set<String> _selectedFeatures = {};
  bool _isSubmitting = false;

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
    _guestNameCtrl.dispose();
    _phoneCtrl.dispose();
    _emailCtrl.dispose();
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

  void _resetForm() {
    _formKey.currentState?.reset();
    _guestNameCtrl.clear();
    _phoneCtrl.clear();
    _emailCtrl.clear();
    _minYearCtrl.clear();
    _maxYearCtrl.clear();
    _makeCtrl.clear();
    _modelCtrl.clear();
    _trimCtrl.clear();
    _maxPriceCtrl.clear();
    _maxMileageCtrl.clear();
    _exteriorColorCtrl.clear();
    _customFeatureCtrl.clear();
    _notesCtrl.clear();
    setState(() {
      _condition = 'Any';
      _drivetrain = 'Any';
      _selectedColors = [];
      _selectedFeatures.clear();
    });
  }

  String _effectiveExteriorColorString() {
    return ExteriorColorSelector.combineSelectedAndTyped(
      _selectedColors,
      _exteriorColorCtrl.text,
    );
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

  Future<void> _submitIntake() async {
    if (!_formKey.currentState!.validate()) return;

    final combinedColors = _effectiveExteriorColorString();
    final hasAnyVehicleSpec = _makeCtrl.text.trim().isNotEmpty ||
        _modelCtrl.text.trim().isNotEmpty ||
        _maxPriceCtrl.text.trim().isNotEmpty ||
        _notesCtrl.text.trim().isNotEmpty ||
        combinedColors.isNotEmpty ||
        _selectedFeatures.isNotEmpty;

    if (!hasAnyVehicleSpec) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
              'Please enter at least a Make, Model, Max Price, Color, or Requirements note for the Gemini Agent.'),
        ),
      );
      return;
    }

    setState(() => _isSubmitting = true);
    try {
      final result = await ApiService.createGuest(
        name: _guestNameCtrl.text.trim(),
        phone: _phoneCtrl.text.trim(),
        email: _emailCtrl.text.trim(),
        condition: _condition,
        minYear: int.tryParse(_minYearCtrl.text.trim()),
        maxYear: int.tryParse(_maxYearCtrl.text.trim()),
        make: _makeCtrl.text.trim(),
        model: _modelCtrl.text.trim(),
        trim: _trimCtrl.text.trim(),
        maxPrice: _parseMaxPrice(_maxPriceCtrl.text),
        maxMileage: int.tryParse(
            _maxMileageCtrl.text.replaceAll(RegExp(r'[^0-9]'), '')),
        drivetrain: _drivetrain,
        exteriorColor: combinedColors,
        features: _selectedFeatures.toList(),
        notes: _notesCtrl.text.trim(),
      );

      widget.onGuestCreated();
      if (!mounted) return;

      final guestId = result.guest.id;
      final guestName = result.guest.name;
      final matchesFound = result.matchesFound;

      _resetForm();

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 7),
          content: Text(
            matchesFound > 0
                ? 'Saved $guestName! Gemini Agent found $matchesFound match(es) on prestonmotor.com. Scheduled daily at 7:30 AM & 2:00 PM.'
                : 'Saved $guestName! Scheduled for twice-daily searches (7:30 AM & 2:00 PM) on prestonmotor.com.',
          ),
          action: SnackBarAction(
            label: 'View Matches ($matchesFound)',
            onPressed: () => widget.onOpenGuestMatches(guestId),
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error saving guest: $e')),
      );
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 40),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 960),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Schedule & Gemini Agent Status Banner
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: scheme.primaryContainer.withValues(alpha: 0.55),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: scheme.primary.withValues(alpha: 0.2),
                    ),
                  ),
                  child: Wrap(
                    spacing: 16,
                    runSpacing: 12,
                    alignment: WrapAlignment.spaceBetween,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          CircleAvatar(
                            backgroundColor: scheme.primary,
                            foregroundColor: scheme.onPrimary,
                            child: const Icon(Icons.auto_awesome, size: 20),
                          ),
                          const SizedBox(width: 12),
                          Flexible(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Gemini Agent • Twice-Daily prestonmotor.com Search',
                                  style: textTheme.titleSmall?.copyWith(
                                    fontWeight: FontWeight.w700,
                                    color: scheme.onPrimaryContainer,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  'Runs automatically at 7:30 AM & 2:00 PM daily • Next: ${widget.status.nextScheduledRunLabel}',
                                  style: textTheme.bodySmall?.copyWith(
                                    color: scheme.onPrimaryContainer
                                        .withValues(alpha: 0.85),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      ActionChip(
                        avatar: Icon(
                          widget.status.geminiConfigured
                              ? Icons.verified
                              : Icons.key,
                          size: 16,
                          color: scheme.primary,
                        ),
                        label: Text(
                          widget.status.geminiConfigured
                              ? 'Gemini (${widget.status.geminiModel}) Active'
                              : 'Configure Gemini API Key',
                        ),
                        onPressed: widget.onOpenSettings,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),

                // Section 1: Guest Information
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(Icons.person_add_alt_1_outlined,
                                color: scheme.primary),
                            const SizedBox(width: 10),
                            Text(
                              'Guest Information',
                              style: textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const Spacer(),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 10, vertical: 4),
                              decoration: BoxDecoration(
                                color: scheme.secondaryContainer,
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: Text(
                                'Unlimited Guests Supported',
                                style: textTheme.labelSmall?.copyWith(
                                  color: scheme.onSecondaryContainer,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        LayoutBuilder(
                          builder: (context, constraints) {
                            final wide = constraints.maxWidth > 620;
                            if (wide) {
                              return Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Expanded(
                                    flex: 5,
                                    child: _buildGuestNameField(),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    flex: 3,
                                    child: _buildPhoneField(),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    flex: 4,
                                    child: _buildEmailField(),
                                  ),
                                ],
                              );
                            }
                            return Column(
                              children: [
                                _buildGuestNameField(),
                                const SizedBox(height: 12),
                                _buildPhoneField(),
                                const SizedBox(height: 12),
                                _buildEmailField(),
                              ],
                            );
                          },
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),

                // Section 2: Target Vehicle Specs
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(Icons.directions_car_outlined,
                                color: scheme.primary),
                            const SizedBox(width: 10),
                            Text(
                              'Target Vehicle Specifications',
                              style: textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),

                        // Condition & Drivetrain Row
                        Wrap(
                          spacing: 24,
                          runSpacing: 16,
                          children: [
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('Vehicle Condition',
                                    style: textTheme.labelMedium),
                                const SizedBox(height: 6),
                                SegmentedButton<String>(
                                  showSelectedIcon: false,
                                  segments: const [
                                    ButtonSegment(
                                        value: 'Any', label: Text('Any')),
                                    ButtonSegment(
                                        value: 'New', label: Text('New')),
                                    ButtonSegment(
                                        value: 'Pre-Owned',
                                        label: Text('Pre-Owned')),
                                    ButtonSegment(
                                        value: 'CPO', label: Text('CPO')),
                                  ],
                                  selected: {_condition},
                                  onSelectionChanged: (s) =>
                                      setState(() => _condition = s.first),
                                ),
                              ],
                            ),
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('Drivetrain',
                                    style: textTheme.labelMedium),
                                const SizedBox(height: 6),
                                SegmentedButton<String>(
                                  showSelectedIcon: false,
                                  segments: const [
                                    ButtonSegment(
                                        value: 'Any', label: Text('Any')),
                                    ButtonSegment(
                                        value: '4WD', label: Text('4WD')),
                                    ButtonSegment(
                                        value: 'AWD', label: Text('AWD')),
                                    ButtonSegment(
                                        value: 'FWD', label: Text('FWD')),
                                    ButtonSegment(
                                        value: 'RWD', label: Text('RWD')),
                                  ],
                                  selected: {_drivetrain},
                                  onSelectionChanged: (s) =>
                                      setState(() => _drivetrain = s.first),
                                ),
                              ],
                            ),
                          ],
                        ),
                        const SizedBox(height: 18),

                        // Quick Preston Motor Brand selector
                        Text(
                          'Quick-Select Preston Automotive Brand (or type any make below)',
                          style: textTheme.labelMedium?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: _prestonMakes.map((brand) {
                            final isSelected = _makeCtrl.text.trim().toLowerCase() ==
                                brand.toLowerCase();
                            return ChoiceChip(
                              label: Text(brand),
                              selected: isSelected,
                              onSelected: (sel) {
                                setState(() {
                                  _makeCtrl.text = sel ? brand : '';
                                });
                              },
                            );
                          }).toList(),
                        ),
                        const SizedBox(height: 16),

                        // Make / Model / Trim
                        LayoutBuilder(
                          builder: (context, constraints) {
                            final wide = constraints.maxWidth > 620;
                            final makeField = TextFormField(
                              controller: _makeCtrl,
                              onChanged: (_) => setState(() {}),
                              decoration: const InputDecoration(
                                labelText: 'Make',
                                hintText: 'e.g. Ford, Lincoln, Hyundai',
                                prefixIcon: Icon(Icons.badge_outlined),
                              ),
                            );
                            final modelField = TextFormField(
                              controller: _modelCtrl,
                              decoration: const InputDecoration(
                                labelText: 'Model',
                                hintText: 'e.g. F-250, Nautilus, Bronco Sport',
                                prefixIcon: Icon(Icons.commute_outlined),
                              ),
                            );
                            final trimField = TextFormField(
                              controller: _trimCtrl,
                              decoration: const InputDecoration(
                                labelText: 'Trim / Cab / Series (Optional)',
                                hintText: 'e.g. Reserve, XL, Lariat, Big Bend',
                                prefixIcon: Icon(Icons.tune_outlined),
                              ),
                            );

                            if (wide) {
                              return Row(
                                children: [
                                  Expanded(child: makeField),
                                  const SizedBox(width: 12),
                                  Expanded(child: modelField),
                                  const SizedBox(width: 12),
                                  Expanded(child: trimField),
                                ],
                              );
                            }
                            return Column(
                              children: [
                                makeField,
                                const SizedBox(height: 12),
                                modelField,
                                const SizedBox(height: 12),
                                trimField,
                              ],
                            );
                          },
                        ),
                        const SizedBox(height: 14),

                        // Min Year / Max Year / Max Price / Max Mileage
                        LayoutBuilder(
                          builder: (context, constraints) {
                            final wide = constraints.maxWidth > 680;
                            final minYearField = TextFormField(
                              controller: _minYearCtrl,
                              keyboardType: TextInputType.number,
                              inputFormatters: [
                                FilteringTextInputFormatter.digitsOnly,
                                LengthLimitingTextInputFormatter(4),
                              ],
                              decoration: const InputDecoration(
                                labelText: 'Min Year',
                                hintText: '2022',
                                prefixIcon: Icon(Icons.calendar_today_outlined),
                              ),
                            );
                            final maxYearField = TextFormField(
                              controller: _maxYearCtrl,
                              keyboardType: TextInputType.number,
                              inputFormatters: [
                                FilteringTextInputFormatter.digitsOnly,
                                LengthLimitingTextInputFormatter(4),
                              ],
                              decoration: const InputDecoration(
                                labelText: 'Max Year',
                                hintText: '2027',
                                prefixIcon: Icon(Icons.event_outlined),
                              ),
                            );
                            final maxPriceField = TextFormField(
                              controller: _maxPriceCtrl,
                              keyboardType: TextInputType.text,
                              inputFormatters: [
                                FilteringTextInputFormatter.allow(
                                  RegExp(r'[0-9kK.$,\s]'),
                                ),
                              ],
                              decoration: const InputDecoration(
                                labelText: 'Max Price (\$)',
                                hintText: '60000 or 60K',
                                prefixIcon: Icon(Icons.attach_money),
                              ),
                            );
                            final maxMilesField = TextFormField(
                              controller: _maxMileageCtrl,
                              keyboardType: TextInputType.number,
                              inputFormatters: [
                                FilteringTextInputFormatter.digitsOnly,
                              ],
                              decoration: const InputDecoration(
                                labelText: 'Max Mileage',
                                hintText: '60000',
                                prefixIcon: Icon(Icons.speed_outlined),
                              ),
                            );

                            if (wide) {
                              return Row(
                                children: [
                                  Expanded(flex: 2, child: minYearField),
                                  const SizedBox(width: 10),
                                  Expanded(flex: 2, child: maxYearField),
                                  const SizedBox(width: 10),
                                  Expanded(flex: 3, child: maxPriceField),
                                  const SizedBox(width: 10),
                                  Expanded(flex: 3, child: maxMilesField),
                                ],
                              );
                            }
                            return Column(
                              children: [
                                Row(
                                  children: [
                                    Expanded(child: minYearField),
                                    const SizedBox(width: 10),
                                    Expanded(child: maxYearField),
                                  ],
                                ),
                                const SizedBox(height: 12),
                                Row(
                                  children: [
                                    Expanded(child: maxPriceField),
                                    const SizedBox(width: 10),
                                    Expanded(child: maxMilesField),
                                  ],
                                ),
                              ],
                            );
                          },
                        ),
                        const SizedBox(height: 16),

                        // Multi-Select Exterior Colors Picker
                        ExteriorColorSelector(
                          selectedColors: _selectedColors,
                          customColorController: _exteriorColorCtrl,
                          onChanged: (colors) {
                            setState(() => _selectedColors = colors);
                          },
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),

                // Section 3: Must-Have Features & Natural Language Notes for Gemini Agent
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(Icons.checklist_rtl_outlined,
                                color: scheme.primary),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                'Target Features & Gemini Agent Requirements',
                                style: textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Text(
                          'Select must-have features or type specific equipment, packages, and deal requirements. Selected matches will highlight which exact features meet these specs.',
                          style: textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 14),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            ..._commonFeatures.map((feat) {
                              final selected = _selectedFeatures.contains(feat);
                              return FilterChip(
                                label: Text(feat),
                                selected: selected,
                                onSelected: (v) {
                                  setState(() {
                                    if (v) {
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
                                .map(
                                  (custom) => InputChip(
                                    label: Text(custom),
                                    selected: true,
                                    onDeleted: () => setState(
                                        () => _selectedFeatures.remove(custom)),
                                  ),
                                ),
                          ],
                        ),
                        const SizedBox(height: 14),
                        Row(
                          children: [
                            Expanded(
                              child: TextField(
                                controller: _customFeatureCtrl,
                                onSubmitted: (_) => _addCustomFeature(),
                                decoration: const InputDecoration(
                                  labelText: 'Add Custom Feature Tag',
                                  hintText:
                                      'e.g. Co-Pilot360, SuperCab 8ft Box, 7.3L V8, Panoramic Roof',
                                  prefixIcon:
                                      Icon(Icons.add_circle_outline_rounded),
                                ),
                              ),
                            ),
                            const SizedBox(width: 10),
                            FilledButton.tonalIcon(
                              onPressed: _addCustomFeature,
                              icon: const Icon(Icons.add),
                              label: const Text('Add Feature'),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        TextFormField(
                          key: const ValueKey('natural_language_search_input'),
                          controller: _notesCtrl,
                          maxLines: 3,
                          onChanged: (_) => setState(() {}),
                          decoration: const InputDecoration(
                            labelText:
                                'Additional Specs & Natural-Language Search for Gemini Agent',
                            hintText:
                                'e.g. Ford F150. 6.5ft bed. XLT. — or describe cab/box configuration, engine, trim, budget, or package codes...',
                            alignLabelWithHint: true,
                            prefixIcon: Padding(
                              padding: EdgeInsets.only(bottom: 42),
                              child: Icon(Icons.psychology_outlined),
                            ),
                          ),
                        ),
                        if (_notesCtrl.text.trim().isNotEmpty ||
                            _selectedColors.isNotEmpty) ...[
                          const SizedBox(height: 12),
                          _buildParsedCriteriaBanner(scheme, textTheme),
                        ],
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 24),

                // Submit Action Row
                Wrap(
                  alignment: WrapAlignment.end,
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    OutlinedButton.icon(
                      onPressed: _isSubmitting ? null : _resetForm,
                      icon: const Icon(Icons.refresh),
                      label: const Text('Clear Form'),
                    ),
                    FilledButton.icon(
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 24, vertical: 16),
                      ),
                      onPressed: _isSubmitting ? null : _submitIntake,
                      icon: _isSubmitting
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(Icons.travel_explore),
                      label: Text(
                        _isSubmitting
                            ? 'Ingesting & Searching prestonmotor.com...'
                            : 'Save Guest & Start Twice-Daily Search',
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

  Widget _buildGuestNameField() {
    return TextFormField(
      controller: _guestNameCtrl,
      textCapitalization: TextCapitalization.words,
      validator: (v) =>
          (v == null || v.trim().isEmpty) ? 'Guest name is required' : null,
      decoration: const InputDecoration(
        labelText: 'Guest Full Name *',
        hintText: 'e.g. Rhonda Vanvorst',
        prefixIcon: Icon(Icons.person_outline),
      ),
    );
  }

  Widget _buildPhoneField() {
    return TextFormField(
      controller: _phoneCtrl,
      keyboardType: TextInputType.phone,
      decoration: const InputDecoration(
        labelText: 'Phone (Optional)',
        hintText: '(302) 555-0148',
        prefixIcon: Icon(Icons.phone_outlined),
      ),
    );
  }

  Widget _buildParsedCriteriaBanner(ColorScheme scheme, TextTheme textTheme) {
    final chips = NaturalLanguageVehicleParser.buildPreviewChips({
      'condition': _condition,
      'minYear': int.tryParse(_minYearCtrl.text.trim()),
      'maxYear': int.tryParse(_maxYearCtrl.text.trim()),
      'make': _makeCtrl.text.trim(),
      'model': _modelCtrl.text.trim(),
      'trim': _trimCtrl.text.trim(),
      'maxPrice': _parseMaxPrice(_maxPriceCtrl.text),
      'maxMileage': int.tryParse(
        _maxMileageCtrl.text.replaceAll(RegExp(r'[^0-9]'), ''),
      ),
      'drivetrain': _drivetrain,
      'exteriorColor': _effectiveExteriorColorString(),
      'features': _selectedFeatures.toList(),
      'notes': _notesCtrl.text.trim(),
    });

    if (chips.isEmpty) return const SizedBox.shrink();

    return Container(
      key: const ValueKey('parsed_natural_language_summary'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.primary.withValues(alpha: 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.verified_outlined, size: 16, color: scheme.primary),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'Understood Search Criteria (Only Matching Vehicles Shown)',
                  style: textTheme.labelMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: scheme.onSecondaryContainer,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: chips
                .map(
                  (c) => Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: scheme.surface,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: scheme.outlineVariant),
                    ),
                    child: Text(
                      c,
                      style: textTheme.labelSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: scheme.onSurface,
                      ),
                    ),
                  ),
                )
                .toList(),
          ),
        ],
      ),
    );
  }

  Widget _buildEmailField() {
    return TextFormField(
      controller: _emailCtrl,
      keyboardType: TextInputType.emailAddress,
      decoration: const InputDecoration(
        labelText: 'Email (Optional)',
        hintText: 'guest@example.com',
        prefixIcon: Icon(Icons.mail_outline),
      ),
    );
  }
}

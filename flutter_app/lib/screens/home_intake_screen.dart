import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/models.dart';
import '../services/api_service.dart';
import '../services/document_picker_service.dart';
import '../services/natural_language_parser.dart';
import '../widgets/copyable_identifier_badge.dart';
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
  String _doors = '';
  String _bedLength = '';
  List<String> _selectedColors = [];
  final Set<String> _selectedFeatures = {};
  bool _isSubmitting = false;
  int _resetGeneration = 0;

  // Document Upload & Gemini Closest-Equivalents state
  bool _isAnalyzingDocument = false;
  PickedDocumentFile? _uploadedDocument;
  DocumentEquivalentSearchResult? _documentSearchResult;
  String? _documentSearchError;

  // Collapsible dropdown states (collapsed by default to minimize clutter)
  bool _contactDropdownOpen = false;
  bool _specsDropdownOpen = false;
  bool _colorsDropdownOpen = false;
  bool _featuresDropdownOpen = false;

  static const List<(String, String)> _conditionOptions = [
    ('Any', 'Any Condition'),
    ('New', 'New'),
    ('Pre-Owned', 'Pre-Owned'),
    ('CPO', 'Certified Pre-Owned (CPO)'),
  ];

  static const List<(String, String)> _drivetrainOptions = [
    ('Any', 'Any Drivetrain'),
    ('4WD', '4WD / 4x4'),
    ('AWD', 'AWD'),
    ('FWD', 'FWD'),
    ('RWD', 'RWD'),
  ];

  static const List<(String, String)> _doorOptions = [
    ('', 'Any Doors'),
    ('2', '2 Doors'),
    ('3', '3 Doors'),
    ('4', '4 Doors'),
    ('5', '5 Doors'),
  ];

  static const List<(String, String)> _bedLengthOptions = [
    ('', 'Any Bed Length'),
    ('5.5', '5.5 ft Bed'),
    ('6.5', '6.5 ft Bed'),
    ('6.75', '6.75 ft Bed'),
    ('8', '8 ft Bed'),
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
    'GMC',
    'Toyota',
    'Honda',
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

  bool get _allDropdownsExpanded =>
      _contactDropdownOpen &&
      _specsDropdownOpen &&
      _colorsDropdownOpen &&
      _featuresDropdownOpen;

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

  void _toggleAllDropdowns() {
    final expand = !_allDropdownsExpanded;
    setState(() {
      _contactDropdownOpen = expand;
      _specsDropdownOpen = expand;
      _colorsDropdownOpen = expand;
      _featuresDropdownOpen = expand;
    });
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
      _doors = '';
      _bedLength = '';
      _selectedColors = [];
      _selectedFeatures.clear();
      _uploadedDocument = null;
      _documentSearchResult = null;
      _documentSearchError = null;
      _resetGeneration++;
    });
  }

  Future<void> _uploadAndMatchDocument() async {
    if (_isAnalyzingDocument || _isSubmitting) return;
    PickedDocumentFile? picked;
    try {
      picked = await DocumentPickerService.pickDocument();
    } catch (err) {
      if (!mounted) return;
      final msg = err.toString().replaceFirst(RegExp(r'^Exception:\s*'), '');
      setState(() => _documentSearchError = msg);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg)),
      );
      return;
    }

    if (picked == null) return;

    setState(() {
      _isAnalyzingDocument = true;
      _uploadedDocument = picked;
      _documentSearchError = null;
    });

    try {
      final result = await ApiService.findEquivalentVehiclesFromDocument(
        document: picked,
        extraNotes: _notesCtrl.text.trim(),
      );
      if (!mounted) return;
      setState(() {
        _documentSearchResult = result;
        _isAnalyzingDocument = false;
        if (_guestNameCtrl.text.trim().isEmpty &&
            result.extractedGuestName.trim().isNotEmpty) {
          _guestNameCtrl.text = result.extractedGuestName.trim();
        }
      });
    } catch (err) {
      if (!mounted) return;
      final msg = err.toString().replaceFirst(RegExp(r'^Exception:\s*'), '');
      setState(() {
        _documentSearchError = msg;
        _isAnalyzingDocument = false;
      });
    }
  }

  void _applyExtractedSpecsToForm(DocumentExtractedVehicleProfile ref) {
    setState(() {
      if (const ['Any', 'New', 'Pre-Owned', 'CPO'].contains(ref.condition)) {
        _condition = ref.condition;
      }
      if (ref.make.isNotEmpty) _makeCtrl.text = ref.make;
      if (ref.model.isNotEmpty) _modelCtrl.text = ref.model;
      if (ref.trim.isNotEmpty) _trimCtrl.text = ref.trim;
      if (const ['2', '3', '4', '5'].contains(ref.doors)) {
        _doors = ref.doors;
      }
      if (const ['5.5', '6.5', '6.75', '8'].contains(ref.bedLength)) {
        _bedLength = ref.bedLength;
      }
      if (const ['Any', '4WD', 'AWD', 'FWD', 'RWD'].contains(ref.drivetrain)) {
        _drivetrain = ref.drivetrain;
      }
      if (ref.minYear != null) {
        _minYearCtrl.text = '${ref.minYear}';
      } else if (ref.year != null) {
        _minYearCtrl.text = '${ref.year}';
      }
      if (ref.maxYear != null) {
        _maxYearCtrl.text = '${ref.maxYear}';
      }
      if (ref.targetPrice != null && ref.targetPrice! > 0) {
        _maxPriceCtrl.text = (ref.targetPrice! * 1.05).round().toString();
      }
      if (ref.maxMileage != null && ref.maxMileage! > 0) {
        _maxMileageCtrl.text = '${ref.maxMileage}';
      }
      if (ref.exteriorColor.isNotEmpty) {
        _exteriorColorCtrl.text = ref.exteriorColor;
      }
      for (final f in ref.keyFeatures) {
        if (f.trim().isNotEmpty) _selectedFeatures.add(f.trim());
      }
      _resetGeneration++;
    });

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        duration: Duration(seconds: 3),
        content: Text(
          'Applied extracted document specifications to the Guest & Vehicle search form.',
        ),
      ),
    );
  }

  void _applyEquivalentVehicleToForm(EquivalentVehicleMatch eq) {
    setState(() {
      final condLower = eq.condition.toLowerCase();
      if (condLower.contains('new')) {
        _condition = 'New';
      } else if (condLower.contains('certified')) {
        _condition = 'CPO';
      } else if (condLower.isNotEmpty) {
        _condition = 'Pre-Owned';
      }
      if (eq.make.isNotEmpty) _makeCtrl.text = eq.make;
      if (eq.model.isNotEmpty) _modelCtrl.text = eq.model;
      if (eq.trim.isNotEmpty) _trimCtrl.text = eq.trim;
      if (const ['4WD', 'AWD', 'FWD', 'RWD']
          .contains(eq.drivetrain.toUpperCase())) {
        _drivetrain = eq.drivetrain.toUpperCase();
      }
      if (eq.year != null) {
        _minYearCtrl.text = '${eq.year}';
      }
      if (eq.price != null && eq.price! > 0) {
        _maxPriceCtrl.text = (eq.price! * 1.03).round().toString();
      }
      if (eq.exteriorColor.isNotEmpty) {
        _exteriorColorCtrl.text = eq.exteriorColor;
      }
      _resetGeneration++;
    });

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 3),
        content: Text(
          'Pre-filled search form from ${eq.title} (${eq.location}). Enter guest name to monitor twice daily.',
        ),
      ),
    );
  }

  Future<void> _openVehicleListingUrl(String urlStr) async {
    final uri = Uri.tryParse(urlStr.trim());
    if (uri == null) return;
    final launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!launched && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Vehicle Listing URL: $urlStr')),
      );
    }
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

  String _contactSummaryLabel() {
    final parts = <String>[];
    if (_phoneCtrl.text.trim().isNotEmpty) {
      parts.add(_phoneCtrl.text.trim());
    }
    if (_emailCtrl.text.trim().isNotEmpty) {
      parts.add(_emailCtrl.text.trim());
    }
    return parts.isEmpty ? 'Optional Phone & Email' : parts.join(' • ');
  }

  bool get _hasContactDetails =>
      _phoneCtrl.text.trim().isNotEmpty || _emailCtrl.text.trim().isNotEmpty;

  String _specsSummaryLabel() {
    final parts = <String>[];
    if (_trimCtrl.text.trim().isNotEmpty) {
      parts.add(_trimCtrl.text.trim());
    }
    if (_doors.isNotEmpty) {
      parts.add('$_doors Doors');
    }
    if (_drivetrain != 'Any') {
      parts.add(_drivetrain);
    }
    if (_bedLength.isNotEmpty) {
      parts.add('$_bedLength ft Bed');
    }
    final minY = _minYearCtrl.text.trim();
    final maxY = _maxYearCtrl.text.trim();
    if (minY.isNotEmpty && maxY.isNotEmpty) {
      parts.add('$minY–$maxY');
    } else if (minY.isNotEmpty) {
      parts.add('$minY+');
    } else if (maxY.isNotEmpty) {
      parts.add('Up to $maxY');
    }
    if (_maxMileageCtrl.text.trim().isNotEmpty) {
      parts.add('≤${_maxMileageCtrl.text.trim()} mi');
    }
    return parts.isEmpty
        ? 'Any Trim, Doors, Drivetrain & Year'
        : parts.join(' • ');
  }

  bool get _hasCustomSpecs =>
      _trimCtrl.text.trim().isNotEmpty ||
      _doors.isNotEmpty ||
      _drivetrain != 'Any' ||
      _bedLength.isNotEmpty ||
      _minYearCtrl.text.trim().isNotEmpty ||
      _maxYearCtrl.text.trim().isNotEmpty ||
      _maxMileageCtrl.text.trim().isNotEmpty;

  String _colorsSummaryLabel() {
    final combined = _effectiveExteriorColorString();
    if (combined.isEmpty) return 'Any Color';
    final list = NaturalLanguageVehicleParser.parseExteriorColors(combined);
    if (list.isEmpty) return 'Any Color';
    if (list.length <= 2) {
      return '${list.length} selected: ${list.join(', ')}';
    }
    return '${list.length} selected: ${list.take(2).join(', ')} +${list.length - 2}';
  }

  bool get _hasSelectedColors => _effectiveExteriorColorString().isNotEmpty;

  String _featuresSummaryLabel() {
    if (_selectedFeatures.isEmpty) return 'Optional';
    final list = _selectedFeatures.toList();
    if (list.length <= 2) {
      return '${list.length} selected: ${list.join(', ')}';
    }
    return '${list.length} selected: ${list.take(2).join(', ')} +${list.length - 2}';
  }

  Future<void> _submitIntake() async {
    if (!_formKey.currentState!.validate()) return;

    final combinedColors = _effectiveExteriorColorString();
    final hasAnyVehicleSpec = _makeCtrl.text.trim().isNotEmpty ||
        _modelCtrl.text.trim().isNotEmpty ||
        _trimCtrl.text.trim().isNotEmpty ||
        _doors.isNotEmpty ||
        _bedLength.isNotEmpty ||
        _condition != 'Any' ||
        _drivetrain != 'Any' ||
        _minYearCtrl.text.trim().isNotEmpty ||
        _maxYearCtrl.text.trim().isNotEmpty ||
        _maxPriceCtrl.text.trim().isNotEmpty ||
        _maxMileageCtrl.text.trim().isNotEmpty ||
        _notesCtrl.text.trim().isNotEmpty ||
        combinedColors.isNotEmpty ||
        _selectedFeatures.isNotEmpty;

    if (!hasAnyVehicleSpec) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Please enter at least a Make, Model, Number of Doors, Max Price, Color, or Requirements note for the Gemini Agent.',
          ),
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
        doors: _doors,
        bedLength: _bedLength,
        maxPrice: _parseMaxPrice(_maxPriceCtrl.text),
        maxMileage: int.tryParse(
          _maxMileageCtrl.text.replaceAll(RegExp(r'[^0-9]'), ''),
        ),
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
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 36),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 920),
          child: KeyedSubtree(
            key: ValueKey('intake_form_gen_$_resetGeneration'),
            child: Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Compact Gemini Status & Dropdown Toggle Bar
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: scheme.primaryContainer.withValues(alpha: 0.5),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: scheme.primary.withValues(alpha: 0.18),
                      ),
                    ),
                    child: Wrap(
                      spacing: 12,
                      runSpacing: 8,
                      alignment: WrapAlignment.spaceBetween,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.auto_awesome,
                              size: 18,
                              color: scheme.primary,
                            ),
                            const SizedBox(width: 8),
                            Flexible(
                              child: Text(
                                '7:30 AM & 2:00 PM prestonmotor.com Search • Next: ${widget.status.nextScheduledRunLabel}',
                                style: textTheme.labelMedium?.copyWith(
                                  fontWeight: FontWeight.w700,
                                  color: scheme.onPrimaryContainer,
                                ),
                              ),
                            ),
                          ],
                        ),
                        Wrap(
                          spacing: 8,
                          runSpacing: 6,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            ActionChip(
                              visualDensity: VisualDensity.compact,
                              avatar: Icon(
                                widget.status.geminiConfigured
                                    ? Icons.verified
                                    : Icons.key,
                                size: 15,
                                color: scheme.primary,
                              ),
                              label: Text(
                                widget.status.geminiConfigured
                                    ? 'Gemini Active'
                                    : 'Set API Key',
                                style: textTheme.labelSmall?.copyWith(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              onPressed: widget.onOpenSettings,
                            ),
                            TextButton.icon(
                              key: const ValueKey('toggle_all_dropdowns_button'),
                              style: TextButton.styleFrom(
                                visualDensity: VisualDensity.compact,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 6,
                                ),
                              ),
                              onPressed: _toggleAllDropdowns,
                              icon: Icon(
                                _allDropdownsExpanded
                                    ? Icons.unfold_less_rounded
                                    : Icons.unfold_more_rounded,
                                size: 18,
                              ),
                              label: Text(
                                _allDropdownsExpanded
                                    ? 'Collapse All'
                                    : 'Expand All',
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),

                  // Primary Quick Search Card (Essential Fields Only)
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(18),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(
                                Icons.manage_search_rounded,
                                color: scheme.primary,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  'Quick Guest & Vehicle Search',
                                  style: textTheme.titleMedium?.copyWith(
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 4,
                                ),
                                decoration: BoxDecoration(
                                  color: scheme.secondaryContainer,
                                  borderRadius: BorderRadius.circular(20),
                                ),
                                child: Text(
                                  'Unlimited Guests',
                                  style: textTheme.labelSmall?.copyWith(
                                    color: scheme.onSecondaryContainer,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 14),

                          // Guest Name + Condition Dropdown
                          LayoutBuilder(
                            builder: (context, constraints) {
                              final wide = constraints.maxWidth > 600;
                              final conditionDropdown =
                                  DropdownButtonFormField<String>(
                                key: const ValueKey('condition_dropdown_field'),
                                isExpanded: true,
                                initialValue: _condition,
                                decoration: const InputDecoration(
                                  labelText: 'Condition',
                                  prefixIcon: Icon(Icons.sell_outlined),
                                ),
                                items: _conditionOptions
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
                                  if (v != null) {
                                    setState(() => _condition = v);
                                  }
                                },
                              );

                              if (wide) {
                                return Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Expanded(
                                      flex: 6,
                                      child: _buildGuestNameField(),
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      flex: 4,
                                      child: conditionDropdown,
                                    ),
                                  ],
                                );
                              }
                              return Column(
                                children: [
                                  _buildGuestNameField(),
                                  const SizedBox(height: 12),
                                  conditionDropdown,
                                ],
                              );
                            },
                          ),
                          const SizedBox(height: 12),

                          // Make (with Quick Brand Dropdown Menu) + Model + Max Price
                          LayoutBuilder(
                            builder: (context, constraints) {
                              final wide = constraints.maxWidth > 640;
                              final makeField = TextFormField(
                                controller: _makeCtrl,
                                onChanged: (_) => setState(() {}),
                                decoration: InputDecoration(
                                  labelText: 'Make',
                                  hintText: 'e.g. Ford, Lincoln, Mazda',
                                  prefixIcon: const Icon(Icons.badge_outlined),
                                  suffixIcon: PopupMenuButton<String>(
                                    key: const ValueKey(
                                      'make_brand_dropdown_button',
                                    ),
                                    tooltip: 'Select Brand',
                                    icon: const Icon(Icons.arrow_drop_down),
                                    onSelected: (brand) {
                                      setState(() {
                                        _makeCtrl.text =
                                            brand == '__CLEAR__' ? '' : brand;
                                      });
                                    },
                                    itemBuilder: (context) => [
                                      const PopupMenuItem<String>(
                                        value: '__CLEAR__',
                                        child: Text('Any / Clear Make'),
                                      ),
                                      const PopupMenuDivider(),
                                      ..._prestonMakes.map(
                                        (b) => PopupMenuItem<String>(
                                          value: b,
                                          child: Text(b),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              );
                              final modelField = TextFormField(
                                controller: _modelCtrl,
                                onChanged: (_) => setState(() {}),
                                decoration: const InputDecoration(
                                  labelText: 'Model',
                                  hintText: 'e.g. F-150, Nautilus, Bronco',
                                  prefixIcon: Icon(Icons.commute_outlined),
                                ),
                              );
                              final maxPriceField = TextFormField(
                                controller: _maxPriceCtrl,
                                keyboardType: TextInputType.text,
                                onChanged: (_) => setState(() {}),
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

                              if (wide) {
                                return Row(
                                  children: [
                                    Expanded(flex: 4, child: makeField),
                                    const SizedBox(width: 12),
                                    Expanded(flex: 4, child: modelField),
                                    const SizedBox(width: 12),
                                    Expanded(flex: 3, child: maxPriceField),
                                  ],
                                );
                              }
                              return Column(
                                children: [
                                  makeField,
                                  const SizedBox(height: 12),
                                  Row(
                                    children: [
                                      Expanded(child: modelField),
                                      const SizedBox(width: 10),
                                      Expanded(child: maxPriceField),
                                    ],
                                  ),
                                ],
                              );
                            },
                          ),
                          const SizedBox(height: 12),

                          // Natural-Language Search Input (Always Handy, Compact 2-Line Field)
                          TextFormField(
                            key: const ValueKey('natural_language_search_input'),
                            controller: _notesCtrl,
                            maxLines: 2,
                            onChanged: (_) => setState(() {}),
                            decoration: const InputDecoration(
                              labelText:
                                  'Natural-Language Search / Quick Notes (Optional)',
                              hintText:
                                  'e.g. Ford F150. 6.5ft bed. XLT. — or type cab, engine, trim, or package codes...',
                              alignLabelWithHint: true,
                              prefixIcon: Padding(
                                padding: EdgeInsets.only(bottom: 22),
                                child: Icon(Icons.psychology_outlined),
                              ),
                            ),
                          ),
                          if (_notesCtrl.text.trim().isNotEmpty ||
                              _hasSelectedColors ||
                              _doors.isNotEmpty ||
                              _bedLength.isNotEmpty) ...[
                            const SizedBox(height: 12),
                            _buildParsedCriteriaBanner(scheme, textTheme),
                          ],
                          const SizedBox(height: 14),
                          Container(
                            key: const ValueKey(
                              'document_upload_intake_banner',
                            ),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 12,
                            ),
                            decoration: BoxDecoration(
                              color: scheme.tertiaryContainer
                                  .withValues(alpha: 0.35),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: scheme.primary.withValues(alpha: 0.22),
                              ),
                            ),
                            child: Wrap(
                              spacing: 12,
                              runSpacing: 10,
                              alignment: WrapAlignment.spaceBetween,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      Icons.description_outlined,
                                      size: 20,
                                      color: scheme.primary,
                                    ),
                                    const SizedBox(width: 10),
                                    Flexible(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            'Have a Window Sticker, Competitor Quote, or Spec Sheet?',
                                            style: textTheme.labelLarge
                                                ?.copyWith(
                                              fontWeight: FontWeight.w700,
                                            ),
                                          ),
                                          Text(
                                            'Upload any PDF, photo, or document — Gemini finds the closest equivalent vehicles across all prestonmotor.com inventory.',
                                            style:
                                                textTheme.bodySmall?.copyWith(
                                              color: scheme.onSurfaceVariant,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                                FilledButton.tonalIcon(
                                  key: const ValueKey(
                                    'upload_document_equivalents_button',
                                  ),
                                  onPressed:
                                      (_isAnalyzingDocument || _isSubmitting)
                                          ? null
                                          : _uploadAndMatchDocument,
                                  icon: _isAnalyzingDocument
                                      ? const SizedBox(
                                          width: 16,
                                          height: 16,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                          ),
                                        )
                                      : const Icon(
                                          Icons.upload_file_rounded,
                                          size: 18,
                                        ),
                                  label: Text(
                                    _isAnalyzingDocument
                                        ? 'Finding Closest Equivalents…'
                                        : 'Upload Document & Find Closest Vehicles',
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (_isAnalyzingDocument ||
                      _documentSearchError != null ||
                      _documentSearchResult != null) ...[
                    const SizedBox(height: 12),
                    _buildDocumentEquivalentsPanel(scheme, textTheme),
                  ],
                  const SizedBox(height: 12),

                  // Collapsible Dropdown 1: Guest Contact Info (Phone & Email)
                  _buildCollapsibleDropdownSection(
                    dropdownKey: const ValueKey('dropdown_guest_contact'),
                    icon: Icons.contact_phone_outlined,
                    title: 'Guest Contact Info',
                    summaryBadge: _contactSummaryLabel(),
                    hasActiveSelection: _hasContactDetails,
                    isExpanded: _contactDropdownOpen,
                    onToggle: () => setState(
                      () => _contactDropdownOpen = !_contactDropdownOpen,
                    ),
                    scheme: scheme,
                    textTheme: textTheme,
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final wide = constraints.maxWidth > 540;
                        if (wide) {
                          return Row(
                            children: [
                              Expanded(child: _buildPhoneField()),
                              const SizedBox(width: 12),
                              Expanded(child: _buildEmailField()),
                            ],
                          );
                        }
                        return Column(
                          children: [
                            _buildPhoneField(),
                            const SizedBox(height: 12),
                            _buildEmailField(),
                          ],
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 10),

                  // Collapsible Dropdown 2: Trim, Doors, Drivetrain, Bed Length, Year & Mileage
                  _buildCollapsibleDropdownSection(
                    dropdownKey: const ValueKey('dropdown_vehicle_specs'),
                    icon: Icons.tune_rounded,
                    title: 'Trim, Doors, Drivetrain, Year & Mileage',
                    summaryBadge: _specsSummaryLabel(),
                    hasActiveSelection: _hasCustomSpecs,
                    isExpanded: _specsDropdownOpen,
                    onToggle: () => setState(
                      () => _specsDropdownOpen = !_specsDropdownOpen,
                    ),
                    scheme: scheme,
                    textTheme: textTheme,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        LayoutBuilder(
                          builder: (context, constraints) {
                            final wide = constraints.maxWidth > 680;
                            final trimField = TextFormField(
                              controller: _trimCtrl,
                              onChanged: (_) => setState(() {}),
                              decoration: const InputDecoration(
                                labelText: 'Trim / Cab / Series',
                                hintText: 'e.g. XLT, Lariat, Reserve, Big Bend',
                                prefixIcon: Icon(Icons.tune_outlined),
                              ),
                            );
                            final doorsField = DropdownButtonFormField<String>(
                              key: const ValueKey('number_of_doors_field'),
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
                            );
                            final drivetrainField =
                                DropdownButtonFormField<String>(
                              key: const ValueKey('drivetrain_dropdown_field'),
                              isExpanded: true,
                              initialValue: _drivetrain,
                              decoration: const InputDecoration(
                                labelText: 'Drivetrain',
                                prefixIcon: Icon(Icons.settings_outlined),
                              ),
                              items: _drivetrainOptions
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
                                if (v != null) {
                                  setState(() => _drivetrain = v);
                                }
                              },
                            );
                            final bedLengthField =
                                DropdownButtonFormField<String>(
                              key: const ValueKey('bed_length_dropdown_field'),
                              isExpanded: true,
                              initialValue: _bedLength,
                              decoration: const InputDecoration(
                                labelText: 'Truck Bed Length',
                                prefixIcon: Icon(Icons.straighten_outlined),
                              ),
                              items: _bedLengthOptions
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
                                setState(() => _bedLength = v ?? '');
                              },
                            );

                            if (wide) {
                              return Column(
                                children: [
                                  Row(
                                    children: [
                                      Expanded(child: trimField),
                                      const SizedBox(width: 12),
                                      Expanded(child: doorsField),
                                    ],
                                  ),
                                  const SizedBox(height: 12),
                                  Row(
                                    children: [
                                      Expanded(child: drivetrainField),
                                      const SizedBox(width: 12),
                                      Expanded(child: bedLengthField),
                                    ],
                                  ),
                                ],
                              );
                            }
                            return Column(
                              children: [
                                trimField,
                                const SizedBox(height: 12),
                                doorsField,
                                const SizedBox(height: 12),
                                drivetrainField,
                                const SizedBox(height: 12),
                                bedLengthField,
                              ],
                            );
                          },
                        ),
                        const SizedBox(height: 12),
                        LayoutBuilder(
                          builder: (context, constraints) {
                            final wide = constraints.maxWidth > 540;
                            final minYearField = TextFormField(
                              controller: _minYearCtrl,
                              keyboardType: TextInputType.number,
                              onChanged: (_) => setState(() {}),
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
                              onChanged: (_) => setState(() {}),
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
                            final maxMilesField = TextFormField(
                              controller: _maxMileageCtrl,
                              keyboardType: TextInputType.number,
                              onChanged: (_) => setState(() {}),
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
                                  Expanded(child: minYearField),
                                  const SizedBox(width: 12),
                                  Expanded(child: maxYearField),
                                  const SizedBox(width: 12),
                                  Expanded(child: maxMilesField),
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
                                maxMilesField,
                              ],
                            );
                          },
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 10),

                  // Collapsible Dropdown 3: Exterior Colors
                  _buildCollapsibleDropdownSection(
                    dropdownKey: const ValueKey('dropdown_exterior_colors'),
                    icon: Icons.palette_outlined,
                    title: 'Exterior Colors',
                    summaryBadge: _colorsSummaryLabel(),
                    hasActiveSelection: _hasSelectedColors,
                    isExpanded: _colorsDropdownOpen,
                    onToggle: () => setState(
                      () => _colorsDropdownOpen = !_colorsDropdownOpen,
                    ),
                    scheme: scheme,
                    textTheme: textTheme,
                    child: ExteriorColorSelector(
                      selectedColors: _selectedColors,
                      customColorController: _exteriorColorCtrl,
                      compact: true,
                      onChanged: (colors) {
                        setState(() => _selectedColors = colors);
                      },
                    ),
                  ),
                  const SizedBox(height: 10),

                  // Collapsible Dropdown 4: Must-Have Features & Packages
                  _buildCollapsibleDropdownSection(
                    dropdownKey: const ValueKey('dropdown_features'),
                    icon: Icons.checklist_rtl_outlined,
                    title: 'Must-Have Features & Packages',
                    summaryBadge: _featuresSummaryLabel(),
                    hasActiveSelection: _selectedFeatures.isNotEmpty,
                    isExpanded: _featuresDropdownOpen,
                    onToggle: () => setState(
                      () => _featuresDropdownOpen = !_featuresDropdownOpen,
                    ),
                    scheme: scheme,
                    textTheme: textTheme,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
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
                                      () => _selectedFeatures.remove(custom),
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
                                controller: _customFeatureCtrl,
                                onSubmitted: (_) => _addCustomFeature(),
                                decoration: const InputDecoration(
                                  labelText: 'Add Custom Feature Tag',
                                  hintText:
                                      'e.g. Co-Pilot360, 7.3L V8, Panoramic Roof',
                                  prefixIcon: Icon(
                                    Icons.add_circle_outline_rounded,
                                  ),
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
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),

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
                            horizontal: 24,
                            vertical: 15,
                          ),
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
      ),
    );
  }

  Widget _buildCollapsibleDropdownSection({
    required Key dropdownKey,
    required IconData icon,
    required String title,
    required String summaryBadge,
    required bool hasActiveSelection,
    required bool isExpanded,
    required VoidCallback onToggle,
    required ColorScheme scheme,
    required TextTheme textTheme,
    required Widget child,
  }) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            key: dropdownKey,
            onTap: onToggle,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
              child: Row(
                children: [
                  Icon(
                    icon,
                    size: 20,
                    color: hasActiveSelection
                        ? scheme.primary
                        : scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      title,
                      style: textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: hasActiveSelection
                            ? scheme.primaryContainer
                            : scheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Text(
                        summaryBadge,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: textTheme.labelSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                          color: hasActiveSelection
                              ? scheme.onPrimaryContainer
                              : scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  AnimatedRotation(
                    turns: isExpanded ? 0.5 : 0.0,
                    duration: const Duration(milliseconds: 180),
                    child: Icon(
                      Icons.expand_more_rounded,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: isExpanded
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Divider(height: 1, color: scheme.outlineVariant),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
                        child: child,
                      ),
                    ],
                  )
                : const SizedBox.shrink(),
          ),
        ],
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
      onChanged: (_) => setState(() {}),
      decoration: const InputDecoration(
        labelText: 'Phone (Optional)',
        hintText: '(302) 555-0148',
        prefixIcon: Icon(Icons.phone_outlined),
      ),
    );
  }

  Widget _buildEmailField() {
    return TextFormField(
      controller: _emailCtrl,
      keyboardType: TextInputType.emailAddress,
      onChanged: (_) => setState(() {}),
      decoration: const InputDecoration(
        labelText: 'Email (Optional)',
        hintText: 'guest@example.com',
        prefixIcon: Icon(Icons.mail_outline),
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
      'doors': _doors,
      'bedLength': _bedLength,
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
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
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

  Widget _buildDocumentEquivalentsPanel(
    ColorScheme scheme,
    TextTheme textTheme,
  ) {
    final res = _documentSearchResult;
    final currencyFmt = NumberFormat.currency(symbol: '\$', decimalDigits: 0);

    return Card(
      key: const ValueKey('document_equivalents_results_section'),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: scheme.primary.withValues(alpha: 0.35),
          width: 1.4,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              spacing: 10,
              runSpacing: 8,
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: scheme.primaryContainer,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Icon(
                        Icons.auto_awesome,
                        size: 19,
                        color: scheme.onPrimaryContainer,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Flexible(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Closest Equivalent Vehicles Across prestonmotor.com',
                            style: textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          Text(
                            _uploadedDocument != null
                                ? 'Document: ${_uploadedDocument!.fileName} (${_uploadedDocument!.formattedSize})'
                                : (res != null
                                    ? 'Document: ${res.fileName}'
                                    : 'Uploaded Document'),
                            style: textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    if (!_isAnalyzingDocument)
                      OutlinedButton.icon(
                        onPressed: _uploadAndMatchDocument,
                        icon: const Icon(Icons.upload_file_rounded, size: 16),
                        label: const Text('Upload Another'),
                      ),
                    IconButton(
                      tooltip: 'Dismiss Document Results',
                      onPressed: _isAnalyzingDocument
                          ? null
                          : () {
                              setState(() {
                                _uploadedDocument = null;
                                _documentSearchResult = null;
                                _documentSearchError = null;
                              });
                            },
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ],
                ),
              ],
            ),

            if (_isAnalyzingDocument) ...[
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    const SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(strokeWidth: 2.5),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Text(
                        'Gemini is reading ${_uploadedDocument?.fileName ?? 'your document'} and ranking the closest equivalent vehicles across the entire prestonmotor.com inventory…',
                        style: textTheme.bodySmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ] else if (_documentSearchError != null) ...[
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: scheme.errorContainer.withValues(alpha: 0.55),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    Icon(Icons.error_outline_rounded,
                        color: scheme.error, size: 20),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        _documentSearchError!,
                        style: textTheme.bodySmall?.copyWith(
                          color: scheme.onErrorContainer,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ] else if (res != null) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(13),
                decoration: BoxDecoration(
                  color: scheme.secondaryContainer.withValues(alpha: 0.45),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: scheme.primary.withValues(alpha: 0.2),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      alignment: WrapAlignment.spaceBetween,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Wrap(
                          spacing: 8,
                          runSpacing: 6,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: scheme.primary,
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: Text(
                                '${res.equivalents.length} Closest Equivalent${res.equivalents.length == 1 ? '' : 's'}',
                                style: textTheme.labelSmall?.copyWith(
                                  color: scheme.onPrimary,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: scheme.surface,
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: Text(
                                '${NumberFormat.decimalPattern().format(res.totalInventoryScanned)} prestonmotor.com Vehicles Scanned',
                                style: textTheme.labelSmall?.copyWith(
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                            Text(
                              'via ${res.agentMode}',
                              style: textTheme.labelSmall?.copyWith(
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                        FilledButton.tonalIcon(
                          key: const ValueKey('apply_document_specs_button'),
                          onPressed: () =>
                              _applyExtractedSpecsToForm(res.referenceVehicle),
                          icon: const Icon(Icons.playlist_add_check_rounded,
                              size: 18),
                          label: const Text('Apply Specs to Form'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      res.overallSummary.isNotEmpty
                          ? res.overallSummary
                          : res.documentSummary,
                      style: textTheme.bodySmall?.copyWith(height: 1.4),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        if (res.referenceVehicle.year != null)
                          _docSpecPill(
                            scheme,
                            textTheme,
                            'Target Year: ${res.referenceVehicle.year}',
                          ),
                        if (res.referenceVehicle.make.isNotEmpty ||
                            res.referenceVehicle.model.isNotEmpty)
                          _docSpecPill(
                            scheme,
                            textTheme,
                            'Reference: ${res.referenceVehicle.make} ${res.referenceVehicle.model} ${res.referenceVehicle.trim}'
                                .trim(),
                          ),
                        if (res.referenceVehicle.bodyCategory.isNotEmpty)
                          _docSpecPill(
                            scheme,
                            textTheme,
                            'Class: ${res.referenceVehicle.bodyCategory}',
                          ),
                        if (res.referenceVehicle.powertrain.isNotEmpty &&
                            res.referenceVehicle.powertrain != 'Any')
                          _docSpecPill(
                            scheme,
                            textTheme,
                            'Powertrain: ${res.referenceVehicle.powertrain}',
                          ),
                        if (res.referenceVehicle.drivetrain.isNotEmpty &&
                            res.referenceVehicle.drivetrain != 'Any')
                          _docSpecPill(
                            scheme,
                            textTheme,
                            'Drivetrain: ${res.referenceVehicle.drivetrain}',
                          ),
                        if (res.referenceVehicle.targetPrice != null)
                          _docSpecPill(
                            scheme,
                            textTheme,
                            'Target Price: ${currencyFmt.format(res.referenceVehicle.targetPrice)}',
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              if (res.equivalents.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                    'No live inventory vehicles were returned from prestonmotor.com right now. Please try again in a moment.',
                    style: textTheme.bodySmall,
                  ),
                )
              else
                Column(
                  key: const ValueKey('document_equivalent_matches_list'),
                  children: res.equivalents
                      .map(
                        (eq) => _buildEquivalentVehicleCard(
                          eq,
                          scheme,
                          textTheme,
                          currencyFmt,
                        ),
                      )
                      .toList(),
                ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _docSpecPill(
    ColorScheme scheme,
    TextTheme textTheme,
    String text,
  ) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Text(
        text,
        style: textTheme.labelSmall?.copyWith(fontWeight: FontWeight.w600),
      ),
    );
  }

  Widget _buildEquivalentVehicleCard(
    EquivalentVehicleMatch eq,
    ColorScheme scheme,
    TextTheme textTheme,
    NumberFormat currencyFmt,
  ) {
    final resolvedPhoto = ApiService.resolveVehiclePhotoUrl(eq.photoUrl);
    final isExactOrSameModel = eq.matchTier.toLowerCase().contains('exact') ||
        eq.matchTier.toLowerCase().contains('same model');

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Container(
        key: ValueKey('equivalent_vehicle_card_${eq.vin}'),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerLowest,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: isExactOrSameModel
                ? const Color(0xFF146C2E).withValues(alpha: 0.45)
                : scheme.outlineVariant,
            width: isExactOrSameModel ? 1.3 : 1.0,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (resolvedPhoto.isNotEmpty) ...[
                  ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: Image.network(
                      resolvedPhoto,
                      width: 108,
                      height: 80,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => Container(
                        width: 108,
                        height: 80,
                        color: scheme.surfaceContainerHighest,
                        child: Icon(
                          Icons.directions_car_filled_rounded,
                          color: scheme.primary,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        spacing: 8,
                        runSpacing: 5,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 9,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: isExactOrSameModel
                                  ? const Color(0xFF146C2E)
                                  : scheme.primary,
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Text(
                              '${eq.similarityScore}% Closest Match',
                              style: textTheme.labelSmall?.copyWith(
                                color: Colors.white,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color: scheme.secondaryContainer,
                              borderRadius: BorderRadius.circular(16),
                            ),
                            child: Text(
                              eq.matchTier,
                              style: textTheme.labelSmall?.copyWith(
                                color: scheme.onSecondaryContainer,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          if (eq.condition.isNotEmpty)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 3,
                              ),
                              decoration: BoxDecoration(
                                color: scheme.surfaceContainerHighest,
                                borderRadius: BorderRadius.circular(16),
                              ),
                              child: Text(
                                eq.condition,
                                style: textTheme.labelSmall?.copyWith(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(
                        eq.title,
                        style: textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Wrap(
                        spacing: 12,
                        runSpacing: 4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text(
                            eq.price != null
                                ? currencyFmt.format(eq.price)
                                : 'Call for Price',
                            style: textTheme.titleSmall?.copyWith(
                              color: scheme.primary,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.location_on_outlined,
                                size: 15,
                                color: scheme.onSurfaceVariant,
                              ),
                              const SizedBox(width: 3),
                              Text(
                                eq.location,
                                style: textTheme.bodySmall?.copyWith(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                          if (eq.mileage > 0)
                            Text(
                              '${NumberFormat.decimalPattern().format(eq.mileage)} mi',
                              style: textTheme.bodySmall?.copyWith(
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                CopyableIdentifierBadge.vin(eq.vin, compact: true),
                if (eq.stockNumber.isNotEmpty)
                  CopyableIdentifierBadge.stock(eq.stockNumber, compact: true),
              ],
            ),
            if (eq.whyEquivalent.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                eq.whyEquivalent,
                style: textTheme.bodySmall?.copyWith(height: 1.38),
              ),
            ],
            if (eq.matchingHighlights.isNotEmpty) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 5,
                children: eq.matchingHighlights
                    .map(
                      (h) => Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFFE6F4EA),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          '✓ $h',
                          style: textTheme.labelSmall?.copyWith(
                            color: const Color(0xFF0F5223),
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    )
                    .toList(),
              ),
            ],
            if (eq.keyDifferences.isNotEmpty) ...[
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 5,
                children: eq.keyDifferences
                    .map(
                      (diff) => Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: scheme.surfaceContainerHighest
                              .withValues(alpha: 0.7),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          'Note: $diff',
                          style: textTheme.labelSmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    )
                    .toList(),
              ),
            ],
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.tonalIcon(
                  key: ValueKey('use_equivalent_vehicle_${eq.vin}'),
                  onPressed: () => _applyEquivalentVehicleToForm(eq),
                  icon: const Icon(Icons.edit_note_rounded, size: 17),
                  label: const Text('Use This Vehicle in Search Form'),
                ),
                if (eq.listingUrl.isNotEmpty)
                  OutlinedButton.icon(
                    onPressed: () => _openVehicleListingUrl(eq.listingUrl),
                    icon: const Icon(Icons.open_in_new, size: 15),
                    label: const Text('View on prestonmotor.com'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

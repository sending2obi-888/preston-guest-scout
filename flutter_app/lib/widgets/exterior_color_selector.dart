import 'package:material_ui/material_ui.dart';
import '../services/natural_language_parser.dart';

class ExteriorColorSwatchOption {
  final String label;
  final Color swatchColor;

  const ExteriorColorSwatchOption(this.label, this.swatchColor);
}

/// Multi-select exterior color picker allowing guests to choose one or multiple
/// acceptable exterior colors (plus optional custom OEM paint names) during initial search.
class ExteriorColorSelector extends StatelessWidget {
  static const List<ExteriorColorSwatchOption> presetOptions = [
    ExteriorColorSwatchOption('White', Color(0xFFF8F9FA)),
    ExteriorColorSwatchOption('Black', Color(0xFF1F2328)),
    ExteriorColorSwatchOption('Gray', Color(0xFF6E7781)),
    ExteriorColorSwatchOption('Silver', Color(0xFFC9D1D9)),
    ExteriorColorSwatchOption('Blue', Color(0xFF1A73E8)),
    ExteriorColorSwatchOption('Red', Color(0xFFD93025)),
    ExteriorColorSwatchOption('Green', Color(0xFF1E8E3E)),
    ExteriorColorSwatchOption('Brown', Color(0xFF6D4C41)),
    ExteriorColorSwatchOption('Tan', Color(0xFFD2B48C)),
    ExteriorColorSwatchOption('Gold', Color(0xFFD4AF37)),
    ExteriorColorSwatchOption('Burgundy', Color(0xFF7B1E3A)),
    ExteriorColorSwatchOption('Orange', Color(0xFFE8710A)),
    ExteriorColorSwatchOption('Yellow', Color(0xFFF9AB00)),
  ];

  final List<String> selectedColors;
  final TextEditingController customColorController;
  final ValueChanged<List<String>> onChanged;
  final bool compact;

  const ExteriorColorSelector({
    super.key,
    required this.selectedColors,
    required this.customColorController,
    required this.onChanged,
    this.compact = false,
  });

  /// Combines selected color chips and any unsubmitted custom color text into a
  /// normalized comma-separated string (e.g. `"White, Blue, Gray"`).
  static String combineSelectedAndTyped(
    Iterable<String> selected,
    String typedText,
  ) {
    final combined = NaturalLanguageVehicleParser.parseExteriorColors([
      ...selected,
      typedText,
    ]);
    return combined.join(', ');
  }

  bool _containsColor(String label) {
    final lower = label.toLowerCase();
    return selectedColors.any((c) => c.toLowerCase() == lower);
  }

  void _toggleColor(String label) {
    final lower = label.toLowerCase();
    final next = [...selectedColors];
    final existingIdx = next.indexWhere((c) => c.toLowerCase() == lower);
    if (existingIdx >= 0) {
      next.removeAt(existingIdx);
    } else {
      next.add(label);
    }
    onChanged(next);
  }

  void _addTypedCustomColors() {
    final raw = customColorController.text.trim();
    if (raw.isEmpty) return;
    final parsedNew = NaturalLanguageVehicleParser.parseExteriorColors(raw);
    if (parsedNew.isEmpty) {
      customColorController.clear();
      return;
    }
    final next = NaturalLanguageVehicleParser.parseExteriorColors([
      ...selectedColors,
      ...parsedNew,
    ]);
    customColorController.clear();
    onChanged(next);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final presetLowerSet =
        presetOptions.map((o) => o.label.toLowerCase()).toSet();
    final customSelected = selectedColors
        .where((c) => !presetLowerSet.contains(c.toLowerCase()))
        .toList();

    return Container(
      key: const ValueKey('multi_exterior_color_selector'),
      padding: EdgeInsets.all(compact ? 12 : 14),
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
            runSpacing: 6,
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.palette_outlined, size: 18, color: scheme.primary),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      'Exterior Colors (Optional — Choose One or Multiple)',
                      style: textTheme.labelLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                    decoration: BoxDecoration(
                      color: selectedColors.isEmpty
                          ? scheme.surfaceContainerHighest
                          : scheme.primaryContainer,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      selectedColors.isEmpty
                          ? 'Any Color'
                          : '${selectedColors.length} selected (matches any)',
                      style: textTheme.labelSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: selectedColors.isEmpty
                            ? scheme.onSurfaceVariant
                            : scheme.onPrimaryContainer,
                      ),
                    ),
                  ),
                  if (selectedColors.isNotEmpty) ...[
                    const SizedBox(width: 6),
                    TextButton(
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                      ),
                      onPressed: () {
                        customColorController.clear();
                        onChanged(const []);
                      },
                      child: const Text('Clear Colors'),
                    ),
                  ],
                ],
              ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              ...presetOptions.map((opt) {
                final selected = _containsColor(opt.label);
                return FilterChip(
                  key: ValueKey('color_chip_${opt.label.toLowerCase()}'),
                  visualDensity: compact
                      ? VisualDensity.compact
                      : VisualDensity.standard,
                  avatar: Container(
                    width: 14,
                    height: 14,
                    decoration: BoxDecoration(
                      color: opt.swatchColor,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: scheme.outline.withValues(alpha: 0.65),
                        width: 1,
                      ),
                    ),
                  ),
                  label: Text(opt.label),
                  selected: selected,
                  onSelected: (_) => _toggleColor(opt.label),
                );
              }),
              ...customSelected.map((custom) {
                return InputChip(
                  key: ValueKey('custom_color_chip_${custom.toLowerCase()}'),
                  visualDensity: compact
                      ? VisualDensity.compact
                      : VisualDensity.standard,
                  avatar: Icon(
                    Icons.color_lens_outlined,
                    size: 16,
                    color: scheme.primary,
                  ),
                  label: Text(custom),
                  selected: true,
                  onDeleted: () => _toggleColor(custom),
                );
              }),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: TextField(
                  key: const ValueKey('custom_exterior_color_input'),
                  controller: customColorController,
                  onSubmitted: (_) => _addTypedCustomColors(),
                  decoration: InputDecoration(
                    isDense: true,
                    labelText:
                        'Add Custom Paint Color(s) (e.g. Oxford White, Rapid Red)',
                    prefixIcon:
                        const Icon(Icons.format_paint_outlined, size: 18),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton.tonalIcon(
                key: const ValueKey('add_custom_color_button'),
                onPressed: _addTypedCustomColors,
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Add Color'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

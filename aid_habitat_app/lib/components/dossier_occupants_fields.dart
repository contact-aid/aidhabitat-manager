import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../models/types.dart';
import '../models/dossier_occupants.dart';
import 'brand_colors.dart';
import 'cta_text_style.dart';
import 'form_widgets.dart';

/// Identity rows in the dossier's Bénéficiaire card.
class DossierOccupantsFields extends StatelessWidget {
  final List<Occupant> occupants;
  final bool locked;
  final void Function(int index, Occupant occupant) onChanged;
  final VoidCallback onAdd;
  final ValueChanged<int>? onRemove;

  const DossierOccupantsFields({
    super.key,
    required this.occupants,
    required this.locked,
    required this.onChanged,
    required this.onAdd,
    this.onRemove,
  });

  Widget _name(int index, Occupant occupant, {required bool lastName}) {
    final label = lastName ? 'Nom' : 'Prénom';
    final value = lastName ? occupant.lastName : occupant.firstName;
    return Builder(
      builder: (context) => FormTextField(
        key: ValueKey('occupant-$index-${lastName ? 'lastName' : 'firstName'}'),
        label: label,
        value: value,
        labelColor: kBrandPurple,
        labelSize: 16,
        valueSize: 16,
        onFocused: () => Scrollable.ensureVisible(
          context,
          duration: const Duration(milliseconds: 200),
          alignment: 0.3,
        ),
        onChanged: (value) => onChanged(
          index,
          lastName
              ? occupants[index].copyWith(lastName: value)
              : occupants[index].copyWith(firstName: value),
        ),
      ),
    );
  }

  Widget _gender(BuildContext context, int index, Occupant occupant) {
    final value = occupant.gender ?? '';
    // Match the adjacent FormTextField: 16 px text with 10 px above/below.
    final fieldStyle =
        (Theme.of(context).textTheme.bodyLarge ?? const TextStyle()).copyWith(
          fontSize: 16,
          color: const Color(0xFF2B323A),
        );
    final metrics = TextPainter(
      text: TextSpan(text: 'Monsieur', style: fieldStyle),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
    )..layout();
    final fieldHeight = metrics.height + 20.0;
    metrics.dispose();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Civilité',
          style: TextStyle(
            color: kBrandPurple,
            fontSize: 16,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 5),
        Theme(
          data: Theme.of(context).copyWith(
            focusColor: const Color(0xFFEDE4F3),
            hoverColor: const Color(0xFFF0E8F6),
          ),
          child: SizedBox(
            height: fieldHeight,
            child: DropdownButtonFormField<String>(
              key: ValueKey('occupant-$index-gender-$value'),
              borderRadius: BorderRadius.circular(16),
              dropdownColor: const Color(0xFFF4EFF8),
              focusColor: const Color(0xFFEDE4F3),
              isExpanded: true,
              isDense: true,
              iconSize: 18,
              style: fieldStyle,
              initialValue: value,
              items: const [
                DropdownMenuItem(value: 'Homme', child: Text('Monsieur')),
                DropdownMenuItem(value: 'Femme', child: Text('Madame')),
                DropdownMenuItem(value: '', child: Text('Non précisé')),
              ],
              selectedItemBuilder: (_) => const [
                Align(alignment: Alignment.centerLeft, child: Text('Monsieur')),
                Align(alignment: Alignment.centerLeft, child: Text('Madame')),
                SizedBox.shrink(),
              ],
              onChanged: (next) {
                if (next != null) {
                  onChanged(index, occupants[index].copyWith(gender: next));
                }
              },
              decoration: InputDecoration(
                isDense: true,
                filled: true,
                fillColor: const Color(0xFFF7F7FA),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(18),
                  borderSide: const BorderSide(color: Color(0xFFE4E7EB)),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(18),
                  borderSide: const BorderSide(color: Color(0xFFE4E7EB)),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(18),
                  borderSide: const BorderSide(color: kBrandPurple, width: 1.5),
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 10,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      if (locked) ...[
        Text(
          occupants.length > 1 ? 'Occupants' : 'Occupant',
          style: const TextStyle(
            color: kBrandPurple,
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 10),
      ],
      for (var index = 0; index < occupants.length; index++)
        Padding(
          key: ValueKey('occupant-row-$index'),
          padding: const EdgeInsets.only(bottom: 16),
          child: locked
              ? Text(
                  dossierOccupantDisplayName(occupants[index], index),
                  style: GoogleFonts.nunito(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: const Color(0xFF0E1116),
                    height: 1.2,
                  ),
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Occupant ${index + 1}',
                      style: const TextStyle(
                        color: kBrandPurple,
                        fontWeight: FontWeight.w600,
                        fontSize: 16,
                      ),
                    ),
                    const SizedBox(height: 8),
                    LayoutBuilder(
                      builder: (context, constraints) {
                        final names = Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: _name(
                                index,
                                occupants[index],
                                lastName: true,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: _name(
                                index,
                                occupants[index],
                                lastName: false,
                              ),
                            ),
                          ],
                        );
                        final gender = _gender(
                          context,
                          index,
                          occupants[index],
                        );
                        if (constraints.maxWidth < 520) {
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              names,
                              const SizedBox(height: 10),
                              Row(
                                children: [
                                  SizedBox(width: 180, child: gender),
                                  const Spacer(),
                                  if (occupants.length > 1 && onRemove != null)
                                    _removeButton(index),
                                ],
                              ),
                            ],
                          );
                        }
                        return Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(child: names),
                            const SizedBox(width: 12),
                            SizedBox(width: 155, child: gender),
                            if (occupants.length > 1 && onRemove != null) ...[
                              const SizedBox(width: 8),
                              _removeButton(index),
                            ],
                          ],
                        );
                      },
                    ),
                    const SizedBox(height: 10),
                    FormTextField(
                      key: ValueKey('occupant-$index-maidenName'),
                      label: 'Nom de naissance',
                      value: occupants[index].maidenName ?? '',
                      labelColor: kBrandPurple,
                      labelSize: 16,
                      valueSize: 16,
                      onChanged: (value) => onChanged(
                        index,
                        occupants[index].copyWith(maidenName: value),
                      ),
                    ),
                  ],
                ),
        ),
      if (!locked)
        Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: Semantics(
            button: true,
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: onAdd,
                borderRadius: BorderRadius.circular(999),
                child: Ink(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF2ECF5),
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(
                      color: const Color(0xFFD8D0DC),
                      width: 1.5,
                    ),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.add, size: 16, color: Color(0xFF554265)),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          'Ajouter un occupant',
                          textAlign: TextAlign.center,
                          style: kCtaTextStyle.copyWith(
                            color: const Color(0xFF554265),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
    ],
  );

  Widget _removeButton(int index) => IconButton(
    key: ValueKey('occupant-$index-remove'),
    tooltip: 'Retirer l’occupant ${index + 1}',
    onPressed: () => onRemove?.call(index),
    icon: const Icon(Icons.remove, size: 18),
    color: const Color(0xFF554265),
    style: IconButton.styleFrom(
      backgroundColor: const Color(0xFFF2ECF5),
      side: const BorderSide(color: Color(0xFFD8D0DC)),
    ),
  );
}

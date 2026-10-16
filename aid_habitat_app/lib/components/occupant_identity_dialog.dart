import 'package:flutter/material.dart';

import '../models/types.dart';
import 'form_widgets.dart';

/// Edits a local copy. Only Enregistrer returns identities to the patient form.
class OccupantIdentityDialog extends StatefulWidget {
  final List<Occupant> occupants;
  final int initialIndex;

  const OccupantIdentityDialog({
    super.key,
    required this.occupants,
    required this.initialIndex,
  });

  @override
  State<OccupantIdentityDialog> createState() => _OccupantIdentityDialogState();
}

class _OccupantIdentityDialogState extends State<OccupantIdentityDialog> {
  late final List<Occupant> _draft = List.of(widget.occupants);
  late int _index = widget.initialIndex.clamp(0, _draft.length - 1);

  void _update(Occupant Function(Occupant) edit) {
    setState(() => _draft[_index] = edit(_draft[_index]));
  }

  @override
  Widget build(BuildContext context) {
    final occupant = _draft[_index];
    return AlertDialog(
      title: const Text('Modifier les occupants'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (var i = 0; i < _draft.length; i++)
                    ChoiceChip(
                      label: Text('Occupant ${i + 1}'),
                      selected: i == _index,
                      onSelected: (_) => setState(() => _index = i),
                    ),
                  TextButton.icon(
                    key: const ValueKey('add-occupant'),
                    icon: const Icon(Icons.person_add_outlined),
                    label: const Text('Ajouter un occupant'),
                    onPressed: () => setState(() {
                      _draft.add(const Occupant());
                      _index = _draft.length - 1;
                    }),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              // Recreate field state when switching people, keeping drafts intact.
              Column(
                key: ValueKey('identity-fields-$_index'),
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  FormTextField(
                    key: const ValueKey('identity-last-name'),
                    label: 'Nom',
                    value: occupant.lastName,
                    onChanged: (value) =>
                        _update((o) => o.copyWith(lastName: value)),
                  ),
                  const SizedBox(height: 12),
                  FormTextField(
                    key: const ValueKey('identity-first-name'),
                    label: 'Prénom',
                    value: occupant.firstName,
                    onChanged: (value) =>
                        _update((o) => o.copyWith(firstName: value)),
                  ),
                  const SizedBox(height: 12),
                  FormToggleGroup(
                    label: 'Civilité',
                    options: const ['Monsieur', 'Madame', 'Non précisé'],
                    selected: switch (occupant.gender) {
                      'Homme' => 'Monsieur',
                      'Femme' => 'Madame',
                      _ => 'Non précisé',
                    },
                    onChanged: (value) => _update(
                      (o) => o.copyWith(
                        gender: switch (value) {
                          'Monsieur' => 'Homme',
                          'Madame' => 'Femme',
                          _ => '',
                        },
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  FormTextField(
                    key: const ValueKey('identity-maiden-name'),
                    label: 'Nom de naissance',
                    value: occupant.maidenName ?? '',
                    onChanged: (value) =>
                        _update((o) => o.copyWith(maidenName: value)),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Annuler'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _draft),
          child: const Text('Enregistrer'),
        ),
      ],
    );
  }
}

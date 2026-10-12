import 'package:flutter/material.dart';

const _fieldLabels = <String, String>{
  'prenom': 'Prénom',
  'nom': 'Nom',
  'telephone': 'Téléphone',
  'mail': 'Adresse mail',
  'adresse_logement': 'Adresse',
  'ville_libre': 'Commune',
  'code_postal_libre': 'Code postal',
  'nombre_personnes': 'Occupants',
  'revenu_fiscal_reference': 'Revenu fiscal',
  'date_naissance_monsieur': 'Date de naissance',
  'date_naissance_madame': 'Date de naissance',
  'categorie_revenu_id1': 'Catégorie de revenus',
  'statut_occupation_id1': 'Statut d’occupation',
  'visit_date': 'Date de visite',
  'nature_accompagnement': 'Type d’accompagnement',
  'status': 'Statut du dossier',
  'type_de_logement_id': 'Type de logement',
  'annee_construction': 'Année de construction',
  'annee_habitation': 'Année d’achat du logement',
  'note': 'Note du dossier',
  'noteBeneficiaire': 'Note Bénéficiaire',
};

String _summary(Map<String, dynamic> item) {
  final fields = item['fields'];
  if (fields is! Map) return '';
  final labels = <String>[];
  for (final entry in fields.entries) {
    if (entry.key == 'note' || entry.key == 'noteBeneficiaire') {
      final note = entry.value.toString().replaceAll(RegExp(r'\s+'), ' ');
      labels.add(
        '${_fieldLabels[entry.key]} : ${note.isEmpty
            ? '(vide)'
            : note.length > 70
            ? '${note.substring(0, 70)}…'
            : note}',
      );
      continue;
    }
    final section = entry.value;
    if (section is! Map) continue;
    for (final value in section.entries) {
      final field = value.key.toString();
      if (field == 'ergo_id') {
        final previous = (item['previousOwner'] ?? '').toString();
        final target = (item['profile'] ?? '').toString();
        labels.add(
          previous.isEmpty
              ? 'Attribution à $target'
              : 'Réattribution : $previous → $target',
        );
      } else {
        final label = _fieldLabels[field] ?? field;
        final detail = value.value;
        labels.add(
          detail is String && detail.isNotEmpty ? '$label : $detail' : label,
        );
      }
    }
  }
  return labels.toSet().join(' · ');
}

Future<List<String>?> showDossierRefreshPreviewDialog(
  BuildContext context,
  Map<String, dynamic> preview,
) {
  final items = ((preview['items'] as List?) ?? const [])
      .whereType<Map>()
      .map((item) => Map<String, dynamic>.from(item))
      .toList();
  final selected = items.map((item) => item['id'].toString()).toSet();
  final skippedCount = ((preview['skipped'] as List?) ?? const []).length;
  return showDialog<List<String>>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) => StatefulBuilder(
      builder: (dialogContext, setDialogState) => AlertDialog(
        title: const Text('Prévisualiser l’actualisation'),
        content: SizedBox(
          width: 760,
          height: items.isEmpty ? 110 : 480,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                items.isEmpty
                    ? 'Aucun changement à appliquer. Les données actuelles sont conservées.'
                    : '${items.length} dossier${items.length > 1 ? 's' : ''} à actualiser. Décochez ceux à exclure.',
              ),
              if (skippedCount > 0) ...[
                const SizedBox(height: 6),
                Text(
                  '$skippedCount élément${skippedCount > 1 ? 's' : ''} non importable${skippedCount > 1 ? 's' : ''}.',
                  style: Theme.of(dialogContext).textTheme.bodySmall,
                ),
              ],
              const SizedBox(height: 12),
              if (items.isNotEmpty)
                Expanded(
                  child: ListView.builder(
                    itemCount: items.length,
                    itemBuilder: (context, index) {
                      final item = items[index];
                      final id = item['id'].toString();
                      final name = (item['name'] ?? id).toString();
                      final profile = (item['profile'] ?? '').toString();
                      final action = item['kind'] == 'create'
                          ? 'Nouveau dossier'
                          : 'Dossier existant';
                      return CheckboxListTile(
                        value: selected.contains(id),
                        onChanged: (checked) => setDialogState(() {
                          if (checked == true) {
                            selected.add(id);
                          } else {
                            selected.remove(id);
                          }
                        }),
                        title: Text('$name · $profile'),
                        subtitle: Text('$action — ${_summary(item)}'),
                        isThreeLine: false,
                        controlAffinity: ListTileControlAffinity.leading,
                      );
                    },
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(items.isEmpty ? 'Fermer' : 'Conserver l’original'),
          ),
          if (items.isEmpty)
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(<String>[]),
              child: const Text('Recharger les dossiers'),
            ),
          if (items.isNotEmpty)
            FilledButton(
              onPressed: selected.isEmpty
                  ? null
                  : () => Navigator.of(dialogContext).pop(selected.toList()),
              child: Text(
                selected.length == items.length
                    ? 'Tout valider'
                    : 'Valider ${selected.length} dossier${selected.length > 1 ? 's' : ''}',
              ),
            ),
        ],
      ),
    ),
  );
}

/// Valeur conservée par le serveur avant qu'un envoi la remplace
/// (étape 1 du plan de synchronisation). Lecture seule côté app : seule la
/// restauration passe par le serveur, qui archive à son tour la valeur
/// remplacée.
class SyncArchiveEntry {
  const SyncArchiveEntry({
    required this.id,
    required this.archivedAt,
    required this.source,
    required this.tableLabel,
    required this.field,
    required this.previous,
    required this.next,
    this.beneficiaryName,
    this.dossierId,
    this.actor,
    this.restoredAt,
  });

  final String id;
  final DateTime? archivedAt;

  /// `guarded` (champ simple), `context` (section du contexte de vie) ou
  /// `restore` (valeur remplacée par une restauration).
  final String source;
  final String tableLabel;
  final String field;
  final Object? previous;
  final Object? next;
  final String? beneficiaryName;
  final String? dossierId;
  final String? actor;
  final DateTime? restoredAt;

  bool get isRestored => restoredAt != null;

  factory SyncArchiveEntry.fromJson(Map<String, dynamic> json) {
    DateTime? date(Object? value) =>
        value == null ? null : DateTime.tryParse(value.toString())?.toLocal();
    String? text(Object? value) {
      final s = value?.toString().trim() ?? '';
      return s.isEmpty ? null : s;
    }

    return SyncArchiveEntry(
      id: json['id']?.toString() ?? '',
      archivedAt: date(json['archivedAt']),
      source: json['source']?.toString() ?? '',
      tableLabel:
          text(json['tableLabel']) ?? text(json['tableId']) ?? 'Fiche',
      field: json['field']?.toString() ?? '',
      previous: json['previous'],
      next: json['next'],
      beneficiaryName: text(json['beneficiaryName']),
      dossierId: text(json['dossierId']),
      actor: text(json['actor']),
      restoredAt: date(json['restoredAt']),
    );
  }
}

/// Rend une valeur archivée lisible : texte tel quel, oui/non, listes et
/// sections (contexte de vie) en lignes « clé : valeur ».
String describeArchivedValue(Object? value) {
  if (value == null) return '(vide)';
  if (value is bool) return value ? 'Oui' : 'Non';
  if (value is String) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return '(vide)';
    if (trimmed == 'true') return 'Oui';
    if (trimmed == 'false') return 'Non';
    return trimmed;
  }
  if (value is List) {
    if (value.isEmpty) return '(vide)';
    return value.map(describeArchivedValue).join(' • ');
  }
  if (value is Map) {
    final lines = value.entries
        .where((e) => e.value != null && '${e.value}'.trim().isNotEmpty)
        .map((e) => '${e.key} : ${describeArchivedValue(e.value)}')
        .toList();
    return lines.isEmpty ? '(vide)' : lines.join('\n');
  }
  return value.toString();
}

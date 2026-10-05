/// A legacy note may still be stored under its patient rather than its dossier.
/// Only an unchanged, exactly identified revision can repair that routing.
/// Our own write id also permits an idempotent retry after a lost ACK; the
/// server still checks the complete desired payload before acknowledging it.
/// Never turn a missing update into a create or rebase another writer's edit.
bool matchesLegacyNoteIdentity({
  required Map<String, dynamic> remote,
  required String patientId,
  required String dossierId,
  required String scopeType,
  required String tabKey,
  required int pageNumber,
  required String? expectedRevision,
  String? writeId,
}) =>
    !const {'Bénéficiaire-Notes', 'notes_rapides'}.contains(tabKey) &&
    expectedRevision != null &&
    expectedRevision.isNotEmpty &&
    dossierId.isNotEmpty &&
    dossierId != patientId &&
    remote['patientId'] == patientId &&
    remote['dossierId'] == dossierId &&
    remote['scopeType'] == scopeType &&
    remote['scopeId'] == patientId &&
    remote['tabKey'] == tabKey &&
    (remote['subTabKey'] == null || remote['subTabKey'] == '') &&
    int.tryParse('${remote['pageNumber']}') == pageNumber &&
    (remote['revision'] == expectedRevision ||
        (writeId != null &&
            writeId.isNotEmpty &&
            remote['revision'] == writeId));

String defaultNoteScopeType(String tabKey) => tabKey == 'Plans'
    ? 'visit_grid'
    : const {
        'Bénéficiaire',
        'Contexte de vie',
        'Mesures',
        'Accessibilité',
        'Salle de bain',
        'WC',
        'Préconisations',
      }.contains(tabKey)
    ? 'visit_report'
    : 'dossier_detail';

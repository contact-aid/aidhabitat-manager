const field = (record, name) => record?.fields?.[name];

const latestRecord = (records) => {
  const sorted = [...records].sort((a, b) => {
    const aDate = new Date(
      field(a, 'UpdatedAt')
        || field(a, 'updated_at')
        || field(a, 'created_at')
        || 0,
    ).getTime();
    const bDate = new Date(
      field(b, 'UpdatedAt')
        || field(b, 'updated_at')
        || field(b, 'created_at')
        || 0,
    ).getTime();
    if (aDate !== bDate) return bDate - aDate;
    return Number(b.id) - Number(a.id);
  });
  return sorted[0];
};

export const dossierIdWhere = (dossierId) => (
  `(dossier_id,eq,${JSON.stringify(String(dossierId))})`
);

export const latestDossierRecord = (records, dossierId) => latestRecord(
  records.filter(
    (record) => String(field(record, 'dossier_id') ?? '') === String(dossierId ?? ''),
  ),
);

/**
 * Resolves and authorizes the dossier before reading its scoped business row.
 * Keeping the final equality check protects dossier isolation even if a remote
 * filter unexpectedly returns unrelated rows.
 */
export const readAuthorizedDossierRecord = async ({
  appUser,
  requestedDossierId,
  ensureDossierRecord,
  canAccessDossierRecord,
  queryAll,
  tableId,
  fields,
}) => {
  const dossierRecord = await ensureDossierRecord(requestedDossierId);
  if (!canAccessDossierRecord(appUser, dossierRecord)) {
    return {
      accessAllowed: false,
      dossierRecord,
      record: null,
    };
  }

  const canonicalDossierId = field(dossierRecord, 'uuid_source') || requestedDossierId;
  const records = await queryAll(tableId, {
    fields,
    where: dossierIdWhere(canonicalDossierId),
  });

  return {
    accessAllowed: true,
    dossierRecord,
    record: latestDossierRecord(records, canonicalDossierId) || null,
  };
};

// This is routing, not conflict resolution: the caller must still compare the
// revision and perform its conditional write against that same revision.
export function selectLegacyNoteAlias(records, address) {
  if (!Array.isArray(records) || records.length !== 1) return null;
  const record = records[0], f = record.fields;
  if (!f || !address.dossierId || address.dossierId === address.patientId
    || ['Bénéficiaire-Notes', 'notes_rapides'].includes(address.tabKey)) return null;
  const exact = {
    beneficiaire_id: address.patientId, dossier_id: address.dossierId,
    scope_type: address.scopeType || 'legacy', scope_id: address.patientId,
    tab_key: address.tabKey, sub_tab_key: address.subTabKey || '',
  };
  if (!Object.entries(exact).every(([k,v]) => String(f[k] ?? '') === String(v))) return null;
  if (Number(f.page_number) !== Number(address.pageNumber)) return null;
  return record;
}

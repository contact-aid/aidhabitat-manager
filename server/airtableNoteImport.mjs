import crypto from 'node:crypto';
import { planIndependentNotes, DOSSIER_NOTE } from './independentNotes.mjs';
import { isCurrentAdaptationDossier, projectAirtableDossier } from './airtableAdaptation.mjs';

const value = (row, key) => row?.fields?.[key] ?? row?.[key];
const plain = (input) => String(input ?? '').trim();

// A stable identity makes a retry safe even if the first response is lost.
export const importedNoteId = (airtableRecordId) => {
  const hash = crypto.createHash('sha256')
    .update(`aidhabitat:airtable-note:${airtableRecordId}`).digest('hex');
  return `${hash.slice(0, 8)}-${hash.slice(8, 12)}-5${hash.slice(13, 16)}-a${hash.slice(17, 20)}-${hash.slice(20, 32)}`;
};
// Initialize two independent pages once. Later edits and intentional blanks
// belong to the user, never to the Airtable refresh.
export async function importCurrentProfileNotes({
  ergoLabel,
  sourceRows, dossierRows, beneficiaryRows, listNotePages, upsertNotePage,
  maxChanges = 5, dryRun = false, selectedIds = null, pendingCreateIds = null,
  pendingReassignIds = null,
}) {
  const dossiers = new Map(dossierRows.map((row) => [plain(value(row, 'uuid_source')), row]));
  const beneficiaries = new Map(beneficiaryRows.map((row) => [String(row.id), row]));
  const operations = [];
  const skipped = [];
  let alreadyPresent = 0;
  if (!ergoLabel?.trim()) throw new TypeError('Profil intervenant requis');
  const eligible = sourceRows.filter(isCurrentAdaptationDossier)
    .map((row) => projectAirtableDossier(row));

  for (const source of eligible) {
    if (selectedIds && !selectedIds.has(source.airtableRecordId)) continue;
    const dossierId = `airtable:${source.airtableRecordId}`;
    const dossier = dossiers.get(dossierId);
    if (!dossier && dryRun && pendingCreateIds?.has(source.airtableRecordId)) {
      operations.push({ sourceId: source.airtableRecordId, dossierId,
        displayName: [source.beneficiary.prenom, source.beneficiary.nom].filter(Boolean).join(' '),
        textContent: plain(source.workDescription), pendingCreate: true });
      continue;
    }
    if (!dossier || (plain(value(dossier, 'ergo_id')) !== ergoLabel
      && !(dryRun && pendingReassignIds?.has(source.airtableRecordId)))) {
      skipped.push({ id: source.airtableRecordId, reason: 'dossier du profil introuvable' });
      continue;
    }
    const beneficiary = beneficiaries.get(String(value(dossier, 'beneficiaires_id')));
    if (!beneficiary) {
      skipped.push({ id: source.airtableRecordId, reason: 'bénéficiaire introuvable' });
      continue;
    }
    const patientId = `nocodb-beneficiaire-${beneficiary.id}`;
    const allPages = await listNotePages(patientId);
    const firstName = plain(value(beneficiary, 'prenom'));
    const lastName = plain(value(beneficiary, 'nom'));
    try {
      const writes = planIndependentNotes({
        pages: allPages, patientId, dossierId, initialText: plain(source.workDescription),
        metadata: { patientFirstName: firstName, patientLastName: lastName,
          patientDisplayName: [firstName, lastName].filter(Boolean).join(' '),
          dossierLabel: [firstName, lastName].filter(Boolean).join(' ') },
      });
      // Retain the historical deterministic import ID for the dossier page.
      for (const write of writes) {
        if (write.tabKey === DOSSIER_NOTE && write.expectedRevision === null) {
          write.notePageId = importedNoteId(source.airtableRecordId);
        }
      }
      if (!writes.length) { alreadyPresent += 1; continue; }
      operations.push({ sourceId: source.airtableRecordId, dossierId,
        displayName: [firstName, lastName].filter(Boolean).join(' '), writes });
    } catch (error) {
      skipped.push({ id: source.airtableRecordId, reason: error.message });
    }
  }

  const changes = operations.map((item) => ({ id: item.sourceId,
    profile: ergoLabel, name: item.displayName, kind: 'note',
    fields: item.pendingCreate
      ? { note: item.textContent, noteBeneficiaire: item.textContent }
      : Object.fromEntries(item.writes.map((write) => [
        write.tabKey === DOSSIER_NOTE ? 'note' : 'noteBeneficiaire', write.textContent,
      ])) }));
  if (dryRun) return { eligible: eligible.length, imported: 0,
    alreadyPresent, remaining: 0, skipped, changes };
  for (const item of operations.slice(0, maxChanges)) {
    // Deliberately no transaction claim: a failed second write is retried
    // independently, without resetting the first page on a later refresh.
    for (const write of item.writes) await upsertNotePage(write);
  }
  return { eligible: eligible.length, imported: Math.min(operations.length, maxChanges),
    alreadyPresent, remaining: Math.max(0, operations.length - maxChanges), skipped, changes };
}

export const importCurrentCoralieNotes = (options) =>
  importCurrentProfileNotes({ ergoLabel: 'Coralie', ...options });

import crypto from 'node:crypto';
import { isCurrentAdaptationDossier, projectAirtableDossier } from './airtableAdaptation.mjs';

const value = (row, key) => row?.fields?.[key] ?? row?.[key];
const plain = (input) => String(input ?? '').trim();

// A stable identity makes a retry safe even if the first response is lost.
export const importedNoteId = (airtableRecordId) => {
  const hash = crypto.createHash('sha256')
    .update(`aidhabitat:airtable-note:${airtableRecordId}`).digest('hex');
  return `${hash.slice(0, 8)}-${hash.slice(8, 12)}-5${hash.slice(13, 16)}-a${hash.slice(17, 20)}-${hash.slice(20, 32)}`;
};
// The current dossier note and the beneficiary visit note share one canonical
// page. Airtable only fills an empty note; later user edits take precedence.
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
    if (!plain(source.workDescription)) continue;
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
    const pages = allPages.filter((page) => page.scopeType === 'dossier_detail'
      && page.scopeId === dossierId && page.tabKey === 'notes_rapides'
      && !plain(page.subTabKey));
    const firstPage = pages.find((page) => Number(page.pageNumber) === 0);
    if (firstPage && !plain(firstPage.revision)) {
      skipped.push({ id: source.airtableRecordId, reason: 'révision de note absente' });
      continue;
    }
    let drawing = { version: 1, text: '', strokes: [] };
    try {
      if (plain(firstPage?.drawingJson)) drawing = JSON.parse(firstPage.drawingJson);
      if (!drawing || typeof drawing !== 'object' || Array.isArray(drawing)) throw new Error();
    } catch {
      skipped.push({ id: source.airtableRecordId, reason: 'dessin de note illisible' });
      continue;
    }
    const previousText = plain(drawing.text) || plain(firstPage?.textContent);
    const desiredText = plain(source.workDescription);
    if (previousText) {
      alreadyPresent += 1;
      continue;
    }
    const firstName = plain(value(beneficiary, 'prenom'));
    const lastName = plain(value(beneficiary, 'nom'));
    operations.push({ sourceId: source.airtableRecordId,
      displayName: [firstName, lastName].filter(Boolean).join(' '),
      noteId: firstPage?.id ?? importedNoteId(source.airtableRecordId),
      patientId, dossierId, pageNumber: 0,
      textContent: desiredText,
      drawingJson: JSON.stringify({ ...drawing, text: desiredText }),
      previewDataUrl: firstPage?.previewDataUrl ?? '',
      layoutKind: firstPage?.layoutKind ?? 'freeform',
      expectedRevision: firstPage?.revision ?? null,
      firstName, lastName });
  }

  const changes = operations.map((item) => ({ id: item.sourceId,
    profile: ergoLabel, name: item.displayName, kind: 'note',
    fields: { note: item.textContent } }));
  if (dryRun) return { eligible: eligible.length, imported: 0,
    alreadyPresent, remaining: 0, skipped, changes };
  for (const item of operations.slice(0, maxChanges)) {
    await upsertNotePage({
      notePageId: item.noteId,
      patientId: item.patientId,
      dossierId: item.dossierId,
      scopeType: 'dossier_detail', scopeId: item.dossierId,
      tabKey: 'notes_rapides', subTabKey: '',
      pageNumber: item.pageNumber,
      textContent: item.textContent,
      drawingJson: item.drawingJson, previewDataUrl: item.previewDataUrl,
      layoutKind: item.layoutKind,
      patientFirstName: item.firstName, patientLastName: item.lastName,
      patientDisplayName: [item.firstName, item.lastName].filter(Boolean).join(' '),
      dossierLabel: [item.firstName, item.lastName].filter(Boolean).join(' '),
      expectedRevision: item.expectedRevision, writeId: crypto.randomUUID(),
    });
  }
  return { eligible: eligible.length, imported: Math.min(operations.length, maxChanges),
    alreadyPresent, remaining: Math.max(0, operations.length - maxChanges), skipped, changes };
}

export const importCurrentCoralieNotes = (options) =>
  importCurrentProfileNotes({ ergoLabel: 'Coralie', ...options });

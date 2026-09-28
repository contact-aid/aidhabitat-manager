import crypto from 'node:crypto';
import { isCurrentCoralieDossier, projectAirtableDossier } from './airtableAdaptation.mjs';

const value = (row, key) => row?.fields?.[key] ?? row?.[key];
const plain = (input) => String(input ?? '').trim();

// A stable identity makes a retry safe even if the first response is lost.
export const importedNoteId = (airtableRecordId) => {
  const hash = crypto.createHash('sha256')
    .update(`aidhabitat:airtable-note:${airtableRecordId}`).digest('hex');
  return `${hash.slice(0, 8)}-${hash.slice(8, 12)}-5${hash.slice(13, 16)}-a${hash.slice(17, 20)}-${hash.slice(20, 32)}`;
};

export function pendingAirtableNoteText(source, pages) {
  const existing = pages.map((page) => plain(page.textContent));
  const blocks = [
    ['Commentaire d’inscription (Airtable)', source.intakeNote],
    ['Commentaire du dossier (Airtable)', source.quickNote],
  ].filter(([, note]) => plain(note))
    .filter(([, note]) => !existing.some((text) => text.includes(plain(note))));
  return blocks.map(([heading, note]) => `${heading}\n${plain(note)}`).join('\n\n');
}

// Import only missing source text into a new quick-note page. Existing pages,
// including drawings and user edits, are never changed.
export async function importCurrentCoralieNotes({
  sourceRows, dossierRows, beneficiaryRows, listNotePages, upsertNotePage,
  maxChanges = 5,
}) {
  const dossiers = new Map(dossierRows.map((row) => [plain(value(row, 'uuid_source')), row]));
  const beneficiaries = new Map(beneficiaryRows.map((row) => [String(row.id), row]));
  const operations = [];
  const skipped = [];
  let alreadyPresent = 0;
  const eligible = sourceRows.filter(isCurrentCoralieDossier)
    .map((row) => projectAirtableDossier(row));

  for (const source of eligible) {
    if (!plain(source.intakeNote) && !plain(source.quickNote)) continue;
    const dossierId = `airtable:${source.airtableRecordId}`;
    const dossier = dossiers.get(dossierId);
    if (!dossier || plain(value(dossier, 'ergo_id')) !== 'Coralie') {
      skipped.push({ id: source.airtableRecordId, reason: 'dossier Coralie introuvable' });
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
    const textContent = pendingAirtableNoteText(source, pages);
    if (!textContent) {
      alreadyPresent += 1;
      continue;
    }
    // The dossier's quick note shares its text across drawing pages. Put the
    // import in page 0, preserving its content and drawing, so it is visible
    // immediately and remains editable in the existing note UI.
    const firstPage = pages.find((page) => Number(page.pageNumber) === 0);
    if (firstPage && !plain(firstPage.revision)) {
      skipped.push({ id: source.airtableRecordId, reason: 'révision de note absente' });
      continue;
    }
    const firstName = plain(value(beneficiary, 'prenom'));
    const lastName = plain(value(beneficiary, 'nom'));
    operations.push({ noteId: firstPage?.id ?? importedNoteId(source.airtableRecordId),
      patientId, dossierId, pageNumber: 0,
      textContent: [plain(firstPage?.textContent), textContent].filter(Boolean).join('\n\n'),
      drawingJson: firstPage?.drawingJson ?? '',
      previewDataUrl: firstPage?.previewDataUrl ?? '',
      layoutKind: firstPage?.layoutKind ?? 'freeform',
      expectedRevision: firstPage?.revision ?? null,
      firstName, lastName });
  }

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
    alreadyPresent, remaining: Math.max(0, operations.length - maxChanges), skipped };
}

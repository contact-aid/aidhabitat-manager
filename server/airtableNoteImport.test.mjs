import assert from 'node:assert/strict';
import test from 'node:test';
import { importCurrentCoralieNotes } from './airtableNoteImport.mjs';

const recordId = 'recAAAAAAAAAAAAAA';
const source = (fields = {}, clientFields = {}) => ({
  dossier: { id: recordId, fields: {
    'Adaptation ou énergie': ['Adaptation'], 'Intervenant couleur': ['Coralie'],
    'Date du RDV avec heure': '2026-09-20T09:00:00.000Z', 'No Client': ['recBBBBBBBBBBBBBB'],
    'Annulé ?': 'Non',
    ...fields,
  } },
  client: { id: 'recBBBBBBBBBBBBBB', fields: clientFields },
});
const dossier = { id: 1, fields: {
  uuid_source: `airtable:${recordId}`, ergo_id: 'Coralie', beneficiaires_id: 2,
} };
const beneficiary = { id: 2, fields: { prenom: 'Camille', nom: 'Exemple' } };
const importRows = async ({ sourceRows = [source({ Commentaires: 'Note dossier' },
  { 'Inscription commentaires': 'Note inscription',
    'Description des travaux': 'Description exacte des travaux' })], pages = [] } = {}) => {
  const saved = [];
  const result = await importCurrentCoralieNotes({
    sourceRows, dossierRows: [dossier], beneficiaryRows: [beneficiary],
    listNotePages: async () => pages,
    upsertNotePage: async (payload) => { saved.push(payload); const row = {
      id: payload.notePageId, scopeType: payload.scopeType, scopeId: payload.scopeId,
      tabKey: payload.tabKey, subTabKey: payload.subTabKey, pageNumber: payload.pageNumber,
      textContent: payload.textContent, drawingJson: payload.drawingJson,
      revision: payload.writeId,
    }; const existingIndex = pages.findIndex((page) => page.id === row.id);
    if (existingIndex >= 0) pages[existingIndex] = row; else pages.push(row); },
  });
  return { saved, result, pages };
};

test('imports the work description into visible page zero and is repeatable', async () => {
  const first = await importRows();
  assert.equal(first.result.eligible, 1);
  assert.equal(first.result.imported, 1);
  assert.equal(first.saved[0].pageNumber, 0);
  assert.equal(first.saved[0].patientId, 'nocodb-beneficiaire-2');
  assert.equal(first.saved[0].textContent, 'Description exacte des travaux');
  assert.equal(JSON.parse(first.saved[0].drawingJson).text, 'Description exacte des travaux');
  const second = await importRows({ pages: first.pages });
  assert.equal(second.result.imported, 0);
  assert.equal(second.result.alreadyPresent, 1);
});

test('archives an existing note and preserves drawing when applying the description', async () => {
  const existing = { id: 'old-page', scopeType: 'dossier_detail',
    scopeId: `airtable:${recordId}`, tabKey: 'notes_rapides', subTabKey: '',
    pageNumber: 0, textContent: 'Note déjà saisie\nNote inscription',
    drawingJson: '{"strokes":[1]}', previewDataUrl: 'data:image/png;base64,x',
    layoutKind: 'freeform', revision: 'old-revision' };
  const pages = [existing];
  const { saved } = await importRows({ pages });
  assert.equal(saved.length, 2);
  assert.equal(saved[0].tabKey, 'notes_rapides_avant_description');
  assert.equal(saved[0].textContent, existing.textContent);
  assert.equal(saved[1].notePageId, 'old-page');
  assert.equal(saved[1].expectedRevision, 'old-revision');
  assert.deepEqual(JSON.parse(saved[1].drawingJson).strokes, [1]);
  assert.equal(JSON.parse(saved[1].drawingJson).text, 'Description exacte des travaux');
  assert.equal(saved[1].previewDataUrl, existing.previewDataUrl);
  const again = await importRows({ pages });
  assert.equal(again.result.imported, 0);
  assert.equal(again.saved.length, 0);
  assert.equal(existing.textContent, 'Note déjà saisie\nNote inscription');
});

test('does not create notes for cancelled or out-of-period dossiers', async () => {
  const wrong = source({ 'Annulé ?': 'Oui' },
    { 'Inscription commentaires': 'Secret' });
  const old = source({ 'Date du RDV avec heure': '2026-07-01T09:00:00.000Z' },
    { 'Inscription commentaires': 'Ancien' });
  const { saved, result } = await importRows({ sourceRows: [wrong, old] });
  assert.equal(result.eligible, 0);
  assert.equal(saved.length, 0);
});

test('replaces inconsistent old display text after archiving it', async () => {
  const existing = { id: 'old-page', scopeType: 'dossier_detail',
    scopeId: `airtable:${recordId}`, tabKey: 'notes_rapides', subTabKey: '',
    pageNumber: 0, textContent: 'Commentaire d’inscription (Airtable)\nNote inscription\n\nCommentaire du dossier (Airtable)\nNote dossier',
    drawingJson: JSON.stringify({ version: 1, text: 'Note personnelle', strokes: [{ x: 1 }] }),
    revision: 'old-revision' };
  const { saved } = await importRows({ pages: [existing] });
  assert.equal(saved.length, 2);
  const drawing = JSON.parse(saved[1].drawingJson);
  assert.deepEqual(drawing.strokes, [{ x: 1 }]);
  assert.equal(drawing.text, 'Description exacte des travaux');
  assert.equal(saved[1].textContent, drawing.text);
});

test('the work description replaces old drawing text and is not appended twice', async () => {
  const existing = { id: 'old-page', scopeType: 'dossier_detail',
    scopeId: `airtable:${recordId}`, tabKey: 'notes_rapides', subTabKey: '',
    pageNumber: 0, textContent: '',
    drawingJson: JSON.stringify({ version: 1, text: 'Note inscription\nNote dossier', strokes: [] }),
    revision: 'old-revision' };
  const { saved } = await importRows({ pages: [existing] });
  assert.equal(saved.length, 2);
  assert.equal(saved[1].textContent, 'Description exacte des travaux');
});

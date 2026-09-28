import assert from 'node:assert/strict';
import test from 'node:test';
import { importCurrentCoralieNotes, pendingAirtableNoteText } from './airtableNoteImport.mjs';

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
  { 'Inscription commentaires': 'Note inscription' })], pages = [] } = {}) => {
  const saved = [];
  const result = await importCurrentCoralieNotes({
    sourceRows, dossierRows: [dossier], beneficiaryRows: [beneficiary],
    listNotePages: async () => pages,
    upsertNotePage: async (payload) => { saved.push(payload); pages.push({
      id: payload.notePageId, scopeType: payload.scopeType, scopeId: payload.scopeId,
      tabKey: payload.tabKey, subTabKey: payload.subTabKey, pageNumber: payload.pageNumber,
      textContent: payload.textContent, drawingJson: payload.drawingJson,
      revision: payload.writeId,
    }); },
  });
  return { saved, result, pages };
};

test('imports both Airtable comments into visible page zero and is repeatable', async () => {
  const first = await importRows();
  assert.equal(first.result.eligible, 1);
  assert.equal(first.result.imported, 1);
  assert.equal(first.saved[0].pageNumber, 0);
  assert.equal(first.saved[0].patientId, 'nocodb-beneficiaire-2');
  assert.match(first.saved[0].textContent, /Commentaire d’inscription \(Airtable\)\nNote inscription/);
  assert.match(first.saved[0].textContent, /Commentaire du dossier \(Airtable\)\nNote dossier/);
  const second = await importRows({ pages: first.pages });
  assert.equal(second.result.imported, 0);
  assert.equal(second.result.alreadyPresent, 1);
});

test('appends missing source text while preserving an existing note and drawing', async () => {
  const existing = { id: 'old-page', scopeType: 'dossier_detail',
    scopeId: `airtable:${recordId}`, tabKey: 'notes_rapides', subTabKey: '',
    pageNumber: 0, textContent: 'Note déjà saisie\nNote inscription',
    drawingJson: '{"strokes":[1]}', previewDataUrl: 'data:image/png;base64,x',
    layoutKind: 'freeform', revision: 'old-revision' };
  const { saved } = await importRows({ pages: [existing] });
  assert.equal(saved.length, 1);
  assert.equal(saved[0].notePageId, 'old-page');
  assert.equal(saved[0].expectedRevision, 'old-revision');
  assert.deepEqual(JSON.parse(saved[0].drawingJson).strokes, [1]);
  assert.equal(JSON.parse(saved[0].drawingJson).text, saved[0].textContent);
  assert.equal(saved[0].previewDataUrl, existing.previewDataUrl);
  assert(saved[0].textContent.startsWith(existing.textContent));
  assert(!saved[0].textContent.includes('Commentaire d’inscription (Airtable)'));
  assert(saved[0].textContent.includes('Commentaire du dossier (Airtable)'));
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

test('a source excerpt already present in any page is not copied twice', () => {
  assert.equal(pendingAirtableNoteText({ intakeNote: 'déjà là', quickNote: 'autre' },
    [{ textContent: 'Texte\ndéjà là' }]), 'Commentaire du dossier (Airtable)\nautre');
});

test('repairs already imported text that was absent from the editor drawing JSON', async () => {
  const existing = { id: 'old-page', scopeType: 'dossier_detail',
    scopeId: `airtable:${recordId}`, tabKey: 'notes_rapides', subTabKey: '',
    pageNumber: 0, textContent: 'Commentaire d’inscription (Airtable)\nNote inscription\n\nCommentaire du dossier (Airtable)\nNote dossier',
    drawingJson: JSON.stringify({ version: 1, text: 'Note personnelle', strokes: [{ x: 1 }] }),
    revision: 'old-revision' };
  const { saved } = await importRows({ pages: [existing] });
  assert.equal(saved.length, 1);
  const drawing = JSON.parse(saved[0].drawingJson);
  assert.deepEqual(drawing.strokes, [{ x: 1 }]);
  assert(drawing.text.startsWith('Note personnelle'));
  assert(drawing.text.includes('Commentaire d’inscription (Airtable)'));
  assert.equal(saved[0].textContent, drawing.text);
});

test('source text already visible in a drawing is not appended twice', async () => {
  const existing = { id: 'old-page', scopeType: 'dossier_detail',
    scopeId: `airtable:${recordId}`, tabKey: 'notes_rapides', subTabKey: '',
    pageNumber: 0, textContent: '',
    drawingJson: JSON.stringify({ version: 1, text: 'Note inscription\nNote dossier', strokes: [] }),
    revision: 'old-revision' };
  const { saved } = await importRows({ pages: [existing] });
  assert.equal(saved.length, 1);
  assert(!saved[0].textContent.includes('(Airtable)'));
  assert.equal(saved[0].textContent, 'Note inscription\nNote dossier');
});

import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import test from 'node:test';
import { createNocodbStoreAdapter } from './mobileSyncStore.mjs';
import { BENEFICIARY_NOTE, DOSSIER_NOTE, planIndependentNotes } from './independentNotes.mjs';

// Real store adapter; every NocoDB IO function replaced by a fictional database.
// No network, credentials, production dossier or schema migration.
function fixture({ preferLocal = false } = {}) {
  const rows = [];
  let nextId = 1;
  const matches = (row, where = '') => [...where.matchAll(/\((\w+),eq,("(?:[^"\\]|\\.)*"|[^)]*)\)/g)]
    .every(([, key, raw]) => String(key === 'Id' ? row.id : row.fields[key] ?? '')
      === String(raw.startsWith('"') ? JSON.parse(raw) : raw));
  const io = {
    queryAll: async (_table, { where } = {}) => structuredClone(rows.filter(row => matches(row, where))),
    createRecord: async (_table, fields) => {
      const row = { id: String(nextId++), fields: structuredClone(fields) };
      rows.push(row); return structuredClone(row);
    },
    updateRecord: async (_table, id, fields) => {
      Object.assign(rows.find(row => row.id === id).fields, fields);
    },
    deleteRecord: async () => { throw new Error('No deletion allowed in this lot'); },
    callNocoTool: async (name) => {
      assert.equal(name, 'getTableSchema');
      return { fields: ['preview_data_url', 'preview_url', 'plan_phase']
        .map(title => ({ title })) };
    },
    requestConditionalNocodbRest: async ({ method, path, body }) => {
      assert.equal(method, 'PATCH');
      const where = new URL(path, 'https://synthetic.invalid').searchParams.get('where');
      const row = rows.find(row => matches(row, where));
      if (row) Object.assign(row.fields, structuredClone(body));
      return row ? 1 : 0;
    },
  };
  const store = createNocodbStoreAdapter({
    absoluteUrl: path => `https://synthetic.invalid${path}`,
    notePagesTableId: 'fictitious_notes', preferLocal, io,
  });
  const patientId = 'nocodb-beneficiaire-fiction';
  const dossierId = 'airtable:recFICTION';
  const list = () => store.listNotePagesByPatient(patientId);
  const plan = async (initialText = 'Import fictif') => planIndependentNotes({
    pages: await list(), patientId, dossierId, initialText,
  });
  const initialize = async (text) => {
    const writes = await plan(text);
    for (const write of writes) await store.upsertNotePage(write);
    return writes;
  };
  const edit = async (tabKey, text, { pageNumber = 0, revision, notePageId, strokes = [] } = {}) => {
    const page = (await list()).find(p => p.tabKey === tabKey && p.pageNumber === pageNumber);
    return store.upsertNotePage({
      patientId, dossierId, scopeType: 'dossier_detail', scopeId: dossierId,
      tabKey, subTabKey: '', pageNumber, textContent: '',
      drawingJson: JSON.stringify({ version: 1, text, strokes }), // build 64 JSON, no marker
      expectedRevision: revision === undefined ? page?.revision ?? null : revision,
      notePageId: notePageId ?? null, writeId: randomUUID(),
    });
  };
  return { rows, store, list, plan, initialize, edit, patientId, dossierId };
}
const text = page => JSON.parse(page.drawingJson).text;

test('initial import, independent web/iPad64 edits, refresh and deliberate clear', async () => {
  const f = fixture();
  assert.equal((await f.initialize()).length, 2);
  assert.deepEqual((await f.list()).map(text), ['Import fictif', 'Import fictif']);
  const ipadPage = (await f.list()).find(p => p.tabKey === BENEFICIARY_NOTE);
  await f.edit(DOSSIER_NOTE, 'Texte web');
  // The iPad kept its own revision while offline; the dossier edit cannot conflict.
  await f.edit(BENEFICIARY_NOTE, 'Texte iPad hors ligne', {
    revision: ipadPage.revision, strokes: [{ points: [[1, 2]] }],
  });
  assert.equal((await f.initialize('Autre texte Airtable')).length, 0);
  const pages = await f.list();
  assert.equal(text(pages.find(p => p.tabKey === DOSSIER_NOTE)), 'Texte web');
  assert.equal(text(pages.find(p => p.tabKey === BENEFICIARY_NOTE)), 'Texte iPad hors ligne');
  await f.edit(BENEFICIARY_NOTE, '', { strokes: [{ points: [[1, 2]] }] });
  assert.equal((await f.initialize('Ne doit pas revenir')).length, 0);
  const reopened = (await f.list()).find(p => p.tabKey === BENEFICIARY_NOTE);
  assert.equal(text(reopened), '');
  assert.deepEqual(JSON.parse(reopened.drawingJson).strokes, [{ points: [[1, 2]] }]);
  assert.equal(JSON.parse(reopened.drawingJson).noteTextInitialized, true);
  await f.edit(DOSSIER_NOTE, '');
  assert.equal((await f.initialize('Airtable')).length, 0);
  assert.deepEqual((await f.list()).map(text), ['', '']);
});

test('existing iPad text and drawing remain byte-for-byte unchanged on initialization', async () => {
  const f = fixture();
  await f.edit(BENEFICIARY_NOTE, 'Saisie iPad ancienne', { strokes: [{ x: 7 }] });
  const row = f.rows[0];
  const drawing = JSON.parse(row.fields.drawing_json);
  delete drawing.noteTextInitialized;
  row.fields.drawing_json = JSON.stringify(drawing);
  const before = structuredClone(row);
  assert.equal((await f.initialize()).length, 1);
  assert.deepEqual(f.rows[0], before);
});

test('legacy empty beneficiary is seeded once from current dossier, keeping all drawing fields', async () => {
  const f = fixture();
  await f.edit(DOSSIER_NOTE, 'Dossier actuel');
  await f.edit(BENEFICIARY_NOTE, '', { strokes: [{ x: 4 }] });
  const row = f.rows.find(r => r.fields.tab_key === BENEFICIARY_NOTE);
  row.fields.drawing_json = JSON.stringify({ version: 1, text: '', strokes: [{ x: 4 }], extra: [1] });
  assert.equal((await f.initialize('Ancien Airtable')).length, 1);
  const result = (await f.list()).find(p => p.tabKey === BENEFICIARY_NOTE);
  assert.deepEqual(JSON.parse(result.drawingJson), {
    version: 1, text: 'Dossier actuel', strokes: [{ x: 4 }], extra: [1], noteTextInitialized: true,
  });
  await f.edit(BENEFICIARY_NOTE, '');
  assert.equal((await f.initialize()).length, 0);
});

test('initialization CAS refuses a concurrent iPad edit even under prefer-local policy', async () => {
  const f = fixture({ preferLocal: true });
  await f.edit(BENEFICIARY_NOTE, '');
  f.rows[0].fields.drawing_json = '{"version":1,"text":"","strokes":[]}';
  const stale = (await f.plan()).find(p => p.tabKey === BENEFICIARY_NOTE);
  await f.edit(BENEFICIARY_NOTE, 'Nouvelle saisie hors ligne');
  await assert.rejects(f.store.upsertNotePage(stale), e => e.code === 'NOTE_PAGE_REVISION_CONFLICT');
  assert.equal(text((await f.list())[0]), 'Nouvelle saisie hors ligne');
});

test('first iPad64 push and initial import cannot create destructive duplicate rows in one server', async () => {
  const f = fixture();
  const initial = (await f.plan()).find(p => p.tabKey === BENEFICIARY_NOTE);
  const outcomes = await Promise.allSettled([
    f.edit(BENEFICIARY_NOTE, 'Saisie iPad', {
      revision: null, notePageId: `note_${f.patientId}_${BENEFICIARY_NOTE}_0`,
    }),
    f.store.upsertNotePage(initial),
  ]);
  assert.equal(outcomes.filter(o => o.status === 'fulfilled').length, 1);
  assert.equal(f.rows.length, 1);
  const winner = outcomes[0].status === 'fulfilled' ? 'Saisie iPad' : 'Import fictif';
  assert.equal(text((await f.list())[0]), winner);
  assert.equal(outcomes.find(o => o.status === 'rejected').reason.code, 'NOTE_PAGE_REVISION_CONFLICT');
});

test('replay accepted before rollout still succeeds; subsequent old-client clear gets the marker', async () => {
  const f = fixture();
  const payload = (await f.plan()).find(p => p.tabKey === BENEFICIARY_NOTE);
  delete payload.initializationOnly;
  payload.drawingJson = '{"version":1,"text":"ancien","strokes":[]}';
  await f.store.upsertNotePage(payload);
  f.rows[0].fields.drawing_json = payload.drawingJson; // pre-rollout accepted write
  assert.equal(text(await f.store.upsertNotePage(payload)), 'ancien');
  assert.equal(f.rows[0].fields.drawing_json, payload.drawingJson);
  await f.edit(BENEFICIARY_NOTE, '');
  assert.equal(JSON.parse(f.rows[0].fields.drawing_json).noteTextInitialized, true);
});

test('new replay is idempotent and a reused write ID with different text is rejected', async () => {
  const f = fixture();
  const payload = (await f.plan())[0];
  await f.store.upsertNotePage(payload);
  const before = structuredClone(f.rows);
  await f.store.upsertNotePage(payload);
  assert.deepEqual(f.rows, before);
  await assert.rejects(f.store.upsertNotePage({ ...payload,
    drawingJson: '{"text":"autre","strokes":[]}' }), e => e.code === 'NOTE_PAGE_WRITE_ID_REUSED');
});

test('duplicate rows, malformed drawing and missing revisions require review without writes', async () => {
  const f = fixture();
  await f.initialize();
  const row = f.rows[0];
  row.fields.drawing_json = 'not-json';
  await assert.rejects(f.plan());
  row.fields.drawing_json = '{"text":"","strokes":[]}';
  row.fields.text_content = '';
  row.fields.app_sync_revision = null;
  await assert.rejects(f.plan(), /révision/);
  f.rows.push({ ...structuredClone(row), id: 'duplicate' });
  await assert.rejects(f.plan(), /doublon/);
  await assert.rejects(f.edit(DOSSIER_NOTE, 'edit'), e => e.code === 'NOTE_PAGE_DUPLICATES_REQUIRE_REVIEW');
  assert.equal(f.rows.length, 3);
});

test('text on later beneficiary pages is preserved without copying the dossier over it', async () => {
  const f = fixture();
  await f.edit(BENEFICIARY_NOTE, 'Saisie page 2', { pageNumber: 1, strokes: [{ x: 1 }] });
  await f.initialize();
  const beneficiary = (await f.list()).filter(p => p.tabKey === BENEFICIARY_NOTE);
  assert.deepEqual(beneficiary.map(text), ['Saisie page 2']);
  assert.equal((await f.initialize()).length, 0);
});

test('legacy shared dossier text on page two is retained and initializes beneficiary', async () => {
  const f = fixture();
  await f.edit(DOSSIER_NOTE, 'Ancien texte partagé', { pageNumber: 1, strokes: [{ x: 8 }] });
  const before = structuredClone(f.rows[0]);
  await f.initialize('Airtable obsolète');
  assert.deepEqual(f.rows[0], before);
  assert.deepEqual((await f.list()).map(text), [
    'Ancien texte partagé', 'Ancien texte partagé', 'Ancien texte partagé',
  ]);
});

test('old patient scopes are refused for review, never silently initialized', async () => {
  const f = fixture();
  await f.edit(BENEFICIARY_NOTE, '');
  f.rows[0].fields.scope_id = f.patientId;
  const before = structuredClone(f.rows);
  await assert.rejects(f.initialize(), /portées/);
  assert.deepEqual(f.rows, before);
});

test('offline64 stale save conflicts even under local priority; reviewed retry keeps canonical URL', async () => {
  const f = fixture({ preferLocal: true });
  await f.initialize();
  const before = (await f.list()).find(p => p.tabKey === BENEFICIARY_NOTE);
  const rowsBefore = structuredClone(f.rows);
  await assert.rejects(f.edit(BENEFICIARY_NOTE, 'Saisie64', {
    revision: null, notePageId: `note_${f.patientId}_${BENEFICIARY_NOTE}_0`,
  }), /NOTE_PAGE_REVISION_CONFLICT/);
  assert.deepEqual(f.rows, rowsBefore);
  const saved = await f.edit(BENEFICIARY_NOTE, 'Saisie64', {
    revision: before.revision, notePageId: `note_${f.patientId}_${BENEFICIARY_NOTE}_0`,
  });
  assert.equal(saved.id, before.id);
  assert.equal(saved.previewUrl, before.previewUrl);
  assert.equal(f.rows.length, 2);
  assert.equal(text(saved), 'Saisie64');
});

test('two simultaneous imports serialize with one winner and no lost rows', async () => {
  const f = fixture();
  const a = (await f.plan())[0];
  const b = (await f.plan())[0];
  const results = await Promise.allSettled([f.store.upsertNotePage(a), f.store.upsertNotePage(b)]);
  assert.equal(results.filter(r => r.status === 'fulfilled').length, 1);
  assert.equal(f.rows.length, 1);
});

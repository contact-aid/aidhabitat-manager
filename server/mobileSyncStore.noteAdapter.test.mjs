import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import test from 'node:test';

import { createNocodbStoreAdapter } from './mobileSyncStore.mjs';
import { createNotePageNocodbFake } from './test-fixtures/notePageNocodbFake.mjs';

const noteId = 'note_patient-1_Plans_1';
const drawing = JSON.stringify({ text: 'fiction', strokes: [{ x: 1, y: 2 }] });
const payload = (changes = {}) => ({
  notePageId: noteId,
  patientId: 'patient-1',
  dossierId: 'dossier-1',
  scopeType: 'visit_grid',
  scopeId: 'patient-1',
  tabKey: 'Plans',
  subTabKey: '',
  pageNumber: 1,
  textContent: 'fiction',
  drawingJson: drawing,
  layoutKind: 'freeform',
  expectedRevision: null,
  writeId: randomUUID(),
  ...changes,
});

const fixture = () => {
  const fake = createNotePageNocodbFake();
  const adapter = createNocodbStoreAdapter({
    absoluteUrl: (path) => `https://fake.test${path}`,
    documentsTableId: 'documents',
    documentChunksTableId: 'chunks',
    notePagesTableId: 'notes',
    preferLocal: true, // production setting
    io: fake.io,
  });
  return { ...fake, adapter };
};

test('missing revision stays a conflict; verified absence then creates once and replays', async () => {
  const { state, adapter } = fixture();
  const stale = payload({ expectedRevision: randomUUID() });
  await assert.rejects(adapter.upsertNotePage(stale), {
    status: 409, code: 'NOTE_PAGE_RECORD_MISSING',
  });
  assert.equal(state.rows.length, 0);

  const create = payload({ drawingJson: drawing });
  const first = await adapter.upsertNotePage(create);
  const replay = await adapter.upsertNotePage(create);
  assert.equal(first.revision, create.writeId);
  assert.equal(replay.revision, create.writeId);
  assert.equal(state.rows.length, 1);
  assert.equal(state.creates, 1);
  assert.equal(state.rows[0].drawing_json, drawing);
  assert.equal(state.rows[0].text_content, 'fiction');
  assert.equal(state.deletes, 0);
});

test('lost creation response is confirmed from the same writeId without duplicate', async () => {
  const { state, adapter } = fixture();
  state.loseCreateResponse = true;
  const create = payload();
  const result = await adapter.upsertNotePage(create);
  assert.equal(result.revision, create.writeId);
  await adapter.upsertNotePage(create);
  assert.equal(state.rows.length, 1);
  assert.equal(state.creates, 1);
  assert.equal(state.deletes, 0);
});

test('two same-process absent creates serialize and cannot silently overwrite', async () => {
  const { state, adapter } = fixture();
  const first = payload();
  const second = payload({ drawingJson: JSON.stringify({ text: 'other', strokes: [] }) });
  const outcomes = await Promise.allSettled([
    adapter.upsertNotePage(first),
    adapter.upsertNotePage(second),
  ]);
  assert.equal(outcomes.filter((result) => result.status === 'fulfilled').length, 1);
  assert.equal(outcomes.filter((result) => result.status === 'rejected'
    && result.reason?.code === 'NOTE_PAGE_REVISION_CONFLICT').length, 1);
  assert.equal(state.rows.length, 1);
  assert.equal(state.creates, 1);
  assert.equal(state.deletes, 0);
});

test('build 64 ordinary save updates canonical row and stale edit is rejected', async () => {
  const { state, adapter } = fixture();
  const first = payload({ notePageId: 'remote-canonical-id' });
  await adapter.upsertNotePage(first);
  const ordinarySave = payload({
    notePageId: '', // build 64 addresses an existing page by composite key
    expectedRevision: first.writeId,
    drawingJson: JSON.stringify({ text: 'new fiction', strokes: [{ x: 3 }] }),
  });
  await adapter.upsertNotePage(ordinarySave);
  assert.equal(state.rows.length, 1);
  assert.equal(state.rows[0].uuid_source, 'remote-canonical-id');
  assert.equal(state.rows[0].drawing_json, ordinarySave.drawingJson);
  assert.equal(state.rows[0].app_sync_revision, ordinarySave.writeId);
  assert.equal(state.patches, 1);
  await assert.rejects(adapter.upsertNotePage(payload({
    notePageId: '', expectedRevision: first.writeId,
  })), { status: 409, code: 'NOTE_PAGE_REVISION_CONFLICT' });
  assert.equal(state.rows[0].drawing_json, ordinarySave.drawingJson);
  assert.equal(state.deletes, 0);
});

test('a reused id cannot move a page and duplicate identities require review', async () => {
  const { state, adapter } = fixture();
  const otherPage = payload({ pageNumber: 2 });
  await adapter.upsertNotePage(otherPage);
  await assert.rejects(adapter.upsertNotePage(payload({
    expectedRevision: otherPage.writeId,
  })), { status: 409, code: 'NOTE_PAGE_IDENTITY_CONFLICT' });
  assert.equal(state.rows[0].page_number, 2);

  const { Id: _recordId, ...sameIdentity } = state.rows[0];
  state.insert({ ...sameIdentity, uuid_source: 'second-id' });
  await assert.rejects(adapter.upsertNotePage(payload({
    pageNumber: 2, notePageId: '', expectedRevision: otherPage.writeId,
  })), { status: 409, code: 'NOTE_PAGE_DUPLICATES_REQUIRE_REVIEW' });
  assert.equal(state.rows.length, 2);
  assert.equal(state.deletes, 0);
});

test('explicit clearing is a guarded save, with other pages untouched and no DELETE', async () => {
  const { state, adapter } = fixture();
  const first = payload();
  const other = payload({ notePageId: 'other-page', pageNumber: 0 });
  await adapter.upsertNotePage(first);
  await adapter.upsertNotePage(other);
  const clear = payload({
    notePageId: '', expectedRevision: first.writeId,
    drawingJson: '', textContent: '',
  });
  await adapter.upsertNotePage(clear);
  assert.equal(state.rows.find((row) => row.page_number === 1).drawing_json, '');
  assert.equal(state.rows.find((row) => row.page_number === 1).text_content, '');
  assert.equal(state.rows.find((row) => row.page_number === 0).drawing_json, drawing);
  assert.equal(state.rows.length, 2);
  assert.equal(state.deletes, 0);
});

test('concurrent createNotePage calls allocate distinct page numbers', async () => {
  const { state, adapter } = fixture();
  const create = () => adapter.createNotePage({
    patientId: 'patient-1', dossierId: 'dossier-1',
    scopeType: 'visit_grid', scopeId: 'patient-1', tabKey: 'Plans',
    subTabKey: '', layoutKind: 'freeform',
  });
  await Promise.all([create(), create()]);
  assert.deepEqual(state.rows.map((row) => row.page_number).sort(), [0, 1]);
  assert.equal(state.deletes, 0);
});

test('createNotePage and upsertNotePage share the page allocation lock', async () => {
  const { state, adapter } = fixture();
  const create = () => adapter.createNotePage({
    patientId: 'patient-1', dossierId: 'dossier-1',
    scopeType: 'visit_grid', scopeId: 'patient-1', tabKey: 'Plans',
    subTabKey: '', layoutKind: 'freeform',
  });
  const queuedEdit = payload({
    notePageId: 'note_patient-1_Plans_0', pageNumber: 0,
  });
  const outcomes = await Promise.allSettled([
    create(), adapter.upsertNotePage(queuedEdit),
  ]);
  assert(outcomes.some((result) => result.status === 'fulfilled'));
  assert(outcomes.every((result) => result.status === 'fulfilled'
    || result.reason?.code === 'NOTE_PAGE_REVISION_CONFLICT'));
  assert.equal(new Set(state.rows.map((row) => row.page_number)).size, state.rows.length);
  assert.equal(state.deletes, 0);
});

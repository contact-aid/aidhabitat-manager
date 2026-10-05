import assert from 'node:assert/strict';
import { randomBytes, randomUUID, createHash } from 'node:crypto';
import test from 'node:test';
import { gzipSync } from 'node:zlib';
import { createNocodbStoreAdapter } from './mobileSyncStore.mjs';
import { NOTE_CONTENT_PREFIX, NOTE_CONTENT_MAX_BYTES } from './noteContentChunks.mjs';
import { createNotePageNocodbFake } from './test-fixtures/notePageNocodbFake.mjs';

const largeDrawing = JSON.stringify({ text: 'Fiction — é 👋', strokes: [
  { data: randomBytes(1200000).toString('base64'), color: '#123456', pressure: 0.7 },
], background: { width: 1200, height: 800 } });
const sha = (value) => createHash('sha256').update(value).digest('hex');
const payload = (changes = {}) => ({
  notePageId: 'fiction-note', patientId: 'fiction-patient', dossierId: 'fiction-dossier',
  scopeType: 'visit_grid', scopeId: 'fiction-patient', tabKey: 'Plans', subTabKey: '', pageNumber: 1,
  drawingJson: largeDrawing, textContent: 'Fiction é', expectedRevision: null,
  writeId: randomUUID(), layoutKind: 'freeform', ...changes,
});
function fixture() {
  const fake = createNotePageNocodbFake();
  const adapter = createNocodbStoreAdapter({ absoluteUrl: p => `https://fake.test${p}`,
    documentsTableId: 'documents', documentChunksTableId: 'chunks', notePagesTableId: 'notes',
    preferLocal: true, io: fake.io });
  return { ...fake, adapter };
}
for (const tabKey of ['Plans', 'Résumé', 'notes_rapides']) {
  test(`${tabKey}: content larger than incident round-trips through list and direct reads`, async () => {
    const { state, adapter } = fixture();
    const input = payload({ tabKey, pageNumber: tabKey === 'Plans' ? 1 : 0,
      scopeType: tabKey === 'Plans' ? 'visit_grid' : 'dossier_detail' });
    const saved = await adapter.upsertNotePage(input);
    const expected = tabKey === 'notes_rapides'
      ? JSON.stringify({ ...JSON.parse(largeDrawing), noteTextInitialized: true }) : largeDrawing;
    assert.equal(saved.drawingJson, expected);
    assert(state.rows[0].drawing_json.startsWith(NOTE_CONTENT_PREFIX));
    assert(state.chunkRows.length > 1);
    assert(state.chunkRows.every(row => row.chunk_base64.length <= 90000));
    const direct = await adapter.getNotePageById(input.notePageId);
    const [listed] = await adapter.listNotePagesByPatient(input.patientId);
    assert.equal(sha(direct.drawingJson), sha(expected));
    assert.equal(listed.drawingJson, expected);
    assert.deepEqual(JSON.parse(listed.drawingJson).strokes, JSON.parse(largeDrawing).strokes);
    const count = state.chunkCreates;
    await adapter.upsertNotePage(input);
    assert.equal(state.chunkCreates, count);
    assert.equal(state.rows.length, 1);
    assert.equal(state.deletes, 0);
  });
}
test('large free text round-trips independently from the drawing', async () => {
  const { state, adapter } = fixture();
  const input = payload({ drawingJson: '{}', textContent: randomBytes(850000).toString('hex') });
  await adapter.upsertNotePage(input);
  assert(state.rows[0].text_content.startsWith(NOTE_CONTENT_PREFIX));
  assert.equal((await adapter.getNotePageById(input.notePageId)).textContent, input.textContent);
});
test('interruption leaves old note intact; retry completes only missing fragments', async () => {
  const { state, adapter } = fixture();
  const first = payload({ drawingJson: '{"text":"old"}' });
  await adapter.upsertNotePage(first);
  const input = payload({ expectedRevision: first.writeId });
  state.beforeChunk = () => { if (state.chunkCreates === 1) throw new Error('Synthetic outage'); };
  await assert.rejects(adapter.upsertNotePage(input), { code: 'NOTE_PAGE_CONTENT_UNAVAILABLE' });
  assert.equal(state.rows[0].drawing_json, first.drawingJson);
  assert.equal(state.rows[0].app_sync_revision, first.writeId);
  assert.equal(state.patches, 0);
  state.beforeChunk = null;
  await adapter.upsertNotePage(input);
  assert.equal((await adapter.getNotePageById(input.notePageId)).drawingJson, largeDrawing);
  assert.equal(state.chunkCreates, state.chunkRows.length);
  assert.equal(state.deletes, 0);
});
test('lost fragment and final note ACKs can be retried without changing content or revision', async () => {
  const { state, adapter } = fixture();
  const first = payload({ drawingJson: '{}' });
  await adapter.upsertNotePage(first);
  const input = payload({ expectedRevision: first.writeId });
  state.loseChunkResponse = true;
  state.losePatchResponse = true;
  await assert.rejects(adapter.upsertNotePage(input), /Synthetic note ACK lost/);
  const count = state.chunkCreates;
  const replay = await adapter.upsertNotePage(input);
  assert.equal(replay.revision, input.writeId);
  assert.equal(replay.drawingJson, largeDrawing);
  assert.equal(state.patches, 1);
  assert.equal(state.chunkCreates, count);
});
test('divergent revision conflicts before any fragment is written', async () => {
  const { state, adapter } = fixture();
  const first = payload({ drawingJson: '{"text":"server"}' });
  await adapter.upsertNotePage(first);
  await assert.rejects(adapter.upsertNotePage(payload({ expectedRevision: randomUUID() })),
    { code: 'NOTE_PAGE_REVISION_CONFLICT', status: 409 });
  assert.equal(state.chunkCreates, 0);
  assert.equal(state.patches, 0);
  assert.equal(state.rows[0].drawing_json, first.drawingJson);
});
test('concurrent update after staging prevents pointer publication and preserves both versions', async () => {
  const { state, adapter } = fixture();
  const first = payload({ drawingJson: '{}' }); await adapter.upsertNotePage(first);
  const winner = randomUUID();
  state.beforePatch = () => { state.rows[0].app_sync_revision = winner; state.rows[0].drawing_json = '{"text":"winner"}'; };
  await assert.rejects(adapter.upsertNotePage(payload({ expectedRevision: first.writeId })),
    { code: 'NOTE_PAGE_WRITE_UNCONFIRMED' });
  assert.equal(state.rows[0].app_sync_revision, winner);
  assert.equal(state.rows[0].drawing_json, '{"text":"winner"}');
  assert(state.chunkRows.length > 0);
  assert.equal(state.deletes, 0);
});
for (const corruption of ['missing', 'changed', 'duplicate', 'other-owner']) {
  test(`read fails closed for ${corruption} fragments or manifest`, async () => {
    const { state, adapter } = fixture(); const input = payload();
    await adapter.upsertNotePage(input);
    if (corruption === 'missing') state.chunkRows.pop();
    if (corruption === 'changed') state.chunkRows[0].chunk_base64 = 'A'.repeat(90000);
    if (corruption === 'duplicate') state.chunkRows.push({ ...state.chunkRows[0], chunk_base64: 'B'.repeat(90000) });
    if (corruption === 'other-owner') state.rows[0].beneficiaire_id = 'another-patient';
    await assert.rejects(adapter.getNotePageById(input.notePageId), { code: 'NOTE_PAGE_CONTENT_UNAVAILABLE' });
    assert.equal(state.deletes, 0);
  });
}
test('ordinary legacy inline and gzip notes remain readable', async () => {
  const { adapter } = fixture();
  for (const drawingJson of ['{"text":"legacy"}', JSON.stringify({ text: 'a'.repeat(150000) })]) {
    const input = payload({ notePageId: randomUUID(), pageNumber: Math.random(), drawingJson });
    await adapter.upsertNotePage(input);
    assert.equal((await adapter.getNotePageById(input.notePageId)).drawingJson, drawingJson);
  }
});
test('bounded maximum rejects before writing fragments', async () => {
  const { state, adapter } = fixture();
  await assert.rejects(adapter.upsertNotePage(payload({ drawingJson: 'x'.repeat(NOTE_CONTENT_MAX_BYTES + 1) })),
    { code: 'NOTE_PAGE_CONTENT_TOO_LARGE', status: 413 });
  assert.equal(state.chunkCreates, 0); assert.equal(state.creates, 0);
});
test('metadata lookup does not load content before authorization', async () => {
  const { state, adapter } = fixture(); const input = payload();
  await adapter.upsertNotePage(input); state.chunkRows = [];
  assert.deepEqual(await adapter.getNotePageById(input.notePageId, { metadataOnly: true }),
    { id: input.notePageId, patientId: input.patientId });
});
test('reserved note fragments cannot be read or deleted as documents', async () => {
  const { state, adapter } = fixture(); await adapter.upsertNotePage(payload());
  const key = state.chunkRows[0].document_uuid_source;
  const before = structuredClone(state.chunkRows);
  assert.equal(await adapter.getDocumentContent(key), null);
  assert.equal(await adapter.getDocumentById(key), null);
  assert.equal(await adapter.deleteDocument(key), false);
  assert.deepEqual(state.chunkRows, before); assert.equal(state.deletes, 0);
});
test('combined decoded note limit applies across text and drawing', async () => {
  const { state, adapter } = fixture();
  const half = 'x'.repeat(NOTE_CONTENT_MAX_BYTES / 2 + 1);
  await assert.rejects(adapter.upsertNotePage(payload({ drawingJson: half, textContent: half })),
    { code: 'NOTE_PAGE_CONTENT_TOO_LARGE' });
  assert.equal(state.chunkCreates, 0); assert.equal(state.creates, 0);
});

test('legacy decompression also enforces the combined page budget', async () => {
  const { state, adapter } = fixture(); const input = payload({ drawingJson: '{}' });
  await adapter.upsertNotePage(input);
  const stored = 'GZIP:' + gzipSync(Buffer.from('x'.repeat(11 * 1024 * 1024))).toString('base64');
  state.rows[0].drawing_json = stored; state.rows[0].text_content = stored;
  await assert.rejects(adapter.getNotePageById(input.notePageId), { code: 'NOTE_PAGE_CONTENT_UNAVAILABLE' });
});

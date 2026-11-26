import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import test from 'node:test';
import { createGuardedMutation } from './guardedMutation.mjs';
import { createConditionalRecordWriter } from './nocodbConditionalWrite.mjs';
import { createContextGuardedSync, contextRecordToSections, contextSectionsToDatabaseFields } from './contextGuardedSync.mjs';
import { SYNC_REVISION_FIELD } from './guardedMutation.mjs';
import { createSyncArchive, overwrittenValues, SyncArchiveUnavailableError } from './syncArchive.mjs';

function memoryArchive({ enabled = true, failing = false, missingTable = false } = {}) {
  const rows = [];
  const archive = createSyncArchive({
    enabled,
    findTableId: async () => (missingTable ? null : 'archive1'),
    createRecord: async (tableId, fields) => {
      if (failing) throw new Error('synthetic archive failure');
      rows.push({ tableId, ...fields });
      return { Id: rows.length };
    },
    now: () => '2026-11-26T15:00:00.000Z',
  });
  return { archive, rows };
}

function fixture({ archive, preferLocal = true } = {}) {
  const row = { Id: 1, app_sync_revision: randomUUID(), first: 'remote edit', second: 'old', third: '' };
  let patches = 0;
  const request = async ({ method, path, body }) => {
    if (path.includes('/meta/')) return { id: 'table1', base_id: 'base1', columns: [
      { title: 'Id', pk: true, uidt: 'ID' },
      ...['app_sync_revision', 'first', 'second', 'third'].map(title => ({ title, uidt: 'SingleLineText' })),
    ] };
    if (method === 'GET') return { list: [structuredClone(row)] };
    patches++;
    const where = new URL(path, 'https://synthetic.test').searchParams.get('where');
    if (where === `(Id,eq,1)~and(app_sync_revision,eq,${row.app_sync_revision})`) Object.assign(row, body);
    return 1;
  };
  const writer = createConditionalRecordWriter({ baseId: 'base1', allowedTableIds: ['table1'], request });
  const apply = createGuardedMutation({ writer, readRecord: async () => structuredClone(row),
    preferLocal, archive });
  return { row, apply, patches: () => patches };
}

test('only values the device had not seen are selected for the archive', () => {
  const entries = overwrittenValues({
    patch: { a: 'new', b: 'new', c: 'new', d: 'same', e: 'new' },
    observed: { a: 'someone else', b: 'device base', c: '', d: 'same', e: 'unknown base' },
    baseFields: { a: 'device base', b: 'device base', c: '' },
  });
  assert.deepEqual(entries, [
    { field: 'a', previous: 'someone else', next: 'new', baseKnown: true },
    { field: 'e', previous: 'unknown base', next: 'new', baseKnown: false },
  ]);
});

test('an overwritten remote value is archived before the write', async () => {
  const { archive, rows } = memoryArchive();
  const f = fixture({ archive });
  await f.apply({ tableId: 'table1', recordId: 1, writeId: randomUUID(), actor: 'ergo-test',
    fields: { first: 'device value', second: 'device value' },
    baseFields: { first: 'what the device saw', second: 'old' } });
  assert.equal(f.row.first, 'device value');
  assert.equal(rows.length, 1, 'only the value the device had not seen');
  assert.equal(rows[0].field_name, 'first');
  assert.equal(JSON.parse(rows[0].previous_value), 'remote edit');
  assert.equal(JSON.parse(rows[0].next_value), 'device value');
  assert.equal(rows[0].table_id, 'table1');
  assert.equal(rows[0].record_id, '1');
  assert.equal(rows[0].actor, 'ergo-test');
  assert.equal(rows[0].base_known, true);
});

test('when the archive cannot be written, nothing is overwritten and the client retries', async () => {
  for (const options of [{ failing: true }, { missingTable: true }]) {
    const { archive } = memoryArchive(options);
    const f = fixture({ archive });
    await assert.rejects(f.apply({ tableId: 'table1', recordId: 1, writeId: randomUUID(),
      fields: { first: 'device value' }, baseFields: { first: 'what the device saw' } }),
    (e) => e.status === 503 && e.code === 'SYNC_ARCHIVE_UNAVAILABLE');
    assert.equal(f.row.first, 'remote edit');
    assert.equal(f.patches(), 0);
  }
});

test('a disabled archive keeps the current behavior and is never called', async () => {
  const { archive, rows } = memoryArchive({ enabled: false, failing: true });
  const f = fixture({ archive });
  await f.apply({ tableId: 'table1', recordId: 1, writeId: randomUUID(),
    fields: { first: 'device value' }, baseFields: { first: 'what the device saw' } });
  assert.equal(f.row.first, 'device value');
  assert.equal(rows.length, 0);
});

test('editing a value the device had seen, or an empty one, archives nothing', async () => {
  const { archive, rows } = memoryArchive();
  const f = fixture({ archive });
  await f.apply({ tableId: 'table1', recordId: 1, writeId: randomUUID(),
    fields: { second: 'device value', third: 'device value' },
    baseFields: { second: 'old', third: '' } });
  assert.equal(f.row.second, 'device value');
  assert.equal(rows.length, 0);
});

test('a strict conflict archives nothing and writes nothing', async () => {
  const { archive, rows } = memoryArchive();
  const f = fixture({ archive, preferLocal: false });
  await assert.rejects(f.apply({ tableId: 'table1', recordId: 1, writeId: randomUUID(),
    fields: { first: 'device value' }, baseFields: { first: 'what the device saw' } }),
  (e) => e.status === 409);
  assert.equal(rows.length, 0);
  assert.equal(f.patches(), 0);
});

test('a replaced context section is archived before the write', async () => {
  const { archive, rows } = memoryArchive();
  const medical = (pathology) => ({ pathology, followUp: '', sensory: '', heightCm: '170', weightKg: '70' });
  let stored = { Id: 7, uuid_source: 'context-1', dossier_id: 'dossier-1',
    ...contextSectionsToDatabaseFields({ medicalContext: medical('modification distante') }),
    [SYNC_REVISION_FIELD]: randomUUID(), UpdatedAt: '2026-11-26T08:00:00.000Z' };
  const mutate = createContextGuardedSync({
    tableId: 'context1', preferLocal: true, archive,
    readByDossierId: async () => structuredClone(stored),
    createRecord: async () => { throw new Error('unused'); },
    writer: async ({ fields, writeId }) => {
      stored = { ...stored, ...fields, [SYNC_REVISION_FIELD]: writeId };
      return { status: 'applied', revision: writeId, replay: false };
    },
  });
  await mutate({ dossierId: 'dossier-1', actor: 'ergo-test', authorizeObserved: () => true,
    updates: { medicalContext: medical('modification locale') },
    concurrency: { version: 1, writeId: randomUUID(), reference: null, baseValues: {} } });
  assert.equal(contextRecordToSections(stored).medicalContext.pathology, 'modification locale');
  assert.equal(rows.length, 1);
  assert.equal(rows[0].source, 'context');
  assert.equal(rows[0].field_name, 'medicalContext');
  assert.equal(rows[0].dossier_id, 'dossier-1');
  assert.equal(rows[0].base_known, false);
  assert.equal(JSON.parse(rows[0].previous_value).pathology, 'modification distante');
});

test('archive failures are reported with a dedicated error', async () => {
  const { archive } = memoryArchive({ missingTable: true });
  await assert.rejects(archive.record([{ field: 'x', previous: 'a', next: 'b' }], { source: 't' }),
    SyncArchiveUnavailableError);
});

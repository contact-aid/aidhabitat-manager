import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import test from 'node:test';
import { createSyncArchive } from './syncArchive.mjs';
import { createSyncArchiveRestorer } from './syncArchiveRoutes.mjs';
import { contextRecordToSections, contextSectionsToDatabaseFields } from './contextGuardedSync.mjs';
import { SYNC_REVISION_FIELD } from './guardedMutation.mjs';

// Archive en mémoire avec lecture, comme la table NocoDB.
function memoryArchive({ enabled = true } = {}) {
  const rows = [];
  const archive = createSyncArchive({
    enabled,
    findTableId: async () => 'archive1',
    createRecord: async (_tableId, fields) => { rows.push({ id: rows.length + 1, fields: { ...fields } }); },
    queryAll: async (_tableId, { where } = {}) => {
      const match = /^\(uuid_source,eq,(.+)\)$/.exec(where || '');
      return rows.filter((row) => !match || row.fields.uuid_source === match[1]);
    },
    updateRecord: async (_tableId, id, fields) => { Object.assign(rows.find((r) => r.id === id).fields, fields); },
  });
  return { archive, rows };
}

function store(initial) {
  let row = { ...initial, [SYNC_REVISION_FIELD]: randomUUID() };
  const writes = [];
  return {
    row: () => row,
    change: (fields) => { row = { ...row, ...fields, [SYNC_REVISION_FIELD]: randomUUID() }; },
    readRecord: async () => structuredClone(row),
    writes,
    writer: async ({ expectedRevision, writeId, fields }) => {
      if (expectedRevision !== row[SYNC_REVISION_FIELD]) return { status: 'not_applied', reason: 'revision_changed' };
      writes.push(fields);
      row = { ...row, ...fields, [SYNC_REVISION_FIELD]: writeId };
      return { status: 'applied' };
    },
  };
}

test('restoring puts the archived value back and archives the replaced one', async () => {
  const { archive, rows } = memoryArchive();
  const db = store({ Id: 5, telephone: '0611111111' });
  await archive.record([{ field: 'telephone', previous: '0100000000', next: '0611111111', baseKnown: true }],
    { source: 'guarded', tableId: 'benef', recordId: 5, beneficiaryId: 'b1' });
  const restore = createSyncArchiveRestorer({ archive, readRecord: db.readRecord, writer: db.writer,
    contextTableId: 'ctx', allowedTableIds: ['benef', 'ctx'] });

  const result = await restore({ entryId: rows[0].fields.uuid_source, actor: 'admin-test' });
  assert.deepEqual(result, { restored: true, unchanged: false });
  assert.equal(db.row().telephone, '0100000000');
  assert.equal(rows.length, 2, 'the replaced value was archived first');
  assert.equal(rows[1].fields.source, 'restore');
  assert.equal(JSON.parse(rows[1].fields.previous_value), '0611111111');
  assert.ok(rows[0].fields.restored_at, 'entry marked as restored');

  // Une entrée déjà restaurée ne peut pas l'être deux fois.
  await assert.rejects(restore({ entryId: rows[0].fields.uuid_source }),
    (e) => e.status === 409 && e.code === 'SYNC_ARCHIVE_ALREADY_RESTORED');
  // La restauration elle-même est réversible.
  await restore({ entryId: rows[1].fields.uuid_source });
  assert.equal(db.row().telephone, '0611111111');
});

test('a record changed during the restore is not overwritten', async () => {
  const { archive, rows } = memoryArchive();
  const db = store({ Id: 5, telephone: '0611111111' });
  await archive.record([{ field: 'telephone', previous: '0100000000', next: '0611111111' }],
    { source: 'guarded', tableId: 'benef', recordId: 5 });
  const writer = async (args) => { db.change({ telephone: '0633333333' }); return db.writer(args); };
  const restore = createSyncArchiveRestorer({ archive, readRecord: db.readRecord, writer,
    contextTableId: 'ctx', allowedTableIds: ['benef'] });
  await assert.rejects(restore({ entryId: rows[0].fields.uuid_source }),
    (e) => e.status === 409 && e.code === 'SYNC_ARCHIVE_RESTORE_RETRY');
  assert.equal(db.row().telephone, '0633333333');
  assert.equal(rows[0].fields.restored_at, undefined, 'not marked as restored');
});

test('a context section is restored as a whole section', async () => {
  const { archive, rows } = memoryArchive();
  const medical = (pathology) => ({ pathology, followUp: '', sensory: '', heightCm: '170', weightKg: '70' });
  const db = store({ Id: 9, dossier_id: 'd1', ...contextSectionsToDatabaseFields({ medicalContext: medical('écrasée') }) });
  await archive.record([{ field: 'medicalContext', previous: medical('ancienne'), next: medical('écrasée') }],
    { source: 'context', tableId: 'ctx', recordId: 9, dossierId: 'd1' });
  const restore = createSyncArchiveRestorer({ archive, readRecord: db.readRecord, writer: db.writer,
    contextTableId: 'ctx', allowedTableIds: ['ctx'] });
  await restore({ entryId: rows[0].fields.uuid_source });
  assert.equal(contextRecordToSections(db.row()).medicalContext.pathology, 'ancienne');
});

test('restore is refused when disabled, unknown, or outside the protected tables', async () => {
  const off = memoryArchive({ enabled: false });
  const db = store({ Id: 5, telephone: 'x' });
  const base = { readRecord: db.readRecord, writer: db.writer, contextTableId: 'ctx', allowedTableIds: ['benef'] };
  await assert.rejects(createSyncArchiveRestorer({ archive: off.archive, ...base })({ entryId: randomUUID() }),
    (e) => e.status === 503 && e.code === 'SYNC_ARCHIVE_DISABLED');

  const { archive, rows } = memoryArchive();
  const restore = createSyncArchiveRestorer({ archive, ...base });
  await assert.rejects(restore({ entryId: randomUUID() }), (e) => e.status === 404);
  await archive.record([{ field: 'secret', previous: 'a', next: 'b' }],
    { source: 'guarded', tableId: 'other-table', recordId: 5 });
  await assert.rejects(restore({ entryId: rows[0].fields.uuid_source }),
    (e) => e.status === 400 && e.code === 'SYNC_ARCHIVE_TABLE_NOT_RESTORABLE');
  assert.equal(db.writes.length, 0);
});

test('restoring a value already in place only marks the entry', async () => {
  const { archive, rows } = memoryArchive();
  const db = store({ Id: 5, telephone: '0100000000' });
  await archive.record([{ field: 'telephone', previous: '0100000000', next: '0611111111' }],
    { source: 'guarded', tableId: 'benef', recordId: 5 });
  const restore = createSyncArchiveRestorer({ archive, readRecord: db.readRecord, writer: db.writer,
    contextTableId: 'ctx', allowedTableIds: ['benef'] });
  assert.deepEqual(await restore({ entryId: rows[0].fields.uuid_source }), { restored: true, unchanged: true });
  assert.equal(db.writes.length, 0);
  assert.ok(rows[0].fields.restored_at);
});

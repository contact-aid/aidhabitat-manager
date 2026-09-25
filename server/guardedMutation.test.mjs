import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import test from 'node:test';
import { createGuardedMutation, planDatabaseMutation } from './guardedMutation.mjs';
import { createConditionalRecordWriter } from './nocodbConditionalWrite.mjs';

function fixture({ loseResponse = false, preferLocal = false } = {}) {
  const row = { Id: 1, app_sync_revision: randomUUID(), first: 'old', second: 'old' };
  let patches = 0;
  const request = async ({ method, path, body }) => {
    if (path.includes('/meta/')) return { id: 'table1', base_id: 'base1', columns: [
      { title: 'Id', pk: true, uidt: 'ID' },
      ...['app_sync_revision', 'first', 'second'].map(title => ({ title, uidt: 'SingleLineText' })),
    ] };
    if (method === 'GET') return { list: [structuredClone(row)] };
    patches++;
    const where = new URL(path, 'https://synthetic.test').searchParams.get('where');
    if (where === `(Id,eq,1)~and(app_sync_revision,eq,${row.app_sync_revision})`) Object.assign(row, body);
    if (loseResponse && patches === 1) throw new Error('synthetic response loss');
    return 1;
  };
  const writer = createConditionalRecordWriter({ baseId: 'base1', allowedTableIds: ['table1'], request });
  const readRecord = async () => structuredClone(row);
  const apply = createGuardedMutation({ writer, readRecord, preferLocal });
  const mutation = { tableId: 'table1', recordId: 1, writeId: randomUUID(),
    fields: { first: 'local' }, baseFields: { first: 'old' } };
  return { row, apply, mutation, writer, readRecord, patches: () => patches };
}

test('independent remote edits are retained', async () => {
  const f = fixture();
  f.row.second = 'remote';
  await f.apply(f.mutation);
  assert.equal(f.row.first, 'local');
  assert.equal(f.row.second, 'remote');
});

test('a same-field conflict applies none of the patch', async () => {
  const f = fixture();
  f.row.first = 'remote';
  await assert.rejects(f.apply({ ...f.mutation, fields: { first: 'local', second: 'local' },
    baseFields: { first: 'old', second: 'old' } }), e => e.status === 409);
  assert.equal(f.patches(), 0);
  assert.equal(f.row.second, 'old');
});

test('local priority overwrites only submitted fields through the conditional writer', async () => {
  const f = fixture({ preferLocal: true });
  f.row.first = 'remote';
  f.row.second = 'remote untouched';
  await f.apply({ ...f.mutation, baseFields: {} });
  assert.equal(f.row.first, 'local');
  assert.equal(f.row.second, 'remote untouched');
  assert.equal(f.patches(), 1);
  assert.equal((await f.apply({ ...f.mutation, baseFields: {} })).replay, true);
  assert.equal(f.patches(), 1);
});

test('local priority still rejects missing mutation identity and authorization', async () => {
  const f = fixture({ preferLocal: true });
  await assert.rejects(f.apply({ ...f.mutation, writeId: null }), e => e.status === 428);
  await assert.rejects(f.apply({ ...f.mutation, authorizeObserved: () => false }), e => e.status === 403);
  assert.equal(f.patches(), 0);
});

test('local priority supports reload and a new edit without losing another field', async () => {
  const f = fixture({ preferLocal: true });
  f.row.first = 'remote before first save';
  await f.apply(f.mutation);
  const reloaded = structuredClone(f.row);
  await f.apply({ ...f.mutation, writeId: randomUUID(),
    fields: { first: 'next local edit' }, baseFields: { first: reloaded.first } });
  assert.equal(f.row.first, 'next local edit');
  assert.equal(f.row.second, 'old');
  assert.equal(f.patches(), 2);
});

test('local priority retries against a changed revision before overwriting', async () => {
  const f = fixture({ preferLocal: true });
  let attempted = 0;
  const apply = createGuardedMutation({ preferLocal: true, readRecord: f.readRecord,
    writer: async input => {
      if (++attempted === 1) {
        f.row.first = 'concurrent';
        f.row.app_sync_revision = randomUUID();
        return { status: 'not_confirmed', reason: 'revision_changed' };
      }
      return f.writer(input);
    } });
  await apply(f.mutation);
  assert.equal(f.row.first, 'local');
  assert.equal(attempted, 2);
  assert.equal(f.patches(), 1);
});

test('missing baseline is unknown, never treated as null', async () => {
  const f = fixture();
  f.row.first = null;
  await assert.rejects(f.apply({ ...f.mutation, baseFields: {} }), e => e.status === 409);
  await f.apply({ ...f.mutation, baseFields: { first: null } });
  assert.equal(f.row.first, 'local');
});

test('lost response retries with the same write id and sends no second PATCH', async () => {
  const f = fixture({ loseResponse: true });
  await assert.rejects(f.apply(f.mutation), /could not be confirmed/);
  const result = await f.apply(f.mutation);
  assert.equal(result.replay, true);
  assert.equal(f.patches(), 1);
});

test('reused write id with a different patch cannot overwrite the first write', async () => {
  const f = fixture();
  await f.apply(f.mutation);
  await assert.rejects(f.apply({ ...f.mutation, fields: { first: 'different' } }), e => e.status === 409);
  assert.equal(f.patches(), 1);
});

test('two concurrent writers preserve both independent edits after guarded replan', async () => {
  const f = fixture();
  let arrive = 0;
  let release;
  const barrier = new Promise(r => { release = r; });
  const apply = createGuardedMutation({ readRecord: f.readRecord, writer: async input => {
    if (++arrive <= 2) { if (arrive === 2) release(); await barrier; }
    return f.writer(input);
  } });
  // A confirmation can be overtaken by B; 503 in that case is intentional.
  const a = f.mutation;
  const b = { ...a, writeId: randomUUID(), fields: { second: 'other' }, baseFields: { second: 'old' } };
  await Promise.allSettled([apply(a), apply(b)]);
  await f.apply(a);
  await f.apply(b);
  assert.equal(f.row.first, 'local');
  assert.equal(f.row.second, 'other');
});

test('same-field concurrent writes have a single winner', async () => {
  const f = fixture();
  const outcomes = await Promise.allSettled([
    f.apply(f.mutation),
    f.apply({ ...f.mutation, writeId: randomUUID(), fields: { first: 'other' } }),
  ]);
  assert.equal(outcomes.filter(o => o.status === 'fulfilled').length, 1);
  assert.ok(['local', 'other'].includes(f.row.first));
});

test('changes during read/write cause bounded retries, never an unconditional write', async () => {
  const f = fixture();
  let attempts = 0;
  const apply = createGuardedMutation({ readRecord: f.readRecord, writer: async () => {
    attempts++;
    return { status: 'not_confirmed', reason: 'revision_changed' };
  } });
  await assert.rejects(apply(f.mutation), e => e.status === 503);
  assert.equal(attempts, 2);
});

test('a local undo cannot acknowledge a different remote value without client reconciliation', async () => {
  const f = fixture();
  f.row.first = 'remote';
  await assert.rejects(f.apply({ ...f.mutation, fields: { first: 'old' } }),
    e => e.status === 409 && e.code === 'SYNC_REMOTE_VALUES_REQUIRE_REVIEW');
  assert.equal(f.row.first, 'remote');
  assert.equal(f.patches(), 0);
});

test('typed baseline and replay share the same schema-aware comparison', async () => {
  const f = fixture();
  f.row.first = '2026-09-09 09:30:00+00:00';
  const apply = createGuardedMutation({ readRecord: f.readRecord,
    readColumns: async () => [{ title: 'first', uidt: 'DateTime' }],
    writer: async ({ writeId }) => {
      f.row.first = '2026-09-10 09:30:00+00:00';
      f.row.app_sync_revision = writeId;
      return { status: 'applied', replay: false };
    } });
  const mutation = { ...f.mutation, fields: { first: '2026-09-10T09:30:00.000Z' }, baseFields: { first: '2026-09-09T09:30:00.000Z' } };
  assert.equal((await apply(mutation)).applied, true);
  assert.equal((await apply(mutation)).replay, true);
});

test('an overtaken confirmation never acknowledges the operation', async () => {
  const f = fixture();
  const apply = createGuardedMutation({ readRecord: f.readRecord,
    writer: async () => ({ status: 'not_confirmed', reason: 'confirmation_mismatch' }) });
  await assert.rejects(apply(f.mutation), e => e.status === 503);
});

test('fresh authorization is checked before each attempt', async () => {
  const f = fixture();
  await assert.rejects(f.apply({ ...f.mutation, authorizeObserved: () => false }), e => e.status === 403);
  assert.equal(f.patches(), 0);
});

test('unprepared revisions and missing mutation IDs fail closed', async () => {
  const f = fixture();
  await assert.rejects(f.apply({ ...f.mutation, writeId: null }), e => e.status === 428);
  delete f.row.app_sync_revision;
  await assert.rejects(f.apply(f.mutation), e => e.status === 503);
  assert.equal(f.patches(), 0);
});

test('structured values are compared atomically', () => {
  const plan = planDatabaseMutation({ fields: { occupants: ['local'], phone: 'new' },
    baseFields: { occupants: ['old'], phone: 'old' }, observed: { occupants: ['remote'], phone: 'old' } });
  assert.deepEqual(plan.conflicts, ['occupants']);
});

for (const [name, fields] of [
  ['reserved identity', { Id: 1 }],
  ['reserved revision', { app_sync_revision: 'unchanged' }],
  ['prototype key', JSON.parse('{"__proto__":"unchanged"}')],
  ['filter syntax', { 'first,eq,other': 'unchanged' }],
  ['nested database value', { first: { value: 'unchanged' } }],
  ['nonfinite number', { first: Infinity }],
  ['undefined value', { first: undefined }],
  ['empty patch', {}],
]) {
  test(`invalid ${name} cannot bypass validation through a no-op`, async () => {
    let reads = 0;
    const apply = createGuardedMutation({
      readRecord: async () => { reads++; return { ...fields, app_sync_revision: randomUUID() }; },
      writer: async () => assert.fail('Invalid mutation must never be written'),
    });
    await assert.rejects(apply({ tableId: 'table1', recordId: 1,
      writeId: randomUUID(), fields, baseFields: fields }),
    e => e.statusCode === 400 && e.code === 'SYNC_MUTATION_INVALID');
    assert.equal(reads, 0);
  });
}

test('malformed baseline is rejected before replay acknowledgment', async () => {
  const f = fixture();
  f.row.app_sync_revision = f.mutation.writeId;
  f.row.first = f.mutation.fields.first;
  await assert.rejects(f.apply({ ...f.mutation, baseFields: { first: [] } }),
    e => e.statusCode === 400);
  assert.equal(f.patches(), 0);
});

test('uncertain write carries a retryable HTTP status outside route adapters', async () => {
  const f = fixture({ loseResponse: true });
  await assert.rejects(f.apply(f.mutation), e => e.statusCode === 503 &&
    e.code === 'NOCODB_CONDITIONAL_WRITE_UNCERTAIN');
  assert.equal((await f.apply(f.mutation)).replay, true);
  assert.equal(f.patches(), 1);
});

import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import test from 'node:test';
import { createConditionalRecordWriter, ConditionalWriteUncertainError } from './nocodbConditionalWrite.mjs';

function fixture({ loseResponse = false, failReadback = false, skipWrite = false, wrongBase = false } = {}) {
  const seed = randomUUID();
  const row = { Id: 1, app_sync_revision: seed, value: 'original', marker_a: '', marker_b: '' };
  const calls = [];
  let patches = 0;
  const request = async ({ method, path, body }) => {
    calls.push({ method, path, body });
    if (path.includes('/meta/')) return { id: 'table1', base_id: wrongBase ? 'other' : 'base1', columns: [
      { title: 'Id', pk: true, uidt: 'ID' },
      ...['app_sync_revision', 'value', 'marker_a', 'marker_b'].map((title) => ({ title, uidt: 'SingleLineText' })),
    ] };
    if (method === 'GET') {
      if (failReadback && patches) throw new Error('readback unavailable');
      return { list: [structuredClone(row)] };
    }
    patches += 1;
    const where = new URL(path, 'https://example.test').searchParams.get('where');
    assert.match(where, /^\(Id,eq,1\)~and\(app_sync_revision,eq,[0-9a-f-]+\)$/);
    assert.equal(Object.hasOwn(body, 'Id'), false);
    if (!skipWrite && where.includes(`eq,${row.app_sync_revision})`)) Object.assign(row, structuredClone(body));
    if (loseResponse && patches === 1) throw new Error('lost response after applying');
    return 1; // Even a rejected guard deliberately claims success.
  };
  const writer = createConditionalRecordWriter({ baseId: 'base1', allowedTableIds: ['table1'], request });
  const mutation = { tableId: 'table1', recordId: 1, expectedRevision: seed, writeId: randomUUID(), fields: { value: 'new' } };
  return { writer, request, mutation, row, calls, patches: () => patches };
}

test('confirms actual content and new revision instead of an HTTP count', async () => {
  const f = fixture();
  assert.deepEqual(await f.writer(f.mutation), { status: 'applied', revision: f.mutation.writeId, replay: false });
  assert.equal(f.row.value, 'new');
});

test('a false success count never acknowledges an unapplied write', async () => {
  const f = fixture({ skipWrite: true });
  const result = await f.writer(f.mutation);
  assert.equal(result.status, 'not_confirmed');
  assert.equal(result.reason, 'confirmation_mismatch');
});

test('lost response can be confirmed on retry without sending a second PATCH', async () => {
  const f = fixture({ loseResponse: true });
  await assert.rejects(f.writer(f.mutation), ConditionalWriteUncertainError);
  assert.equal(f.row.app_sync_revision, f.mutation.writeId);
  const result = await f.writer(f.mutation);
  assert.equal(result.status, 'applied');
  assert.equal(result.replay, true);
  assert.equal(f.patches(), 1);
});

test('failed readback retains uncertainty, without automatic retry', async () => {
  const f = fixture({ failReadback: true });
  await assert.rejects(f.writer(f.mutation), ConditionalWriteUncertainError);
  assert.equal(f.patches(), 1);
});

test('a newer revision is not overwritten', async () => {
  const f = fixture();
  f.row.app_sync_revision = randomUUID();
  assert.equal((await f.writer(f.mutation)).reason, 'revision_changed');
  assert.equal(f.patches(), 0);
});

test('reusing a writeId for different contents is never treated as success', async () => {
  const f = fixture();
  await f.writer(f.mutation);
  assert.equal((await f.writer({ ...f.mutation, fields: { value: 'different' } })).reason, 'write_id_mismatch');
  assert.equal(f.patches(), 1);
});

test('a competing write after our PATCH remains unconfirmed, not a definite failure', async () => {
  const f = fixture();
  const request = async (req) => {
    const result = await f.request(req);
    if (req.method === 'PATCH') f.row.app_sync_revision = randomUUID();
    return result;
  };
  const writer = createConditionalRecordWriter({ baseId: 'base1', allowedTableIds: ['table1'], request });
  assert.equal((await writer(f.mutation)).status, 'not_confirmed');
  assert.equal(f.patches(), 1);
});

test('two simultaneous guarded writes do not both report success', async () => {
  const f = fixture();
  let waiting = 0;
  let release;
  const barrier = new Promise((resolve) => { release = resolve; });
  const request = async (req) => {
    if (req.method === 'PATCH') { if (++waiting === 2) release(); await barrier; }
    return f.request(req);
  };
  const writer = createConditionalRecordWriter({ baseId: 'base1', allowedTableIds: ['table1'], request });
  const outcomes = await Promise.all([
    writer({ ...f.mutation, fields: { value: 'A', marker_a: 'A' } }),
    writer({ ...f.mutation, writeId: randomUUID(), fields: { value: 'B', marker_b: 'B' } }),
  ]);
  assert.equal(outcomes.filter((o) => o.status === 'applied').length, 1);
  assert.ok((f.row.marker_a === 'A') !== (f.row.marker_b === 'B'));
});

test('only allowlisted tables in the verified base can be written', async () => {
  const f = fixture({ wrongBase: true });
  await assert.rejects(f.writer(f.mutation), /mismatch/);
  await assert.rejects(f.writer({ ...f.mutation, tableId: 'other' }), /not enabled/);
  assert.equal(f.patches(), 0);
});

test('invalid filter inputs and dangerous fields are rejected before network access', async () => {
  const f = fixture();
  for (const changes of [
    { recordId: 0 }, { recordId: '1~or(x,eq,y)' }, { expectedRevision: '' },
    { writeId: f.mutation.expectedRevision }, { fields: {} },
    { fields: { Id: 2 } }, { fields: { app_sync_revision: randomUUID() } },
    { fields: { 'value)~or(x': 'oops' } }, { fields: { value: undefined } },
    { fields: { value: Infinity } }, { fields: { value: ['complex'] } },
  ]) await assert.rejects(f.writer({ ...f.mutation, ...changes }), TypeError);
  assert.equal(f.calls.length, 0);
});

test('an absent or unsupported column fails before a write', async () => {
  const f = fixture();
  await assert.rejects(f.writer({ ...f.mutation, fields: { missing: 'value' } }), /column/);
  assert.equal(f.patches(), 0);
});

test('a missing revision column prevents activation', async () => {
  const f = fixture();
  const request = async (req) => {
    const result = await f.request(req);
    if (result.columns) result.columns = result.columns.filter((c) => c.title !== 'app_sync_revision');
    return result;
  };
  const writer = createConditionalRecordWriter({ baseId: 'base1', allowedTableIds: ['table1'], request });
  await assert.rejects(writer(f.mutation), /not prepared/);
  assert.equal(f.patches(), 0);
});

test('only scalar foreign keys backed by a same-base belongs-to relation are allowed', async () => {
  for (const kind of ['valid', 'orphan', 'cross-base', 'link-array']) {
    const f = fixture();
    f.row.parent_id = 1;
    const request = async (input) => {
      const result = await f.request(input);
      if (result.columns) {
        result.columns.push({ id: 'fk1', title: 'parent_id', uidt: kind === 'link-array' ? 'Links' : 'ForeignKey' });
        if (kind !== 'orphan') result.columns.push({ title: 'Parent', uidt: 'LinkToAnotherRecord',
          colOptions: { type: 'bt', fk_child_column_id: 'fk1', fk_related_model_id: 'parent1',
            fk_related_base_id: kind === 'cross-base' ? 'other' : null } });
      }
      return result;
    };
    const writer = createConditionalRecordWriter({ baseId: 'base1', allowedTableIds: ['table1'], request });
    const mutation = { ...f.mutation, fields: { parent_id: 2 } };
    if (kind === 'valid') {
      assert.equal((await writer(mutation)).status, 'applied');
      assert.equal(f.row.parent_id, 2);
      await assert.rejects(writer({ ...mutation, fields: { parent_id: '2' } }), /positive integer/);
    } else {
      await assert.rejects(writer(mutation), e => e.statusCode === 503);
      assert.equal(f.patches(), 0);
    }
  }
});

test('typed date and checkbox confirmation does not leave successful writes pending', async () => {
  const f = fixture();
  f.row.instant = '2026-09-09 09:30:00+00:00';
  f.row.enabled = false;
  const request = async (input) => {
    const result = await f.request(input);
    if (result.columns) result.columns.push({ title: 'instant', uidt: 'DateTime' }, { title: 'enabled', uidt: 'Checkbox' });
    if (input.method === 'PATCH') {
      assert.equal(input.body.enabled, true);
      f.row.instant = '2026-09-10 09:30:00+00:00';
    }
    return result;
  };
  const writer = createConditionalRecordWriter({ baseId: 'base1', allowedTableIds: ['table1'], request });
  const mutation = { ...f.mutation, fields: { instant: '2026-09-10T09:30:00.000Z', enabled: 'true' } };
  assert.equal((await writer(mutation)).status, 'applied');
  assert.equal((await writer(mutation)).replay, true);
  assert.equal(f.patches(), 1);
});

test('verified accented column titles are supported without permitting filter syntax', async () => {
  const f = fixture();
  const key = 'reconnaissance_invalidit\u00e9_mdph_txt';
  f.row[key] = '';
  const request = async (input) => {
    const result = await f.request(input);
    if (result.columns) result.columns.push({ title: key, uidt: 'LongText' });
    return result;
  };
  const writer = createConditionalRecordWriter({ baseId: 'base1', allowedTableIds: ['table1'], request });
  assert.equal((await writer({ ...f.mutation, fields: { [key]: 'updated' } })).status, 'applied');
  assert.equal(f.row[key], 'updated');
  await assert.rejects(writer({ ...f.mutation, fields: { [`${key},Id`]: 'bad' } }), /Invalid/);
});

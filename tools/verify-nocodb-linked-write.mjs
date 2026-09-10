import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { pathToFileURL } from 'node:url';
import { STAGING_BASE, createProbeRestRequest, conditionalProbeRequest } from './probe-nocodb-conditional-write.mjs';
import { createConditionalRecordWriter, validateConditionalSchema } from '../server/nocodbConditionalWrite.mjs';
import { createGuardedMutation } from '../server/guardedMutation.mjs';

// Always create fresh fixtures. Never accept a caller-provided table or row.
export async function verifyLinkedWrite({ baseId, apply = false, request, onCreated = () => {} }) {
  assert.equal(baseId, STAGING_BASE, 'Only the approved synthetic staging base is allowed');
  if (!apply) return { mode: 'dry-run', baseId, createsTables: 2, touchesBusinessData: false };
  const suffix = randomUUID().replaceAll('-', '');
  const create = async (kind, extra) => {
    const title = `codex_linked_${kind}_${suffix}`;
    const table = await request({ method: 'POST', path: `/api/v2/meta/bases/${baseId}/tables`, body: {
      title, table_name: title, columns: [
        { title: 'Id', column_name: 'id', uidt: 'Number', dt: 'integer', pk: true, rqd: true },
        { title: 'value', column_name: 'value', uidt: 'SingleLineText', dt: 'character varying', pv: true },
        ...extra,
      ],
    } });
    assert.match(table?.id ?? '', /^[a-zA-Z0-9_]+$/);
    onCreated({ tableId: table.id, title, retainedOnFailure: true });
    const schema = await request({ method: 'GET', path: `/api/v2/meta/tables/${table.id}` });
    assert.equal(schema.base_id, baseId);
    assert.equal(schema.title, title);
    return schema;
  };
  const parent = await create('parent', []);
  const child = await create('child', [
    { title: 'app_sync_revision', column_name: 'app_sync_revision', uidt: 'SingleLineText', dt: 'character varying' },
    { title: 'enabled', column_name: 'enabled', uidt: 'Checkbox', dt: 'boolean' },
    { title: 'day', column_name: 'day', uidt: 'Date', dt: 'date' },
    { title: 'instant', column_name: 'instant', uidt: 'DateTime', dt: 'timestamp' },
    { title: 'details', column_name: 'details', uidt: 'LongText', dt: 'text' },
  ]);
  await request({ method: 'POST', path: `/api/v2/meta/tables/${child.id}/columns`, body: {
    title: 'ParentRef', childId: child.id, parentId: parent.id, type: 'bt', uidt: 'LinkToAnotherRecord',
  } });
  const linked = await request({ method: 'GET', path: `/api/v2/meta/tables/${child.id}` });
  assert.equal(linked.base_id, baseId);
  const relation = linked.columns.find((c) => c.title === 'ParentRef');
  assert.equal(relation?.colOptions?.fk_related_model_id, parent.id);
  const fk = linked.columns.find((c) => c.id === relation.colOptions.fk_child_column_id);
  assert.equal(fk?.uidt, 'ForeignKey');
  await request({ method: 'PATCH', path: `/api/v2/meta/columns/${fk.id}`, body: { title: 'parent_id' } });
  const schema = await request({ method: 'GET', path: `/api/v2/meta/tables/${child.id}` });
  assert.ok(schema.columns.some((c) => c.id === fk.id && c.title === 'parent_id' && c.uidt === 'ForeignKey'));
  await request({ method: 'POST', path: `/api/v2/tables/${parent.id}/records`, body: [
    { Id: 1, value: 'synthetic parent A' }, { Id: 2, value: 'synthetic parent B' },
  ] });
  const seed = randomUUID();
  await request({ method: 'POST', path: `/api/v2/tables/${child.id}/records`, body: [
    { Id: 1, value: 'original', app_sync_revision: seed, parent_id: 1, enabled: false },
    { Id: 2, value: 'untouched sentinel', app_sync_revision: seed, parent_id: 1, enabled: false },
  ] });
  const read = async () => {
    const result = await request({ method: 'GET', path: `/api/v2/tables/${child.id}/records?limit=10` });
    assert.equal(result?.list?.length, 2);
    return result.list;
  };
  const initial = await read();
  const target = (rows) => rows.find((r) => Number(r.Id) === 1);
  const sentinel = (rows) => rows.find((r) => Number(r.Id) === 2);
  const revision = randomUUID();
  const input = conditionalProbeRequest({ baseId, tableId: child.id, rowId: 1,
    expected: seed, revision, value: 'linked update' });
  Object.assign(input.body, { parent_id: 2, enabled: true, day: '2026-09-10',
    instant: '2026-09-10T09:30:00.000Z', details: JSON.stringify({ rdc: ['sdb'] }) });
  await request(input);
  const rows = await read();
  const updated = target(rows);
  assert.equal(updated.app_sync_revision, revision);
  assert.equal(Number(updated.parent_id), 2);
  assert.equal(Number(updated.ParentRef?.Id), 2, 'The foreign key must update the actual relation');
  assert.equal(updated.enabled, true);
  assert.equal(updated.day, '2026-09-10');
  assert.equal(Date.parse(updated.instant), Date.parse(input.body.instant));
  assert.equal(updated.details, input.body.details);
  assert.deepEqual(sentinel(rows), sentinel(initial));
  await request({ ...input, body: { value: 'stale must not apply', parent_id: 1, app_sync_revision: randomUUID() } });
  assert.deepEqual(await read(), rows);
  return { mode: 'applied', baseId, parentTableId: parent.id, childTableId: child.id,
    retained: true, checks: ['foreign-key-and-relation', 'checkbox', 'date', 'datetime', 'json-text', 'stale-rejected', 'sentinel-unchanged'],
    representations: { enabled: updated.enabled, day: updated.day, instant: updated.instant, parent_id: updated.parent_id } };
}

export async function verifyExistingLinkedTransport({ baseId, apply = false, request }) {
  assert.equal(baseId, STAGING_BASE);
  const tableId = 'm4jwiaxge75rmnz';
  const title = 'codex_linked_child_2ec223b039cc494fac71c7f1299f684a';
  if (!apply) return { mode: 'dry-run', baseId, tableId, title, touchesBusinessData: false };
  let schema = await request({ method: 'GET', path: `/api/v2/meta/tables/${tableId}` });
  assert.equal(schema.title, title);
  let columns = validateConditionalSchema(schema, { tableId, baseId });
  const parentId = columns.find(c => c.title === 'ParentRef')?.colOptions?.fk_related_model_id;
  assert.equal(parentId, 'mdiilatrbpwdfny');
  const parentSchema = await request({ method: 'GET', path: `/api/v2/meta/tables/${parentId}` });
  assert.equal(parentSchema.base_id, baseId);
  assert.equal(parentSchema.title, 'codex_linked_parent_2ec223b039cc494fac71c7f1299f684a');
  const accentedKey = 'reconnaissance_invalidit\u00e9_mdph_txt';
  if (!columns.some(c => c.title === accentedKey)) {
    await request({ method: 'POST', path: `/api/v2/meta/tables/${tableId}/columns`,
      body: { title: accentedKey, column_name: 'invalidity_note', uidt: 'LongText' } });
    schema = await request({ method: 'GET', path: `/api/v2/meta/tables/${tableId}` });
    columns = validateConditionalSchema(schema, { tableId, baseId });
    assert.ok(columns.some(c => c.title === accentedKey && c.uidt === 'LongText'));
  }
  const read = async () => {
    const result = await request({ method: 'GET', path: `/api/v2/tables/${tableId}/records?limit=10` });
    assert.equal(result.list.length, 2);
    const row = result.list.find(r => Number(r.Id) === 1);
    const sentinel = result.list.find(r => Number(r.Id) === 2);
    assert.ok(row && sentinel);
    assert.equal(sentinel.value, 'untouched sentinel');
    return { row, sentinel };
  };
  const initial = await read();
  let patches = 0;
  const writer = createConditionalRecordWriter({ baseId, allowedTableIds: [tableId], request: async (input) => {
    if (input.method === 'PATCH') patches++;
    return request(input);
  } });
  const applyMutation = createGuardedMutation({ writer, readColumns: async () => columns,
    readRecord: async () => (await read()).row });
  const keys = ['parent_id', 'enabled', 'day', 'instant', 'details', accentedKey];
  const mutation = { tableId, recordId: 1, writeId: randomUUID(),
    fields: { parent_id: 1, enabled: 'false', day: '2026-09-11', instant: '2026-09-11T09:30:00.000Z', details: '{"floor":["wc"]}', [accentedKey]: 'synthetic updated text' },
    baseFields: Object.fromEntries(keys.map(key => [key, initial.row[key]])) };
  // Change at least one field even when this retained fixture is verified again.
  mutation.fields.details = JSON.stringify({ floor: ['wc'], marker: mutation.writeId });
  await applyMutation(mutation);
  const after = await read();
  assert.equal(after.row.app_sync_revision, mutation.writeId);
  assert.equal(after.row.ParentRef.Id, 1);
  assert.equal(after.row.enabled, false);
  assert.equal(after.row[accentedKey], 'synthetic updated text');
  assert.deepEqual(await applyMutation(mutation), { applied: true, replay: true });
  assert.equal(patches, 1, 'Typed replay must not write twice');
  const clear = { ...mutation, writeId: randomUUID(), fields: { parent_id: null }, baseFields: { parent_id: 1 } };
  await applyMutation(clear);
  const cleared = await read();
  assert.equal(cleared.row.parent_id, null);
  assert.equal(cleared.row.ParentRef, null);
  await applyMutation({ ...clear, writeId: randomUUID(), fields: { parent_id: 1 }, baseFields: { parent_id: null } });
  assert.deepEqual((await read()).sentinel, initial.sentinel);
  return { mode: 'applied', baseId, tableId, patches, retained: true,
    checks: ['typed-writer-confirmed', 'typed-coordinator-replay-without-patch', 'foreign-key-clear-and-restore', 'accented-column-title', 'sentinel-unchanged'] };
}

async function main(args) {
  assert.ok(args.every((a) => a === '--apply' || a === '--verify-existing' || a === `--base=${STAGING_BASE}`));
  assert.ok(args.includes(`--base=${STAGING_BASE}`));
  const apply = args.includes('--apply');
  const verify = args.includes('--verify-existing') ? verifyExistingLinkedTransport : verifyLinkedWrite;
  console.log(JSON.stringify(await verify({ baseId: STAGING_BASE, apply,
    request: apply ? await createProbeRestRequest() : undefined,
    onCreated: (value) => console.log(JSON.stringify(value)),
  }), null, 2));
}
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main(process.argv.slice(2)).catch((e) => { console.error(e.message); process.exitCode = 1; });
}

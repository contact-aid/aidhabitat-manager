import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import fs from 'node:fs/promises';
import { pathToFileURL } from 'node:url';
import dotenv from 'dotenv';
import { fetchNocodbRestWithDeadline } from '../server/nocodbRequestDeadline.mjs';

export const STAGING_BASE = 'p7jzofcton1tabh';
const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

// No general-purpose bulk API: constrain both identifiers and revision before
// constructing a filter. Never include Id in the PATCH body (NocoDB can take
// a different path when a primary key is supplied there).
export function conditionalProbeRequest({ baseId, tableId, rowId, expected, revision, value, marker }) {
  assert.equal(baseId, STAGING_BASE, 'Only the documented App Ergo Staging base is allowed');
  assert.match(tableId, /^[a-zA-Z0-9_]+$/);
  assert.ok(Number.isSafeInteger(rowId) && rowId > 0);
  assert.match(expected, uuidPattern);
  assert.match(revision, uuidPattern);
  assert.notEqual(expected, revision);
  assert.ok(marker === undefined || marker === 'a' || marker === 'b');
  const query = new URLSearchParams({ where: `(Id,eq,${rowId})~and(app_sync_revision,eq,${expected})` });
  return {
    method: 'PATCH',
    path: `/api/v1/db/data/bulk/noco/${baseId}/${tableId}/all?${query}`,
    body: { value, app_sync_revision: revision, ...(marker ? { [`writer_${marker}`]: 'applied' } : {}) },
  };
}

export async function runConditionalWriteProbe({ baseId, apply = false, request, onCreated = () => {} }) {
  assert.equal(baseId, STAGING_BASE, 'Production and CRM test bases are forbidden');
  if (!apply) return { mode: 'dry-run', baseId, writes: 0, plan: 'Create one isolated synthetic table; verify filtered writes and concurrent writers. No existing table is modified. The probe table is retained.' };
  const title = `codex_sync_probe_${randomUUID().replaceAll('-', '')}`;
  const created = await request({ method: 'POST', path: `/api/v2/meta/bases/${baseId}/tables`, body: {
    title, table_name: title,
    columns: [
      { title: 'Id', column_name: 'id', uidt: 'Number', dt: 'integer', np: '32', ns: '0', pk: true, rqd: true },
      { title: 'app_sync_revision', column_name: 'app_sync_revision', uidt: 'SingleLineText', dt: 'character varying' },
      { title: 'value', column_name: 'value', uidt: 'LongText', dt: 'text' },
      { title: 'writer_a', column_name: 'writer_a', uidt: 'SingleLineText', dt: 'character varying' },
      { title: 'writer_b', column_name: 'writer_b', uidt: 'SingleLineText', dt: 'character varying' },
    ],
  } });
  const tableId = created?.id;
  assert.equal(typeof tableId, 'string');
  assert.match(tableId, /^[a-zA-Z0-9_]+$/);
  onCreated({ baseId, tableId, title });
  const schema = await request({ method: 'GET', path: `/api/v2/meta/tables/${tableId}` });
  assert.equal(schema.base_id, baseId, 'Created table is not in the approved staging base');
  assert.equal(schema.title, title, 'Table identity does not match the newly created fixture');
  const recordsPath = `/api/v2/tables/${tableId}/records`;
  const read = async () => {
    const payload = await request({ method: 'GET', path: `${recordsPath}?limit=10` });
    const rows = Array.isArray(payload) ? payload : payload?.list;
    assert.ok(Array.isArray(rows));
    assert.equal(rows.length, 2, 'Unexpected rows in the isolated fixture');
    return rows;
  };
  const seed = randomUUID();
  await request({ method: 'POST', path: recordsPath, body: [
    { Id: 1, app_sync_revision: seed, value: 'original', writer_a: '', writer_b: '' },
    { Id: 2, app_sync_revision: seed, value: 'untouched sentinel', writer_a: '', writer_b: '' },
  ] });
  const initialRows = await read();
  const initial = initialRows.find((r) => Number(r.Id) === 1);
  const initialSentinel = initialRows.find((r) => Number(r.Id) === 2);
  assert.equal(initial?.app_sync_revision, seed);
  assert.equal(initialSentinel?.app_sync_revision, seed);
  const write = (expected, revision, value, marker) => request(conditionalProbeRequest({ baseId, tableId, rowId: 1, expected, revision, value, marker }));
  const a = randomUUID();
  const b = randomUUID();
  // Never infer success from a count: some NocoDB implementations compute it
  // before executing the UPDATE. Read the stored revision and sentinel.
  const responses = await Promise.all([write(seed, a, 'writer-A', 'a'), write(seed, b, 'writer-B', 'b')]);
  let rows = await read();
  const winner = rows.find((r) => Number(r.Id) === 1);
  const sentinel = rows.find((r) => Number(r.Id) === 2);
  assert.ok([a, b].includes(winner?.app_sync_revision));
  assert.equal(winner.value, winner.app_sync_revision === a ? 'writer-A' : 'writer-B');
  // Distinct marker columns expose the otherwise invisible case where BOTH
  // writes executed after separate prechecks and the second merely won last.
  assert.equal(winner.writer_a, winner.app_sync_revision === a ? 'applied' : initial.writer_a);
  assert.equal(winner.writer_b, winner.app_sync_revision === b ? 'applied' : initial.writer_b);
  assert.equal(sentinel?.value, 'untouched sentinel', 'The Id filter did not isolate the target row');
  assert.equal(sentinel.app_sync_revision, seed);
  assert.deepEqual(sentinel, initialSentinel);
  const winnerSnapshot = structuredClone(winner);
  await write(seed, randomUUID(), 'stale-writer-must-not-win');
  rows = await read();
  assert.deepEqual(rows.find((r) => Number(r.Id) === 1), winnerSnapshot, 'Stale revision was allowed to overwrite the winner');
  assert.deepEqual(rows.find((r) => Number(r.Id) === 2), sentinel);
  const next = randomUUID();
  await write(winner.app_sync_revision, next, 'valid-follow-up');
  rows = await read();
  assert.equal(rows.find((r) => Number(r.Id) === 1)?.app_sync_revision, next);
  assert.equal(rows.find((r) => Number(r.Id) === 1)?.value, 'valid-follow-up');
  assert.deepEqual(rows.find((r) => Number(r.Id) === 2), sentinel);
  return { mode: 'applied', baseId, tableId, title, checks: ['concurrent-writers', 'stale-write-rejected', 'sentinel-unchanged', 'valid-follow-up'], responseCountsNotUsedAsAcknowledgements: responses, retained: true };
}

export async function createProbeRestRequest() {
  const local = dotenv.parse(await fs.readFile('.env.local'));
  const config = { ...local, ...process.env };
  const root = new URL(config.NOCODB_API_URL);
  assert.equal(root.protocol, 'https:', 'The remote probe requires HTTPS');
  const token = config.NOCODB_API_TOKEN;
  assert.ok(token, 'NOCODB_API_TOKEN is required');
  return async ({ method, path, body }) => {
    const { response, text } = await fetchNocodbRestWithDeadline(new URL(path, root.origin), {
      method, headers: { 'xc-token': token, 'Content-Type': 'application/json' },
      body: body === undefined ? undefined : JSON.stringify(body),
    }, { timeoutMs: 30_000, method, path });
    // No fallback/retry after an ambiguous mutation; keep the fixture for inspection.
    if (!response.ok) throw new Error(`Probe ${method} failed with HTTP ${response.status}`);
    return text ? JSON.parse(text) : null;
  };
}

async function main(args) {
  assert.ok(args.every((arg) => arg === '--apply' || arg === `--base=${STAGING_BASE}`), 'Only --apply and the explicit staging base are allowed');
  assert.ok(args.includes(`--base=${STAGING_BASE}`), 'Pass the documented staging base explicitly');
  const apply = args.includes('--apply');
  if (!apply) {
    console.log(JSON.stringify(await runConditionalWriteProbe({ baseId: STAGING_BASE }), null, 2));
    return;
  }
  const request = await createProbeRestRequest();
  console.log(JSON.stringify(await runConditionalWriteProbe({
    baseId: STAGING_BASE, apply, request,
    onCreated: (table) => console.log(JSON.stringify({ createdProbe: table, retainedOnFailure: true })),
  }), null, 2));
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main(process.argv.slice(2)).catch((error) => {
    console.error(`Conditional write probe stopped: ${error.message}`);
    process.exitCode = 1;
  });
}

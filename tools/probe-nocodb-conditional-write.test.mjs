import assert from 'node:assert/strict';
import test from 'node:test';
import { randomUUID } from 'node:crypto';
import { conditionalProbeRequest, runConditionalWriteProbe, STAGING_BASE } from './probe-nocodb-conditional-write.mjs';

function syntheticServer({ unsafePrecheck = false, ignoreId = false, wrongBase = false, failPatch = false } = {}) {
  const calls = [];
  let title;
  let rows = [];
  let racing = 0;
  let release;
  const barrier = new Promise((resolve) => { release = resolve; });
  const request = async ({ method, path, body }) => {
    calls.push({ method, path, body });
    if (method === 'POST' && path.includes('/meta/')) { title = body.title; return { id: 'probe_table' }; }
    if (method === 'GET' && path.includes('/meta/')) return { title, base_id: wrongBase ? 'production' : STAGING_BASE };
    if (method === 'POST') { rows = structuredClone(body); return structuredClone(rows); }
    if (method === 'GET') return { list: structuredClone(rows) };
    assert.equal(method, 'PATCH');
    if (failPatch) throw new Error('ambiguous timeout');
    const where = new URL(path, 'https://example.test').searchParams.get('where');
    const match = /^\(Id,eq,(\d+)\)~and\(app_sync_revision,eq,([0-9a-f-]+)\)$/.exec(where);
    assert.ok(match);
    assert.equal(Object.hasOwn(body, 'Id'), false);
    const candidates = rows.filter((row) => (ignoreId || row.Id === Number(match[1])) && row.app_sync_revision === match[2]);
    if (body.value === 'writer-A' || body.value === 'writer-B') {
      racing += 1;
      if (racing === 2) release();
      await barrier;
    }
    for (const row of candidates) {
      if (unsafePrecheck || row.app_sync_revision === match[2]) Object.assign(row, structuredClone(body));
    }
    return candidates.length; // Deliberately report the pre-write count.
  };
  return { request, calls };
}

test('dry-run performs no network request', async () => {
  const result = await runConditionalWriteProbe({ baseId: STAGING_BASE, request: () => { throw new Error('unexpected request'); } });
  assert.equal(result.writes, 0);
  assert.equal(result.mode, 'dry-run');
});

for (const baseId of ['pskgbjythubfzv9', 'nocodb_test', '', undefined]) {
  test(`rejects unapproved base ${baseId} even in dry-run`, async () => {
    await assert.rejects(runConditionalWriteProbe({ baseId, request: () => assert.fail('must not call') }));
  });
}

test('conditional filter cannot be empty or omit identity/revision', () => {
  const input = { baseId: STAGING_BASE, tableId: 'test_table', rowId: 1, expected: randomUUID(), revision: randomUUID(), value: 'synthetic' };
  const req = conditionalProbeRequest(input);
  assert.match(new URL(req.path, 'https://example.test').searchParams.get('where'), /^\(Id,eq,1\)~and\(app_sync_revision,eq,/);
  for (const bad of [ { expected: '' }, { expected: '(x,eq,1)' }, { tableId: '../prod' }, { rowId: 0 }, { rowId: 1.1 }, { revision: input.expected }, { marker: '__proto__' } ]) {
    assert.throws(() => conditionalProbeRequest({ ...input, ...bad }));
  }
  assert.equal(Object.hasOwn(req.body, 'Id'), false);
});

test('stored revision and marker checks succeed even if both responses claim one row', async () => {
  const server = syntheticServer();
  const result = await runConditionalWriteProbe({ baseId: STAGING_BASE, apply: true, request: server.request });
  assert.deepEqual(result.responseCountsNotUsedAsAcknowledgements, [1, 1]);
  assert.equal(result.checks.length, 4);
  assert.equal(result.retained, true);
  assert.equal(server.calls.filter((c) => c.method === 'DELETE').length, 0);
});

test('separate precheck followed by unconditional writes fails the race test', async () => {
  const server = syntheticServer({ unsafePrecheck: true });
  await assert.rejects(runConditionalWriteProbe({ baseId: STAGING_BASE, apply: true, request: server.request }));
});

test('a filter ignoring the Id is caught by the sentinel row', async () => {
  const server = syntheticServer({ ignoreId: true });
  await assert.rejects(runConditionalWriteProbe({ baseId: STAGING_BASE, apply: true, request: server.request }), /Id filter/);
});

test('a mismatched table identity prevents all record mutations', async () => {
  const server = syntheticServer({ wrongBase: true });
  await assert.rejects(runConditionalWriteProbe({ baseId: STAGING_BASE, apply: true, request: server.request }), /approved staging base/);
  assert.equal(server.calls.filter((c) => c.path.includes('/records')).length, 0);
});

test('an ambiguous write is not retried or replaced by a normal PATCH', async () => {
  const server = syntheticServer({ failPatch: true });
  await assert.rejects(runConditionalWriteProbe({ baseId: STAGING_BASE, apply: true, request: server.request }), /ambiguous timeout/);
  const patches = server.calls.filter((c) => c.method === 'PATCH');
  assert.equal(patches.length, 2); // Only the two original concurrent requests.
  assert.ok(patches.every((c) => c.path.includes('/all?where=')));
});

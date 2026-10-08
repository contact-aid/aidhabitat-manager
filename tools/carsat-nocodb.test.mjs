import test from 'node:test';
import assert from 'node:assert/strict';
import { applyPlan, createNocodbClient, makePlan, PRODUCTION_BASE, PRODUCTION_TABLE } from './carsat-nocodb.mjs';

const base = 'staging-test-base';
const table = 'staging-test-table';
const original = [
  { Id: 3, nom: 'CNAV (Assurance retraite / CARSAT)', uuid_source: 'old-3' },
  { Id: 4, nom: 'MSA', uuid_source: 'old-4' },
];
function mockHttp(initial = original, { failAfterCreate = false } = {}) {
  let rows = structuredClone(initial);
  const calls = [];
  const fetchImpl = async (url, options) => {
    const route = new URL(url).pathname;
    calls.push({ route, method: options.method });
    const response = (status, data) => ({ ok: status < 400, status, json: async () => data });
    if (route === `/api/v2/meta/bases/${base}/tables`) return response(200, { list: [{ id: table, title: 'Caisses_de_retraite' }] });
    if (route === `/api/v2/meta/tables/${table}`) return response(200, {
      id: table, base_id: base, title: 'Caisses_de_retraite', columns: ['Id', 'nom', 'uuid_source'].map(title => ({ title })),
    });
    if (route === `/api/v2/tables/${table}/records` && options.method === 'GET') return response(200, { list: rows });
    if (route === `/api/v2/tables/${table}/records` && options.method === 'POST') {
      const body = JSON.parse(options.body);
      rows.push({ Id: 5, ...body });
      if (failAfterCreate) return response(502, {});
      return response(200, rows.at(-1));
    }
    return response(404, {});
  };
  return { client: createNocodbClient({ apiUrl: 'https://example.invalid', token: 'fixture', fetchImpl }), calls, rows: () => rows };
}

test('HTTP staging plan, create, verified ID, and replay without a second POST', async () => {
  const mock = mockHttp();
  const snapshot = await mock.client.read(base);
  const plan = makePlan({ environment: 'staging', baseId: base, ...snapshot, operationId: '00000000-0000-4000-8000-000000000001' });
  assert.equal(plan.action, 'create');
  assert.deepEqual(plan.overlappingLabels, [{ id: '3', nom: 'CNAV (Assurance retraite / CARSAT)' }]);
  assert.deepEqual(await applyPlan(mock.client, plan, { environment: 'staging', baseId: base, exclusiveWindowConfirmed: true }), { created: true, id: '5', verified: true, recoveredAfterUncertainResponse: false });
  assert.deepEqual(await applyPlan(mock.client, plan, { environment: 'staging', baseId: base, exclusiveWindowConfirmed: true }), { created: false, id: '5', verified: true, replay: true });
  assert.equal(mock.calls.filter(call => call.method === 'POST').length, 1);
  assert.deepEqual(mock.rows().slice(0, 2), original);
});

test('uncertain POST is resolved only by matching operation UUID and reread', async () => {
  const mock = mockHttp(original, { failAfterCreate: true });
  const snapshot = await mock.client.read(base);
  const plan = makePlan({ environment: 'staging', baseId: base, ...snapshot, operationId: '00000000-0000-4000-8000-000000000002' });
  assert.equal((await applyPlan(mock.client, plan, { environment: 'staging', baseId: base, exclusiveWindowConfirmed: true })).recoveredAfterUncertainResponse, true);
});

test('changed reference, regional entry, duplicates and missing maintenance window block writes', async () => {
  const mock = mockHttp();
  const snapshot = await mock.client.read(base);
  const plan = makePlan({ environment: 'staging', baseId: base, ...snapshot });
  await assert.rejects(applyPlan(mock.client, plan, { environment: 'staging', baseId: base }), /Exclusive/);
  mock.rows()[1].nom = 'MSA revised';
  await assert.rejects(applyPlan(mock.client, plan, { environment: 'staging', baseId: base, exclusiveWindowConfirmed: true }), /Reference changed/);
  assert.equal(mock.calls.filter(call => call.method === 'POST').length, 0);
  assert.throws(() => makePlan({ environment: 'staging', baseId: base, tableId: table, rows: [...original, { Id: 5, nom: 'CARSAT Bretagne' }] }), /Regional/);
  assert.throws(() => makePlan({ environment: 'staging', baseId: base, tableId: table, rows: [...original, { Id: 5, nom: 'CARSAT' }, { Id: 6, nom: ' carsat ' }] }), /Duplicate/);
});

test('production base and table are fixed; a foreign target cannot be labeled production', () => {
  assert.throws(() => makePlan({ environment: 'production', baseId: base, tableId: table, rows: original }), /mismatch/);
  assert.throws(() => makePlan({ environment: 'production', baseId: PRODUCTION_BASE, tableId: table, rows: original }), /table mismatch/);
  assert.throws(() => makePlan({ environment: 'staging', baseId: PRODUCTION_BASE, tableId: PRODUCTION_TABLE, rows: original }), /mismatch/);
});

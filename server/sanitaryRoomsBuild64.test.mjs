import assert from 'node:assert/strict';
import test from 'node:test';
import { randomUUID } from 'node:crypto';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { mkdtemp, rm, readFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';
import { once } from 'node:events';

if (process.argv.includes('--runner')) await run();
else test('sanitary build64 projections cannot remove rooms or undo deliberate clears', { timeout: 45000 }, async () => {
  const root = await mkdtemp(`${tmpdir()}/secondary-atomic-`);
  try {
    for (const creation of ['1']) {
    const { stdout } = await promisify(execFile)(process.execPath, [fileURLToPath(import.meta.url), '--runner'], {
      cwd: root, timeout: 40000, maxBuffer: 200000,
      env: { NODE_ENV: 'test', AIDHABITAT_API_ONLY: '1', AIDHABITAT_DATA_DIR_PATH: root,
        AUTH_SESSION_SECRET: 'synthetic-secondary-http-session-secret',
        NOCODB_API_URL: 'https://nocodb.test.invalid', NOCODB_API_TOKEN: 'synthetic-conditional-http-token',
        NOCODB_BASE_ID: 'conditional_http_base', NOCODB_FORCE_REST: '1', AIDHABITAT_CONDITIONAL_SYNC: '1',
        AIDHABITAT_UNIQUE_CHILDREN_READY: creation },
    });
    assert.match(stdout, /SANITARY_BUILD64_PASS/);
    }
  } catch (e) { assert.fail(`${e.stdout}\n${e.stderr || e.message}`); }
  finally { await rm(root, { recursive: true, force: true }); }
});

async function run() {
  const { createRestMock, dossierId, ownerEmail, password, baseId } = await import('./test-fixtures/conditionalRoutes.rest.mjs');
  const base = createRestMock();
  const { FIELD_SETS } = await import('./helpers.mjs');
  const cases = [{ table: 'mdukulxcd18ae3o' }];
  const rows = new Map(); let origin; let writes = 0;
  const nativeFetch = globalThis.fetch;
  const json = body => new Response(JSON.stringify(body), { headers: { 'content-type': 'application/json' } });
  globalThis.fetch = async (input, init = {}) => {
    const url = new URL(input instanceof Request ? input.url : input);
    if (origin === url.origin) return nativeFetch(input, init);
    const c = cases.find(c => url.pathname.includes(c.table));
    if (!c) return base.fetch(input, init);
    assert.equal(url.origin, 'https://nocodb.test.invalid');
    if (url.pathname === `/api/v2/meta/tables/${c.table}`) {
      return json({ id: c.table, base_id: baseId, columns: [
        { title: 'Id', pk: true, uidt: 'ID' },
        { title: 'app_sync_revision', uidt: 'SingleLineText' },
        ...[...new Set([...FIELD_SETS.diagnosticSanitaires, 'dossiers_id', 'updated_at', ...Object.keys(rows.get(c.table) || {})].filter(k => !['Id', 'app_sync_revision'].includes(k)))]
          .map(title => ({ title, uidt: title === 'debout_hauteur_coude' ? 'Number' : 'LongText' })),
      ] });
    }
    if ((init.method || 'GET') === 'GET') {
      const row = rows.get(c.table); return json({ list: row ? [structuredClone(row)] : [] });
    }
    if (init.method === 'POST') {
      assert.equal(process.env.AIDHABITAT_UNIQUE_CHILDREN_READY, '1');
      assert.equal(url.pathname, `/api/v2/tables/${c.table}/records`);
      assert(!rows.has(c.table), 'dossier uniqueness');
      writes++;
      const row = { Id: 401, ...JSON.parse(init.body), UpdatedAt: '2026-09-17T10:00:00Z' };
      rows.set(c.table, row);
      return json(row);
    }
    assert.equal(init.method, 'PATCH');
    assert.equal(url.pathname, `/api/v1/db/data/bulk/noco/${baseId}/${c.table}/all`, 'No legacy PATCH or create allowed');
    const match = /^\(Id,eq,401\)~and\(app_sync_revision,eq,([^()]+)\)$/.exec(url.searchParams.get('where'));
    assert(match);
    const row = rows.get(c.table);
    if (row.app_sync_revision === match[1]) {
      writes++; Object.assign(row, JSON.parse(init.body), { UpdatedAt: '2026-09-17T10:00:00Z' });
    }
    return json({ count: 1 });
  };
  const { default: app } = await import('./index.mjs');
  const server = app.listen(0, '127.0.0.1'); await once(server, 'listening');
  origin = `http://127.0.0.1:${server.address().port}`;
  const request = async (path, body, token, method = 'PUT') => {
    const r = await fetch(origin + path, { method, headers: { 'content-type': 'application/json', ...(token ? { 'x-app-session': token } : {}) }, body: JSON.stringify(body) });
    return { status: r.status, body: await r.json() };
  };
  try {
    const login = await request('/api/auth/login', { email: ownerEmail, password }, null, 'POST');
    assert.equal(login.status, 200); const token = login.body.data.token;
    const table = 'mdukulxcd18ae3o';
    const path = `/api/diagnostic-sanitaires/${dossierId}`;
    for (const kind of ['sdb', 'wc']) {
      const key = `${kind}Instances`;
      const dbKey = `${kind}_instances_json`;
      const bathroomDefaults = Object.fromEntries([
        'sdbBaignoire', 'sdbBacDouche', 'sdbVasqueSuspendue', 'sdbVasqueColonne',
        'sdbMeubleVasque', 'sdbBidet', 'sdbParoiDouche', 'sdbSolGlissant', 'sdbMachineALaver',
      ].map(key => [key, false]));
      const bathroomHeights = Object.fromEntries([
        'sdbBaignoireHauteur', 'sdbBacDoucheHauteur', 'sdbVasqueSuspendueHauteur',
        'sdbVasqueColonneHauteur', 'sdbMeubleVasqueHauteur', 'sdbBidetHauteur',
        'sdbParoiDoucheHauteur', 'sdbMachineALaverHauteur', 'porteSdbLargeurSuffisante',
        'porteSdbDimension', 'porteSdbSensAdapte',
      ].map(key => [key, null]));
      const room = (id, height) => kind === 'sdb'
        ? { ...bathroomDefaults, ...bathroomHeights, id, levelField: 'rdc', levelLabel: 'RDC', sdbBaignoire: true, sdbBaignoireHauteur: height }
        : { wcCuvetteBonneHauteur: false, wcCuvetteTropBasse: false, wcCuvetteTropHaute: false, wcBarreRelevement: false, porteWcLargeurSuffisante: null, porteWcDimension: null, porteWcSensAdapte: null, id, levelField: 'rdc', levelLabel: 'RDC', wcCuvetteHauteur: height, observationEquipementsUtilisation: `Fictif ${id}` };
      rows.set(table, { Id: 401, dossier_id: dossierId, uuid_source: 'synthetic-sanitary',
        app_sync_revision: randomUUID(), UpdatedAt: '2026-09-01T00:00:00Z',
        sdb_instances_json: '[]', wc_instances_json: '[]',
        [dbKey]: JSON.stringify([room('one', 41), room('two', 52)]) });
      const pull = async () => {
        const result = await request(path, undefined, token, 'GET');
        assert.equal(result.status, 200); return result.body[key];
      };
      const save = (value, baseline, capable = false) => request(path, { [key]: value,
        concurrency: { version: 1, writeId: randomUUID(), baseValues: { [key]: baseline },
          ...(capable ? { collectionContract: 'collections-v2' } : {}) } }, token);
      const initial = await pull();
      assert.equal(initial.length, 2);
      // Exact64 projection keeps only the first room even after a fresh pull.
      const ipadValue = [{ ...initial[0], ...(kind === 'sdb' ? { sdbBacDouche: true } : { wcCuvetteTropBasse: true }) }];
      const beforeWrites = writes;
      const rejected = await save(ipadValue, initial);
      assert.equal(rejected.status, 409);
      assert.equal(rejected.body.error, 'COLLECTION_CLIENT_UPGRADE_REQUIRED');
      assert.equal(writes, beforeWrites);
      assert.deepEqual((await pull()).map(r => r.id), ['one', 'two']);
      assert.equal((await save([room('one', 71), room('two', 82)], initial, true)).status, 200);
      const offline = await save([room('one', 42)], initial);
      assert.equal(offline.status, 409);
      assert.deepEqual((await pull()).map(r => r.id), ['one', 'two']);
      // Capable clients must also compare the observed values, not overwrite by timestamp.
      assert.equal((await save([room('one', 42)], initial, true)).status, 409);
      const beforeDeletion = await pull();
      assert.equal((await save([], beforeDeletion, true)).status, 200);
      assert.equal((await pull()).length, 0);
      assert.equal((await save([room('one', 46)], beforeDeletion)).status, 409);
      assert.equal((await pull()).length, 0);

    }
    const sparseFixture = JSON.parse(await readFile(new URL('../test/fixtures/sanitary-sparse-payload.synthetic.json', import.meta.url), 'utf8'));
    for (const [name, scenario] of Object.entries(sparseFixture.scenarios)) {
      const baseline = scenario.baseValues;
      rows.set(table, { Id: 401, dossier_id: dossierId, uuid_source: 'synthetic-sanitary',
        app_sync_revision: randomUUID(), UpdatedAt: sparseFixture.source.updatedAt,
        sdb_instances_json: JSON.stringify(baseline.sdbInstances),
        wc_instances_json: JSON.stringify(baseline.wcInstances) });
      const result = await request(path, scenario.wireBody, token);
      assert.equal(result.status, 200, `${name}: ${JSON.stringify(result.body)}`);
      const reopened = await request(path, undefined, token, 'GET');
      assert.equal(reopened.status, 200);
      assert.deepEqual(reopened.body.sdbInstances, scenario.updates.sdbInstances, name);
      assert.deepEqual(reopened.body.wcInstances, scenario.updates.wcInstances, name);
      const noMoreWrites = writes;
      assert.equal((await request(path, scenario.wireBody, token)).status, 200, `${name} replay`);
      assert.equal(writes, noMoreWrites, `${name}: idempotent replay`);
      // A sparse baseline must not gain permission to clear a later remote edit.
      const concurrent = rows.get(table);
      concurrent.app_sync_revision = randomUUID();
      concurrent.sdb_instances_json = JSON.stringify([
        ...scenario.updates.sdbInstances, { id: 'concurrent-bath', levelField: 'floor', sdbBaignoireHauteur: 91 },
      ]);
      const beforeConflict = structuredClone(concurrent);
      const stale = structuredClone(scenario.wireBody);
      stale.concurrency.writeId = randomUUID();
      assert.equal((await request(path, stale, token)).status, 409, `${name}: concurrent edit`);
      assert.equal(writes, noMoreWrites);
      assert.deepEqual(rows.get(table), beforeConflict);

    }
    assert.deepEqual(base.violations, []);
    console.log('SANITARY_BUILD64_PASS');
  } finally { server.closeAllConnections(); await new Promise(resolve => server.close(resolve)); }
}

import assert from 'node:assert/strict';
import test from 'node:test';
import { randomUUID } from 'node:crypto';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';
import { once } from 'node:events';

if (process.argv.includes('--runner')) await run();
else test('actual secondary routes use atomic CAS with no unconditional fallback', { timeout: 45000 }, async () => {
  const root = await mkdtemp(`${tmpdir()}/secondary-atomic-`);
  try {
    for (const creation of ['0', '1']) {
    const { stdout } = await promisify(execFile)(process.execPath, [fileURLToPath(import.meta.url), '--runner'], {
      cwd: root, timeout: 40000, maxBuffer: 200000,
      env: { NODE_ENV: 'test', AIDHABITAT_API_ONLY: '1', AIDHABITAT_DATA_DIR_PATH: root,
        AUTH_SESSION_SECRET: 'synthetic-secondary-http-session-secret',
        NOCODB_API_URL: 'https://nocodb.test.invalid', NOCODB_API_TOKEN: 'synthetic-conditional-http-token',
        NOCODB_BASE_ID: 'conditional_http_base', NOCODB_FORCE_REST: '1', AIDHABITAT_CONDITIONAL_SYNC: '1',
        AIDHABITAT_UNIQUE_CHILDREN_READY: creation },
    });
    assert.match(stdout, /ATOMIC_SECONDARY_PASS/);
    }
  } catch (e) { assert.fail(`${e.stdout}\n${e.stderr || e.message}`); }
  finally { await rm(root, { recursive: true, force: true }); }
});

async function run() {
  const { createRestMock, dossierId, ownerEmail, password, baseId } = await import('./test-fixtures/conditionalRoutes.rest.mjs');
  const base = createRestMock();
  const cases = [
    { table: 'mbaj91z97utreco', route: 'mesures', key: 'observations', dbKey: 'observations', value: 'new' },
    { table: 'mbaj91z97utreco', route: 'mesures', key: 'deboutHauteurCoude', dbKey: 'debout_hauteur_coude', value: 99, before: 91 },
    { table: 'mbkuomk0aazes1c', route: 'observations', key: 'observationEquipements', dbKey: 'observation_equipements', value: 'new' },
    { table: 'mdukulxcd18ae3o', route: 'diagnostic-sanitaires', key: 'sdbInstances', dbKey: 'sdb_instances_json', value: [{ id: 'room', sdbBaignoire: true }] },
  ];
  const rows = new Map(); let origin; let writes = 0; let barrier;
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
        ...Object.keys(rows.get(c.table) || {}).filter(k => !['Id', 'app_sync_revision'].includes(k))
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
    if (barrier) {
      const b = barrier; b.arrivals++;
      if (b.arrivals === 2) { barrier = null; b.release(); }
      await b.ready;
    }
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
    for (const c of cases) {
      const reset = () => { writes = 0; rows.set(c.table, { Id: 401, dossier_id: dossierId,
        uuid_source: 'child-1', app_sync_revision: randomUUID(), UpdatedAt: '2026-09-01T00:00:00Z',
        [c.dbKey]: c.key === 'sdbInstances' ? null : c.before ?? 'old',
        ...(c.key === 'sdbInstances' ? {
          sdb_niveau_pieces_vie: 'false', sdb_baignoire: 'false',
          ...Object.fromEntries(['baignoire', 'bac_douche', 'vasque_suspendue', 'vasque_colonne',
            'meuble_vasque', 'bidet', 'paroi_douche', 'machine_a_laver'].map(k => [`sdb_${k}_hauteur`, null])),
          porte_sdb_largeur_suffisante: null, porte_sdb_dimension: null, porte_sdb_sens_adapte: null,
        } : {}),
      }); };
      const body = () => ({ [c.key]: c.value, concurrency: { version: 1, writeId: randomUUID(),
        baseValues: { [c.key]: c.key === 'sdbInstances' ? [] : c.before ?? 'old' } } });
      const path = `/api/${c.route}/${dossierId}`;
      reset();
      assert.equal((await request(path, { [c.key]: c.value }, token)).status, 428);
      assert.equal(writes, 0);
      const mutation = body();
      const saved = await request(path, mutation, token);
      assert.equal(saved.status, 200, JSON.stringify(saved));
      assert.equal(writes, 1);
      assert.equal((await request(path, mutation, token)).status, 200);
      assert.equal(writes, 1, 'ACK replay must not write twice');
      reset();
      let release; const ready = new Promise(resolve => { release = resolve; });
      barrier = { ready, release, arrivals: 0 };
      const other = body(); other[c.key] = c.key === 'sdbInstances' ? [{ id: 'another', sdbBaignoire: false }] : c.before ? 100 : 'other';
      const mutations = [body(), other];
      const results = await Promise.all(mutations.map(b => request(path, b, token)));
      assert.equal(results.filter(r => r.status === 200).length, 1, JSON.stringify(results));
      const loser = results.findIndex(r => r.status !== 200);
      assert([409, 503].includes(results[loser].status), JSON.stringify(results));
      // A mismatched post-write read is deliberately uncertain, not a false ACK.
      assert.equal((await request(path, mutations[loser], token)).status, 409);
      assert.equal(writes, 1);
      reset(); rows.delete(c.table);
      const creationReady = process.env.AIDHABITAT_UNIQUE_CHILDREN_READY === '1';
      const create = { ...body(), concurrency: { ...body().concurrency, createIfAbsent: true } };
      const created = await request(path, create, token);
      assert.equal(created.status, creationReady ? 200 : 503, JSON.stringify(created));
      assert.equal(writes, creationReady ? 1 : 0);
      if (creationReady) {
        const replay = await request(path, create, token);
        assert.equal(replay.status, 200, JSON.stringify(replay));
        assert.equal(writes, 1);
      }
    }
    assert.deepEqual(base.violations, []);
    console.log('ATOMIC_SECONDARY_PASS');
  } finally { server.closeAllConnections(); await new Promise(resolve => server.close(resolve)); }
}

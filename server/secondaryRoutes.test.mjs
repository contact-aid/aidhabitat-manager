import assert from 'node:assert/strict';
import test from 'node:test';
import { execFile } from 'node:child_process';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';
import { once } from 'node:events';
import { setImmediate } from 'node:timers/promises';

// The runner lives in this file so this slice needs no fixture-file changes.
// As in conditionalRoutes.test.mjs, import the actual app only in an isolated
// child with synthetic credentials and a fail-closed fetch implementation.
if (process.argv.includes('--secondary-runner')) {
  await runRoutes();
} else {
  test('real Express secondary GET/PUT routes, legacy and captured versions', { timeout: 45000 }, async (t) => {
    const root = await mkdtemp(path.join(tmpdir(), 'aidhabitat-secondary-http-'));
    try {
      const { stdout, stderr } = await promisify(execFile)(process.execPath, [
        fileURLToPath(import.meta.url), '--secondary-runner',
      ], {
        cwd: root,
        env: {
          NODE_ENV: 'test', AIDHABITAT_API_ONLY: '1', AIDHABITAT_DATA_DIR_PATH: root,
          AUTH_SESSION_SECRET: 'synthetic-secondary-http-session-secret',
          NOCODB_API_URL: 'https://nocodb.test.invalid',
          NOCODB_API_TOKEN: 'synthetic-conditional-http-token',
          NOCODB_BASE_ID: 'conditional_http_base', NOCODB_FORCE_REST: '1',
          NOCODB_REST_TIMEOUT_MS: '5000',
        },
        timeout: 40000, maxBuffer: 200000,
      });
      assert.match(stdout, /SECONDARY_ROUTES_PASS/);
      t.diagnostic(stdout.split('\n').filter((line) => /^(PASS |SECONDARY_ROUTES_PASS)/.test(line)).join('\n'));
      if (stderr.trim()) t.diagnostic(stderr.trim());
    } catch (error) {
      assert.fail(`Secondary HTTP integration failed\n${error.stdout || ''}\n${error.stderr || error.message}`);
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });
}

async function runRoutes() {
  const { createRestMock, dossierId, ownerEmail, otherEmail, password } =
    await import('./test-fixtures/conditionalRoutes.rest.mjs');
  const base = createRestMock();
  const before = '2026-09-03T10:00:00.000Z';
  const after = '2026-09-04T11:30:00.000Z';
  const definitions = [
    { route: 'mesures', table: 'mbaj91z97utreco',
      fields: { debout_hauteur_coude: '91', assis_hauteur_assise: '45', observations: 'keep' },
      update: { deboutHauteurCoude: 99 }, changed: 'debout_hauteur_coude', expected: '99',
      untouched: ['assis_hauteur_assise', 'observations'], clear: { observations: null }, clearKey: 'observations' },
    { route: 'observations', table: 'mbkuomk0aazes1c',
      fields: { observation_equipements: 'before', projet_souhait_usage: 'keep', resume_preconisations: 'keep too' },
      update: { observationEquipements: 'after' }, changed: 'observation_equipements', expected: 'after',
      untouched: ['projet_souhait_usage', 'resume_preconisations'],
      clear: { resumePreconisations: null }, clearKey: 'resume_preconisations' },
    { route: 'diagnostic-sanitaires', table: 'mdukulxcd18ae3o',
      fields: { sdb_instances_json: '[{"id":"bathroom","sdbBaignoire":true}]',
        wc_instances_json: '[{"id":"wc","wcCuvetteHauteur":43}]',
        wc_cuvette_hauteur: '43', porte_wc_dimension: '80', observation_equipements_utilisation: 'keep' },
      update: { sdbInstances: [{ id: 'bathroom', sdbBaignoire: false }] },
      changed: 'sdb_instances_json', expected: '[{"id":"bathroom","sdbBaignoire":false}]',
      untouched: ['wc_instances_json', 'wc_cuvette_hauteur', 'porte_wc_dimension', 'observation_equipements_utilisation'],
      clear: { wcInstances: [] }, clearKey: 'wc_instances_json' },
  ];
  const rows = new Map();
  const calls = [];
  const violations = [];
  let hideReadback = false;
  let staleReadback = false;
  let normalizeReadback = false;
  let oldRows = [];
  let didWrite = false;
  let apiOrigin;
  const nativeFetch = globalThis.fetch;
  const json = (body) => new Response(JSON.stringify(body), { headers: { 'content-type': 'application/json' } });
  globalThis.fetch = async (input, init = {}) => {
    const url = new URL(input instanceof Request ? input.url : input);
    if (apiOrigin && url.origin === apiOrigin) return nativeFetch(input, { ...init, redirect: 'error' });
    const match = /^\/api\/v2\/tables\/([^/]+)\/records$/.exec(url.pathname);
    if (!match || !definitions.some((entry) => entry.table === match[1])) return base.fetch(input, init);
    try {
      assert.equal(url.origin, 'https://nocodb.test.invalid');
      assert.equal(new Headers(init.headers).get('xc-token'), 'synthetic-conditional-http-token');
      const method = init.method || 'GET';
      const call = { method, table: match[1], query: Object.fromEntries(url.searchParams) };
      calls.push(call);
      if (method === 'GET') {
        for (const key of url.searchParams.keys()) assert(['offset', 'limit', 'page', 'fields', 'where', 'sort'].includes(key));
        let list = hideReadback && didWrite ? []
          : structuredClone(staleReadback && didWrite ? oldRows : rows.get(match[1]) || []);
        const where = url.searchParams.get('where');
        if (where) {
          const filter = /^\((Id|dossier_id|uuid_source),eq,(.+)\)$/.exec(where);
          assert(filter, `Unexpected filter ${where}`);
          const value = filter[2].startsWith('"') ? JSON.parse(filter[2]) : filter[2];
          list = list.filter((row) => String(row[filter[1]]) === String(value));
        }
        const fields = url.searchParams.get('fields')?.split(',');
        if (fields) list = list.map((row) => Object.fromEntries(fields.map((key) => [key, row[key] ?? null])));
        return json({ list, pageInfo: { totalRows: list.length, isLastPage: true } });
      }
      assert(['PATCH', 'POST'].includes(method), `Unexpected secondary method ${method}`);
      assert.equal(url.search, '');
      call.body = JSON.parse(init.body);
      if (method === 'PATCH') {
        assert(Array.isArray(call.body));
        assert.equal(call.body.length, 1);
      } else {
        assert(!Array.isArray(call.body) && call.body && typeof call.body === 'object');
      }
      const patch = method === 'PATCH' ? call.body[0] : call.body;
      assert(!Object.hasOwn(patch, 'concurrency'));
      assert(!Object.hasOwn(patch, 'expectedUpdatedAt'));
      oldRows = structuredClone(rows.get(match[1]) || []);
      let row;
      if (method === 'PATCH') {
        row = rows.get(match[1]).find((entry) => entry.Id === patch.Id);
        assert(row, 'PATCH must address an existing child row');
      } else {
        assert(!Object.hasOwn(patch, 'Id'));
        row = { Id: 401 };
        rows.set(match[1], [row]);
      }
      Object.assign(row, patch, { UpdatedAt: after });
      if (staleReadback && method === 'POST') {
        // A replica exposes the new identity/version, but not the saved values.
        oldRows = [{ Id: row.Id, uuid_source: row.uuid_source, dossier_id: dossierId, UpdatedAt: after }];
      }
      if (normalizeReadback) {
        if (row.debout_hauteur_coude != null) row.debout_hauteur_coude = Number(row.debout_hauteur_coude);
        if (row.sdb_instances_json != null) row.sdb_instances_json = JSON.stringify(JSON.parse(row.sdb_instances_json), null, 2);
        // The production DateTime columns return whole-second precision.
        for (const key of ['updated_at', 'created_at']) {
          if (row[key]) row[key] = row[key].replace(/\.\d+Z$/, 'Z').replace('T', ' ').replace('Z', '+00:00');
        }
      }
      didWrite = true;
      return json(method === 'PATCH' ? [row] : row);
    } catch (error) {
      violations.push(error.message);
      throw error;
    }
  };
  const { default: app } = await import('./index.mjs');
  const server = app.listen(0, '127.0.0.1');
  await once(server, 'listening');
  apiOrigin = `http://127.0.0.1:${server.address().port}`;
  const request = async (pathname, token, body, method = body === undefined ? 'GET' : 'PUT') => {
    const response = await fetch(apiOrigin + pathname, {
      method, headers: { 'content-type': 'application/json', ...(token ? { 'x-app-session': token } : {}) },
      body: body === undefined ? undefined : JSON.stringify(body), signal: AbortSignal.timeout(8000),
    });
    return { status: response.status, body: await response.json() };
  };
  const expect = (result, status) => {
    assert.equal(result.status, status, JSON.stringify(result.body));
    return result.body;
  };
  let count = 0;
  const failures = [];
  try {
    await setImmediate();
    const login = async (email) => expect(await request('/api/auth/login', undefined, { email, password }, 'POST'), 200).data.token;
    const owner = await login(ownerEmail);
    const other = await login(otherEmail);
    assert.deepEqual(base.violations, []);
    for (const definition of definitions) {
      const { table, route } = definition;
      const pathname = `/api/${route}/${dossierId}`;
      const row = () => rows.get(table)[0];
      const writes = () => calls.filter((call) => ['PATCH', 'POST'].includes(call.method));
      const guarded = (expectedUpdatedAt = before) => ({ ...definition.update, expectedUpdatedAt,
        concurrency: { version: 1, writeId: '11111111-1111-4111-8111-111111111111',
          baseValues: { retained: 'client baseline' } } });
      const check = async (name, run) => {
        base.reset(); calls.length = 0; violations.length = 0; didWrite = false; hideReadback = false;
        staleReadback = false; normalizeReadback = false; oldRows = [];
        rows.set(table, [{ Id: 401, uuid_source: `synthetic-${route}`, dossier_id: dossierId,
          ...definition.fields, UpdatedAt: before, updated_at: '2026-08-01T10:00:00.000Z' }]);
        try {
          await run();
          assert.deepEqual(base.violations, []);
          assert.deepEqual(violations, []);
          count++;
          console.log(`PASS ${route}: ${name}`);
        } catch (error) {
          failures.push(name);
          console.error(`FAIL ${route}: ${name}\n${error.stack}`);
        }
      };
      await check('GET exposes child identity and native version, not dossier or app clock', async () => {
        const result = expect(await request(pathname, owner), 200);
        assert.equal(result.updatedAt, before);
        assert.equal(result.dossierId, dossierId);
        assert.equal(result.id, `synthetic-${route}`);
        assert(!Object.hasOwn(result, 'data'));
        if (route === 'diagnostic-sanitaires') {
          assert(Array.isArray(result.sdbInstances));
          assert(Array.isArray(result.wcInstances));
        } else if (route === 'mesures') {
          assert.equal(result.deboutHauteurCoude, 91);
          assert.equal(result.assisProfondeurGenoux, null);
        } else {
          assert.equal(typeof result.observationEquipements, 'string');
        }
        assert.equal(writes().length, 0);
      });
      await check('absent GET retains null shape', async () => {
        rows.set(table, []);
        assert.equal(expect(await request(pathname, owner), 200), null);
      });
      await check('guarded creation waits for database preparation', async () => {
        rows.set(table, []);
        const body = { ...definition.update, concurrency: {
          version: 1, writeId: '11111111-1111-4111-8111-111111111111',
          createIfAbsent: true, baseValues: {},
        } };
        const result = expect(await request(pathname, owner, body), 503);
        assert.equal(result.error, 'SYNC_CONDITIONAL_NOT_PREPARED');
        assert.equal(writes().length, 0);
      });
      await check('authentication and ownership checked before writes', async () => {
        expect(await request(pathname, undefined, guarded()), 401);
        expect(await request(pathname, other, guarded()), 403);
        expect(await request(pathname, other), 403);
        assert.equal(writes().length, 0);
        assert.equal(calls.length, 0, 'Forbidden requests must not read child data');
      });
      await check('stale child clock returns 409 and remote snapshot without PATCH', async () => {
        const body = guarded('2026-09-02T10:00:00.000Z');
        const captured = structuredClone(body);
        const result = expect(await request(pathname, owner, body), 409);
        assert.equal(result.conflict, true);
        assert.equal(result.remoteUpdatedAt, before);
        assert.equal(result.remoteData[definition.changed], definition.fields[definition.changed]);
        assert.deepEqual(body, captured);
        assert.equal(writes().length, 0);
      });
      await check('guarded PUT preserves absent fields and returns re-read own version', async () => {
        const body = guarded();
        const captured = structuredClone(body);
        const result = expect(await request(pathname, owner, body), 200);
        assert.equal(calls[0].method, 'GET');
        assert.equal(calls[0].query.where, `(dossier_id,eq,${dossierId})`);
        assert.deepEqual(result, { success: true, error: null,
          data: { id: `synthetic-${route}`, dossierId, updatedAt: after } });
        assert.equal(row()[definition.changed], definition.expected);
        for (const key of definition.untouched) {
          assert.equal(row()[key], definition.fields[key]);
          assert(!Object.hasOwn(writes()[0].body[0], key), `Absent ${key} leaked into PATCH`);
        }
        assert.deepEqual(body, captured);
        assert.equal(writes().length, 1);
        assert.equal(expect(await request(pathname, owner), 200).updatedAt, after);
        const replay = expect(await request(pathname, owner, body), 200);
        assert.equal(replay.data.updatedAt, after);
        assert.equal(writes().length, 1, 'Lost-response retry must confirm without a second write');
        row()[definition.changed] = 'concurrent edit';
        expect(await request(pathname, owner, body), 409);
        assert.equal(writes().length, 1, 'A different remote value must remain protected');
      });
      await check('explicit null or empty list still clears supplied field', async () => {
        expect(await request(pathname, owner, definition.clear), 200);
        assert.equal(row()[definition.clearKey], null);
        assert.equal(row()[definition.changed], definition.fields[definition.changed]);
      });
      await check('missing/malformed captured timestamps return 428 without PATCH', async () => {
        for (const value of [undefined, null, '', 'bad', 42, [], {}, '2026-09-03',
          '2026-02-30T10:00:00Z', '2026-09-03T24:00:00Z', '2026-09-03T10:60:00Z']) {
          const body = guarded(); body.expectedUpdatedAt = value;
          expect(await request(pathname, owner, body), 428);
        }
        for (const concurrency of [null, [], 'v1', {}, { version: 2 }]) {
          expect(await request(pathname, owner, { ...guarded(), concurrency }), 428);
        }
        assert.equal(writes().length, 0);
      });
      await check('guarded future timestamp also rejects mismatched version', async () => {
        expect(await request(pathname, owner, guarded('2026-09-05T10:00:00.000Z')), 409);
        assert.equal(writes().length, 0);
      });
      await check('supplied existing-row version never creates a missing row', async () => {
        rows.set(table, []);
        for (const body of [guarded(), { ...definition.update, expectedUpdatedAt: before }]) {
          const result = expect(await request(pathname, owner, body), 409);
          assert.equal(result.remoteUpdatedAt, null);
          assert.equal(result.remoteData, null);
        }
        assert.equal(writes().length, 0);
      });
      await check('unknown child clock rejects captured version', async () => {
        delete row().UpdatedAt; delete row().updated_at;
        assert.equal(expect(await request(pathname, owner), 200).updatedAt, null);
        expect(await request(pathname, owner, guarded()), 409);
        expect(await request(pathname, owner, { ...definition.update, expectedUpdatedAt: before }), 409);
        assert.equal(writes().length, 0);
      });
      await check('never-edited row uses authoritative CreatedAt, not parent clock', async () => {
        delete row().UpdatedAt; delete row().updated_at;
        row().CreatedAt = before;
        assert.equal(expect(await request(pathname, owner), 200).updatedAt, before);
        expect(await request(pathname, owner, guarded()), 200);
      });
      await check('legacy create without timestamp remains supported', async () => {
        rows.set(table, []);
        const result = expect(await request(pathname, owner, definition.update), 200);
        assert.equal(result.success, true);
        assert.equal(result.data.updatedAt, after);
        assert.equal(result.data.dossierId, dossierId);
        assert.match(result.data.id, /^[0-9a-f-]{36}$/);
        assert.equal(writes()[0].method, 'POST');
      });
      await check('legacy update without concurrency retains stale timestamp protection', async () => {
        expect(await request(pathname, owner, { ...definition.update, expectedUpdatedAt: '2026-09-02T10:00:00.000Z' }), 409);
        assert.equal(writes().length, 0);
        expect(await request(pathname, owner, definition.update), 200);
        assert.equal(writes().length, 1);
      });
      await check('missing post-write readback is not falsely acknowledged', async () => {
        hideReadback = true;
        const result = expect(await request(pathname, owner, guarded()), 503);
        assert.equal(result.success, false);
        assert(!Object.hasOwn(result, 'data'));
        assert.equal(writes().length, 1);
      });
      await check('old post-write readback cannot acknowledge changed values', async () => {
        staleReadback = true;
        expect(await request(pathname, owner, guarded()), 503);
        assert.equal(writes().length, 1);
      });
      await check('legacy create with missing or incomplete readback returns 503', async () => {
        for (const missing of [true, false]) {
          rows.set(table, []); didWrite = false;
          hideReadback = missing; staleReadback = !missing;
          expect(await request(pathname, owner, definition.update), 503);
        }
        assert.equal(writes().length, 2);
      });
      await check('known numeric, JSON and zoned timestamp representations verify', async () => {
        normalizeReadback = true;
        expect(await request(pathname, owner, guarded()), 200);
        assert.equal(writes().length, 1);
      });
    }
    assert.deepEqual(failures, []);
    console.log(`SECONDARY_ROUTES_PASS ${count} HTTP scenarios`);
  } finally {
    await new Promise((resolve, reject) => server.close((error) => error ? reject(error) : resolve()));
    globalThis.fetch = nativeFetch;
  }
}

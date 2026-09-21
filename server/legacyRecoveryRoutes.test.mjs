import assert from 'node:assert/strict';
import test from 'node:test';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { once } from 'node:events';

if (!process.argv.includes('--runner')) {
  test('legacy HTTP retries confirm saved data without overwriting competitors', { timeout: 45000 }, async () => {
    const root = await mkdtemp(path.join(tmpdir(), 'legacy-recovery-'));
    try {
      const result = await promisify(execFile)(process.execPath, [fileURLToPath(import.meta.url), '--runner'], {
        cwd: root, timeout: 40000, env: {
          NODE_ENV: 'test', AIDHABITAT_API_ONLY: '1', AIDHABITAT_DATA_DIR_PATH: root,
          AUTH_SESSION_SECRET: 'synthetic-recovery-test-secret',
          NOCODB_API_URL: 'https://nocodb.test.invalid', NOCODB_API_TOKEN: 'synthetic-conditional-http-token',
          NOCODB_BASE_ID: 'conditional_http_base', NOCODB_FORCE_REST: '1',
        },
      });
      assert.match(result.stdout, /RECOVERY_PASS/);
    } catch (error) {
      assert.fail(`${error.stdout || ''}\n${error.stderr || error.message}`);
    } finally { await rm(root, { recursive: true, force: true }); }
  });
} else {
  const { createRestMock, tables, timestamp, patientId, dossierId, ownerEmail, password } =
    await import('./test-fixtures/conditionalRoutes.rest.mjs');
  const mock = createRestMock();
  const nativeFetch = globalThis.fetch;
  let origin;
  let writes = 0;
  let hideVersion = false;
  let active;
  globalThis.fetch = async (input, init = {}) => {
    const url = new URL(input instanceof Request ? input.url : input);
    if (url.origin === origin) return nativeFetch(input, init);
    const match = /^\/api\/v2\/tables\/([^/]+)\/records$/.exec(url.pathname);
    if (match && active && match[1] === tables[active] && init.method === 'PATCH') {
      assert.equal(url.origin, 'https://nocodb.test.invalid');
      const [patch] = JSON.parse(init.body);
      assert.equal(patch.Id, mock.row(active).Id);
      Object.assign(mock.row(active), patch, { UpdatedAt: '2026-09-17T10:00:00.000Z' });
      writes++;
      return Response.json([mock.row(active)]);
    }
    const response = await mock.fetch(input, init);
    if (match && active && match[1] === tables[active] && writes && hideVersion) {
      const body = await response.json();
      body.list = body.list.map((row) => ({ ...row, UpdatedAt: null, updated_at: null, CreatedAt: null, created_at: null }));
      return Response.json(body);
    }
    return response;
  };
  const { default: app } = await import('./index.mjs');
  const server = app.listen(0, '127.0.0.1');
  await once(server, 'listening');
  origin = `http://127.0.0.1:${server.address().port}`;
  try {
    const login = await nativeFetch(`${origin}/api/auth/login`, { method: 'POST',
      headers: { 'content-type': 'application/json' }, body: JSON.stringify({ email: ownerEmail, password }) });
    const token = (await login.json()).data.token;
    for (const [entity, route, appKey, dbKey] of [
      ['dossier', `/api/dossiers/${dossierId}`, 'compteAnah', 'compte_anah'],
      ['beneficiaire', `/api/beneficiaires/${patientId}`, 'phone', 'telephone'],
      ['logement', `/api/logements/by-beneficiary/${patientId}`, 'comments', 'commentaire'],
    ]) {
      for (const missingVersion of [false, true]) {
        mock.reset(); active = entity; writes = 0; hideVersion = missingVersion;
        const body = { [appKey]: 'saved', expectedUpdatedAt: timestamp,
          concurrency: { version: 1, writeId: '11111111-1111-4111-8111-111111111111',
            baseValues: { [appKey]: mock.row(entity)[dbKey] } } };
        const patch = () => nativeFetch(origin + route, { method: 'PATCH',
          headers: { 'content-type': 'application/json', 'x-app-session': token }, body: JSON.stringify(body) });
        const first = await patch();
        assert.equal(first.status, missingVersion ? 503 : 200, `${entity}: ${await first.text()}`);
        hideVersion = false;
        const replay = await patch();
        assert.equal(replay.status, 200, `${entity}: ${await replay.text()}`);
        assert.equal(writes, 1, `${entity}: retry must not write again`);
        mock.row(entity)[dbKey] = 'another device';
        assert.equal((await patch()).status, 409);
        assert.equal(writes, 1);
        assert.deepEqual(mock.violations, []);
      }
    }
    mock.reset(); active = null; mock.removeHousing();
    const writeId = '22222222-2222-4222-8222-222222222222';
    const createBody = { comments: 'first housing', concurrency: {
      version: 1, writeId, createIfAbsent: true, expectedUpdatedAt: null, baseValues: {},
    } };
    const create = (body = createBody) => nativeFetch(
      `${origin}/api/logements/by-beneficiary/${patientId}`,
      { method: 'PATCH', headers: { 'content-type': 'application/json', 'x-app-session': token },
        body: JSON.stringify(body) },
    );
    mock.loseNextResponse();
    assert.equal((await create()).status, 500);
    assert.equal(mock.rows('logement').length, 1, 'the uncertain create committed once');
    const replay = await create();
    if (replay.status !== 200) assert.fail(await replay.text());
    const replayData = await replay.json();
    assert.equal(replayData.data.id, writeId);
    assert.match(replayData.data.updatedAt, /^2026-09-02T10:00:00\.000Z$/);
    assert.equal(mock.rows('logement').length, 1, 'retry must not duplicate housing');

    const competing = await create({ comments: 'other device', concurrency: {
      version: 1, writeId: '33333333-3333-4333-8333-333333333333',
      createIfAbsent: true, expectedUpdatedAt: null, baseValues: {},
    } });
    if (competing.status !== 409) assert.fail(await competing.text());
    assert.equal(mock.rows('logement').length, 1, 'competing creation must not overwrite or duplicate');
    assert.equal(mock.row('logement').commentaire, 'first housing');

    mock.reset(); mock.removeHousing();
    const [deviceA, deviceB] = await Promise.all([
      create({ comments: 'device A', concurrency: { version: 1,
        writeId: '44444444-4444-4444-8444-444444444444', createIfAbsent: true,
        expectedUpdatedAt: null, baseValues: {} } }),
      create({ comments: 'device B', concurrency: { version: 1,
        writeId: '55555555-5555-4555-8555-555555555555', createIfAbsent: true,
        expectedUpdatedAt: null, baseValues: {} } }),
    ]);
    assert.deepEqual([deviceA.status, deviceB.status].sort(), [200, 409]);
    assert.equal(mock.rows('logement').length, 1, 'simultaneous devices create exactly one row');
    assert.deepEqual(mock.violations, []);
    console.log('RECOVERY_PASS');
  } finally { server.closeAllConnections(); await new Promise((resolve) => server.close(resolve)); }
}

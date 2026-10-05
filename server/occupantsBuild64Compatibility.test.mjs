// Characterization tests: successful execution proves why roster writes are EXCLUDED.
import assert from 'node:assert/strict';
import test from 'node:test';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';
import { once } from 'node:events';
import { randomUUID } from 'node:crypto';

if (process.argv.includes('--runner')) await run();
else test('characterize roster loss and clears through real patient route, mocked NocoDB only',
  { timeout: 45000 }, async () => {
    const root = await mkdtemp(`${tmpdir()}/occupants64-http-`);
    try {
      const { stdout } = await promisify(execFile)(process.execPath,
        [fileURLToPath(import.meta.url), '--runner'], { cwd: root, timeout: 40000, maxBuffer: 200000,
          env: { NODE_ENV: 'test', AIDHABITAT_API_ONLY: '1', AIDHABITAT_DATA_DIR_PATH: root,
            AUTH_SESSION_SECRET: 'synthetic-occupants-http-session-secret',
            NOCODB_API_URL: 'https://nocodb.test.invalid', NOCODB_API_TOKEN: 'synthetic-conditional-http-token',
            NOCODB_BASE_ID: 'conditional_http_base', NOCODB_FORCE_REST: '1', AIDHABITAT_CONDITIONAL_SYNC: '1' },
        });
      assert.match(stdout, /OCCUPANTS64_BLOCKERS_REPRODUCED/);
    } catch (error) { assert.fail(`${error.stdout || ''}\n${error.stderr || error.message}`); }
    finally { await rm(root, { recursive: true, force: true }); }
  });

async function run() {
  const { createRestMock, patientId, ownerEmail, password } = await import('./test-fixtures/conditionalRoutes.rest.mjs');
  const mock = createRestMock(); const nativeFetch = globalThis.fetch; let origin;
  globalThis.fetch = async (input, init) => {
    const url = new URL(input instanceof Request ? input.url : input);
    return url.origin === origin ? nativeFetch(input, init) : mock.fetch(input, init);
  };
  const { default: app } = await import('./index.mjs');
  const server = app.listen(0, '127.0.0.1'); await once(server, 'listening');
  origin = `http://127.0.0.1:${server.address().port}`;
  const request = async (path, body, token, method = 'PATCH') => {
    const response = await fetch(origin + path, { method,
      headers: { 'content-type': 'application/json', ...(token ? { 'x-app-session': token } : {}) },
      body: JSON.stringify(body) });
    return { status: response.status, body: await response.json() };
  };
  const alice = { firstName: 'Alice', lastName: 'Fictif', birthDate: '', gender: 'Femme', maidenName: 'Naissance' };
  const bob = { firstName: 'Bob', lastName: 'Fictif', birthDate: '', gender: 'Homme' };
  const legacy = ({ gender, maidenName, ...known }) => known;
  const mutation = (occupants, baseline) => ({ occupants,
    concurrency: { version: 1, writeId: randomUUID(), baseValues: { occupants: baseline } } });
  const reset = (people) => {
    mock.reset(); const row = mock.row('beneficiaire');
    row.occupants_json = JSON.stringify(people); row.nombre_personnes = people.length;
  };
  try {
    const login = await request('/api/auth/login', { email: ownerEmail, password }, null, 'POST');
    assert.equal(login.status, 200); const token = login.body.data.token;
    const path = `/api/beneficiaires/${patientId}`;
    reset([alice, bob]);
    let result = await request(path, mutation([ { ...legacy(alice), homeHelp: true }, legacy(bob) ],
      [alice, bob]), token);
    assert.equal(result.status, 200, JSON.stringify(result));
    let saved = JSON.parse(mock.row('beneficiaire').occupants_json);
    assert.equal(saved[0].gender, 'Femme'); assert.equal(saved[0].maidenName, 'Naissance');
    assert.equal(saved[0].homeHelp, true);

    // Offline64 knew one person. Web added Bob before reconnection.
    reset([alice, bob]);
    result = await request(path, mutation([{ ...legacy(alice), homeHelp: true }], [alice]), token);
    assert.equal(result.status, 200, JSON.stringify(result));
    saved = JSON.parse(mock.row('beneficiaire').occupants_json);
    assert.equal(saved.length, 1, 'BLOCKER: baseline does not stop stale64 deleting Bob');

    // A deliberate web removal is resurrected by an old offline roster.
    reset([alice]);
    result = await request(path, mutation([legacy(alice), legacy(bob)], [alice, bob]), token);
    assert.equal(result.status, 200, JSON.stringify(result));
    saved = JSON.parse(mock.row('beneficiaire').occupants_json);
    assert.equal(saved.length, 2, 'BLOCKER: stale64 resurrects a removed occupant');
    assert.equal(saved[1].firstName, 'Bob');

    // Clear supported today when identities are unchanged; a missing key is not a clear.
    reset([alice]);
    result = await request(path, mutation([{ ...alice, gender: '', maidenName: '' }], [alice]), token);
    assert.equal(result.status, 200, JSON.stringify(result));
    const cleared = JSON.parse(mock.row('beneficiaire').occupants_json);
    assert.equal(cleared[0].gender, ''); assert.equal(cleared[0].maidenName, '');
    result = await request(path, mutation([{ ...legacy(alice), homeHelp: true }], [alice]), token);
    assert.equal(result.status, 200, JSON.stringify(result));
    saved = JSON.parse(mock.row('beneficiaire').occupants_json);
    assert.equal(saved[0].gender, ''); assert(!saved[0].maidenName);
    assert.deepEqual(mock.violations, []);
    console.log('OCCUPANTS64_BLOCKERS_REPRODUCED');
  } finally { server.closeAllConnections(); await new Promise(resolve => server.close(resolve)); }
}

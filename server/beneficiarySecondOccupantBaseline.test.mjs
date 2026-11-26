import assert from 'node:assert/strict';
import test from 'node:test';
import { randomUUID } from 'node:crypto';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { once } from 'node:events';

// Household imported with one legacy row: joint given names, Monsieur's birth
// date, nothing for the second occupant and no occupants JSON. The read
// contract therefore exposes ONE occupant. The iPad then records the second
// occupant's birth date. That one-occupant baseline means "no second occupant
// yet", not "unknown": it must not raise a permanent conflict.
if (!process.argv.includes('--runner')) {
  test('a second occupant added from a one-occupant baseline is not a conflict', { timeout: 45000 }, async () => {
    const root = await mkdtemp(path.join(tmpdir(), 'second-occupant-baseline-'));
    try {
      const result = await promisify(execFile)(process.execPath, [fileURLToPath(import.meta.url), '--runner'], {
        cwd: root, timeout: 40000, env: { NODE_ENV: 'test', AIDHABITAT_API_ONLY: '1',
          AIDHABITAT_DATA_DIR_PATH: root, AUTH_SESSION_SECRET: 'synthetic-second-occupant-secret',
          AIDHABITAT_CONDITIONAL_SYNC: '1', NOCODB_API_URL: 'https://nocodb.test.invalid',
          NOCODB_API_TOKEN: 'synthetic-conditional-http-token', NOCODB_BASE_ID: 'conditional_http_base', NOCODB_FORCE_REST: '1' },
      });
      assert.match(result.stdout, /SECOND_OCCUPANT_PASS/);
    } catch (e) { assert.fail(`${e.stdout || ''}\n${e.stderr || e.message}`); }
    finally { await rm(root, { recursive: true, force: true }); }
  });
} else {
  const { createRestMock, patientId, dossierId, ownerEmail, password } = await import('./test-fixtures/conditionalRoutes.rest.mjs');
  const mock = createRestMock();
  const originalFetch = globalThis.fetch; let origin;
  globalThis.fetch = (input, init) => new URL(input instanceof Request ? input.url : input).origin === origin
    ? originalFetch(input, init) : mock.fetch(input, init);
  const { default: app } = await import('./index.mjs');
  const server = app.listen(0, '127.0.0.1'); await once(server, 'listening'); origin = `http://127.0.0.1:${server.address().port}`;
  try {
    const login = await originalFetch(origin + '/api/auth/login', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ email: ownerEmail, password }) });
    const token = (await login.json()).data.token;
    const headers = { 'content-type': 'application/json', 'x-app-session': token };
    const row = mock.row('beneficiaire');
    Object.assign(row, { prenom: 'Synthetic et Second', nom: 'HOUSEHOLD',
      date_naissance_monsieur: '1940-01-01', date_naissance_madame: null,
      prenom_occupant_2: null, nom_occupant_2: null, occupants_json: null });

    const read = async () => (await (await originalFetch(origin + '/api/dossiers', { headers })).json())
      .find((d) => d.id === dossierId).patient;
    const patient = await read();
    assert.equal(patient.occupants.length, 1, 'legacy row exposes a single occupant');

    const edit = (base) => ({
      occupants: [patient.occupants[0], { firstName: '', lastName: '', birthDate: '1942-02-02' }],
      concurrency: { version: 1, collectionContract: 'collections-v2', writeId: randomUUID(),
        baseValues: { occupants: base } },
    });
    const save = (body) => originalFetch(origin + `/api/beneficiaires/${patientId}`,
      { method: 'PATCH', headers, body: JSON.stringify(body) });

    const saved = await save(edit(patient.occupants));
    assert.equal(saved.status, 200, await saved.text());
    assert.equal(row.date_naissance_madame, '1942-02-02');
    assert.equal(row.date_naissance_monsieur, '1940-01-01', "Monsieur's date is untouched");
    assert.equal(JSON.parse(row.occupants_json).length, 2);

    // A second occupant really recorded elsewhere meanwhile is still a conflict,
    // and nothing is written.
    Object.assign(row, { date_naissance_madame: '1945-05-05', occupants_json: null });
    const writes = mock.patches().length;
    const conflicted = await save(edit([patient.occupants[0]]));
    assert.equal(conflicted.status, 409, await conflicted.text());
    assert.equal(mock.patches().length, writes);
    assert.equal(row.date_naissance_madame, '1945-05-05');
    assert.deepEqual(mock.violations, []);
    console.log('SECOND_OCCUPANT_PASS');
  } finally { await new Promise((r) => server.close(r)); }
}

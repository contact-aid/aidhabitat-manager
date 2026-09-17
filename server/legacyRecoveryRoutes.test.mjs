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
  const mock = createRestMock({ referenceRows: Object.fromEntries(
    ['situations', 'statuts', 'caisses', 'caissesComp'].map((entity) =>
      [entity, [{ Id: 501, nom: 'Selection test', libelle: 'Selection test' }]])) });
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
    for (const storedOccupants of [null, '', '[]']) {
      mock.reset(); active = 'beneficiaire'; writes = 0; hideVersion = false;
      mock.row(active).occupants_json = storedOccupants;
      const read = async () => (await (await nativeFetch(origin + '/api/dossiers', {
        headers: { 'x-app-session': token },
      })).json()).find((row) => row.id === dossierId).patient;
      const patient = await read();
      assert.equal(patient.birthDate, null, 'blank dates must remain available for conflict review');
      assert.equal(patient.occupant1BirthDate, null);
      const body = {
        occupant1BirthDate: '1966-08-04',
        occupants: patient.occupants.map((occupant) => ({ ...occupant, birthDate: '1966-08-04' })),
        expectedUpdatedAt: patient.updatedAt,
        concurrency: { version: 1, writeId: '11111111-1111-4111-8111-111111111111',
          baseValues: { occupant1BirthDate: null, occupants: patient.occupants } },
      };
      const patch = () => nativeFetch(origin + `/api/beneficiaires/${patientId}`, {
        method: 'PATCH', headers: { 'content-type': 'application/json', 'x-app-session': token },
        body: JSON.stringify(body),
      });
      const saved = await patch();
      assert.equal(saved.status, 200, `first birth date: ${await saved.text()}`);
      assert.equal((await read()).occupant1BirthDate, '1966-08-04');
      assert.equal((await patch()).status, 200, 'replay must be acknowledged');
      assert.equal(writes, 1);
      mock.row(active).occupants_json = storedOccupants;
      mock.row(active).date_naissance_monsieur = '1965-02-03';
      assert.equal((await patch()).status, 409, 'a different remote date remains protected');
      body.expectedUpdatedAt = mock.row(active).UpdatedAt;
      assert.equal((await patch()).status, 409, 'a current timestamp must not hide different values');
      mock.row(active).date_naissance_monsieur = null;
      mock.row(active).occupants_json = '{invalid JSON';
      assert.equal((await patch()).status, 409, 'corrupt JSON must never be treated as an empty household');
      assert.equal(writes, 1);
      assert.deepEqual(mock.violations, []);
    }
    for (const [appKey, dbKey, reference] of [
      ['familySituation', 'situation_proprietaire_id1', 'situations'],
      ['occupationStatus', 'statut_occupation_id1', 'statuts'],
      ['caisseRetraitePrincipale', 'caisses_de_retraite_id', 'caisses'],
      ['caissesRetraiteComplementaires', 'caisses_de_retraite_complementaires_id', 'caissesComp'],
    ]) {
      mock.reset(); active = 'beneficiaire'; writes = 0;
      const body = { [appKey]: 'Selection test', expectedUpdatedAt: timestamp,
        concurrency: { version: 1, writeId: '11111111-1111-4111-8111-111111111111', baseValues: { [appKey]: '' } } };
      const patch = () => nativeFetch(origin + `/api/beneficiaires/${patientId}`, {
        method: 'PATCH', headers: { 'content-type': 'application/json', 'x-app-session': token }, body: JSON.stringify(body),
      });
      const saved = await patch();
      assert.equal(saved.status, 200, `${appKey}: ${await saved.text()}`);
      assert.equal(mock.row(active)[dbKey], 501, `${appKey}: selection must actually persist`);
      assert.equal((await patch()).status, 200);
      assert.equal(writes, 1);
      mock.row(active)[dbKey] = 502;
      assert.equal((await patch()).status, 409);
      assert.equal(writes, 1);
    }
    console.log('RECOVERY_PASS');
  } finally { server.closeAllConnections(); await new Promise((resolve) => server.close(resolve)); }
}

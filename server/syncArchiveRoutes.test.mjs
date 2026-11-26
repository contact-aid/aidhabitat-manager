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

// Bout en bout, sur la vraie route : archive activée, table d'archive absente.
// Un envoi qui écraserait une valeur que l'appareil n'avait pas vue doit être
// refusé de façon temporaire, sans aucune écriture. Un envoi qui ne remplace
// que ce que l'appareil avait vu passe sans consulter l'archive.
if (!process.argv.includes('--runner')) {
  test('the real API refuses an unarchivable overwrite and writes nothing', { timeout: 45000 }, async () => {
    const root = await mkdtemp(path.join(tmpdir(), 'sync-archive-routes-'));
    try {
      const result = await promisify(execFile)(process.execPath, [fileURLToPath(import.meta.url), '--runner'], {
        cwd: root, timeout: 40000, env: { NODE_ENV: 'test', AIDHABITAT_API_ONLY: '1',
          AIDHABITAT_DATA_DIR_PATH: root, AUTH_SESSION_SECRET: 'synthetic-archive-secret',
          AIDHABITAT_CONDITIONAL_SYNC: '1', AIDHABITAT_SYNC_ARCHIVE: '1',
          NOCODB_API_URL: 'https://nocodb.test.invalid',
          NOCODB_API_TOKEN: 'synthetic-conditional-http-token', NOCODB_BASE_ID: 'conditional_http_base', NOCODB_FORCE_REST: '1' },
      });
      assert.match(result.stdout, /SYNC_ARCHIVE_ROUTES_PASS/);
    } catch (e) { assert.fail(`${e.stdout || ''}\n${e.stderr || e.message}`); }
    finally { await rm(root, { recursive: true, force: true }); }
  });
} else {
  const { createRestMock, patientId, ownerEmail, password } = await import('./test-fixtures/conditionalRoutes.rest.mjs');
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
    const save = (phone, basePhone) => originalFetch(origin + `/api/beneficiaires/${patientId}`, {
      method: 'PATCH', headers, body: JSON.stringify({ phone,
        concurrency: { version: 1, writeId: randomUUID(), baseValues: { phone: basePhone } } }) });

    // Le serveur a 0100000000, l'appareil croyait 0199999999 : écrasement.
    const writes = mock.patches().length;
    const refused = await save('0611111111', '0199999999');
    assert.equal(refused.status, 503, await refused.text());
    assert.equal(row.telephone, '0100000000', 'nothing overwritten');
    assert.equal(mock.patches().length, writes, 'no write at all');

    // L'appareil remplace la valeur qu'il avait vue : pas d'archive nécessaire.
    const saved = await save('0622222222', '0100000000');
    assert.equal(saved.status, 200, await saved.text());
    assert.equal(row.telephone, '0622222222');
    assert.deepEqual(mock.violations, []);
    console.log('SYNC_ARCHIVE_ROUTES_PASS');
  } finally { await new Promise((r) => server.close(r)); }
}

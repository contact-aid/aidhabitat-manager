import assert from 'node:assert/strict';
import test from 'node:test';
import { createHash } from 'node:crypto';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';
import { once } from 'node:events';

if (process.argv.includes('--runner')) await run();
else test('mandate transports verify the account and accept legacy missing dossierId', async () => {
  const root = await mkdtemp(`${tmpdir()}/mandate-identity-`);
  try {
    const { stdout } = await promisify(execFile)(process.execPath, [fileURLToPath(import.meta.url), '--runner'], {
      cwd: root, timeout: 40000, maxBuffer: 200000,
      env: { NODE_ENV: 'test', AIDHABITAT_API_ONLY: '1', AIDHABITAT_DATA_DIR_PATH: root,
        AUTH_SESSION_SECRET: 'synthetic-mandate-identity-secret', NOCODB_FORCE_REST: '1',
        NOCODB_API_URL: 'https://nocodb.test.invalid', NOCODB_API_TOKEN: 'synthetic-conditional-http-token',
        NOCODB_BASE_ID: 'conditional_http_base' },
    });
    assert.match(stdout, /MANDATE_IDENTITY_PASS/);
  } catch (error) { assert.fail(`${error.stdout || ''}\n${error.stderr || error.message}`); }
  finally { await rm(root, { recursive: true, force: true }); }
});
async function run() {
  const { createRestMock, ownerEmail, password, patientId, dossierId } = await import('./test-fixtures/conditionalRoutes.rest.mjs');
  const mock = createRestMock();
  const nativeFetch = globalThis.fetch;
  let origin;
  globalThis.fetch = (input, init) => new URL(input instanceof Request ? input.url : input).origin === origin
    ? nativeFetch(input, init) : mock.fetch(input, init);
  const { default: app } = await import('./index.mjs');
  const server = app.listen(0, '127.0.0.1'); await once(server, 'listening');
  origin = `http://127.0.0.1:${server.address().port}`;
  try {
    const login = await fetch(`${origin}/api/auth/login`, { method: 'POST',
      headers: { 'content-type': 'application/json' }, body: JSON.stringify({ email: ownerEmail, password }) });
    assert.equal(login.status, 200);
    const token = (await login.json()).data.token;
    const identity = { patientId, dossierId, documentLocalId: `doc_mandat_${dossierId}_${'a'.repeat(64)}` };
    const before = mock.calls.length;
    for (const route of ['/api/documents/upload', '/api/documents', '/api/documents/upload/finalize']) {
      const raw = route === '/api/documents/upload';
      const response = await fetch(origin + route + (raw ? `?${new URLSearchParams(identity)}` : ''), {
        method: 'POST', headers: { 'x-app-session': token, 'content-type': raw ? 'application/pdf' : 'application/json' },
        body: raw ? '%PDF-synthetic' : JSON.stringify({ ...identity, uploadId: 'synthetic-only' }),
      });
      assert.equal(response.status, 403, `${route}: ${await response.text()}`);
    }
    assert(!mock.calls.slice(before).some(call => call.method !== 'GET'));
    assert.deepEqual(mock.violations, []);
    const legacyIdentity = { patientId,
      documentLocalId: `doc_mandat_${dossierId}_${createHash('sha256').update(ownerEmail.trim().toLowerCase()).digest('hex')}`,
      title: 'Synthetic mandate', fileName: 'synthetic.pdf', mimeType: 'application/pdf' };
    const raw = await fetch(`${origin}/api/documents/upload?${new URLSearchParams(legacyIdentity)}`, {
      method: 'POST', headers: { 'x-app-session': token, 'content-type': 'application/pdf' }, body: '%PDF-synthetic',
    });
    assert.equal(raw.status, 201, await raw.text());
    const multipart = new FormData();
    for (const [key, value] of Object.entries(legacyIdentity)) multipart.set(key, value);
    multipart.set('file', new Blob(['%PDF-synthetic'], { type: 'application/pdf' }), 'synthetic.pdf');
    const uploaded = await fetch(`${origin}/api/documents`, {
      method: 'POST', headers: { 'x-app-session': token }, body: multipart,
    });
    assert.equal(uploaded.status, 201);
    assert.equal((await uploaded.json()).data.document.dossierId, dossierId);
    const chunk = new FormData();
    chunk.set('uploadId', 'synthetic-legacy-mandate');
    chunk.set('chunkIndex', '0'); chunk.set('totalChunks', '1');
    chunk.set('chunk', new Blob(['%PDF-synthetic']), 'chunk.bin');
    const staged = await fetch(`${origin}/api/documents/upload/chunk`, {
      method: 'POST', headers: { 'x-app-session': token }, body: chunk,
    });
    assert.equal(staged.status, 202, await staged.text());
    const finalized = await fetch(`${origin}/api/documents/upload/finalize`, {
      method: 'POST', headers: { 'x-app-session': token, 'content-type': 'application/json' },
      body: JSON.stringify({ ...legacyIdentity, uploadId: 'synthetic-legacy-mandate' }),
    });
    assert.equal(finalized.status, 201);
    assert.equal((await finalized.json()).data.document.dossierId, dossierId);
    assert.deepEqual(mock.violations, []);
    console.log('MANDATE_IDENTITY_PASS');
  } finally { server.closeAllConnections(); await new Promise(resolve => server.close(resolve)); }
}

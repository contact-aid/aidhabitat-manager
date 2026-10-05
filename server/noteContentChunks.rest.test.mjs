import assert from 'node:assert/strict';
import test from 'node:test';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';
import { once } from 'node:events';
import { randomBytes, randomUUID } from 'node:crypto';

if (process.argv.includes('--runner')) await run();
else test('real REST adapter paginates note fragments; HTTP denies another account before fragment reads', async () => {
  const root = await mkdtemp(`${tmpdir()}/note-chunks-rest-`);
  try {
    const { stdout } = await promisify(execFile)(process.execPath, [fileURLToPath(import.meta.url), '--runner'], {
      cwd: root, timeout: 60000, maxBuffer: 200000,
      env: { NODE_ENV: 'test', AIDHABITAT_API_ONLY: '1', AIDHABITAT_DATA_DIR_PATH: root,
        AUTH_SESSION_SECRET: 'synthetic-note-chunk-secret', NOCODB_FORCE_REST: '1',
        NOCODB_API_URL: 'https://nocodb.test.invalid', NOCODB_API_TOKEN: 'synthetic-conditional-http-token',
        NOCODB_BASE_ID: 'conditional_http_base' },
    });
    assert.match(stdout, /NOTE_CHUNKS_REST_PASS/);
  } catch (error) { assert.fail(`${error.stdout || ''}\n${error.stderr || error.message}`); }
  finally { await rm(root, { recursive: true, force: true }); }
});
async function run() {
  const { createRestMock, tables, otherEmail, password, patientId, dossierId } = await import('./test-fixtures/conditionalRoutes.rest.mjs');
  const mock = createRestMock();
  const chunks = []; const chunkCalls = [];
  const nativeFetch = globalThis.fetch; let appOrigin;
  globalThis.fetch = async (input, init = {}) => {
    const url = new URL(input instanceof Request ? input.url : input);
    if (url.origin === appOrigin) return nativeFetch(input, init);
    assert.equal(url.origin, 'https://nocodb.test.invalid');
    if (url.pathname === `/api/v2/tables/${tables.mobile_document_chunks}/records`) {
      assert.equal(new Headers(init.headers).get('xc-token'), 'synthetic-conditional-http-token');
      chunkCalls.push({ method: init.method || 'GET', offset: Number(url.searchParams.get('offset') || 0) });
      const json = value => new Response(JSON.stringify(value), { status: 200, headers: { 'content-type': 'application/json' } });
      if ((init.method || 'GET') === 'GET') {
        const where = url.searchParams.get('where');
        if (where?.includes(',like,upload_')) {
          assert(!chunks.some(r => r.document_uuid_source.startsWith('upload_')));
          return json({ list: [], pageInfo: { isLastPage: true } });
        }
        const match = /^\(document_uuid_source,eq,([^()]+)\)$/.exec(where || ''); assert(match);
        const selected = chunks.filter(r => r.document_uuid_source === match[1]);
        const offset = Number(url.searchParams.get('offset') || 0), limit = Number(url.searchParams.get('limit') || 25);
        return json({ list: selected.slice(offset, offset + limit), pageInfo: {
          totalRows: selected.length, page: Math.floor(offset / limit) + 1, pageSize: limit,
          isLastPage: offset + limit >= selected.length,
        } });
      }
      assert.equal(init.method, 'POST');
      const body = JSON.parse(init.body); const rows = Array.isArray(body) ? body : [body];
      const created = rows.map(fields => {
        assert(fields.chunk_base64.length <= 90000);
        const row = { Id: chunks.length + 1, ...fields }; chunks.push(row); return row;
      });
      return json(Array.isArray(body) ? created : created[0]);
    }
    return mock.fetch(input, init);
  };
  const { createNocodbStoreAdapter } = await import('./mobileSyncStore.mjs');
  const adapter = createNocodbStoreAdapter({ absoluteUrl: p => `https://fake.test${p}`,
    documentsTableId: tables.mobile_documents, documentChunksTableId: tables.mobile_document_chunks,
    notePagesTableId: tables.mobile_note_pages, preferLocal: true });
  const input = { notePageId: 'synthetic-chunked-note', patientId, dossierId,
    scopeType: 'visit_grid', scopeId: patientId, tabKey: 'Plans', subTabKey: '', pageNumber: 1,
    drawingJson: JSON.stringify({ text: 'Fiction', strokes: [{ data: randomBytes(7100000).toString('base64') }] }),
    textContent: 'Fiction', expectedRevision: null, writeId: randomUUID() };
  await adapter.upsertNotePage(input);
  assert(chunks.length > 100);
  assert.equal((await adapter.getNotePageById(input.notePageId)).drawingJson, input.drawingJson);
  assert(chunkCalls.some(call => call.method === 'GET' && call.offset >= 100));
  assert(mock.rows('mobile_note_pages')[0].drawing_json.length < 100000);

  const { default: app } = await import('./index.mjs');
  const server = app.listen(0, '127.0.0.1'); await once(server, 'listening');
  appOrigin = `http://127.0.0.1:${server.address().port}`;
  try {
    const login = await fetch(`${appOrigin}/api/auth/login`, { method: 'POST',
      headers: { 'content-type': 'application/json' }, body: JSON.stringify({ email: otherEmail, password }) });
    assert.equal(login.status, 200); const token = (await login.json()).data.token;
    const before = chunkCalls.length;
    for (const [method, path, body] of [
      ['GET', `/public/note-pages/${input.notePageId}/preview`],
      ['GET', `/api/note-pages/${patientId}`],
      ['PUT', '/api/note-pages', input],
      ['DELETE', `/api/note-pages/${input.notePageId}`],
    ]) {
      const response = await fetch(appOrigin + path, { method,
        headers: { 'x-app-session': token, 'content-type': 'application/json' },
        ...(body ? { body: JSON.stringify(body) } : {}) });
      assert.equal(response.status, 403, `${path}: ${await response.text()}`);
    }
    assert.equal(chunkCalls.length, before);
    const adminLogin = await fetch(`${appOrigin}/api/auth/login`, { method: 'POST',
      headers: { 'content-type': 'application/json' }, body: JSON.stringify({ email: 'contact@aidhabitat.fr', password }) });
    assert.equal(adminLogin.status, 200);
    const adminToken = (await adminLogin.json()).data.token;
    const read = await fetch(`${appOrigin}/api/note-pages/${patientId}`, { headers: { 'x-app-session': adminToken } });
    assert.equal(read.status, 200);
    assert.equal((await read.json()).data.notePages[0].drawingJson, input.drawingJson);
    const { purgeStaleChunks } = await import('./storage.mjs');
    const chunkCount = chunks.length;
    assert.equal(await purgeStaleChunks(), 0);
    assert.equal(chunks.length, chunkCount);
    assert.deepEqual(mock.violations, []);
    console.log('NOTE_CHUNKS_REST_PASS');
  } finally { server.closeAllConnections(); await new Promise(resolve => server.close(resolve)); }
}

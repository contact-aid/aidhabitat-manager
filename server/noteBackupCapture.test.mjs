import assert from 'node:assert/strict';
import test from 'node:test';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { mkdtemp, rm, realpath, readdir, readFile, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { randomBytes, randomUUID, createHash } from 'node:crypto';
import { once } from 'node:events';
const runFile = fileURLToPath(import.meta.url);
if (process.argv.includes('--runner')) await run();
else test('real note API retains 409/413 and produces verified backup only when capture succeeds', async () => {
  const root = await realpath(await mkdtemp(`${tmpdir()}/note-backup-http-`));
  try {
    const { stdout } = await promisify(execFile)(process.execPath, [runFile, '--runner'], {
      cwd: root, timeout: 60000, maxBuffer: 200000,
      env: { NODE_ENV: 'test', AIDHABITAT_API_ONLY: '1', AIDHABITAT_DATA_DIR_PATH: root,
        AUTH_SESSION_SECRET: 'synthetic-backup-only-secret', NOCODB_FORCE_REST: '1',
        NOCODB_API_URL: 'https://nocodb.test.invalid', NOCODB_API_TOKEN: 'synthetic-conditional-http-token',
        NOCODB_BASE_ID: 'conditional_http_base', AIDHABITAT_NOTE_BACKUP_ENABLED: '1',
        AIDHABITAT_NOTE_BACKUP_DURABLE: '1', AIDHABITAT_NOTE_BACKUP_DIR: root,
        AIDHABITAT_NOTE_BACKUP_KEY_ID: 'test',
        AIDHABITAT_NOTE_BACKUP_KEYS_JSON: JSON.stringify({ test: randomBytes(32).toString('base64') }),
      },
    });
    assert.match(stdout, /BACKUP_CAPTURE_PASS/);
  } catch (e) { assert.fail(`${e.stdout || ''}\n${e.stderr || e.message}`); }
  finally { await rm(root, { recursive: true, force: true }); }
});
async function run() {
  const { createRestMock, tables, password, patientId, dossierId, revision } = await import('./test-fixtures/conditionalRoutes.rest.mjs');
  process.env.AIDHABITAT_NOTE_BACKUP_CAPTURE_ENABLED = '1';
  process.env.AIDHABITAT_NOTE_BACKUP_CAPTURE_TARGETS_JSON = JSON.stringify([{ owner: 'ergo:1', patientId, tabKey: 'Plans', pageNumber: 0 }]);
  const mock = createRestMock();
  mock.rows('mobile_note_pages').push({ Id: 1, uuid_source: 'fiction-note', beneficiaire_id: patientId,
    dossier_id: dossierId, scope_type: 'visit_grid', scope_id: patientId, tab_key: 'Plans', sub_tab_key: '',
    page_number: 0, drawing_json: '{}', text_content: '', app_sync_revision: revision });
  const nativeFetch = globalThis.fetch; let origin;
  globalThis.fetch = (input, init) => new URL(input instanceof Request ? input.url : input).origin === origin
    ? nativeFetch(input, init) : mock.fetch(input, init);
  const { default: app } = await import('./index.mjs');
  const server = app.listen(0, '127.0.0.1'); await once(server, 'listening');
  origin = `http://127.0.0.1:${server.address().port}`;
  try {
    const login = await fetch(`${origin}/api/auth/login`, { method: 'POST', headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ email: 'contact@aidhabitat.fr', password }) });
    assert.equal(login.status, 200); const token = (await login.json()).data.token;
    const headers = { 'x-app-session': token, 'content-type': 'application/json' };
    const body = { patientId, tabKey: 'Plans', scopeType: 'visit_grid', scopeId: patientId, pageNumber: 0,
      drawingJson: '{"text":"Fiction intégrale é","strokes":[1,2]}', expectedRevision: randomUUID(), writeId: randomUUID() };
    const response = await fetch(`${origin}/api/note-pages`, { method: 'PUT', headers, body: JSON.stringify(body) });
    assert.equal(response.status, 409);
    const conflict = await response.json(); assert.equal(conflict.error, 'NOTE_PAGE_REVISION_CONFLICT');
    assert.equal(conflict.backupReceipt.storedVerified, true); assert.equal(conflict.backupReceipt.source, 'sync-request');
    const restored = await fetch(`${origin}/api/note-backups/${conflict.backupReceipt.backupId}/content`, { headers });
    assert.equal(restored.status, 200); const result = (await restored.json()).data;
    assert.equal(JSON.parse(result.snapshotJson).payload.drawingJson, body.drawingJson);
    assert.equal(createHash('sha256').update(result.snapshotJson).digest('hex'), conflict.backupReceipt.sha256);
    assert.equal(mock.rows('mobile_note_pages')[0].app_sync_revision, revision);
    assert(!mock.calls.some(call => call.method !== 'GET' && call.path.includes(tables.mobile_note_pages)));

    // Offline escrow recovery proves a copy can be restored independently of API.
    const root = process.env.AIDHABITAT_NOTE_BACKUP_DIR;
    const owner = 'ergo:1', ownerHash = createHash('sha256').update(owner).digest('hex');
    const archive = path.join(root, ownerHash, `${conflict.backupReceipt.backupId}.json`);
    const keysFile = path.join(root, 'escrow.json'), output = path.join(root, 'restored.json');
    await writeFile(keysFile, process.env.AIDHABITAT_NOTE_BACKUP_KEYS_JSON, { mode: 0o600 });
    await promisify(execFile)(process.execPath, [fileURLToPath(new URL('../tools/verify-note-backup.mjs', import.meta.url)),
      '--archive', archive, '--keys-file', keysFile, '--owner', owner, '--out', output]);
    assert.equal(await readFile(output, 'utf8'), result.snapshotJson);
    await assert.rejects(promisify(execFile)(process.execPath, [fileURLToPath(new URL('../tools/verify-note-backup.mjs', import.meta.url)),
      '--archive', archive, '--keys-file', keysFile, '--owner', owner, '--out', output]));

    // A request beyond BOTH configured budgets cannot be claimed backed up.
    const tooLarge = await fetch(`${origin}/api/note-pages`, { method: 'PUT', headers,
      body: JSON.stringify({ ...body, expectedRevision: revision, drawingJson: 'x'.repeat(20 * 1024 * 1024 + 1) }) });
    assert.equal(tooLarge.status, 413); const oversized = await tooLarge.json();
    assert.equal(oversized.backupStatus, 'unavailable'); assert.equal(oversized.backupReceipt, undefined);
    assert.equal(mock.rows('mobile_note_pages')[0].app_sync_revision, revision);
    assert.equal((await readdir(path.join(root, ownerHash))).filter(x => x.endsWith('.json')).length, 1);
    // Disabled, non-targeted and unavailable captures never fabricate a receipt
    // or turn a genuine conflict into an acknowledgement.
    const keys = process.env.AIDHABITAT_NOTE_BACKUP_KEYS_JSON;
    for (const mode of ['disabled', 'non-target', 'missing-key', 'missing-volume']) {
      process.env.AIDHABITAT_NOTE_BACKUP_CAPTURE_ENABLED = mode === 'disabled' ? '0' : '1';
      process.env.AIDHABITAT_NOTE_BACKUP_CAPTURE_TARGETS_JSON = JSON.stringify([
        { owner: 'ergo:1', patientId, tabKey: 'Plans', pageNumber: mode === 'non-target' ? 9 : 0 }]);
      process.env.AIDHABITAT_NOTE_BACKUP_KEYS_JSON = mode === 'missing-key' ? '{}' : keys;
      process.env.AIDHABITAT_NOTE_BACKUP_DIR = mode === 'missing-volume' ? path.join(root, 'absent-volume') : root;
      const retry = await fetch(`${origin}/api/note-pages`, { method: 'PUT', headers, body: JSON.stringify(body) });
      assert.equal(retry.status, 409);
      const failure = await retry.json();
      assert.equal(failure.backupReceipt, undefined);
      assert.equal(failure.backupStatus, ['missing-key', 'missing-volume'].includes(mode) ? 'unavailable' : undefined);
    }
    assert.equal(mock.rows('mobile_note_pages')[0].app_sync_revision, revision);
    assert(!mock.calls.some(call => call.method !== 'GET' && call.path.includes(tables.mobile_note_pages)));
    assert.deepEqual(mock.violations, []);
    console.log('BACKUP_CAPTURE_PASS');
  } finally { server.closeAllConnections(); await new Promise(resolve => server.close(resolve)); }
}

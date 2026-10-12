import assert from 'node:assert/strict';
import test from 'node:test';
import fs from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import { randomBytes, createHash } from 'node:crypto';
import express from 'express';
import { once } from 'node:events';
import { createNoteBackupStore, noteBackupConfig, decryptNoteBackup, validateNoteSnapshot } from './noteBackup.mjs';
import { registerNoteBackupRoutes, shouldCaptureSubmittedNote } from './noteBackupRoutes.mjs';
const owner = 'ergo:4', patientId = 'fiction-patient';
const sha = value => createHash('sha256').update(value).digest('hex');
const snapshotJson = JSON.stringify({ schemaVersion: 1, operationId: 'fiction-operation',
  entityType: 'note_page', entityLocalId: 'fiction-note', payload: { patientLocalId: patientId,
    tabKey: 'Plans', pageNumber: 1, drawingJson: '{"text":"Fiction é 👋","strokes":[1,2]}',
    expectedRevision: 'unchanged', writeId: 'unchanged-write' },
  localNote: { patient_local_id: patientId, local_id: 'fiction-note', drawingJson: 'different local content retained', textContent: 'Fiction local' },
  status: 'conflict', createdAt: '2026-10-01', updatedAt: '2026-10-05' });
async function fixture(t) {
  const directory = await fs.realpath(await fs.mkdtemp(path.join(os.tmpdir(), 'note-backup-')));
  t.after(() => fs.rm(directory, { recursive: true, force: true }));
  const config = { directory, activeKeyId: 'v1', keyring: { v1: randomBytes(32) } };
  return { config, store: createNoteBackupStore(config),
    file: id => path.join(directory, sha(owner), `${id}.json`) };
}
test('disabled or incomplete configuration never silently uses an ephemeral directory', () => {
  assert.equal(noteBackupConfig({}), null);
  assert.throws(() => noteBackupConfig({ AIDHABITAT_NOTE_BACKUP_ENABLED: '1' }), { code: 'NOTE_BACKUP_UNAVAILABLE' });
  assert.throws(() => noteBackupConfig({ AIDHABITAT_NOTE_BACKUP_ENABLED: '1', AIDHABITAT_NOTE_BACKUP_DIR: '/tmp',
    AIDHABITAT_NOTE_BACKUP_KEY_ID: 'v1', AIDHABITAT_NOTE_BACKUP_KEYS_JSON: JSON.stringify({ v1: randomBytes(32).toString('base64') }) }),
  { code: 'NOTE_BACKUP_UNAVAILABLE' });
});
test('verified encrypted snapshot restores exact UTF-8 and retries idempotently', async t => {
  const { store, config, file } = await fixture(t);
  const saved = await store.save({ owner, patientId, snapshotJson });
  assert.equal(saved.created, true); assert.equal(saved.receipt.storedVerified, true);
  assert.equal(saved.receipt.sha256, sha(snapshotJson)); assert.equal(saved.receipt.bytes, Buffer.byteLength(snapshotJson));
  const bytes = await fs.readFile(file(saved.receipt.backupId), 'utf8');
  assert(!bytes.includes('Fiction')); assert(!bytes.includes(patientId)); assert(!bytes.includes('drawingJson'));
  assert.equal((await fs.stat(file(saved.receipt.backupId))).mode & 0o777, 0o600);
  const restored = decryptNoteBackup(JSON.parse(bytes), { owner, backupId: saved.receipt.backupId, keyring: config.keyring });
  assert.equal(restored.snapshotJson, snapshotJson);
  const retried = await store.save({ owner, patientId, snapshotJson });
  assert.equal(retried.created, false); assert.deepEqual(retried.receipt, saved.receipt);
  assert.equal(await fs.readFile(file(saved.receipt.backupId), 'utf8'), bytes);
});
test('concurrent identical captures publish one immutable verified object', async t => {
  const { store, config } = await fixture(t);
  const results = await Promise.all(Array.from({ length: 4 }, () => store.save({ owner, patientId, snapshotJson })));
  assert.equal(new Set(results.map(r => r.receipt.backupId)).size, 1);
  assert.equal(results.filter(r => r.created).length, 1);
  assert.equal((await fs.readdir(path.join(config.directory, sha(owner)))).filter(n => n.endsWith('.json')).length, 1);
});
for (const corruption of ['ciphertext', 'tag', 'ownerHash', 'key']) {
  test(`corruption ${corruption} fails closed and never overwrites the old archive`, async t => {
    const { store, config, file } = await fixture(t);
    const saved = await store.save({ owner, patientId, snapshotJson });
    const envelope = JSON.parse(await fs.readFile(file(saved.receipt.backupId), 'utf8'));
    if (corruption === 'key') config.keyring.v1 = randomBytes(32);
    else envelope[corruption] = corruption === 'ownerHash' ? '0'.repeat(64) : randomBytes(16).toString('base64');
    await fs.writeFile(file(saved.receipt.backupId), JSON.stringify(envelope));
    await assert.rejects(store.read(owner, saved.receipt.backupId), { code: 'NOTE_BACKUP_UNAVAILABLE' });
    await assert.rejects(store.save({ owner, patientId, snapshotJson }), { code: 'NOTE_BACKUP_UNAVAILABLE' });
  });
}
test('another owner cannot read an archive and patient identity mismatch cannot be saved', async t => {
  const { store } = await fixture(t); const saved = await store.save({ owner, patientId, snapshotJson });
  await assert.rejects(store.read('ergo:5', saved.receipt.backupId), { status: 404 });
  await assert.rejects(store.save({ owner, patientId: 'other', snapshotJson }), { status: 400 });
  assert.throws(() => validateNoteSnapshot(patientId, '{'), { status: 400 });
});
test('missing or nonprivate durable root and symlinked files fail closed', async t => {
  const { store, config, file } = await fixture(t);
  const saved = await store.save({ owner, patientId, snapshotJson });
  const original = file(saved.receipt.backupId), moved = original + '.preserved';
  await fs.rename(original, moved); await fs.symlink(moved, original);
  await assert.rejects(store.read(owner, saved.receipt.backupId), { code: 'NOTE_BACKUP_UNAVAILABLE' });
  await fs.chmod(config.directory, 0o755);
  await assert.rejects(store.save({ owner, patientId, snapshotJson }), { code: 'NOTE_BACKUP_UNAVAILABLE' });
});
test('key rotation keeps old backups readable without re-encryption', async t => {
  const { config, store, file } = await fixture(t);
  const saved = await store.save({ owner, patientId, snapshotJson }); const before = await fs.readFile(file(saved.receipt.backupId));
  config.keyring.v2 = randomBytes(32); config.activeKeyId = 'v2';
  assert.equal((await store.read(owner, saved.receipt.backupId)).snapshotJson, snapshotJson);
  const next = await store.save({ owner, patientId, snapshotJson: snapshotJson.replace('fiction-operation', 'second-operation') });
  assert.equal(JSON.parse(await fs.readFile(file(next.receipt.backupId))).keyId, 'v2');
  assert.deepEqual(await fs.readFile(file(saved.receipt.backupId)), before);
});
test('HTTP explicit capture is authenticated, owner-only, independently rereadable, and no-store', async t => {
  const { config } = await fixture(t); const app = express(); app.use(express.json({ limit: '30mb' }));
  let denied = false;
  registerNoteBackupRoutes(app, { config: () => config,
    requireAuth: (req, res, next) => {
      if (!req.headers['x-test-owner']) return res.status(401).end();
      req.appUser = { ergoRecordId: req.headers['x-test-owner'] }; next();
    }, resolveBeneficiaryAccess: async (_user, p) => { if (denied || p !== patientId) throw Object.assign(new Error('private'), { statusCode: 403 }); } });
  const server = app.listen(0, '127.0.0.1'); await once(server, 'listening');
  t.after(() => new Promise(resolve => { server.closeAllConnections(); server.close(resolve); }));
  const root = `http://127.0.0.1:${server.address().port}/api/note-backups`;
  assert.equal((await fetch(root, { method: 'POST' })).status, 401);
  const response = await fetch(root, { method: 'POST', headers: { 'x-test-owner': '4', 'content-type': 'application/json' }, body: JSON.stringify({ patientId, snapshotJson }) });
  assert.equal(response.status, 201); const receipt = (await response.json()).data.receipt;
  const own = await fetch(`${root}/${receipt.backupId}/content`, { headers: { 'x-test-owner': '4' } });
  assert.equal(own.status, 200); assert.match(own.headers.get('cache-control'), /no-store/);
  assert.equal((await own.json()).data.snapshotJson, snapshotJson);
  assert.equal((await fetch(`${root}/${receipt.backupId}`, { headers: { 'x-test-owner': '5' } })).status, 404);
  denied = true;
  assert.equal((await fetch(`${root}/${receipt.backupId}/content`, { headers: { 'x-test-owner': '4' } })).status, 403);
});

test('client SQLite identity aliases must match the operation and beneficiary', () => {
  for (const field of ['patient_local_id', 'local_id']) {
    const snapshot = JSON.parse(snapshotJson); snapshot.localNote[field] = 'another';
    assert.throws(() => validateNoteSnapshot(patientId, JSON.stringify(snapshot)), { status: 400 });
  }
});
test('passive capture requires separate enablement and exact owner/patient/tab/page targets', () => {
  const req = { appUser: { ergoRecordId: '4' }, body: { patientId, tabKey: 'Plans', pageNumber: 1 } };
  const target = { owner, ...req.body };
  const env = { AIDHABITAT_NOTE_BACKUP_CAPTURE_ENABLED: '1',
    AIDHABITAT_NOTE_BACKUP_CAPTURE_TARGETS_JSON: JSON.stringify([target]) };
  assert.equal(shouldCaptureSubmittedNote(req, {}), false);
  assert.equal(shouldCaptureSubmittedNote(req, { ...env, AIDHABITAT_NOTE_BACKUP_CAPTURE_ENABLED: '0' }), false);
  assert.equal(shouldCaptureSubmittedNote(req, { AIDHABITAT_NOTE_BACKUP_CAPTURE_ENABLED: '1' }), false);
  assert.equal(shouldCaptureSubmittedNote(req, env), true);
  for (const change of [{ patientId: 'another' }, { tabKey: 'Résumé' }, { pageNumber: 0 }]) {
    assert.equal(shouldCaptureSubmittedNote({ ...req, body: { ...req.body, ...change } }, env), false);
  }
  assert.equal(shouldCaptureSubmittedNote({ ...req, appUser: { ergoRecordId: '5' } }, env), false);
  assert.throws(() => shouldCaptureSubmittedNote(req, { ...env, AIDHABITAT_NOTE_BACKUP_CAPTURE_TARGETS_JSON: '[{}]' }));
  assert.throws(() => shouldCaptureSubmittedNote(req, { ...env, AIDHABITAT_NOTE_BACKUP_CAPTURE_TARGETS_JSON: '{' }));
});

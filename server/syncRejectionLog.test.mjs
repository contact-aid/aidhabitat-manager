import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';

import { createSyncRejectionLog } from './syncRejectionLog.mjs';

const at = new Date('2026-11-06T10:00:00.000Z');
const writeId = '11111111-2222-4333-8444-555555555555';

async function setup(options = {}) {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'sync-rejections-'));
  const log = createSyncRejectionLog({ directory, now: () => at, ...options });
  return { log, file: path.join(directory, 'sync-rejections-2026-11.jsonl') };
}

async function respond(log, { method = 'PATCH', requestPath, status, body }) {
  const sent = [];
  const res = { statusCode: status, json: (value) => { sent.push(value); return 'sent'; } };
  let nextCalled = false;
  log.middleware({ method, path: requestPath }, res, () => { nextCalled = true; });
  assert.equal(nextCalled, true);
  assert.equal(res.json(body), 'sent');
  assert.deepEqual(sent, [body]);
  await log.flush();
}

const readEntries = async (file) => (await fs.readFile(file, 'utf8'))
  .trim().split('\n').map((line) => JSON.parse(line));

test('a conflict keeps its cause without any record content', async () => {
  const { log, file } = await setup();
  await respond(log, { requestPath: '/api/logements/by-beneficiary/42', status: 409, body: {
    success: false, error: 'SYNC_FIELD_CONFLICT', conflict: true,
    conflictFields: ['nombre_niveaux', 'bad field; DROP'], retainedFields: [], writeId,
    remoteData: { nom: 'DUPONT Jeanne', adresse: '1 rue Secrète' },
  } });
  const [entry] = await readEntries(file);
  assert.deepEqual(entry, { at: at.toISOString(), method: 'PATCH', resource: 'logements',
    status: 409, code: 'SYNC_FIELD_CONFLICT', conflictFields: ['nombre_niveaux'],
    retainedFields: [], writeId });
  assert.doesNotMatch(await fs.readFile(file, 'utf8'), /DUPONT|Secrète|by-beneficiary/);
});

test('free text errors are not stored', async () => {
  const { log, file } = await setup();
  await respond(log, { method: 'DELETE', requestPath: '/api/documents/9', status: 404,
    body: { success: false, error: 'Document de Mme Dupont introuvable' } });
  const [entry] = await readEntries(file);
  assert.equal(entry.code, null);
  assert.equal(entry.status, 404);
});

test('only rejected sync writes are recorded', async () => {
  const { log, file } = await setup();
  for (const request of [
    { requestPath: '/api/dossiers/1', status: 200, body: { success: true } },
    { requestPath: '/api/dossiers/1', status: 401, body: { error: 'SESSION_EXPIRED' } },
    { requestPath: '/api/dossiers/1', status: 403, body: { error: 'FORBIDDEN' } },
    { requestPath: '/api/dossiers/1', status: 503, body: { error: 'SYNC_WRITE_UNCONFIRMED' } },
    { method: 'GET', requestPath: '/api/dossiers/1', status: 404, body: { error: 'MISSING' } },
    { method: 'POST', requestPath: '/api/members', status: 409, body: { error: 'EXISTS' } },
  ]) await respond(log, request);
  await assert.rejects(fs.access(file));
});

test('a storage failure never reaches the request', async () => {
  const blocker = path.join(os.tmpdir(), `sync-rejections-file-${process.pid}`);
  await fs.writeFile(blocker, '');
  const log = createSyncRejectionLog({ directory: path.join(blocker, 'child'), now: () => at });
  await respond(log, { requestPath: '/api/dossiers/1', status: 409, body: { error: 'SYNC_FIELD_CONFLICT' } });
  await fs.rm(blocker);
});

test('the monthly file stops growing at its size limit', async () => {
  const { log, file } = await setup({ maxFileBytes: 1 });
  for (let i = 0; i < 3; i++) {
    await respond(log, { requestPath: '/api/dossiers/1', status: 409, body: { error: 'SYNC_FIELD_CONFLICT' } });
  }
  assert.equal((await readEntries(file)).length, 1);
});

test('a real Express 409 is recorded after the JSON body parser', async () => {
  const { default: express } = await import('express');
  const { log, file } = await setup();
  const app = express();
  app.use(express.json());
  app.use(log.middleware);
  app.put('/api/note-pages', (_req, res) => {
    res.status(409).json({ error: 'NOTE_PAGE_REVISION_CONFLICT', remoteData: { text: 'secret' } });
  });
  const server = await new Promise((resolve) => {
    const started = app.listen(0, '127.0.0.1', () => resolve(started));
  });
  try {
    const response = await fetch(`http://127.0.0.1:${server.address().port}/api/note-pages`, {
      method: 'PUT', headers: { 'content-type': 'application/json' }, body: '{}',
    });
    assert.equal(response.status, 409);
    assert.equal((await response.json()).remoteData.text, 'secret');
  } finally {
    await new Promise((resolve) => server.close(resolve));
  }
  await log.flush();
  const [entry] = await readEntries(file);
  assert.equal(entry.resource, 'note-pages');
  assert.equal(entry.code, 'NOTE_PAGE_REVISION_CONFLICT');
  assert.doesNotMatch(await fs.readFile(file, 'utf8'), /secret/);
});

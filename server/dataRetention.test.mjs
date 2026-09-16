import assert from 'node:assert/strict';
import test from 'node:test';
import { mkdtemp, readFile, writeFile, rm, stat } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import express from 'express';
import { addCalendarMonths, buildRetentionReport, createRetentionStore, validateRetentionRecord } from './dataRetention.mjs';
import { createDataRetentionRouter } from './routes/dataRetention.mjs';

const now = () => new Date('2026-09-15T12:00:00Z');
const record = (overrides = {}) => ({ kind: 'dossier', id: 'synthetic-1', expectedRevision: 0, lastContactOn: '2024-09-15', closedOn: '2024-09-16', hold: false, exceptionsReviewed: true, ...overrides });
async function fixture(t) {
  const directory = await mkdtemp(path.join(tmpdir(), 'retention-test-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const file = path.join(directory, 'events.jsonl');
  return { file, store: createRetentionStore(file, now) };
}

test('calendar deadlines clamp month ends and leap days', () => {
  assert.equal(addCalendarMonths('2024-02-29', 24), '2026-02-28');
  assert.equal(addCalendarMonths('2025-08-31', 6), '2026-02-28');
  assert.equal(addCalendarMonths('0098-02-28', 24), '0100-02-28');
});

test('business dates use the Paris day at midnight boundaries', () => {
  assert.doesNotThrow(() => validateRetentionRecord(record({ lastContactOn: '2026-09-16', closedOn: null }), new Date('2026-09-15T22:30:00Z')));
  assert.throws(() => validateRetentionRecord(record({ lastContactOn: '2026-09-17', closedOn: null }), new Date('2026-09-15T22:30:00Z')));
});

test('CLI report and restored synthetic ledger preserve content and holds', async t => {
  const { store, file } = await fixture(t);
  await store.update(record({ hold: true, holdReference: 'CASE-1' }), 'synthetic-admin');
  const before = await readFile(file, 'utf8');
  const restored = `${file}.restored`;
  await writeFile(restored, before, { mode: 0o600 });
  const cli = fileURLToPath(new URL('../tools/data-retention-report.mjs', import.meta.url));
  const report = JSON.parse(execFileSync(process.execPath, [cli, restored], { encoding: 'utf8' }));
  assert.equal(report.deletionEnabled, false);
  assert.equal(report.coverage, 'registered-records-only');
  assert.ok(report.items[0].blockers.includes('retention_hold'));
  assert.equal(await readFile(restored, 'utf8'), before);
  assert.equal(await readFile(file, 'utf8'), before);
  assert.throws(() => execFileSync(process.execPath, [cli, `${file}.missing`], { stdio: 'pipe' }));
  await writeFile(restored, before.trimEnd());
  await assert.rejects(createRetentionStore(restored, now).update(record({ expectedRevision: 1 }), 'admin'), error => error.status === 503);
  assert.equal(await readFile(restored, 'utf8'), before.trimEnd());
  assert.throws(() => execFileSync(process.execPath, [cli, restored], { stdio: 'pipe' }));
});

test('invalid dates, future dates, personal text and ambiguous records are rejected', () => {
  for (const change of [
    { lastContactOn: '2024-02-30' }, { lastContactOn: '2027-01-01' },
    { id: '../secret' }, { message: 'health notes' }, { expectedRevision: -1 },
    { hold: true }, { holdReference: 'unused' }, { hold: 'false' },
    { closedOn: '2024-09-14' }, { resolvedOn: '2025-01-01' },
  ]) assert.throws(() => validateRetentionRecord(record(change), now()));
});

test('deadlines are review candidates, never deletion authorizations', async t => {
  const { store } = await fixture(t);
  await store.update(record(), 'synthetic-admin');
  const report = await store.report();
  assert.equal(report.items[0].status, 'review_due');
  assert.equal(report.items[0].dueOn, '2026-09-15');
  assert.equal(report.items[0].deletionAllowed, false);
  assert.equal(report.deletionEnabled, false);
  assert.equal(report.copiesVerified, false);
  assert.equal(report.coverage, 'registered-records-only');
  assert.equal(buildRetentionReport(await store.read(), '2026-09-14').items[0].status, 'not_due');
});

test('missing dates, active dossiers, holds and unreviewed exceptions block review', async t => {
  const { store } = await fixture(t);
  const cases = [
    [{ lastContactOn: null }, 'missing_business_date'],
    [{ closedOn: null }, 'dossier_not_closed'],
    [{ hold: true, holdReference: 'CASE-1' }, 'retention_hold'],
    [{ exceptionsReviewed: false }, 'exceptions_not_reviewed'],
  ];
  for (const [index, [change]] of cases.entries()) await store.update(record({ ...change, id: `synthetic-${index}` }), 'synthetic-admin');
  const report = await store.report();
  for (const [index, [, reason]] of cases.entries()) {
    assert.equal(report.items[index].status, 'blocked');
    assert.ok(report.items[index].blockers.includes(reason));
  }
});

test('resolution anchors assistance and reopening removes its deadline', async t => {
  const { store } = await fixture(t);
  const input = record({ kind: 'feedback', lastContactOn: null, closedOn: null, resolvedOn: '2026-03-15' });
  await store.update(input, 'synthetic-admin');
  assert.equal((await store.report()).items[0].status, 'review_due');
  await store.update({ ...input, expectedRevision: 1, resolvedOn: null }, 'synthetic-admin');
  assert.equal((await store.report()).items[0].dueOn, null);
  assert.equal((await store.read()).length, 2);
});

test('revision conflicts and concurrent writers preserve the audit log', async t => {
  const { store, file } = await fixture(t);
  const results = await Promise.allSettled([store.update(record(), 'admin-1'), store.update(record(), 'admin-2')]);
  assert.equal(results.filter(result => result.status === 'fulfilled').length, 1);
  assert.equal(results.find(result => result.status === 'rejected').reason.status, 409);
  await assert.rejects(store.update(record(), 'admin-3'), error => error.status === 409);
  assert.equal((await store.read()).length, 1);
  assert.equal((await stat(file)).mode & 0o777, 0o600);
});

test('corruption and stale locks fail closed without truncating data', async t => {
  const { store, file } = await fixture(t);
  await writeFile(file, 'broken');
  await assert.rejects(store.update(record(), 'admin'), error => error.status === 503);
  assert.equal(await readFile(file, 'utf8'), 'broken');
  await writeFile(`${file}.lock`, '');
  await assert.rejects(store.update(record(), 'admin'), error => error.status === 409);
});

test('admin HTTP workflow records metadata and does not expose a deletion route', async t => {
  const { store } = await fixture(t);
  const app = express();
  app.use(express.json());
  // Synthetic authorization is confined to this test fixture.
  app.use(createDataRetentionRouter({ store, authorize: (req, res, next) => {
    if (req.headers['x-test-role'] !== 'ADMIN') return res.sendStatus(403);
    req.appUser = { id: 'synthetic-admin' }; next();
  } }));
  const server = app.listen(0, '127.0.0.1');
  await new Promise(resolve => server.on('listening', resolve));
  t.after(() => new Promise(resolve => server.close(resolve)));
  const url = `http://127.0.0.1:${server.address().port}/api/admin/data-retention`;
  assert.equal((await fetch(url)).status, 403);
  const headers = { 'x-test-role': 'ADMIN', 'content-type': 'application/json' };
  const saved = await fetch(url, { method: 'POST', headers, body: JSON.stringify(record()) });
  assert.equal(saved.status, 200);
  assert.equal(saved.headers.get('cache-control'), 'no-store');
  assert.equal((await saved.json()).revision, 1);
  assert.equal((await fetch(url, { headers })).status, 200);
  assert.equal((await fetch(url, { method: 'DELETE', headers })).status, 404);
});

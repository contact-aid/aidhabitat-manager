import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { createJournaledHousingWriter } from './housingWriteJournal.mjs';

async function fixture(t) {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'housing-journal-'));
  t.after(() => fs.rm(directory, { recursive: true, force: true }));
  let row = { app_sync_revision: 'before', surface: 80 };
  let writes = 0;
  let loseResponse = false;
  const args = { tableId: 'housing', recordId: 1, expectedRevision: 'before',
    writeId: 'ipad', fields: { surface: 90 } };
  const options = { directory, readRecord: async () => structuredClone(row),
    writer: async input => {
      if (row.app_sync_revision === input.writeId) return { status: 'applied', replay: true };
      if (row.app_sync_revision !== input.expectedRevision) return {
        status: 'not_confirmed', reason: 'revision_changed', observed: structuredClone(row),
      };
      writes++;
      row = { ...row, ...input.fields, app_sync_revision: input.writeId };
      if (loseResponse) throw new Error('response lost');
      return { status: 'applied', replay: false };
    } };
  return { directory, args, options, apply: createJournaledHousingWriter(options),
    setRow: value => { row = value; }, row: () => row, writes: () => writes,
    loseResponse: () => { loseResponse = true; } };
}

test('confirmed write cannot be applied again after a web edit, including ABA', async t => {
  const f = await fixture(t);
  await f.apply(f.args);
  f.setRow({ surface: 80, app_sync_revision: 'web' });
  const restarted = createJournaledHousingWriter(f.options);
  await assert.rejects(restarted({ ...f.args, expectedRevision: 'web' }),
    e => e.code === 'SYNC_HOUSING_WRITE_SUPERSEDED');
  assert.equal(f.writes(), 1);
  assert.equal(f.row().surface, 80);
  const [filename] = await fs.readdir(f.directory);
  const receipt = JSON.parse(await fs.readFile(path.join(f.directory, filename)));
  assert.equal(receipt.before.surface, 80);
  assert.equal(receipt.args.fields.surface, 90);
  assert.equal(receipt.status, 'applied');
});

test('uncertain write survives restart and never adopts a newer revision', async t => {
  const f = await fixture(t);
  f.loseResponse();
  await assert.rejects(f.apply(f.args), /response lost/);
  f.setRow({ surface: 100, app_sync_revision: 'web' });
  await assert.rejects(createJournaledHousingWriter(f.options)({ ...f.args, expectedRevision: 'web' }),
    e => e.code === 'SYNC_HOUSING_WRITE_SUPERSEDED');
  assert.equal(f.writes(), 1);
  assert.equal(f.row().surface, 100);
});

test('lost response can be acknowledged when the original revision is still present', async t => {
  const f = await fixture(t);
  f.loseResponse();
  await assert.rejects(f.apply(f.args));
  assert.equal((await createJournaledHousingWriter(f.options)(f.args)).status, 'applied');
  assert.equal(f.writes(), 1);
});

test('reused identity with different content is rejected without a write', async t => {
  const f = await fixture(t);
  await f.apply(f.args);
  await assert.rejects(f.apply({ ...f.args, fields: { surface: 200 } }),
    e => e.code === 'SYNC_WRITE_ID_MISMATCH');
  assert.equal(f.writes(), 1);
});

test('unreadable journal fails closed before any remote write', async t => {
  const f = await fixture(t);
  await f.apply(f.args);
  const [name] = await fs.readdir(f.directory);
  await fs.writeFile(path.join(f.directory, name), '{broken');
  await assert.rejects(createJournaledHousingWriter(f.options)(f.args));
  assert.equal(f.writes(), 1);
});

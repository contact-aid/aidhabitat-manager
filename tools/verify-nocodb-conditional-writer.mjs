import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { pathToFileURL } from 'node:url';
import { createConditionalRecordWriter, ConditionalWriteUncertainError } from '../server/nocodbConditionalWrite.mjs';
import { STAGING_BASE, createProbeRestRequest } from './probe-nocodb-conditional-write.mjs';

// Reuse only the synthetic fixture explicitly authorized for the F05 probe.
const tableId = 'md38tdejnvrqlry';
const title = 'codex_sync_probe_3ca73c1cd9f547049980875119f053a9';

export async function verifyConditionalWriter({ baseId, apply = false, request }) {
  assert.equal(baseId, STAGING_BASE, 'Only the approved staging base is allowed');
  if (!apply) return { mode: 'dry-run', baseId, tableId, title, createsTables: false, touchesBusinessData: false };
  const schema = await request({ method: 'GET', path: `/api/v2/meta/tables/${tableId}` });
  assert.equal(schema.id, tableId);
  assert.equal(schema.base_id, baseId);
  assert.equal(schema.title, title);
  const read = async () => {
    const payload = await request({ method: 'GET', path: `/api/v2/tables/${tableId}/records?limit=10` });
    const rows = Array.isArray(payload) ? payload : payload?.list;
    assert.ok(Array.isArray(rows));
    assert.equal(rows.length, 2, 'The synthetic fixture must contain exactly two rows');
    const target = rows.find((row) => Number(row.Id) === 1);
    const sentinel = rows.find((row) => Number(row.Id) === 2);
    assert.ok(target && sentinel);
    assert.equal(sentinel.value, 'untouched sentinel');
    return { target, sentinel };
  };
  const initial = await read();
  let patchCount = 0;
  let dropNextResponse = false;
  let raceBarrier = null;
  let releaseRace;
  let raceArrivals = 0;
  const writer = createConditionalRecordWriter({
    baseId, allowedTableIds: [tableId],
    request: async (input) => {
      if (input.method === 'PATCH') {
        patchCount++;
        if (raceBarrier) {
          // Both writers must complete their pre-read before either PATCH.
          if (++raceArrivals === 2) releaseRace();
          let timeout;
          try {
            await Promise.race([raceBarrier, new Promise((_, reject) => {
              timeout = setTimeout(() => reject(new Error('Concurrent writer did not reach PATCH')), 15_000);
            })]);
          } finally {
            clearTimeout(timeout);
          }
        }
      }
      const result = await request(input);
      if (input.method === 'PATCH' && dropNextResponse) {
        dropNextResponse = false;
        // Lose only the response, after the real server has processed the PATCH.
        throw new Error('Synthetic lost response');
      }
      return result;
    },
  });
  const mutation = (revision, value, extra = {}) => ({
    tableId, recordId: 1, expectedRevision: revision, writeId: randomUUID(), fields: { value, ...extra },
  });
  const first = mutation(initial.target.app_sync_revision, 'writer-verified');
  assert.deepEqual(await writer(first), { status: 'applied', revision: first.writeId, replay: false });
  assert.deepEqual(await writer(first), { status: 'applied', revision: first.writeId, replay: true });
  assert.equal(patchCount, 1, 'A replay must not send another PATCH');
  const lost = mutation(first.writeId, 'writer-lost-response-recovered');
  dropNextResponse = true;
  await assert.rejects(writer(lost), ConditionalWriteUncertainError);
  assert.deepEqual(await writer(lost), { status: 'applied', revision: lost.writeId, replay: true });
  assert.equal(patchCount, 2, 'Recovery must not resend the applied write');

  const beforeRace = await read();
  const a = mutation(lost.writeId, 'writer-race-A', { writer_a: randomUUID() });
  const b = mutation(lost.writeId, 'writer-race-B', { writer_b: randomUUID() });
  raceBarrier = new Promise((resolve) => { releaseRace = resolve; });
  const results = await Promise.all([writer(a), writer(b)]);
  raceBarrier = null;
  assert.equal(raceArrivals, 2);
  assert.equal(results.filter((result) => result.status === 'applied').length, 1);
  const afterRace = await read();
  const winner = afterRace.target.app_sync_revision === a.writeId ? a : b;
  assert.equal(afterRace.target.app_sync_revision, winner.writeId);
  assert.equal(afterRace.target.value, winner.fields.value);
  assert.equal(afterRace.target.writer_a, winner === a ? a.fields.writer_a : beforeRace.target.writer_a);
  assert.equal(afterRace.target.writer_b, winner === b ? b.fields.writer_b : beforeRace.target.writer_b);
  const countBeforeStale = patchCount;
  const stale = await writer(mutation(lost.writeId, 'must-not-overwrite'));
  assert.equal(stale.status, 'not_confirmed');
  assert.equal(stale.reason, 'revision_changed');
  assert.equal(patchCount, countBeforeStale);
  const final = await read();
  assert.deepEqual(final.target, afterRace.target);
  assert.deepEqual(final.sentinel, initial.sentinel);
  return { mode: 'applied', baseId, tableId, retained: true, patchCount,
    checks: ['write-confirmed', 'replay-without-patch', 'lost-response-recovery-without-patch', 'concurrent-single-winner', 'stale-rejected', 'sentinel-unchanged'] };
}

async function main(args) {
  assert.ok(args.every((arg) => arg === '--apply' || arg === `--base=${STAGING_BASE}`));
  assert.ok(args.includes(`--base=${STAGING_BASE}`), 'Pass the documented staging base explicitly');
  const apply = args.includes('--apply');
  const request = apply ? await createProbeRestRequest() : undefined;
  console.log(JSON.stringify(await verifyConditionalWriter({ baseId: STAGING_BASE, apply, request }), null, 2));
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main(process.argv.slice(2)).catch((error) => {
    console.error(`Conditional writer verification stopped: ${error.message}`);
    process.exitCode = 1;
  });
}

import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import test from 'node:test';
import { checkConditionalSyncReadiness, SYNC_BASE } from './check-conditional-sync-readiness.mjs';

test('readiness is offline by default and cannot scan an arbitrary base', async () => {
  const request = () => assert.fail('Network forbidden');
  assert.equal((await checkConditionalSyncReadiness({ baseId: SYNC_BASE, request })).mode, 'dry-run');
  await assert.rejects(checkConditionalSyncReadiness({ baseId: 'other', request, check: true }));
});

function requestWith(rows, { missing = false, duplicate = false } = {}) {
  return async ({ method, path }) => {
    assert.equal(method, 'GET');
    if (path.includes('/meta/')) return {
      id: path.split('/').at(-1), base_id: SYNC_BASE,
      columns: [{ title: 'Id', pk: true }, ...(missing ? [] : [{ title: 'app_sync_revision', uidt: 'SingleLineText' }])],
    };
    assert.ok(!missing, 'No data should be fetched if the schema is not ready');
    const params = new URL(path, 'https://synthetic.test').searchParams;
    assert.equal(params.get('fields'), 'Id,app_sync_revision');
    const offset = duplicate ? 0 : Number(params.get('offset'));
    return { list: rows.slice(offset, offset + 100) };
  };
}
test('missing schema is not readiness and never fetches business rows', async () => {
  const report = await checkConditionalSyncReadiness({ baseId: SYNC_BASE, check: true, request: requestWith([], { missing: true }) });
  assert.equal(report.schemaAndRevisionsReady, false);
  assert.equal(report.writes, 0);
});
test('all pages are checked and row contents are not included in the report', async () => {
  const rows = Array.from({ length: 101 }, (_, i) => ({ Id: i + 1, app_sync_revision: randomUUID() }));
  rows[100].app_sync_revision = null;
  const report = await checkConditionalSyncReadiness({ baseId: SYNC_BASE, check: true, request: requestWith(rows) });
  assert.equal(report.schemaAndRevisionsReady, false);
  assert.equal(report.tables[0].checkedRows, 101);
  assert.equal(report.tables[0].invalidRevisions, 1);
  assert.equal(JSON.stringify(report).includes(rows[0].app_sync_revision), false);
});
test('schema readiness alone never authorizes activation', async () => {
  const report = await checkConditionalSyncReadiness({ baseId: SYNC_BASE, check: true, request: requestWith([{ Id: 1, app_sync_revision: randomUUID() }]) });
  assert.equal(report.schemaAndRevisionsReady, true);
  assert.equal(report.activationApproved, false);
});
test('repeated pagination fails closed', async () => {
  const rows = Array.from({ length: 100 }, (_, i) => ({ Id: i + 1, app_sync_revision: randomUUID() }));
  await assert.rejects(checkConditionalSyncReadiness({ baseId: SYNC_BASE, check: true, request: requestWith(rows, { duplicate: true }) }), /pagination/);
});

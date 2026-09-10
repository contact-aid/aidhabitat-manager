import assert from 'node:assert/strict';
import test from 'node:test';
import { randomUUID } from 'node:crypto';
import { verifyConditionalWriter } from './verify-nocodb-conditional-writer.mjs';
import { STAGING_BASE } from './probe-nocodb-conditional-write.mjs';

test('writer verification defaults to zero network calls', async () => {
  const result = await verifyConditionalWriter({ baseId: STAGING_BASE, request: () => assert.fail('network') });
  assert.equal(result.mode, 'dry-run');
});

test('writer verification refuses production even without apply', async () => {
  await assert.rejects(verifyConditionalWriter({ baseId: 'pskgbjythubfzv9', request: () => assert.fail('network') }));
});

test('writer verification refuses an unrelated staging table before reading rows', async () => {
  let calls = 0;
  await assert.rejects(verifyConditionalWriter({ baseId: STAGING_BASE, apply: true, request: async () => {
    calls++;
    return { id: 'md38tdejnvrqlry', base_id: STAGING_BASE, title: 'business_data' };
  } }));
  assert.equal(calls, 1);
});

test('verification exercises two guarded PATCHes and lost-response replay without duplicating writes', async () => {
  const seed = randomUUID();
  const rows = [
    { Id: 1, app_sync_revision: seed, value: 'original', writer_a: '', writer_b: '' },
    { Id: 2, app_sync_revision: seed, value: 'untouched sentinel', writer_a: '', writer_b: '' },
  ];
  let patches = 0;
  const result = await verifyConditionalWriter({ baseId: STAGING_BASE, apply: true, request: async ({ method, path, body }) => {
    if (path.includes('/meta/')) return {
      id: 'md38tdejnvrqlry', base_id: STAGING_BASE, title: 'codex_sync_probe_3ca73c1cd9f547049980875119f053a9',
      columns: [{ title: 'Id', pk: true, uidt: 'ID' },
        ...['app_sync_revision', 'value', 'writer_a', 'writer_b'].map((title) => ({ title, uidt: 'SingleLineText' }))],
    };
    const where = new URL(path, 'https://example.test').searchParams.get('where');
    if (method === 'GET') return { list: structuredClone(where ? [rows[0]] : rows) };
    assert.equal(method, 'PATCH');
    patches++;
    assert.match(where, /^\(Id,eq,1\)~and\(app_sync_revision,eq,[0-9a-f-]+\)$/);
    if (where.includes(`eq,${rows[0].app_sync_revision})`)) Object.assign(rows[0], body);
    return 1;
  } });
  assert.equal(patches, 4);
  assert.equal(result.checks.length, 6);
});

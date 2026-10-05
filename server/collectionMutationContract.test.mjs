import test from 'node:test';
import assert from 'node:assert/strict';
import { assertCollectionMutationAllowed as guard } from './collectionMutationContract.mjs';
for (const [kind, updates] of [
  ['patient', { dependenceTxt: 'Canne' }],
  ['patient', { occupants: [] }],
  ['housing', { roomsBreakdown: { rdc: [] } }],
  ['housing', { rdc: false }],
  ['sanitary', { sdbInstances: [], wcInstances: [{ id: 'stale-deleted-room' }] }],
]) {
  test(`${kind}: old client cannot erase or resurrect, reviewed client still needs separate CAS`, () => {
    const payload = { updates, concurrency: { version: 1, expectedUpdatedAt: '2026-10-05T10:00:00Z' } };
    const before = structuredClone(payload);
    assert.throws(() => guard({ kind, payload }), e => e.status === 409 && e.code === 'COLLECTION_CLIENT_UPGRADE_REQUIRED');
    assert.deepEqual(payload, before);
    guard({ kind, payload: { ...payload, concurrency: { ...payload.concurrency, collectionContract: 'collections-v2' } } });
  });
}
test('simple fields remain compatible; root sanitary PUT is also guarded', () => {
  guard({ kind: 'patient', payload: { phone: 'fiction' } });
  guard({ kind: 'housing', payload: { comments: '' } });
  assert.throws(() => guard({ kind: 'sanitary', payload: { sdbInstances: [] } }), /ancienne version/);
  assert.throws(() => guard({ kind: 'unknown', payload: {} }), /Unknown/);
});

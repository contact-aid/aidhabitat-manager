import assert from 'node:assert/strict';
import test from 'node:test';
import { inspectLegacyRecovery, mappedDatabaseValueEquals } from './legacySyncRecovery.mjs';

const request = {
  guard: { version: 1, writeId: '11111111-1111-4111-8111-111111111111', baseValues: { note: 'old' } },
  updatedAt: '2026-09-17T09:00:00Z',
  fields: { note: 'new' }, baseFields: { note: 'old' }, observed: { note: 'new' },
};
test('database scalar normalization stays restricted to mapped types', () => {
  assert(mappedDatabaseValueEquals('checkbox', 'false', false));
  assert(mappedDatabaseValueEquals('checkbox', null, false));
  assert(mappedDatabaseValueEquals('relation_id', '42', 42));
  assert(mappedDatabaseValueEquals('notes', '', null));
  assert(mappedDatabaseValueEquals('occupants_json', '[ { "id": 1 } ]', '[{"id":1}]'));
  assert(!mappedDatabaseValueEquals('telephone', '001', '1'));
  assert(!mappedDatabaseValueEquals('checkbox', 'false', true));
  assert(!mappedDatabaseValueEquals('occupants_json', '[{"id":2}]', '[{"id":1}]'));
});
test('lost reply confirms the complete patch without authorizing another write', () => {
  assert.equal(inspectLegacyRecovery(request), 'replay');
});
test('different remote value remains a conflict even with a fresh timestamp', () => {
  assert.equal(inspectLegacyRecovery({ ...request, observed: { note: 'other device' } }), 'conflict');
});
test('unchanged baseline still goes through the existing timestamp guard', () => {
  assert.equal(inspectLegacyRecovery({ ...request, observed: { note: 'old' } }), null);
});
test('no replay on missing version, baseline, fields or unknown projection', () => {
  for (const override of [{ updatedAt: null }, { updatedAt: 'bad' }, { guard: null },
    { fields: {} }, { observed: {} }, { guard: { version: 1, writeId: 'id' } }]) {
    assert.notEqual(inspectLegacyRecovery({ ...request, ...override }), 'replay');
  }
});
test('structured values and every changed field must match', () => {
  assert.equal(inspectLegacyRecovery({ ...request, fields: { note: 'new', people: [{ id: 1 }] },
    observed: { note: 'new', people: [{ id: 2 }] } }), null);
});

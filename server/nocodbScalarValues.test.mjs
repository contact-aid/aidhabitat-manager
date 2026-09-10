import assert from 'node:assert/strict';
import test from 'node:test';
import { canonicalDatabasePatch, createDatabaseValueComparator } from './nocodbScalarValues.mjs';

const columns = [{ title: 'instant', uidt: 'DateTime' }, { title: 'enabled', uidt: 'Checkbox' }, { title: 'text', uidt: 'SingleLineText' }];
const equals = createDatabaseValueComparator(columns);
test('only date columns compare zoned ISO and PostgreSQL timestamps as instants', () => {
  assert.equal(equals('instant', '2026-09-10T11:30:00.000+02:00', '2026-09-10 09:30:00+00:00'), true);
  assert.equal(equals('text', '2026-09-10T09:30:00.000Z', '2026-09-10 09:30:00+00:00'), false);
  assert.equal(equals('instant', '2026-09-10T09:30:00.000Z', '2026-09-10 09:30:00.000001+00:00'), false);
  assert.equal(equals('instant', '2026-09-10 09:30:00', '2026-09-10T09:30:00.000Z'), false);
  assert.equal(equals('instant', '2026-02-30T09:30:00Z', '2026-03-02T09:30:00Z'), false);
  assert.equal(equals('instant', null, ''), false);
});
test('typed checkbox mapping preserves null and does not coerce text or numbers', () => {
  assert.equal(equals('enabled', 'false', false), true);
  assert.equal(equals('enabled', 'true', true), true);
  assert.equal(equals('enabled', null, false), false);
  assert.equal(equals('enabled', '0', false), false);
  assert.equal(equals('text', 'false', false), false);
  assert.deepEqual(canonicalDatabasePatch({ enabled: 'false', text: 'false' }, columns), { enabled: false, text: 'false' });
});

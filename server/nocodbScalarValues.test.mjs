import assert from 'node:assert/strict';
import test from 'node:test';
import { canonicalDatabasePatch, createDatabaseValueComparator } from './nocodbScalarValues.mjs';

const columns = [{ title: 'instant', uidt: 'DateTime' }, { title: 'enabled', uidt: 'Checkbox' },
  { title: 'beneficiaire_apa', uidt: 'Checkbox' },
  { title: 'acces_facile_rue', uidt: 'Checkbox' },
  { title: 'text', uidt: 'SingleLineText' }];
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
  assert.equal(equals('enabled', 0, false), true);
  assert.equal(equals('enabled', '0', false), true);
  assert.equal(equals('enabled', null, false), false);
  assert.equal(equals('text', 'false', false), false);
  assert.deepEqual(canonicalDatabasePatch({ enabled: 'false', text: 'false' }, columns), { enabled: false, text: 'false' });
});

test('legacy false defaults are field-specific and preserve tri-state null', () => {
  for (const stored of [null, '', false, 'false', 0, '0']) {
    assert.equal(equals('beneficiaire_apa', stored, false), true);
  }
  assert.equal(equals('beneficiaire_apa', null, true), false);
  assert.equal(equals('acces_facile_rue', null, false), false);
});

test('null and empty string equivalence is limited to declared read defaults', () => {
  assert.equal(equals('commentaire', null, ''), true);
  assert.equal(equals('text', null, ''), false);
});

test('dossier enum names and NocoDB labels compare canonically', () => {
  assert.equal(equals('status', 'A visiter', 'TO_VISIT'), true);
  assert.equal(equals('status', 'À visiter', 'TO_VISIT'), true);
  assert.equal(equals('status', 'En cours', 'IN_PROGRESS'), true);
  assert.equal(equals('status', 'Clos', 'IN_PROGRESS'), false);
});

test('numeric representation changes are limited to Number columns', () => {
  const same = createDatabaseValueComparator([{ title: 'measure', uidt: 'Number' }]);
  assert(same('measure', '91.0', 91));
  assert(!same('measure', '91', 92));
  assert(!same('measure', '', 0));
  assert(!same('measure', null, 0));
  assert(!same('measure', '9007199254740993', 9007199254740992));
  assert(!same('text', '91', 91));
});

test('known JSON arrays ignore formatting but preserve order and all values', () => {
  assert(equals('sdb_instances_json', '[{"id":"1","enabled":true}]', '[ { "enabled": true, "id": "1" } ]'));
  assert(!equals('sdb_instances_json', '[1,2]', '[2,1]'));
  assert(!equals('sdb_instances_json', '[{"id":"1"}]', '[{"id":"2"}]'));
  assert(!equals('sdb_instances_json', 'invalid', '[]'));
  assert(!equals('text', '[1, 2]', '[1,2]'));
  assert(!equals('occupants_json', null, '[]'));
});

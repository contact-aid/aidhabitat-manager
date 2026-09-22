import assert from 'node:assert/strict';
import test from 'node:test';
import { DEFAULT_NOCODB_TABLES, resolveNocodbTables } from './nocodbTables.mjs';

test('table ids keep production defaults without an explicit override', () => {
  assert.deepEqual(resolveNocodbTables(''), DEFAULT_NOCODB_TABLES);
});

test('staging can replace a strict subset without changing other ids', () => {
  const tables = resolveNocodbTables(JSON.stringify({ dossiers: 'staging_dossiers', contexteDeVie: 'staging_context' }));
  assert.equal(tables.dossiers, 'staging_dossiers');
  assert.equal(tables.contexteDeVie, 'staging_context');
  assert.equal(tables.beneficiaires, DEFAULT_NOCODB_TABLES.beneficiaires);
});

test('malformed, unknown and unsafe overrides fail closed', () => {
  assert.throws(() => resolveNocodbTables('{'), /valid JSON/);
  assert.throws(() => resolveNocodbTables('[]'), /plain object/);
  assert.throws(() => resolveNocodbTables('{"other":"table"}'), /Unknown/);
  assert.throws(() => resolveNocodbTables('{"dossiers":"bad-id"}'), /Invalid/);
});

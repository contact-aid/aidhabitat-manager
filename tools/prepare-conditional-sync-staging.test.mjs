import assert from 'node:assert/strict';
import test from 'node:test';
import { buildPlan, REQUIRED_TABLES } from './prepare-conditional-sync-staging.mjs';

test('buildPlan accepts decorated staging titles in the required order', () => {
  const tables = [
    { id: '7', title: '🚿 diagnostic_sanitaires' }, { id: '2', title: 'Logements' },
    { id: '4', title: '👨‍👩‍👧 contexte_de_vie' }, { id: '1', title: 'Beneficiaires' },
    { id: '6', title: '📝 observations' }, { id: '3', title: '📁 dossiers' },
    { id: '5', title: '📏 mesures_anthropometriques' },
  ];
  assert.deepEqual(buildPlan(tables).map(table => table.key), REQUIRED_TABLES.map(table => table.key));
});

test('buildPlan rejects missing or ambiguous business tables', () => {
  assert.throws(() => buildPlan([]), /exactly one/);
  const tables = REQUIRED_TABLES.map((table, i) => ({ id: String(i), title: table.key }));
  tables.push({ id: 'duplicate', title: '📁 dossiers' });
  assert.throws(() => buildPlan(tables), /exactly one/);
});

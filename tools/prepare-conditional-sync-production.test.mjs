import test from 'node:test';
import assert from 'node:assert/strict';
import { parseArgs, PRODUCTION_BASE, RESTORE_PROOF } from './prepare-conditional-sync-production.mjs';

test('production preparation is dry-run without the apply flag', () => {
  assert.deepEqual(parseArgs([`--base=${PRODUCTION_BASE}`], {}), { apply: false });
});

test('production apply requires both the environment guard and restoration proof', () => {
  assert.throws(() => parseArgs([`--base=${PRODUCTION_BASE}`, '--apply'], {}));
  assert.throws(() => parseArgs([`--base=${PRODUCTION_BASE}`, '--apply'], { AIDHABITAT_PRODUCTION_MIGRATION: '1' }));
  assert.deepEqual(parseArgs([
    `--base=${PRODUCTION_BASE}`,
    `--backup-restored=${RESTORE_PROOF}`,
    '--apply',
  ], { AIDHABITAT_PRODUCTION_MIGRATION: '1' }), { apply: true });
});

test('production preparation rejects any other base or argument', () => {
  assert.throws(() => parseArgs(['--base=wrong'], {}));
  assert.throws(() => parseArgs([`--base=${PRODUCTION_BASE}`, '--force'], {}));
});

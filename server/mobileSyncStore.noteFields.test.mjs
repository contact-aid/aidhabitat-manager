import assert from 'node:assert/strict';
import test from 'node:test';
import { notePageReadFields } from './notePageFields.mjs';

test('note-page confirmation reads plan phase when the column exists', () => {
  const fields = notePageReadFields(new Set([
    'preview_data_url', 'preview_url', 'plan_phase',
  ]));
  assert(fields.includes('plan_phase'));
  assert(fields.includes('preview_data_url'));
  assert(fields.includes('preview_url'));
  assert(fields.includes('app_sync_revision'));
});

test('note-page reads remain compatible with schemas before plan phase', () => {
  const fields = notePageReadFields(new Set(['preview_data_url']));
  assert(!fields.includes('plan_phase'));
  assert(fields.includes('preview_data_url'));
});

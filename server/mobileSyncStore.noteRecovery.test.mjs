import assert from 'node:assert/strict';
import { randomBytes } from 'node:crypto';
import test from 'node:test';

import {
  assertNotePageWriteAllowed,
  compressDrawingForStorage,
  decompressDrawingForRead,
  sameNotePageIdentity,
} from './mobileSyncStore.mjs';

const oldRevision = '00000000-0000-4000-8000-000000000001';
const newWriteId = '00000000-0000-4000-8000-000000000002';

test('a missing-page retry cannot overwrite a concurrent create', () => {
  assert.throws(
    () => assertNotePageWriteAllowed({
      observedRevision: oldRevision,
      expectedRevision: null,
      writeId: newWriteId,
      matchesDesired: false,
    }),
    { status: 409, code: 'NOTE_PAGE_REVISION_CONFLICT' },
  );
});

test('a reused row id cannot silently move a Plans page', () => {
  const fields = {
    beneficiaire_id: 'patient-1', scope_type: 'visit_grid', scope_id: 'patient-1',
    tab_key: 'Plans', sub_tab_key: '', page_number: 2,
  };
  assert.equal(sameNotePageIdentity(fields, {
    patientId: 'patient-1', scopeType: 'visit_grid', scopeId: 'patient-1',
    tabKey: 'Plans', subTabKey: '', pageNumber: 1,
  }), false);
});

test('a lost response replays the same contents, but not changed contents', () => {
  assert.equal(assertNotePageWriteAllowed({
    observedRevision: newWriteId,
    expectedRevision: null,
    writeId: newWriteId,
    matchesDesired: true,
  }), 'replay');
  assert.throws(
    () => assertNotePageWriteAllowed({
      observedRevision: newWriteId,
      expectedRevision: null,
      writeId: newWriteId,
      matchesDesired: false,
    }),
    { status: 409, code: 'NOTE_PAGE_WRITE_ID_REUSED' },
  );
});

test('drawing compression is lossless and rejects incompressible overflow', () => {
  const drawing = JSON.stringify({ strokes: Array.from({ length: 30000 }, (_, i) => [i, i % 20]), text: 'fiction' });
  const stored = compressDrawingForStorage(drawing);
  assert(stored.startsWith('GZIP:'));
  assert(stored.length <= 100000);
  assert.equal(decompressDrawingForRead(stored), drawing);

  const incompressible = randomBytes(85000).toString('base64');
  assert.throws(
    () => compressDrawingForStorage(incompressible),
    { status: 413, code: 'NOTE_PAGE_CONTENT_TOO_LARGE' },
  );
});

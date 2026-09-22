import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

import {
  buildImplicitDossierFields,
  canAccessDossierAssignment,
  normalizeDossierAssignment,
} from './dossierAssignments.mjs';

const source = readFileSync(new URL('./index.mjs', import.meta.url), 'utf8');
const helpersSource = readFileSync(new URL('./helpers.mjs', import.meta.url), 'utf8');

const sourceFragment = (start, end) => {
  const from = source.indexOf(start);
  const to = source.indexOf(end, from + start.length);
  assert.ok(from >= 0 && to > from, `Source boundaries changed: ${start}`);
  return source.slice(from, to);
};

const buildFilter = () => new Function(
  'buildLocalAccessScopes',
  'normalizeDossierAssignment',
  `${sourceFragment('const filterDossiersByScopes =', 'const ensureDossierRecord =')}; return filterDossiersByScopes;`,
)(
  (user) => user.scopes ?? [],
  normalizeDossierAssignment,
);

test('empty, E1 and user are unassigned without rewriting existing labels', () => {
  for (const value of ['', ' ', 'E1', 'e1', 'user', ' USER ']) {
    assert.equal(normalizeDossierAssignment(value), '');
  }
  assert.equal(normalizeDossierAssignment('Coralie'), 'Coralie');
  assert.equal(normalizeDossierAssignment(' Christelle '), 'Christelle');
});

test('administrators retain visibility while ergotherapists need an assignment', () => {
  const admin = { role: 'ADMIN', ergoLabel: '' };
  const coralie = { role: 'ERGO', ergoLabel: 'Coralie' };
  const legacyE1 = { role: 'ERGO', ergoLabel: 'E1' };

  for (const assignment of ['', 'E1', 'user', 'Coralie']) {
    assert.equal(canAccessDossierAssignment(admin, assignment), true);
  }
  assert.equal(canAccessDossierAssignment(coralie, 'Coralie'), true);
  assert.equal(canAccessDossierAssignment(coralie, 'Christelle'), false);
  assert.equal(canAccessDossierAssignment(coralie, ''), false);
  assert.equal(canAccessDossierAssignment(legacyE1, 'E1'), false);
});

test('scope filtering never exposes an unassigned dossier to non-admin users', () => {
  const filter = buildFilter();
  const dossiers = [
    { id: 'empty', ergoId: '' },
    { id: 'e1', ergoId: 'E1' },
    { id: 'user', ergoId: 'user' },
    { id: 'coralie', ergoId: 'Coralie' },
    { id: 'christelle', ergoId: 'Christelle' },
  ];

  assert.deepEqual(filter(dossiers, { role: 'ADMIN', scopes: [] }), dossiers);
  assert.deepEqual(filter(dossiers, {
    role: 'ERGO',
    ergoLabel: 'Coralie',
    scopes: [{ type: 'dossier_ergo', value: 'Coralie' }],
  }), [dossiers[3]]);
  assert.deepEqual(filter(dossiers, {
    role: 'ERGO',
    ergoLabel: 'Coralie',
    scopes: [{ type: 'dossier_access', value: '*' }],
  }), [dossiers[3], dossiers[4]]);
  assert.deepEqual(filter(dossiers, {
    role: 'ERGO',
    ergoLabel: 'Coralie',
    scopes: [{ type: 'dossier_id', value: 'empty' }],
  }), []);
});

test('implicit dossier creation contains no assignment field', () => {
  const fields = buildImplicitDossierFields({
    uuidSource: 'dossier-1',
    patientId: 'patient-1',
    beneficiaryRecordId: 12,
    createdAt: '2026-09-14T08:00:00.000Z',
  });

  assert.equal(Object.hasOwn(fields, 'ergo_id'), false);
  assert.deepEqual(fields, {
    uuid_source: 'dossier-1',
    patient_id: 'patient-1',
    beneficiaires_id: 12,
    status: 'À visiter',
    created_at: '2026-09-14T08:00:00.000Z',
  });
});

test('GET dossier listing has no legacy migration writes', () => {
  const listing = sourceFragment(
    'const getDossiersForApp = async',
    'const getDossierByIdForApp = async',
  );
  const helperStart = helpersSource.indexOf('export const getDossiersForApp = async');
  const helperEnd = helpersSource.indexOf('export const ensureDossierRecord = async', helperStart);
  assert.ok(helperStart >= 0 && helperEnd > helperStart);
  const helperListing = helpersSource.slice(helperStart, helperEnd);

  assert.doesNotMatch(listing, /backfillLegacyDossierAssignments/);
  assert.doesNotMatch(listing, /backfillChildDossierLinks/);
  assert.doesNotMatch(helperListing, /backfillLegacyDossierAssignments/);
  assert.doesNotMatch(helperListing, /backfillChildDossierLinks/);
  assert.doesNotMatch(listing, /ergo_id\s*:/);
  assert.doesNotMatch(source, /const backfillLegacyDossierAssignments/);
});

test('explicitly assigned dossier creation remains wired to assignedErgoLabel', () => {
  const creationRoute = sourceFragment(
    "app.post('/api/beneficiaires'",
    "app.patch('/api/beneficiaires/:patientId'",
  );
  assert.match(creationRoute, /const assignedErgoLabel = await resolveRequestedErgoLabel/);
  assert.match(creationRoute, /ergo_id: assignedErgoLabel/);
});

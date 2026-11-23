import assert from 'node:assert/strict';
import test from 'node:test';
import { buildImplicitDossierFields, canAccessDossierAssignment } from './dossierAssignments.mjs';
import { selectDossierRecord, selectDossierByField } from './dossierRecordSelection.mjs';

const blank = {
  id: 2,
  fields: buildImplicitDossierFields({
    uuidSource: 'd177ec81-a44b-4bfa-b768-65f39004a011',
    patientId: 'nocodb-beneficiaire-7',
    beneficiaryRecordId: 7,
    createdAt: '2026-11-12T10:00:00.500Z',
  }),
};
const scheduled = {
  id: 1,
  fields: {
    ...blank.fields,
    created_at: '2026-11-12T10:00:00.000Z',
    uuid_source: 'airtable:rec12345678901234',
    ergo_id: 'Intervenante',
    visit_date: '2026-11-24T13:00:00.000Z',
    airtable_stage: '1b. Rendez-vous pris',
  },
};

test('a later blank cannot hide an imported visit in the agenda or block opening it', () => {
  for (const rows of [[scheduled, blank], [blank, scheduled]]) {
    const dossier = selectDossierRecord(rows);
    assert.equal(dossier, scheduled);
    assert.equal(selectDossierByField(rows, 'beneficiaires_id', '7'), dossier);
    assert.equal(selectDossierByField(rows, 'patient_id', blank.fields.patient_id), dossier);
    assert.equal(canAccessDossierAssignment({ role: 'ERGO', ergoLabel: 'Intervenante' }, dossier.fields.ergo_id), true);
    assert.equal(canAccessDossierAssignment({ role: 'ERGO', ergoLabel: 'Autre' }, dossier.fields.ergo_id), false);
  }
});

test('real later dossiers keep precedence, including unassigned or cancelled imports', () => {
  for (const fields of [
    { visit_date: '2026-12-01' }, { ergo_id: 'Autre' }, { status: 'En cours' },
    { beneficiaire_prepare: true }, { nature_accompagnement: 'complet' },
    { uuid_source: 'airtable:rec98765432109876', airtable_stage: 'Annulé' },
  ]) {
    const newer = { ...blank, fields: { ...blank.fields, ...fields } };
    assert.equal(selectDossierRecord([scheduled, newer]), newer);
  }
});

test('keeps the original fallback without an Airtable sibling and isolates beneficiaries', () => {
  const unrelated = { ...scheduled, fields: { ...scheduled.fields, beneficiaires_id: 8 } };
  assert.equal(selectDossierRecord([]), undefined);
  assert.equal(selectDossierRecord([blank]), blank);
  assert.equal(selectDossierRecord([unrelated, blank]), blank);
  assert.equal(selectDossierByField([unrelated, blank], 'beneficiaires_id', 8), unrelated);
});

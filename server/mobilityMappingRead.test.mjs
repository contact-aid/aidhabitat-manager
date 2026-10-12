// Contract for Main's shared mapper read correction. Intentionally fails on
// unpatched web68 when a stale linked reference hides nonempty free text.
import assert from 'node:assert/strict';
import test from 'node:test';
import { mapPatient, mapBeneficiaryUpdatesToFields } from './helpers.mjs';

const linkedCanne = { fields: { nom: 'Canne' } };
for (const [name, text, link, expected] of [
  ['old reference only', undefined, linkedCanne, 'Canne'],
  ['old null text', null, linkedCanne, 'Canne'],
  ['old empty text', '', linkedCanne, 'Canne'],
  ['single text', 'Déambulateur', null, 'Déambulateur'],
  ['multiple text and stale reference', 'Canne, Déambulateur', linkedCanne, 'Canne, Déambulateur'],
  ['unknown text and stale reference', 'Orthèse spéciale', linkedCanne, 'Orthèse spéciale'],
  ['absence text and stale reference', 'Aucune', linkedCanne, 'Aucune'],
  ['voluntary cleared text and relation', null, null, ''],
]) {
  test(`mobility read: ${name}`, () => {
    const fields = { dependance_particuliere: link };
    if (text !== undefined) fields.dependance_particuliere_txt = text;
    const input = { fields };
    const before = structuredClone(input);
    const patient = mapPatient(input, 'synthetic-mobility');
    assert.equal(patient.dependenceTxt, expected);
    assert.equal(patient.occupants[0].dependenceTxt, expected);
    assert.deepEqual(input, before);
  });
}

test('existing occupant JSON is not rewritten by a display-only read', () => {
  const patient = mapPatient({ fields: {
    dependance_particuliere: linkedCanne,
    dependance_particuliere_txt: 'Canne, Déambulateur',
    occupants_json: JSON.stringify([
      { firstName: 'Anne', dependenceTxt: 'Orthèse spécifique' },
      { firstName: 'Marie', dependenceTxt: 'Canne' },
    ]),
  } }, 'synthetic-mobility');
  assert.deepEqual(patient.occupants.map(o => o.dependenceTxt), ['Orthèse spécifique', 'Canne']);
});

test('omission versus explicit clear retain the existing write contract', () => {
  const refs = { situations: [], statuts: [], dependances: [], caisses: [],
    caissesComp: [], communes: [], baremesAnah: [] };
  const unrelated = mapBeneficiaryUpdatesToFields({ phone: '0612345678' }, refs);
  assert.equal(Object.hasOwn(unrelated, 'dependance_particuliere_txt'), false);
  assert.equal(Object.hasOwn(unrelated, 'dependances_particulieres_id'), false);
  const cleared = mapBeneficiaryUpdatesToFields({ dependenceTxt: '' }, refs);
  assert.equal(cleared.dependance_particuliere_txt, null);
  assert.equal(cleared.dependances_particulieres_id, null);
  const reread = mapPatient({ fields: { ...cleared, dependance_particuliere: null } }, 'synthetic-mobility');
  assert.equal(reread.dependenceTxt, '');
});

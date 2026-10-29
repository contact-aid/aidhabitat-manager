import { test } from 'node:test';
import assert from 'node:assert/strict';
import { planDatabaseMutation } from './guardedMutation.mjs';
import { initialValuePreference } from './syncInitialValues.mjs';

test('explicit answers beat initial defaults without an old baseline', () => {
  const fields = { dependance_particuliere_txt: 'Aucune', rdc: 'true',
    rooms_breakdown_json: JSON.stringify({ rdc: ['Cuisine', 'Chambre', 'Chambre'] }) };
  const plan = planDatabaseMutation({ fields, baseFields: {}, observed: {
    dependance_particuliere_txt: null, rdc: false,
    rooms_breakdown_json: JSON.stringify({ basement: [], rdc: [], floor: [] }),
  } });
  assert.deepEqual(plan.patch, fields);
  assert.deepEqual(plan.conflicts, []);
});

test('initial local defaults cannot erase explicit server answers', () => {
  const plan = planDatabaseMutation({ fields: { dependance_particuliere_txt: '', rdc: false },
    baseFields: {}, observed: { dependance_particuliere_txt: 'Aucune', rdc: true } });
  assert.deepEqual(plan.patch, {});
  assert.deepEqual(plan.retainedFields, ['dependance_particuliere_txt', 'rdc']);
});

test('same occupants can enrich empty properties but never replace real answers', () => {
  const person = { firstName: 'Camille', lastName: 'Fictif', birthDate: '' };
  const a = { ...person, dependenceTxt: 'Aucune', numeroSecuriteSociale: 'synthetic', caisseRetraitePrincipale: 'Caisse fictive' };
  const b = { ...person, dependenceTxt: '', numeroSecuriteSociale: '', caisseRetraitePrincipale: '' };
  const preference = (left, right) => initialValuePreference('occupants_json', JSON.stringify(left), JSON.stringify(right));
  assert.equal(preference([a], [b]), 'local');
  assert.equal(preference([b], [a]), 'remote');
  assert.equal(preference([a], [{ ...b, dependenceTxt: 'Canne' }]), null);
  assert.equal(preference([a], [{ ...b, lastName: 'Autre' }]), null);
  assert.equal(preference([a, a], [b, b]), null);
  assert.equal(preference([a], [{ ...b, unknown: 'preserve' }]), null);
  assert.equal(initialValuePreference('occupants_json', '{broken', '[]'), null);
});

test('no default inference for nullable choices, numbers, missing columns or invalid rooms', () => {
  for (const [key, local, remote] of [
    ['acces_facile_rue', true, false], ['revenue', 100, 0],
    ['dependance_particuliere_txt', 'Aucune', 'Canne'],
    ['rooms_breakdown_json', '{"rdc":["WC"]}', '{"unknown":[]}'],
  ]) {
    assert.deepEqual(planDatabaseMutation({ fields: { [key]: local }, baseFields: {},
      observed: { [key]: remote } }).conflicts, [key]);
  }
  assert.deepEqual(planDatabaseMutation({ fields: { rdc: true }, baseFields: {}, observed: {} }).conflicts, ['rdc']);
});

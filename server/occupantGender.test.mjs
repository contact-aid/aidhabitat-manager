import assert from 'node:assert/strict';
import test from 'node:test';
import { preserveLegacyOccupantGender } from './occupantGender.mjs';

const stored = JSON.stringify([
  { firstName: 'René', lastName: 'Exemple', birthDate: '1948-01-01', gender: 'Homme' },
  { firstName: 'Madeleine', lastName: 'Exemple', gender: 'Femme' },
]);

test('build 64 updates keep gender on matching occupants', () => {
  const updates = { occupants: [
    { firstName: 'René', lastName: 'Exemple', birthDate: '1948-01-01', homeHelp: true },
    { firstName: 'Madeleine', lastName: 'Exemple', homeHelp: false },
  ] };
  assert.deepEqual(preserveLegacyOccupantGender(updates, stored).occupants.map((o) => o.gender),
    ['Homme', 'Femme']);
});

test('an explicit web change or clear wins over the stored gender', () => {
  const updates = { occupants: [
    { firstName: 'René', lastName: 'Exemple', gender: 'Femme' },
    { firstName: 'Madeleine', lastName: 'Exemple', gender: '' },
  ] };
  assert.deepEqual(preserveLegacyOccupantGender(updates, stored), updates);
});

test('identity changes and invalid stored JSON never assign gender by position alone', () => {
  const updates = { occupants: [
    { firstName: 'Autre', lastName: 'Personne' },
    { firstName: 'Madeleine', lastName: 'Exemple' },
  ] };
  assert.throws(() => preserveLegacyOccupantGender(updates, stored), { statusCode: 409 });
  assert.equal(preserveLegacyOccupantGender(updates, '{').occupants[1].gender, undefined);
});


test('an appended occupant does not erase the genders of existing people', () => {
  const occupants = JSON.parse(stored).map(({ gender, ...rest }) => rest);
  occupants.push({ firstName: 'Alex', lastName: 'Exemple' });
  assert.deepEqual(preserveLegacyOccupantGender({ occupants }, stored).occupants.map(o => o.gender),
    ['Homme', 'Femme', undefined]);
});

test('reordered identities keep their own genders', () => {
  const occupants = JSON.parse(stored).map(({ gender, ...rest }) => rest).reverse();
  assert.deepEqual(preserveLegacyOccupantGender({ occupants }, stored).occupants.map(o => o.gender),
    ['Femme', 'Homme']);
});

test('legacy rename uses the observed identity and preserves medical edits', () => {
  const baseline = JSON.parse(stored).map(({ gender, ...rest }) => rest);
  const occupants = baseline.map(o => ({ ...o }));
  occupants[0].lastName = 'Corrigé';
  occupants[0].homeHelp = true;
  const result = preserveLegacyOccupantGender({ occupants,
    concurrency: { baseValues: { occupants: baseline } } }, stored);
  assert.equal(result.occupants[0].gender, 'Homme');
  assert.equal(result.occupants[0].homeHelp, true);
  assert.equal(result.occupants[0].lastName, 'Corrigé');
});

test('same birthday alone must not transfer gender to another person', () => {
  assert.throws(() => preserveLegacyOccupantGender({ occupants: [
    { firstName: 'Autre', lastName: 'Personne', birthDate: '1948-01-01' },
  ] }, stored), { statusCode: 409 });
});


test('an unnamed placeholder without gender remains editable beside a known person', () => {
  const first = JSON.parse(stored)[0];
  const { gender, ...legacyFirst } = first;
  const result = preserveLegacyOccupantGender({ occupants: [legacyFirst,
    { firstName: '', lastName: '', homeHelp: true }] }, JSON.stringify([first,
    { firstName: '', lastName: '', homeHelp: false }]));
  assert.equal(result.occupants[0].gender, 'Homme');
  assert.equal(result.occupants[1].homeHelp, true);
});

test('build 64 preserves a stored maiden name for the same occupant', () => {
  const storedWithMaidenName = JSON.stringify([
    { firstName: 'Madeleine', lastName: 'Exemple', gender: 'Femme', maidenName: 'Martin' },
  ]);
  const occupants = [{ firstName: 'Madeleine', lastName: 'Exemple', homeHelp: true }];
  const [result] = preserveLegacyOccupantGender({ occupants }, storedWithMaidenName).occupants;
  assert.equal(result.maidenName, 'Martin');
  assert.equal(result.gender, 'Femme');
  assert.equal(result.homeHelp, true);
});

test('an explicit maiden name change or clear is kept', () => {
  const storedWithMaidenName = JSON.stringify([
    { firstName: 'Madeleine', lastName: 'Exemple', maidenName: 'Martin' },
  ]);
  for (const maidenName of ['Durand', '']) {
    const occupants = [{ firstName: 'Madeleine', lastName: 'Exemple', maidenName }];
    assert.deepEqual(preserveLegacyOccupantGender({ occupants }, storedWithMaidenName).occupants, occupants);
  }
});

test('maiden name is not transferred to an ambiguous identity', () => {
  const storedWithMaidenName = JSON.stringify([
    { firstName: 'Madeleine', lastName: 'Exemple', maidenName: 'Martin' },
  ]);
  assert.throws(() => preserveLegacyOccupantGender({ occupants: [
    { firstName: 'Autre', lastName: 'Personne' },
  ] }, storedWithMaidenName), { statusCode: 409 });
});

test('older clients preserve RFR year and health details without reviving an explicit clear', () => {
  const previous = JSON.stringify([{
    firstName: 'Madeleine', lastName: 'Exemple', birthDate: '1948-01-01',
    fiscalRevenueYear: '2025', apaDetails: 'Détail fictif', invalidityDetails: 'Autre détail fictif',
  }]);
  const oldClient = [{ firstName: 'Madeleine', lastName: 'Exemple', birthDate: '1948-01-01', homeHelp: true }];
  const [preserved] = preserveLegacyOccupantGender({ occupants: oldClient }, previous).occupants;
  assert.equal(preserved.fiscalRevenueYear, '2025');
  assert.equal(preserved.apaDetails, 'Détail fictif');
  assert.equal(preserved.invalidityDetails, 'Autre détail fictif');
  const [cleared] = preserveLegacyOccupantGender({ occupants: [{ ...oldClient[0], apaDetails: '' }] }, previous).occupants;
  assert.equal(cleared.apaDetails, '');
  assert.throws(() => preserveLegacyOccupantGender({ occupants: [{ firstName: 'Autre', lastName: 'Personne' }] }, previous), { statusCode: 409 });
});

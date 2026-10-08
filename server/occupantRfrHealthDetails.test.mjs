import assert from 'node:assert/strict';
import test from 'node:test';
import { mapPatient, mapBeneficiaryUpdatesToFields } from './helpers.mjs';

const refs = { situations: [], statuts: [], dependances: [], caisses: [],
  caissesComp: [], communes: [], baremesAnah: [] };

test('per-occupant RFR year and health details survive the API mapper', () => {
  const occupants = [
    { firstName: 'Anne', lastName: 'Fictive', fiscalRevenue: 14000,
      fiscalRevenueYear: '2025', apa: true, apaGir: '3',
      apaDetails: 'Détail fictif APA', invalidity: true,
      invalidityTxt: '40 %', invalidityDetails: 'Détail fictif invalidité' },
    { firstName: 'Jean', lastName: 'Fictif', fiscalRevenue: 9000,
      fiscalRevenueYear: '2024' },
  ];
  const stored = mapBeneficiaryUpdatesToFields({ occupants }, refs).occupants_json;
  const read = mapPatient({ fields: { occupants_json: stored } }, 'synthetic-test');
  assert.deepEqual(read.occupants.map((o) => o.fiscalRevenueYear), ['2025', '2024']);
  assert.equal(read.occupants[0].apaDetails, 'Détail fictif APA');
  assert.equal(read.occupants[0].invalidityDetails, 'Détail fictif invalidité');
});

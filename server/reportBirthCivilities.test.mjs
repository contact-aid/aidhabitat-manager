import assert from 'node:assert/strict';
import test from 'node:test';
import { PDFDocument } from 'pdf-lib';
import {
  generateVisitReport,
  reportBirthSlots,
} from './reports/generateVisitReport.mjs';

test('birth-date slots follow occupant order and selected civilities', () => {
  const women = reportBirthSlots({ occupants: [
    { gender: 'Femme', birthDate: '1950-02-01' },
    { gender: 'Femme', birthDate: '1952-03-04' },
  ] });
  assert.deepEqual(women.civilities, ['Mme', 'Mme']);
  assert.equal(women.firstDate, '01/02/1950');
  assert.equal(women.secondDate, '04/03/1952');

  const men = reportBirthSlots({ occupants: [
    { gender: 'Homme', birthDate: '1950-02-01' },
    { gender: 'Homme', birthDate: '1952-03-04' },
  ] });
  assert.deepEqual(men.civilities, ['M.', 'M.']);

  const removed = reportBirthSlots({
    occupants: [{ gender: 'Femme', birthDate: '1952-03-04' }],
    birthDateMme: '1950-02-01',
  });
  assert.deepEqual(removed.civilities, ['Mme', '']);
  assert.equal(removed.secondDate, '');
  assert.deepEqual(reportBirthSlots({ occupants: [{ birthDate: '' }] }).civilities,
    ['', '']);
  assert.deepEqual(reportBirthSlots({ birthDateMr: '1950-02-01' }).civilities,
    ['M.', 'Mme']);
});

test('synthetic report fills both date fields for two women', async () => {
  const { bytes } = await generateVisitReport({
    dossier: {
      id: 'synthetic-two-women',
      patient: {
        firstName: 'Anne',
        lastName: 'EXEMPLE',
        occupants: [
          { firstName: 'Anne', gender: 'Femme', birthDate: '1950-02-01' },
          { firstName: 'Marie', gender: 'Femme', birthDate: '1952-03-04' },
        ],
      },
    },
    sanitaires: {},
    observations: {},
    fetchImageBytes: async () => null,
    flatten: false,
  });
  const pdf = await PDFDocument.load(bytes);
  assert.equal(pdf.getForm().getTextField('date de naissance').getText(), '01/02/1950');
  assert.equal(pdf.getForm().getTextField('date de naissance mme').getText(), '04/03/1952');
});

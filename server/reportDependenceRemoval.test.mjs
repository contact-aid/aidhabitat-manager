import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import test from 'node:test';
import { PDFDocument, PDFName } from 'pdf-lib';
import { generateVisitReport } from './reports/generateVisitReport.mjs';

for (const role of ['ERGO', 'TECHNICIAN']) {
  test(`${role}: dependence is omitted without losing birth dates`, async () => {
    const { bytes } = await generateVisitReport({
      dossier: { id: `synthetic-${role}`, patient: {
        firstName: 'Anne', lastName: 'FICTIF', dependenceTxt: 'Canne - AIDE-MOBILITE-SECRET',
        occupants: [
          { firstName: 'Anne', lastName: 'FICTIF', gender: 'Femme', birthDate: '1950-02-01' },
          { firstName: 'Paul', lastName: 'FICTIF', gender: 'Homme', birthDate: '1952-03-04' },
        ],
      } },
      ergoProfile: { role, displayName: 'INTERVENANT FICTIF' },
      sanitaires: {}, observations: {}, fetchImageBytes: async () => null,
      flatten: false,
    });
    const pdf = await PDFDocument.load(bytes);
    const form = pdf.getForm();
    assert.equal(form.getTextField('date de naissance').getText(), '01/02/1950');
    assert.equal(form.getTextField('date de naissance mme').getText(), '04/03/1952');
    assert.equal(form.getTextField('dépendance').getText() || '', '');
    const text = spawnSync('pdftotext', ['-', '-'], {
      input: Buffer.from(bytes), encoding: 'utf8', maxBuffer: 5_000_000,
    });
    if (!text.error) assert.doesNotMatch(text.stdout, /AIDE-MOBILITE-SECRET/);
  });
}

test('flattened report has no remaining form widgets', async () => {
  const { bytes } = await generateVisitReport({
    dossier: { id: 'synthetic-flat', patient: { dependenceTxt: 'Canne' } },
    sanitaires: {}, observations: {}, fetchImageBytes: async () => null,
  });
  const pdf = await PDFDocument.load(bytes);
  assert.equal(pdf.getForm().getFields().length, 0);
  for (const page of pdf.getPages()) {
    for (const ref of page.node.Annots()?.asArray() || []) {
      const annotation = pdf.context.lookup(ref);
      assert.notEqual(annotation?.get?.(PDFName.of('Subtype')), PDFName.of('Widget'));
    }
  }
});

import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import test, { before, after } from 'node:test';
import { PDFDocument, PDFArray, PDFName } from 'pdf-lib';
import { mobilityPdfSandbox } from '../tools/compat/mobility-pdf-sandbox.mjs';
import { formatMobilityAidsForReport } from './reports/mobilityAids.mjs';

let sandbox;
before(async () => { sandbox = await mobilityPdfSandbox(); });
after(async () => { await sandbox?.dispose(); });

function streams(doc, page) {
  const contents = page.node.Contents();
  const refs = contents instanceof PDFArray ? contents.asArray() : [contents];
  return refs.filter(Boolean).map(ref => Buffer.from(doc.context.lookup(ref).contents));
}

for (const role of ['ERGO', 'TECHNICIAN']) {
  for (const long of [false, true]) {
    test(`${role}: mobility display preserves birth dates and original Morbihan page (long=${long})`, async () => {
      const raw = long
        ? 'Canne, Déambulateur, Fauteuil roulant, Orthèse de marche personnalisée avec assistance spécifique'
        : 'Canne, Déambulateur, Fauteuil roulant, Canne';
      const options = {
        dossier: { id: 'synthetic-mobility', patient: {
          firstName: 'Anne', lastName: 'FICTIF', zipCode: '56000', dependenceTxt: raw,
          occupants: [
            { gender: role === 'ERGO' ? 'Femme' : 'Homme', birthDate: '1950-02-01' },
            { gender: role === 'ERGO' ? 'Femme' : 'Homme', birthDate: '1952-03-04' },
          ],
        } },
        ergoProfile: { role, displayName: 'INTERVENANT FICTIF' },
        sanitaires: {}, observations: {}, fetchImageBytes: async () => null, flatten: false,
      };
      const previous = await PDFDocument.load((await sandbox.generateVisitReport({
        ...options, dossier: { ...options.dossier, patient: {
          ...options.dossier.patient, dependenceTxt: '',
        } },
      })).bytes);
      const result = await sandbox.generateVisitReport(options);
      const pdf = await PDFDocument.load(result.bytes);
      const form = pdf.getForm();
      assert.equal(form.getTextField('date de naissance').getText(), '01/02/1950');
      assert.equal(form.getTextField('date de naissance mme').getText(), '04/03/1952');
      assert.equal(form.getTextField('dépendance').getText(), long
        ? 'Voir annexe aides à la mobilité' : formatMobilityAidsForReport(raw));
      assert.equal(pdf.getPageCount(), previous.getPageCount() + (long ? 1 : 0));
      assert.equal(result.stats.morbihanWorksPageAdded, true);
      const appendix = await PDFDocument.load(await fs.readFile(
        new URL('./templates/visitReport.morbihan-eligible-works.pdf', import.meta.url)));
      const original = streams(appendix, appendix.getPage(0))[0];
      assert.equal(pdf.getPages().filter(page => streams(pdf, page)
        .some(stream => stream.equals(original))).length, 1);
    });
  }
}

test('intentional empty remains empty and flattened report has no remaining widgets', async () => {
  const options = { dossier: { id: 'empty-mobility', patient: { dependenceTxt: '' } },
    sanitaires: {}, observations: {}, fetchImageBytes: async () => null };
  const interactive = await PDFDocument.load((await sandbox.generateVisitReport({ ...options, flatten: false })).bytes);
  assert.equal(interactive.getForm().getTextField('dépendance').getText() || '', '');
  const flat = await PDFDocument.load((await sandbox.generateVisitReport(options)).bytes);
  assert.equal(flat.getForm().getFields().length, 0);
  for (const page of flat.getPages()) {
    for (const ref of page.node.Annots()?.asArray() || []) {
      const annotation = flat.context.lookup(ref);
      assert.notEqual(annotation?.get?.(PDFName.of('Subtype')), PDFName.of('Widget'));
    }
  }
});


test('unsupported pasted symbols do not abort the report or disappear silently', async () => {
  const result = await sandbox.generateVisitReport({
    dossier: { patient: { dependenceTxt: 'Orthèse ≥ 5 cm 🦯' } }, sanitaires: {},
    observations: {}, fetchImageBytes: async () => null, flatten: false,
  });
  const pdf = await PDFDocument.load(result.bytes);
  const value = pdf.getForm().getTextField('dépendance').getText();
  assert.equal(value, 'Orthèse >= 5 cm [U+1F9AF]');
});

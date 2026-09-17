import test from 'node:test';
import assert from 'node:assert/strict';
import { PDFDocument, PDFName } from 'pdf-lib';
import { generateVisitReport } from './reports/generateVisitReport.mjs';

for (const role of ['TECHNICIAN', 'ERGO']) {
  test(`${role} report fills professional identity and flattens without dangling widgets`, async () => {
    const options = {
      dossier: { id: 'synthetic-report', patient: { firstName: 'Camille', lastName: 'EXEMPLE' } },
      sanitaires: {}, observations: {},
      ergoProfile: { role, displayName: 'Fabien CRIBIER', email: 'f.cribier@aidhabitat.fr' },
      fetchImageBytes: async () => null,
    };
    const editable = await generateVisitReport({ ...options, flatten: false });
    const editablePdf = await PDFDocument.load(editable.bytes);
    const form = editablePdf.getForm();
    const expectedLinks = editablePdf.getPages().flatMap(page => page.node.Annots()?.asArray() || [])
      .filter(ref => editablePdf.context.lookup(ref)?.get?.(PDFName.of('Subtype')) === PDFName.of('Link')).length;
    assert.equal(form.getTextField('Nom et prénom').getText(), 'Fabien CRIBIER');
    assert.match(form.getTextField('contact').getText(), /f\.cribier@aidhabitat\.fr/);
    const result = await generateVisitReport(options);
    const pdf = await PDFDocument.load(result.bytes);
    assert.equal(pdf.getForm().getFields().length, 0);
    assert.ok(pdf.getPageCount() > 10);
    let links = 0;
    for (const page of pdf.getPages()) {
      for (const ref of page.node.Annots()?.asArray() || []) {
        const annotation = pdf.context.lookup(ref);
        assert.ok(annotation, 'Every annotation reference must resolve');
        assert.notEqual(annotation.get(PDFName.of('Subtype')), PDFName.of('Widget'));
        if (annotation.get(PDFName.of('Subtype')) === PDFName.of('Link')) links++;
      }
    }
    assert.equal(links, expectedLinks, 'Existing links must survive flattening');
  });
}

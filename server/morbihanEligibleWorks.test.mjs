import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import test from 'node:test';
import { PDFArray, PDFDocument } from 'pdf-lib';
import { generateVisitReport } from './reports/generateVisitReport.mjs';
import { needsMorbihanEligibleWorks, insertMorbihanEligibleWorks } from './reports/morbihanEligibleWorks.mjs';

function streams(doc, page) {
  const contents = page.node.Contents();
  const refs = contents instanceof PDFArray ? contents.asArray() : [contents];
  return refs.filter(Boolean).map(ref => Buffer.from(doc.context.lookup(ref).contents));
}

function containsStream(doc, page, expected) {
  return streams(doc, page).some(stream => stream.equals(expected));
}

test('Morbihan is determined exclusively by a complete structured 56xxx postal code', () => {
  for (const zipCode of ['56000', '56100', '56999', ' 56300 ', 56000]) {
    assert.equal(needsMorbihanEligibleWorks({ patient: { zipCode } }), true);
  }
  for (const zipCode of ['35000', '29000', '5600', '560000', '56', '', null, undefined, 'abc56000']) {
    assert.equal(needsMorbihanEligibleWorks({ patient: { zipCode, address: '56 rue du Morbihan' } }), false);
  }
  assert.equal(needsMorbihanEligibleWorks({}), false);
});

test('invalid insertion anchor fails rather than silently placing the appendix elsewhere', async () => {
  const pdf = await PDFDocument.create();
  pdf.addPage();
  await assert.rejects(insertMorbihanEligibleWorks(pdf, -1), /introuvable/);
});

for (const [role, recoCount] of [['ERGO', 0], ['ERGO', 1], ['ERGO', 2], ['TECHNICIAN', 1]]) {
  test(`${role}, ${recoCount} recommendations: exactly one original page before the norms, only for 56`, async () => {
    const source = await PDFDocument.load(await fs.readFile(new URL('./templates/visitReport.morbihan-eligible-works.pdf', import.meta.url)));
    const appendixStream = streams(source, source.getPage(0))[0];
    const template = await PDFDocument.load(await fs.readFile(new URL(
      role === 'TECHNICIAN' ? './templates/visitReport.technician.pdf' : './templates/visitReport.template.pdf', import.meta.url,
    )));
    const normsStream = streams(template, template.getPage(17))[0];
    const options = {
      sanitaires: {}, observations: {},
      ergoProfile: { role, displayName: 'INTERVENANT FICTIF' },
      recommendations: Array.from({length: recoCount}, (_, i) => ({wikiTitle: `Travaux fictifs ${i + 1}`, note: 'Données de test'})),
      fetchImageBytes: async () => null,
    };
    const generate = zipCode => generateVisitReport({ ...options,
      dossier: {id: 'synthetic-morbihan', patient: {firstName: 'Camille', lastName: 'EXEMPLE', zipCode}},
    });
    const local = await generate('56000');
    const other = await generate('35000');
    const pdf = await PDFDocument.load(local.bytes);
    const otherPdf = await PDFDocument.load(other.bytes);
    const indices = pdf.getPages().map((page, index) => containsStream(pdf, page, appendixStream) ? index : -1).filter(index => index >= 0);
    assert.equal(indices.length, 1);
    assert.ok(containsStream(pdf, pdf.getPage(indices[0] + 1), normsStream), 'The first norms page immediately follows the appendix');
    assert.equal(pdf.getPageCount(), otherPdf.getPageCount() + 1);
    assert.equal(local.stats.morbihanWorksPageAdded, true);
    assert.equal(other.stats.morbihanWorksPageAdded, false);
    assert.equal(local.stats.descriptifMerged, recoCount % 2 === 1);
    assert.ok(otherPdf.getPages().every(page => !containsStream(otherPdf, page, appendixStream)));
    assert.deepEqual(pdf.getPage(indices[0]).getSize(), source.getPage(0).getSize());
    assert.equal(pdf.getForm().getFields().length, 0);
  });
}

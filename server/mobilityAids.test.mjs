import assert from 'node:assert/strict';
import test from 'node:test';
import { PDFDocument, StandardFonts } from 'pdf-lib';
import { formatMobilityAidsForReport, applyMobilityAidsToReport } from './reports/mobilityAids.mjs';

test('display retains single/multiple/unknown values and explicit empty', () => {
  for (const value of ['', 'Canne', 'Orthèse spéciale', 'Canne adaptée sur mesure']) {
    assert.equal(formatMobilityAidsForReport(value), value);
  }
  assert.equal(formatMobilityAidsForReport('Canne, Déambulateur, Fauteuil roulant'),
    'Canne, Déambulateur, Fauteuil roulant');
  assert.equal(formatMobilityAidsForReport('Canne; Déambulateur\ncanne, Orthèse spéciale, Orthèse spéciale'),
    'Canne, Déambulateur, Orthèse spéciale');
  assert.equal(formatMobilityAidsForReport('Non'), 'Aucune');
  assert.equal(formatMobilityAidsForReport('Aucune, Canne adaptée'), 'Aucune, Canne adaptée');
});

test('short list fits the field and long free text is complete in an appendix', async () => {
  const pdfDoc = await PDFDocument.create();
  const page = pdfDoc.addPage([595, 842]);
  const field = pdfDoc.getForm().createTextField('dépendance');
  field.addToPage(page, { x: 400, y: 530, width: 163, height: 20, borderWidth: 0 });
  const font = await pdfDoc.embedFont(StandardFonts.Helvetica);
  const short = 'Canne, Déambulateur, Fauteuil roulant';
  const result = applyMobilityAidsToReport({ pdfDoc, field, font, rawValue: short });
  assert.equal(result.addedPages, 0);
  assert.equal(field.getText(), short);
  const long = `${short}, Orthèse de marche personnalisée avec assistance spécifique`;
  const overflow = applyMobilityAidsToReport({ pdfDoc, field, font, rawValue: long });
  assert.equal(overflow.text, long);
  assert.equal(overflow.addedPages, 1);
  assert.equal(pdfDoc.getPageCount(), 2);
  assert.equal(field.getText(), 'Voir annexe aides à la mobilité');
});

test('unknown long words wrap without dropping any character', async () => {
  const { decodePDFRawStream } = await import('pdf-lib');
  const pdfDoc = await PDFDocument.create();
  const page = pdfDoc.addPage([595, 842]);
  const field = pdfDoc.getForm().createTextField('dépendance');
  field.addToPage(page, { x: 400, y: 530, width: 163, height: 20, borderWidth: 0 });
  const font = await pdfDoc.embedFont(StandardFonts.Helvetica);
  const text = 'Orthèse '.repeat(160) + 'X'.repeat(150);
  applyMobilityAidsToReport({ pdfDoc, field, font, rawValue: text });
  const content = pdfDoc.getPages().slice(1).map((page) => {
    const contents = page.node.Contents();
    const refs = contents.asArray ? contents.asArray() : [contents];
    return refs.map(ref => {
      const stream = pdfDoc.context.lookup(ref);
      // Before serialization page contents are uncompressed content streams.
      return stream.getUnencodedContents
        ? Buffer.from(stream.getUnencodedContents()).toString()
        : Buffer.from(decodePDFRawStream(stream).decode()).toString();
    }).join('\n');
  }).join('\n');
  const strings = [...content.matchAll(/<([A-Fa-f\d]+)>\s*Tj/g)]
    .map(match => new TextDecoder('windows-1252').decode(Buffer.from(match[1], 'hex')))
    .filter(value => !value.startsWith('Annexe -'));
  assert.equal(strings.join('').replace(/\s/g, ''), text.replace(/\s/g, ''));
});

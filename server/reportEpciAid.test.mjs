import assert from 'node:assert/strict';
import test from 'node:test';
import { hasEpciAid, resolveReportEpciAid } from './reports/reportEpciAid.mjs';
for (const value of [null, undefined, false, '', 'Non', '0', '/', 'Aucune']) {
  test(`no EPCI funding for ${value}`, () => assert.equal(hasEpciAid(value), false));
}
for (const value of [true, 'Oui', '500 € sous conditions']) {
  test(`EPCI funding for ${value}`, () => assert.equal(hasEpciAid(value), true));
}
for (const aid of [null, 'Non', '500 €']) {
  test(`territory label only appears with actual aid: ${aid}`, async () => {
    const calls = [];
    const label = await resolveReportEpciAid({ cityId: '46' }, {
      tables: { communes: 'town', epci: 'epci' },
      queryAll: async (table, options) => {
        calls.push([table, options.where]);
        return [{ fields: table === 'town' ? { epci_id1: 9 } : { nom: 'EPCI exemple', aide_communautes_commune: aid } }];
      },
    });
    assert.equal(label, aid === '500 €' ? 'EPCI exemple' : '/');
    assert.deepEqual(calls, [['town', '(Id,eq,46)'], ['epci', '(Id,eq,9)']]);
  });
}

test('PDF keeps the community row and its borders, with a dash when there is no aid', async () => {
  const { PDFPage } = await import('pdf-lib');
  const { generateVisitReport } = await import('./reports/generateVisitReport.mjs');
  const originalRectangle = PDFPage.prototype.drawRectangle;
  const originalText = PDFPage.prototype.drawText;
  for (const role of ['ERGO', 'TECHNICIAN']) {
    for (const label of ['/', '', 'EPCI avec aide']) {
      const rectangles = [];
      const text = [];
      PDFPage.prototype.drawRectangle = function(options) {
        rectangles.push(options);
        return originalRectangle.call(this, options);
      };
      PDFPage.prototype.drawText = function(value, options) {
        if (options.x === 383.2) text.push(value);
        return originalText.call(this, value, options);
      };
      try {
        await generateVisitReport({
          dossier: { patient: { firstName: 'Test', lastName: 'AIDES' } },
          ergoProfile: { role }, epciResolved: label,
          caisseComplementaireResolved: 'Pro BTP, IRCANTEC sous conditions*',
          fetchImageBytes: async () => null,
        });
      } finally {
        PDFPage.prototype.drawRectangle = originalRectangle;
        PDFPage.prototype.drawText = originalText;
      }
      assert.ok(text.includes(label && label !== '/' ? label : '-'), `${role}: community value`);
      assert.ok(!rectangles.some(r => r.x === 40 && r.y === 519 && r.width === 516),
        'the template community row must remain visible');
      assert.ok(!rectangles.some(r => r.x > 370 && r.x < 390 && r.y <= 564 && r.y + r.height >= 564),
        'value masks must not cover the retirement row border');
    }
  }
});

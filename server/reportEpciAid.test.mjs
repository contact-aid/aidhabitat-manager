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

test('PDF clears the whole community row only when there is no aid', async () => {
  const { PDFPage } = await import('pdf-lib');
  const { generateVisitReport } = await import('./reports/generateVisitReport.mjs');
  const original = PDFPage.prototype.drawRectangle;
  for (const label of ['/', 'EPCI avec aide']) {
    let cleared = false;
    PDFPage.prototype.drawRectangle = function(options) {
      if (options.x === 44 && options.y === 523 && options.width === 510) cleared = true;
      return original.call(this, options);
    };
    try {
      await generateVisitReport({ dossier: { patient: { firstName: 'Test', lastName: 'AIDES' } }, epciResolved: label, fetchImageBytes: async () => null });
    } finally { PDFPage.prototype.drawRectangle = original; }
    assert.equal(cleared, label === '/');
  }
});

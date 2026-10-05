// Characterization of the current PDF limits, not a release acceptance test.
import assert from 'node:assert/strict';
import test from 'node:test';
import { mkdtemp, writeFile, rm, copyFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { execFileSync } from 'node:child_process';
import { PDFDocument } from 'pdf-lib';
import { appendSanitaryRoomsAppendix } from './reports/sanitaryRoomsAppendix.mjs';
import { generateVisitReport } from './reports/generateVisitReport.mjs';

test('sanitary PDF retains first three columns but omits fourth room and later WC observations', async () => {
  const folder = await mkdtemp(`${tmpdir()}/assist2-sanitary-pdf-`);
  try {
    const fixture = {
      dossier: { id: 'synthetic-only', patient: { firstName: 'Fictif', lastName: 'SANITAIRES', occupants: [] }, housing: {} },
      sanitaires: {
        sdbInstances: Array.from({ length: 4 }, (_, i) => ({ id: `bath-${i}`, levelField: i === 2 ? 'floor' : 'rdc',
          levelLabel: `Salle fictive ${i + 1}`, sdbBaignoire: true, sdbBaignoireHauteur: 41 + i,
          porteSdbDimension: 71 + i })),
        wcInstances: Array.from({ length: 4 }, (_, i) => ({ id: `wc-${i}`, levelField: i === 2 ? 'floor' : 'rdc',
          wcCuvetteHauteur: 51 + i, porteWcDimension: 81 + i,
          observationEquipementsUtilisation: `OBSERVATION_FICTIVE_${i + 1}` })),
      }, observations: {}, fetchImageBytes: async () => { throw new Error('No network allowed'); },
    };
    const { bytes } = await generateVisitReport(fixture);
    const pdf = `${folder}/report.pdf`;
    await writeFile(pdf, bytes);
    const text = execFileSync('pdftotext', ['-layout', pdf, '-'], { encoding: 'utf8' });
    for (const value of ['41 cm', '42 cm', '43 cm', '51 cm', '52 cm', '53 cm']) assert(text.includes(value), value);
    for (const value of ['44 cm', '54 cm', 'Salle de bain 4', 'WC 4', 'OBSERVATION_FICTIVE_2']) assert(!text.includes(value), `Known omission: ${value}`);
    assert(text.includes('OBSERVATION_FICTIVE_1'));
    const fixedDoc = await PDFDocument.load(bytes);
    const originalCount = fixedDoc.getPageCount();
    const extraPages = await appendSanitaryRoomsAppendix({ pdfDoc: fixedDoc, sanitaires: fixture.sanitaires });
    assert(extraPages > 0);
    assert.equal(fixedDoc.getPageCount(), originalCount + extraPages);
    const fixedPath = `${folder}/complete-report.pdf`;
    await writeFile(fixedPath, await fixedDoc.save());
    const completeText = execFileSync('pdftotext', ['-layout', fixedPath, '-'], { encoding: 'utf8' });
    for (const value of ['44 cm', '54 cm', 'Salle de bain 4', 'WC 4', 'OBSERVATION_FICTIVE_2', 'OBSERVATION_FICTIVE_4']) assert(completeText.includes(value), value);
    if (process.env.SANITARY_REVIEW_FIXED_PDF) await copyFile(fixedPath, process.env.SANITARY_REVIEW_FIXED_PDF);
    // Optional review output stays outside real dossiers; all values are synthetic.
    if (process.env.SANITARY_REVIEW_PDF) await copyFile(pdf, process.env.SANITARY_REVIEW_PDF);
  } finally { await rm(folder, { recursive: true, force: true }); }
});

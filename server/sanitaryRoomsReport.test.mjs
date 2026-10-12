// Acceptance of the integrated, read-only sanitary PDF appendix.
import assert from 'node:assert/strict';
import test from 'node:test';
import { mkdtemp, writeFile, rm, copyFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { execFileSync } from 'node:child_process';
import { PDFDocument } from 'pdf-lib';
import { generateVisitReport } from './reports/generateVisitReport.mjs';

test('integrated sanitary PDF retains all rooms and observations without changing input', async () => {
  const folder = await mkdtemp(`${tmpdir()}/assist2-sanitary-pdf-`);
  try {
    const fixture = {
      dossier: { id: 'synthetic-only', patient: { firstName: 'Fictif', lastName: 'SANITAIRES', occupants: [], zipCode: '56000',
          dependenceTxt: 'Canne, Déambulateur, Fauteuil roulant, Orthèse fictive avec assistance spécifique' }, housing: {} },
      sanitaires: {
        sdbInstances: Array.from({ length: 4 }, (_, i) => ({ id: `bath-${i}`, levelField: i === 2 ? 'floor' : 'rdc',
          levelLabel: `Salle fictive ${i + 1}`, sdbBaignoire: true, sdbBaignoireHauteur: 41 + i,
          porteSdbDimension: 71 + i })),
        wcInstances: Array.from({ length: 4 }, (_, i) => ({ id: `wc-${i}`, levelField: i === 2 ? 'floor' : 'rdc',
          wcCuvetteHauteur: 51 + i, porteWcDimension: 81 + i,
          observationEquipementsUtilisation: `OBSERVATION_FICTIVE_${i + 1}` })),
      }, observations: {}, fetchImageBytes: async () => { throw new Error('No network allowed'); },
    };
    const original = structuredClone(fixture.sanitaires);
    const { bytes, stats } = await generateVisitReport(fixture);
    assert.deepEqual(fixture.sanitaires, original);
    assert(stats.sanitaryAppendixPages > 0);
    assert.equal(stats.mobilityAppendixPages, 1);
    assert.equal(stats.morbihanWorksPageAdded, true);
    const pdf = `${folder}/report.pdf`;
    await writeFile(pdf, bytes);
    const text = execFileSync('pdftotext', ['-layout', pdf, '-'], { encoding: 'utf8' });
    for (const value of ['41 cm', '42 cm', '43 cm', '51 cm', '52 cm', '53 cm']) assert(text.includes(value), value);
    for (const value of ['44 cm', '54 cm', 'Salle de bain 4', 'WC 4',
        'OBSERVATION_FICTIVE_1', 'OBSERVATION_FICTIVE_2', 'OBSERVATION_FICTIVE_4']) {
      assert(text.includes(value), `Missing from integrated output: ${value}`);
    }
    const pdfDoc = await PDFDocument.load(bytes);
    assert.equal(pdfDoc.getForm().getFields().length, 0);
    assert(text.includes('Orthèse fictive avec assistance spécifique'));
    assert(text.includes('Annexe - Aides à la mobilité'));
    assert(text.indexOf('Annexe - Aides à la mobilité') < text.indexOf('Annexe — Détail des sanitaires'));
    if (process.env.SANITARY_REVIEW_FIXED_PDF) await copyFile(pdf, process.env.SANITARY_REVIEW_FIXED_PDF);
    // Optional review output stays outside real dossiers; all values are synthetic.
    if (process.env.SANITARY_REVIEW_PDF) await copyFile(pdf, process.env.SANITARY_REVIEW_PDF);
  } finally { await rm(folder, { recursive: true, force: true }); }
});

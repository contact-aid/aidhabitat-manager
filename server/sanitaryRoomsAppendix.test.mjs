import assert from 'node:assert/strict';
import test from 'node:test';
import { PDFDocument } from 'pdf-lib';
import { mkdtemp, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { execFileSync } from 'node:child_process';
import { appendSanitaryRoomsAppendix, needsSanitaryRoomsAppendix } from './reports/sanitaryRoomsAppendix.mjs';

test('appendix is absent for old single rooms and complete existing tables', () => {
  assert.equal(needsSanitaryRoomsAppendix({}), false);
  assert.equal(needsSanitaryRoomsAppendix({ wcInstances: [{ observationEquipementsUtilisation: 'old note' }] }), false);
  assert.equal(needsSanitaryRoomsAppendix({ wcInstances: [{ levelField: 'rdc', wcCuvetteHauteur: 40 }, { levelField: 'rdc', wcCuvetteHauteur: 42 }] }), false);
});

test('appendix preserves all rooms, measurements, long observations and input; paginates', async () => {
  const folder = await mkdtemp(`${tmpdir()}/assist2-sanitary-appendix-`);
  try {
    const sanitaires = {
      sdbInstances: Array.from({ length: 4 }, (_, i) => ({ id: `private-bath-id-${i}`, levelField: 'rdc',
        levelLabel: `RDC salle ${i + 1}`, sdbBaignoire: i === 0, sdbBaignoireHauteur: 41 + i,
        sdbVasqueSuspendueHauteur: i === 1 ? 87 : null, porteSdbDimension: 71 + i })),
      wcInstances: Array.from({ length: 4 }, (_, i) => ({ id: `private-wc-id-${i}`, levelField: i === 2 ? 'second_floor' : 'rdc',
        wcCuvetteHauteur: 51 + i, wcBarreRelevement: i === 1, porteWcDimension: 81 + i,
        observationEquipementsUtilisation: `NOTE_${i + 1} ` + (i === 3 ? 'Observation fictive longue. '.repeat(450) + 'FIN_DERNIERE_NOTE' : '') })),
    };
    const before = structuredClone(sanitaires);
    const pdf = await PDFDocument.create();
    const pages = await appendSanitaryRoomsAppendix({ pdfDoc: pdf, sanitaires });
    assert(pages >= 4);
    assert.deepEqual(sanitaires, before);
    const bytes = await pdf.save();
    const path = `${folder}/appendix.pdf`; await writeFile(path, bytes);
    const output = execFileSync('pdftotext', ['-layout', path, '-'], { encoding: 'utf8' });
    for (let i = 1; i <= 4; i++) {
      assert(output.includes(`Salle de bain ${i}`)); assert(output.includes(`WC ${i}`)); assert(output.includes(`NOTE_${i}`));
    }
    for (const value of ['44 cm', '54 cm', '87 cm', '2e étage', 'FIN_DERNIERE_NOTE']) assert(output.includes(value), value);
    assert(!output.includes('private-'));
    if (process.env.SANITARY_APPENDIX_PDF) await writeFile(process.env.SANITARY_APPENDIX_PDF, bytes);
  } finally { await rm(folder, { recursive: true, force: true }); }
});

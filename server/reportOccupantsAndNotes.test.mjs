import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import test from 'node:test';
import { PDFDocument } from 'pdf-lib';
import { generateVisitReport } from './reports/generateVisitReport.mjs';

test('occupant identities and health details are printable, and long visit notes continue', async (t) => {
  const longNote = 'Observation médicale longue. '.repeat(160);
  const { bytes, stats } = await generateVisitReport({
    dossier: {
      id: 'synthetic-occupants',
      patient: {
        firstName: 'Anne', lastName: 'EXEMPLE', familySituation: 'Pacsé(e)',
        occupants: [
          { firstName: 'Anne', lastName: 'EXEMPLE', gender: 'Femme',
            birthDate: '1950-02-01', maidenName: 'MARTIN',
            apa: true, invalidity: true,
            apaDetails: 'Accompagnement quotidien',
            invalidityDetails: 'Reconnaissance permanente' },
          { firstName: 'Paul', lastName: 'EXEMPLE', gender: 'Homme',
            birthDate: '1948-12-31' },
        ],
      },
    },
    sanitaires: {}, observations: {
      observationEquipements: 'Observation sanitaire longue. '.repeat(180),
      projetSouhaitUsage: 'Projet détaillé de la personne. '.repeat(110),
      resumePreconisations: 'Préconisation détaillée. '.repeat(350),
    },
    contexteNotes: [
      { tabKey: 'Bénéficiaire-Notes', textContent: 'SECRET HORS RAPPORT' },
      { tabKey: 'Contexte de vie-Médical', textContent: longNote },
    ],
    fetchImageBytes: async () => null,
  });
  assert.equal(stats.occupantDetailsPages, 1);
  assert.ok(stats.noteContinuationPages >= 4);
  const pdf = await PDFDocument.load(bytes);
  assert.ok(pdf.getPageCount() >= 3 + stats.occupantDetailsPages + stats.noteContinuationPages);

  const extracted = spawnSync('pdftotext', ['-layout', '-', '-'], {
    input: Buffer.from(bytes), encoding: 'utf8', maxBuffer: 5_000_000,
  });
  if (extracted.error?.code === 'ENOENT') {
    t.diagnostic('pdftotext absent: vérification textuelle ignorée');
    return;
  }
  assert.equal(extracted.status, 0, extracted.stderr);
  assert.match(extracted.stdout, /Mme EXEMPLE Anne né\(e\) le 01\/02\/1950/);
  assert.match(extracted.stdout, /Situation familiale : Pacsé\(e\)/);
  assert.match(extracted.stdout, /nom de jeune fille : MARTIN/);
  assert.match(extracted.stdout, /Détails APA : Accompagnement quotidien/);
  assert.match(extracted.stdout, /Détails invalidité : Reconnaissance permanente/);
  assert.match(extracted.stdout, /M\. EXEMPLE Paul né\(e\) le 31\/12\/1948/);
  assert.match(extracted.stdout, /Suite - Environnement/);
  assert.match(extracted.stdout, /Suite - Observations sanitaires/);
  assert.match(extracted.stdout, /Suite - Projet de l'usager/);
  assert.match(extracted.stdout, /Suite - Résumé des préconisations/);
  assert.doesNotMatch(extracted.stdout, /SECRET HORS RAPPORT/);
});

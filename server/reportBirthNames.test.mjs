import assert from 'node:assert/strict';
import test from 'node:test';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { PDFDocument, StandardFonts } from 'pdf-lib';
import { drawBeneficiaryOccupants } from './reports/adaptiveReportLayout.mjs';
import { generateVisitReport } from './reports/generateVisitReport.mjs';

async function draw(occupants) {
  const doc = await PDFDocument.create();
  const page = doc.addPage([595.44, 841.92]);
  const texts = [];
  const original = page.drawText.bind(page);
  page.drawText = (value, options) => { texts.push({ value, ...options }); return original(value, options); };
  const patient = { numberPeople: occupants.length, occupants };
  const before = structuredClone(patient);
  const details = await drawBeneficiaryOccupants(doc, page, patient, { homeHelpDisplay: 'Non' });
  assert.deepEqual(patient, before);
  return { doc, texts, details };
}

for (const maidenName of [undefined, null, '', '  \t\n ']) {
  test(`an empty birth name (${JSON.stringify(maidenName)}) adds no birth label or blank row`, async () => {
    const { texts } = await draw([
      { lastName: 'Durand', firstName: 'Alice', maidenName },
      { lastName: 'Petit', firstName: 'Paul' },
    ]);
    assert(!texts.some(t => /^née?\b/u.test(t.value)));
    assert.equal(texts.find(t => t.value === 'Occupant 1').y, 744);
    assert.equal(texts.find(t => t.value === 'Occupant 2').y, 725);
  });
}

test('three birth names sit below each surname and push following occupants down without touching statuses', async () => {
  const { texts } = await draw([
    { lastName: 'Durand', maidenName: '  Martin  ', firstName: 'Alice', gender: 'Femme' },
    { lastName: 'Petit', maidenName: 'Bernard', firstName: 'Paul', gender: 'Homme' },
    { lastName: 'Moreau', maidenName: 'Robert', firstName: 'Claire' },
  ]);
  for (const [i, label] of ['née MARTIN', 'né BERNARD', 'née ROBERT'].entries()) {
    const identity = texts.find(t => t.value === `Occupant ${i + 1}`);
    const birth = texts.find(t => t.value === label);
    assert.equal(birth.y, identity.y - 11);
    assert.equal(birth.size, 8);
    if (i < 2) assert(texts.find(t => t.value === `Occupant ${i + 2}`).y < birth.y - 8);
  }
  const lastBirth = texts.find(t => t.value === 'née ROBERT');
  const status = texts.find(t => t.value === 'Célibataire');
  assert(lastBirth.y - lastBirth.size > status.y);
});

test('long surnames remain inside their column and are preserved in the continuation', async () => {
  const lastName = 'DUPONT DES LONGUES TERRES DE LA VALLÉE';
  const maidenName = 'MARTIN DE LA GRANDE MAISON AUX CHAMPS';
  const { doc, texts, details } = await draw(Array.from({ length: 3 }, () => ({ lastName, maidenName })));
  assert(details.includes(lastName));
  assert(details.includes(`née ${maidenName}`));
  const font = await doc.embedFont(StandardFonts.Helvetica);
  const surnameLines = texts.filter(t => t.x >= 107 && t.x < 218 && t.y >= 673 && t.y <= 744);
  assert.equal(surnameLines.length, 6);
  for (const line of surnameLines) {
    assert(line.value.endsWith('…'));
    assert(line.x + font.widthOfTextAtSize(line.value, line.size) <= 218.01);
  }
});

test('ERGO and TECHNICIAN PDFs include birth names and retain complete long values in continuation', async () => {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'birth-names-'));
  try {
    for (const role of ['ERGOTHERAPIST', 'TECHNICIAN']) {
      const maidenName = 'MARTIN DES LONGUES TERRES ET DES GRANDES VALLÉES';
      const { bytes } = await generateVisitReport({
        dossier: { patient: { numberPeople: 3, occupants: [
          { lastName: 'Durand', firstName: 'Alice', maidenName: 'Martin' },
          { lastName: 'Petit', firstName: 'Paul' },
          { lastName: 'Moreau', firstName: 'Claire', maidenName },
        ] }, housing: {} },
        ergoProfile: { role }, fetchImageBytes: async () => null,
      });
      const file = path.join(directory, `${role}.pdf`);
      await fs.writeFile(file, bytes);
      const text = execFileSync('pdftotext', ['-raw', file, '-'], { encoding: 'utf8' });
      assert(text.includes('née MARTIN'));
      assert(text.includes('Occupant 3'));
      assert(text.replace(/\s+/g, ' ').includes(`née ${maidenName}`));
      assert(text.includes('Renseignements sur les occupants (suite)'));
    }
  } finally {
    await fs.rm(directory, { recursive: true, force: true });
  }
});

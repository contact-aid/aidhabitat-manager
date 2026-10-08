// Local synthetic preview: apply the integration patch only to a disposable copy.
import fs from 'node:fs/promises';
import path from 'node:path';
import { PDFDocument } from 'pdf-lib';
import { mobilityPdfSandbox } from './mobility-pdf-sandbox.mjs';
const { generateVisitReport, dispose } = await mobilityPdfSandbox();

const output = path.resolve('output/pdf/mobility');
await fs.mkdir(output, { recursive: true });
const cases = [
  ['aides-multiples', 'Canne, Déambulateur, Fauteuil roulant, Canne', '35000'],
  ['aides-inconnues-morbihan', 'Canne, Déambulateur, Fauteuil roulant, Orthèse de marche personnalisée avec assistance spécifique', '56000'],
];
for (const [name, dependenceTxt, zipCode] of cases) {
  const { bytes, stats } = await generateVisitReport({
    dossier: { id: `synthetic-${name}`, patient: {
      firstName: 'Anne', lastName: 'EXEMPLE FICTIF', zipCode, dependenceTxt,
      occupants: [
        { firstName: 'Anne', gender: 'Femme', birthDate: '1950-02-01' },
        { firstName: 'Marie', gender: 'Femme', birthDate: '1952-03-04' },
      ],
    } },
    ergoProfile: { role: 'ERGO', displayName: 'INTERVENANT FICTIF' },
    sanitaires: {}, observations: {}, fetchImageBytes: async () => null,
    flatten: true,
  });
  const pdfDoc = await PDFDocument.load(bytes);
  const file = path.join(output, `${name}.pdf`);
  await fs.writeFile(file, await pdfDoc.save());
  console.log(JSON.stringify({ file, mobilityText: dependenceTxt,
    morbihanPage: stats.morbihanWorksPageAdded, pages: pdfDoc.getPageCount() }));
}

await dispose();

import fs from 'node:fs/promises';
import path from 'node:path';
import { generateVisitReport } from '../server/reports/generateVisitReport.mjs';

const result = await generateVisitReport({
  dossier: { id: 'synthetic-technician-preview', visitDate: '2026-09-17',
    patient: { id: 'synthetic-beneficiary', firstName: 'Camille', lastName: 'EXEMPLE',
      birthDate: '1958-03-12', address: '12 rue Exemple', zipCode: '35131', city: 'Chartres-de-Bretagne' },
    housing: { address: '12 rue Exemple', zipCode: '35131', city: 'Chartres-de-Bretagne' } },
  sanitaires: {}, observations: {
    projetSouhaitUsage: 'Conserver un usage autonome de la salle de bain.',
    resumePreconisations: 'Adapter la douche et faciliter les déplacements dans le logement.' },
  ergoProfile: { role: 'TECHNICIAN', displayName: 'Fabien CRIBIER', email: 'f.cribier@aidhabitat.fr', establishmentLabel: "Aid'Habitat" },
  fetchImageBytes: async () => null,
});
const target = path.resolve('output/pdf/rapport-technicien-exemple.pdf');
await fs.mkdir(path.dirname(target), { recursive: true });
await fs.writeFile(target, result.bytes);
console.log(JSON.stringify({ target, stats: result.stats }));

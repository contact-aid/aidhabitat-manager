import fs from 'node:fs/promises';
import { PDFDocument } from 'pdf-lib';

const APPENDIX_URL = new URL('../templates/visitReport.morbihan-eligible-works.pdf', import.meta.url);

// Use the structured postal code, never a street number or a city-name guess.
export function needsMorbihanEligibleWorks(dossier) {
  return /^56\d{3}$/.test(String(dossier?.patient?.zipCode ?? '').trim());
}

export async function insertMorbihanEligibleWorks(pdfDoc, beforePageIndex) {
  if (!Number.isInteger(beforePageIndex) || beforePageIndex < 0 || beforePageIndex >= pdfDoc.getPageCount()) {
    throw new Error('Emplacement de la page travaux Morbihan introuvable dans le rapport');
  }
  const source = await PDFDocument.load(await fs.readFile(APPENDIX_URL));
  if (source.getPageCount() !== 1 || source.getForm().getFields().length !== 0) {
    throw new Error('La liste des travaux Morbihan doit contenir une page statique');
  }
  // Copy the supplied page without rasterizing or retyping its contents.
  const [page] = await pdfDoc.copyPages(source, [0]);
  pdfDoc.insertPage(beforePageIndex, page);
}

import { StandardFonts, rgb } from 'pdf-lib';
import { printableMobilityAidsForReport } from './mobilityAids.mjs';

export const REPORT_ORANGE = rgb(237 / 255, 152 / 255, 68 / 255);
const black = rgb(0, 0, 0);
const white = rgb(1, 1, 1);

function printable(text, font) {
  return [...String(text ?? '')].map(char => {
    if (char === '\n' || char === '\r') return char;
    try { font.encodeText(char); return char; }
    catch { return `[U+${char.codePointAt(0).toString(16).toUpperCase()}]`; }
  }).join('');
}

// Measure rendered glyphs rather than a character quota. Preserve paragraph
// boundaries and split an exceptionally long word so it cannot cross a border.
export function wrapReportLines(text, font, size, width) {
  if (!(width > 0 && size > 0)) throw new TypeError('Invalid text geometry');
  const lines = [];
  for (const paragraph of printable(text, font).replace(/\r\n?/g, '\n').split('\n')) {
    let current = '';
    for (const word of paragraph.split(/\s+/u).filter(Boolean)) {
      const candidate = current ? `${current} ${word}` : word;
      if (font.widthOfTextAtSize(candidate, size) <= width) { current = candidate; continue; }
      if (current) lines.push(current);
      current = '';
      for (const char of word) {
        if (current && font.widthOfTextAtSize(current + char, size) > width) {
          lines.push(current); current = '';
        }
        current += char;
      }
    }
    lines.push(current);
  }
  return lines;
}

export function drawReportFrame(page, title, font, { bottom = 42.4, top = 793 } = {}) {
  const x = 31.1;
  const width = page.getWidth() - x - 31.2;
  page.drawRectangle({ x, y: bottom, width, height: top - bottom, borderWidth: 0.55, borderColor: REPORT_ORANGE });
  const label = printable(title, font);
  const textWidth = font.widthOfTextAtSize(label, 13);
  page.drawRectangle({ x: 38, y: top - 7, width: textWidth + 12, height: 17, color: white });
  page.drawText(label, { x: 42, y: top - 5, size: 13, font, color: black });
}

// Apply after page deletions on the canonical document. Each flow owns a page
// object, so inserting earlier continuations cannot invalidate later anchors.
export async function drawPaginatedReportText(pdfDoc, { page, text, title, x = 42, width = 510, yTop, bottom = 54, size = 11, lineHeight = 13.5 }) {
  const font = await pdfDoc.embedFont(StandardFonts.Helvetica);
  const bold = await pdfDoc.embedFont(StandardFonts.HelveticaBold);
  const lines = wrapReportLines(text, font, size, width);
  let capacity = Math.floor((yTop - size - bottom) / lineHeight) + 1;
  if (capacity < 1) throw new Error('Text area cannot hold a line');
  let offset = 0;
  let current = page;
  let added = 0;
  let top = yTop;
  while (offset < lines.length) {
    const count = Math.min(capacity, lines.length - offset);
    for (let i = 0; i < count; i++) {
      if (lines[offset + i]) current.drawText(lines[offset + i], {
        x, y: top - size - i * lineHeight, size, font, color: black,
      });
    }
    offset += count;
    if (offset >= lines.length) break;
    const index = pdfDoc.getPages().findIndex(p => p.ref === current.ref);
    current = pdfDoc.insertPage(index + 1, [page.getWidth(), page.getHeight()]);
    drawReportFrame(current, `${title} (suite)`, bold);
    top = 775;
    capacity = Math.floor((top - size - bottom) / lineHeight) + 1;
    added++;
  }
  return { addedPages: added, lines: lines.length, firstPageCapacity: Math.floor((yTop - size - bottom) / lineHeight) + 1 };
}

export function reportOccupants(patient = {}) {
  const stored = Array.isArray(patient.occupants) ? patient.occupants : [];
  const countValue = Number(patient.numberPeople);
  const count = Math.min(3, Math.max(1, Number.isInteger(countValue) && countValue > 0 ? countValue : stored.length || (patient.secondFirstName || patient.secondLastName ? 2 : 1)));
  return Array.from({ length: count }, (_, index) => {
    const fallback = index === 0 ? {
      firstName: patient.firstName, lastName: patient.lastName,
      birthDate: patient.birthDate ?? patient.birthDateMr,
      dependenceTxt: patient.dependenceTxt,
    } : index === 1 ? {
      firstName: patient.secondFirstName, lastName: patient.secondLastName,
      birthDate: patient.birthDateMme,
    } : {};
    // An explicitly empty occupant field is authoritative.
    return { ...fallback, ...(stored[index] ?? {}) };
  });
}

export async function drawBeneficiaryOccupants(pdfDoc, page, patient, view, { primaryMobilityAppendix = false } = {}) {
  const regular = await pdfDoc.embedFont(StandardFonts.Helvetica);
  const bold = await pdfDoc.embedFont(StandardFonts.HelveticaBold);
  // Replace only the beneficiary frame, keeping all following blocks fixed.
  page.drawRectangle({ x: 29, y: 516, width: 538, height: 292, color: white });
  drawReportFrame(page, 'Renseignements sur le bénéficiaire', bold, { bottom: 517.5, top: 793.8 });
  const occupants = reportOccupants(patient);
  const columns = [
    { x: 42, width: 61, label: '' },
    { x: 107, width: 111, label: 'Nom' },
    { x: 223, width: 107, label: 'Prénom' },
    { x: 335, width: 91, label: 'Date de naissance' },
    { x: 431, width: 124, label: 'Dépendance' },
  ];
  for (const col of columns) if (col.label) page.drawText(col.label, { x: col.x, y: 765, size: 9, font: bold });
  let y = 744;
  const details = [];
  for (const [index, occupant] of occupants.entries()) {
    const iso = String(occupant.birthDate ?? '');
    const date = /^(\d{4})-(\d{2})-(\d{2})/.exec(iso);
    const values = [`Occupant ${index + 1}`, occupant.lastName ?? '', occupant.firstName ?? '', date ? `${date[3]}/${date[2]}/${date[1]}` : iso,
      printableMobilityAidsForReport(occupant.dependenceTxt, regular)];
    const cells = values.map((value, i) => wrapReportLines(value, regular, 9, columns[i].width));
    const rowLines = Math.min(2, Math.max(...cells.map(cell => cell.length)));
    if (cells.some((cell, col) => cell.length > 2 && !(index === 0 && col === 4 && primaryMobilityAppendix))) details.push(values.join(' | '));
    for (const [i, lines] of cells.entries()) {
      for (const [line, value] of (lines.length > 2 ? [lines[0], index === 0 && i === 4 && primaryMobilityAppendix ? 'Voir annexe mobilité' : 'Voir suite'] : lines).entries()) if (value) page.drawText(value, {
        x: columns[i].x, y: y - line * 11, size: 9, font: i === 0 ? bold : regular,
      });
    }
    y -= rowLines * 11 + 8;

  }
  // At most three ordinary occupant rows leave ample room for all statuses.
  // A long dependency remains readable in a dedicated continuation rather
  // than consuming the lower labels or silently truncating its source value.
  y = 660;
  function text(value, baseline = y) { page.drawText(printable(value, regular), { x: 42, y: baseline, size: 10, font: regular }); }
  function options(items, selected) {
    let x = 42;
    for (const [label, key] of items) {
      const labelWidth = regular.widthOfTextAtSize(label, 10);
      page.drawText(label, { x, y, size: 10, font: regular });
      const boxX = x + labelWidth + 8;
      page.drawRectangle({ x: boxX, y: y - 1, width: 9, height: 9, borderWidth: .5, borderColor: black });
      if (selected === key) {
        page.drawLine({ start: { x: boxX + 1, y: y + 3 }, end: { x: boxX + 4, y: y }, thickness: 1 });
        page.drawLine({ start: { x: boxX + 4, y: y }, end: { x: boxX + 8, y: y + 7 }, thickness: 1 });
      }
      x = boxX + 24;
    }
  }
  options([['Célibataire', 'Célibataire'], ['En concubinage', 'En concubinage'], ['Marié(e)', 'Mariée'], ['Veuf(ve)', 'Veufve'], ['Divorcé(e)', 'Divorcée']], view.familySituationNormalized);
  y -= 22; text('Statut d’occupation :');
  y -= 20; options([['Propriétaire', 'Propriétaire'], ['Locataire', 'Locataire'], ['Usufruitier(e)', 'Usufruitiere']], view.occupationStatusNormalized);
  y -= 22; text(`Bénéficiaire APA : ${view.apaLabel}${view.apaLabel === 'Oui' && view.apaGirRaw ? ` (GIR ${view.apaGirRaw})` : ''}`);
  y -= 22; text(`Reconnaissance d’invalidité MDPH : ${view.invalidityDisplay}`);
  y -= 22;
  const helpLines = wrapReportLines(`Aide à domicile : ${view.homeHelpDisplay}`, regular, 10, 510);
  if (helpLines.length > 2) details.push(`Aide à domicile : ${view.homeHelpDisplay}`);
  for (const [i, line] of (helpLines.length > 2 ? [helpLines[0], 'Voir suite'] : helpLines).entries()) text(line, y - i * 12);
  return details.join('\n\n');
}

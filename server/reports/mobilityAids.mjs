import { rgb } from 'pdf-lib';

// Display only: never use this formatter to rewrite the stored dependenceTxt.
// Only exact items are deduplicated; a free-text item containing "canne" is
// not replaced by Canne and is never discarded as an unknown value.
export function formatMobilityAidsForReport(raw) {
  const items = String(raw ?? '').split(/[,;\r\n]+/u).map((item) => item.trim()).filter(Boolean);
  const seen = new Set();
  const result = [];
  for (const item of items) {
    const key = item.normalize('NFC').toLocaleLowerCase('fr');
    const absence = ['aucun', 'aucune', 'non'].includes(key);
    const dedupKey = absence ? 'aucune' : key;
    if (seen.has(dedupKey)) continue;
    seen.add(dedupKey);
    result.push(absence ? 'Aucune' : item);
  }
  return result.join(', ');
}

// Preserve the identity of unsupported glyphs in print instead of crashing the
// whole report or silently deleting characters. Source data is unchanged.
export function printableMobilityAidsForReport(raw, font) {
  return [...formatMobilityAidsForReport(raw)].map(char => {
    try { font.encodeText(char); return char; }
    catch { return `[U+${char.codePointAt(0).toString(16).toUpperCase()}]`; }
  }).join('');
}

function wrapText(text, font, size, width) {
  const lines = [];
  let current = '';
  for (const word of text.split(/\s+/u)) {
    const combined = current ? `${current} ${word}` : word;
    if (font.widthOfTextAtSize(combined, size) <= width) {
      current = combined;
      continue;
    }
    if (current) lines.push(current);
    current = '';
    for (const character of word) {
      if (current && font.widthOfTextAtSize(current + character, size) > width) {
        lines.push(current);
        current = '';
      }
      current += character;
    }
  }
  if (current) lines.push(current);
  return lines;
}

/**
 * Call after the generator's global updateFieldAppearances, before flatten.
 * Existing report pages, birth fields and Morbihan appendix are not modified.
 * A long list is printed in full on an additional page instead of clipped or
 * reduced below a readable 8.5 pt in the existing narrow dependence field.
 */
export function applyMobilityAidsToReport({ pdfDoc, field, font, rawValue }) {
  const text = printableMobilityAidsForReport(rawValue, font);
  const widgets = field.acroField.getWidgets();
  const width = Math.min(...widgets.map((widget) => widget.getRectangle().width)) - 8;
  if (!Number.isFinite(width) || width <= 0) throw new Error('Mobility field has no usable widget');
  field.removeMaxLength();
  const normalSize = 9.5;
  const minimumSize = 8.5;
  const textWidth = font.widthOfTextAtSize(text, normalSize);
  const fitSize = textWidth ? Math.min(normalSize, normalSize * width / textWidth) : normalSize;
  let addedPages = 0;
  if (fitSize >= minimumSize) {
    field.setText(text);
    field.setFontSize(fitSize);
  } else {
    const reference = 'Voir annexe aides à la mobilité';
    field.setText(reference);
    field.setFontSize(minimumSize);
    if (font.widthOfTextAtSize(reference, minimumSize) > width) {
      throw new Error('Mobility appendix reference does not fit the field');
    }
    const { width: pageWidth, height: pageHeight } = pdfDoc.getPage(0).getSize();
    const margin = 42;
    const lines = wrapText(text, font, 11, pageWidth - margin * 2);
    const linesPerPage = Math.floor((pageHeight - margin * 2 - 48) / 16);
    if (linesPerPage < 1) throw new Error('Mobility appendix page is too small');
    for (let offset = 0; offset < lines.length; offset += linesPerPage) {
      const page = pdfDoc.addPage([pageWidth, pageHeight]);
      addedPages++;
      page.drawText('Annexe - Aides à la mobilité', {
        x: margin, y: pageHeight - margin - 18, size: 16, font, color: rgb(0, 0, 0),
      });
      lines.slice(offset, offset + linesPerPage).forEach((line, index) => {
        page.drawText(line, {
          x: margin, y: pageHeight - margin - 52 - index * 16,
          size: 11, font, color: rgb(0, 0, 0),
        });
      });
    }
  }
  field.updateAppearances(font);
  return { text, addedPages };
}

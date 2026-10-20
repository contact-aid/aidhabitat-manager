// Shared written notes are mirrored on each handwritten page. Keep distinct
// legacy page texts, but print each complete written note only once.
export function joinReportNotePagesText(pages) {
  const seen = new Set();
  return (Array.isArray(pages) ? pages : [])
    .filter(Boolean)
    .slice()
    .sort((a, b) => Number(a.pageNumber) - Number(b.pageNumber))
    .map(page => {
      try {
        const drawing = JSON.parse(String(page.drawingJson || '{}'));
        if (drawing?.deleted === true) return '';
        if (typeof drawing?.text === 'string' && drawing.text.trim()) {
          return drawing.text.trim();
        }
      } catch { /* Legacy pages may store textContent without valid JSON. */ }
      return String(page.textContent || '').trim();
    })
    .filter(text => {
      if (!text) return false;
      const key = text.replace(/\s+/g, ' ').trim().toLowerCase();
      if (seen.has(key)) return false;
      seen.add(key);
      return true;
    })
    .join('\n\n');
}

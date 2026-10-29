import { joinReportNotePagesText } from './noteText.mjs';

export const CONTEXT_TEXT_INITIALIZED = 'contextTextV2Initialized';
const environmentKey = 'Bénéficiaire-Notes';
const habitsKey = 'Contexte de vie-Habitudes';

export function contextNotesForReport(pages = []) {
  const text = (canonicalKey, legacyKeys) => {
    const canonical = pages.filter(p => p?.tabKey === canonicalKey);
    const zero = canonical.find(p => Number(p.pageNumber) === 0);
    try {
      const drawing = JSON.parse(zero?.drawingJson || '{}');
      if (drawing[CONTEXT_TEXT_INITIALIZED] === true) {
        return drawing.deleted === true ? '' : String(drawing.text || '').trim();
      }
    } catch { /* Preserve legacy text-only pages. */ }
    // Source priority is stable; original page numbers/drawings are untouched.
    const sources = legacyKeys.flatMap(key => pages.filter(p => p?.tabKey === key)
      .sort((a, b) => Number(a.pageNumber) - Number(b.pageNumber)));
    return joinReportNotePagesText(sources.map((p, i) => {
      let textContent = p.textContent;
      try {
        const drawing = JSON.parse(p.drawingJson || '{}');
        if (drawing.noteTextInitialized === true && Object.hasOwn(drawing, 'text')) {
          textContent = String(drawing.text || '');
        }
      } catch { /* Legacy text-only note. */ }
      return { ...p, textContent, pageNumber: i };
    }));
  };
  return {
    environnement: text(environmentKey, [environmentKey, 'Contexte de vie-Médical']),
    habitudes: text(habitsKey, ['Contexte de vie-Autonomie']),
  };
}

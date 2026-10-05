import crypto from 'node:crypto';

export const DOSSIER_NOTE = 'notes_rapides';
export const BENEFICIARY_NOTE = 'Bénéficiaire-Notes';
export const isIndependentNote = (tabKey) =>
  tabKey === DOSSIER_NOTE || tabKey === BENEFICIARY_NOTE;
const plain = (value) => String(value ?? '').trim();

export function readNoteDrawing(raw) {
  const drawing = plain(raw) ? JSON.parse(raw) : { version: 1, text: '', strokes: [] };
  if (!drawing || typeof drawing !== 'object' || Array.isArray(drawing)) {
    throw new TypeError('dessin de note illisible');
  }
  return drawing;
}

// Kept server-side: build 64 rebuilds drawing_json when saving and does not
// retain unknown properties. Every real save (including a clear) establishes
// initialization; opening/reading a note never does. No NocoDB schema change.
export function stampNoteInitialization({ tabKey, pageNumber, drawingJson }) {
  if (!isIndependentNote(tabKey) || Number(pageNumber) !== 0) return drawingJson;
  return JSON.stringify({ ...readNoteDrawing(drawingJson), noteTextInitialized: true });
}

const textOf = (page) => {
  const drawing = readNoteDrawing(page?.drawingJson);
  // A stored explicit empty text with our marker is an intentional blank.
  if (drawing.noteTextInitialized === true && typeof drawing.text === 'string') {
    return drawing.text;
  }
  return plain(drawing.text) ? drawing.text : String(page?.textContent ?? '');
};

const stableId = (patientId, dossierId, tabKey) => {
  const hex = crypto.createHash('sha256')
    .update(JSON.stringify(['independent-notes-v1', patientId, dossierId, tabKey])).digest('hex');
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-5${hex.slice(13, 16)}-a${hex.slice(17, 20)}-${hex.slice(20, 32)}`;
};

// Pure plan, also usable for a reviewed initialization of existing dossiers
// outside the current Airtable import period. Never opens a database.
export function planIndependentNotes({ pages, patientId, dossierId, initialText = '', metadata = {} }) {
  const groups = new Map();
  for (const tabKey of [DOSSIER_NOTE, BENEFICIARY_NOTE]) {
    const candidates = pages.filter((page) => page.tabKey === tabKey && !plain(page.subTabKey));
    // Never resolve conflicting scopes/duplicates by picking a winner: there
    // may be an iPad text or drawing in either row. Require review instead.
    for (const page of candidates) {
      if ((page.dossierId && page.dossierId !== dossierId)
          || (page.scopeId && page.scopeId !== dossierId)
          || (page.scopeType && page.scopeType !== 'dossier_detail')) {
        throw new Error('plusieurs dossiers ou portées de note : revue requise');
      }
      readNoteDrawing(page.drawingJson);
    }
    if (new Set(candidates.map((p) => Number(p.pageNumber))).size !== candidates.length) {
      throw new Error('pages de note en doublon : revue requise');
    }
    groups.set(tabKey, candidates);
  }
  const operations = [];
  const initialize = (tabKey, seed) => {
    const group = groups.get(tabKey);
    const page = group.find((p) => Number(p.pageNumber) === 0);
    const drawing = readNoteDrawing(page?.drawingJson);
    if (drawing.noteTextInitialized === true || plain(textOf(page))) return textOf(page);
    // A note with text on a later page is not empty. Preserve every page.
    const laterTexts = [...new Set(group.map(textOf).filter(plain))];
    if (tabKey === BENEFICIARY_NOTE && laterTexts.length) return textOf(page);
    if (laterTexts.length > 1) throw new Error('textes dossier divergents : revue requise');
    const text = laterTexts[0] ?? seed;
    if (page && !plain(page.revision)) throw new Error('révision de note absente');
    operations.push({
      ...metadata, notePageId: page?.id ?? stableId(patientId, dossierId, tabKey),
      patientId, dossierId, tabKey,
      scopeType: page?.scopeType || 'dossier_detail',
      scopeId: page?.scopeId || dossierId, subTabKey: '', pageNumber: 0,
      textContent: text,
      drawingJson: stampNoteInitialization({ tabKey, pageNumber: 0,
        drawingJson: JSON.stringify({ ...drawing, text }) }),
      previewDataUrl: page?.previewDataUrl ?? '', layoutKind: page?.layoutKind ?? 'freeform',
      planPhase: page?.planPhase ?? null,
      expectedRevision: page?.revision ?? null, writeId: crypto.randomUUID(),
      // Initialization must never use the normal prefer-local conflict policy.
      initializationOnly: true,
    });
    return text;
  };
  const dossierText = initialize(DOSSIER_NOTE, String(initialText ?? ''));
  initialize(BENEFICIARY_NOTE, dossierText);
  return operations;
}

const parseOptionalFiniteNumber = raw => raw !== null && raw !== undefined && raw !== '' && Number.isFinite(Number(raw)) ? Number(raw) : null;

// Flutter scopes imported document identities to the patient. Dart's
// base64Url.encode retains padding, unlike Node's base64url encoding.
export function reportDocumentAliases(doc, patientId) {
  const encode = value => Buffer.from(String(value)).toString('base64').replaceAll('+', '-').replaceAll('/', '_');
  const identities = [doc.id, doc.clientDocumentId].filter(Boolean).map(String);
  return identities.flatMap(id => [id, `remote_doc_${id}`,
    ...(patientId ? [`remote_doc_${encode(patientId)}_${encode(id)}`] : [])]);
}

export const mergeInlineDocuments = (remoteDocs, inlineMap, orderMap = new Map(), patientId = '') => {
  const visitTagsNormalized = new Set([
    'visite - logement',
    'visite - accessibilite',
    'visite - sanitaires',
  ]);
  const normalizeTag = (s) => String(s || '')
    .toLowerCase()
    .normalize('NFD')
    .replace(/[̀-ͯ]/g, '')
    .replace(/\s+/g, ' ')
    .trim();
  const hasVisitTag = (tags) =>
    Array.isArray(tags) && tags.some((tag) => {
      const tn = normalizeTag(tag);
      if (visitTagsNormalized.has(tn)) return true;
      const match = tn.match(/^(.+) \(#\d+\)$/);
      return Boolean(match && visitTagsNormalized.has(match[1]));
    });

  const merged = [];
  const seenIds = new Set();
  const seenClientIds = new Set();
  // 1) inline d'abord (priorité), filtrés par tag visite
  for (const inline of inlineMap.values()) {
    if (!hasVisitTag(inline.tags)) continue;
    merged.push({
      id: inline.id,
      clientDocumentId: inline.clientDocumentId || inline.id,
      title: inline.title || '',
      fileName: inline.fileName,
      mimeType: inline.mimeType,
      tags: inline.tags,
      categoryOrder: orderMap.get(String(inline.id))
        ?? parseOptionalFiniteNumber(inline.categoryOrder)
        ?? null,
      dossierId: inline.dossierId,
    });
    seenIds.add(String(inline.id));
    seenClientIds.add(String(inline.clientDocumentId || inline.id));
  }
  // 2) puis les remotes pas en doublon
  for (const doc of Array.isArray(remoteDocs) ? remoteDocs : []) {
    if (!doc) continue;
    if (seenIds.has(String(doc.id))) continue;
    const cid = String(doc.clientDocumentId || '');
    if (cid && seenClientIds.has(cid)) continue;
    const localOrder = reportDocumentAliases(doc, patientId)
      .map(id => orderMap.get(id)).find(value => value !== undefined);
    merged.push({
      ...doc,
      categoryOrder: localOrder ?? parseOptionalFiniteNumber(doc.categoryOrder),
    });
  }
  return merged;
};


import { createHash, randomUUID } from 'node:crypto';
import { gzipSync } from 'node:zlib';

const safeId = (value) => typeof value === 'string' && /^[\w:.-]{1,160}$/.test(value) ? value : null;
export const safeNoteErrorCode = (value) => typeof value === 'string' && /^[A-Z][A-Z0-9_]{1,95}$/.test(value) ? value : 'NOTE_PAGE_SERVER_ERROR';
export function noteSyncMetadata(body = {}) {
  const drawing = typeof body.drawingJson === 'string' ? body.drawingJson : '';
  const bytes = Buffer.from(drawing, 'utf8');
  return {
    writeId: safeId(body.writeId), notePageId: safeId(body.notePageId),
    patientId: safeId(body.patientId), scopeId: safeId(body.scopeId),
    // No free-text labels, note text, preview or authentication material in logs.
    identitySha256: createHash('sha256').update(JSON.stringify([
      body.patientId, body.scopeType, body.scopeId, body.tabKey, body.subTabKey || '', body.pageNumber,
    ])).digest('hex'),
    pageNumber: Number.isInteger(body.pageNumber) ? body.pageNumber : null,
    drawingBytes: bytes.length, drawingCharacters: drawing.length,
    drawingSha256: createHash('sha256').update(bytes).digest('hex'),
    storedDrawingCharacters: drawing.length > 80000 ? 5 + gzipSync(bytes).toString('base64').length : drawing.length,
  };
}
export function noteSyncDiagnostics(req, res, next) {
  const requestId = randomUUID();
  res.locals.noteRequestId = requestId;
  res.setHeader('X-Request-Id', requestId);
  const startedAt = new Date().toISOString();
  let metadata;
  try { metadata = noteSyncMetadata(req.body); }
  catch { metadata = { metadataError: 'NOTE_DIAGNOSTIC_UNAVAILABLE' }; }
  res.once('finish', () => console.info('[note-sync]', JSON.stringify({
    requestId, startedAt, finishedAt: new Date().toISOString(), status: res.statusCode,
    code: res.locals.noteErrorCode || null, ...metadata,
  })));
  next();
}

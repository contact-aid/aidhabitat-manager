import { createHash } from 'node:crypto';
import { gzipSync, gunzipSync } from 'node:zlib';

export const NOTE_CONTENT_PREFIX = 'NOTE_CHUNKS_V1:';
export const NOTE_CHUNK_NAMESPACE = 'note-content-v1:';
export const NOTE_CONTENT_MAX_BYTES = 20 * 1024 * 1024;
const CHUNK_SIZE = 90000;
const hash = (value) => createHash('sha256').update(value).digest('hex');
const value = (row, key) => row?.fields?.[key];
const fail = () => {
  const error = new Error('NOTE_PAGE_CONTENT_UNAVAILABLE');
  error.code = error.message;
  error.status = error.statusCode = 503;
  throw error;
};
export const isNoteChunkKey = (key) => String(key).startsWith(NOTE_CHUNK_NAMESPACE);
export const noteContentOwner = (identity, kind) => hash(JSON.stringify([
  identity.patientId, identity.scopeType || 'legacy',
  identity.scopeId || identity.dossierId || identity.patientId,
  identity.tabKey, identity.subTabKey || '', Number(identity.pageNumber), kind,
]));

// Immutable objects: stage and verify before publishing the pointer in a
// conditional note write. No cleanup or deletion is performed here.
export function createNoteContentStore({ tableId, queryAll, createRecord, inlineEncode, inlineDecode }) {
  const list = (key) => queryAll(tableId, {
    fields: ['document_uuid_source', 'chunk_index', 'chunk_base64'],
    where: `(document_uuid_source,eq,${JSON.stringify(key)})`,
  });
  function prepare(rawValue, owner) {
    const raw = String(rawValue ?? '');
    const bytes = Buffer.from(raw, 'utf8');
    if (bytes.length > NOTE_CONTENT_MAX_BYTES) {
      const error = new Error('NOTE_PAGE_CONTENT_TOO_LARGE');
      error.code = error.message; error.status = error.statusCode = 413;
      throw error;
    }
    try {
      const inline = raw.startsWith(NOTE_CONTENT_PREFIX)
        ? 'GZIP:' + gzipSync(bytes).toString('base64') : inlineEncode(raw);
      if (inline.length <= 100000) return { stored: inline };
    } catch (error) {
      if (error.code !== 'NOTE_PAGE_CONTENT_TOO_LARGE') throw error;
    }
    if (!tableId) fail();
    const encoded = gzipSync(bytes).toString('base64');
    const chunks = Array.from({ length: Math.ceil(encoded.length / CHUNK_SIZE) },
      (_, index) => encoded.slice(index * CHUNK_SIZE, (index + 1) * CHUNK_SIZE));
    const manifest = { owner, sha256: hash(bytes), bytes: bytes.length,
      encodedSha256: hash(encoded), encodedLength: encoded.length, count: chunks.length };
    return { stored: NOTE_CONTENT_PREFIX + JSON.stringify(manifest), manifest, chunks };
  }
  function parse(stored, owner) {
    try {
      const m = JSON.parse(stored.slice(NOTE_CONTENT_PREFIX.length));
      if (m.owner !== owner || !/^[a-f0-9]{64}$/.test(m.owner)
        || !/^[a-f0-9]{64}$/.test(m.sha256) || !/^[a-f0-9]{64}$/.test(m.encodedSha256)
        || !Number.isInteger(m.bytes) || m.bytes < 0 || m.bytes > NOTE_CONTENT_MAX_BYTES
        || !Number.isInteger(m.encodedLength) || m.encodedLength < 1
        || m.encodedLength > 2 * NOTE_CONTENT_MAX_BYTES
        || m.count !== Math.ceil(m.encodedLength / CHUNK_SIZE)) fail();
      return m;
    } catch { fail(); }
  }
  const keyFor = (m) => `${NOTE_CHUNK_NAMESPACE}${m.owner}:${m.sha256}`;
  function collect(rows, m, partial = false) {
    const found = new Map();
    for (const row of rows) {
      const index = Number(value(row, 'chunk_index'));
      const data = value(row, 'chunk_base64');
      if (value(row, 'document_uuid_source') !== keyFor(m) || !Number.isInteger(index) || index < 0 || index >= m.count
        || typeof data !== 'string' || data.length !== Math.min(CHUNK_SIZE, m.encodedLength - index * CHUNK_SIZE)
        || !/^[A-Za-z0-9+/]*={0,2}$/.test(data)
        || (found.has(index) && found.get(index) !== data)) fail();
      found.set(index, data); // Identical retry duplicates are harmless.
    }
    if (!partial && found.size !== m.count) fail();
    return found;
  }
  function decode(rows, m, maxBytes = NOTE_CONTENT_MAX_BYTES) {
    if (m.bytes > maxBytes) fail();
    const found = collect(rows, m);
    const encoded = Array.from({ length: m.count }, (_, i) => found.get(i)).join('');
    if (hash(encoded) !== m.encodedSha256) fail();
    try {
      const bytes = gunzipSync(Buffer.from(encoded, 'base64'), { maxOutputLength: Math.max(1, maxBytes) });
      if (bytes.length !== m.bytes || hash(bytes) !== m.sha256) fail();
      return bytes.toString('utf8');
    } catch { fail(); }
  }
  async function read(storedValue, owner, maxBytes = NOTE_CONTENT_MAX_BYTES) {
    const stored = String(storedValue ?? '');
    if (!stored.startsWith(NOTE_CONTENT_PREFIX)) {
      try {
        const bytes = stored.startsWith('GZIP:')
          ? gunzipSync(Buffer.from(stored.slice(5), 'base64'), { maxOutputLength: Math.max(1, maxBytes) })
          : Buffer.from(inlineDecode(stored), 'utf8');
        if (bytes.length > maxBytes) fail();
        return bytes.toString('utf8');
      } catch { fail(); }
    }
    if (!tableId) fail();
    const m = parse(stored, owner);
    if (m.bytes > maxBytes) fail();
    return decode(await list(keyFor(m)), m, maxBytes);
  }
  async function persist(prepared) {
    if (!prepared.manifest) return;
    const m = prepared.manifest;
    const key = keyFor(m);
    const found = collect(await list(key), m, true);
    for (let index = 0; index < m.count; index++) {
      if (found.has(index)) {
        if (found.get(index) !== prepared.chunks[index]) fail();
        continue;
      }
      try {
        await createRecord(tableId, {
          uuid_source: hash(`${key}:${index}`), document_uuid_source: key,
          chunk_index: index, chunk_base64: prepared.chunks[index],
          updated_at: new Date().toISOString(),
        });
      } catch {
        // An ACK can be lost after commit. Confirm the exact fragment before
        // continuing; an unavailable/incomplete read leaves the note untouched.
        const confirmed = collect(await list(key), m, true);
        if (confirmed.get(index) !== prepared.chunks[index]) fail();
      }
    }
    decode(await list(key), m);
  }
  return { prepare, persist, read };
}

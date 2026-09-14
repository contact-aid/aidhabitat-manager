import { isDeepStrictEqual } from 'node:util';

const sourceOf = (record) => record?.fields && typeof record.fields === 'object'
  ? { Id: Number(record.id), ...record.fields }
  : record;

const normalizeForeignKey = (value) => {
  if (value == null || value === '') return null;
  const parsed = Number(value);
  return Number.isSafeInteger(parsed) ? parsed : value;
};

const canonicalWikiFields = (fields = {}) => ({
  uuid_source: String(fields.uuid_source ?? '').trim(),
  titre: String(fields.titre ?? ''),
  photos: String(fields.photos ?? ''),
  photo_base64: String(fields.photo_base64 ?? ''),
  contenu: String(fields.contenu ?? ''),
  wiki_tags_id: normalizeForeignKey(fields.wiki_tags_id),
});

export class WikiPersistenceError extends Error {
  constructor(code, { statusCode = 503, cause } = {}) {
    super(code, cause ? { cause } : undefined);
    this.name = 'WikiPersistenceError';
    this.code = code;
    this.statusCode = statusCode;
  }
}

export const findWikiRecord = (records, itemId) => (records || []).find(
  (record) => String(sourceOf(record)?.uuid_source ?? '').trim() === String(itemId).trim(),
) || null;

export const wikiRecordMatches = (record, expectedFields) => {
  if (!record) return false;
  return isDeepStrictEqual(
    canonicalWikiFields(sourceOf(record)),
    canonicalWikiFields(expectedFields),
  );
};

const readConfirmedRecords = async (readRecords, cause) => {
  try {
    const records = await readRecords();
    if (!Array.isArray(records)) throw new TypeError('Wiki read did not return records');
    return records;
  } catch (confirmationError) {
    throw new WikiPersistenceError('WIKI_PERSISTENCE_UNCONFIRMED', {
      cause: cause || confirmationError,
    });
  }
};

/**
 * Acknowledges only a NocoDB row whose complete persisted payload matches.
 * A create replay returns the existing row. If its durable local operation was
 * edited meanwhile, the same identity updates that row instead of duplicating it.
 */
export async function persistWikiRecord({
  operation,
  itemId,
  fields,
  initialRecords,
  readRecords,
  createRecord,
  updateRecord,
}) {
  if (!['create', 'update'].includes(operation)) {
    throw new TypeError('Unsupported wiki persistence operation');
  }
  if (!String(itemId || '').trim() || typeof readRecords !== 'function'
      || typeof createRecord !== 'function' || typeof updateRecord !== 'function') {
    throw new TypeError('Wiki persistence dependencies are required');
  }

  const expected = canonicalWikiFields({ ...fields, uuid_source: itemId });
  let records = Array.isArray(initialRecords)
    ? initialRecords
    : await readConfirmedRecords(readRecords);
  const existing = findWikiRecord(records, itemId);

  if (operation === 'create' && existing) {
    if (wikiRecordMatches(existing, expected)) {
      return { record: existing, replay: true };
    }
    // A local draft may be edited while a lost create response is waiting for
    // retry. The stable identity still denotes the same draft: update that one
    // row rather than creating a duplicate or rejecting the preserved intent.
  }

  let writeError;
  try {
    if (existing) await updateRecord(existing, expected);
    else await createRecord(expected);
  } catch (error) {
    // A transport error may happen after NocoDB committed. Confirmation below
    // decides the outcome; the write response alone is never an acknowledgement.
    writeError = error;
  }

  records = await readConfirmedRecords(readRecords, writeError);
  const confirmed = findWikiRecord(records, itemId);
  if (!wikiRecordMatches(confirmed, expected)) {
    throw new WikiPersistenceError('WIKI_PERSISTENCE_UNCONFIRMED', {
      cause: writeError,
    });
  }
  return { record: confirmed, replay: false };
}

/** Deletion is successful only after a NocoDB read confirms absence. */
export async function deleteWikiRecord({
  itemId,
  initialRecords,
  readRecords,
  deleteRecord,
}) {
  if (!String(itemId || '').trim() || typeof readRecords !== 'function'
      || typeof deleteRecord !== 'function') {
    throw new TypeError('Wiki deletion dependencies are required');
  }
  let records = Array.isArray(initialRecords)
    ? initialRecords
    : await readConfirmedRecords(readRecords);
  const existing = findWikiRecord(records, itemId);
  if (!existing) return { replay: true };

  let writeError;
  try {
    await deleteRecord(existing);
  } catch (error) {
    writeError = error;
  }
  records = await readConfirmedRecords(readRecords, writeError);
  if (findWikiRecord(records, itemId)) {
    throw new WikiPersistenceError('WIKI_DELETE_UNCONFIRMED', {
      cause: writeError,
    });
  }
  return { replay: false };
}

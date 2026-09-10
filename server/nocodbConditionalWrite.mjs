import { canonicalDatabasePatch, createDatabaseValueComparator } from './nocodbScalarValues.mjs';

const identifier = /^[A-Za-z_][A-Za-z0-9_]*$/;
const columnIdentifier = /^[\p{L}_][\p{L}\p{M}\p{N}_]*$/u;
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const revisionField = 'app_sync_revision';

function requireValue(condition, message) {
  if (!condition) throw new TypeError(message);
}

export class ConditionalWriteUncertainError extends Error {
  constructor(cause) {
    super('Conditional write could not be confirmed; retain the mutation and its writeId', { cause });
    this.name = 'ConditionalWriteUncertainError';
    this.code = 'NOCODB_CONDITIONAL_WRITE_UNCERTAIN';
    this.statusCode = 503;
  }
}

export function validateConditionalPatch(fields, { allowEmpty = false } = {}) {
  requireValue(fields && Object.getPrototypeOf(fields) === Object.prototype &&
    (allowEmpty || Object.keys(fields).length > 0), 'A plain field patch is required');
  for (const [key, value] of Object.entries(fields)) {
    requireValue(columnIdentifier.test(key) &&
      !['Id', 'id', revisionField, '__proto__', 'constructor', 'prototype'].includes(key),
    'Invalid or reserved patch field');
    requireValue(value === null || ['string', 'boolean'].includes(typeof value) ||
      (typeof value === 'number' && Number.isFinite(value)),
    'Patch fields must be scalar database values');
  }
}

export class ConditionalSchemaError extends Error {
  constructor(message) {
    super(message);
    this.name = 'ConditionalSchemaError';
    this.code = 'NOCODB_CONDITIONAL_SCHEMA_UNSUPPORTED';
    this.statusCode = 503;
  }
}

export function validateConditionalSchema(schema, { tableId, baseId }) {
  const check = (condition, message) => { if (!condition) throw new ConditionalSchemaError(message); };
  check(schema?.id === tableId && schema?.base_id === baseId, 'Table identity/base mismatch');
  const columns = Array.isArray(schema.columns) ? schema.columns : [];
  const primary = columns.filter((column) => column.pk);
  check(primary.length === 1 && primary[0].title === 'Id', 'Unsupported primary key');
  const revision = columns.find((column) => column.title === revisionField);
  check(revision?.uidt === 'SingleLineText' && !revision.pk, 'Revision column is not prepared');
  return columns;
}

/**
 * Opt-in transport, not a replacement for the application's existing writes.
 * The caller must authorize access, persist writeId before sending, and ensure
 * ALL writers of these tables maintain app_sync_revision before enabling it.
 * HTTP counts are never acknowledgements. Neither errors nor rejected guards
 * are retried as unconditional writes or via MCP.
 */
export function createConditionalRecordWriter({ baseId, allowedTableIds, request }) {
  requireValue(typeof baseId === 'string' && identifier.test(baseId), 'Invalid base id');
  requireValue(Array.isArray(allowedTableIds) && allowedTableIds.length > 0, 'An explicit table allowlist is required');
  requireValue(allowedTableIds.every((id) => typeof id === 'string' && identifier.test(id)), 'Invalid allowed table id');
  requireValue(typeof request === 'function', 'A REST request adapter is required');
  const tables = new Set(allowedTableIds);

  return async function write({ tableId, recordId, expectedRevision, writeId, fields }) {
    requireValue(tables.has(tableId), 'Table is not enabled for conditional writes');
    requireValue(Number.isSafeInteger(recordId) && recordId > 0, 'Invalid record id');
    requireValue(typeof expectedRevision === 'string' && uuid.test(expectedRevision), 'A known UUID revision is required');
    requireValue(typeof writeId === 'string' && uuid.test(writeId) && writeId !== expectedRevision, 'A distinct stable writeId is required');
    validateConditionalPatch(fields);
    // Detach values before any awaits; callers cannot alter the pending write.
    let patch = { ...fields };
    const schema = await request({ method: 'GET', path: `/api/v2/meta/tables/${tableId}` });
    const columns = validateConditionalSchema(schema, { tableId, baseId });
    for (const key of Object.keys(patch)) {
      const column = columns.find((entry) => entry.title === key);
      const linkedForeignKey = column?.uidt === 'ForeignKey' && columns.some((entry) =>
        entry.uidt === 'LinkToAnotherRecord' && entry.colOptions?.type === 'bt' &&
        entry.colOptions.fk_child_column_id === column.id &&
        entry.colOptions.fk_related_model_id &&
        (!entry.colOptions.fk_related_base_id || entry.colOptions.fk_related_base_id === baseId));
      if (!column || column.pk || (!linkedForeignKey && !['SingleLineText', 'LongText', 'Number', 'Decimal', 'Checkbox', 'Date', 'DateTime', 'Email', 'PhoneNumber', 'URL'].includes(column.uidt))) {
        throw new ConditionalSchemaError('Patch column is missing or not a supported writable scalar');
      }
      if (linkedForeignKey) requireValue(patch[key] === null || (Number.isSafeInteger(patch[key]) && patch[key] > 0), 'A foreign key must be a positive integer or null');
    }
    patch = canonicalDatabasePatch(patch, columns);
    const equals = createDatabaseValueComparator(columns);

    const read = async () => {
      const params = new URLSearchParams({ where: `(Id,eq,${recordId})`, limit: '2', fields: ['Id', revisionField, ...Object.keys(patch)].join(',') });
      const result = await request({ method: 'GET', path: `/api/v2/tables/${tableId}/records?${params}` });
      const rows = Array.isArray(result) ? result : result?.list;
      requireValue(Array.isArray(rows) && rows.length <= 1, 'Read did not isolate one record');
      const row = rows[0] ?? null;
      requireValue(!row || Number(row.Id) === recordId, 'Read returned a different record');
      return row;
    };
    const matchesPatch = (row) => row && Object.entries(patch).every(([key, value]) =>
      Object.hasOwn(row, key) && equals(key, row[key], value));
    const before = await read();
    if (!before) return { status: 'not_confirmed', reason: 'record_missing' };
    if (before[revisionField] === writeId) {
      return matchesPatch(before)
        ? { status: 'applied', revision: writeId, replay: true }
        : { status: 'not_confirmed', reason: 'write_id_mismatch', observed: before };
    }
    if (before[revisionField] !== expectedRevision) {
      return { status: 'not_confirmed', reason: 'revision_changed', observed: before };
    }

    const params = new URLSearchParams({ where: `(Id,eq,${recordId})~and(${revisionField},eq,${expectedRevision})` });
    try {
      await request({
        method: 'PATCH',
        path: `/api/v1/db/data/bulk/noco/${baseId}/${tableId}/all?${params}`,
        body: { ...patch, [revisionField]: writeId },
      });
      const after = await read();
      if (after?.[revisionField] === writeId && matchesPatch(after)) {
        return { status: 'applied', revision: writeId, replay: false };
      }
      // The write may have lost the race OR succeeded before another writer.
      // Do not classify this as definite failure or acknowledge the mutation.
      return { status: 'not_confirmed', reason: 'confirmation_mismatch', observed: after };
    } catch (error) {
      throw new ConditionalWriteUncertainError(error);
    }
  };
}

import { createHash } from 'node:crypto';
import { gzipSync, gunzipSync } from 'node:zlib';

export const VISIT_RECOMMENDATIONS_PROTOCOL_VERSION = 1;
export const VISIT_RECOMMENDATIONS_REVISION_FIELD = 'app_sync_revision';

const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const identifierPattern = /^[A-Za-z_][A-Za-z0-9_]*$/;
const filterValuePattern = /^[A-Za-z0-9:_-]+$/;

const isPlainObject = (value) => (
  value !== null
  && typeof value === 'object'
  && Object.getPrototypeOf(value) === Object.prototype
);

const stringValue = (value) => value == null ? '' : String(value);

const cloneJson = (value) => JSON.parse(JSON.stringify(value));
const compressedItemsPrefix = 'GZIP:';

export const encodeVisitRecommendationsSnapshotItems = (items) => {
  const json = JSON.stringify(items);
  if (json.length <= 80_000) return json;
  return `${compressedItemsPrefix}${gzipSync(Buffer.from(json, 'utf8')).toString('base64')}`;
};

export class VisitRecommendationsPublicationError extends Error {
  constructor(status, code, { observed = null, details = null, cause } = {}) {
    super(code, cause ? { cause } : undefined);
    this.name = 'VisitRecommendationsPublicationError';
    this.status = status;
    this.statusCode = status;
    this.code = code;
    this.observed = observed;
    this.details = details;
  }
}

const fail = (status, code, options) => {
  throw new VisitRecommendationsPublicationError(status, code, options);
};

const canonicalize = (value) => {
  if (Array.isArray(value)) {
    return value.map(canonicalize);
  }
  if (isPlainObject(value)) {
    return Object.fromEntries(
      Object.keys(value)
        .sort()
        .map((key) => [key, canonicalize(value[key])]),
    );
  }
  return value;
};

export const hashVisitRecommendationsRequest = ({ dossierId, items }) => (
  createHash('sha256')
    .update(JSON.stringify(canonicalize({
      dossierId,
      items: items.map((item) => ({
        id: stringValue(item.id).trim(),
        wikiItemId: stringValue(item.wikiItemId).trim(),
        customTitle: stringValue(item.customTitle).trim(),
        note: stringValue(item.note),
        createdAt: stringValue(item.createdAt),
        updatedAt: stringValue(item.updatedAt),
      })),
    })))
    .digest('hex')
);

const normalizeRequestItem = (item) => {
  if (!isPlainObject(item)) {
    fail(400, 'VISIT_RECOMMENDATIONS_ITEM_INVALID');
  }

  const id = stringValue(item.id).trim();
  const wikiItemId = stringValue(item.wikiItemId).trim();
  if (!id) {
    fail(400, 'VISIT_RECOMMENDATIONS_ITEM_ID_REQUIRED');
  }
  if (!wikiItemId) {
    fail(400, 'VISIT_RECOMMENDATIONS_DRAFT_NOT_PUBLISHABLE');
  }
  if (/^local_draft_/i.test(wikiItemId)) {
    fail(409, 'VISIT_RECOMMENDATIONS_WIKI_LINK_LOCAL_DRAFT', {
      details: { wikiItemId },
    });
  }

  return {
    id,
    wikiItemId,
    wikiTitle: stringValue(item.wikiTitle).trim(),
    wikiImageUrl: stringValue(item.wikiImageUrl).trim(),
    wikiTag: stringValue(item.wikiTag).trim(),
    wikiDescription: stringValue(item.wikiDescription),
    customTitle: stringValue(item.customTitle).trim(),
    note: stringValue(item.note),
    createdAt: stringValue(item.createdAt),
    updatedAt: stringValue(item.updatedAt),
  };
};

export const validateVisitRecommendationsEnvelope = ({ dossierId, envelope }) => {
  const normalizedDossierId = stringValue(dossierId).trim();
  if (!normalizedDossierId) {
    fail(400, 'VISIT_RECOMMENDATIONS_DOSSIER_ID_REQUIRED');
  }
  if (!isPlainObject(envelope)) {
    fail(400, 'VISIT_RECOMMENDATIONS_PAYLOAD_INVALID');
  }
  if (envelope.protocolVersion !== VISIT_RECOMMENDATIONS_PROTOCOL_VERSION) {
    fail(400, 'VISIT_RECOMMENDATIONS_PROTOCOL_UNSUPPORTED');
  }

  const writeId = stringValue(envelope.writeId).trim();
  if (!uuidPattern.test(writeId)) {
    fail(428, 'VISIT_RECOMMENDATIONS_WRITE_ID_REQUIRED');
  }

  if (!Object.hasOwn(envelope, 'expectedRevision')) {
    fail(428, 'VISIT_RECOMMENDATIONS_REVISION_REQUIRED');
  }
  const expectedRevision = envelope.expectedRevision == null
    ? null
    : stringValue(envelope.expectedRevision).trim();
  if (expectedRevision !== null && !uuidPattern.test(expectedRevision)) {
    fail(428, 'VISIT_RECOMMENDATIONS_REVISION_REQUIRED');
  }
  if (expectedRevision === writeId) {
    fail(400, 'VISIT_RECOMMENDATIONS_WRITE_ID_MUST_ADVANCE');
  }
  if (!Array.isArray(envelope.items)) {
    fail(400, 'VISIT_RECOMMENDATIONS_ITEMS_REQUIRED');
  }

  const items = envelope.items.map(normalizeRequestItem);
  const ids = new Set();
  for (const item of items) {
    if (ids.has(item.id)) {
      fail(400, 'VISIT_RECOMMENDATIONS_DUPLICATE_ITEM_ID', {
        details: { itemId: item.id },
      });
    }
    ids.add(item.id);
  }

  return {
    dossierId: normalizedDossierId,
    writeId,
    expectedRevision,
    items,
    requestHash: hashVisitRecommendationsRequest({
      dossierId: normalizedDossierId,
      items,
    }),
  };
};

const snapshotForClient = (snapshot) => snapshot == null ? null : ({
  revision: snapshot.revision,
  items: cloneJson(snapshot.items),
  updatedAt: snapshot.updatedAt,
});

const matchesAppliedWrite = (snapshot, mutation) => (
  snapshot?.lastWriteId === mutation.writeId
  && snapshot?.requestHash === mutation.requestHash
);

const matchesAppliedSnapshot = (snapshot, next) => (
  snapshot?.revision === next.revision
  && snapshot?.lastWriteId === next.lastWriteId
  && snapshot?.requestHash === next.requestHash
  && JSON.stringify(snapshot?.items) === JSON.stringify(next.items)
);

const normalizePublishedItems = async (items, resolveWikiItem) => {
  const resolved = await Promise.all(items.map(async (item) => ({
    item,
    wikiItem: await resolveWikiItem(item.wikiItemId),
  })));
  const staleWikiItemIds = resolved
    .filter(({ wikiItem }) => !wikiItem)
    .map(({ item }) => item.wikiItemId);
  if (staleWikiItemIds.length > 0) {
    fail(409, 'VISIT_RECOMMENDATIONS_WIKI_LINK_STALE', {
      details: { wikiItemIds: staleWikiItemIds },
    });
  }

  return resolved.map(({ item, wikiItem }) => ({
    ...item,
    wikiItemId: stringValue(wikiItem.id).trim(),
    wikiTitle: stringValue(wikiItem.title).trim(),
    // The snapshot stores identities and user-authored content, not embedded
    // library binaries. GET rehydrates the current authoritative image.
    wikiImageUrl: /^data:/i.test(stringValue(wikiItem.imageUrl).trim())
      ? ''
      : stringValue(wikiItem.imageUrl).trim(),
    wikiTag: stringValue(wikiItem.tags?.[0] ?? wikiItem.tag).trim(),
    wikiDescription: stringValue(wikiItem.description),
  }));
};

const requireStore = (store) => {
  if (!store || typeof store.read !== 'function' || typeof store.compareAndSwap !== 'function') {
    throw new TypeError('A snapshot store with read and compareAndSwap is required');
  }
};

/**
 * Publishes a complete, linked-only recommendation snapshot.
 *
 * compareAndSwap must atomically replace one row when its revision matches,
 * or atomically create it when expectedRevision is null. It must never emulate
 * this contract with a delete/create loop.
 */
export const createVisitRecommendationsPublisher = ({
  store,
  resolveWikiItem,
  now = () => new Date().toISOString(),
}) => {
  requireStore(store);
  if (typeof resolveWikiItem !== 'function') {
    throw new TypeError('An authoritative wiki resolver is required');
  }

  return async ({ dossierId, envelope }) => {
    const mutation = validateVisitRecommendationsEnvelope({ dossierId, envelope });
    const before = await store.read(mutation.dossierId);

    if (before?.lastWriteId === mutation.writeId) {
      if (!matchesAppliedWrite(before, mutation)) {
        fail(409, 'VISIT_RECOMMENDATIONS_WRITE_ID_REUSED', {
          observed: snapshotForClient(before),
        });
      }
      return {
        applied: true,
        replay: true,
        snapshot: snapshotForClient(before),
      };
    }

    const currentRevision = before?.revision ?? null;
    if (currentRevision !== mutation.expectedRevision) {
      fail(409, 'VISIT_RECOMMENDATIONS_REVISION_CONFLICT', {
        observed: snapshotForClient(before),
      });
    }

    const publishedItems = await normalizePublishedItems(
      mutation.items,
      resolveWikiItem,
    );
    const next = {
      dossierId: mutation.dossierId,
      revision: mutation.writeId,
      lastWriteId: mutation.writeId,
      requestHash: mutation.requestHash,
      items: publishedItems,
      updatedAt: now(),
    };

    let outcome;
    try {
      outcome = await store.compareAndSwap({
        dossierId: mutation.dossierId,
        expectedRevision: mutation.expectedRevision,
        next: cloneJson(next),
      });
    } catch (cause) {
      let observed;
      try {
        observed = await store.read(mutation.dossierId);
      } catch (readCause) {
        fail(503, 'VISIT_RECOMMENDATIONS_WRITE_UNCONFIRMED', {
          cause: new AggregateError([cause, readCause]),
        });
      }
      if (matchesAppliedSnapshot(observed, next)) {
        return {
          applied: true,
          replay: true,
          snapshot: snapshotForClient(observed),
        };
      }
      fail(503, 'VISIT_RECOMMENDATIONS_WRITE_UNCONFIRMED', {
        observed: snapshotForClient(observed),
        cause,
      });
    }

    if (outcome?.status === 'applied') {
      const observed = outcome.snapshot ?? await store.read(mutation.dossierId);
      if (matchesAppliedSnapshot(observed, next)) {
        return {
          applied: true,
          replay: Boolean(outcome.replay),
          snapshot: snapshotForClient(observed),
        };
      }
      fail(503, 'VISIT_RECOMMENDATIONS_WRITE_UNCONFIRMED', {
        observed: snapshotForClient(observed),
      });
    }

    if (outcome?.status === 'revision_changed') {
      const observed = outcome.snapshot ?? await store.read(mutation.dossierId);
      if (matchesAppliedWrite(observed, mutation)) {
        return {
          applied: true,
          replay: true,
          snapshot: snapshotForClient(observed),
        };
      }
      fail(409, 'VISIT_RECOMMENDATIONS_REVISION_CONFLICT', {
        observed: snapshotForClient(observed),
      });
    }

    fail(503, 'VISIT_RECOMMENDATIONS_WRITE_UNCONFIRMED', {
      observed: snapshotForClient(outcome?.snapshot),
    });
  };
};

const parseSnapshotItems = (value) => {
  try {
    const stored = stringValue(value);
    const json = stored.startsWith(compressedItemsPrefix)
      ? gunzipSync(Buffer.from(stored.slice(compressedItemsPrefix.length), 'base64')).toString('utf8')
      : stored;
    const parsed = JSON.parse(json);
    if (!Array.isArray(parsed)) throw new TypeError('items_json is not an array');
    return parsed;
  } catch (cause) {
    fail(503, 'VISIT_RECOMMENDATIONS_SNAPSHOT_CORRUPT', { cause });
  }
};

const mapSnapshotRow = (row) => {
  if (!row) return null;
  const revision = stringValue(row[VISIT_RECOMMENDATIONS_REVISION_FIELD]).trim();
  const lastWriteId = stringValue(row.last_write_id).trim();
  const requestHash = stringValue(row.request_hash).trim();
  if (!Number.isSafeInteger(Number(row.Id)) || !uuidPattern.test(revision)
      || !uuidPattern.test(lastWriteId) || !/^[0-9a-f]{64}$/i.test(requestHash)) {
    fail(503, 'VISIT_RECOMMENDATIONS_SNAPSHOT_CORRUPT');
  }
  const mapped = {
    recordId: Number(row.Id),
    dossierId: stringValue(row.dossier_id),
    revision,
    lastWriteId,
    requestHash,
    items: parseSnapshotItems(row.items_json),
    updatedAt: stringValue(row.updated_at),
  };
  if (!mapped.dossierId || hashVisitRecommendationsRequest(mapped) !== requestHash) {
    fail(503, 'VISIT_RECOMMENDATIONS_SNAPSHOT_CORRUPT');
  }
  return mapped;
};

const snapshotFields = (snapshot) => ({
  dossier_id: snapshot.dossierId,
  items_json: encodeVisitRecommendationsSnapshotItems(snapshot.items),
  request_hash: snapshot.requestHash,
  [VISIT_RECOMMENDATIONS_REVISION_FIELD]: snapshot.revision,
  last_write_id: snapshot.lastWriteId,
  updated_at: snapshot.updatedAt,
});

/**
 * NocoDB REST adapter for the dedicated one-row-per-dossier snapshot table.
 * The injected request function must not retry writes or fall back to MCP.
 * A database UNIQUE constraint on dossier_id is mandatory for atomic create.
 */
export const createNocodbVisitRecommendationsSnapshotStore = ({
  baseId,
  tableId,
  request,
}) => {
  if (!identifierPattern.test(baseId ?? '') || !identifierPattern.test(tableId ?? '')) {
    throw new TypeError('Valid NocoDB base and table identifiers are required');
  }
  if (typeof request !== 'function') {
    throw new TypeError('A NocoDB REST request adapter is required');
  }

  const read = async (dossierId) => {
    if (!filterValuePattern.test(String(dossierId))) {
      fail(400, 'VISIT_RECOMMENDATIONS_DOSSIER_ID_INVALID');
    }
    const params = new URLSearchParams({
      where: `(dossier_id,eq,${String(dossierId)})`,
      limit: '2',
      fields: [
        'Id',
        'dossier_id',
        'items_json',
        'request_hash',
        VISIT_RECOMMENDATIONS_REVISION_FIELD,
        'last_write_id',
        'updated_at',
      ].join(','),
    });
    const result = await request({
      method: 'GET',
      path: `/api/v2/tables/${tableId}/records?${params}`,
    });
    const rows = Array.isArray(result) ? result : result?.list;
    if (!Array.isArray(rows) || rows.length > 1) {
      fail(503, 'VISIT_RECOMMENDATIONS_SNAPSHOT_NOT_UNIQUE');
    }
    const snapshot = mapSnapshotRow(rows[0]);
    if (snapshot && snapshot.dossierId !== String(dossierId)) {
      fail(503, 'VISIT_RECOMMENDATIONS_SNAPSHOT_SCOPE_MISMATCH');
    }
    return snapshot;
  };

  const compareAndSwap = async ({ dossierId, expectedRevision, next }) => {
    const observed = await read(dossierId);
    if ((observed?.revision ?? null) !== expectedRevision) {
      return { status: 'revision_changed', snapshot: observed };
    }

    if (!observed) {
      await request({
        method: 'POST',
        path: `/api/v2/tables/${tableId}/records`,
        body: snapshotFields(next),
      });
    } else {
      const params = new URLSearchParams({
        where: `(Id,eq,${observed.recordId})~and(${VISIT_RECOMMENDATIONS_REVISION_FIELD},eq,${expectedRevision})`,
      });
      await request({
        method: 'PATCH',
        path: `/api/v1/db/data/bulk/noco/${baseId}/${tableId}/all?${params}`,
        body: snapshotFields(next),
      });
    }

    const after = await read(dossierId);
    if (after?.revision === next.revision
        && after?.lastWriteId === next.lastWriteId
        && after?.requestHash === next.requestHash
        && JSON.stringify(after?.items) === JSON.stringify(next.items)) {
      return { status: 'applied', replay: false, snapshot: after };
    }
    return { status: 'revision_changed', snapshot: after };
  };

  return { read, compareAndSwap };
};

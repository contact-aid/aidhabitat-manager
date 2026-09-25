import { isDeepStrictEqual } from 'node:util';
import { createDatabaseValueComparator } from './nocodbScalarValues.mjs';
import { validateConditionalPatch } from './nocodbConditionalWrite.mjs';

export const SYNC_REVISION_FIELD = 'app_sync_revision';
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const structuredColumns = new Set(['occupants_json', 'sdb_instances_json', 'wc_instances_json']);

function unreadableStructuredFields(fields, observed) {
  return Object.keys(fields).filter((key) => {
    if (!structuredColumns.has(key)) return false;
    const value = observed[key];
    if (value == null || value === '') return false;
    if (typeof value !== 'string') return true;
    try {
      const parsed = JSON.parse(value);
      return !Array.isArray(parsed) || parsed.some((item) =>
        item == null || typeof item !== 'object' || Array.isArray(item));
    } catch { return true; }
  });
}

export class SyncMutationError extends Error {
  constructor(status, code, observed = null, details = null) {
    super(code);
    this.status = status;
    this.statusCode = status;
    this.code = code;
    this.observed = observed;
    this.details = details;
  }
}

/** All values use the SAME database mapper for the patch and its baseline.
 * A missing baseline is unknown, never null. Derived/structured columns are
 * compared atomically. This planner alone grants no permission to write.
 */
export function planDatabaseMutation({ fields, baseFields, observed, equals = (_key, a, b) => isDeepStrictEqual(a, b) }) {
  const patch = {};
  const conflicts = [];
  const retainedFields = [];
  for (const [key, value] of Object.entries(fields)) {
    if (!Object.hasOwn(observed, key)) conflicts.push(key);
    else if (equals(key, observed[key], value)) continue;
    else if (!Object.hasOwn(baseFields, key)) conflicts.push(key);
    else if (equals(key, baseFields[key], value)) retainedFields.push(key);
    else if (equals(key, baseFields[key], observed[key])) patch[key] = value;
    else conflicts.push(key);
  }
  return { patch, conflicts, retainedFields };
}

/** Opt-in coordinator. Call ONLY after authorization and domain mapping.
 * readRecord must isolate one table/Id. writer must atomically compare Id AND
 * app_sync_revision and confirm content, never use an unconditional fallback.
 */
export function createGuardedMutation({ readRecord, writer, readColumns, preferLocal = false }) {
  return async ({ tableId, recordId, fields, baseFields, writeId, authorizeObserved,
    normalizeObserved }) => {
    if (!uuid.test(writeId ?? '') || typeof writeId !== 'string') {
      throw new SyncMutationError(428, 'SYNC_MUTATION_ID_REQUIRED');
    }
    // Validate before reads and no-op/replay shortcuts, not only in the writer.
    try {
      validateConditionalPatch(fields);
      validateConditionalPatch(baseFields, { allowEmpty: true });
    } catch {
      throw new SyncMutationError(400, 'SYNC_MUTATION_INVALID');
    }
    const desired = structuredClone(fields);
    const baseline = structuredClone(baseFields);
    const equals = createDatabaseValueComparator(readColumns ? await readColumns(tableId) : []);
    // One bounded retry if a competitor wins before our guarded write. The
    // entire comparison is recomputed; the revision is never just refreshed.
    for (let attempt = 0; attempt < 2; attempt++) {
      const observed = await readRecord(tableId, recordId);
      if (!observed) throw new SyncMutationError(409, 'SYNC_RECORD_MISSING');
      if (authorizeObserved && !await authorizeObserved(observed)) {
        throw new SyncMutationError(403, 'SYNC_RECORD_FORBIDDEN');
      }
      const comparisonObserved = normalizeObserved
        ? await normalizeObserved(structuredClone(observed))
        : observed;
      const revision = observed[SYNC_REVISION_FIELD];
      if (!uuid.test(revision ?? '')) {
        throw new SyncMutationError(503, 'SYNC_REVISION_NOT_PREPARED');
      }
      if (revision === writeId) {
        const replayPlan = planDatabaseMutation({ fields: desired, baseFields: baseline,
          observed: comparisonObserved, equals });
        if (!replayPlan.conflicts.length && !replayPlan.retainedFields.length && !Object.keys(replayPlan.patch).length) {
          return { applied: true, replay: true };
        }
        throw new SyncMutationError(409, 'SYNC_WRITE_ID_MISMATCH', observed, {
          conflicts: replayPlan.conflicts, retainedFields: replayPlan.retainedFields, writeId,
        });
      }
      const unreadable = preferLocal
        ? unreadableStructuredFields(desired, comparisonObserved)
        : [];
      if (unreadable.length) {
        throw new SyncMutationError(409, 'SYNC_REMOTE_VALUES_REQUIRE_REVIEW', observed,
          { conflicts: unreadable, retainedFields: [], writeId });
      }
      const plan = preferLocal
        ? { patch: Object.fromEntries(Object.entries(desired).filter(([key, value]) =>
            !Object.hasOwn(comparisonObserved, key) || !equals(key, comparisonObserved[key], value))),
          conflicts: [], retainedFields: [] }
        : planDatabaseMutation({ fields: desired, baseFields: baseline,
          observed: comparisonObserved, equals });
      if (plan.conflicts.length) {
        throw new SyncMutationError(409, 'SYNC_FIELD_CONFLICT', observed, {
          conflicts: plan.conflicts, retainedFields: plan.retainedFields, writeId,
        });
      }
      // The current client only consumes updatedAt from a PATCH response.
      // Acknowledging a local undo while keeping a different remote value
      // would mark that stale local value as synced until the next pull.
      if (plan.retainedFields.length) {
        throw new SyncMutationError(409, 'SYNC_REMOTE_VALUES_REQUIRE_REVIEW', observed, {
          conflicts: plan.conflicts, retainedFields: plan.retainedFields, writeId,
        });
      }
      if (!Object.keys(plan.patch).length) return { applied: true, replay: true };
      const result = await writer({ tableId, recordId, expectedRevision: revision,
        writeId, fields: plan.patch });
      if (result.status === 'applied') return { applied: true, replay: result.replay };
      if (result.reason !== 'revision_changed') {
        // A mismatching confirmation may follow a successful write. Retain
        // the SAME mutation for retry, without falsely declaring a conflict.
        throw new SyncMutationError(503, 'SYNC_WRITE_UNCONFIRMED');
      }
    }
    throw new SyncMutationError(503, 'SYNC_COMPETING_WRITE_RETRY');
  };
}

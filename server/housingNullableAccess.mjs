import { SyncMutationError } from './guardedMutation.mjs';
import { createDatabaseValueComparator } from './nocodbScalarValues.mjs';
const sameInstant = createDatabaseValueComparator([{title:'updatedAt',uidt:'DateTime'}]);

export function sameHousingSourceVersion(expected, observed) {
  return typeof expected === 'string' && typeof observed === 'string' &&
    Number.isFinite(Date.parse(expected)) && Number.isFinite(Date.parse(observed)) &&
    sameInstant('updatedAt', expected, observed);
}

// Older clients projected an unanswered nullable choice to false in their
// baseline. Repair that projection ONLY while the exact source record version
// is still current. A later web edit, including a clear back to null, wins.
export function normalizeHousingAccessBaseline({baseline,observed,expectedUpdatedAt,observedUpdatedAt,desiredAccess}) {
  // A projected legacy false must not masquerade as an explicit No entered
  // by another device after the original read. First null references remain
  // ordinary field-level merges; only this ambiguous old false is bounded.
  if ((baseline.acces_facile_rue === false || baseline.acces_facile_rue === 'false') &&
      (observed.acces_facile_rue === false || observed.acces_facile_rue === 'false') &&
      (desiredAccess === true || desiredAccess === 'true') &&
      !sameHousingSourceVersion(expectedUpdatedAt,observedUpdatedAt)) {
    throw new SyncMutationError(409,'SYNC_FIELD_CONFLICT',observed,
      {conflicts:['acces_facile_rue'],retainedFields:[]});
  }
  if (Object.hasOwn(baseline,'acces_facile_rue') &&
      (baseline.acces_facile_rue === false || baseline.acces_facile_rue === 'false') &&
      Object.hasOwn(observed,'acces_facile_rue') && observed.acces_facile_rue === null &&
      sameHousingSourceVersion(expectedUpdatedAt,observedUpdatedAt)) {
    return {...baseline,acces_facile_rue:null};
  }
  return baseline;
}

import { createDatabaseValueComparator } from './nocodbScalarValues.mjs';
const sameInstant = createDatabaseValueComparator([{title:'updatedAt',uidt:'DateTime'}]);

// Older clients projected an unanswered nullable choice to false in their
// baseline. Repair that projection ONLY while the exact source record version
// is still current. A later web edit, including a clear back to null, wins.
export function normalizeHousingAccessBaseline({baseline,observed,expectedUpdatedAt,observedUpdatedAt}) {
  if (Object.hasOwn(baseline,'acces_facile_rue') &&
      (baseline.acces_facile_rue === false || baseline.acces_facile_rue === 'false') &&
      Object.hasOwn(observed,'acces_facile_rue') && observed.acces_facile_rue === null &&
      typeof expectedUpdatedAt === 'string' && typeof observedUpdatedAt === 'string' &&
      Number.isFinite(Date.parse(expectedUpdatedAt)) && Number.isFinite(Date.parse(observedUpdatedAt)) &&
      sameInstant('updatedAt',expectedUpdatedAt,observedUpdatedAt)) {
    return {...baseline,acces_facile_rue:null};
  }
  return baseline;
}

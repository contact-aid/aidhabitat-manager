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
export function normalizeHousingAccessBaseline({baseline,observed,expectedUpdatedAt,observedUpdatedAt}) {
  if (Object.hasOwn(baseline,'acces_facile_rue') &&
      (baseline.acces_facile_rue === false || baseline.acces_facile_rue === 'false') &&
      Object.hasOwn(observed,'acces_facile_rue') && observed.acces_facile_rue === null &&
      sameHousingSourceVersion(expectedUpdatedAt,observedUpdatedAt)) {
    return {...baseline,acces_facile_rue:null};
  }
  return baseline;
}

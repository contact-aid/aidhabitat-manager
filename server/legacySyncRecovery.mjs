import { isDeepStrictEqual } from 'node:util';
import { legacyDefaultFalseColumns } from './nocodbScalarValues.mjs';

// These housing checkboxes are read as false when the legacy database is empty.
// Nullable choices (notably acces_facile_rue) deliberately stay out of this set.
export const defaultFalseHousingColumns = new Set([...legacyDefaultFalseColumns]
  .filter((key) => !['beneficiaire_apa', 'reconnaissance_invalidite_mdph',
    'aide_a_domicile', 'beneficiaire_prepare'].includes(key)));

export function mappedDatabaseValueEquals(key, observed, mapped) {
  if (isDeepStrictEqual(observed, mapped)) return true;
  if (defaultFalseHousingColumns.has(key) && ['true', 'false'].includes(mapped)) {
    if (observed == null || observed === '' || observed === false || observed === 0) return mapped === 'false';
    if (observed === true || observed === 1) return mapped === 'true';
  }
  if ((observed == null && mapped === '') || (mapped == null && observed === '')) return true;
  if (typeof mapped === 'boolean') {
    if (observed === 'true' || observed === 1) return mapped;
    if (observed === 'false' || observed === 0 || observed == null) return !mapped;
  }
  if (typeof mapped === 'number' && typeof observed === 'string' && observed.trim()) {
    return Number.isFinite(mapped) && Number(observed) === mapped;
  }
  if (key.endsWith('_json') && typeof observed === 'string' && typeof mapped === 'string') {
    try { return isDeepStrictEqual(JSON.parse(observed), JSON.parse(mapped)); } catch { return false; }
  }
  return false;
}

// A retry may confirm an already applied patch, but must never write through
// a stale timestamp. Compare all mapped fields, not a subset of the request.
export function inspectLegacyRecovery({ guard, fields, baseFields = {}, observed,
  updatedAt, equals = mappedDatabaseValueEquals }) {
  if (guard?.version !== 1 || typeof guard.writeId !== 'string'
      || !/^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/.test(guard.writeId)
      || !guard.baseValues || typeof guard.baseValues !== 'object'
      || Array.isArray(guard.baseValues) || !Number.isFinite(Date.parse(updatedAt))) return null;
  const entries = Object.entries(fields).filter(([, value]) => value !== undefined);
  if (!entries.length) return null;
  const matches = (key, value) => Object.hasOwn(observed, key) && equals(key, observed[key], value);
  if (entries.every(([key, value]) => matches(key, value))) return 'replay';
  // Even a current timestamp cannot authorize overwriting a baseline that
  // changed during recovery of an earlier write from this device.
  if (entries.some(([key, value]) => Object.hasOwn(baseFields, key)
      && baseFields[key] !== undefined && !matches(key, value) && !matches(key, baseFields[key]))) {
    return 'conflict';
  }
  return null;
}

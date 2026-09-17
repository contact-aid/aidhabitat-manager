import { isDeepStrictEqual } from 'node:util';

function instantMicros(value) {
  if (typeof value !== 'string') return null;
  // Only zoned, complete timestamps. Do not guess local time or truncate
  // PostgreSQL microseconds when comparing a stored value with an ISO date.
  const match = /^(\d{4}-\d{2}-\d{2})[ T](\d{2}:\d{2}:\d{2})(?:\.(\d{1,6}))?(Z|[+-]\d{2}:\d{2})$/.exec(value);
  if (!match) return null;
  const local = Date.parse(`${match[1]}T${match[2]}Z`);
  if (!Number.isFinite(local) || new Date(local).toISOString().slice(0, 19) !== `${match[1]}T${match[2]}`) return null;
  const milliseconds = Date.parse(`${match[1]}T${match[2]}${match[4]}`);
  if (!Number.isFinite(milliseconds)) return null;
  return BigInt(milliseconds) * 1000n + BigInt((match[3] ?? '').padEnd(6, '0'));
}

function checkbox(value) {
  if (value === true || value === 'true') return true;
  if (value === false || value === 'false') return false;
  return value;
}

const structuredColumns = new Set(['sdb_instances_json', 'wc_instances_json', 'occupants_json']);
function numeric(value) {
  if (typeof value === 'number') return Number.isFinite(value) && Math.abs(value) <= Number.MAX_SAFE_INTEGER ? value : null;
  if (typeof value !== 'string' || !/^[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?$/.test(value.trim())) return null;
  const result = Number(value);
  return Number.isFinite(result) && Math.abs(result) <= Number.MAX_SAFE_INTEGER ? result : null;
}

export function createDatabaseValueComparator(columns = []) {
  const types = new Map(columns.map((column) => [column.title, column.uidt]));
  return (key, a, b) => {
    if (isDeepStrictEqual(a, b)) return true;
    if (types.get(key) === 'DateTime') {
      const left = instantMicros(a);
      return left !== null && left === instantMicros(b);
    }
    if (types.get(key) === 'Checkbox') return isDeepStrictEqual(checkbox(a), checkbox(b));
    if (types.get(key) === 'Number') {
      const left = numeric(a);
      return left !== null && left === numeric(b);
    }
    if (structuredColumns.has(key) && typeof a === 'string' && typeof b === 'string') {
      try {
        const left = JSON.parse(a);
        const right = JSON.parse(b);
        return Array.isArray(left) && Array.isArray(right) && isDeepStrictEqual(left, right);
      } catch { return false; }
    }
    return false;
  };
}

export function canonicalDatabasePatch(fields, columns) {
  const types = new Map(columns.map((column) => [column.title, column.uidt]));
  return Object.fromEntries(Object.entries(fields).map(([key, value]) =>
    [key, types.get(key) === 'Checkbox' ? checkbox(value) : value]));
}

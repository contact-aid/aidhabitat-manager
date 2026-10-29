import { isDeepStrictEqual } from 'node:util';
import { isEmptyRoomBreakdown } from './nocodbScalarValues.mjs';

const levels = new Set(['sous_sol', 'rdc', 'etage', 'second_etage', 'third_etage']);
const texts = new Set(['dependance_particuliere_txt', 'dependenceTxt',
  'numeroSecuriteSociale', 'caisseRetraitePrincipale', 'caissesRetraiteComplementaires',
  'apaGir', 'apaDetails', 'invalidityTxt', 'invalidityDetails', 'homeHelpTxt', 'fiscalReferenceYear']);
const empty = value => value == null || (typeof value === 'string' && !value.trim());
function initial(key, value) {
  if (texts.has(key)) return empty(value);
  if (levels.has(key)) return empty(value) || [false, 0, 'false', '0'].includes(value);
  if (key === 'rooms_breakdown_json') return isEmptyRoomBreakdown(value);
  return false;
}

// No preference means that the normal three-way comparison must decide.
// Mixed independent occupant changes are merged by the client after a fresh
// review: never acknowledge a snapshot different from the sent values.
export function initialValuePreference(key, local, remote) {
  if (key === 'occupants_json') {
    let a, b;
    try { a = JSON.parse(local); b = JSON.parse(remote); } catch { return null; }
    if (!Array.isArray(a) || !Array.isArray(b) || a.length !== b.length) return null;
    const seen = new Set();
    let preference = null;
    for (let i = 0; i < a.length; i++) {
      const identity = person => person && typeof person === 'object' && !Array.isArray(person)
        && `${person.firstName ?? ''}${person.lastName ?? ''}`.trim()
        ? JSON.stringify([person.firstName ?? '', person.lastName ?? '', person.birthDate ?? '']) : null;
      const id = identity(a[i]);
      if (!id || id !== identity(b[i]) || seen.has(id)) return null;
      seen.add(id);
      for (const property of new Set([...Object.keys(a[i]), ...Object.keys(b[i])])) {
        if (isDeepStrictEqual(a[i][property], b[i][property])
            || (texts.has(property) && empty(a[i][property]) && empty(b[i][property]))) continue;
        const next = initialValuePreference(property, a[i][property], b[i][property]);
        if (!next || (preference && preference !== next)) return null;
        preference = next;
      }
    }
    return preference;
  }
  if (initial(key, remote) && !initial(key, local)) return 'local';
  if (initial(key, local) && !initial(key, remote)) return 'remote';
  return null;
}

// Stable role assignments, separate from preset accounts: loading the registry
// must not provision users or reset credentials as a side effect.
export const TECHNICIAN_PROFILES = Object.freeze({
  'f.cribier@aidhabitat.fr': Object.freeze({ displayName: 'Fabien CRIBIER' }),
  'r.lamour@aidhabitat.fr': Object.freeze({ displayName: 'Renan LAMOUR' }),
  'ag.rozec@aidhabitat.fr': Object.freeze({ displayName: 'Anne-Gaëlle ROZEC' }),
});

export function isTechnicianEmail(email) {
  return Object.hasOwn(TECHNICIAN_PROFILES, String(email ?? '').trim().toLowerCase());
}

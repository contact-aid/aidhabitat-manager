const hasGender = (occupant) => occupant && Object.hasOwn(occupant, 'gender')
  && ['', 'Homme', 'Femme'].includes(occupant.gender);
const hasMaidenName = (occupant) => occupant && typeof occupant.maidenName === 'string'
  && occupant.maidenName.trim() !== '';
const protectedTextFields = ['fiscalRevenueYear', 'apaDetails', 'invalidityDetails'];
const hasProtectedText = (occupant, key) => occupant && typeof occupant[key] === 'string'
  && occupant[key].trim() !== '';
const hasProtectedField = (occupant) => hasGender(occupant) || hasMaidenName(occupant)
  || protectedTextFields.some((key) => hasProtectedText(occupant, key));
const needsProtection = (incoming, previous) =>
  (hasGender(previous) && !Object.hasOwn(incoming, 'gender'))
  || (hasMaidenName(previous) && !Object.hasOwn(incoming, 'maidenName'))
  || protectedTextFields.some((key) =>
    hasProtectedText(previous, key) && !Object.hasOwn(incoming, key));
const normalized = (value) => String(value ?? '').trim().toLocaleLowerCase('fr');
const sameIdentity = (left, right) => left && right
  && Boolean(normalized(left.firstName) || normalized(left.lastName))
  && normalized(left.firstName) === normalized(right.firstName)
  && normalized(left.lastName) === normalized(right.lastName)
  && normalized(left.birthDate) === normalized(right.birthDate);

// Older builds strip unknown fields. Preserve newer occupant fields only when the identity is
// unique (or the client's observed identity identifies an intentional rename).
// Never infer identity from birth date alone or blindly zip arrays by position.
export function preserveLegacyOccupantGender(updates, storedOccupantsJson, { strict = true } = {}) {
  if (!Array.isArray(updates?.occupants)) return updates;
  let stored;
  try { stored = JSON.parse(storedOccupantsJson || '[]'); } catch { return updates; }
  if (!Array.isArray(stored) || !stored.some(hasProtectedField)) return updates;
  const baseline = updates.concurrency?.baseValues?.occupants;
  const uniqueMatch = (occupant) => {
    const matches = stored.filter((previous) => sameIdentity(occupant, previous));
    return matches.length === 1 ? matches[0] : null;
  };
  const direct = updates.occupants.map(uniqueMatch);
  const reordered = direct.some((match, index) => match && stored.indexOf(match) !== index);
  const occupants = updates.occupants.map((incoming, index) => {
    if (!incoming || typeof incoming !== 'object') return incoming;
    let previous = direct[index];
    if (!previous && !reordered && Array.isArray(baseline)
      && baseline.length === updates.occupants.length) previous = uniqueMatch(baseline[index]);
    if (previous) return {
      ...incoming,
      ...(hasGender(previous) && !Object.hasOwn(incoming, 'gender')
        ? { gender: previous.gender } : {}),
      ...(hasMaidenName(previous) && !Object.hasOwn(incoming, 'maidenName')
        ? { maidenName: previous.maidenName } : {}),
      ...Object.fromEntries(protectedTextFields
        .filter((key) => hasProtectedText(previous, key) && !Object.hasOwn(incoming, key))
        .map((key) => [key, previous[key]])),
    };
    // A genuinely appended blank/new occupant has no earlier gender to retain.
    if (index >= stored.length || !strict) return incoming;
    // Unnamed placeholders carry no identity/gender to recover. Keep their
    // medical fields exactly as submitted; normal array conflict checks apply.
    if (!normalized(incoming.firstName) && !normalized(incoming.lastName)
      && !normalized(stored[index]?.firstName) && !normalized(stored[index]?.lastName)
      && !hasProtectedField(stored[index])) return incoming;
    if (!needsProtection(incoming, stored[index])) return incoming;
    const error = new Error('L’identité des occupants a changé. Actualisez le dossier avant de réessayer.');
    error.statusCode = 409;
    throw error;
  });
  return { ...updates, occupants };
}

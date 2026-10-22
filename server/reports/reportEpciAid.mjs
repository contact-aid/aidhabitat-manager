// An EPCI linked to a town identifies its territory, not an available grant.
export function hasEpciAid(value) {
  if (typeof value === 'boolean') return value;
  if (typeof value === 'number') return value > 0;
  const text = String(value ?? '').trim().toLowerCase();
  return Boolean(text) && !['non', 'false', '0', '/', 'aucune', 'aucun', 'néant', 'pas d’aide', "pas d'aide"].includes(text);
}

export async function resolveReportEpciAid(patient, { queryAll, tables }) {
  const cityId = String(patient?.cityId ?? '').trim();
  if (!/^\d+$/.test(cityId)) return '/';
  try {
    const [commune] = await queryAll(tables.communes, {
      fields: ['epci_id1'], where: `(Id,eq,${cityId})`,
    });
    const epciId = String(commune?.fields?.epci_id1 ?? '').trim();
    if (!/^\d+$/.test(epciId)) return '/';
    const [epci] = await queryAll(tables.epci, {
      fields: ['nom', 'aide_communautes_commune'], where: `(Id,eq,${epciId})`,
    });
    if (!hasEpciAid(epci?.fields?.aide_communautes_commune)) return '/';
    return String(epci?.fields?.nom ?? '').trim() || '/';
  } catch (error) {
    console.warn('[report] échec résolution aide EPCI :', error?.message || error);
    return '/';
  }
}

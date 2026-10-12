import { AIRTABLE_ADAPTATION } from '../airtableAdaptation.mjs';

// The actual Airtable dossier lookup is derived from the client's checkbox.
// Never infer programme membership from the commune or the EPCI alone.
export async function resolveReportPigPloermel(dossierId, { token, fetchImpl = fetch } = {}) {
  const match = /^airtable:(rec[A-Za-z0-9]{14})$/.exec(String(dossierId));
  if (!match) return null;
  if (!token) throw new Error('Lecture Airtable nécessaire pour vérifier le tarif AMO PIG Ploërmel.');
  const url = new URL(`https://api.airtable.com/v0/${AIRTABLE_ADAPTATION.baseId}/${AIRTABLE_ADAPTATION.dossiersTableId}`);
  url.searchParams.set('filterByFormula', `RECORD_ID()="${match[1]}"`);
  url.searchParams.append('fields[]', 'PIG ploermel');
  const response = await fetchImpl(url, { headers: { Authorization: `Bearer ${token}` }, signal: AbortSignal.timeout(15000), redirect: 'error' });
  if (!response.ok) throw new Error(`Vérification AMO Airtable indisponible (${response.status}).`);
  const { records } = await response.json();
  if (!Array.isArray(records) || records.length !== 1 || records[0].id !== match[1]) throw new Error('Dossier Airtable introuvable pour vérifier le tarif AMO.');
  const value = records[0].fields?.['PIG ploermel'];
  return (Array.isArray(value) ? value : [value]).some(flag => flag === true || flag === 1);
}

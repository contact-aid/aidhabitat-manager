import { normalizeDossierAssignment } from './dossierAssignments.mjs';

const recordTime = ({ fields }) => new Date(
  fields?.UpdatedAt || fields?.updated_at || fields?.created_at || 0,
).getTime();

export const latestRecord = (records) => [...records].sort((a, b) => {
  const aTime = recordTime(a);
  const bTime = recordTime(b);
  return aTime !== bTime ? bTime - aTime : Number(b.id) - Number(a.id);
})[0];

const generatedUuid = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

const isBlankGeneratedDossier = ({ fields }) =>
  generatedUuid.test(fields.uuid_source)
  && fields.status === 'À visiter'
  && !normalizeDossierAssignment(fields.ergo_id)
  && !fields.visit_date && !fields.airtable_stage && !fields.airtable_report_sent_date
  && !fields.compte_anah && !fields.nature_accompagnement && !fields.envoi_rapport
  && !fields.personnes_presentes_visite && !fields.beneficiaire_prepare;

// During import, a concurrent dossier listing can create an empty row for the
// new beneficiary. Keep normal recency ordering for every substantive dossier.
export function selectDossierRecord(records) {
  const latest = latestRecord(records);
  if (!latest || !isBlankGeneratedDossier(latest)) return latest;
  const beneficiaryId = latest.fields.beneficiaires_id;
  if (!beneficiaryId) return latest;
  const sameBeneficiary = (row) => String(row.fields.beneficiaires_id) === String(beneficiaryId);
  const siblings = records.filter(sameBeneficiary);
  if (!siblings.some(row => row.fields.uuid_source?.startsWith('airtable:'))) {
    return latest;
  }
  return latestRecord(siblings.filter(row => !isBlankGeneratedDossier(row)));
}

export const selectDossierByField = (records, key, value) => selectDossierRecord(
  records.filter(row => String(row.fields?.[key] ?? '') === String(value ?? '')),
);

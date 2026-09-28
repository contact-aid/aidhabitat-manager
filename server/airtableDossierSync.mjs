import crypto from 'node:crypto';
import { isCurrentCoralieDossier, projectAirtableDossier } from './airtableAdaptation.mjs';

const value = (record, key) => record?.fields?.[key] ?? record?.[key];
const normalized = (input) => String(input ?? '').trim().replace(/\s+/g, ' ');
const same = (left, right) => normalized(left) === normalized(right);

// This first rollout is deliberately limited to the 22 non-cancelled Coralie
// appointments dated 1 August 2026 or later. Airtable remains read only.
export async function syncCurrentCoralieDossiers({
  sourceRows, dossierRows, beneficiaryRows, createBeneficiary, createDossier,
  updateBeneficiary, updateDossier, maxChanges = 5,
}) {
  const eligible = sourceRows.filter(isCurrentCoralieDossier).map(projectAirtableDossier);
  const dossiersByUuid = new Map(dossierRows.map((row) => [normalized(value(row, 'uuid_source')), row]));
  const beneficiariesById = new Map(beneficiaryRows.map((row) => [String(row.id), row]));
  const operations = [];
  const skipped = [];

  for (const source of eligible) {
    const uuid = `airtable:${source.airtableRecordId}`;
    const existingDossier = dossiersByUuid.get(uuid);
    if (existingDossier && !same(value(existingDossier, 'ergo_id'), 'Coralie')) {
      skipped.push({ id: source.airtableRecordId, reason: 'attribution différente' });
      continue;
    }
    if (!source.beneficiary.prenom || !source.beneficiary.nom || !source.airtableClientRecordId) {
      skipped.push({ id: source.airtableRecordId, reason: 'fiche client incomplète' });
      continue;
    }
    if (!existingDossier) {
      operations.push({ kind: 'create', source, uuid });
      continue;
    }
    const beneficiary = beneficiariesById.get(String(value(existingDossier, 'beneficiaires_id')));
    if (!beneficiary) {
      skipped.push({ id: source.airtableRecordId, reason: 'bénéficiaire introuvable' });
      continue;
    }
    const beneficiaryPatch = Object.fromEntries(Object.entries(source.beneficiary)
      .filter(([key, desired]) => !same(value(beneficiary, key), desired)));
    const dossierPatch = Object.fromEntries(Object.entries(source.dossier)
      .filter(([key, desired]) => !same(value(existingDossier, key), desired)));
    if (Object.keys(beneficiaryPatch).length || Object.keys(dossierPatch).length) {
      operations.push({ kind: 'update', source, existingDossier, beneficiary,
        beneficiaryPatch, dossierPatch });
    }
  }

  let created = 0;
  let updated = 0;
  for (const operation of operations.slice(0, maxChanges)) {
    if (operation.kind === 'create') {
      const beneficiary = await createBeneficiary({
        ...operation.source.beneficiary,
        app_sync_revision: crypto.randomUUID(),
      });
      if (!beneficiary?.id) throw new Error('Création du bénéficiaire non confirmée');
      const dossier = await createDossier({
        uuid_source: operation.uuid,
        patient_id: `nocodb-beneficiaire-${beneficiary.id}`,
        beneficiaires_id: Number(beneficiary.id),
        ergo_id: 'Coralie',
        status: 'À visiter',
        ...operation.source.dossier,
        created_at: new Date().toISOString(),
        app_sync_revision: crypto.randomUUID(),
      });
      if (!dossier?.id) throw new Error('Création du dossier non confirmée');
      created += 1;
    } else {
      if (Object.keys(operation.beneficiaryPatch).length) {
        await updateBeneficiary(operation.beneficiary, operation.beneficiaryPatch);
      }
      if (Object.keys(operation.dossierPatch).length) {
        await updateDossier(operation.existingDossier, operation.dossierPatch);
      }
      updated += 1;
    }
  }
  return {
    eligible: eligible.length,
    created,
    updated,
    unchanged: eligible.length - operations.length - skipped.length,
    remaining: Math.max(0, operations.length - maxChanges),
    skipped,
  };
}

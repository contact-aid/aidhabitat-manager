import crypto from 'node:crypto';
import { mapPatient } from './helpers.mjs';
import { isCurrentAdaptationDossier, projectAirtableDossier } from './airtableAdaptation.mjs';

const value = (record, key) => record?.fields?.[key] ?? record?.[key];
const normalized = (input) => String(input ?? '').trim().replace(/\s+/g, ' ');
const same = (left, right) => normalized(left) === normalized(right);
const isEmpty = (input) => input == null || (typeof input === 'string' && !input.trim());
const validYear = (raw) => /^(18|19|20)\d{2}$/.test(String(raw ?? '').trim())
  ? String(raw).trim() : '';
const labelId = (rows, label) => rows.find((row) =>
  same(value(row, 'libelle'), label))?.id;
const housingPrefill = (source, housingTypes) => {
  const patch = {};
  const type = labelId(housingTypes, source.housing.typology);
  if (type) patch.type_de_logement_id = Number(type);
  const construction = validYear(source.housing.yearConstruction);
  if (construction) patch.annee_construction = construction;
  const purchase = validYear(source.housing.purchaseYear);
  if (purchase) patch.annee_habitation = purchase;
  return patch;
};

const baremeFor = (records, householdSize) => {
  const size = Number(householdSize);
  if (!Number.isSafeInteger(size) || size <= 0) return null;
  const candidates = records.filter((row) => Number(value(row, 'nombre_personnes')) <= size);
  candidates.sort((a, b) => {
    const exactA = Number(value(a, 'nombre_personnes')) === size ? 1 : 0;
    const exactB = Number(value(b, 'nombre_personnes')) === size ? 1 : 0;
    return exactB - exactA
      || Number(value(b, 'annee_plafond') || 0) - Number(value(a, 'annee_plafond') || 0)
      || Number(value(b, 'nombre_personnes')) - Number(value(a, 'nombre_personnes'));
  });
  return candidates[0] ?? null;
};

// Import the validated recent, non-cancelled cohort for the authenticated
// profile. Airtable remains read only.
export async function syncCurrentProfileDossiers({
  ergoLabel,
  sourceRows, dossierRows, beneficiaryRows, housingRows = [], housingTypes = [],
  occupationTypes = [], baremeRows = [], createBeneficiary, createDossier,
  updateBeneficiary, updateDossier, createHousing, updateHousing,
  maxChanges = 5, enhancedWeb = true, dryRun = false, selectedIds = null,
}) {
  if (!ergoLabel?.trim()) throw new TypeError('Profil intervenant requis');
  const eligible = sourceRows.filter(isCurrentAdaptationDossier)
    .map((row) => projectAirtableDossier(row, { enhancedWeb }));
  for (const source of enhancedWeb ? eligible : []) {
    const bareme = baremeFor(baremeRows, source.beneficiary.nombre_personnes);
    if (bareme?.id && Number.isSafeInteger(Number(bareme.id))) {
      source.beneficiary.categorie_revenu_id1 = Number(bareme.id);
    }
  }
  const dossiersByUuid = new Map(dossierRows.map((row) => [normalized(value(row, 'uuid_source')), row]));
  const beneficiariesById = new Map(beneficiaryRows.map((row) => [String(row.id), row]));
  const housingByBeneficiary = new Map(housingRows.map((row) =>
    [String(value(row, 'beneficiaires_id')), row]));
  const operations = [];
  const skipped = [];

  for (const source of eligible) {
    if (selectedIds && !selectedIds.has(source.airtableRecordId)) continue;
    const uuid = `airtable:${source.airtableRecordId}`;
    const existingDossier = dossiersByUuid.get(uuid);
    if (!existingDossier) {
      if (!source.beneficiary.prenom || !source.beneficiary.nom || !source.airtableClientRecordId) {
        skipped.push({ id: source.airtableRecordId, reason: 'fiche client incomplète' });
        continue;
      }
      if (enhancedWeb && source.beneficiaryGender) {
        const occupants = mapPatient({ fields: source.beneficiary }, '').occupants;
        occupants[0].gender = source.beneficiaryGender;
        source.beneficiary.occupants_json = JSON.stringify(occupants);
      }
      operations.push({ kind: 'create', source, uuid });
      continue;
    }
    const beneficiary = beneficiariesById.get(String(value(existingDossier, 'beneficiaires_id')));
    if (!beneficiary) {
      skipped.push({ id: source.airtableRecordId, reason: 'bénéficiaire introuvable' });
      continue;
    }
    const beneficiaryPatch = Object.fromEntries(Object.entries(source.beneficiary)
      .filter(([key]) => isEmpty(value(beneficiary, key))));
    if (enhancedWeb && source.beneficiaryGender) {
      const raw = value(beneficiary, 'occupants_json');
      let occupants;
      try { occupants = JSON.parse(raw || '[]'); } catch { /* preserve malformed data */ }
      if (Array.isArray(occupants) && occupants.length === 0) {
        // Hydrate the complete legacy household before creating JSON: birthdays,
        // medical data, pensions and the second identity must survive the import.
        occupants = mapPatient({ ...beneficiary, fields: {
          ...(beneficiary.fields ?? beneficiary), ...beneficiaryPatch,
        } }, beneficiary.id).occupants;
      }
      if (Array.isArray(occupants) && occupants[0]
        && typeof occupants[0] === 'object'
        && !Object.hasOwn(occupants[0], 'gender')
        && same(occupants[0].firstName, source.beneficiary.prenom)
        && same(occupants[0].lastName, source.beneficiary.nom)) {
        beneficiaryPatch.occupants_json = JSON.stringify([
          { ...occupants[0], gender: source.beneficiaryGender }, ...occupants.slice(1),
        ]);
      }
    }
    if (enhancedWeb && same(source.housing.ownerType, 'Propriétaire occupant')) {
      const ownerId = labelId(occupationTypes, 'Propriétaire');
      if (ownerId && isEmpty(value(beneficiary, 'statut_occupation_id1'))) {
        beneficiaryPatch.statut_occupation_id1 = Number(ownerId);
      }
    }
    const dossierPatch = Object.fromEntries(Object.entries(source.dossier)
      .filter(([key]) => isEmpty(value(existingDossier, key))));
    // Ownership follows the verified Airtable assignment; all other existing
    // dossier fields remain fill-only, including notes and visit work.
    if (!same(value(existingDossier, 'ergo_id'), ergoLabel)) {
      dossierPatch.ergo_id = ergoLabel;
    }
    const housing = housingByBeneficiary.get(String(value(existingDossier, 'beneficiaires_id')));
    const housingPatch = enhancedWeb ? Object.fromEntries(
      Object.entries(housingPrefill(source, housingTypes)).filter(([key]) =>
        isEmpty(value(housing, key)))) : {};
    if (source.hasAirtableReport && isEmpty(value(existingDossier, 'status'))) {
      dossierPatch.status = 'En cours';
    }
    if (Object.keys(beneficiaryPatch).length || Object.keys(dossierPatch).length
      || Object.keys(housingPatch).length) {
      operations.push({ kind: 'update', source, existingDossier, beneficiary,
        beneficiaryPatch, dossierPatch, housing, housingPatch });
    }
  }

  const changes = operations.map((operation) => ({
    id: operation.source.airtableRecordId,
    profile: ergoLabel,
    name: [operation.source.beneficiary.prenom, operation.source.beneficiary.nom]
      .filter(Boolean).join(' ') || operation.source.airtableDossierLabel || operation.source.airtableRecordId,
    kind: operation.kind,
    previousOwner: operation.kind === 'update' && operation.dossierPatch.ergo_id
      ? normalized(value(operation.existingDossier, 'ergo_id')) : '',
    fields: operation.kind === 'create'
      ? { beneficiary: operation.source.beneficiary,
        dossier: { ...operation.source.dossier,
          status: operation.source.hasAirtableReport ? 'En cours' : 'À visiter' },
        housing: enhancedWeb ? housingPrefill(operation.source, housingTypes) : {} }
      : { beneficiary: operation.beneficiaryPatch, dossier: operation.dossierPatch,
        housing: operation.housingPatch },
  }));
  if (dryRun) return { eligible: eligible.length, created: 0, updated: 0,
    unchanged: eligible.length - operations.length - skipped.length,
    remaining: 0, skipped, changes };
  let created = 0;
  let updated = 0;
  for (const operation of operations.slice(0, maxChanges)) {
    if (operation.kind === 'create') {
      const beneficiary = await createBeneficiary({
        ...operation.source.beneficiary,
        ...(enhancedWeb && same(operation.source.housing.ownerType, 'Propriétaire occupant')
          && labelId(occupationTypes, 'Propriétaire')
          ? { statut_occupation_id1: Number(labelId(occupationTypes, 'Propriétaire')) }
          : {}),
        app_sync_revision: crypto.randomUUID(),
      });
      if (!beneficiary?.id) throw new Error('Création du bénéficiaire non confirmée');
      const dossier = await createDossier({
        uuid_source: operation.uuid,
        patient_id: `nocodb-beneficiaire-${beneficiary.id}`,
        beneficiaires_id: Number(beneficiary.id),
        ergo_id: ergoLabel,
        status: operation.source.hasAirtableReport ? 'En cours' : 'À visiter',
        ...operation.source.dossier,
        created_at: new Date().toISOString(),
        app_sync_revision: crypto.randomUUID(),
      });
      if (!dossier?.id) throw new Error('Création du dossier non confirmée');
      const housingFields = enhancedWeb ? housingPrefill(operation.source, housingTypes) : {};
      if (Object.keys(housingFields).length && createHousing) {
        await createHousing({
          uuid_source: crypto.randomUUID(),
          beneficiaire_id: `nocodb-beneficiaire-${beneficiary.id}`,
          beneficiaires_id: Number(beneficiary.id),
          ...housingFields,
          app_sync_revision: crypto.randomUUID(),
        });
      }
      created += 1;
    } else {
      if (Object.keys(operation.beneficiaryPatch).length) {
        await updateBeneficiary(operation.beneficiary, operation.beneficiaryPatch);
      }
      if (Object.keys(operation.dossierPatch).length) {
        await updateDossier(operation.existingDossier, operation.dossierPatch);
      }
      if (Object.keys(operation.housingPatch).length) {
        if (operation.housing) {
          await updateHousing(operation.housing, operation.housingPatch);
        } else if (createHousing) {
          await createHousing({
            uuid_source: crypto.randomUUID(),
            beneficiaire_id: `nocodb-beneficiaire-${operation.beneficiary.id}`,
            beneficiaires_id: Number(operation.beneficiary.id),
            ...operation.housingPatch,
            app_sync_revision: crypto.randomUUID(),
          });
        }
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
    skipped, changes,
  };
}

export const syncCurrentCoralieDossiers = (options) =>
  syncCurrentProfileDossiers({ ergoLabel: 'Coralie', ...options });

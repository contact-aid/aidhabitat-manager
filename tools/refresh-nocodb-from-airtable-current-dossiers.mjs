#!/usr/bin/env node
import fs from 'node:fs/promises';
import path from 'node:path';
import dotenv from 'dotenv';
import {
  TABLES,
  FIELD_SETS,
  closeMcpClient,
  field,
  findByLabel,
  normalizeLabelForMatch,
  queryAll,
  selectBaremeAnah,
  updateRecord,
} from '../server/helpers.mjs';

dotenv.config({ path: '.env.local' });
dotenv.config();

const DOSSIER_FIELDS = {
  label: 'fldsef4Hl0K4JWhJ6',
  clientLink: 'fldg4kX4jfOgwee0n',
  ergoShort: 'fldQIh3epmfnX9uDy',
  visitDate: 'fldGNSD8cKxuhmPb6',
  nature: 'fldPFsYbjPXGXRieJ',
  ownerStatus: 'fldtD9SclmlFZMI9w',
};

const CLIENT_FIELDS = {
  firstName: 'fldc6Wl3eXeP9AipC',
  lastName: 'fldpwndl965UgxeWg',
  phone: 'fldPQQKeKtEpc8sxh',
  email: 'fldBlRfdJcLkxYK67',
  address: 'fldJbW0r4WZ2uPGYs',
  city: 'fldJobkrZzEpB8YrA',
  zipCode: 'fldFpzAMQ2gCj4X2e',
  householdSize: 'fld3gCahEtojDdNgz',
  fiscalRevenue: 'fldLfNU088ve0UmMy',
  category: 'fldxB1VxyVFLgm8dA',
  civility: 'fldI5dwnLn0A7kBPZ',
  birthDate: 'fldvpuNvKjBXvEQBw',
};

const DEFAULT_DOSSIERS_JSON = 'tmp/airtable-refresh/crm-current-dossiers-airtable.json';
const DEFAULT_LINKS_JSON = 'tmp/airtable-refresh/crm-current-dossier-client-links-airtable.json';
const DEFAULT_CLIENTS_JSON = 'tmp/airtable-refresh/crm-current-clients-airtable.json';
const DEFAULT_PLAN_JSON = 'tmp/airtable-refresh/airtable-to-nocodb-plan.json';

const args = process.argv.slice(2);
const hasFlag = (flag) => args.includes(flag);
const optionValue = (name, fallback) => {
  const index = args.indexOf(name);
  return index >= 0 && args[index + 1] ? args[index + 1] : fallback;
};

const shouldApply = hasFlag('--apply');
const planPath = optionValue('--plan', DEFAULT_PLAN_JSON);
const dossiersPath = optionValue('--dossiers', DEFAULT_DOSSIERS_JSON);
const linksPath = optionValue('--links', DEFAULT_LINKS_JSON);
const clientsPath = optionValue('--clients', DEFAULT_CLIENTS_JSON);
const now = new Date().toISOString().replace(/[:.]/g, '-');
const backupPath = optionValue('--backup', `tmp/airtable-refresh/nocodb-before-airtable-refresh-${now}.json`);

const asArray = (value) => Array.isArray(value) ? value : [];
const normalizeString = (value) => String(value ?? '').trim().replace(/\s+/g, ' ');
const nullableString = (value) => {
  const normalized = normalizeString(value);
  return normalized ? normalized : null;
};

const firstCellValue = (value) => {
  if (value == null) return null;

  if (Array.isArray(value)) {
    for (const item of value) {
      const extracted = firstCellValue(item);
      if (extracted != null && String(extracted).trim() !== '') return extracted;
    }
    return null;
  }

  if (typeof value === 'object') {
    if (Object.prototype.hasOwnProperty.call(value, 'name')) return value.name;
    if (Object.prototype.hasOwnProperty.call(value, 'value')) return firstCellValue(value.value);
    if (Array.isArray(value.linkedRecordIds) && value.valuesByLinkedRecordId) {
      for (const recordId of value.linkedRecordIds) {
        const extracted = firstCellValue(value.valuesByLinkedRecordId[recordId]);
        if (extracted != null && String(extracted).trim() !== '') return extracted;
      }
    }
    return null;
  }

  return value;
};

const cell = (record, fieldId) => firstCellValue(record?.cellValuesByFieldId?.[fieldId]);
const linkIds = (record, fieldId) => asArray(record?.cellValuesByFieldId?.[fieldId])
  .map((item) => String(item?.id || '').trim())
  .filter(Boolean);

const normalizeEmailValue = (value) => {
  const email = normalizeString(value).toLowerCase();
  if (!email) return null;
  if (!email.includes('@')) return null;
  if (/^(aucun|sans|pas\.?de|pas-de|non|neant|néant|na|n\/a)@/i.test(email)) return null;
  return email;
};

const normalizePhoneValue = (value) => {
  const phone = String(value ?? '').replace(/\D/g, '');
  return phone || null;
};

const normalizeIntegerValue = (value) => {
  const parsed = Number.parseInt(String(value ?? '').replace(/\D/g, ''), 10);
  return Number.isFinite(parsed) ? parsed : null;
};

const normalizeNumberValue = (value) => {
  if (value == null || value === '') return null;
  const parsed = Number(String(value).replace(/\s/g, '').replace(',', '.'));
  return Number.isFinite(parsed) ? parsed : null;
};

const normalizeErgo = (value) => {
  const normalized = normalizeLabelForMatch(value);
  if (!normalized) return null;
  if (normalized.includes('coralie')) return 'Coralie';
  if (normalized.includes('christelle')) return 'Christelle';
  return null;
};

const normalizeNature = (value) => {
  const normalized = normalizeLabelForMatch(value);
  if (!normalized) return null;
  if (normalized.includes('complet')) return 'complet';
  if (normalized.includes('ergo')) return 'ergo';
  if (normalized.includes('mixte')) return 'mixte';
  if (normalized.includes('socle')) return 'socle';
  return null;
};

const normalizeOwnerStatus = (value) => {
  const normalized = normalizeLabelForMatch(value);
  if (!normalized) return null;
  if (normalized.includes('locataire')) return 'Locataire';
  if (normalized.includes('usufruit')) return 'Usufruitier(e)';
  if (normalized.includes('proprietaire')) return 'Propriétaire';
  return null;
};

const normalizeDateString = (value) => {
  const date = normalizeString(value);
  return date || null;
};

const normalizeCategory = (value) => normalizeString(value)
  .replace(/[✔️✅☑︎☑]/g, '')
  .trim()
  .replace(/\s+/g, ' ') || null;

const sameValue = (left, right) => {
  const normalizeComparable = (value) => {
    if (value == null || value === '') return null;
    if (typeof value === 'number') return value;
    return normalizeString(value);
  };
  return normalizeComparable(left) === normalizeComparable(right);
};

const buildDiff = (record, desired) => {
  const changes = {};
  for (const [key, value] of Object.entries(desired)) {
    if (!sameValue(field(record, key), value)) {
      changes[key] = { from: field(record, key) ?? null, to: value };
    }
  }
  return changes;
};

const changedFieldsOnly = (changes) => Object.fromEntries(
  Object.entries(changes).map(([key, value]) => [key, value.to])
);

const readJson = async (filePath) => JSON.parse(await fs.readFile(filePath, 'utf8'));

const labelFor = (record) => [
  normalizeString(cell(record, CLIENT_FIELDS.firstName)),
  normalizeString(cell(record, CLIENT_FIELDS.lastName)),
].filter(Boolean).join(' ');

const main = async () => {
  const [airtableDossiers, airtableLinks, airtableClients] = await Promise.all([
    readJson(dossiersPath),
    readJson(linksPath),
    readJson(clientsPath),
  ]);

  const [
    beneficiaires,
    dossiers,
    situations,
    statuts,
    baremesAnah,
  ] = await Promise.all([
    queryAll(TABLES.beneficiaires, {
      fields: [
        ...FIELD_SETS.beneficiaires,
        'situation_proprietaire_id1',
        'statut_occupation_id1',
        'categorie_revenu_id1',
        'revenu_fiscal_reference',
      ],
    }),
    queryAll(TABLES.dossiers, { fields: FIELD_SETS.dossiers }),
    queryAll(TABLES.situationProprietaire, { fields: FIELD_SETS.referencesLibelle }),
    queryAll(TABLES.statutOccupation, { fields: FIELD_SETS.referencesLibelle }),
    queryAll(TABLES.baremesAnah, { fields: FIELD_SETS.baremesAnah }),
  ]);

  const currentByAirtableDossierId = new Map(
    dossiers
      .map((record) => [String(field(record, 'uuid_source') || '').replace(/^airtable:/, ''), record])
      .filter(([sourceId]) => sourceId)
  );
  const beneficiariesById = new Map(beneficiaires.map((record) => [String(record.id), record]));
  const clientById = new Map(airtableClients.records.map((record) => [record.id, record]));
  const linksByDossierId = new Map(airtableLinks.records.map((record) => [record.id, record]));

  const plan = {
    generatedAt: new Date().toISOString(),
    mode: shouldApply ? 'apply' : 'dry-run',
    source: {
      dossiersPath,
      linksPath,
      clientsPath,
      airtableDossierRecords: airtableDossiers.records.length,
      airtableClientRecords: airtableClients.records.length,
    },
    backupPath: shouldApply ? backupPath : null,
    summary: {
      matchedDossiers: 0,
      missingNocodbDossiers: 0,
      missingNocodbBeneficiaries: 0,
      missingAirtableClients: 0,
      beneficiaryRecordsToUpdate: 0,
      dossierRecordsToUpdate: 0,
      skippedUnknownErgo: 0,
      skippedUnknownOwnerStatus: 0,
      skippedFields: {
        civility: 'Airtable M./Mme is not mapped to an app field in this sync.',
        categoryLabel: 'Airtable category is checked for audit only; the app computes it from RFR + barème.',
        compteAnah: 'App compte_anah stores structured account/mandate state; Airtable link/reference is ambiguous and is not written.',
      },
    },
    updates: [],
    warnings: [],
  };

  for (const airtableDossier of airtableDossiers.records) {
    const sourceDossierId = airtableDossier.id;
    const nocodbDossier = currentByAirtableDossierId.get(sourceDossierId);
    const linkRecord = linksByDossierId.get(sourceDossierId);
    const clientId = linkIds(linkRecord, DOSSIER_FIELDS.clientLink)[0];
    const airtableClient = clientById.get(clientId);
    const dossierLabel = normalizeString(cell(airtableDossier, DOSSIER_FIELDS.label));

    if (!nocodbDossier) {
      plan.summary.missingNocodbDossiers += 1;
      plan.warnings.push({ sourceDossierId, dossierLabel, reason: 'Dossier NocoDB introuvable pour ce RecordID Airtable.' });
      continue;
    }

    const beneficiary = beneficiariesById.get(String(field(nocodbDossier, 'beneficiaires_id') || ''));
    if (!beneficiary) {
      plan.summary.missingNocodbBeneficiaries += 1;
      plan.warnings.push({ sourceDossierId, dossierLabel, nocodbDossierId: nocodbDossier.id, reason: 'Bénéficiaire NocoDB introuvable.' });
      continue;
    }

    if (!airtableClient) {
      plan.summary.missingAirtableClients += 1;
      plan.warnings.push({ sourceDossierId, dossierLabel, nocodbDossierId: nocodbDossier.id, reason: 'Fiche client Airtable liée introuvable.' });
      continue;
    }

    plan.summary.matchedDossiers += 1;

    const householdSize = normalizeIntegerValue(cell(airtableClient, CLIENT_FIELDS.householdSize));
    const baremeMatch = householdSize ? selectBaremeAnah(baremesAnah, householdSize) : undefined;
    const ownerStatus = normalizeOwnerStatus(cell(airtableDossier, DOSSIER_FIELDS.ownerStatus));
    const ownerStatusMatch = ownerStatus ? findByLabel(statuts, ownerStatus) : undefined;
    const ergo = normalizeErgo(cell(airtableDossier, DOSSIER_FIELDS.ergoShort));
    const categoryLabel = normalizeCategory(cell(airtableClient, CLIENT_FIELDS.category));

    if (!ergo) plan.summary.skippedUnknownErgo += 1;
    if (cell(airtableDossier, DOSSIER_FIELDS.ownerStatus) && !ownerStatusMatch) {
      plan.summary.skippedUnknownOwnerStatus += 1;
    }

    const desiredBeneficiary = {
      prenom: nullableString(cell(airtableClient, CLIENT_FIELDS.firstName)),
      nom: nullableString(cell(airtableClient, CLIENT_FIELDS.lastName)),
      mail: normalizeEmailValue(cell(airtableClient, CLIENT_FIELDS.email)),
      telephone: normalizePhoneValue(cell(airtableClient, CLIENT_FIELDS.phone)),
      adresse_logement: nullableString(cell(airtableClient, CLIENT_FIELDS.address)),
      ville_libre: nullableString(cell(airtableClient, CLIENT_FIELDS.city)),
      code_postal_libre: nullableString(cell(airtableClient, CLIENT_FIELDS.zipCode)),
      nombre_personnes: householdSize,
      revenu_fiscal_reference: normalizeNumberValue(cell(airtableClient, CLIENT_FIELDS.fiscalRevenue)),
      statut_occupation_id1: ownerStatusMatch ? Number(ownerStatusMatch.id) : null,
      categorie_revenu_id1: baremeMatch ? Number(baremeMatch.id) : null,
    };

    const civility = normalizeString(cell(airtableClient, CLIENT_FIELDS.civility));
    const birthDate = normalizeDateString(cell(airtableClient, CLIENT_FIELDS.birthDate));
    if (birthDate && normalizeLabelForMatch(civility) === 'monsieur') {
      desiredBeneficiary.date_naissance_monsieur = birthDate;
      desiredBeneficiary.date_naissance_madame = null;
    } else if (birthDate && normalizeLabelForMatch(civility) === 'madame') {
      desiredBeneficiary.date_naissance_monsieur = null;
      desiredBeneficiary.date_naissance_madame = birthDate;
    }

    const desiredDossier = {
      ergo_id: ergo,
      visit_date: normalizeDateString(cell(airtableDossier, DOSSIER_FIELDS.visitDate)),
      nature_accompagnement: normalizeNature(cell(airtableDossier, DOSSIER_FIELDS.nature)),
    };

    const beneficiaryChanges = buildDiff(beneficiary, desiredBeneficiary);
    const dossierChanges = buildDiff(nocodbDossier, desiredDossier);

    if (Object.keys(beneficiaryChanges).length > 0) {
      plan.summary.beneficiaryRecordsToUpdate += 1;
    }
    if (Object.keys(dossierChanges).length > 0) {
      plan.summary.dossierRecordsToUpdate += 1;
    }

    plan.updates.push({
      sourceDossierId,
      dossierLabel,
      sourceClientId: airtableClient.id,
      sourceClientLabel: labelFor(airtableClient),
      expectedCategoryFromAirtable: categoryLabel,
      nocodb: {
        dossierId: String(nocodbDossier.id),
        beneficiaryId: String(beneficiary.id),
      },
      beneficiaryChanges,
      dossierChanges,
    });
  }

  await fs.mkdir(path.dirname(planPath), { recursive: true });
  await fs.writeFile(planPath, JSON.stringify(plan, null, 2));

  if (shouldApply) {
    const backup = {
      generatedAt: new Date().toISOString(),
      beneficiaires,
      dossiers,
    };
    await fs.mkdir(path.dirname(backupPath), { recursive: true });
    await fs.writeFile(backupPath, JSON.stringify(backup, null, 2));

    for (const update of plan.updates) {
      if (Object.keys(update.beneficiaryChanges).length > 0) {
        await updateRecord(TABLES.beneficiaires, update.nocodb.beneficiaryId, changedFieldsOnly(update.beneficiaryChanges));
      }
      if (Object.keys(update.dossierChanges).length > 0) {
        await updateRecord(TABLES.dossiers, update.nocodb.dossierId, changedFieldsOnly(update.dossierChanges));
      }
    }
  }

  console.log(JSON.stringify({
    mode: plan.mode,
    planPath: path.resolve(planPath),
    backupPath: shouldApply ? path.resolve(backupPath) : null,
    summary: plan.summary,
    warnings: plan.warnings,
  }, null, 2));
};

main()
  .catch((error) => {
    console.error(error);
    process.exitCode = 1;
  })
  .finally(async () => {
    await closeMcpClient().catch(() => undefined);
  });

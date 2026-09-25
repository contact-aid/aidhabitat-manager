import { isDeepStrictEqual } from 'node:util';

import {
  planDatabaseMutation,
  SYNC_REVISION_FIELD,
  SyncMutationError,
} from './guardedMutation.mjs';
import {
  AUTONOMY_ITEMS,
  autonomyChecklistToMap,
  normalizeAutonomyChecklist,
} from '../shared/autonomyContract.js';

const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const allowedSections = new Set(['medicalContext', 'autonomy']);

const sourceOf = (record) => record?.fields && typeof record.fields === 'object'
  ? { Id: Number(record.id), ...record.fields }
  : record;
const stringValue = (value) => value == null ? '' : String(value);
const nullableString = (value) => value == null || value === '' ? null : String(value);
const boolValue = (value) => value === true || value === 1
  || ['1', 'true', 'oui', 'yes', 'x'].includes(stringValue(value).trim().toLowerCase());
const plainObject = (value) => value && Object.getPrototypeOf(value) === Object.prototype;

const normalizedMedical = (value, { strict = false } = {}) => {
  const source = plainObject(value) ? value : {};
  if (strict) {
    for (const key of ['pathology', 'followUp', 'sensory', 'heightCm', 'weightKg']) {
      if (source[key] != null && typeof source[key] !== 'string') {
        throw new SyncMutationError(400, 'CONTEXT_MEDICAL_INVALID');
      }
    }
  }
  return {
    pathology: stringValue(source.pathology),
    followUp: stringValue(source.followUp),
    sensory: stringValue(source.sensory),
    heightCm: stringValue(source.heightCm),
    weightKg: stringValue(source.weightKg),
  };
};

const validateChecklist = (value) => Array.isArray(value)
  && value.every((entry) => plainObject(entry)
    && typeof entry.name === 'string'
    && AUTONOMY_ITEMS.includes(entry.name)
    && typeof entry.checked === 'boolean')
  && new Set(value.map((entry) => entry.name)).size === value.length;

const normalizedOccupants = (value, { strict = false } = {}) => {
  const source = Array.isArray(value) ? value : [];
  if (strict && (!Array.isArray(value) || source.some((entry) => !plainObject(entry)
      || typeof entry.autonomyDone !== 'boolean'
      || !validateChecklist(entry.autonomy)
      || !validateChecklist(entry.attention)
      || !validateChecklist(entry.humanHelp)))) {
    throw new SyncMutationError(400, 'CONTEXT_OCCUPANTS_INVALID');
  }
  return source.filter(plainObject)
  .map((entry) => ({
    medical: normalizedMedical(entry.medical, { strict }),
    autonomyDone: strict ? entry.autonomyDone : boolValue(entry.autonomyDone),
    autonomy: normalizeAutonomyChecklist(entry.autonomy),
    attention: normalizeAutonomyChecklist(entry.attention),
    humanHelp: normalizeAutonomyChecklist(entry.humanHelp),
  }));
};

const normalizedAutonomy = (value, { strict = false } = {}) => {
  const source = plainObject(value) ? value : {};
  if (strict && (typeof source.done !== 'boolean'
      || !validateChecklist(source.checklist)
      || !Array.isArray(source.occupants))) {
    throw new SyncMutationError(400, 'CONTEXT_AUTONOMY_INVALID');
  }
  return {
    done: strict ? source.done : boolValue(source.done),
    checklist: normalizeAutonomyChecklist(source.checklist),
    occupants: normalizedOccupants(source.occupants, { strict }),
  };
};

const canonicalSections = (sections, { strict = false } = {}) => {
  assertSectionMap(sections, strict ? 'INPUT' : 'VALUES');
  return Object.fromEntries(Object.entries(sections).map(([key, value]) => [
    key,
    key === 'medicalContext'
      ? normalizedMedical(value, { strict })
      : normalizedAutonomy(value, { strict }),
  ]));
};

const assertSectionMap = (sections, label) => {
  if (!plainObject(sections)) {
    throw new SyncMutationError(400, `CONTEXT_${label}_INVALID`);
  }
  for (const key of Object.keys(sections)) {
    if (!allowedSections.has(key) || !plainObject(sections[key])) {
      throw new SyncMutationError(400, `CONTEXT_${label}_INVALID`);
    }
  }
};

export const CONTEXT_RECORD_FIELDS = Object.freeze([
  'Id', 'uuid_source', 'dossier_id', 'beneficiaire_id', 'dossiers_id',
  'beneficiaires_id', 'nom_pathologie', 'suivi_medical',
  'pathologie_maladie', 'maladie_evolutive', 'frequence_suivi_medical',
  'deficience_auditive_visuelle', 'deficience_auditive',
  'deficience_visuelle', 'taille_approximative', 'poids_exact',
  'surcharge_pondérale', 'utilise_fauteuil', 'utilise_canne',
  'utilise_deambulateur',
  'aide_technique_deplacement', 'difficultes_escalier',
  'restrictions_conduite', 'autonomie_toilette', 'autonomie_repas',
  'autonomie_menage', 'autonomie_demarches_admin', 'occupants_json',
  SYNC_REVISION_FIELD, 'UpdatedAt', 'updated_at', 'CreatedAt',
]);

const primaryDatabaseFields = Object.freeze([
  'nom_pathologie', 'suivi_medical', 'deficience_auditive_visuelle',
  'taille_approximative', 'poids_exact', 'aide_technique_deplacement',
  'difficultes_escalier', 'restrictions_conduite', 'autonomie_toilette',
  'autonomie_repas', 'autonomie_menage', 'autonomie_demarches_admin',
  'occupants_json',
]);
const legacyDatabaseFields = Object.freeze([
  'pathologie_maladie', 'maladie_evolutive', 'frequence_suivi_medical',
  'deficience_auditive', 'deficience_visuelle', 'surcharge_pondérale',
  'utilise_fauteuil', 'utilise_canne', 'utilise_deambulateur',
]);

const selectFields = (row, names) => Object.fromEntries(
  names.map((name) => [name, row[name] ?? null]),
);

/** Raw storage state is intentionally separate from the UI representation. */
export function contextRecordDatabaseState(record) {
  const row = sourceOf(record) || {};
  return {
    primary: selectFields(row, primaryDatabaseFields),
    legacy: selectFields(row, legacyDatabaseFields),
  };
}

const hasInvalidOccupantsStorage = (record) => {
  const raw = stringValue(sourceOf(record)?.occupants_json).trim();
  if (!raw) return false;
  try {
    const parsed = JSON.parse(raw);
    return !Array.isArray(parsed) || parsed.some((entry) => !plainObject(entry));
  } catch {
    return true;
  }
};

export function contextSectionsToDatabaseFields(sections) {
  const canonical = canonicalSections(sections, { strict: true });
  const fields = {};
  if (Object.hasOwn(canonical, 'medicalContext')) {
    const medical = canonical.medicalContext;
    fields.nom_pathologie = nullableString(medical.pathology);
    fields.suivi_medical = nullableString(medical.followUp);
    fields.deficience_auditive_visuelle = nullableString(medical.sensory);
    fields.taille_approximative = nullableString(medical.heightCm);
    fields.poids_exact = nullableString(medical.weightKg);
  }
  if (Object.hasOwn(canonical, 'autonomy')) {
    const autonomy = canonical.autonomy;
    const checklist = autonomyChecklistToMap(autonomy.checklist);
    fields.aide_technique_deplacement = Boolean(checklist.get('Déplacements/transferts'));
    fields.difficultes_escalier = checklist.get('Escaliers') ? 'Oui' : '';
    fields.restrictions_conduite = checklist.get('Conduite automobile') ? 'Oui' : '';
    fields.autonomie_toilette = checklist.get('Toilette/habillage') ? 'Oui' : '';
    fields.autonomie_repas = checklist.get('Repas (y compris courses)') ? 'Oui' : '';
    fields.autonomie_menage = checklist.get('Tâches ménagères') ? 'Oui' : '';
    fields.autonomie_demarches_admin = checklist.get('Démarches admin') ? 'Oui' : '';
    fields.occupants_json = autonomy.occupants.length
      ? JSON.stringify(autonomy.occupants)
      : null;
  }
  return fields;
}

export function contextRecordToSections(record) {
  const row = sourceOf(record) || {};
  const medicalContext = normalizedMedical({
    pathology: [row.nom_pathologie, row.pathologie_maladie, row.maladie_evolutive]
      .filter(Boolean).join(' • '),
    followUp: [row.suivi_medical, row.frequence_suivi_medical]
      .filter(Boolean).join(' • '),
    sensory: [row.deficience_auditive_visuelle, row.deficience_auditive, row.deficience_visuelle]
      .filter(Boolean).join(' • '),
    heightCm: stringValue(row.taille_approximative).replace(/[^\d.,]/g, '').replace(',', '.'),
    weightKg: stringValue(row.poids_exact).replace(/[^\d.,]/g, '').replace(',', '.'),
  });
  let occupants = [];
  if (stringValue(row.occupants_json).trim()) {
    try {
      occupants = normalizedOccupants(JSON.parse(row.occupants_json));
    } catch {
      occupants = [];
    }
  }
  const fallbackChecklist = AUTONOMY_ITEMS.map((name) => ({
    name,
    checked: Boolean({
      'Déplacements/transferts': boolValue(row.aide_technique_deplacement)
        || boolValue(row.utilise_fauteuil) || boolValue(row.utilise_canne)
        || boolValue(row.utilise_deambulateur),
      Escaliers: boolValue(row.difficultes_escalier),
      'Conduite automobile': boolValue(row.restrictions_conduite),
      'Toilette/habillage': boolValue(row.autonomie_toilette),
      'Repas (y compris courses)': boolValue(row.autonomie_repas),
      'Tâches ménagères': boolValue(row.autonomie_menage),
      'Démarches admin': boolValue(row.autonomie_demarches_admin),
    }[name]),
  }));
  const checklist = occupants[0]?.autonomy || fallbackChecklist;
  return {
    medicalContext,
    autonomy: {
      done: occupants.length > 0
        ? occupants[0].autonomyDone
        : checklist.some((item) => item.checked),
      checklist,
      occupants,
    },
  };
}

export function contextServerReference(record) {
  const row = sourceOf(record);
  const recordId = Number(row?.Id);
  const revision = row?.[SYNC_REVISION_FIELD];
  if (!Number.isSafeInteger(recordId) || recordId <= 0 || !uuidPattern.test(revision ?? '')) {
    throw new SyncMutationError(503, 'CONTEXT_REFERENCE_NOT_PREPARED');
  }
  const updatedAt = row.UpdatedAt || row.updated_at || row.CreatedAt || null;
  return { recordId, revision, updatedAt };
}

export class ContextCreateUncertainError extends Error {
  constructor(cause) {
    super('Context creation could not be confirmed; retain the same mutation and writeId', { cause });
    this.name = 'ContextCreateUncertainError';
    this.code = 'CONTEXT_CREATE_UNCONFIRMED';
    this.status = 503;
    this.statusCode = 503;
  }
}

const validateConcurrency = (value) => {
  if (!plainObject(value) || value.version !== 1 || !uuidPattern.test(value.writeId ?? '')) {
    throw new SyncMutationError(428, 'CONTEXT_CONCURRENCY_REQUIRED');
  }
  assertSectionMap(value.baseValues, 'BASELINE');
  if (!Object.hasOwn(value, 'reference')) {
    throw new SyncMutationError(428, 'CONTEXT_REFERENCE_REQUIRED');
  }
  if (value.reference == null) return { ...value, reference: null };
  if (!plainObject(value.reference)
      || !Number.isSafeInteger(value.reference.recordId)
      || value.reference.recordId <= 0
      || !uuidPattern.test(value.reference.revision ?? '')) {
    throw new SyncMutationError(428, 'CONTEXT_REFERENCE_REQUIRED');
  }
  return value;
};

const conflict = (code, observed) => new SyncMutationError(409, code, {
  ...contextRecordToSections(observed),
  serverReference: contextServerReference(observed),
});

/**
 * Coordinates context-only writes. A read followed by a write is not atomic:
 * atomicity for existing rows comes exclusively from writer's
 * (Id + app_sync_revision) condition. Initial creation additionally requires a
 * database-enforced unique dossier_id and is always confirmed by re-reading.
 */
export function createContextGuardedSync({
  tableId,
  readByDossierId,
  writer,
  createRecord,
  preferLocal = false,
}) {
  if (!tableId || typeof readByDossierId !== 'function'
      || typeof writer !== 'function' || typeof createRecord !== 'function') {
    throw new TypeError('Context guarded sync dependencies are required');
  }

  return async function mutate({
    dossierId,
    beneficiaryId,
    dossierRecordId,
    beneficiaryRecordId,
    updates,
    concurrency,
    authorizeObserved,
  }) {
    if (typeof dossierId !== 'string' || !dossierId.trim()) {
      throw new SyncMutationError(400, 'CONTEXT_DOSSIER_REQUIRED');
    }
    assertSectionMap(updates, 'UPDATES');
    if (!Object.keys(updates).length) {
      throw new SyncMutationError(400, 'CONTEXT_UPDATES_INVALID');
    }
    const guard = validateConcurrency(concurrency);
    const desired = canonicalSections(structuredClone(updates), { strict: true });
    const baseline = canonicalSections(structuredClone(guard.baseValues), { strict: true });

    for (let attempt = 0; attempt < 2; attempt++) {
      const observed = await readByDossierId(dossierId);
      if (observed && authorizeObserved && !await authorizeObserved(observed)) {
        throw new SyncMutationError(403, 'CONTEXT_RECORD_FORBIDDEN');
      }

      if (!observed) {
        if (guard.reference) throw new SyncMutationError(409, 'CONTEXT_RECORD_MISSING');
        const fields = contextSectionsToDatabaseFields(desired);
        try {
          await createRecord(tableId, {
            uuid_source: guard.writeId,
            dossier_id: dossierId,
            beneficiaire_id: beneficiaryId || null,
            dossiers_id: dossierRecordId ?? null,
            beneficiaires_id: beneficiaryRecordId ?? null,
            ...fields,
            [SYNC_REVISION_FIELD]: guard.writeId,
          });
        } catch (error) {
          throw new ContextCreateUncertainError(error);
        }
        const created = await readByDossierId(dossierId);
        if (created && sourceOf(created)[SYNC_REVISION_FIELD] === guard.writeId
            && isDeepStrictEqual(contextRecordToSections(created), {
              medicalContext: desired.medicalContext
                ? normalizedMedical(desired.medicalContext)
                : contextRecordToSections(created).medicalContext,
              autonomy: desired.autonomy
                ? normalizedAutonomy(desired.autonomy)
                : contextRecordToSections(created).autonomy,
            })) {
          return { applied: true, replay: false, serverReference: contextServerReference(created) };
        }
        throw new ContextCreateUncertainError();
      }

      const reference = contextServerReference(observed);
      const remote = contextRecordToSections(observed);
      if (Object.hasOwn(desired, 'autonomy') && hasInvalidOccupantsStorage(observed)) {
        throw conflict('CONTEXT_OCCUPANTS_REQUIRE_MIGRATION', observed);
      }
      if (reference.revision === guard.writeId) {
        const replay = planDatabaseMutation({
          fields: desired,
          baseFields: baseline,
          observed: remote,
        });
        if (!replay.conflicts.length && !replay.retainedFields.length
            && !Object.keys(replay.patch).length) {
          return { applied: true, replay: true, serverReference: reference };
        }
        throw conflict('CONTEXT_WRITE_ID_MISMATCH', observed);
      }
      if (!preferLocal && !guard.reference) throw conflict('CONTEXT_REFERENCE_REQUIRED', observed);
      if (guard.reference && guard.reference.recordId !== reference.recordId) {
        throw conflict('CONTEXT_REFERENCE_CHANGED', observed);
      }

      const plan = preferLocal
        ? { patch: Object.fromEntries(Object.entries(desired).filter(([key, value]) =>
            !isDeepStrictEqual(remote[key], value))), conflicts: [], retainedFields: [] }
        : planDatabaseMutation({
          fields: desired,
          baseFields: baseline,
          observed: remote,
        });
      if (plan.conflicts.length) throw conflict('CONTEXT_FIELD_CONFLICT', observed);
      if (plan.retainedFields.length) {
        throw conflict('CONTEXT_REMOTE_VALUES_REQUIRE_REVIEW', observed);
      }
      if (!Object.keys(plan.patch).length) {
        return { applied: true, replay: true, serverReference: reference };
      }

      const databasePatch = contextSectionsToDatabaseFields(plan.patch);
      const projected = contextRecordToSections({
        ...sourceOf(observed),
        ...databasePatch,
      });
      if (Object.keys(plan.patch).some(
        (section) => !isDeepStrictEqual(projected[section], desired[section]),
      )) {
        // Legacy shadow columns remain read-only here. Clearing them is a
        // migration decision and must never be an implicit side effect of a
        // user's context edit.
        throw conflict('CONTEXT_LEGACY_VALUES_REQUIRE_MIGRATION', observed);
      }

      const result = await writer({
        tableId,
        recordId: reference.recordId,
        expectedRevision: reference.revision,
        writeId: guard.writeId,
        fields: databasePatch,
      });
      if (result.status === 'applied') {
        return {
          applied: true,
          replay: Boolean(result.replay),
          // The writer confirms the new revision, but does not return the
          // corresponding NocoDB timestamp. Never associate the timestamp
          // observed before the CAS with the newly written revision.
          serverReference: {
            recordId: reference.recordId,
            revision: guard.writeId,
            updatedAt: null,
          },
        };
      }
      if (result.reason !== 'revision_changed') {
        throw new SyncMutationError(503, 'CONTEXT_WRITE_UNCONFIRMED');
      }
    }
    throw new SyncMutationError(503, 'CONTEXT_COMPETING_WRITE_RETRY');
  };
}

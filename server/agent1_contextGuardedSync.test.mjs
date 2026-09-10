import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import test from 'node:test';

import {
  ContextCreateUncertainError,
  contextRecordDatabaseState,
  contextRecordToSections,
  contextSectionsToDatabaseFields,
  createContextGuardedSync,
} from './contextGuardedSync.mjs';
import { SYNC_REVISION_FIELD, SyncMutationError } from './guardedMutation.mjs';
import { AUTONOMY_ITEMS } from '../shared/autonomyContract.js';

const medical = (pathology) => ({
  pathology,
  followUp: '',
  sensory: '',
  heightCm: '170',
  weightKg: '70',
});

const autonomy = (checked) => ({
  done: checked,
  checklist: AUTONOMY_ITEMS.map((name) => ({
    name,
    checked: name === 'Déplacements/transferts' && checked,
  })),
  occupants: [],
});

function fixture({
  initial = true,
  loseCreateResponse = false,
  loseWriteResponse = false,
} = {}) {
  const dossierId = 'dossier-1';
  const dossier = { Id: 70, app_sync_revision: randomUUID(), status: 'À visiter' };
  let row = initial
    ? {
        Id: 11,
        uuid_source: 'context-1',
        dossier_id: dossierId,
        ...contextSectionsToDatabaseFields({
          medicalContext: medical('initial'),
          autonomy: autonomy(false),
        }),
        [SYNC_REVISION_FIELD]: randomUUID(),
        UpdatedAt: '2026-09-10T08:00:00.000Z',
      }
    : null;
  let writes = 0;
  let creates = 0;
  let beforeConditionalWrite = null;
  const readByDossierId = async (requested) => requested === dossierId && row
    ? structuredClone(row)
    : null;
  const writer = async ({ recordId, expectedRevision, writeId, fields }) => {
    writes += 1;
    if (beforeConditionalWrite) {
      const callback = beforeConditionalWrite;
      beforeConditionalWrite = null;
      callback();
    }
    assert.equal(recordId, 11);
    if (row[SYNC_REVISION_FIELD] !== expectedRevision) {
      return { status: 'not_confirmed', reason: 'revision_changed' };
    }
    Object.assign(row, structuredClone(fields), {
      [SYNC_REVISION_FIELD]: writeId,
      UpdatedAt: '2026-09-10T09:00:00.000Z',
    });
    if (loseWriteResponse && writes === 1) throw new Error('response lost');
    return { status: 'applied', revision: writeId, replay: false };
  };
  const createRecord = async (_tableId, fields) => {
    creates += 1;
    if (row) throw new Error('unique dossier_id');
    row = { Id: 11, ...structuredClone(fields), UpdatedAt: '2026-09-10T09:00:00.000Z' };
    if (loseCreateResponse && creates === 1) throw new Error('response lost');
    return structuredClone(row);
  };
  const mutate = createContextGuardedSync({
    tableId: 'contextes',
    readByDossierId,
    writer,
    createRecord,
  });
  const reference = () => row && ({
    recordId: row.Id,
    revision: row[SYNC_REVISION_FIELD],
    updatedAt: row.UpdatedAt,
  });
  const guard = ({ baseValues, writeId = randomUUID(), ref = reference() }) => ({
    version: 1,
    writeId,
    reference: ref,
    baseValues,
  });
  return {
    dossierId,
    dossier,
    mutate,
    guard,
    row: () => row,
    writes: () => writes,
    creates: () => creates,
    race: (callback) => { beforeConditionalWrite = callback; },
  };
}

test('deux éditions successives avancent seulement la référence contexte', async () => {
  const f = fixture();
  const dossierRevision = f.dossier.app_sync_revision;
  const first = await f.mutate({
    dossierId: f.dossierId,
    updates: { medicalContext: medical('première édition') },
    concurrency: f.guard({
      baseValues: { medicalContext: medical('initial') },
    }),
    authorizeObserved: () => true,
  });
  assert.equal(first.applied, true);
  assert.equal(first.serverReference.updatedAt, null);
  assert.equal(contextRecordToSections(f.row()).medicalContext.pathology, 'première édition');

  const second = await f.mutate({
    dossierId: f.dossierId,
    updates: { autonomy: autonomy(true) },
    concurrency: f.guard({
      baseValues: { autonomy: autonomy(false) },
    }),
    authorizeObserved: () => true,
  });
  assert.equal(second.applied, true);
  assert.equal(contextRecordToSections(f.row()).medicalContext.pathology, 'première édition');
  assert.equal(contextRecordToSections(f.row()).autonomy.done, true);
  assert.equal(f.dossier.app_sync_revision, dossierRevision);
  assert.equal(f.writes(), 2);
});

test('une réponse perdue est rejouée avec le même writeId sans second PATCH', async () => {
  const f = fixture({ loseWriteResponse: true });
  const writeId = randomUUID();
  const concurrency = f.guard({
    writeId,
    baseValues: { medicalContext: medical('initial') },
  });
  await assert.rejects(f.mutate({
    dossierId: f.dossierId,
    updates: { medicalContext: medical('appliqué') },
    concurrency,
    authorizeObserved: () => true,
  }), /response lost/);
  assert.equal(f.row()[SYNC_REVISION_FIELD], writeId);
  const replay = await f.mutate({
    dossierId: f.dossierId,
    updates: { medicalContext: medical('appliqué') },
    concurrency,
    authorizeObserved: () => true,
  });
  assert.equal(replay.replay, true);
  assert.equal(f.writes(), 1);
});

test('un conflit de section est explicite et ne déclenche aucune écriture', async () => {
  const f = fixture();
  f.row().nom_pathologie = 'modification distante';
  f.row()[SYNC_REVISION_FIELD] = randomUUID();
  await assert.rejects(
    f.mutate({
      dossierId: f.dossierId,
      updates: { medicalContext: medical('modification locale') },
      concurrency: f.guard({
        baseValues: { medicalContext: medical('initial') },
        ref: { recordId: 11, revision: randomUUID() },
      }),
      authorizeObserved: () => true,
    }),
    (error) => error instanceof SyncMutationError
      && error.status === 409
      && error.code === 'CONTEXT_FIELD_CONFLICT'
      && error.observed.medicalContext.pathology === 'modification distante',
  );
  assert.equal(f.writes(), 0);
});

test('une modification distante pendant la comparaison fait échouer la condition puis recompare', async () => {
  const f = fixture();
  f.race(() => {
    f.row().nom_pathologie = 'concurrent';
    f.row()[SYNC_REVISION_FIELD] = randomUUID();
  });
  await assert.rejects(
    f.mutate({
      dossierId: f.dossierId,
      updates: { medicalContext: medical('local') },
      concurrency: f.guard({
        baseValues: { medicalContext: medical('initial') },
      }),
      authorizeObserved: () => true,
    }),
    (error) => error.code === 'CONTEXT_FIELD_CONFLICT'
      && error.observed.medicalContext.pathology === 'concurrent',
  );
  assert.equal(f.writes(), 1);
  assert.equal(contextRecordToSections(f.row()).medicalContext.pathology, 'concurrent');
});

test('une création dont la réponse est perdue reste incertaine puis se confirme au rejeu', async () => {
  const f = fixture({ initial: false, loseCreateResponse: true });
  const writeId = randomUUID();
  const input = {
    dossierId: f.dossierId,
    beneficiaryId: 'beneficiary-1',
    dossierRecordId: 70,
    beneficiaryRecordId: 80,
    updates: { medicalContext: medical('hors ligne') },
    concurrency: f.guard({ baseValues: {}, writeId, ref: null }),
    authorizeObserved: () => true,
  };
  await assert.rejects(f.mutate(input), ContextCreateUncertainError);
  assert.equal(f.creates(), 1);
  assert.equal(f.row()[SYNC_REVISION_FIELD], writeId);

  const replay = await f.mutate(input);
  assert.equal(replay.applied, true);
  assert.equal(replay.replay, true);
  assert.equal(replay.serverReference.recordId, 11);
  assert.equal(f.creates(), 1);
});

test('l’autorisation est revérifiée avant toute écriture contexte', async () => {
  const f = fixture();
  await assert.rejects(
    f.mutate({
      dossierId: f.dossierId,
      updates: { autonomy: autonomy(true) },
      concurrency: f.guard({ baseValues: { autonomy: autonomy(false) } }),
      authorizeObserved: () => false,
    }),
    (error) => error.code === 'CONTEXT_RECORD_FORBIDDEN' && error.status === 403,
  );
  assert.equal(f.writes(), 0);
});

test('les colonnes historiques visibles participent à la comparaison', () => {
  const record = {
    Id: 11,
    nom_pathologie: 'Pathologie actuelle',
    pathologie_maladie: 'Historique',
    frequence_suivi_medical: 'Chaque mois',
    deficience_visuelle: 'Basse vision',
    utilise_canne: 'x',
    [SYNC_REVISION_FIELD]: randomUUID(),
  };
  const sections = contextRecordToSections(record);

  assert.deepEqual(sections.medicalContext, {
    pathology: 'Pathologie actuelle • Historique',
    followUp: 'Chaque mois',
    sensory: 'Basse vision',
    heightCm: '',
    weightKg: '',
  });
  assert.equal(
    sections.autonomy.checklist.find(
      (item) => item.name === 'Déplacements/transferts',
    ).checked,
    true,
  );
  assert.equal(contextRecordDatabaseState(record).legacy.pathologie_maladie, 'Historique');
});

test('une édition médicale ne réinjecte pas les colonnes historiques', async () => {
  const f = fixture();
  f.row().pathologie_maladie = 'ancienne valeur';
  const before = contextRecordToSections(f.row()).medicalContext;

  await assert.rejects(
    f.mutate({
      dossierId: f.dossierId,
      updates: { medicalContext: medical('nouvelle valeur') },
      concurrency: f.guard({ baseValues: { medicalContext: before } }),
      authorizeObserved: () => true,
    }),
    (error) => error.code === 'CONTEXT_LEGACY_VALUES_REQUIRE_MIGRATION'
      && error.observed.medicalContext.pathology === 'initial • ancienne valeur',
  );
  assert.equal(f.writes(), 0);
  assert.equal(f.row().nom_pathologie, 'initial');
  assert.equal(f.row().pathologie_maladie, 'ancienne valeur');
});

test('une ancienne aide technique ne peut pas annuler silencieusement une décoche', async () => {
  const f = fixture();
  f.row().utilise_canne = 'Oui';
  f.row().aide_technique_deplacement = true;
  const before = contextRecordToSections(f.row()).autonomy;

  await assert.rejects(
    f.mutate({
      dossierId: f.dossierId,
      updates: { autonomy: autonomy(false) },
      concurrency: f.guard({ baseValues: { autonomy: before } }),
      authorizeObserved: () => true,
    }),
    (error) => error.code === 'CONTEXT_LEGACY_VALUES_REQUIRE_MIGRATION',
  );
  assert.equal(f.writes(), 0);
  assert.equal(contextRecordToSections(f.row()).autonomy.checklist[0].checked, true);
});

test('les occupants invalides et booléens textuels sont refusés côté écriture', () => {
  assert.throws(
    () => contextSectionsToDatabaseFields({
      autonomy: {
        done: false,
        checklist: AUTONOMY_ITEMS.map((name) => ({ name, checked: false })),
        occupants: [{
          medical: medical(''),
          autonomyDone: 'false',
          autonomy: [],
          attention: [],
          humanHelp: [],
        }],
      },
    }),
    (error) => error.code === 'CONTEXT_OCCUPANTS_INVALID',
  );

  const read = contextRecordToSections({
    Id: 11,
    occupants_json: JSON.stringify([{
      medical: medical(''),
      autonomyDone: 'false',
      autonomy: [],
      attention: [],
      humanHelp: [],
    }]),
    [SYNC_REVISION_FIELD]: randomUUID(),
  });
  assert.equal(read.autonomy.done, false);
  assert.equal(read.autonomy.occupants[0].autonomyDone, false);
});

test('une référence absente n’est jamais assimilée à une création explicite', async () => {
  const f = fixture({ initial: false });
  const concurrency = f.guard({
    baseValues: {},
    ref: null,
  });
  delete concurrency.reference;

  await assert.rejects(
    f.mutate({
      dossierId: f.dossierId,
      updates: { medicalContext: medical('hors ligne') },
      concurrency,
      authorizeObserved: () => true,
    }),
    (error) => error.code === 'CONTEXT_REFERENCE_REQUIRED'
      && error.status === 428,
  );
  assert.equal(f.writes(), 0);
  assert.equal(f.creates(), 0);
});

test('un occupants_json corrompu bloque l’autonomie sans écriture', async () => {
  const f = fixture();
  f.row().occupants_json = '{json incomplet';
  const before = contextRecordToSections(f.row()).autonomy;

  await assert.rejects(
    f.mutate({
      dossierId: f.dossierId,
      updates: { autonomy: autonomy(true) },
      concurrency: f.guard({ baseValues: { autonomy: before } }),
      authorizeObserved: () => true,
    }),
    (error) => error.code === 'CONTEXT_OCCUPANTS_REQUIRE_MIGRATION'
      && error.status === 409,
  );
  assert.equal(f.writes(), 0);
  assert.equal(f.creates(), 0);
  assert.equal(f.row().occupants_json, '{json incomplet');
});

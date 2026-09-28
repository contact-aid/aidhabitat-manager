import assert from 'node:assert/strict';
import test from 'node:test';
import { syncCurrentCoralieDossiers } from './airtableDossierSync.mjs';

const source = (id, date, cancelled = 'NON', first = 'Camille') => ({
  dossier: { id, fields: {
    'Adaptation ou énergie': ['Adaptation'],
    'Intervenant couleur': ['Coralie'],
    'Date du RDV avec heure': date,
    'Annulé ?': cancelled,
    'No Client': [`rec${id.slice(3)}`],
  } },
  client: { id: `rec${id.slice(3)}`, fields: { Prénom: first, Nom: 'Exemple' } },
});

test('only the agreed recent, non-cancelled cohort is imported in bounded batches', async () => {
  const created = [];
  const rows = [
    source('recAAAAAAAAAAAAAA', '2026-08-02T08:00:00.000Z'),
    source('recBBBBBBBBBBBBBB', '2026-09-29T08:00:00.000Z'),
    source('recCCCCCCCCCCCCCC', '2026-07-31T08:00:00.000Z'),
    source('recDDDDDDDDDDDDDD', '2026-10-01T08:00:00.000Z', 'OUI'),
  ];
  let nextId = 1;
  const result = await syncCurrentCoralieDossiers({
    sourceRows: rows, dossierRows: [], beneficiaryRows: [], maxChanges: 1,
    createBeneficiary: async (fields) => { created.push({ table: 'beneficiary', fields }); return { id: nextId++ }; },
    createDossier: async (fields) => { created.push({ table: 'dossier', fields }); return { id: nextId++ }; },
    updateBeneficiary: async () => assert.fail('unexpected update'),
    updateDossier: async () => assert.fail('unexpected update'),
  });
  assert.equal(result.eligible, 2);
  assert.equal(result.created, 1);
  assert.equal(result.remaining, 1);
  assert.equal(created[1].fields.uuid_source, 'airtable:recAAAAAAAAAAAAAA');
  assert.equal(created[1].fields.ergo_id, 'Coralie');
});

test('an existing exact Airtable ID updates source fields without touching visit notes', async () => {
  const patches = [];
  const result = await syncCurrentCoralieDossiers({
    sourceRows: [source('recAAAAAAAAAAAAAA', '2026-09-29T08:00:00.000Z')],
    dossierRows: [{ id: 10, fields: { uuid_source: 'airtable:recAAAAAAAAAAAAAA',
      beneficiaires_id: 11, ergo_id: 'Coralie', visit_date: '2026-08-01T08:00:00.000Z',
      status: 'En cours', compte_anah: 'déjà saisi' } }],
    beneficiaryRows: [{ id: 11, fields: { prenom: 'Ancien', nom: 'Exemple' } }],
    createBeneficiary: async () => assert.fail('unexpected creation'),
    createDossier: async () => assert.fail('unexpected creation'),
    updateBeneficiary: async (_, patch) => patches.push({ table: 'beneficiary', patch }),
    updateDossier: async (_, patch) => patches.push({ table: 'dossier', patch }),
  });
  assert.equal(result.created, 0);
  assert.equal(result.updated, 1);
  assert.equal(result.remaining, 0);
  assert.deepEqual(patches, [
    { table: 'beneficiary', patch: { prenom: 'Camille' } },
    { table: 'dossier', patch: { visit_date: '2026-09-29T08:00:00.000Z' } },
  ]);
});

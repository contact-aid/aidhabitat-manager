import assert from 'node:assert/strict';
import test from 'node:test';
import { syncCurrentCoralieDossiers, syncCurrentProfileDossiers } from './airtableDossierSync.mjs';

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

test('another profile imports its own records and cannot overwrite another assignment', async () => {
  const christelle = source('recAAAAAAAAAAAAAA', '2026-09-29T08:00:00.000Z');
  christelle.dossier.fields['Intervenant couleur'] = ['Christelle'];
  const conflicting = source('recBBBBBBBBBBBBBB', '2026-09-29T08:00:00.000Z');
  conflicting.dossier.fields['Intervenant couleur'] = ['Christelle'];
  const created = [];
  const result = await syncCurrentProfileDossiers({
    ergoLabel: 'Christelle', sourceRows: [christelle, conflicting],
    dossierRows: [{ id: 9, fields: { uuid_source: 'airtable:recBBBBBBBBBBBBBB',
      ergo_id: 'Coralie', beneficiaires_id: 8 } }],
    beneficiaryRows: [],
    createBeneficiary: async (fields) => { created.push(fields); return { id: 1 }; },
    createDossier: async (fields) => { created.push(fields); return { id: 2 }; },
  });
  assert.equal(result.created, 1);
  assert.equal(created[1].ergo_id, 'Christelle');
  assert.deepEqual(result.skipped, [{ id: 'recBBBBBBBBBBBBBB', reason: 'attribution différente' }]);
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

test('an Airtable PDF promotes the dossier while visit fields already entered are preserved', async () => {
  const input = source('recAAAAAAAAAAAAAA', '2026-09-29T08:00:00.000Z');
  input.dossier.fields['Audit ou Eval'] = [{ type: 'application/pdf', filename: 'rapport.pdf' }];
  input.dossier.fields['Commune texte'] = 'Ville lisible';
  input.client.fields['Date de naissance'] = '1950-01-01';
  input.client.fields['Catégorie sans emoji'] = 'Modeste';
  input.client.fields['Nb du foyer'] = '1';
  const patches = [];
  await syncCurrentCoralieDossiers({
    sourceRows: [input],
    dossierRows: [{ id: 10, fields: { uuid_source: 'airtable:recAAAAAAAAAAAAAA',
      beneficiaires_id: 11, ergo_id: 'Coralie', status: 'À visiter',
      visit_date: '2026-09-29T08:00:00.000Z' } }],
    beneficiaryRows: [{ id: 11, fields: { prenom: 'Camille', nom: 'Exemple',
      ville_libre: 'recBBBBBBBBBBBBBB', date_naissance_monsieur: '1949-01-01' } }],
    baremeRows: [{ id: 42, fields: { nombre_personnes: 1, annee_plafond: 2026 } }],
    createBeneficiary: async () => assert.fail('unexpected creation'),
    createDossier: async () => assert.fail('unexpected creation'),
    updateBeneficiary: async (_, patch) => patches.push({ table: 'beneficiary', patch }),
    updateDossier: async (_, patch) => patches.push({ table: 'dossier', patch }),
  });
  assert.deepEqual(patches, [
    { table: 'beneficiary', patch: {
      ville_libre: 'Ville lisible', nombre_personnes: 1,
      categorie_revenu_id1: 42,
    } },
    { table: 'dossier', patch: { status: 'En cours' } },
  ]);
});

test('the earlier iPad request keeps its original import behavior', async () => {
  const input = source('recAAAAAAAAAAAAAA', '2026-09-29T08:00:00.000Z');
  input.dossier.fields['Audit ou Eval'] = [{ type: 'application/pdf', filename: 'rapport.pdf' }];
  input.dossier.fields.Commune = ['recBBBBBBBBBBBBBB'];
  input.dossier.fields['Commune texte'] = 'Ville lisible';
  input.client.fields['M./Mme'] = 'Madame';
  input.client.fields['Date de naissance'] = '1950-01-01';
  input.client.fields['Nb du foyer'] = '1';
  const created = [];
  await syncCurrentCoralieDossiers({
    sourceRows: [input], dossierRows: [], beneficiaryRows: [],
    baremeRows: [{ id: 42, fields: { nombre_personnes: 1, annee_plafond: 2026 } }],
    enhancedWeb: false,
    createBeneficiary: async (fields) => { created.push(fields); return { id: 1 }; },
    createDossier: async (fields) => { created.push(fields); return { id: 2 }; },
    updateBeneficiary: async () => assert.fail('unexpected update'),
    updateDossier: async () => assert.fail('unexpected update'),
  });
  assert.equal(created[0].ville_libre, undefined);
  assert.equal(created[0].date_naissance_madame, '1950-01-01');
  assert.equal(created[0].categorie_revenu_id1, undefined);
  assert.equal(created[1].status, 'À visiter');
});

test('prefills housing and ownership from new-client Airtable fields without replacing visit edits', async () => {
  const input = source('recAAAAAAAAAAAAAA', '2026-09-29T08:00:00.000Z');
  Object.assign(input.client.fields, {
    'Inscription Maison ou appart ?': 'Maison',
    "Inscription Année d'achat": '1988',
    'Inscription Anné de construction': '1975',
    'Inscription PO ou PB': 'Propriétaire occupant',
  });
  const patches = [];
  const result = await syncCurrentCoralieDossiers({
    sourceRows: [input],
    dossierRows: [{ id: 10, fields: { uuid_source: 'airtable:recAAAAAAAAAAAAAA',
      beneficiaires_id: 11, ergo_id: 'Coralie', visit_date: '2026-09-29T08:00:00.000Z' } }],
    beneficiaryRows: [{ id: 11, fields: { prenom: 'Camille', nom: 'Exemple' } }],
    housingRows: [{ id: 21, fields: { beneficiaires_id: 11, annee_construction: '1981' } }],
    housingTypes: [{ id: 1, fields: { libelle: 'Maison' } }],
    occupationTypes: [{ id: 1, fields: { libelle: 'Propriétaire' } }],
    updateBeneficiary: async (_, patch) => patches.push({ table: 'beneficiary', patch }),
    updateDossier: async () => assert.fail('unexpected dossier update'),
    updateHousing: async (_, patch) => patches.push({ table: 'housing', patch }),
  });
  assert.equal(result.updated, 1);
  assert.deepEqual(patches, [
    { table: 'beneficiary', patch: { statut_occupation_id1: 1 } },
    { table: 'housing', patch: { type_de_logement_id: 1, annee_habitation: '1988' } },
  ]);
});

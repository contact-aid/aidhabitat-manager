import assert from 'node:assert/strict';
import test from 'node:test';
import { assignedAdaptationFormula, createAirtableAdaptationReader, projectAirtableDossier } from './airtableAdaptation.mjs';

const id = (char) => `rec${char.repeat(14)}`;
const row = (recordId, fields) => ({ id: recordId, fields });

test('the authenticated intervenant and Adaptation both constrain the Airtable search', async () => {
  const calls = [];
  const fetchImpl = async (url, options) => {
    calls.push({ url: new URL(url), options });
    if (url.pathname.endsWith('/tbl7qYd2ZKgwQVNU1')) {
      return Response.json({ records: [
        row(id('a'), { 'Dossier ID': 'FICTIF-2026', 'Adaptation ou énergie': ['Adaptation'],
          'Intervenant couleur': ['Coralie'], 'Nom intervenant': ['Coralie Exemple'], 'No Client': [id('x')],
          Commentaires: 'Note fictive' }),
        row(id('b'), { 'Adaptation ou énergie': ['énergie'],
          'Intervenant couleur': ['Coralie'], 'No Client': [id('y')] }),
        row(id('c'), { 'Adaptation ou énergie': ['Adaptation'],
          'Intervenant couleur': ['Christelle'], 'No Client': [id('z')] }),
        row(id('d'), { 'Adaptation ou énergie': ['Adaptation'],
          'Intervenant couleur': ['Coralie'], 'Nom intervenant': ['Coralie Autre'], 'No Client': [] }),
      ] });
    }
    return Response.json({ records: [row(id('x'), { Prénom: 'Fictive' })] });
  };
  const read = createAirtableAdaptationReader({ token: 'synthetic-token', fetchImpl });
  const result = await read('Coralie', { fullName: 'Coralie Exemple' });
  assert.equal(result.length, 1);
  assert.equal(result[0].dossier.id, id('a'));
  assert.equal(result[0].client.id, id('x'));
  assert.equal(calls.length, 2);
  assert.equal(calls[0].url.searchParams.get('filterByFormula'), assignedAdaptationFormula('Coralie'));
  assert.match(calls[1].url.searchParams.get('filterByFormula'), /RECORD_ID\(\)/);
  assert(calls.every((call) => call.options.headers.Authorization === 'Bearer synthetic-token'));
  assert(calls.every((call) => call.options.method === 'GET'));
});

test('a missing server token or unsafe intervenant prevents any Airtable request', async () => {
  assert.throws(() => createAirtableAdaptationReader({ token: '' }), /AIRTABLE_TOKEN/);
  let calls = 0;
  const read = createAirtableAdaptationReader({
    token: 'synthetic-token', fetchImpl: () => { calls++; return Response.json({ records: [] }); },
  });
  await assert.rejects(read('Coralie"),1)\n'), /Intervenant invalide/);
  assert.equal(calls, 0);
});

test('pagination is exhausted before returning a scoped result', async () => {
  let calls = 0;
  const read = createAirtableAdaptationReader({
    token: 'synthetic-token',
    fetchImpl: async () => {
      calls++;
      return Response.json(calls === 1
        ? { records: [], offset: 'next' }
        : { records: [row(id('a'), { 'Dossier ID': 'FICTIF-2026', 'Adaptation ou énergie': ['Adaptation'],
          'Intervenant couleur': ['Coralie'], 'No Client': [] })] });
    },
  });
  const result = await read('Coralie');
  assert.equal(calls, 2);
  assert.equal(result.length, 1);
});

test('projection only contains authorized dossier identity and scheduling fields', () => {
  const result = projectAirtableDossier({
    dossier: row(id('a'), { 'Dossier ID': 'FICTIF-2026', Commentaires: 'Note fictive',
      Commune: ['Ville fictive'], 'Communauté de communes': ['EPCI fictif'],
      'Date du RDV avec heure': '2026-10-01T08:00:00.000Z',
      'Nature des travaux conca': "MaPrimeAdapt' Complet",
      autonomy: 'must be ignored', wcInstances: ['must be ignored'] }),
    client: row(id('x'), { Prénom: 'Camille', Nom: 'Exemple',
      'Nb du foyer': '2', Ressources: 12345, 'Catégorie': 'Très modeste',
      'M./Mme': 'Madame', 'Date de naissance': '1950-01-01',
      'N° et rue': '1 rue fictive' }),
  });
  assert.deepEqual(result.beneficiary, {
    prenom: 'Camille', nom: 'Exemple', adresse_logement: '1 rue fictive',
    ville_libre: 'Ville fictive', nombre_personnes: 2,
    revenu_fiscal_reference: 12345, date_naissance_madame: '1950-01-01',
  });
  assert.deepEqual(result.dossier, {
    visit_date: '2026-10-01T08:00:00.000Z', nature_accompagnement: 'complet',
  });
  assert.equal(result.quickNote, 'Note fictive');
  assert.equal(result.airtableRecordId, id('a'));
  assert.equal(result.airtableDossierLabel, 'FICTIF-2026');
  assert.equal(result.epciLabel, 'EPCI fictif');
  assert.equal(result.incomeCategoryLabel, 'Très modeste');
  assert(!JSON.stringify(result).includes('must be ignored'));
});

test('an absent Airtable record identity cannot be guessed from a patient name', () => {
  assert.throws(() => projectAirtableDossier({
    dossier: row('', { 'Dossier ID': '', Prénom: 'Camille' }),
    client: row(id('x'), { Prénom: 'Camille' }),
  }), /Identifiant Airtable/);
});

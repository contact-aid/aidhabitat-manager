// Read-only Airtable source for the explicit "Actualiser" action. The token
// stays on the API server; neither Flutter nor NocoDB receives it.
export const AIRTABLE_ADAPTATION = Object.freeze({
  baseId: 'appiLdUPtCWODdJ1a',
  dossiersTableId: 'tbl7qYd2ZKgwQVNU1',
  clientsTableId: 'tbl2ILt8GBHUjG3sA',
});

const dossierFields = [
  'Dossier ID', 'Adaptation ou énergie', 'Intervenant couleur', 'Nom intervenant',
  'No Client', 'Commentaires', 'Date du RDV avec heure',
  'Nature des travaux conca', 'Commune', 'Communauté de communes',
];
const clientFields = [
  'Prénom', 'Nom', 'Téléphone', 'Adresse mail', 'N° et rue',
  'Communes', 'Code postal (from Communes)',
  'Communauté de commune (from Communes)', 'Nb du foyer',
  'Ressources', 'Catégorie', 'M./Mme', 'Date de naissance',
];

const labels = (value) => {
  if (Array.isArray(value)) return value.flatMap(labels);
  if (value == null) return [];
  if (typeof value === 'object') {
    if (typeof value.name === 'string') return [value.name];
    return [];
  }
  return [String(value)];
};

const normalized = (value) => String(value ?? '').normalize('NFD')
  .replace(/[\u0300-\u036f]/g, '').toLowerCase().trim().replace(/\s+/g, ' ');

const first = (value) => labels(value).map((item) => item.trim()).find(Boolean) ?? '';
const asNumber = (value) => {
  const raw = first(value).replace(/\s/g, '').replace(',', '.');
  if (!raw) return null;
  const valueNumber = Number(raw);
  return Number.isFinite(valueNumber) ? valueNumber : null;
};

/** Explicit allowlist: no accessibility, autonomy, bathroom, WC, or report note. */
export function projectAirtableDossier({ dossier, client }) {
  const source = dossier?.fields || {};
  const person = client?.fields || {};
  const beneficiary = {};
  const dossierPatch = {};
  if (!/^rec[A-Za-z0-9]{14}$/.test(String(dossier?.id ?? ''))) {
    throw new TypeError('Identifiant Airtable du dossier invalide');
  }
  const add = (target, targetKey, value) => {
    if (value !== undefined && value !== null && value !== '') target[targetKey] = value;
  };
  add(beneficiary, 'prenom', first(person['Prénom']));
  add(beneficiary, 'nom', first(person.Nom));
  add(beneficiary, 'telephone', first(person.Téléphone).replace(/\D/g, ''));
  add(beneficiary, 'mail', first(person['Adresse mail']).toLowerCase());
  add(beneficiary, 'adresse_logement', first(person['N° et rue']));
  add(beneficiary, 'ville_libre', first(source.Commune));
  add(beneficiary, 'code_postal_libre', first(person['Code postal (from Communes)']));
  const people = asNumber(person['Nb du foyer']);
  if (Number.isSafeInteger(people) && people > 0) beneficiary.nombre_personnes = people;
  const revenue = asNumber(person.Ressources);
  if (revenue != null && revenue >= 0) beneficiary.revenu_fiscal_reference = revenue;
  const birthDate = first(person['Date de naissance']);
  const civility = normalized(first(person['M./Mme']));
  if (/^\d{4}-\d{2}-\d{2}$/.test(birthDate)) {
    if (civility === 'monsieur') beneficiary.date_naissance_monsieur = birthDate;
    if (civility === 'madame') beneficiary.date_naissance_madame = birthDate;
  }
  add(dossierPatch, 'visit_date', first(source['Date du RDV avec heure']));
  const nature = normalized(first(source['Nature des travaux conca']));
  if (nature.includes('complet')) dossierPatch.nature_accompagnement = 'complet';
  else if (nature.includes('ergo')) dossierPatch.nature_accompagnement = 'ergo';
  else if (nature.includes('mixte')) dossierPatch.nature_accompagnement = 'mixte';
  else if (nature.includes('socle')) dossierPatch.nature_accompagnement = 'socle';
  return {
    airtableRecordId: dossier.id,
    airtableClientRecordId: client?.id || null,
    airtableDossierLabel: first(source['Dossier ID']),
    beneficiary,
    dossier: dossierPatch,
    quickNote: first(source.Commentaires),
    epciLabel: first(source['Communauté de communes']),
    incomeCategoryLabel: first(person['Catégorie']),
  };
}

// Imported NocoDB dossiers already use `airtable:<record ID>` as uuid_source.
// Older imports may instead have kept the Airtable client ID as patient_id.
// Names and addresses are excluded because they can be duplicated or changed.
export function resolveAirtableLinks(airtableRecords, nocodbDossiers) {
  const sourceCounts = new Map();
  const clientCounts = new Map();
  for (const record of airtableRecords) {
    sourceCounts.set(record.airtableRecordId,
      (sourceCounts.get(record.airtableRecordId) || 0) + 1);
    if (record.airtableClientRecordId) clientCounts.set(record.airtableClientRecordId,
      (clientCounts.get(record.airtableClientRecordId) || 0) + 1);
  }
  const uuidCounts = new Map();
  const patientCounts = new Map();
  const field = (row, key) => row?.fields?.[key] ?? row?.[key];
  for (const row of nocodbDossiers) {
    const uuid = String(field(row, 'uuid_source') ?? '').trim();
    const patientId = String(field(row, 'patient_id') ?? '').trim();
    if (uuid) uuidCounts.set(uuid, (uuidCounts.get(uuid) || 0) + 1);
    if (patientId) patientCounts.set(patientId,
      (patientCounts.get(patientId) || 0) + 1);
  }
  return airtableRecords.map((record) => {
    const sourceId = record.airtableRecordId;
    const clientId = record.airtableClientRecordId;
    const sourceUuid = `airtable:${sourceId}`;
    const linked = nocodbDossiers.filter((row) =>
      field(row, 'uuid_source') === sourceUuid);
    const legacy = linked.length ? [] : nocodbDossiers.filter((row) =>
      clientId &&
      field(row, 'patient_id') === clientId);
    const candidates = linked.length ? linked : legacy;
    const unique = sourceCounts.get(sourceId) === 1 &&
      (linked.length ? uuidCounts.get(sourceUuid) === 1 :
        clientId && clientCounts.get(clientId) === 1 &&
        patientCounts.get(clientId) === 1);
    const dossierId = unique && candidates.length === 1
      ? String(field(candidates[0], 'uuid_source') ?? '').trim() : '';
    return {
      ...record,
      nocodbDossierId: dossierId || null,
      linkSource: dossierId ? (linked.length ? 'airtable_uuid' : 'legacy_client_id') : null,
    };
  });
}

export const assignedAdaptationFormula = (intervenant) => {
  const name = normalized(intervenant);
  if (!name || !/^[\p{L}\p{N} .'-]{1,80}$/u.test(name)) {
    throw new TypeError('Intervenant invalide');
  }
  const quoted = JSON.stringify(name);
  return `AND(FIND("adaptation",LOWER(ARRAYJOIN({Adaptation ou énergie}))),FIND(${quoted},LOWER(ARRAYJOIN({Intervenant couleur}))))`;
};

const isAssignedAdaptation = (fields, intervenant, fullName) =>
  labels(fields['Adaptation ou énergie']).some((label) => normalized(label) === 'adaptation')
  && labels(fields['Intervenant couleur']).some((label) =>
    normalized(label) === normalized(intervenant))
  && (!fullName || labels(fields['Nom intervenant']).some((label) =>
    normalized(label) === normalized(fullName)));

export function createAirtableAdaptationReader({
  token,
  fetchImpl = globalThis.fetch,
  baseId = AIRTABLE_ADAPTATION.baseId,
  dossiersTableId = AIRTABLE_ADAPTATION.dossiersTableId,
  clientsTableId = AIRTABLE_ADAPTATION.clientsTableId,
}) {
  if (!token || typeof token !== 'string') throw new TypeError('AIRTABLE_TOKEN absent');
  if (typeof fetchImpl !== 'function') throw new TypeError('Airtable fetch absent');

  const list = async (tableId, { formula, fields }) => {
    const records = [];
    let offset;
    for (let page = 0; page < 100; page++) {
      const url = new URL(`https://api.airtable.com/v0/${baseId}/${tableId}`);
      url.searchParams.set('pageSize', '100');
      url.searchParams.set('filterByFormula', formula);
      for (const fieldName of fields) url.searchParams.append('fields[]', fieldName);
      if (offset) url.searchParams.set('offset', offset);
      const response = await fetchImpl(url, {
        method: 'GET',
        headers: { Authorization: `Bearer ${token}` },
        redirect: 'error',
        signal: AbortSignal.timeout(15000),
      });
      if (!response.ok) throw new Error(`Airtable HTTP ${response.status}`);
      const body = await response.json();
      if (!Array.isArray(body.records)) throw new Error('Réponse Airtable invalide');
      records.push(...body.records);
      if (!body.offset) return records;
      if (typeof body.offset !== 'string' || body.offset === offset) {
        throw new Error('Pagination Airtable invalide');
      }
      offset = body.offset;
    }
    throw new Error('Pagination Airtable trop longue');
  };

  return async (intervenant, { fullName = '' } = {}) => {
    if (fullName && (!/^[\p{L}\p{N} .'-]{1,120}$/u.test(fullName)
      || normalized(fullName).split(' ')[0] !== normalized(intervenant))) {
      throw new TypeError('Nom complet de l’intervenant invalide');
    }
    const dossiers = (await list(dossiersTableId, {
      formula: assignedAdaptationFormula(intervenant), fields: dossierFields,
    })).filter((record) => isAssignedAdaptation(record.fields || {}, intervenant, fullName));
    const clientIds = [...new Set(dossiers.flatMap((record) =>
      Array.isArray(record.fields?.['No Client'])
        ? record.fields['No Client'] : []))]
      .filter((id) => /^rec[A-Za-z0-9]{14}$/.test(id));
    const clients = [];
    for (let start = 0; start < clientIds.length; start += 25) {
      const batch = clientIds.slice(start, start + 25);
      clients.push(...await list(clientsTableId, {
        formula: `OR(${batch.map((id) => `RECORD_ID()=${JSON.stringify(id)}`).join(',')})`,
        fields: clientFields,
      }));
    }
    const byId = new Map(clients.map((record) => [record.id, record]));
    return dossiers.map((dossier) => ({
      dossier,
      client: byId.get(dossier.fields['No Client']?.[0]) ?? null,
    }));
  };
}

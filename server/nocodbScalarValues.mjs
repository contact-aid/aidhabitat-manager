import { isDeepStrictEqual } from 'node:util';

function instantMicros(value) {
  if (typeof value !== 'string') return null;
  // Only zoned, complete timestamps. Do not guess local time or truncate
  // PostgreSQL microseconds when comparing a stored value with an ISO date.
  const match = /^(\d{4}-\d{2}-\d{2})[ T](\d{2}:\d{2}:\d{2})(?:\.(\d{1,6}))?(Z|[+-]\d{2}:\d{2})$/.exec(value);
  if (!match) return null;
  const local = Date.parse(`${match[1]}T${match[2]}Z`);
  if (!Number.isFinite(local) || new Date(local).toISOString().slice(0, 19) !== `${match[1]}T${match[2]}`) return null;
  const milliseconds = Date.parse(`${match[1]}T${match[2]}${match[4]}`);
  if (!Number.isFinite(milliseconds)) return null;
  return BigInt(milliseconds) * 1000n + BigInt((match[3] ?? '').padEnd(6, '0'));
}

function checkbox(value) {
  if (value === true || value === 'true' || value === 1 || value === '1') return true;
  if (value === false || value === 'false' || value === 0 || value === '0') return false;
  return value;
}

const structuredColumns = new Set(['sdb_instances_json', 'wc_instances_json', 'occupants_json']);

// These fields are exposed as false by the read contract when an old NocoDB
// row contains null/empty. The list is deliberately explicit: nullable
// three-state choices such as acces_facile_rue and the sanitary door answers
// must keep null distinct from false.
export const legacyDefaultFalseColumns = new Set([
  'beneficiaire_apa', 'reconnaissance_invalidite_mdph', 'aide_a_domicile',
  'beneficiaire_prepare',
  'sous_sol', 'rdc', 'etage', 'second_etage', 'third_etage', 'garage',
  'veranda', 'balcon', 'terrasse', 'jardin', 'chauffage',
  'radiateurs_electrique', 'chaudiere_gaz', 'chaudiere_fioul',
  'pompe_a_chaleur', 'chaudiere_collective', 'cheminee_pole_bois',
  'poele_granules', 'autre_chauffage', 'volets_roulants_manuels_entier',
  'volets_roulants_electriques_entier', 'volets_persiennes_entier',
  'cheminement_escalier_exterieur', 'cheminement_escalier_interieur',
  'cheminement_pente_douce', 'cheminement_plat',
  'cheminement_quelques_marches', 'cheminement_par_arriere',
  'cheminement_seuil_porte', 'difficultes_circulation_interieure',
]);

// GET maps these nullable database strings to an empty application string.
// Relation ids, dates and nullable booleans intentionally stay out.
export const legacyDefaultEmptyStringColumns = new Set([
  'prenom', 'nom', 'prenom_occupant_2', 'nom_occupant_2', 'mail', 'telephone',
  'adresse_logement', 'ville_libre', 'code_postal_libre',
  'reconnaissance_invalidité_mdph_txt', 'aide_a_domicile_txt',
  'dependance_particuliere_txt', 'personne_confiance',
  'telephone_personne_confiance', 'mail_personne_confiance',
  'numero_securite_sociale_monsieur', 'numero_securite_sociale_madame',
  'compte_anah', 'nature_accompagnement', 'envoi_rapport',
  'personnes_presentes_visite', 'annee_construction', 'annee_habitation',
  'surface_habitable', 'description_sous_sol', 'description_rdc',
  'description_etage', 'volets_roulants_manuels_localisation',
  'volets_roulants_electriques_localisation', 'volets_persiennes_localisation',
  'commentaire', 'observation_accessibilite', 'observations',
  'observation_equipements', 'projet_souhait_usage', 'resume_preconisations',
  'observation_equipements_utilisation',
]);

function defaultFalse(value) {
  if (value == null || value === '') return false;
  return checkbox(value);
}

function dossierStatus(value) {
  if (typeof value !== 'string') return value;
  const normalized = value.trim().normalize('NFD').replace(/\p{Diacritic}/gu, '')
    .toLowerCase().replace(/[\s-]+/g, '_');
  const aliases = new Map([
    ['a_visiter', 'TO_VISIT'], ['to_visit', 'TO_VISIT'],
    ['en_cours', 'IN_PROGRESS'], ['in_progress', 'IN_PROGRESS'],
    ['valide', 'GRANT_VALIDATED'], ['grant_validated', 'GRANT_VALIDATED'],
    ['clos', 'CLOSED'], ['closed', 'CLOSED'],
  ]);
  return aliases.get(normalized) ?? value;
}

export function toDatabaseDossierStatus(value) {
  const canonical = dossierStatus(value);
  return new Map([
    ['TO_VISIT', 'À visiter'],
    ['IN_PROGRESS', 'En cours'],
    ['GRANT_VALIDATED', 'Validé'],
    ['CLOSED', 'Clos'],
  ]).get(canonical) ?? value;
}
function numeric(value) {
  if (typeof value === 'number') return Number.isFinite(value) && Math.abs(value) <= Number.MAX_SAFE_INTEGER ? value : null;
  if (typeof value !== 'string' || !/^[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?$/.test(value.trim())) return null;
  const result = Number(value);
  return Number.isFinite(result) && Math.abs(result) <= Number.MAX_SAFE_INTEGER ? result : null;
}

export function createDatabaseValueComparator(columns = []) {
  const types = new Map(columns.map((column) => [column.title, column.uidt]));
  return (key, a, b) => {
    if (isDeepStrictEqual(a, b)) return true;
    if (types.get(key) === 'DateTime') {
      const left = instantMicros(a);
      return left !== null && left === instantMicros(b);
    }
    if (legacyDefaultFalseColumns.has(key)) {
      return isDeepStrictEqual(defaultFalse(a), defaultFalse(b));
    }
    if (types.get(key) === 'Checkbox') return isDeepStrictEqual(checkbox(a), checkbox(b));
    if (types.get(key) === 'Number') {
      const left = numeric(a);
      return left !== null && left === numeric(b);
    }
    if (structuredColumns.has(key) && typeof a === 'string' && typeof b === 'string') {
      try {
        const left = JSON.parse(a);
        const right = JSON.parse(b);
        return Array.isArray(left) && Array.isArray(right) && isDeepStrictEqual(left, right);
      } catch { return false; }
    }
    if (legacyDefaultEmptyStringColumns.has(key)
        && (a == null || a === '') && (b == null || b === '')) return true;
    if (key === 'status') return isDeepStrictEqual(dossierStatus(a), dossierStatus(b));
    return false;
  };
}

export function canonicalDatabasePatch(fields, columns) {
  const types = new Map(columns.map((column) => [column.title, column.uidt]));
  return Object.fromEntries(Object.entries(fields).map(([key, value]) =>
    [key, types.get(key) === 'Checkbox' ? checkbox(value) : value]));
}

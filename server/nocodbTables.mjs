const tableId = /^[A-Za-z0-9_]+$/;

export const DEFAULT_NOCODB_TABLES = Object.freeze({
  beneficiaires: 'muvp56d5i9z2qbe', logements: 'mgdpvdrnzyy6n4k', dossiers: 'mez74y7ndoej30p',
  observations: 'mbkuomk0aazes1c', diagnosticSanitaires: 'mdukulxcd18ae3o',
  mesuresAnthropometriques: 'mbaj91z97utreco', visitPhotos: 'mfeu4lijbge4opz',
  communes: 'mtwhx481kcfn19h', epci: 'mntevbq41mk4y6h', situationProprietaire: 'mqwqqzsfopejd5q',
  statutOccupation: 'mqgrx6hut8oskbr', dependancesParticulieres: 'm09p3a4xns7wqdg',
  etablissements: 'mw1ajdw6ictkdzf', ergotherapeutes: 'mww8mr4ngp3nbxh',
  caissesRetraite: 'mxmsm320nnljdmm', caissesRetraiteComplementaires: 'm067j5k5a03beog',
  wikiTags: 'mt36dqp3ybw5dtt', wiki: 'm34ho32msfz8b2x', typeDeLogement: 'mp34j2fxnupoxd0',
  porteDeGarage: 'my9em2miybwiwr0', portail: 'm8e1g1ab3a4ubtx', contexteDeVie: 'mjyj2lz4wfs5pd5',
  informationsAdministratives: 'mv2hgaqj3u5ittg', baremesAnah: 'mtg6pgm9t274ya9',
});

export function resolveNocodbTables(raw = process.env.NOCODB_TABLE_IDS_JSON) {
  if (!String(raw || '').trim()) return { ...DEFAULT_NOCODB_TABLES };
  let overrides;
  try {
    overrides = JSON.parse(raw);
  } catch {
    throw new Error('NOCODB_TABLE_IDS_JSON must be valid JSON');
  }
  if (!overrides || Array.isArray(overrides) || Object.getPrototypeOf(overrides) !== Object.prototype) {
    throw new Error('NOCODB_TABLE_IDS_JSON must be a plain object');
  }
  for (const [key, value] of Object.entries(overrides)) {
    if (!Object.hasOwn(DEFAULT_NOCODB_TABLES, key)) throw new Error(`Unknown NocoDB table key: ${key}`);
    if (typeof value !== 'string' || !tableId.test(value)) throw new Error(`Invalid NocoDB table id for ${key}`);
  }
  return { ...DEFAULT_NOCODB_TABLES, ...overrides };
}

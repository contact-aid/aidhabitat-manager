import { WIKI_FILTER_TAGS } from './wikiLibraryCatalog.mjs';

const asArray = (value) => Array.isArray(value) ? value : [];
const stringValue = (value) => value == null ? '' : String(value);

export const resolveWikiPrimaryTag = ({ title, description, category, tags }) => {
  // The UI offers Autre explicitly. A manual choice must win over text
  // inference on create, update, and every subsequent library read.
  for (const tag of asArray(tags)) {
    const key = stringValue(tag).trim().toLowerCase();
    if (key === 'autres') return 'Autre';
    const explicit = WIKI_FILTER_TAGS.find((allowed) => allowed.toLowerCase() === key);
    if (explicit) return explicit;
  }

  const haystack = `${stringValue(title)} ${stringValue(description)} ${stringValue(category)} ${asArray(tags).join(' ')}`.toLowerCase();
  if (haystack.includes('wc') || haystack.includes('toilette')) return 'WC';
  if (haystack.includes('barre') || haystack.includes('main courante') || haystack.includes('accoudoir') || haystack.includes('relevage') || haystack.includes('redressement')) return "Barres d'appui";
  if (haystack.includes('douche') || haystack.includes('baignoire') || haystack.includes('lavabo') || haystack.includes('mitigeur') || haystack.includes('salle de bain')) return 'Salle de bain';
  if (haystack.includes('cuisine') || haystack.includes('evier') || haystack.includes('plan de travail') || haystack.includes('tiroir')) return 'Cuisine';
  if (haystack.includes('chambre') || haystack.includes('lit')) return 'Chambre';
  if (haystack.includes('monte') || haystack.includes('escalier') || haystack.includes('ascenseur') || haystack.includes('plateforme') || haystack.includes('reperage contrastant')) return 'Escaliers & ascenseur';
  if (haystack.includes('seuil surbaisse') || haystack.includes('seuil plat') || haystack.includes('porte') || haystack.includes('fenetre') || haystack.includes('volet') || haystack.includes('garage') || haystack.includes('portail')) return 'Ouvertures';
  if (haystack.includes('revetement antiderapant')) return 'Accès extérieurs';
  if (haystack.includes('rampe') || haystack.includes('pente') || haystack.includes('acces') || haystack.includes('passerelle') || haystack.includes('exterieur')) return 'Accès extérieurs';
  if (haystack.includes('revetement') || haystack.includes('sol ') || haystack.includes('sol-') || haystack.includes('parquet') || haystack.includes('doublage') || haystack.includes('isole')) return 'Equipements';
  if (haystack.includes('eclairage') || haystack.includes('lumineux') || haystack.includes('detection') || haystack.includes('vmc') || haystack.includes('poele') || haystack.includes('television') || haystack.includes('penderie')) return 'Equipements';
  return 'Equipements';
};


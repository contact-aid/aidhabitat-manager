# Import des photos de preconisations

Import termine le 15 septembre 2026 dans la bibliotheque NocoDB de production.

- 229 photos sources lisibles.
- 54 correspondances avec des fiches existantes, conservees sans modification.
- 175 nouvelles fiches, chacune avec titre, description, categorie et image.
- 230 fiches au total apres import : les 229 photos et une fiche preexistante
  supplementaire. Les 55 lignes presentes avant import sont inchangees.
- Aucun dossier, releve de visite ou enregistrement Airtable modifie.

Les descriptions decrivent les equipements sans inventer leurs dimensions,
capacites ou garanties de securite. Les noms de fichiers servent de titres ;
les suffixes techniques des fichiers commerciaux et quelques coquilles sont
nettoyes. Plusieurs photos d'un meme equipement restent des fiches distinctes.

## Images et hors ligne

Les originaux Google Drive sont intacts (40 734 129 octets). Les nouvelles
copies JPEG representent 5 392 608 octets. Chaque image respecte la limite
LongText NocoDB de 100 000 caracteres apres encodage en data URL.

Les nouvelles images sont stockees dans photo_base64 avec les fiches. Apres
la premiere synchronisation en ligne, WikiRepository conserve l'image complete
dans SQLite, avec le titre et la description. La bibliotheque et le selecteur
de preconisations lisent tous deux ce repository local.

Le test Flutter a charge les 175 fiches et leurs vraies images, ferme puis
rouvert le fichier SQLite et verifie l'egalite exacte des contenus sans nouveau
telechargement. Le parcours en mode avion sur iPad reel reste a verifier.

## Tracabilite

Import additif uniquement : aucune requete UPDATE ou DELETE. Identifiants
stables par chemin source, empreintes SHA-256 des originaux et des copies,
relecture de chaque creation et comparaison finale des 55 anciennes lignes.
L'arret initial sur une image trop volumineuse a conserve la premiere creation
confirmee ; la reprise l'a reconnue et n'a pas cree de doublon.

Sauvegarde, plan, images et journal local (ignores par Git) :
`tmp/preco-import-20260915-final/`.

Outils : `tools/import-preco-photos.mjs`, `tools/precoPhotoCatalog.mjs`.
La preparation n'ecrit pas dans NocoDB. Executer `optimize` apres `prepare`,
puis `apply` avec le meme plan ; `verify` effectue les controles sans ecriture
distante. Ne pas modifier les images d'un plan deja applique.

Validation : quatre tests du catalogue, test Flutter sur les 175 images,
analyse Flutter ciblee et relecture NocoDB reussis. Aucun changement du runtime,
aucune archive iOS, aucun push ou deploiement necessaire a cet import de donnees.

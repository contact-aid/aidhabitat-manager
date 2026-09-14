# Audit App'Ergo iPad et web - 14 septembre 2026

## Perimetre et limites

Audit du code a `9c6a9cfa813686c972c667aa80ae5192e402ffaa`, des livraisons,
de la synchronisation, des documents/PDF, de la bibliotheque et des affectations.
Lectures distantes uniquement ; aucune modification de donnees, de configuration,
aucun build ou deploiement. Seul ce rapport est ajoute au depot.

Les reproductions utilisent des fonctions extraites de `server/index.mjs` dans
un contexte VM avec stockage et transport simules. Elles ne sont pas des tests
HTTP authentifies ni des essais sur les dossiers reels.
Pas d'acces aux files locales des trois iPad ni de verification de leur version
installee aujourd'hui. La recette web visuelle est limitee a la connexion sans
authentification. Cet audit ne certifie pas l'absence de tout autre bug.

## Etat des versions

- `main` et `origin/main` identiques apres `git fetch`, dernier commit du 10 septembre.
- Aucune modification de code suivie en attente au debut de l'audit.
- Script non suivi preexistant : `tools/refresh-nocodb-from-airtable-current-dossiers.mjs`.
  Il n'a pas ete execute et ne doit pas etre inclus automatiquement dans un push.
- Archive iPad locale controlee : 1.0.0 (19). Cela ne prouve pas son installation
  sur chaque appareil ni l'absence d'une livraison realisee sur un autre poste.
- Web public : `/version.json` annonce 1.0.0 (10), pas le paquet web 19 prepare.
- SHA256 du `main.dart.js` public :
  `088dc274348f8a65490b4b1b437471c3975295b713588280d8cc769031477d6e`.
- SHA256 du paquet web 19 local :
  `832b096aa19aea4027a2327f0e7d395977152f5ac57ad5d34276fc1f0f75c39f`.
- API publique : `/api/health/live` annonce `7b47dca77a780780661ccc56c1b0f018d60cd0d1`.
  Ce commit contient le correctif de precision des dates NocoDB. Le commit 19
  suivant ne necessitait pas une nouvelle version du serveur.

## Constats prioritaires

### A01 - P1 : succes de bibliotheque sans ecriture NocoDB confirmee

Sources : `server/index.mjs:5204`, `server/index.mjs:5286`,
`server/index.mjs:5323`, `server/index.mjs:1573`.

Les routes POST, PUT et DELETE de `/api/wiki-library` interceptent l'erreur
NocoDB, mais continuent a repondre success=true ou HTTP 204. Le fichier local
du serveur est modifie avant cette ecriture ; cela ne vaut pas une sauvegarde
dans NocoDB, qui reste prioritaire lors des lectures suivantes.

Reproduction du POST : deux tentatives, deux appels de creation NocoDB forces
en erreur, zero ligne en base simulee, mais deux reponses de succes.
Un element peut donc paraitre synchronise puis disparaitre ou revenir a son
ancienne version apres actualisation ; une suppression peut reapparaitre.
La reproduction porte sur POST ; PUT/DELETE ont le meme traitement d'erreur,
constate par lecture, sans reproduction de ces deux routes.

Action : n'acquitter qu'apres persistence NocoDB confirmee ; conserver la file
client et renvoyer une erreur recuperable si la confirmation manque.

### A02 - P1 : paquet web recent non deploye

Preuves : versions et empreintes ci-dessus ; le fichier de livraison build 19
indique explicitement que le web n'a pas ete publie.

Les corrections preparees pour le paquet web 19 ne sont pas celles servies
sur `app.aidhabitat.fr`. Les utilisateurs web et iPad peuvent donc conserver
des comportements differents malgre la validation du nouveau code.

Action : preparer une publication web controlee, verifier le paquet et la
reprise du stockage local, puis tester l'actualisation sans effacer les saisies.
Ne pas demander de vider les donnees du navigateur pour forcer cette mise a jour.

### A03 - P1 : protection inter-appareils non atomique

Sources : `server/index.mjs:880`, `server/index.mjs:7373`,
`server/index.mjs:7405`, `server/index.mjs:8523`.

Le flag `AIDHABITAT_CONDITIONAL_SYNC` est desactive dans le conteneur actif,
conformement au choix de compatibilite du build 18. Le controle de date precede
l'ecriture : deux requetes ayant lu la meme version peuvent passer le controle,
puis ecrire successivement. Une date attendue absente/invalide ne bloque pas
non plus ce chemin historique. La relecture ne rend pas l'ecriture atomique.

Risque confirme par le code, pas de perte inter-appareils reproduite en production.
Ne pas activer le flag seul : il faut migrer les versions et tous les chemins
d'ecriture, puis tester la compatibilite des clients et le schema NocoDB.

### A04 - P2 : doublons possibles lors du rejeu d'une creation de bibliotheque

Sources : `server/index.mjs:5167`,
`aid_habitat_app/lib/services/nocodb_api_client.dart:1848`,
`aid_habitat_app/lib/services/nocodb_sync_service.dart:1523`.

Le client n'envoie pas d'identifiant stable de creation ; le serveur genere
un nouvel UUID a chaque POST. Si la premiere ecriture reussit mais que sa reponse
est perdue, une nouvelle tentative peut creer un second element.
Reproduction isolee : deux requetes identiques, deux UUID et deux lignes simulees.

Action : conserver un identifiant de mutation stable de bout en bout et rendre
le traitement serveur idempotent. Un simple dedoublonnage par titre ne suffit pas.

### A05 - P2 : affectation automatique a Coralie pendant une lecture

Sources : `server/index.mjs:3623`, `server/index.mjs:3712`.

`getDossiersForApp` appelle un backfill qui remplace les affectations vides,
`E1` ou `user` par Coralie. Une consultation peut ainsi decider de l'auteur sans
instruction explicite. Reproduction isolee : affectation vide transformee en
Coralie avec une ecriture simulee.

Controle distant en lecture seule : 21 dossiers, zero affectation de ce type.
Le risque est latent, pas une mauvaise affectation constatee aujourd'hui.
Action : sortir cette migration du parcours de lecture et demander une decision
explicite pour les affectations inconnues.

### A06 - P2 : deploiement automatique API toujours incomplet

Source : `.github/workflows/build-deploy-api.yml:145`.

Le workflow exige `EASYPANEL_API_WEBHOOK`. La liste des secrets GitHub ne contient
pas ce secret et le dernier workflow API est en echec. L'API active a toutefois
ete deployee manuellement et repond correctement : pas de panne serveur deduite.

Action : configurer un mecanisme de deploiement valide et conserver le controle
du SHA actif. Un push ou une image construite ne prouve pas une mise en ligne.

## Optimisations et dette restantes

- `server/index.mjs:3712` charge cinq tables completes avant le filtrage des
  dossiers par utilisateur. Pas de fuite client demontree ; cout serveur et
  latence a surveiller lorsque le nombre de dossiers augmente. Mesurer avant
  de remplacer ce parcours, notamment ses migrations implicites.
- `DocumentRepository.enqueueAnnotatedPageBytes` (`document_repository.dart:699`)
  reste une ancienne methode d'annotations locales sans appel trouve dans le
  code de l'app. Ce n'est pas une preuve que les annotations actuelles ne sont
  pas synchronisees. Nettoyage possible apres verification des usages externes.
- Les anciens routeurs et `helpers.mjs` dupliquent une partie de `index.mjs`.
  Ne pas corriger un routeur non monte en pensant modifier le serveur actif.

## Verifications executees

- Flutter : 728 tests passes, execution serielle dans une copie temporaire.
- Analyse Flutter : aucune erreur signalee.
- Serveur : 164 tests passes.
- Publication et export PDF web : 47 tests passes.
- TypeScript : `tsc --noEmit` termine sans erreur.
- Parcours critiques : 20/20 controles passes.
- Stack live : sept controles passes ; liveness/readiness et CORS corrects,
  GET/HEAD `/` et `/openapi.json` renvoient 404, pas 500.
- Connexion web : screenshots inspectes a 1366 et 768 px, rendu non vide,
  aucune erreur JavaScript de page observee. Aucun login effectue.
- Aucun appel direct a l'API Airtable trouve dans les repertoires runtime
  `api`, `server`, `shared` et `aid_habitat_app/lib` ; aucun import execute.

Le premier lancement Flutter dans le chemin contenant une apostrophe echoue
dans le code genere du lanceur de tests. Il a ete interrompu puis remplace par
la suite complete reussie dans `/tmp/appergo-audit-20260914.kWGD7L`.
Les suites vertes ne couvraient pas les reproductions A01/A04/A05 ci-dessus.

Logs : `/tmp/appergo-audit-20260914-{node,analyze,tsc,flutter-safe,release-tests}.log`.

## Suite proposee

Corriger d'abord A01 et A04 ensemble, avec tests de coupure et de rejeu ; traiter
A05 separement. Preparer ensuite la publication web et sa recette. A03 demande
un chantier de migration dedie et ne doit pas etre active en urgence. Aucun
nouveau build iPad n'a ete lance pendant cet audit.

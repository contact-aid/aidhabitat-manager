# Audit de conception, fiabilite et performance App'Ergo

Date : 9 septembre 2026. Etat audite : commit `10df5d4` et modifications locales presentes.

## Conclusion

Les optimisations les plus utiles concernent la sauvegarde des documents, la coherence du cache et la quantite de donnees relues. La base offline-first, Flutter et SQLite restent adaptes a cette application. Une reecriture complete n'est pas justifiee par les elements observes.

Plusieurs protections existent deja : SQLCipher sur iOS, secrets de session dans le Keychain, file de synchronisation persistante, reprise reseau, transactions pour de nombreuses saisies metier, limitation a trois groupes de mutations et rotation PDFKit en arriere-plan. Les problemes viennent surtout de chemins qui ne respectent pas encore ces garanties de facon uniforme.

Cet audit identifie 20 constats. P1 signifie a traiter en priorite pour la fiabilite ou la maintenance de securite ; P2 signifie defaut fonctionnel ou optimisation importante ; P3 signifie dette de maintenance. Les scenarios non reproduits sur appareil sont explicitement distingues des reproductions automatiques.

## Perimetre et preuves

- Analyse des points d'entree Flutter, ecrans principaux, documents, notes, sauvegardes, repositories SQLite, synchronisation, authentification et appels HTTP.
- Analyse des routes Express actives, stockage NocoDB, generation de rapports, Docker et workflows GitHub Actions.
- Inventaire des imports statiques Flutter : 130 fichiers, 82 163 lignes dans `lib/`, commentaires et lignes vides inclus.
- Analyse du code React historique, encore present dans les commandes de build et les controles CI.
- Aucun changement de code applicatif, aucun commit, build distribue ou changement de donnees metier effectue pendant cet audit.
- Les fichiers deja modifies localement ont ete conserves. Le rapport est le seul ajout au depot pour cet audit. Trois tests de reproduction ont ete ajoutes uniquement dans la copie temporaire de test.

Verifications executees :

| Verification | Resultat |
| --- | --- |
| `flutter analyze --no-pub` | Aucune anomalie |
| Suite Flutter complete, via `tool/test_safely.sh` | 142 tests reussis |
| Tests Node : `test/*.test.mjs`, `shared/*.test.mjs`, `server/*.test.mjs` | 24 tests reussis |
| `npm run test:sync-contract` | Reussi ; les 10 tests Node inclus sont deja comptes parmi les 24 |
| `npm run check:critical` | 20 controles statiques reussis |
| `git diff --check` | Reussi |
| `tsc --noEmit` | Echec : composant `X` non defini, voir F20 |
| `npm audit --json` | 5 paquets signales : 3 high, 2 moderate |
| API `/api/health/live` | HTTP 200, environ 0,28 s sur une requete |
| API `/api/health/ready` | HTTP 200, environ 0,30 s sur une requete |
| 3 reproductions SQLite supplementaires | Les 3 comportements indesirables sont reproduits |

Le premier essai de tests avec `--no-pub` dans une copie sans `.dart_tool` a echoue faute de resolution des dependances. Le lancement normal du script a ensuite execute les 142 tests avec succes, sans modifier le lockfile du projet.

Limites : aucun profilage Instruments/DevTools sur les trois iPad, aucune mesure de charge en production, aucune inspection des volumes et sauvegardes actuels du serveur, aucune preuve du SHA exact embarque dans TestFlight. Les temps du healthcheck ne mesurent pas les performances des documents. Le nombre actuel de dossiers et le volume NocoDB n'ont pas ete relus ; les exemples de volumetrie ci-dessous sont des calculs, pas des mesures de production.

## Priorites de fiabilite

### F01 - P1 - Une sauvegarde peut echouer puis fermer le document

**Constat de code.** `_handleSave()` intercepte l'erreur et affiche un message, mais ne renvoie pas un resultat d'echec. Dans le chemin de fermeture avec choix Enregistrer, `_handleClose()` attend cette methode puis ferme la fenetre dans tous les cas. De plus, les deux wrappers PDF interceptent les erreurs d'ecriture page par page puis vident `_dirtyPages`. L'interface peut donc perdre l'indication de modifications non sauvegardees.

**Scenario.** Stockage indisponible, ecriture impossible ou exception pendant la rotation ; l'utilisateur choisit Enregistrer en quittant. La fenetre peut se fermer malgre l'echec. Pour les annotations, certaines erreurs sont entierement silencieuses.

**Correction recommandee.** Retourner un resultat explicite de sauvegarde ; conserver la fenetre et l'etat modifie en cas d'echec ; retirer uniquement les pages dont la persistance a reussi ; attendre tous les enregistrements avant de confirmer.

Sources : [gestion de sauvegarde](/Users/aidhabitat/Downloads/aid'habitat-manager/aid_habitat_app/lib/screens/documents_screen.dart:2599), [fermeture](/Users/aidhabitat/Downloads/aid'habitat-manager/aid_habitat_app/lib/screens/documents_screen.dart:2909), [PDF natif](/Users/aidhabitat/Downloads/aid'habitat-manager/aid_habitat_app/lib/screens/documents_screen.dart:4107), [PDF web](/Users/aidhabitat/Downloads/aid'habitat-manager/aid_habitat_app/lib/screens/documents_screen.dart:3725).

### F02 - P1 - Les annotations PDF ne sont pas synchronisees dans le PDF partage

**Constat de code.** Sur iOS, les traits sont enregistres dans des fichiers JSON a cote des pages rendues ; le PDF original reste intact. Sur web, les aplats sont stockes dans `annotations_json`, explicitement sans operation de synchronisation. Le telechargement avec annotation ne traite que les images simples, puis utilise le telechargement ordinaire pour les PDF.

**Impact.** Un PDF qui semble annote dans l'app peut etre envoye sans ses annotations, et un autre appareil ne recupere pas ces traits par la synchronisation actuelle. Ces annotations n'ont pas la meme garantie de sauvegarde distante que le document original. La rotation peut en outre desaligner les couches locales si le fichier tourne mais pas leur representation.

**Correction recommandee.** Definir une representation durable des annotations par page, synchronisee et versionnee. Produire un PDF comprenant les annotations pour le partage, tout en conservant l'original et les traits editables. Tester le parcours annotation + rotation + partage + ouverture sur un second iPad.

Sources : [branche de sauvegarde PDF](/Users/aidhabitat/Downloads/aid'habitat-manager/aid_habitat_app/lib/screens/documents_screen.dart:2609), [annotations locales web](/Users/aidhabitat/Downloads/aid'habitat-manager/aid_habitat_app/lib/services/document_repository.dart:676), [export](/Users/aidhabitat/Downloads/aid'habitat-manager/aid_habitat_app/lib/screens/documents_screen.dart:2915).

### F03 - P1 - Un nouveau document distant conserve les anciens fichiers locaux

**Reproduit en test SQLite.** `mergeRemoteDocuments()` reconnait le document via `clientDocumentId` et actualise ses metadonnees, mais preserve `local_file_path`, `local_file_data_url` et les annotations. Le serveur change pourtant l'UUID du contenu a chaque remplacement. `_persistRemoteDocumentsLocally()` ignore ensuite les lignes dont le fichier local existe deja. La preview prefere ce fichier local au nouveau contenu distant.

**Impact.** Un autre iPad peut afficher ou partager une ancienne version apres une rotation faite ailleurs, meme si les metadonnees sont recentes. Changer seulement la cle de vignette ne corrige pas les octets sources.

**Correction recommandee.** Separer identite du document et revision du contenu. Associer chaque fichier local a sa revision distante ; telecharger la nouvelle revision, la verifier, puis basculer la reference locale. Conserver distinctement les versions non synchronisees.

Sources : [fusion distante](/Users/aidhabitat/Downloads/aid'habitat-manager/aid_habitat_app/lib/services/document_repository.dart:1695), [conservation du fichier existant](/Users/aidhabitat/Downloads/aid'habitat-manager/aid_habitat_app/lib/services/document_repository.dart:1995), [priorite du fichier local](/Users/aidhabitat/Downloads/aid'habitat-manager/aid_habitat_app/lib/components/doc_thumbnails.dart:235), [remplacement serveur](/Users/aidhabitat/Downloads/aid'habitat-manager/server/mobileSyncStore.mjs:1282).

### F04 - P1 - Les remplacements de documents ne sont pas atomiques

**Constat de code.** `enqueueReplacementFile()` et `enqueueReplacementBytes()` ecrivent le fichier, suppriment des operations, modifient la ligne document puis inserent la nouvelle operation dans des appels separes. Les operations supprimees incluent celles en cours (`running`). Les ecritures natives utilisent une copie/ecriture directe a la destination, sans fichier temporaire suivi d'un renommage atomique.

**Scenario de risque.** Arret entre la modification du document et l'insertion de l'operation : nouveau fichier local sans intention d'envoi durable. Arret pendant la copie : fichier destination potentiellement incomplet. Une requete reseau deja lancee continue meme si sa ligne `running` a ete supprimee et peut encore actualiser les metadonnees locales a son retour.

**Correction recommandee.** Fichiers immuables par revision, ecriture temporaire + validation + renommage, puis transaction SQLite reunissant reference document et operation. Ne pas supprimer une operation en vol ; rendre ses acquittements conditionnels a la revision qu'elle transporte. Appliquer le meme principe aux metadonnees document.

Sources : [remplacement fichier](/Users/aidhabitat/Downloads/aid'habitat-manager/aid_habitat_app/lib/services/document_repository.dart:1031), [remplacement bytes](/Users/aidhabitat/Downloads/aid'habitat-manager/aid_habitat_app/lib/services/document_repository.dart:896), [metadonnees](/Users/aidhabitat/Downloads/aid'habitat-manager/aid_habitat_app/lib/services/document_repository.dart:1246), [ecritures natives](/Users/aidhabitat/Downloads/aid'habitat-manager/aid_habitat_app/lib/services/native_file_protection.dart:65), [acquittement upload](/Users/aidhabitat/Downloads/aid'habitat-manager/aid_habitat_app/lib/services/nocodb_sync_service.dart:1414).

### F05 - P1 - Les conflits peuvent ecraser silencieusement une modification distante

**Constat de code.** A la reception d'un conflit HTTP 409, `_autoResolveConflictForceLocal()` rejoue l'operation sans le controle de version. L'ecran beneficiaire transmet une grande partie du formulaire au repository. Precision apres relecture : `updatePatient()` realise deja un diff contre SQLite avant l'envoi ; le formulaire complet n'est donc pas systematiquement transmis au serveur. Ce diff n'est toutefois pas une comparaison a trois versions avec la copie distante.

**Scenario.** Deux appareils travaillent sur le meme dossier. Une ancienne copie hors ligne est reconnectee apres une modification sur l'autre appareil. Le rejeu force-local peut remplacer des champs distants par leur ancienne valeur. Il s'agit d'un risque de conception confirme, pas d'une perte de donnees constatee sur un dossier reel pendant l'audit.

**Correction recommandee.** Envoyer uniquement les champs modifies ; fusionner les changements independants ; conserver un conflit explicite si le meme champ a change des deux cotes. Utiliser une revision serveur pour la concurrence plutot que la seule horloge de l'iPad.

Sources : [rejeu force-local](/Users/aidhabitat/Downloads/aid'habitat-manager/aid_habitat_app/lib/services/nocodb_sync_service.dart:446), [formulaire complet](/Users/aidhabitat/Downloads/aid'habitat-manager/aid_habitat_app/lib/screens/visit_report/beneficiary_tab.dart:475), [controle serveur](/Users/aidhabitat/Downloads/aid'habitat-manager/server/index.mjs:806).

### F06 - P2 - La file de synchronisation n'est pas rattachee a la session qui a cree les operations

**Constat de code.** `fetchRunnableOperations()` selectionne toutes les operations pending. `signOut()` conserve legitimement les donnees offline et la file. Les operations ne sont cependant pas filtrees par utilisateur a leur reprise. Les indicateurs et tentatives d'envoi peuvent ainsi concerner les modifications d'un autre profil precedemment utilise sur l'appareil.

**Impact.** Avec un changement Coralie/Christelle, des operations peuvent etre rejouees avec une session qui n'a plus les droits attendus. Les 403 sont classes comme transitoires, ce qui peut produire une attente durable. Les controles serveur limitent l'acces aux dossiers ; ce constat ne prouve pas un contournement de ces controles.

**Correction recommandee.** Conserver l'auteur et le perimetre d'autorisation de l'operation ; mettre en pause les operations inaccessibles au profil courant ; distinguer session expiree et acces refuse. Ajouter une generation de session aux traitements en vol pour ignorer leurs retours apres deconnexion.

Sources : [selection de file](/Users/aidhabitat/Downloads/aid'habitat-manager/aid_habitat_app/lib/services/sync_repository.dart:40), [deconnexion](/Users/aidhabitat/Downloads/aid'habitat-manager/aid_habitat_app/lib/services/auth_service.dart:899), [classification 403](/Users/aidhabitat/Downloads/aid'habitat-manager/aid_habitat_app/lib/services/nocodb_sync_service.dart:99), [arret moteur](/Users/aidhabitat/Downloads/aid'habitat-manager/aid_habitat_app/lib/services/sync_engine.dart:177).

### F07 - P1 - Dependances serveur vulnerables et runtime Docker en fin de support

**Verification executee.** `npm audit` signale `multer`, `nodemailer`, `fast-uri` en high, `hono` et `qs` en moderate. Ce sont cinq paquets affectes, pas cinq incidents observes. Des correctifs sont disponibles selon le registre. `multer` est effectivement utilise dans les uploads ; l'exploitabilite de chaque avis n'a pas ete testee.

L'image declare `FROM node:20-alpine`, et les workflows API/sync utilisent Node 20. Le Mac execute Node 24.11.0. La documentation officielle classe Node 20 en fin de vie ; cette image doit etre alignee sur une branche LTS maintenue. Le runtime exact du conteneur actuellement deploye n'est pas expose par le healthcheck.

**Correction recommandee.** Mettre a jour le lockfile de facon ciblee, tester uploads interrompus, multipart et feedback, puis reconstruire l'image sur une LTS maintenue. Eviter un `audit fix --force` global sans revue. Verifier aussi `authHeadersFor()` : comparer les origines parsees plutot qu'un prefixe de chaine, et utiliser cette selection pour les URL externes.

Sources : [image Docker](/Users/aidhabitat/Downloads/aid'habitat-manager/Dockerfile.api:34), [dependances](/Users/aidhabitat/Downloads/aid'habitat-manager/package.json:43), [selection du header](/Users/aidhabitat/Downloads/aid'habitat-manager/aid_habitat_app/lib/services/media_cache_service.dart:143), [Node officiel](https://nodejs.org/en/about/previous-releases), [avis multipart Multer](https://github.com/advisories/GHSA-wc9g-mqfw-jrwm).

## Chargements et performance

### F08 - P2 - Une actualisation complete relit tous les dossiers, leurs enfants et leurs notes

`refreshWorkspaceFromRemote()` charge la liste complete, quatre sources globales, quatre tables enfants par dossier, toutes les notes par patient puis le statut ANAH. Pour D dossiers et P patients distincts, cela represente environ `6 + 4D + P` appels API, hors authentification supplementaire, documents, retries et chargements d'ecrans. Exemple : 19 dossiers pour 19 patients donnent 101 appels. Le nombre de dossiers actuel n'a pas ete mesure.

`MainScreen.initState()` recharge aussi trois des memes referentiels. L'ouverture du detail d'un dossier appelle `refreshDossierRecordsFromRemote()`, qui relit encore la liste globale.

**Optimisation.** Garder la preparation hors ligne, mais lui donner un manifest de revisions et un indicateur de disponibilite. Faire une synchronisation incrementale avec suppressions explicites, mutualiser les appels en cours, actualiser les referentiels selon leur revision et fournir un endpoint de detail cible. Ne pas simplement supprimer les prechargements necessaires au terrain.

Sources : [workspace](/Users/aidhabitat/Downloads/aid'habitat-manager/aid_habitat_app/lib/services/data_service.dart:963), [detail](/Users/aidhabitat/Downloads/aid'habitat-manager/aid_habitat_app/lib/services/data_service.dart:1137), [demarrage ecran](/Users/aidhabitat/Downloads/aid'habitat-manager/aid_habitat_app/lib/screens/main_screen.dart:117).

### F09 - P2 - Des endpoints pour un dossier lisent des tables NocoDB entieres

Les routes diagnostics sanitaires, mesures et observations appellent `queryAll()` sans filtre dossier puis recherchent la ligne en JavaScript. La fonction parcourt toutes les pages de 100 lignes. Cela amplifie F08 : on relit les memes tables pour chaque dossier. Certains PATCH beneficiaire/logement lisent aussi des ensembles entiers.

**Optimisation.** Appliquer les filtres NocoDB au plus pres des donnees, limiter les colonnes et choisir la derniere ligne cote requete lorsque possible. Mutualiser les referentiels et les resolutions d'identifiants sur la requete. Verifier les index cote base avec un plan d'execution avant d'en ajouter ; aucun plan SQL de production n'a ete inspecte.

Sources : [sanitaires](/Users/aidhabitat/Downloads/aid'habitat-manager/server/index.mjs:8363), [mesures](/Users/aidhabitat/Downloads/aid'habitat-manager/server/index.mjs:8525), [observations](/Users/aidhabitat/Downloads/aid'habitat-manager/server/index.mjs:8584), [pagination](/Users/aidhabitat/Downloads/aid'habitat-manager/server/index.mjs:2479), [PATCH logement](/Users/aidhabitat/Downloads/aid'habitat-manager/server/index.mjs:7347).

### F10 - P2 - La pastille verte ne garantit pas que toutes les operations du document sont terminees

**Reproduit en test.** `markCompleted()` marque l'entite synced apres la reussite d'une operation, sans verifier s'il reste une autre operation pending/failed pour cette entite. Le verrou sur le statut running protege le remplacement de la meme operation, mais pas deux operations ayant des identifiants distincts.

**Correction.** Deriver l'etat du document de sa revision acquittee et de toutes ses operations restantes, dans une transaction. Exposer separement enregistre sur l'appareil, en attente de connexion, en cours, erreur et synchronise.

Sources : [acquittement](/Users/aidhabitat/Downloads/aid'habitat-manager/aid_habitat_app/lib/services/sync_repository.dart:160), [etat d'entite](/Users/aidhabitat/Downloads/aid'habitat-manager/aid_habitat_app/lib/services/sync_repository.dart:1091), [couleur](/Users/aidhabitat/Downloads/aid'habitat-manager/aid_habitat_app/lib/components/doc_card.dart:17).

### F11 - P2 - La file charge finalement tous les gros payloads en memoire

`fetchRunnableOperations()` exclut d'abord `payload_json`, puis le charge pour chaque operation et conserve toutes les chaines dans la liste retournee. Le commentaire annonce un seul payload en RAM ; cette propriete n'est pas respectee par la liste finale. Le chargement intervient avant le test offline dans `pushPendingChanges()` et sert aussi au compteur initial dans `MainScreen`.

**Impact.** Une longue file de photos ou d'annotations hors ligne peut prendre beaucoup de RAM meme lorsque rien ne peut etre envoye. `importDocumentBytes()` conserve encore une copie Base64 dans la ligne document et une autre dans la file, y compris en natif, en plus du fichier.

**Optimisation.** Charger uniquement les descripteurs de file, puis le payload au moment ou un worker prend l'operation ; plafonner les octets en vol. Utiliser un COUNT pour les compteurs. En natif, stocker une reference de fichier immuable dans la file plutot que du Base64.

Sources : [chargement de file](/Users/aidhabitat/Downloads/aid'habitat-manager/aid_habitat_app/lib/services/sync_repository.dart:110), [test offline tardif](/Users/aidhabitat/Downloads/aid'habitat-manager/aid_habitat_app/lib/services/nocodb_sync_service.dart:217), [compteur initial](/Users/aidhabitat/Downloads/aid'habitat-manager/aid_habitat_app/lib/screens/main_screen.dart:215), [import bytes](/Users/aidhabitat/Downloads/aid'habitat-manager/aid_habitat_app/lib/services/document_repository.dart:428).

### F12 - P2 - Les images et certains PDF peuvent encore bloquer le thread d'interface

La compression `image.decodeImage/copyResize/encodeJpg` est synchrone a l'interieur d'une fonction async sans travail deporte. La rotation d'une image fait aussi decodage, rotation et encodage PNG sur le thread principal. Une photo JPEG devient systematiquement PNG apres rotation, avec un risque d'augmentation importante du poids. Le fallback PDF hors iOS rasterise toutes les pages, perd le texte vectoriel et utilise les dimensions en pixels comme dimensions PDF en points.

**Optimisation.** Utiliser un worker/isolate pour les transformations natives ; conserver le format photo lorsque possible ; gerer orientation et annotations comme transformations jusqu'a l'export. Etendre la rotation PDF native au Mac si cette cible est maintenue. La voie iOS PDFKit est deja hors du thread principal et doit etre conservee.

Sources : [compression](/Users/aidhabitat/Downloads/aid'habitat-manager/aid_habitat_app/lib/services/image_compressor.dart:121), [rotation image/fallback](/Users/aidhabitat/Downloads/aid'habitat-manager/aid_habitat_app/lib/screens/documents_screen.dart:2780), [PDFKit](/Users/aidhabitat/Downloads/aid'habitat-manager/aid_habitat_app/ios/Runner/AppDelegate.swift:61), [regles Flutter sur les isolates](https://docs.flutter.dev/perf/isolates).

### F13 - P2 - Les caches et prechargements multiplient les copies sans budget global

Plusieurs Maps statiques conservent bytes, images distantes et apercus PDF sans limite en octets. Les anciennes revisions PDF peuvent rester en cache. Le cache disque n'a pas de politique de retention automatique visible. Certaines images de grille sont decodees a leur resolution complete sans `cacheWidth/cacheHeight`.

Le prechargement de l'ecran utilise des URL avec `preview_v`, tandis que celui du repository utilise les URL brutes. Le cache et sa deduplication reposent sur l'URL complete : le meme contenu peut donc etre telecharge et stocke deux fois. Une copie supplementaire est ensuite faite dans `cached_remote_documents`. `prefetchAll()` lance toutes les requetes sans limite et rend immediatement, meme lorsqu'il est awaited. Le pool limite dans l'ecran ne s'applique qu'au web.

**Optimisation.** Une cle de contenu canonique et versionnee commune, un pool global de telechargement, de vraies vignettes dimensionnees et un cache LRU borne en octets. Distinguer les originaux prepares pour le hors-ligne des caches regenerables ; ne jamais purger des fichiers non synchronises.

Sources : [caches visuels](/Users/aidhabitat/Downloads/aid'habitat-manager/aid_habitat_app/lib/components/doc_thumbnails.dart:82), [cache PDF](/Users/aidhabitat/Downloads/aid'habitat-manager/aid_habitat_app/lib/components/doc_thumbnails.dart:351), [prechargement natif](/Users/aidhabitat/Downloads/aid'habitat-manager/aid_habitat_app/lib/services/media_cache_service.dart:225), [URL versionnee](/Users/aidhabitat/Downloads/aid'habitat-manager/aid_habitat_app/lib/components/doc_thumbnails.dart:32), [prechargement repository](/Users/aidhabitat/Downloads/aid'habitat-manager/aid_habitat_app/lib/services/document_repository.dart:1896), [dimensions de decodage Flutter](https://api.flutter.dev/flutter/widgets/Image-class.html).

### F14 - P2 - Le stockage des fichiers dans NocoDB coute beaucoup de requetes et de memoire

Les fichiers sont encodes en Base64 puis decoupes en cellules de 95 000 caracteres. Un fichier de 10 Mio represente environ 148 morceaux permanents. `createDocumentChunks()` fait un `Promise.all` de creations individuelles, et la suppression utilise egalement des appels individuels. Les morceaux temporaires de l'upload client utilisent deja une insertion par lot, mais pas les morceaux definitifs. La lecture du fichier reassemble l'ensemble en memoire.

**Optimisation courte.** Inserer/supprimer les morceaux par lots bornes, limiter les octets traites simultanement et assurer le nettoyage des ecritures partielles. La liste de documents demande aussi `contenu_base64` sans l'utiliser dans le payload final : supprimer cette colonne de cette lecture.

**Evolution structurelle.** Le projet possede deja un plan de migration vers du stockage objet. Le mettre en oeuvre progressivement : binaires dans le stockage objet, metadonnees et droits dans NocoDB, checksums et revisions, lecture de secours des anciens fichiers, sauvegarde/restauration verifiee. Aucun fournisseur ni tarif n'a ete selectionne pendant cet audit.

Sources : [creations concurrentes](/Users/aidhabitat/Downloads/aid'habitat-manager/server/mobileSyncStore.mjs:516), [lecture complete](/Users/aidhabitat/Downloads/aid'habitat-manager/server/mobileSyncStore.mjs:1827), [colonne inutile de liste](/Users/aidhabitat/Downloads/aid'habitat-manager/server/mobileSyncStore.mjs:1168), [plan existant](/Users/aidhabitat/Downloads/aid'habitat-manager/docs/object-storage-migration.md).

### F15 - P2 - Un evenement de synchronisation provoque des relectures sans changement utile

`lastSyncAt` change apres des pushes, y compris des cycles sans mutation, et pas seulement apres un pull distant. `NotesWidget` interprete cet evenement comme une raison de relire la page sur le serveur. MainScreen relit tous les dossiers ; DocumentsScreen relit tous les documents. `fetchDossierById()` charge tous les dossiers pour en chercher un seul. `_refreshSingleDocument()` recharge aussi toute la liste. `fetchDocuments()` charge toutes les colonnes, decode les annotations et reapplique la protection native a chaque fichier.

**Optimisation.** Emettre des evenements types contenant les identifiants et revisions modifies. Utiliser des projections SQLite legeres pour listes, des requetes par cle pour un element et ne charger les gros contenus qu'a l'ouverture. Appliquer la protection de fichiers a leur creation/migration. Separer revision du contenu et date de renommage : un changement de titre ne doit pas invalider le rendu PDF.

Sources : [emission moteur](/Users/aidhabitat/Downloads/aid'habitat-manager/aid_habitat_app/lib/services/sync_engine.dart:529), [notes](/Users/aidhabitat/Downloads/aid'habitat-manager/aid_habitat_app/lib/components/notes_widget.dart:573), [recherche unitaire](/Users/aidhabitat/Downloads/aid'habitat-manager/aid_habitat_app/lib/services/dossier_repository.dart:291), [document unitaire](/Users/aidhabitat/Downloads/aid'habitat-manager/aid_habitat_app/lib/screens/documents_screen.dart:268), [mapping lourd](/Users/aidhabitat/Downloads/aid'habitat-manager/aid_habitat_app/lib/services/document_repository.dart:2049).

### F16 - P2 - La suppression distante du dernier document reste invisible

**Reproduit en test.** La reconciliation ne supprime rien lorsque `remoteLocalIds` est vide. Cette protection contre les listes temporairement incompletes empeche aussi de distinguer une vraie suppression de tous les documents. L'operation de suppression agit sur l'appareil qui la cree ; elle n'est pas rejouee sur les autres appareils.

La bibliotheque presente aussi un retour anticipe lorsque la liste distante est vide. Ces garde-fous necessitent un protocole de suppression explicite.

**Correction.** Renvoyer des tombstones ou un snapshot complet accompagne d'une revision/garantie d'exhaustivite. Ne pas remplacer le garde-fou par une suppression aveugle sur toute reponse vide.

Sources : [reconciliation](/Users/aidhabitat/Downloads/aid'habitat-manager/aid_habitat_app/lib/services/document_repository.dart:1858), [bibliotheque vide](/Users/aidhabitat/Downloads/aid'habitat-manager/aid_habitat_app/lib/services/data_service.dart:143).

### F17 - P2 - Les appels REST NocoDB n'ont pas de delai d'abandon explicite

`restRequest()` utilise `fetch()` sans signal d'annulation ni deadline applicative. Les delais cote client Flutter ne stoppent pas automatiquement le travail distant. Une panne lente peut donc immobiliser des traitements serveur tandis que l'application retente. Le client cree aussi plusieurs `NocodbApiClient()` ponctuels sans cycle de fermeture explicite visible.

**Optimisation.** Definir un budget de temps par operation et le propager aux appels amont ; limiter les requetes en vol, classifier les echecs et conserver l'idempotence des ecritures. Mutualiser les clients HTTP Flutter durables et leurs files de mutations. Ne pas simplement augmenter les timeouts.

Source : [transport REST](/Users/aidhabitat/Downloads/aid'habitat-manager/server/nocodbMcpClient.mjs:134), [clients ponctuels](/Users/aidhabitat/Downloads/aid'habitat-manager/aid_habitat_app/lib/services/dossier_repository.dart:3101).

## Maintenance et environnement

### F18 - P3 - Code orphelin, doubles implementations et controles statiques fragiles

L'analyse des imports depuis `main.dart` trouve 17 fichiers non atteignables, soit 3 800 lignes :

- `screens/visit_tabs/` : 9 anciens fichiers d'onglets, distincts des fichiers actifs de `screens/visit_report/`.
- `screens/create_beneficiary_screen.dart`, `screens/start_visit_screen.dart`.
- `components/commune_autocomplete.dart`, `dashboard_widgets.dart`, `hover_border.dart`, `hover_scale.dart`, `occupants_editor.dart`.
- `data/mock_data.dart`.

Il s'agit de candidats a suppression apres verification des points d'entree secondaires et des usages de test. Le gain principal est la maintenance ; il ne faut pas promettre une reduction equivalente de l'IPA, le build release pouvant deja eliminer ce code.

Cote serveur, `index.mjs` contient 8 872 lignes et `helpers.mjs` 3 003 lignes. Les routeurs `routes/auth.mjs`, `dossiers.mjs`, `documents.mjs`, `references.mjs` et `sync.mjs` ne sont pas montes par l'entree active, qui ne monte que les routeurs AI et feedback. Des outils d'audit lisent pourtant encore les anciens routeurs. `onConflictAutoResolved` est affecte mais jamais invoque.

**Recommandation.** Documenter les points d'entree deployes, retirer progressivement les orphelins, partager une seule implementation des regles serveur. Decouper DocumentsScreen en editeur, rendu, sauvegarde et partage ; eviter de changer de framework pour cela. Les tests de contrat fondes sur `source.includes(...)` doivent etre completes par des tests HTTP reels sur l'application Express active.

Sources : [entree serveur](/Users/aidhabitat/Downloads/aid'habitat-manager/server/index.mjs:8), [ancien routeur](/Users/aidhabitat/Downloads/aid'habitat-manager/server/routes/dossiers.mjs:1), [audit d'un ancien routeur](/Users/aidhabitat/Downloads/aid'habitat-manager/tools/audit-commercial-tenant-readiness.mjs:86), [controles statiques](/Users/aidhabitat/Downloads/aid'habitat-manager/tools/check-critical-flows.mjs:1), [callback inutilise](/Users/aidhabitat/Downloads/aid'habitat-manager/aid_habitat_app/lib/services/nocodb_sync_service.dart:509).

### F19 - P2 - Un deploiement peut sembler reussi sans preuve de version active

Le workflow API ne fait qu'emettre un warning pour un webhook de deploiement non-2xx puis poursuit avec un resume de succes. Le workflow web de publication ajoute toujours le tag `latest`, meme si le tag demande est `staging`. Le risque pour la production depend du tag effectivement suivi par l'hebergeur, qui n'a pas ete inspecte.

Le script iOS n'impose ni arborescence propre ni numero de build unique et place les symboles par SHA, sans numero de build. Des builds locaux differents peuvent donc avoir une tracabilite ambigue. A l'ouverture de l'audit, quatre fichiers Flutter sont modifies localement et un test de cache n'est pas suivi ; ces modifications ne sont pas dans le commit courant. Cela ne permet pas de savoir si un ancien build manuel les inclut.

**Recommandation.** Faire echouer les deploiements non aboutis ; verifier ensuite un endpoint exposant le SHA/version attendu. Separer tags staging/production, enregistrer un manifest de build avec SHA, etat dirty, SDK, API cible et numero TestFlight ; archiver les symboles par build. Ajouter un controle macOS/iOS et les tests document aux checks obligatoires avant distribution.

Sources : [deploiement API](/Users/aidhabitat/Downloads/aid'habitat-manager/.github/workflows/build-deploy-api.yml:140), [tags web](/Users/aidhabitat/Downloads/aid'habitat-manager/.github/workflows/flutter-web-build.yml:95), [script natif](/Users/aidhabitat/Downloads/aid'habitat-manager/aid_habitat_app/tool/build_native_release.sh:132), [selection des tests CI](/Users/aidhabitat/Downloads/aid'habitat-manager/aid_habitat_app/tool/test_sync_critical.sh:6).

Etat local mesure : Flutter 3.38.4, Dart 3.10.3, Xcode 26.6, Node 24.11.0. Minimum iOS configure : 26.5. C'est coherent avec le choix precedent de viser un iPadOS recent ; augmenter le minimum OS n'est pas en soi une optimisation de performance.

Stockage Mac mesure : environ 24 Gio disponibles sur le volume ; `.git` 425 Mo, `tmp` 567 Mo, `backups` 432 Mo, build Flutter 289 Mo, `.dart_tool` 199 Mo, `node_modules` 188 Mo. Aucune saturation disque immediate n'est demontree. Les sauvegardes et symboles ne doivent pas etre assimiles a du cache supprimable. Des fichiers runtime historiques sont encore suivis dans `server/data/` : separer donnees de test, ressources de reference et donnees privees apres inventaire, sans purger l'historique a l'aveugle.

### F20 - P2 - Une erreur TypeScript est presente dans l'interface React

**Reproduit par `tsc --noEmit`.** `VisitReportView.tsx:4985` utilise `<X size={18} />` sans importer `X` de `lucide-react`. Le chemin de choix d'une description peut lever une erreur de rendu lorsqu'il est utilise dans cette interface. Cela ne concerne pas directement le binaire Flutter de l'iPad.

**Correction.** Importer le composant et ajouter le typecheck au build React. Si cette interface est retiree, le faire explicitement avec ses routes de deploiement et ses checks CI ; sa seule presence ne justifie pas une suppression.

Source : [composant non importe](/Users/aidhabitat/Downloads/aid'habitat-manager/components/pages/dossier/visit-report/VisitReportView.tsx:4985).

## Ordre de travail recommande

1. **Fiabiliser le document de bout en bout** : F01-F04 et F10. Sauvegarde locale atomique, revision de contenu, acquittement exact, annotations synchronisees et exportees. C'est la priorite pour les symptomes rencontres sur iPad.
2. **Reduire le travail inutile** : F08-F09, F11-F13 et F15. Synchronisation incrementale, filtres serveur, evenements cibles, file legere, pool de medias et traitement d'images en arriere-plan. Commencer par des filtres et des projections, puis faire evoluer le protocole.
3. **Securiser les reprises et l'environnement** : F05-F07, F16-F17 et F19. Conflits de champs, changement de profil, suppressions explicites, timeouts et chaine de publication fiable. Les correctifs de dependances peuvent avancer independamment du travail UI.
4. **Simplifier la maintenance et le stockage** : F14, F18 et F20. Nettoyage des chemins inutilises et migration progressive des binaires, sans migration massive non verifiee.

Les petits correctifs de lecture SQL, import React et echec du webhook sont limites. La revision des documents et le protocole de synchronisation demandent davantage de soin parce qu'ils touchent a la conservation des donnees. Aucun pourcentage de gain ni delai fixe n'est avance sans mesure sur appareil.

## Validation attendue avant un prochain build

- Rotation/annotation d'un PDF puis partage : les pages, le nom, l'orientation et les traits doivent etre identiques sur les deux appareils.
- Deux sauvegardes rapides pendant un upload : seule la derniere revision devient verte apres acquittement ; aucune ancienne reponse ne la remplace.
- Erreur d'ecriture simulee : aucune confirmation trompeuse ; la fenetre reste ouverte et les modifications recuperables.
- Modification hors ligne, fermeture forcee, relance puis retour reseau : reprise sans manipulation de navigation.
- Suppression du dernier document : propagation sur un autre appareil avec conservation des brouillons locaux.
- Changement de profil avec operations en attente : isolation de la file et explication de l'etat d'attente.
- Ouverture de 30 documents puis changement de dossier : memoire et nombre de telechargements bornes ; pas de rechargement binaire des documents inchanges.
- Formulaire modifie sur deux appareils : conservation des changements independants et conflit explicite sur un meme champ.
- Profilage en mode profile/release sur iPad : duree des frames, memoire maximale, octets reseau, appels API/NocoDB, temps de sauvegarde locale et de synchronisation p50/p95. Conserver un corpus synthetique fixe pour comparer avant/apres.

Les trois tests supplementaires de l'audit constatent volontairement les comportements actuels F03, F10 et F16 ; leur succes signifie que le defaut a ete reproduit, pas corrige. Ils ont ete executes contre une base SQLite en memoire et des documents synthetiques, dans la copie temporaire creee par `test_safely.sh`. Aucun dossier reel n'a ete modifie.

## Suivi des corrections - Etape 1, 9 septembre 2026

Premier correctif F01 implemente localement, apres l'audit :

- La fermeture avec Enregistrer depend du resultat de la sauvegarde. Une erreur conserve la preview et les modifications non enregistrees.
- Les sauvegardes PDF natives et web ne retirent une page de la liste des modifications qu'apres une persistance reussie. Les erreurs remontent au lieu d'etre ignorees ; la nouvelle tentative reprend les pages restantes.
- Les images ne sont marquees enregistrees qu'apres la preparation du re-upload et l'ecriture des annotations. Un echec d'export n'est plus ignore.
- Pendant l'enregistrement, les commandes concurrentes et les interactions d'edition sont bloquees. Les demandes de fermeture ne multiplient pas les confirmations.
- Aucun changement du protocole de synchronisation, du schema de base, des affectations, des donnees metier ou des versions de dependances.

Validation : 150 tests Flutter reussis, dont 8 nouveaux (fermeture en erreur et nouvelle tentative, sauvegarde normale, annulation/abandon, sauvegarde en cours, echec partiel titre/rotation, persistance partielle de pages). `flutter analyze --no-pub` et `git diff --check` reussis.

Limites : les tests de preview utilisent un document synthetique et les tests de pages un persisteur simule. Ils ne remplacent pas une validation PDFKit/Pencil et des erreurs de stockage sur iPad reel. Les annotations PDF restent locales a ce stade (F02) ; la protection contre un arret brutal pendant l'ecriture et la coherence des acquittements restent a traiter (F04/F10). Aucun commit, push ou build distribue pour cette etape.

## Suivi des corrections - Etape 2, 9 septembre 2026

Correctif F10 et gardes contre les operations perimees implementes localement :

- `markCompleted` acquitte l'operation et recalcule l'etat de l'entite dans une transaction SQLite. Une autre operation pending/running conserve pendingSync ; une erreur ou un conflit restant est conserve. Seule une file sans autre operation non terminee permet synced. Le controle conserve la distinction entity_type/entity_local_id.
- Le worker utilise `tryMarkRunning` pour reserver uniquement une operation encore pending et identique au snapshot charge (identite, date et payload). Une operation supprimee ou remplacee pendant le traitement d'un autre groupe n'est plus envoyee depuis l'ancienne copie. Deux reservations simultanees ne peuvent pas gagner toutes les deux.
- L'enregistrement du chemin/URL distant d'un document exige l'operation upload correspondante encore running, un document non marque pour suppression et l'absence d'un autre upload non termine. Un ancien retour ignore ne change pas non plus updated_at. Une operation de renommage ne bloque pas l'enregistrement du lien dont elle a besoin.

Fichiers applicatifs modifies pour cette etape : `sync_repository.dart` et `nocodb_sync_service.dart`. Aucun changement du schema SQLite, des endpoints, de la politique de conflits, du format des fichiers ou des fichiers reserves aux cinq agents.

Validation : 21 nouveaux tests SQLite synthetiques dans `test/services/sync_acknowledgement_test.dart` ; 171 tests Flutter reussis au total ; analyse statique et `git diff --check` reussis. Les tests couvrent aussi le rollback sur erreur d'ecriture, la reprise apres cette erreur, les notes/patients pour le chemin partage et les reponses d'uploads remplaces. Tests executes avec un TMPDIR unique, sans base ou reseau de production.

Limites : pas de validation reseau/iPad reel ni de migration des anciens etats deja incorrects. Ces gardes ne constituent pas encore une revision de contenu de bout en bout et n'annulent pas une requete deja partie vers le serveur. L'atomicite fichier + intention d'envoi (F04), les anciennes copies distantes (F03), les annotations synchronisees (F02) et la frequence de rafraichissement des pastilles (F15) restent a traiter. Avant toute future migration SQLite, verifier aussi le traitement des erreurs d'ouverture/migration dans `_openEncrypted`, qui contient un chemin historique de recreation de base. Aucun commit, push ou build distribue.

## Integration agent 5 - Dependances serveur, 9 septembre 2026

Diff relu puis integre depuis le worktree `aid-habitat-manager-agent-5`, base `10df5d4` : package.json, package-lock.json, server/dependencyCompatibility.test.mjs et docs/retour-agent-5.md. Sept paquets verrouilles changent, dont deux dependances transitives imposees par qs ; aucune migration majeure ni modification des scripts npm. Le test d'interruption disque a ete ajuste lors de l'integration : il attend des octets effectivement ecrits au lieu de supposer que 20 ms suffisent.

Verifications refaites dans le repertoire principal : npm ci --ignore-scripts reussi ; 33 tests Node reussis ; test:sync-contract reussi ; 20 controles check:critical reussis ; npm audit --json signale zero vulnerabilite a cet instant ; build Vite reussi avec l'avertissement de taille de chunk deja connu. Le typecheck TypeScript echoue toujours uniquement sur X non importe dans VisitReportView.tsx:4985 (F20). Aucun test Flutter relance pour cette integration limitee aux dependances Node ; la derniere validation Flutter reste a 171 tests reussis.

F07 reste PARTIEL : les limites multipart fieldArrayIndexLimit et la profondeur/plafonds compatibles avec les champs metier doivent etre examines dans les configurations Multer actives ; la migration Node Docker/CI reste distincte. Ne pas modifier server/index.mjs tant que le travail de l'agent 1 n'est pas integre. La mise a jour npm seule n'active pas ces limites opt-in. Les tests de compatibilite ne remplacent pas un test des routes metier completes ni une validation du conteneur cible.

Integration locale uniquement, sans commit, push, publication serveur ou build TestFlight. Les modifications Flutter precedentes et les autres perimetres d'agents sont conserves.

## Integration agent 2 - Delais NocoDB, 9 septembre 2026

Diff relu puis integre depuis `aid-habitat-manager-agent-2` : nocodbMcpClient.mjs,
nouveau helper nocodbRequestDeadline.mjs, ses tests et docs/retour-agent-2.md.
Le transport REST dispose d'un plafond couvrant fetch et response.text(),
avec AbortController et nettoyage du timer. NOCODB_REST_TIMEOUT_MS accepte
1 000 a 900 000 ms ; valeur par defaut 120 000 ms. Une valeur invalide est
refusee explicitement au chargement de la configuration.

Renforcement du coordinateur : le fallback d'une mutation MCP ne depend plus
de quelques textes d'erreur. Apres un appel potentiel a client.callTool,
aucune erreur ne declenche une seconde ecriture REST. L'echec de connexion
avant envoi conserve le fallback, de meme que les lectures. Des tests de
callNocoTool avec SDK simule verifient les tentatives reelles, en complement
des tests unitaires de la regle pure. Pas de reseau NocoDB ou processus MCP reel.

Verification avec les dependances de l'agent 5 deja integrees : 62 tests Node
reussis, test:sync-contract reussi, 20 controles critiques reussis et diff sans
erreur de whitespace. Flutter non modifie pour cette integration ; derniere
suite Flutter validee : 171 tests. Aucun fichier reserve a l'agent 1 modifie.

F17 traite ici au niveau du transport REST. Le budget de temps de bout en bout,
les reprises des mutations ambigues et le cycle de vie des clients Flutter
ne sont pas traites. Une deadline n'annule pas une ecriture deja appliquee
sur le serveur. Aucun commit, push ou deploiement.

## Integration agent 4 - Publication, 9 septembre 2026

Integration locale des deux workflows API/web, du script build_native_release.sh,
du helper release-artifact-check.mjs, de ses tests et du rapport retour-agent-4.md.
Les erreurs de webhook font echouer le job ; le resume distingue acceptation
du redeploiement et preuve du SHA actif. Le script natif reserve manifest et
symboles par execution, refuse les collisions et impose une acceptation explicite
des modifications locales (--allow-dirty ou variable dediee). Il ne verifie pas
le numero de build dans App Store Connect et l'indique dans le manifest.

Renforcements du coordinateur : deadline du webhook couvrant aussi son corps,
erreurs sans URL/secrets/corps de reponse, refus des redirections ; tags staging
et staging-<sha> distincts de latest et <sha> de production ; reconnaissance CLI
par chemins reels pour ne pas ignorer les commandes via un symlink macOS.
Tests natifs rendus independants du vrai depot, avec cas clean/dirty/echec et
non-ecrasement des symboles. Tests de publication ajoutes aux deux workflows.

Validation : 75 tests Node reussis sur l'ensemble agents 2/4/5, dont 13 tests
de publication ; test:sync-contract et check:critical (20/20) reussis ; Bash/YAML
syntaxiquement valides ; git diff --check reussi. shellcheck et actionlint ne
sont pas disponibles. Aucun fichier Dart change pour cette integration ; la
derniere suite Flutter reste a 171 tests reussis.

F19 reste sans preuve du SHA actif et sans verification du numero de build
distant. Aucun workflow reel execute, aucun build Flutter/Xcode reel, aucune
signature, aucun commit, push ou deploiement. Les versions Node n'ont pas change.

## Integration agent 3 - Compression, 9 septembre 2026

Integration locale du compresseur, du nouveau worker compute, des tests et du
rapport retour-agent-3.md depuis le worktree aid-habitat-manager-agent-3.
Decode/resize/encode sont dans un callback top-level ; signature, seuils,
qualite, noms, MIME et replis restent inchanges. Aucune dependance ajoutee.
Deux tests de relecture completent les huit de l'agent : PDF non transforme
et repli sur erreur reelle du worker. Timer de mesure nettoye dans finally.

Validation dans le repertoire principal avec tous les changements Flutter
actuels : 181 tests reussis, analyse statique sans probleme et format Dart
valide. Les sorties du compresseur sont comparees a l'ancien algorithme sur
des images synthetiques. Mesure illustrative : ancien 859 ms, worker 869 ms,
173 ticks dans l'isolate appelant. Aucun gain de temps total garanti, aucune
mesure sur appareil reel. Build web reussi rapporte par l'agent, non relance
par le coordinateur ; aucune compilation native ou publication.

F12 reste PARTIEL : l'inspection des appelants montre que ce service est
actuellement utilise par les imports web et le drag-and-drop, lequel est
no-op sur natif (file_drop_listener_io.dart). Les imports photo natifs
utilisent image_picker et un autre chemin de persistence. Le deplacement
CPU est valide sur VM native, mais ne demontre donc pas un gain sur un
parcours iPad existant. Sur web, compute utilise toujours la boucle
principale ; le freeze correspondant reste a traiter. Ne pas ajouter une
seconde compression native sans revoir la politique qualite/format.
Rotation, annotations, sauvegardes et repositories non modifies par ce lot.

Aucun commit, push, build TestFlight ni acces aux donnees metier. Les autres
lots locaux sont preserves ; le retour de l'agent 1 reste attendu.

## Integration agent 1 - Lectures ciblees, 9 septembre 2026

Integration locale des trois GET actifs diagnostic-sanitaires, mesures et
observations, du helper dossierReadQueries.mjs, de ses tests et du rapport
retour-agent-1.md. Les tables metier sont filtrees par dossier_id canonique
apres resolution et controle d'acces. queryAll conserve le filtre a chaque
page ; une verification locale ecarte aussi les lignes hors dossier. Les
projections, reponses null/JSON et regles historiques de selection restent
inchangees. Pas de modification des PUT, documents ou contrats de sync.

Relecture renforcee par quatre tests : repli sur l'identifiant demande sans
UUID, priorite temporelle jusqu'a created_at/Id, echec de resolution et
propagation des erreurs/deadlines sans faux resultat vide ni scan global.
Validation combinee : 91 tests Node reussis, dont 16 pour les lectures
ciblees ; test:sync-contract, check:critical (20/20) et node --check des
deux modules de production reussis. Aucune modification Dart pour ce lot ;
derniere suite Flutter combinee validee : 181 tests, analyse statique propre.

F09 traite pour ces trois GET. Limites : ensureDossierRecord peut encore
parcourir la table dossiers ; les lectures internes PDF restent hors lot.
Le gain de 3 appels/251 lignes a 1 appel/1 ligne est une simulation, pas une
mesure de production. Tests du helper avec services simules et inspection
statique des routes, sans validation HTTP/NocoDB reelle ; notamment, le
parseur distant des identifiants atypiques n'est pas valide par ces tests.

Les cinq retours d'agents sont maintenant integres localement. Les constats
restants de l'audit et les limites des lots partiels restent ouverts. Aucun
commit, push, deploiement ou nouveau build distribue ; aucune donnee metier
modifiee. Le F20 TypeScript historique et les limites multipart/versions Node
du F07 restent des travaux distincts, non modifies pendant cette integration.

## Suivi des corrections - Etape 3, sauvegardes de contenu, 9 septembre 2026

F04 : les quatre entrees de remplacement de contenu (rotation depuis bytes
ou fichier, image annotee depuis bytes ou fichier) passent par le meme chemin.
DocumentRevisionStore prepare un fichier protege dans un repertoire unique,
termine son ecriture et flush avant publication. Aucun ancien fichier n'est
ecrase. La reference locale, les metadonnees de format, le statut pendingSync
et la nouvelle operation upload_file sont ensuite valides dans une seule
transaction SQLite. Sur web, le data URL chiffre et l'intention d'envoi sont
valides dans cette meme transaction. Aucun changement de schema/version DB.

Les anciennes operations upload pending/running/failed sont remplacees dans
la transaction, sans supprimer les operations de renommage ou suppression.
Les fichiers des anciens uploads restent disponibles pour un envoi deja parti.
Le retour de cet ancien envoi ne peut plus acquitter la nouvelle operation
grace aux gardes de l'etape 2. La ligne est relue dans la transaction : une
suppression ou un remplacement concurrent fait echouer la sauvegarde au lieu
d'ecraser silencieusement le nouveau contenu. Les metadonnees changees pendant
la preparation sont reprises dans le nouveau payload. Un document absent ou
un contenu vide produit une erreur explicite, pas un faux succes.

Adaptations du viewer indispensables aux chemins immuables : les rotations
successives repartent de la revision ouverte et appliquent l'angle total ;
un tour complet republie les bytes d'origine sans rasterisation PDF. Les
annotations PDF locales existantes suivent le nouveau chemin, sans copier
les PNG de rendu. Une sauvegarde de traits pendant que l'ancien viewer reste
ouvert maintient aussi les sidecars de la revision courante. Cela ne les
integre pas dans le PDF partage (F02 reste ouvert). L'image aplatie est
preparee directement par le repository, sans ecrasement d'un fichier .flat.png
partage entre sauvegardes. Le partage/telechargement individuel relit le
document en base ; un telechargement sans modifications non sauvees utilise
la version enregistree plutot qu'un nouvel aplat de l'ancien viewer.

Tests ajoutes : document_revision_save_test.dart (17 cas SQLite/fichiers) et
document_preview_revision_test.dart (4 rotations sauvegardees dans une meme
fenetre). Les pannes sont simulees par erreurs I/O et triggers SQLite, avec
fermeture/reouverture d'une base sur disque. Le test de viewer simule PDFKit,
pas un rendu ou une rotation PDF reelle sur appareil. Donnees synthetiques,
aucun reseau de production ni dossier patient reel utilise.

Limites avant generalisation/distribution : les versions precedentes et les
revisions preparees mais non publiees apres interruption sont conservees.
Leur collecte devra tenir compte des references DB, de la file et des viewers
ouverts ; ne pas lancer de purge aveugle. Les imports/regenerations de rapports
et les sauvegardes de metadonnees seules gardent leurs chemins historiques
et doivent encore etre examines pour generaliser F04. Pas de preuve de
resistance a une panne materielle, ni de validation SQLCipher/PDFKit sur iPad.
Les conflits entre appareils, les retours de requetes deja appliquees au
serveur, F02/F03/F15 et le cout CPU des transformations restent distincts.
L'ancien helper resolveReplacementDocumentPath reste present avec ses tests
historiques ; les remplacements utilisent desormais DocumentRevisionStore.

Aucun commit, push, build natif signe ou deploiement. Les autres lots locaux
sont preserves. Validation finale de cette etape consignée ci-dessous.

Validation : suite complete Flutter 199/199 reussie ; derniere passe ciblee
23/23 reussie apres les derniers gardes de contenu vide/telechargement ;
flutter analyze --no-pub sans probleme ; format des cinq fichiers Dart et
git diff --check valides. Compilation flutter build web --release --no-pub
reussie, avec les avertissements Wasm existants (dart:html / interop des
dependances). Cette compilation ne valide ni l'execution web offline ni
l'appareil iPad. Les tests utilisent chacun un TMPDIR isole. Le premier
essai du nouveau test widget a ete interrompu car ses I/O tournaient dans
l'horloge simulee ; elles ont ete placees dans tester.runAsync puis le test
a reussi seul, dans la suite complete et dans la passe finale.

Le serveur n'est pas modifie par cette etape ; derniere validation Node
reste celle de l'integration agent 1 (91 tests). F04 est traite pour les
remplacements de contenu, pas declare clos pour tous les chemins de l'app.

## Etape 4 - Coherence des revisions distantes (F03)

Implementation locale le 9 septembre 2026, apres les sauvegardes immuables
de l'etape 3. Le contrat serveur a ete relu dans mobileSyncStore.mjs :
un remplacement NocoDB attribue un nouvel UUID au contenu et une nouvelle
URL. Un renommage ne change pas ce chemin de contenu.

mergeRemoteDocuments detache les anciens fichiers/data URL et overlays
uniquement lors d'un changement de contenu distant identifiable. Un simple
rafraichissement de metadonnees conserve les bytes, les annotations, l'ordre,
le dossier et l'organisation. Un updatedAt absent conserve sa valeur locale
au lieu de changer la cle visuelle a chaque polling.

Toute operation document non terminee, meme si la ligne affiche deja synced,
protege les modifications locales contre le merge et la reconciliation.
Les lignes ignorees restent dans l'ensemble de reconciliation. Les
horodatages distants deja acceptes sont suivis separement dans kv_store
(document_remote_version:<id>) afin de rejeter une reponse distante plus
ancienne sans la comparer a l'heure de l'iPad ou de l'acquittement local.
Les pendingSync orphelins sans operation gardent leur politique historique.

Avant de detacher une ancienne revision, sa ligne complete est archivee
transactionnellement dans kv_store (document_previous_revision:<id>:<instant>),
via OfflineVault. Les fichiers et sidecars precedents ne sont pas effaces.
Les overlays de l'ancien PDF ne sont pas appliques au nouveau contenu.
Ces sauvegardes sont des points de recuperation techniques, pas encore un
historique consultable/restaurable dans l'interface. Leur retention et celle
des fichiers doivent etre traitees avec la collecte des revisions de F04.

Le prechargement travaille sur les lignes acceptees en base, pas sur la
reponse distante brute. Il ignore les sources locales disponibles et les
operations en attente, prepare un fichier independant puis le rattache
uniquement si URL, date, chemin local, etat et file correspondent toujours
au document observe. Une copie privee devenue obsolete est supprimee avant
toute publication. Un echec sur un document n'interrompt pas les suivants.
Le prochain passage peut retenter un telechargement echoue hors connexion.
Une ancienne reference de fichier absent peut etre reparee.

La meme construction d'URL de cache sert desormais aux vignettes, au
prechargement, aux viewers, aux rotations et au partage/telechargement
individuel. Elle ne reecrit pas les origines tierces signees, remplace
preview_v au lieu de l'empiler et preserve le fragment. Le chargement PDF
natif ignore aussi le resultat d'une generation precedente du widget.

Tests synthetiques ajoutes : 25 cas SQLite/fichiers dans
document_remote_revision_test.dart, plus 3 cas d'URL dans
doc_thumbnail_cache_test.dart. Couverture : remplacement/renommage,
annotations archivees, operations pending/running/failed/conflict,
suppression, reconciliation, retours dans le desordre, horloge iPad decalee,
telechargement tardif face a une sauvegarde offline, reprise apres echec,
isolation des patients et stabilite des autres cles visuelles.

Limites : aucun serveur, dossier reel ni iPad utilise. Pas de migration
SQLite, de publication ou de changement du contrat serveur. Une ancienne
ligne deja incoherente avant ce correctif n'est pas automatiquement reparee
si son URL ne change plus. Sans horodatage serveur valide, les UUID donnent
l'identite du contenu mais pas son ordre chronologique. La resolution des
conflits entre appareils/viewers deja ouverts (F05), la synchronisation des
traits PDF (F02), la collecte des revisions et le rythme des refresh (F15)
restent des chantiers distincts. Aucun engagement de fluidite mesuree sur
appareil n'est deduit des tests SQLite.

Validation finale : 227/227 tests Flutter reussis dans la copie a chemin
compatible avec Dart (TMPDIR isole), flutter analyze --no-pub sans probleme,
format des six fichiers Dart verifies et git diff --check valides.
flutter build web --release --no-pub reussi (98,3 s) ; avertissements
historiques du dry-run Wasm sur dart:html/interop JS, sans echec du build JS.
Pas de nouveau test Node : aucun fichier serveur modifie dans cette etape.
Le prechargement de ce repository est maintenant sequentiel et ignore les
bytes locaux disponibles ; l'ancien prefetchAll lancait tous les fetchs
sans attendre. Cela limite les requetes simultanees mais peut allonger la
premiere mise en cache d'un gros dossier. Le chargement a la demande reste
disponible ; une concurrence bornee et mesuree appartient au prochain lot
performance, sans revenir au lancement illimite.

## Etape 5 - F02 annotations PDF natives (partiel)

Le parcours iOS utilise maintenant PDFKit pour lire, ecrire et rendre les
annotations. Les traits sont integres au PDF sous forme d'annotations ink
standard, avec des metadonnees de geometrie permettant de les reediter dans
l'application. Le traitement PDFKit est lance hors du thread principal.
Les pages, leur texte vectoriel et les annotations tierces sont conserves.
Le rendu des vignettes utilise aussi PDFKit pour afficher ces annotations.
Reference API : [PDFAnnotation](https://developer.apple.com/documentation/pdfkit/pdfannotation).

L'enregistrement produit un fichier temporaire distinct, puis passe par la
publication transactionnelle F04 : nouvelle revision locale et operation
d'upload PDF, y compris hors connexion. L'original reste intact. Les etats
modifies ne sont acquittes qu'apres le commit de cette publication ; une
erreur native ou SQLite conserve les traits ouverts et permet une nouvelle
tentative. Des controles de revision refusent la publication si une autre
version a remplace le document pendant l'edition ou l'export. Cela ne clot
pas la resolution generale des conflits F05. Aucun contrat serveur change.

Les nouveaux traits utilisent des coordonnees et une epaisseur relatives a
la page, pas aux marges du viewer. Les rotations sont calculees depuis la
source d'ouverture, meme apres plusieurs sauvegardes. La detection des
modifications distingue deux traits ayant le meme nombre de points.

Les anciens sidecars JSON natifs sont repris au prochain enregistrement
explicite, y compris ceux des pages non visitees. Le telechargement depuis
le viewer demande d'abord cette sauvegarde. Les fichiers historiques ne
sont pas supprimes ; la nouvelle revision n'a plus besoin de sidecars.
Limite de migration : l'ancien format ne memorisait pas les dimensions du
viewport d'origine. La conversion utilise le viewport a l'ouverture ; la
position historique exacte ne peut pas etre garantie pour des fenetres
differentes. Des PDF reels anciens doivent etre controles sur iPad avant
diffusion. La collecte des anciennes revisions/sidecars reste differee.

Les overlays web historiques dans annotations_json ne sont pas convertis
en ink par ce lot. L'export individuel est refuse lorsqu'il omettrait ces
annotations (ou des sidecars natifs encore non integres), avec un message
explicite. La conversion web et la synchronisation de ses annotations
restent a terminer : F02 n'est donc pas clos. Aucun effacement silencieux
des overlays web n'est effectue par le parcours natif. La modification de
metadonnees ink par des editeurs PDF externes n'est pas couverte.

Verification native : tool/pdf_ink_native_test.swift cree un PDF synthetique
de quatre pages et verifie les orientations 0/90/180/270, les mediaBox
decalees, la preservation du texte et des annotations tierces, l'effacement,
la reedition, les sauvegardes successives et l'integrite de l'original.
Tests reussis sur PDFKit macOS avec controles de pixels ; rendus inspectes
visuellement, dont un rendu independant avec Poppler. Le coeur Swift passe
aussi le typecheck contre le SDK iOS 26.5 ; AppDelegate passe le parsing et
le projet Xcode la validation plist. Cela ne remplace pas un build Runner
complet ni les tests UIKit/Apple Pencil sur appareil.

Commande native depuis la racine du projet :

```sh
xcrun swiftc aid_habitat_app/ios/Runner/PdfInkEditor.swift aid_habitat_app/tool/pdf_ink_native_test.swift -o /tmp/aidhabitat-pdf-ink-test
/tmp/aidhabitat-pdf-ink-test
```

Tests Flutter ajoutes : geometrie et pont natif, refus des sorties invalides,
reprise des sidecars, protection des revisions, sauvegarde PDF dans la file
SQLite, pages non visitees, erreurs natives/transactionnelles et nouvelles
tentatives, traits au stylet et modifications successives a nombre de points
egal. Les tests de widgets simulent le rendu ; les tests Swift utilisent de
vrais PDF. Pas de dossiers reels, de migration SQLite, de commit, de push,
de publication serveur ou de build signe dans cette etape. AirDrop, reprise
reseau et synchronisation entre deux iPad restent a verifier sur appareils.

Validation finale de cette etape : 244/244 tests Flutter reussis, analyse
Flutter sans probleme, format des huit fichiers Dart concernes conforme et
git diff --check valide. Build web release reussi (86 s), avec les memes
avertissements historiques du dry-run Wasm (dart:html et interop JS) ; le
build JavaScript termine normalement. Aucun test Node relance, le serveur
n'ayant pas ete modifie dans ce lot.

## Etape 6 - F02 sauvegarde et export PDF web

Cause confirmee : le viewer web persistait uniquement des images de pages
dans annotations_json, sans produire de nouveau PDF ni d'upload. Ce lot
remplace ce parcours par la publication d'un PDF complet et de son upload
dans la meme transaction SQLite que les revisions F04.

Le moteur utilise pdf-lib 1.17.1, deja present dans le projet, avec une copie
locale du bundle et de sa licence MIT dans web/pdf-export. Le traitement
PDF s'execute dans un Web Worker, precharge a l'ouverture du viewer. Aucun
CDN ou serveur de conversion ne recoit le document. Un delai d'abandon et
les erreurs du worker sont remontes sans acquitter les modifications.
Reference API : [PDFPage.drawImage](https://pdf-lib.js.org/docs/api/classes/pdfpage#drawimage).

Les nouveaux traits sont captures sur fond transparent, sans rasteriser
le texte ou les annotations natives deja contenus dans le PDF. Le worker
integre ces calques uniquement aux pages annotees et applique la rotation
aux pages originales. Les pages intactes, le texte sous-jacent, les boites
de page, les champs de formulaire et les annotations tierces sont conserves. Les coordonnees tiennent
compte de la rotation initiale et de l'intersection CropBox/MediaBox de PDF.js.
La source d'ouverture est copiee avant lecture PDF.js, car celui-ci peut
transferer son buffer a son propre worker. Chaque sauvegarde repart de
cette source avec les calques courants, sans empiler les exports precedents.

Les anciens aplats sont decodes strictement, y compris les pages jamais
visitees. Un JSON, PNG ou numero de page invalide bloque l'export au lieu
de perdre silencieusement des annotations. Les marges centrees de l'ancien
BoxFit.contain sont retirees pour replacer l'image sur la page. Cette reprise
ne peut pas reconstruire l'historique d'un aplat deja degrade ou contenant
plusieurs marges successives : validation de documents reels necessaire.
Les traces dessinees dans les anciennes marges, hors du papier, ne font pas
partie de la page exportee ; l'ancien aplat complet reste dans la sauvegarde.
Les anciens PNG et le nouveau calque web restent des images, pas des traits
ink reeditables apres reouverture. L'edition des traits natifs deja presents
n'est pas convertie en image par les nouvelles captures web.

La sauvegarde controle la revision du document et ses overlays avant et
pendant la publication. Lorsqu'il existe des overlays historiques, elle
archive leur ligne complete avant de les integrer. Elle efface les seuls
overlays integres et inscrit le PDF complet dans la file pending, dans une
transaction unique. Un echec conserve original, overlays et modifications
ouvertes ; la nouvelle tentative est possible. Les PDF signes ou chiffres
sont refuses par ce moteur, sans tentative de contournement.

Le telechargement depuis le viewer enregistre d'abord les changements.
L'export direct depuis la liste integre aussi les overlays historiques,
sans modifier la source. La duplication web d'un PDF deja exporte ne
recopie pas une seconde fois les overlays locaux. Les noms publics et
l'extension PDF restent geres par document_file_naming. Le viewer abandonne
le focus du titre avant l'enregistrement et bloque focus/pointeurs pendant
le save. Sur web, cela evite de modifier readOnly sur un input DOM deja
detache (erreur du moteur Flutter observee dans Chrome avec les semantics).
Les changements de page sont serialises pendant la capture des traits,
pour qu'un double clic ne rattache pas la capture a une autre page.

Verification : 8 tests Dart de decodage/geometrie et 4 tests SQLite ajoutes
(archive/publication, modifications concurrentes, rollback et retry).
tools/web-pdf-export.test.mjs couvre 11 cas, dont de vrais PDF multipages,
quatre orientations, CropBox decalee, texte conserve, annotations tierces,
exports repetes, formulaires editables, entree invalide/signature et identite du bundle vendore.
Les rendus Poppler ont des assertions de pixels et ont ete inspectes.

Le fixture tool/web_pdf_preview_smoke.dart utilise le vrai DocumentPreview,
PDF.js, le worker et SQLite WASM, avec uniquement un dossier synthetique.
tools/web-pdf-preview-smoke.mjs pilote Chrome isole : echec SQLite provoque,
retry apres coupure reseau, reprise d'une page historique non visitee,
dessin, sauvegardes successives, annulation, navigation rapide entre pages
et callback de telechargement, sans erreur navigateur non interceptee.
Les sorties PDF sont rouvertes et les captures desktop/tablette inspectees.
Ce test ne contacte ni serveur de production ni compte utilisateur.

Pour reproduire, compiler le fixture depuis une copie du projet dont le
chemin ne contient pas d'apostrophe (limite du generateur d'entrypoint Dart),
puis servir/piloter la sortie avec le script Node :

```sh
flutter build web --release --no-pub --pwa-strategy=none --target tool/web_pdf_preview_smoke.dart --output /tmp/aid-pdf-smoke
PLAYWRIGHT_MODULE=/chemin/playwright/index.mjs node tools/web-pdf-preview-smoke.mjs /tmp/aid-pdf-smoke
node --test tools/web-pdf-export.test.mjs
```

Limites : l'offline teste est une coupure apres ouverture et chargement du
worker, pas un lancement a froid du site online-first. La reception sur un
deuxieme appareil, Safari/iPadOS, AirDrop et les performances sur de gros
PDF restent a verifier. Les conflits inter-appareils F05 et la retention
des revisions historiques restent ouverts. Pas de migration de schema,
de mise a jour de donnees reelles, de commit/push, de deploiement ni de
nouveau build iOS signe dans cette etape.

Validation finale : 256/256 tests Flutter reussis, 11/11 tests PDF Node
reussis, scenario Chrome/SQLite/worker valide sans erreur non interceptee,
flutter analyze --no-pub sans probleme, format des huit fichiers Dart
verifie et git diff --check valide. Build principal web release reussi
(38,3 s, --no-wasm-dry-run sur la derniere passe). Une premiere compilation
avec dry-run a retrouve les avertissements Wasm historiques de dart:html
et interop JS, sans echec du build JavaScript. Les scripts du worker et
le moteur PDF local sont bien inclus dans build/web/pdf-export.

## Etape 7A - F05 : proteger les saisies pendant le pull

Prerequis local realise avant de modifier la politique de resolution 409.
Le merge workspace autorisait une version distante plus recente a remplacer
un dossier, patient ou logement en attente de synchronisation. Il remplacait
aussi remote_updated_at, c'est-a-dire la reference du prochain controle de
version, alors que le serveur n'avait pas confirme la mutation locale.

Le merge identifie maintenant, dans sa transaction SQLite, les dossiers
ayant une operation dossier/patient/logement/contexte de vie pending,
running, failed ou conflict. Il conserve leurs lignes principales et leurs
references de version, meme si sync_state indique synced par erreur.
La reconciliation des suppressions conserve egalement ces dossiers et leurs
liens si le snapshot distant ne les contient plus. Les gardes des tables
enfants reconnaissent maintenant les operations conflict, meme avec un
sync_state local incoherent. Aucun payload lourd n'est charge pour ce
controle : une requete d'identifiants precede le parcours du snapshot.

Les autres dossiers continuent a etre actualises. Apres acquittement de
l'operation, le merge et la reconciliation habituels reprennent. Le mecanisme
de reparation des anciens etats pending orphelins, sans operation associee,
reste en place. Compromis volontaire : tant qu'une vraie mutation bloque,
le bundle principal concerne attend aussi pour ses autres champs ; une
fusion champ par champ n'est pas encore implementee.

24 tests SQLite synthetiques couvrent les quatre types et les quatre statuts,
les references serveur inchangees, les autres dossiers, le redemarrage du
repository, la reprise apres acquittement, un changement de lien patient,
la suppression distante, les etats orphelins et les conflits des tables
enfants. Aucun dossier utilisateur ni service distant n'a ete contacte.

F05 reste OUVERT. Le rejeu force-local apres 409 n'est pas encore retire :
l'ancien parcours de resolution ne permet pas de le remplacer en securite.
`resolveConflictKeepLocal()` ne fait que changer un indicateur dossier ;
`resolveConflictTakeRemote()` remplace un bundle puis nettoie uniquement
certaines operations du dossier. Il faut d'abord une resolution atomique,
ciblee sur les mutations et avec sauvegarde des versions, ainsi qu'un choix
explicite lorsque le meme champ a change des deux cotes. Le boot remet aussi
les anciens conflits en attente et devra etre adapte dans ce meme lot.
Restent egalement la capture de reference au moment de la saisie, les
protections serveur sur les uploads documents et les verifications sur
deux appareils. Cette etape ne garantit pas encore l'absence d'ecrasement
inter-appareils lors des pushes. Pas de changement de schema, de politique
de retry, de commit/push, de deploiement ni de build iOS signe.

Validation de cette etape : 280/280 tests Flutter reussis (dont 24 nouveaux),
flutter analyze --no-pub sans probleme. Les tests utilisent SQLite en
memoire et les services locaux ; ils ne simulent pas deux serveurs NocoDB
concurrents ni deux iPad physiques.

## Etape 7B - F05 : references durables et comparaison a trois versions

Les nouvelles operations patient, logement et dossier enregistrent maintenant
un objet concurrency versionne dans leur payload deja protege par OfflineVault.
Il contient le remote_updated_at connu lors du save et les anciennes valeurs
des seuls champs modifies, converties par les memes mappers que le PATCH.
Le diff patient et logement est maintenant calcule dans la transaction qui
ecrit la ligne locale et sa file, comme c'etait deja le cas pour le dossier.
Un pull ne peut donc plus changer la reference entre lecture et publication.
Cela capture SQLite au moment du save, pas encore le snapshot d'ouverture
d'un formulaire reste ouvert pendant un rafraichissement.

Le regroupement de plusieurs saves conserve la premiere reference de chaque
champ non acquitte. Les champs ajoutes ensuite gardent leur propre ancienne
valeur. Une ancienne operation sans reference n'en recoit pas une inventee
a partir de la ligne deja modifiee : ses champs restent inconnus. Une
operation completed permet de commencer une nouvelle reference. Une erreur
de dechiffrement/decodage d'une operation precedente n'est plus ignoree :
la nouvelle transaction echoue sans supprimer cette ancienne saisie. Les
operations conflict sont incluses dans la conservation du payload ; leur
politique actuelle de remise en attente n'est pas encore remplacee.

sync_mutation.dart contient aussi un planificateur pur de comparaison entre
baseValues, modifications locales et valeurs distantes canoniques. Il
identifie les changements independants, les valeurs deja appliquees apres
perte d'une reponse, les annulations locales et les conflits reels. Un champ
distant absent n'est pas confondu avec null. Les objets et listes sont
traites comme des champs atomiques : aucune fusion par index des occupants.
Si canApplyAutomatically est false, aucune partie du plan ne doit etre
publiee. Toute application du plan devra encore etre conditionnee a la
version distante effectivement comparee.

IMPORTANT : le planificateur n'est pas encore branche au moteur reseau.
Les nouvelles references sont persistees, mais le push actuel continue de
lire son ancien controle et conserve son retry force-local. Ce lot ne
resout donc PAS encore F05 et ne doit pas etre presente comme une protection
complete entre appareils. Aucun comportement de fusion automatique ou
nouveau choix utilisateur n'est active par cette etape.

Le raccordement doit traiter ensemble : reponse 409 dans le vocabulaire API
(actuellement remoteData expose les champs NocoDB), controle et ecriture
conditionnels cote serveur, retry borne sans force-local, conservation des
conflits au boot, compteurs/file/bloquage des rapports, puis choix utilisateur
atomique avec sauvegarde des deux versions. Le client REST updateRecords
actuel n'envoie que Id et fields ; sendConflictIfStale precede un await
updateRecord separe. Un verrou uniquement en memoire Node ne suffirait pas
pour plusieurs instances : la garantie d'ecriture conditionnelle doit etre
verifiee au niveau du stockage avant activation. Les PDF et les autres
tables de saisie n'ont pas encore ce nouveau format de reference.

Validation : 313/313 tests Flutter reussis, dont 18 tests du planificateur
et de la construction des mutations, et 15 tests SQLite de capture,
regroupement, ancienne file, sauvegardes simultanees, champs structures,
reference absente, rollback et corruption. flutter analyze --no-pub sans
probleme. Pas de migration, modification de donnees reelles, commit/push,
deploiement ou build iOS signe.

## Etape 7C - F05 : preuve d'ecriture conditionnelle avant raccordement

Investigation du stockage : l'adaptateur courant updateRecords utilise
PATCH v2 avec Id et fields, sans condition de revision dans l'ecriture.
La lecture des sources officielles NocoDB montre une autre voie :
bulkUpdateAll construit un UPDATE avec filtre. Attention : le compteur
renvoye est obtenu par un COUNT avant l'UPDATE et ne prouve donc pas a lui
seul qu'une ecriture conditionnelle a effectivement modifie la ligne.
Ces sources concernent la branche develop consultee, pas une verification
du binaire deploye chez Aid'Habitat.

Sources : [BaseModelSqlv2](https://github.com/nocodb/nocodb/blob/develop/packages/nocodb/src/db/BaseModelSqlv2.ts),
[controleur bulk v1](https://github.com/nocodb/nocodb/blob/develop/packages/nocodb/src/controllers/bulk-data-alias.controller.ts),
[service bulk](https://github.com/nocodb/nocodb/blob/develop/packages/nocodb/src/services/bulk-data-alias.service.ts).

Le script tools/probe-nocodb-conditional-write.mjs prepare une verification
reproductible dans une table entierement nouvelle, synthetique et isolee.
Il refuse toute base autre que App Ergo Staging p7jzofcton1tabh. Le mode
par defaut ne lit meme pas les identifiants et n'effectue aucun appel reseau.
Avec --apply, il cree une table nommee codex_sync_probe_<uuid>, verifie son
identite et sa base, puis cree deux lignes fictives. Il ne modifie aucune
table existante et ne supprime rien. La table reste disponible pour examen,
y compris en cas d'echec ou de timeout ambigu, sans rejeu automatique.

Le scenario lance deux ecritures avec la meme reference UUID mais deux
nouvelles revisions distinctes, puis relit le resultat et une ligne temoin.
Deux colonnes marqueurs distinctes permettent de detecter si LES DEUX
ecritures ont ete appliquees : verifier seulement la derniere valeur aurait
masque cette course. Le test refuse aussi une ecriture ulterieure avec
l'ancienne revision et verifie qu'une ecriture avec la bonne reference
reste possible. Le filtre associe toujours Id et revision ; Id n'est jamais
present dans le body de l'ecriture filtree.

11 tests Node locaux valident le scenario, ses garde-fous et ses echec-types,
notamment un faux serveur qui compare puis ecrit sans condition atomique,
un serveur ignorant le filtre Id, deux reponses annoncant chacune un succes,
une identite de table incorrecte et un timeout sans retry. Le dry-run est
valide. GET des seules metadonnees de la base distante confirme HTTP 200,
id p7jzofcton1tabh et titre App Ergo Staging. Aucune table ni ligne distante
n'avait ete creee ou modifiee pendant cette preparation.

Execution reelle AUTORISEE puis REUSSIE le 2026-09-09 vers 17:52 CEST,
apres l'accord utilisateur « ok tu peux demarrer ». Commande executee :

```sh
node tools/probe-nocodb-conditional-write.mjs --base=p7jzofcton1tabh --apply
```

Table fictive creee : codex_sync_probe_3ca73c1cd9f547049980875119f053a9,
identifiant md38tdejnvrqlry, dans la seule base p7jzofcton1tabh.
Elle contient deux lignes synthetiques et reste conservee pour inspection.
Aucune table preexistante, aucun dossier utilisateur ni aucune donnee de
production n'a ete modifie.

Resultat du processus : exit code 0. Quatre controles reels reussis :

- deux ecritures lancees avec la meme revision : une seule appliquee,
  verifiee par relecture de la revision et des deux marqueurs distincts ;
- nouvelle tentative avec la revision obsolete : ligne gagnante inchangee ;
- ligne temoin : integralement inchangee ;
- ecriture suivante avec la bonne revision : appliquee et relue correctement.

Les deux reponses concurrentes ont renvoye respectivement 1 et 0, mais ces
compteurs n'ont pas servi de preuve d'acquittement : les assertions portent
sur les donnees relues. Il s'agit d'un scenario reel reussi sur cette
installation, pas d'un test de charge, de tous les interleavings possibles,
des coupures reseau reelles ou de deux iPad.

Cette preuve, meme positive, ne suffit pas seule a activer F05 : il faudra
garantir que tous les writers des tables concernees maintiennent la revision
(anciens clients, autres routes et editions NocoDB compris), traiter les
lectures de confirmation ambigues, puis raccorder API, file et resolution.
Le choix utilisateur et le retrait du force-local restent non actives.
Pas de changement de production, de schema existant, de build ou de deploy.

### Etape 7D - Transport conditionnel teste et preparation iOS

Le 2026-09-09, ajout de server/nocodbConditionalWrite.mjs. Ce module reste
volontairement non raccorde aux routes metier : activation uniquement apres
preparation des revisions et garantie que tous les chemins d'ecriture les
maintiennent. Il exige une table explicitement autorisee, verifie son schema
et sa base, puis filtre l'UPDATE sur Id ET revision UUID. Aucun Id dans le
corps du PATCH, aucun repli vers une ecriture non conditionnelle.

L'acquittement exige de relire la revision writeId et les valeurs exactes du
patch. Si une reponse est perdue apres application, une reprise avec le MEME
writeId reconnait l'ecriture sans second PATCH. Ce writeId devra etre conserve
durablement par l'appelant avant envoi. Une erreur apres debut de mutation
reste explicitement incertaine ; une relecture divergente n'est ni acquittee,
ni presentee comme une preuve certaine que l'ecriture n'a jamais eu lieu.

12 tests unitaires couvrent le transport, les entrelacements concurrents,
les faux compteurs de succes, les pertes de reponse, les erreurs de relecture,
les revisions obsoletes, les donnees divergentes sous un meme writeId et les
garde-fous de schema/identite/champs.

Verification distante REUSSIE du module lui-meme sur la table fictive DEJA
creee et autorisee md38tdejnvrqlry, sans creation de table supplementaire :

```sh
node tools/verify-nocodb-conditional-writer.mjs --base=p7jzofcton1tabh --apply
```

Le mode par defaut reste sans reseau. Le script refuse toute autre base ou
identite de table ; quatre tests locaux couvrent ces garde-fous et le scenario.
L'adaptateur REST a delai borne est partage avec le premier script de probe.

Six controles distants reussis : ecriture confirmee, rejeu sans PATCH, perte
SIMULEE de reponse apres PATCH reel puis reprise sans PATCH, deux ecritures
concurrentes avec un seul gagnant, rejet de version obsolete, ligne temoin
integralement inchangee. La barriere du test attend que les deux writers aient
lu la meme version avant d'envoyer leurs PATCH ; les deux marqueurs distincts
prouvent qu'un seul a modifie la ligne. Quatre PATCH au total pour ce scenario.
Ce test ne simule pas une panne reseau physique ni deux iPad. Seule la premiere
ligne fictive a ete modifiee ; aucune donnee utilisateur/production touchee.

Controles avant futur build :

- 101 tests Node reussis pour server/*.test.mjs, les deux probes et les
  controles d'artefacts de publication ;
- flutter analyze --no-pub : aucune anomalie ;
- derniere suite Flutter complete de l'etape 7B : 313 tests reussis ;
- compilation iOS RELEASE complete reussie en 163,4 secondes, Runner.app
  36,8 Mo, avec la commande ci-dessous ;
- git diff --check sans erreur.

```sh
flutter build ios --release --no-codesign --no-pub \
  --dart-define=AIDHABITAT_API_BASE_URL=https://api.aidhabitat.fr
```

Cette compilation est NON SIGNEE : aucune archive distribuee, aucun envoi
TestFlight/Apple, aucun commit/push/deploiement. Version source inchangee
1.0.0+18, minimum iOS 26.5. Les fichiers generes ne changent pas le perimetre
Git suivi observe avant compilation.

**Limite de livraison F05 : non terminee.** Le retry force-local sur 409 est
encore present dans nocodb_sync_service.dart. Le nouveau transport n'est pas
appele par les routes actives. Restent la preparation des tables et des autres
writers, le contrat API normalise, le writeId durable de la file et la
resolution utilisateur transactionnelle. Ne pas annoncer cette protection
comme active dans le prochain build sans ces raccordements et leurs tests.

Un build iPad peut embarquer les correctifs Flutter/natifs deja integres,
mais les optimisations Node demandent un deploiement API distinct. La recette
physique reste necessaire : rotation/enregistrement, vignette actualisee,
partage nom+extension, hors ligne/reconnexion, puis synchronisation entre
deux appareils. Le numero du prochain build devra etre verifie contre App
Store Connect avant signature, sans deduire sa disponibilite du seul pubspec.

## Etape 7E - Corrections de file avant livraison

Demande utilisateur : terminer les etapes necessaires avant le build, puis
push une fois termine. Aucun commit/push ni deploiement lance dans cette
etape : le perimetre F05 complet reste ouvert, voir les conditions ci-dessous.

Corrections effectives dans le moteur et le repository SQLite :

- les reponses patient/logement/contexte/mesures/observations/diagnostic/
  preconisations ne positionnent plus directement sync_state=synced ;
  l'acquittement transactionnel de la file est seul responsable de cet etat ;
- la version serveur recue est conservee uniquement si la meme operation,
  la meme entite et le meme payload possedent encore la reponse ; une saisie
  remplacee pendant l'envoi ne recoit pas la reference de l'ancienne reponse ;
- correction du binding housing : les operations portent l'identifiant du
  dossier, et il faut suivre dossiers.housing_local_id pour atteindre la ligne
  logement. L'ancien binding local_id=entityLocalId ne la mettait pas a jour ;
- une operation en backoff, running, failed, conflict ou etat inconnu bloque
  les suivantes de la meme entite ; les autres entites continuent. La prise
  en charge transactionnelle verifie de nouveau les blocages apres lecture ;
- le compteur des travaux non termines inclut running et conflict. Un rapport
  attend aussi les pre-requis running/conflict de SON dossier, sans etre
  bloque par un autre beneficiaire ;
- les transitions failed/transient/conflict et l'etat de l'entite sont dans
  une seule transaction : une erreur SQLite ne laisse plus une demi-transition ;
- markCompleted renvoie si l'acquittement a effectivement ete accepte ; une
  ancienne operation remplacee n'est plus comptee comme une synchronisation
  reussie et ne laisse pas partir les suivantes de son groupe ;
- le resultat du retry historique apres 409 remonte maintenant ses vrais
  compteurs : un echec ne compte plus comme pushed ; une erreur transitoire
  preserve l'attente et bloque les operations suivantes du groupe ;
- correction de isTransientErrorLike pour reconnaitre aussi une exception
  TransientRemoteException typee. Le premier push la capturait explicitement,
  mais le catch du retry la classait a tort comme definitive ;
- un drain partage entre instances NocodbSyncService empeche le push manuel
  de DataService et le push automatique de SyncEngine de lancer deux pools
  concurrents sur la meme base SQLite. Ce verrou LOCAL ne remplace pas la
  condition atomique requise entre appareils/instances serveur.

Verification :

- suite Flutter COMPLETE : 340 tests reussis (contre 313 avant cette etape),
  dont reprise apres 409, remplacement pendant ACK, serialisation des drains,
  blocages de file, pre-requis rapport et rollback des transitions SQLite ;
- suite Node serveur/contrats/probes/publication/PDF/surface publique :
  116 tests reussis ;
- controles de parcours critiques : 20/20 ; contrat autonomie : 11 elements ;
- PDFKit natif compile et execute sur le Mac avec fichiers fictifs : lecture,
  ecriture, quatre orientations, boites decalees, verification de pixels,
  gomme, sauvegardes repetees, conservation de l'original et du texte : PASS ;
- flutter analyze --no-pub : aucune anomalie ;
- compilation iOS release NON SIGNEE reussie : Xcode 44,2 s, Runner.app 36,8 Mo.
- compilation web release reussie : 41,2 s, sortie build/web ;
- git diff --check sans erreur.

Les echecs rencontres pendant les tests ont ete corriges, pas ignores :
le test de retry 503 a expose la mauvaise classification transitoire ; un
ancien test affirmait explicitement cette classification incorrecte et a ete
mis a jour pour couvrir le chemin de retry reel. La suite complete repasse.

**F05 n'est toujours pas annonce comme termine ou active.** Les corrections
ci-dessus securisent le traitement local mais ne raccordent pas le writer
conditionnel aux routes actives, ni le choix utilisateur a une resolution
transactionnelle. Le force-local historique apres 409 reste present. Sa
suppression isolee laisserait des conflits sans parcours de resolution fiable.

Une question a ete adressee a l'utilisateur sur les outils qui ecrivent
aujourd'hui directement dans NocoDB (edition manuelle, Make, imports Airtable,
autres). Le versionnement UUID exige leur prise en compte ; un simple build
iPad ne peut pas proteger les ecritures qui contournent ce protocole. Il reste
egalement a raccorder le contrat API, la file durable et la resolution, puis
a verifier l'ensemble en staging avant activation. Ne pas confondre cet
inventaire necessaire avec une integration deja terminee.

Aucune donnee reelle modifiee, aucune migration distante appliquee pendant
cette etape. La recette physique iPad/Apple Pencil/AirDrop et deux appareils
reste distincte des tests automatiques locaux. Le futur deploiement API reste
distinct de l'archive native et de son envoi TestFlight.

Controle live de la stack existante, uniquement GET/HEAD, avec
tools/check-live-stack.mjs --timeout-ms 10000 : le PWA, /api/health/live et
/api/health/ready passent, mais GET/HEAD / et /openapi.json renvoient HTTP 500
HTML au lieu du 403/404 JSON attendu. Le controle global est donc EN ECHEC,
pas valide malgre les checks de sante positifs. Une requete GET independante
confirme le 500. Aucun deploiement ou parametre distant n'a ete modifie.

Reproduction locale avec l'application Express COMPLETE, un repertoire de
donnees temporaire, AIDHABITAT_API_ONLY=1, sans identifiants NocoDB/SMTP et sans
appels sortants : les quatre GET/HEAD renvoient bien 404 et /api/health/live
reste a 200. Ce scenario est maintenant couvert par
server/publicSurface.test.mjs, execute dans un processus isole sans lecture
du .env.local du projet. Cela ne prouve pas la cause du 500 distant : les logs
et la configuration/version du deploiement restent a verifier. Le controle
live doit repasser apres la prochaine livraison serveur.

## Etape 7F - Erreurs 500 publiques corrigees en ligne

Le 9 septembre 2026, l'utilisateur confirme que seule l'application iPad
ecrit actuellement dans NocoDB. Cette information est conservee pour F05 ;
elle ne signifie pas que son writer conditionnel est deja raccorde.
La presente intervention porte uniquement sur les erreurs 500 publiques.

Cause confirmee par les logs du conteneur distant :

- le service apps_aidhabitat-api-staging dessert bien api.aidhabitat.fr,
  malgre son ancien nom staging (routage Traefik verifie) ;
- son image datait du 25 aout, revision
  a4941bfd163f3c0ea1b5a2253354ebb25e49cdcb ;
- GET/HEAD / et /openapi.json tombaient dans le fallback du site web,
  qui executait fs.access('/app/dist/index.html') ; ce fichier est
  intentionnellement absent de l'image API ;
- l'ENOENT remontait au gestionnaire Express par defaut, produisant
  une reponse HTML 500 au lieu du refus JSON attendu ;
- le correctif etait deja publie dans l'image du 28 aout, revision
  15d6fec5a5090589db38c4ca21bdb374855977b0. Le run GitHub Actions
  33174557489 avait reussi la construction/publication de l'image,
  puis echoue a l'etape Trigger Easypanel redeploy.

Correction effectivement deployee : remplacement de l'image de CE service
Docker Swarm par l'image existante verifiee, sans construire ni publier les
modifications locales en attente. Digest actif :
sha256:b21a8faebe97c30e109e19ebf338310ceff4644e42060c0e3ac5eb2f05248d3d.
L'ancien digest reste disponible pour retour arriere :
sha256:0dc26d33e907b24ef9e49213d072541883866903d248bbb70609c8a747545a91.

Le diff des deux revisions dans le perimetre serveur/image concerne
uniquement Dockerfile.api, server/index.mjs et server/routes/references.mjs :
mode API seul, refus JSON des routes absentes, traitement ENOENT, placement
final du gestionnaire d'erreurs et normalisation des messages de sante.
Aucune modification des routes metier, dependances ou du protocole de sync
n'est incluse. Les variables, volumes, secrets/configs et reseaux du service
ont la meme empreinte SHA-256 avant et apres remplacement. Le rollout
start-first existant a converge, une seule replique active.

Verifications executees :

- image publiee testee dans un conteneur jetable, sans reseau externe,
  sans volumes ni identifiants de production : GET/HEAD /, /openapi.json
  et /api/does-not-exist retournent 404 JSON ; liveness retourne 200 ;
- server/publicSurface.test.mjs repasse sur le code local ;
- tools/check-live-stack.mjs --timeout-ms 10000 reproduisait les quatre
  500 juste avant la bascule ; apres bascule, les 7 controles passent :
  PWA, liveness/readiness et CORS, GET/HEAD /, GET/HEAD /openapi.json ;
- aucun ENOENT dist/index.html ni message fatal dans les logs du nouveau
  conteneur apres ces requetes.

Ce blocage live est donc RESOLU. Aucun import, migration ou changement manuel
de donnees NocoDB ; aucun commit/push du chantier local, aucune nouvelle
archive iPad ni livraison TestFlight. Le demarrage normal de l'API conserve
son fonctionnement existant. Le pipeline automatique n'a pas ete reconfigure
ici : la prochaine livraison devra toujours verifier le redeploiement reel,
et pas seulement la publication de l'image. F05 et la recette physique
restent des travaux distincts, non declares termines par cette intervention.

## Etape 7G - F05 : conflits durables et raccordement conditionnel prepare

Travail du 10 septembre 2026, apres l'accord utilisateur pour poursuivre.
Tout reste LOCAL ; aucune nouvelle livraison serveur/iPad ni push. Le
service public corrige en 7F reste sain (7 controles GET/HEAD reussis).

### Client et resolution locale

- Suppression du retry force-local apres 409 : une operation rejetee n'est
  plus renvoyee sans garde. Les 428 (reference requise) suivent le parcours
  de conflit plutot qu'une erreur definitive sans solution.
- Le moteur transmet la reference capturee au save pour patient/logement/
  dossier et non une reference plus recente lue pendant le push. Un nouveau
  payload v1 sans timestamp valide est conserve pour verification explicite.
- Les mutations capturees possedent un UUID writeId durable ; une nouvelle
  edition ou une resolution volontaire genere un autre UUID. Un retry du
  meme payload conserve son UUID. Les anciens payloads sans UUID ne sont
  pas artificiellement declares compatibles avec le futur protocole.
- markConflict ne conserve une reponse que si l'operation, son entite, son
  statut running ET son payload correspondent encore a la requete envoyee.
  La reponse distante est chiffree avec le payload de la mutation. Une
  ancienne reponse ne marque pas une nouvelle saisie en conflit.
- Les conflits survivent au boot et au pull, bloquent les operations suivantes
  de leur entite et les rapports dependants ; les autres entites continuent.
  Une nouvelle saisie patient/logement/dossier conserve l'etat conflict et
  son ancienne reference au lieu de relancer implicitement la file.
- L'ecran affiche les champs du PATCH concerne et les valeurs serveur
  canoniques reconstruites avec les mappers SQLite/API, pas un remplacement
  du dossier entier. Une comparaison incomplete ou indisponible refuse la
  resolution. Les trois entites principales sont couvertes a cette etape.
- Garder le local remet le meme PATCH en attente avec la reference observee
  et un nouvel UUID, sans retirer la garde. Prendre le distant ne remplace
  que les colonnes du PATCH relu. Une autre saisie/operation sur la meme
  entite invalide la comparaison ; aucun effacement global de la file.
- Migration SQLite additive 21 -> 22 : sync_conflict_history. Mutation
  d'origine, valeurs distantes et decision sont archivees via OfflineVault.
  Archive, changement de file et valeurs locales partagent une transaction.
  L'historique n'est pas purge avec les operations completed de plus de 24 h.
- Suppression des anciens helpers inutilises de resolution par remplacement
  complet, qui inventaient aussi un remote_updated_at depuis l'horloge locale.

### Serveur : raccordement SOUS FLAG, non active

server/guardedMutation.mjs compare les champs mappes en vocabulaire NocoDB
a leur baseline et a une lecture distante. Les colonnes derivees et JSON
sont des valeurs atomiques. Un conflit sur un champ interdit tout le PATCH.
Les changements independants sont proposes au writer Id + revision UUID
teste en 7D ; une course avant ecriture provoque au plus une recomparaison
complete, jamais un simple remplacement de reference. Une confirmation
ambigue reste 503 et conserve la mutation pour reprise.

Le raccordement aux PATCH beneficiaire, logement et dossier est present
sous AIDHABITAT_CONDITIONAL_SYNC=1. Ce flag est DESACTIVE par defaut et n'a
pas ete configure sur le serveur. En mode actif, les creations initialisent
une revision apres verification du schema. Les updateRecords non gardes
sur ces trois tables sont refuses jusque dans l'adaptateur MCP/REST.
Le backfill interne des attributions de dossiers utilise aussi le writer
conditionnel : il constituait un autre chemin d'ecriture de l'application.
Les mutations melant dossier et contexte ne sont pas declarees atomiques.

### Verifications et limites de bascule

Resultats locaux :

- suite Flutter complete : 356 tests reussis, dont nouvelles regressions
  de conflit, reprise, payload remplace, rollback SQLite et migration 21->22 ;
- ecran teste aux largeurs 390 et 1024, choix unique pendant un await,
  refus des comparaisons offline/stale ; goldens de layout avec police Ahem
  du runner (pas une recette typographique sur appareil reel) ;
- suite Node serveur/contrats/probes/PDF/publication : 145 tests reussis,
  dont 13 du coordinateur et deux garde-fous supplementaires du transport ;
- flutter analyze --no-pub : aucune anomalie ;
- iOS release NON SIGNE : compilation Xcode reussie en 44,5 s,
  Runner.app 36,8 Mo ; aucun build TestFlight envoye ;
- parcours critiques 20/20, contrat autonomie 11 elements, git diff --check OK.

Deux anciens tests de transitions utilisaient une fonction dynamique commune
aux erreurs et conflits : ils ont ete adaptes au nouveau contrat explicite
de markConflict (payload attendu). Le test de redemarrage qui exigeait le
rejeu d'un conflit exige maintenant sa conservation. Ces tests n'ont pas
ete supprimes pour masquer un echec.

Metadonnees NocoDB lues UNIQUEMENT par GET, sans dossiers ni donnees metier :
les tables beneficiaires muvp56d5i9z2qbe, logements mgdpvdrnzyy6n4k et
dossiers mez74y7ndoej30p appartiennent a la base pskgbjythubfzv9.
Aucune ne possede app_sync_revision. Les schemas contiennent notamment
des colonnes ForeignKey (par exemple communes_id), volontairement refusees
par le transport conditionnel actuel faute de preuve distante suffisante.

**F05 reste non livrable en protection complete. Ne pas activer le flag.**
Il reste a valider les mappers et cles etrangeres sur des fixtures staging
representatives, preparer les colonnes/revisions, couvrir les autres tables
de saisie et la resolution des conflits historiques hors des trois entites
principales, puis tester les routes actives avec authentification et deux
clients. Les tests du coordinateur ne remplacent pas ces tests de routes.
La compatibilite des anciens iPad et la bascule sans ancien writer encore
en vol doivent etre gerees explicitement. Le nouveau client conserve deja
les 409, mais le serveur actuel garde la fenetre lecture/ecriture historique
tant que le writer conditionnel n'est pas active.

Aucune migration NocoDB, creation de table distante, modification de dossier
reel ou nouveau deploiement pendant cette etape. L'ajout technique de
revision en production n'est pas deduit des seuls tests de la table fictive.

## Etape 7H - Consolidation avant livraison, 10 septembre 2026

Suite de la demande de terminer les verifications avant le build. Aucun
commit, push, build de livraison ou deploiement dans cette etape. Les
corrections ci-dessous sont locales ; le flag serveur reste DESACTIVE.

### Ecritures conditionnelles : preuves supplementaires

- Nouvelle fixture ISOLEE dans App Ergo Staging, base p7jzofcton1tabh :
  parent mdiilatrbpwdfny et enfant m4jwiaxge75rmnz, suffixe unique
  2ec223b039cc494fac71c7f1299f684a. Deux lignes enfant synthetiques dont
  une sentinelle. Aucun dossier metier utilise ; fixtures conservees.
- Le vrai endpoint NocoDB bulk conditionnel a confirme une ForeignKey ET
  sa relation belongs-to, la case a cocher, Date, DateTime et LongText JSON.
  Un patch obsolete n'a rien change ; la sentinelle est restee intacte.
- Le transport de production prepare est ensuite passe sur cette fixture :
  confirmation, rejeu sans deuxieme PATCH, suppression/restauration du lien
  via null et colonne avec accent. La colonne de test avec accent a ete
  ajoutee uniquement a cette fixture dont l'identite est verifiee.
- NocoDB renvoie DateTime sous la forme `2026-09-10 09:30:00+00:00`,
  differente de l'ISO envoye. Nouveau comparateur dependant du schema :
  equivalence des instants zones, precision microseconde preservee, aucune
  interpretation implicite des dates sans fuseau. Les Checkbox string
  true/false sont canonicalisees ; les colonnes texte ne sont pas coercies.
- Les FK restent limitees aux colonnes verifiees avec relation bt dans
  la meme base, valeur entier positif/null. Pas de listes relationnelles.
- Les noms de colonnes Unicode verifies dans le schema sont acceptes,
  notamment reconnaissance_invalidite_mdph_txt avec e accent aigu dans le
  vrai mapper. Les identifiants table/filtre restent contraints ; virgules,
  parentheses et champs reserves restent interdits.
- Une erreur de schema remonte en 503 ; SyncMutationError preserve aussi
  statusCode hors du helper. Aucun fallback inconditionnel ajoute.
- Correction du faux acquittement apres annulation locale : si la valeur
  locale revient a sa baseline mais differe du distant, le serveur exige
  une comparaison explicite (409) plutot que marquer une valeur obsolete
  comme synchronisee. Le client actuel ne consomme pas de valeurs
  canoniques dans la reponse PATCH, seulement updatedAt.

Commandes distantes executees :

```sh
node tools/verify-nocodb-linked-write.mjs --base=p7jzofcton1tabh --apply
node tools/verify-nocodb-linked-write.mjs --base=p7jzofcton1tabh --verify-existing --apply
node tools/check-conditional-sync-readiness.mjs --base=pskgbjythubfzv9 --check
```

Le dernier outil est STRICTEMENT en lecture. Il a confirme que les trois
tables reelles ne sont pas preparees. Aucune ligne metier lue pour ce
controle (schema insuffisant), aucune ecriture en production. Sa sortie
est volontairement non-zero ; un health 200 n'autorise pas la bascule.

Les nouveaux tests HTTP lancent le vrai Express avec un vrai login et des
identites synthetiques, dans un processus sans credentials herites. Le
mock NocoDB refuse tout appel inconnu et tout reseau externe. 34 scenarios
couvrent les trois PATCH, 401/403/428 sans ecriture, schema absent, deux
clients, courses sur champs communs/independants, reponse perdue et rejeu.
Cette preuve HTTP complete la fixture distante, sans les confondre : pas
de deploiement du vrai serveur contre des dossiers de production.

### Sauvegarde locale et formulaires

- Les cinq entites secondaires conservent conflit, baseline et payload
  apres reedition. Leurs references sont explicitement `localReference`,
  pas des gardes reseau faussement completes. Les merges et mises en file
  passent par une transaction. Leur resolution serveur/UI reste ouverte.
- Les preconisations devenues uniquement brouillons restent sauvegardees
  localement. Si une intention publiee/publiante existait, une liste vide
  retire les elements distants, avec la meme baseline ; le premier
  brouillon sans reference n'envoie pas de suppression. Les brouillons
  survivent a l'acquittement et aux pulls. Aucun StateError nouveau ne
  bloque cette transition.
- BeneficiaryTab envoie uniquement les differences du formulaire depuis
  sa derniere sauvegarde locale confirmee. Patient et champs admin sont
  suivis separement. Saves serialises, saisies pendant await conservees,
  pas de rehydratation concurrente. Reprises automatiques bornees 1/2/4 s,
  puis erreur visible et action Reessayer. Flush dispose best effort.
  La reference repository reste capturee au save : le cas d'un pull
  intervenu pendant une edition du MEME champ n'est pas declare resolu.
- Au boot iOS, recuperation des running anterieurs au debut du processus,
  meme recents, sans attendre 72 h. Le cutoff reste fixe si une tache de
  boot reprend tard. Running nouveaux et conflits exclus ; web/desktop
  conservent leur delai conservateur pour ne pas reprendre un autre tab.
- SQLCipher : suppression du chemin rename/delete/recreation automatique
  apres erreur. Base, WAL, SHM et journal ne sont plus deplaces/effaces par
  ce code de recuperation. Ouverture partagee entre appelants. En cas
  d'echec au boot, ecran de stockage indisponible avec relance ; pas de
  lancement du sync/editor contre une base inaccessible. Les tests
  injectent l'erreur d'ouverture et verifient les fichiers, ils ne
  remplacent pas un test SQLCipher/Keychain sur iPad.
- La date de visite choisie est serialisee en instant UTC depuis l'heure
  Europe/Paris, pour eviter le decalage au retour NocoDB. L'heure locale
  inexistante au passage a l'heure d'ete est refusee explicitement.
- F20 : import de l'icone X manquante dans le composant React historique.

### Publication et validations

- Dockerfile API et CI Node alignes sur Node 24 ; SHA complet requis dans
  l'image. Endpoints live/ready exposent uniquement le SHA valide, sans
  cache. Apres webhook, la CI attend le SHA attendu ET readiness 200, avec
  delais bornes couvrant aussi le corps HTTP ; redirects refuses. README
  Easypanel actualise. Aucun webhook ou nouveau conteneur lance ici.
- Le daemon Docker local est arrete : compatibilite du conteneur Alpine
  NON executee. Tests Node executes sous Node 24.11.0 ; ne pas les
  presenter comme une execution de l'image Docker.
- Les regressions serveur et les nouveaux tests Flutter critiques sont
  raccordes a la CI. Le script critique reste syntaxiquement valide.

Resultats apres integration :

- 472 tests Flutter passes ;
- 194 tests Node passes (incluant les tests HTTP/routes et de publication) ;
- flutter analyze : aucune anomalie ; TypeScript `tsc --noEmit` reussi ;
- controles critiques 20/20, contrat autonomie 11 elements, diff propre ;
- npm audit --omit=dev : aucune vulnerabilite signalee a cette date ;
- 7 controles live publics reussis, sans deploiement des modifications.

**Le lot n'est PAS encore declare pret au build avec F05 complet.**
Les revisions de production, le protocole des tables secondaires/listes,
leur resolution UI et les anciens payloads/appareils restent a terminer.
Ne pas activer globalement le flag pour combler ces lacunes. La recette
physique iPad (Pencil, AirDrop, offline, redemarrage, mise a jour de la
base chiffree) reste aussi a faire. Voir le rapport de compatibilite
`docs/sync-release-readiness-2026-09-10.md` ; certains constats de sa
lecture precedente sont corriges ci-dessus (dates, accents, faux no-op,
recovery SQLCipher, preuve HTTP et fixture distante).

## Etape 7I - Versions et resolution des fiches secondaires (10 septembre)

Lot local, sans push, build, deploiement ni activation du flag conditionnel.

- Migration SQLite v23 additive : `remote_updated_at` nullable pour mesures,
  observations et diagnostics sanitaires. Les anciennes valeurs et operations
  ne sont pas reecrites ; aucune version n'est fabriquee pendant la migration.
- GET de ces trois fiches : identite du dossier et horodatage propre a la ligne.
  PUT : version capturee transmise, 409/428 sans ecriture si obsolete/incomplete,
  puis relecture des champs persistants avant confirmation. Une reponse non
  verifiable reste une erreur transitoire, pas un acquittement de sauvegarde.
- Les PUT lisent seulement les lignes du dossier autorise, au lieu de charger
  toute la table. Les requetes interdites ne lisent plus les fiches secondaires.
  Les clients historiques sans garde restent acceptes.
- Baseline/version capturees au premier changement d'une fiche synchronisee.
  Les reeditions conservent la reference initiale. Les anciennes operations
  `localReference` restent historiques, sans promotion implicite en garde reseau.
- Comparaison et resolution locale/serveur des trois fiches dans l'ecran existant,
  avec historique chiffre et transaction SQLite. Une nouvelle saisie invalide
  une comparaison precedente. Seuls les champs compares sont remplaces ; les
  listes SDB/WC sont traitees comme des champs structures, pas fusionnees par index.
- Les conflits secondaires remontent dans l'etat du dossier pour rendre le
  bouton de resolution accessible. Double validation avant reconstruction UI
  bloquee. Lectures de comparaison limitees aux types en conflit.
- Identifiants distants utilises pour les dossiers crees hors ligne, lors de la
  comparaison et du transport des trois fiches. Suppression du fallback a l'heure
  locale dans les mappers de versions patient/logement/dossier.
- Acquittement des trois enfants conditionne au payload exact encore en cours :
  une reponse tardive ne valide pas une saisie plus recente.

Verification de structure en production : GET metadata uniquement de la table
diagnostic sanitaire. Les champs booleens historiques sont des SingleLineText,
les hauteurs melangent SingleLineText et Number, les listes sont LongText,
`dossiers_id` est ForeignKey. Aucune ligne metier lue ou modifiee pour ce controle.

Limites toujours ouvertes : la comparaison d'horodatage suivie d'une ecriture
reste non atomique. Le contexte de vie et la liste des preconisations ne sont
pas couverts par ce nouveau parcours de resolution. Le protocole atomique, la
migration des revisions NocoDB et la transition des anciens iPad restent a
terminer avant de declarer F05 integralement resolu. La reference de formulaire
capturee avant un pull concurrent sur le meme champ reste egalement ouverte.

La premiere relance complete a expose une fragilite du test PDF natif : delai
fixe de 120 ms avant `pumpAndSettle`, insuffisant pour garantir la fin des I/O
SQLite/fichiers. Le timeout provoquait ensuite une fermeture PDF apres retrait
du mock natif. Le test attend maintenant la fin effective de la sauvegarde
(borne reelle de 10 s avec frames), et dispose le widget avant de retirer les
canaux simules. Les trois cas passent isoles ; aucun code PDF de production
n'a ete change pour masquer ces echecs. Ces tests rejoignent la suite critique.

Verification TypeScript : `tsconfig.json` exclut desormais les sorties generees
`dist`, `aid_habitat_app/build` et `.dart_tool`, en conservant les exclusions de
dependances habituelles. Comparaison par le parseur TypeScript des configurations
avant/apres : 27 fichiers generes retires, aucun fichier source retire, 150
fichiers racines conserves. `tsc --noEmit` termine sans erreur. Cela ne modifie
pas le bundle ni le fonctionnement de l'application.

Resultats finaux du lot : 619 tests Flutter passes (dont 147 nouveaux), 195 tests
Node passes (incluant 51 scenarios HTTP secondaires dans leur test d'integration),
TypeScript sans erreur, controles critiques 20/20, contrat autonomie 11 elements,
syntaxe du script critique et `git diff --check` valides. Les simulations natives
PDF et la migration SQLite FFI ne remplacent pas la recette sur iPad reel.

## Etape 7J - Garde-fous du coordinateur commun (10 septembre)

Pendant le travail isole des cinq agents : validation structurelle partagee entre
le coordinateur et le writer, avant les raccourcis no-op/rejeu. Les cles reservees,
valeurs non scalaires/non finies et baselines mal formees sont rejetees en 400
sans lecture ni ecriture, meme si un faux instantane distant semble les confirmer.
Les champs structures API doivent etre mappes en colonnes JSON serialisees avant
ce niveau, comme pour les ecritures effectives.

`ConditionalWriteUncertainError` porte aussi HTTP 503 lorsqu'elle est propagee
hors de l'adaptateur de route, au lieu d'un 500 generique. Le rejeu conserve le
meme identifiant de mutation et ne renvoie pas de second PATCH si la premiere
ecriture est confirmee. 205 tests Node passes, dont 10 nouveaux. Pas de changement
Flutter, de schema distant, de push, de build ou d'activation en production.

Contrat de raccordement : `docs/integration-sync-agents-2026-09-10.md`.

## Etape 7K - Integration de la revue et reponses tardives (10 septembre)

Travail en cours, pas une autorisation de build. Les snapshots bruts SQLite
accompagnent maintenant le formulaire beneficiaire : un pull du meme champ
pendant la saisie conserve le candidat et la valeur concurrente dans un conflit
durable. Les champs sans rapport ne bloquent pas la saisie. 35 tests cibles
passes, puis 622 tests Flutter passes sur cet instantane.

Revue independante Agent 5 recue. Le nettoyage implicite des documents distants
absents des photos inline du rapport a ete retire : une liste partielle n'est
pas une intention de suppression. 205 tests Node passes apres ce retrait ; test
HTTP specifique demande a Agent 4, non encore recu.

Images et fallbacks de rotation passent maintenant leur reference d'ouverture.
Une annotation avec rotation ne publie plus deux remplacements successifs. Le
repository retourne la revision exacte commitee, sans relire une eventuelle
revision recue entre commit et retour a l'apercu.

Session : les workers capturent un epoch et un jeton, controles avant transport
et pendant lecture de reponse. Un changement de session suspend l'ancien drain
et les anciens callbacks UI. Les batches en attente ne doivent pas adopter le
nouveau compte. L'attribution durable des intentions a leur auteur reste a
integrer avec Agent 3 : cette protection reseau seule ne clot pas R4.

626 tests Flutter, 205 Node et analyse Flutter sans erreur passes avant le
dernier ajustement du retour de revision et de l'ACK creation. Ensuite les deux
tests rouges creation hors ligne d'Agent 4 passent avec le correctif : les IDs
distants ne fabriquent plus de date serveur ; patient/logement tiennent compte
de leurs intentions restantes. Lot cible creation + PDF : 30 tests passes.

Restent en cours : integration Wiki transactionnelle et remappage des liens,
compatibilite/auteur de file, raccord contextes/preconisations. Les modules CAS
distants necessitent toujours migrations, unicite et qualification staging ;
les gardes timestamp seules des fiches secondaires ne sont pas atomiques.
La recette SQLCipher et PDF sur iPad reel reste non executee. Aucun push,
deploiement, modification de base metier ni build de publication dans ce lot.

## Etape 7L - Integration locale et verification croisee (10 septembre)

Cette section actualise les points encore marques en cours dans 7K ; les
comptes de tests precedents restent des instantanes, pas des totaux cumulables.

- Rapport : test HTTP Express reel recu et passe. Un ensemble partiel de
  photos inline ne supprime plus aucun document distant ; PDF genere valide.
- Wiki : acquittement et remappage des IDs dans une seule transaction SQLite,
  comparaison du payload en cours, conservation des modifications et suppressions
  suivantes. Remappage des references de preconisations dans cette transaction.
  Tests avec reponse HTTP retardee passes. Une reponse POST perdue avant le
  commit local peut toujours exiger une idempotence serveur : R3 pas clos globalement.
- Preconisations : un cache Wiki partiel ne retire plus des references distantes
  valides au moment de sauvegarder. Modules de publication atomique et de contexte
  relus et testes, mais PAS raccordes aux routes actives ni actives en production.
- File : le drain ne garde que les metadonnees ; chaque worker charge le payload
  de son operation courante. Relecture et claim protegent les snapshots remplaces.
  Une erreur de lecture locale devient visible sans effacer le payload ni bloquer
  les groupes des autres entites. Les formats de date historiques sont compares
  comme instants, puis le CAS utilise le texte SQLite brut.
- Comptes : schema local v24 additif, auteur capture a l'insertion, historique
  avant remplacement intercompte, absence d'attribution automatique de l'historique.
  Filtrage et claim verifies avec le constructeur de production. Les tests de
  persistance sans authentification utilisent explicitement le constructeur
  forTesting ; ils ne prouvent pas eux-memes le cloisonnement entre comptes.
  Ecran de revue administrateur encore en integration au moment de cette note.
- Web : migration du coffre v2 stricte, marqueur seulement apres succes, erreurs
  de chiffrement/ecriture propagees, lecture des contenus ligne par ligne. Les
  triggers d'historique ne sont installes qu'apres cette preparation. Le test
  injecte un chiffreur pour verifier l'echec/reprise, sans pretendre executer
  WebCrypto dans les tests Flutter natifs.

Verification de l'instantane avant les derniers tests coffre/UI : 702 tests
Flutter passes ; 234 tests Node passes ; analyse Flutter et TypeScript sans
erreur ; 20 controles de parcours critiques et contrat autonomie passes.
PDFKit natif macOS compile et execute : quatre rotations, boites decalees,
pixels, effacement, sauvegardes repetees et conservation texte/original passes.
Controle live en lecture seule : 7 controles passes, dont readiness et absence
de 500 sur GET/HEAD / et /openapi.json. Aucun deploiement dans cette etape.

Limites a ne pas confondre avec les tests locaux : SQLCipher et fluidite iPad
physique non qualifies ; aucune preuve de migration du schema NocoDB metier ;
unicite et revisions des tables de contexte/preconisations non preparees ;
gardes timestamp des autres fiches secondaires encore non atomiques. Le flag
conditionnel serveur doit rester desactive. Le prochain push declenchera des
workflows de publication : il reste distinct de ces verifications locales.

Cloture du lot local : ecran de revue raccorde a Details, verification du compte
administrateur avant/apres decision, cible identifiable, blocage des contenus
illisibles et des operations running, validation refusee si le contenu change.
L'envoi est reveille apres commit de la decision, sans attendre la fermeture.
10 tests widget couvrent notamment le petit viewport et le changement de compte
pendant la lecture. Suite globale : 720 tests Flutter passes ; 234 tests Node
passes. Bilan et recette restante : docs/bilan-avant-build-2026-09-10.md.
Les prerequis distants et la recette physique listes plus haut restent ouverts.

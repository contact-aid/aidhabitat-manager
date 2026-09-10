# Sync release readiness - 2026-09-10

## Decision

**Ne pas activer `AIDHABITAT_CONDITIONAL_SYNC=1` sur un parc comprenant encore des anciens clients. F05 reste ouvert.** Les corrections locales peuvent etre livrees separement, avec le flag absent ou explicitement `0`, apres recette du lot effectivement retenu. Cela preserve le contrat HTTP historique des anciens iPad ; cela ne supprime pas leurs ecritures force-local, les courses serveur ni les ecritures hors protocole.

Le flag ne negocie aucune capacite par appareil : c'est un choix global, lu au chargement du processus. Un deploiement roulant avec des instances `0` et `1` derriere la meme URL donnerait des resultats incompatibles et laisserait des writers sans revision. Ajouter seulement les colonnes ou mettre a jour un seul iPad ne suffit pas.

## Perimetre et preuve

Analyse locale du workspace `/Users/aidhabitat/Downloads/aid'habitat-manager`, HEAD `10df5d4c289ffe757af6027f0be0f670fa8f97b7`, avec modifications non commitees et travaux concurrents. Les symboles cites sont les reperes principaux ; les lignes sont celles de la lecture et peuvent se decaler. Les changements du parent dans le transport et ceux de l'autre agent dans `dossier_repository.dart` ne sont ni modifies ni certifies ici.

L'entree effective est [server/index.mjs](</Users/aidhabitat/Downloads/aid'habitat-manager/server/index.mjs:1>), reexportee par [api/index.mjs](</Users/aidhabitat/Downloads/aid'habitat-manager/api/index.mjs:1>). Seuls `routes/ai.mjs` et `routes/feedback.mjs` sont montes. Les fichiers historiques `routes/dossiers.mjs`, `routes/documents.mjs`, `routes/sync.mjs`, etc. ne prouvent pas le comportement de l'API active. `helpers.mjs` reste toutefois accessible aux middlewares des routeurs AI/feedback : ne pas confondre routeur non monte et module totalement inutilise.

Dans ce document, **non protege signifie sans condition atomique de concurrence**, pas sans authentification. Les routes metier listees utilisent `requireAuth`, et les routes admin `requireAdmin`, avec des controles de portee variables. Aucun test d'authentification bout en bout n'a ete execute.

Aucun service lance, appel reseau, lecture de secrets, dossier reel, schema distant, build, commit, push ou deploiement dans cette sous-tache. L'ancien code client est celui de `git show HEAD:...`, **pas une preuve du binaire TestFlight installe**. L'audit du 9 septembre rapporte des schemas sans revision ; ce constat historique n'est pas revalide ici. Le minimum natif configure est iOS 26.5 dans [Podfile](</Users/aidhabitat/Downloads/aid'habitat-manager/aid_habitat_app/ios/Podfile:3>), `Runner.xcodeproj/project.pbxproj` et `Flutter/AppFrameworkInfo.plist`. Un appareil incapable de recevoir ce minimum ne peut pas etre suppose migrable vers le nouveau binaire. Compatibilite materielle, version de l'app et version du protocole sont trois inventaires distincts.

## Contrat exact du flag

Sources : [configuration et applyConditionalSync](</Users/aidhabitat/Downloads/aid'habitat-manager/server/index.mjs:477>), [guardedMutation](</Users/aidhabitat/Downloads/aid'habitat-manager/server/guardedMutation.mjs:1>), [writer](</Users/aidhabitat/Downloads/aid'habitat-manager/server/nocodbConditionalWrite.mjs:1>), [comparateur de valeurs](</Users/aidhabitat/Downloads/aid'habitat-manager/server/nocodbScalarValues.mjs:1>).

| Point | Comportement observe |
| --- | --- |
| Activation | Seule la chaine exacte `1` active le flag. Tables : `beneficiaires` (`muvp56d5i9z2qbe`), `logements` (`mgdpvdrnzyy6n4k`), `dossiers` (`mez74y7ndoej30p`). Aucun flag Flutter correspondant. |
| Enveloppe PATCH | `concurrency: {version: 1, writeId: UUID, baseValues: {...}}`. Baseline absente/non objet/version differente : HTTP 428 `SYNC_BASELINE_REQUIRED`. UUID absent/invalide : 428 `SYNC_MUTATION_ID_REQUIRED`. `expectedUpdatedAt` seul ne remplace pas cette enveloppe. |
| Mapping | Patch et baseline passent par le meme mapper API vers colonnes NocoDB. Baseline inconnue n'est pas assimilee a null. Un champ conflictuel interdit tout le patch de cette ligne. Les JSON sont compares comme valeurs completes, sans fusion d'occupants par indice. |
| Lecture | Lecture par `Id`, controle d'une seule ligne, schema de la table et revision UUID requis. Une revision absente/invalide produit `SYNC_REVISION_NOT_PREPARED`. La revision utilisee pour le CAS vient de cette lecture serveur, pas d'un UUID fourni par le client. |
| Ecriture | PATCH bulk v1 avec `where=(Id,eq,...)~and(app_sync_revision,eq,...)`, contenu et nouveau `writeId` dans la meme requete. Relecture confirmant revision et contenu. Un compteur HTTP n'est pas un acquittement. Aucun fallback inconditionnel du writer. |
| Reprise | Une recomparaison complete supplementaire si `revision_changed`. Confirmation ambigue : 503, meme mutation et meme UUID a conserver. Pas de journal durable de toutes les mutations cote serveur : ne pas promettre de traitement exactement une fois. |
| Autorisation | `authorizeObserved` est reexecute pour un PATCH dossier. Beneficiaire/logement : controle d'acces prealable via le dossier associe, sans revalidation de cette autre ligne dans le CAS. Une reassignment concurrente reste une limite a tester. |
| Couverture du CAS | Une ligne d'une des trois tables, sous reserve que le backend execute reellement le predicat dans l'ecriture et que tous les writers respectent la revision. Aucune transaction dossier + beneficiaire + contexte + documents. |

Exemple d'enveloppe synthetique acceptee pour une modification scalaire d'un dossier prepare :

```json
{
  "status": "apres",
  "expectedUpdatedAt": "2026-09-10T08:00:00.000Z",
  "concurrency": {
    "version": 1,
    "writeId": "11111111-1111-4111-8111-111111111111",
    "baseValues": {"status": "avant"}
  }
}
```

Le `expectedUpdatedAt` reste utile au nouveau client et au mode off ; le serveur conditionnel compare ici les valeurs et sa revision courante. Fournir une baseline fraiche inventee pour un ancien patch detruit la detection d'un changement intervenu depuis la saisie.

### Limites qui subsistent meme avec le writer

1. Un writer ancien peut modifier un champ entre la lecture du coordinateur et le CAS sans changer `app_sync_revision`. Le predicat reste vrai et la modification peut etre ecrasee. Lui ajouter seulement un UUID a chaque ecriture ne protege pas non plus son propre patch obsolete. Il faut que chaque chemin respecte une condition de concurrence, ou qu'il soit exclu du perimetre actif.
2. `planDatabaseMutation` peut rendre un no-op lorsque la valeur desiree egale la baseline et que le distant a change : c'est une conservation du distant, pas une preuve que toutes les valeurs locales ont ete ecrites. `applyConditionalSync` ignore le resultat detaille et les routes renvoient surtout `updatedAt`. Verifier la reconciliation du prochain pull ; ne pas presenter `applied/replay` comme preuve d'une valeur locale identique au serveur pour tous les champs.
3. La confirmation ne porte que sur le patch effectivement ecrit. Les effets secondaires, autres lignes et comparaisons devenues no-op n'appartiennent pas a une transaction commune. Apres reponse perdue, une autre revision peut conduire a un conflit au retry meme si une premiere ecriture avait reussi : conserver le travail et permettre une decision explicite.
4. Le transport evolue dans le lot parent : la version relue accepte certaines `ForeignKey` reliees a un `LinkToAnotherRecord` de type `bt`, avec cible definie et valeur entier positif/null. Il serait desormais faux d'ecrire que toutes les FK sont refusees. Cela ne constitue pas une preuve distante de leurs effets relationnels. Les autres types non supportes restent rejetes.

## Matrice anciens et nouveaux clients

Sources : [routes PATCH actives](</Users/aidhabitat/Downloads/aid'habitat-manager/server/index.mjs:7294>), [dispatch Flutter](</Users/aidhabitat/Downloads/aid'habitat-manager/aid_habitat_app/lib/services/nocodb_sync_service.dart:350>), [client HTTP](</Users/aidhabitat/Downloads/aid'habitat-manager/aid_habitat_app/lib/services/nocodb_api_client.dart:422>), [capture des mutations](</Users/aidhabitat/Downloads/aid'habitat-manager/aid_habitat_app/lib/services/sync_mutation.dart:16>).

| Requete / etat | Flag off | Flag on |
| --- | --- | --- |
| Ancien PATCH beneficiaire existant, sans `concurrency` | Ancien controle timestamp facultatif, puis update inconditionnel. | 428 baseline requise, aucune mise a jour metier du beneficiaire. |
| Ancien PATCH logement existant | Meme controle facultatif. | 428 baseline requise. |
| Ancien PATCH dossier avec au moins un champ dossier reconnu | Ancien controle facultatif. | 428 baseline requise. `temp-*` peut toutefois avoir cree le dossier avant ce rejet. |
| Ancien PATCH contexte/autonomie seuls | Upsert contexte apres controle du timestamp **dossier**. | Meme upsert non conditionnel si pas de `concurrency`. Deux changements de contexte peuvent passer avec le meme timestamp dossier. |
| Ancien PATCH melant dossier et contexte | Deux ecritures successives, sans transaction. | 409 si le timestamp est stale ; sinon 428 sur les champs dossier, avant l'upsert contexte. |
| Nouveau PATCH contexte/autonomie avec `concurrency` | Metadonnees ignorees par le serveur, controle historique applique. | 409 si timestamp stale ; sinon **HTTP 400 `SYNC_MULTITABLE_MUTATION_UNSUPPORTED`**. Meme si le patch ne contient que le contexte. |
| Nouveau PATCH scalaire principal, reference complete | Champs partiels acceptes ; baseline/UUID non utilises, timestamp historique utilise. Pas de fusion automatique serveur. | Possible apres preparation du schema et validation des types/mappers ; 409 si conflit, 503 si non prepare/incertain. |
| Nouveau payload v1 sans timestamp valide | `_expectedVersion` leve un conflit **avant HTTP**, meme avec flag off. | Idem, meme si le serveur pourrait comparer des valeurs sans timestamp. |
| Ancienne operation en file, app nouvellement mise a jour | Pas de baseline/UUID retroactifs sur une operation intacte. Envoi legacy possible. Une nouvelle edition coalescee avec une ancienne operation garde les valeurs inconnues et peut exiger une verification locale. | Operation intacte envoyee sans garde : 428. Une simple mise a jour de l'app ne rend pas toutes les anciennes files compatibles. |
| POST beneficiaire / logement absent | Creation legacy. | Pas d'enveloppe client exigee a la creation ; revision initialisee par serveur, schema requis. Creation non transactionnelle et non garantie exactement une fois. |
| PATCH dossier vide / cles inconnues seulement | Peut retourner succes sans effet. | Peut retourner succes sans appeler `applyConditionalSync` si aucun champ dossier/contexte reconnu. Ce n'est pas un bypass ecrivant une ligne existante. |
| Batch JSON | Status individuel de chaque sous-requete. | Meme rejet individuel que les routes directes. HTTP 200 externe ne signifie pas que tout est applique. |

Sur le client historique de HEAD, `NocodbApiClient.updateDossier/updateBeneficiary/updateLogement` ne classe que 409 en `ConflictException`. Un 428 devient une erreur ordinaire puis `markFailed` dans `NocodbSyncService._processGroup` ; ce n'est pas une invitation de mise a jour exploitable automatiquement. Sur 409, `_autoResolveConflictForceLocal` retente sans timestamp, et `_processGroup` incremente historiquement le compteur de pushes meme si le retry a ete marque en echec par le helper. Cela n'autorise pas a conclure que toutes les anciennes versions installables ont exactement ce comportement, mais suffit a rejeter une bascule transparente non testee.

Le client local courant classe 409 **et 428** en conflit, conserve le payload rejete via `markConflict`, cesse de pousser ce groupe et n'effectue plus de retry force-local. Les 5xx sont classes transitoires par `_runWithTransientGuard`. Le rejet contexte en 400 devient une erreur permanente `markFailed`, pas une fusion ni un conflit resoluble automatiquement. Les references et les conflits sont persistants ; ces protections locales ne rendent pas le serveur legacy atomique.

`DossierRepository.reviewConflicts/resolveReviewedConflict` ne couvre actuellement que patient, housing et dossier : les conflits contexte, sanitaires, mesures, observations ne sont pas automatiquement resolubles par cet ecran. Les valeurs distantes sont verifiees et la decision archivee ; une reference manquante, un champ non relisible ou des IDs locaux/distants non reconciliables bloquent la resolution. Voir [repository](</Users/aidhabitat/Downloads/aid'habitat-manager/aid_habitat_app/lib/services/dossier_repository.dart:53>) et [ecran](</Users/aidhabitat/Downloads/aid'habitat-manager/aid_habitat_app/lib/screens/conflict_resolution_screen.dart:1>).

**Attention au lot concurrent :** `_enqueueChildUpdate` est maintenant present dans `dossier_repository.dart` pour contexte/sanitaires/mesures/observations. Il prepare des baselines locales, mais n'ajoute aucun CAS aux routes enfant. Le processeur contexte transmet cette enveloppe et entre donc dans le rejet ci-dessus avec flag on. Les processeurs mesures/observations/sanitaires lisent encore leurs payloads historiques sans transmettre la garde ; il faut une recette explicite de ces associations producteur/transport. L'integration de ce lot doit etre reverifiee a sa finalisation.

## Inventaire des vraies ecritures

### Trois tables candidates et chemins indirects

Toutes les routes ci-dessous sont dans `server/index.mjs`.

| Route / symbole | Cible et protection reelle sous flag on | Risque / prerequis |
| --- | --- | --- |
| `PATCH /api/beneficiaires/:patientId` (7294), `mapBeneficiaryUpdatesToFields` | CAS de la ligne beneficiaire via `applyConditionalSync`. Ensuite `getDossiersForApp`, synchronisation des metadonnees de notes, resync des noms `mobile_*`. | Pas de transaction avec ces effets secondaires. Une erreur apres le CAS peut faire echouer la reponse alors que la ligne principale est deja ecrite. Resync de noms en REST direct dans `server/resyncLegacyNames.mjs`. |
| `PATCH /api/dossiers/:dossierId` (7400) | CAS seulement des colonnes dossier reconnues. Contexte traite a part, voir matrice. | Le contexte n'est pas protege par la revision dossier. Guard absent n'interdit pas la branche contexte seule. |
| `PATCH /api/logements/by-beneficiary/:beneficiaryId` (7475) | CAS si logement trouve ; sinon `createRecord` avec revision initiale, sans baseline client. | Deux lecteurs ne trouvant pas de logement peuvent en creer deux. `latestRecord` n'est pas une contrainte d'unicite. Les liens beneficiaire sont dans le mapper meme pour certains patches partiels. |
| `POST /api/beneficiaires` (7173) | Creation beneficiaire, puis initialisation des relations via writer conditionnel, puis creation dossier. | Trois etapes sans rollback global. `clientLocalId` dedoublonne par une lecture de dossier prealable ; deux requetes simultanees, panne avant creation dossier, ou echec de cette lecture (catch puis continuation) peuvent laisser doublons/orphelins. Les UUID de creation/liens ne sont pas une intention durable commune. |
| `GET /api/dossiers` (5574) -> `getDossiersForApp` (3712) | Cree les dossiers absents via `ensureDossiersForBeneficiaries`; backfill des attributions via CAS; liens contexte/admin via updates ordinaires. | Une lecture ecrit, avant filtrage final des scopes. Un vieux dossier avec attribution vide/`E1`/`user` et revision non preparee peut faire echouer le pull. Sans nouvelle creation ni backfill necessaire, la lecture peut encore marcher : ne pas affirmer que tout GET est toujours casse. |
| `ensureDossierRecord` (3908), IDs `temp-*` | Cree un dossier si absent, avant le controle d'acces effectue par plusieurs handlers appelants. | Creation potentielle meme si l'action suivante refuse la requete. Concurrence sur le meme patient et phase de preparation a traiter. Appele par PATCH dossier, GET/PUT plans, PUT sanitaires/mesures/observations, GET/PUT preconisations. |
| `backfillLegacyDossierAssignments` (3620) | CAS et baseline issus de la lecture precedente ; 409 saute, autres erreurs remontent. | Ce chemin est raccorde : **ne pas le lister comme update inconditionnel avec flag on**. Pas d'autorisation par utilisateur dans le backfill global. UUID genere par tentative, pas journal de migration durable. |
| `backfillChildDossierLinks` (2191) | Appels directs `callNocoTool('updateRecords')` sur contexte de vie et informations administratives. | Chemin reel non conditionnel ; il n'est pas appele avec `TABLES.logements` dans `getDossiersForApp`. Eviter de lui attribuer un bypass logement inexistant. |

Deux garde-fous existent : [updateRecord/createRecord](</Users/aidhabitat/Downloads/aid'habitat-manager/server/index.mjs:2576>) et [callNocoTool](</Users/aidhabitat/Downloads/aid'habitat-manager/server/nocodbMcpClient.mjs:367>). Le premier refuse les updates legacy des trois tables ; le second refuse leurs `updateRecords` et les `createRecords` sans UUID de revision, avant transport MCP/REST. Une route qui rencontre cette interdiction est **bloquee**, pas une ecriture silencieusement non protegee.

Le garde-fou `callNocoTool` ne refuse pas `deleteRecords`. Aucune route DELETE beneficiaire/dossier/logement n'est enregistree dans l'entree active : c'est une lacune du perimetre transport/futurs outils, pas la preuve d'un endpoint DELETE metier deja expose. Il ne controle pas un autre processus, une edition NocoDB, du REST direct ou un script externe. L'information historique "seule l'app iPad ecrit" ne dispense pas de couvrir ses propres routes indirectes, anciennes versions et requetes en vol.

### Saisies encore hors CAS

| Routes actives | Persistance | Controle actuel et risque concret |
| --- | --- | --- |
| `PATCH /api/dossiers/:dossierId`, contexte/autonomie | `upsertContexte` (3953), `TABLES.contexteDeVie` | Timestamp de la ligne dossier, facultatif, puis update/create contexte inconditionnel. Deux iPad peuvent remplacer le meme contexte sans modifier le timestamp dossier. JSON occupants medical/autonomie remplace comme ensemble. |
| `PUT /api/diagnostic-sanitaires/:dossierId` (8591) | `TABLES.diagnosticSanitaires` | `sendConflictIfStale` seulement si ligne existante ; valeurs salle de bain/WC et JSON remplaces. Flutter n'envoie pas de timestamp ici. Sans condition atomique ; creation concurrente possible. |
| `PUT /api/mesures/:dossierId` (8690) | `TABLES.mesuresAnthropometriques` | Meme garde timestamp facultative ; Flutter pousse `updates` sans garde de concurrence. Champs presents remplaces, sans CAS. |
| `PUT /api/observations/:dossierId` (8752) | `TABLES.observations` | Meme garde facultative ; Flutter ne transmet pas de version. Une ancienne saisie peut ecraser les champs presents. |
| `PUT /api/visit-recommendations/:dossierId` (8843) | `persistVisitRecommendationsInNocodb` (2674), sinon store JSON local serveur | Diff de liste : updates, creations, puis suppressions des IDs absents. Pas de version/transaction de collection. Une ancienne liste peut supprimer des ajouts d'un autre iPad. Appelle aussi `loadWikiLibrary`, qui peut ecrire. |
| `POST /api/documents/upload` (7705), `POST /api/documents` (7775), `POST /api/documents/upload/finalize` (7946) | `mobileSyncStore.upsertDocument`, `mobile_documents` et `mobile_document_chunks`, ou adapter local | Remplacement par cle client, UUID de contenu changeant, preparation des chunks puis publication. Aucune revision attendue client ; deux remplacements peuvent se depasser. URL versionnee/cache frais ne signifie pas CAS. |
| `POST /api/documents/upload/chunk` (7884) | `storage.mjs`, fragments en memoire scopes par proprietaire/upload | Protection d'appartenance, pas condition sur le document final. Le finalize ci-dessus est l'ecriture metier. |
| `PATCH /api/documents/:documentId` (8069) | `mobileSyncStore.updateDocument` | Titre/tags modifies sans version attendue. |
| `DELETE /api/documents/:documentId` (8101) | `mobileSyncStore.deleteDocument`, chunks associes | Suppression sans revision/tombstone de concurrence. |
| `PUT /api/note-pages` (8242), `POST /api/note-pages` (8331), `DELETE /api/note-pages/:notePageId` (8387) | `mobileSyncStore.upsertNotePage/createNotePage/deleteNotePage` | Controles patient/scope mais aucune version attendue. Texte, dessin, preview, phase peuvent etre remplaces ; allocation de page et suppression sans CAS. |
| `PUT /api/visit-plans/:dossierId` (8444) | `upsertDocument`, ID client stable `plan_logement_<dossierId>` | Remplacement de plan sans baseline ; meme risque que les documents. |
| `POST /api/reports/visit/:dossierId` (6833) | Lectures multiples, `upsertDocument` du rapport, `deleteObsoleteReportDocuments` | Aucun snapshot transactionnel des donnees du rapport. Deux generations peuvent se remplacer. En plus, si au moins une photo inline est presente, les documents distants absents de cet ensemble sont supprimes en arriere-plan. Un ancien iPad avec liste incomplete peut supprimer des photos plus recentes. |

Sources des stores : [mobileSyncStore wrappers](</Users/aidhabitat/Downloads/aid'habitat-manager/server/mobileSyncStore.mjs:403>), [upsertDocument NocoDB](</Users/aidhabitat/Downloads/aid'habitat-manager/server/mobileSyncStore.mjs:1243>), [upsertNotePage NocoDB](</Users/aidhabitat/Downloads/aid'habitat-manager/server/mobileSyncStore.mjs:1633>), [rapport et cleanup inline](</Users/aidhabitat/Downloads/aid'habitat-manager/server/index.mjs:6958>). Les sauvegardes/revisions locales Flutter ne protegent pas ces ecritures inter-appareils cote serveur.

### Autres ecritures actives a ne pas oublier

| Surface | Ecritures hors protocole F05 |
| --- | --- |
| `POST /api/profile/photo` (4457) | Store auth et profil ergotherapeute/photo NocoDB. |
| `POST /api/auth/provision` (4590), `POST/PATCH/DELETE /api/admin/access-members[/... ]` (4654/4714/4740), `POST .../:email/revoke-sessions` (4776) | Credentials/store auth, ergotherapeutes, versions de session. Controles admin, pas CAS metier. |
| `POST /api/auth/login`, `POST /api/auth/refresh`, lectures session/local-state/admin et warmup | Chargement/normalisation du registre pouvant persister le store et assurer des lignes/profils via `loadMemberRegistry`, `ensureErgoRecordForMember`. `POST /api/auth/logout` renvoie seulement succes dans ce handler. |
| `POST /api/retirement-funds-principal` (5048), `POST /api/retirement-funds` (5319), `PUT /api/retirement-funds/:fundId` (5399) | Caisses principales/complementaires, metadonnees et store local ; pas de revision attendue. |
| `POST /api/wiki-library` (5120), `PUT/DELETE /api/wiki-library/:itemId` (5207/5287) | Store JSON, wiki et tags NocoDB. Les erreurs NocoDB peuvent etre traitees best-effort apres mise a jour locale. |
| `GET /api/wiki-library` et tout appel de `loadWikiLibrary` (2105) | `syncLocalWikiStoreToNocodb` importe/met a jour, supprime les wiki absents du store local, nettoie les tags. Une lecture peut donc modifier/supprimer des lignes ; idem appel depuis les preconisations. |
| `POST /api/mobile-sync/migrate` (5562) | `migrateLocalToNocodb` importe documents et notes via les upserts non conditionnels. **Ne prepare pas** `app_sync_revision` sur les trois tables. |
| `POST /api/ai/rewrite` | Route montee, appel de reformulation ; pas de write de dossier dans le handler. Middleware auth pouvant charger le registre. |
| `POST /api/feedback` | Envoi de signalement et journal de livraison, hors synchronisation dossier. Voir `server/routes/feedback.mjs` ; le POST utilise une session optionnelle. Les `GET /api/feedback/mail-events` et `GET .../:feedbackId` lisent le journal ; ils ne sont pas des ecritures metier. |
| Scripts de maintenance/import/resync, editions directes NocoDB, anciennes instances | Writers potentiels hors de cette entree ; presence d'un script ne prouve pas son execution. Les inventorier et les suspendre/raccorder avant activation, y compris REST direct et suppressions. Aucun n'a ete execute ici. |

Les GET documents/contenu/notes, schemas, health, references et lectures de diagnostics ne constituent pas en eux-memes des CAS. Certains passent par initialisation de stores/registre ; les backfills metier certains sont listes ci-dessus. Aucun endpoint generique permettant au client de soumettre un `tableId` arbitraire n'a ete identifie dans l'entree active.

### Batch : transport uniquement

[server/syncBatch.mjs](</Users/aidhabitat/Downloads/aid'habitat-manager/server/syncBatch.mjs:1>) autorise exactement les PATCH dossier/beneficiaire/logement et PUT mesures/observations/sanitaires. Trois operations maximum par lot, execution sequentielle, deux lots simultanes via la gate en memoire. Chaque operation est redispatchee par HTTP a sa route avec le token. Le lot peut meler 200, 428 et 503 et continuer apres un echec. Ni la gate, ni le batch, ni le traitement sequentiel Flutter ne sont un verrou inter-instances ou une transaction. L'ID de sous-operation sert a associer la reponse ; il ne remplace pas `concurrency.writeId`.

## Blocages release verifiables

| Priorite | Constat / preuve | Condition de fermeture |
| --- | --- | --- |
| P1 bascule | Ancien PATCH principal refuse en 428 ; ancien client HEAD le traite en echec ordinaire. Tests isoles 1 et 2. | Parc et files historiques migres/traites, avec reprise preservee. Pas d'activation globale pendant coexistence non geree. |
| P1 bascule | Contexte legacy passe sans CAS ; contexte avec garde refuse en 400. Tests 3 a 5. | Definir et implementer le contrat de la ligne contexte, y compris anciennes operations ; recette nouveau producteur `_enqueueChildUpdate` avec le transport. |
| P2 erreurs | Le parent a ajoute `SyncMutationError.statusCode` pendant l'audit : les statuts 400/428/503 sont maintenant preserves par le middleware, test 6. `ConditionalWriteUncertainError` hors `applyConditionalSync` reste sans statusCode, donc 500 generique. | Conserver le correctif du parent et verifier les classifications restantes, notamment creations/liens et backfills. Les `SyncMutationError` 503 hors helper gardent le statut, mais leur code est masque par le message generique du middleware. |
| P1 bascule | Schemas/revisions de toutes les lignes non prouves ici. Health ready ne fait qu'une lecture beneficiaire ; les endpoints mobile schema concernent les tables mobiles. | Preflight specifique aux trois tables, base/Id/type, revisions valides et couverture complete des writers. Un health 200 ne vaut pas readiness F05. |
| P1 bascule | Mapper `invalidityTxt` -> colonne `reconnaissance_invalidit\u00e9_mdph_txt` (nom avec e accent aigu) ; `identifier` du writer n'accepte que ASCII. | Tester cette vraie cle de mapper et adapter le contrat de noms sans contourner les gardes. Dans la version lue, un changement effectif sur cette colonne provoque TypeError avant envoi, puis 500. |
| P1 perimetre | Notes/documents/plans/preconisations/sanitaires/mesures/observations et creations restent hors CAS ou sans transaction d'ensemble. | Couverture serveur et UI des conflits/suppressions/idempotence, ou exclusion explicite du perimetre revendique. F05 global ne peut pas etre ferme en protegeant trois PATCH seulement. |
| P1 livraison locale | Nouveaux conflits conserves mais resolution limitee aux trois entites ; timestamp absent peut bloquer avant HTTP meme flag off. `_enqueueChildUpdate` evolue. | Recette ancienne file, premiere saisie enfant, dossiers crees offline, conflit historique et reprise apres upgrade. Ne pas livrer automatiquement tout le worktree parce que le flag est off. |
| P1 reprise locale | [LocalDatabase._openEncrypted](</Users/aidhabitat/Downloads/aid'habitat-manager/aid_habitat_app/lib/services/local_database.dart:271>) intercepte toute erreur d'ouverture/migration, tente backup/recreation ; echec du backup peut aboutir a suppression. | Valider migration SQLite 21 -> 22, WAL/SHM, cle de coffre et preservation des saisies non poussees sur corpus synthetique avant upgrade du parc. Le backup n'est pas une preuve de reprise automatique. |
| P2 mappers | Colonnes derivees (occupants/noms, commune/code postal, bareme), relations, Dates/Checkbox/JSON ; mapping baseline via references actuelles et champs parfois omis. | Fixtures representatives et allers-retours UI -> SQLite -> API -> DB -> API. Ne pas clore sur un simple champ `status`. Integrer les tests du parent sur valeurs scalaires et FK. |
| P2 autorisation | Create `temp-*` precedant certains controles, filtre final apres backfills globaux ; beneficiaire/logement sans recontrole de la ligne d'acces au CAS. | Tests routes authentifiees, reassignment concurrente, mauvais scopes et absence d'effets de bord sur requete refusee. |

`sendConflictIfStale` ([source](</Users/aidhabitat/Downloads/aid'habitat-manager/server/index.mjs:878>)) est facultatif : absence de timestamp, timestamp non parseable ou absence de date distante laissent passer. Il compare `remoteTime > expectedTime` avant une ecriture ordinaire ; une date future peut passer et deux requetes ayant lu la meme date peuvent gagner. `getRecordUpdatedAt` privilegie `updated_at` avant `UpdatedAt`, tandis que `createDossier.updatedAt` prend l'ordre inverse : verifier aussi le schema reel de dates et les acquittements, sans utiliser l'horloge iPad comme autorite. Ces limites existent en mode off, meme apres retrait du force-local sur les nouveaux appareils.

## Livraison locale avec flag off

**Oui, c'est techniquement possible et c'est la recommandation de compatibilite actuelle.** Les mappers serveur historiques ignorent `concurrency` quand le flag est off. Le test 7 montre un PATCH v1 accepte sur le chemin legacy, et le test 8 montre que le timestamp historique peut encore le refuser. Pas besoin de colonne `app_sync_revision` pour ce mode.

1. Finaliser un lot coherent de corrections locales : persistence/operations/acquittements/documents, preservation pendant pull, retrait du force-local et conflits durables. Conserver les dependances et migration SQLite necessaires ; decider explicitement du lot enfant encore en cours. Aucun de ces choix n'est applique par cette sous-tache.
2. Recetter ce lot avec serveur off et avec des anciennes files synthetiques. Verifier conflits visibles, choix utilisateur, erreurs reseau, redemarrage, premiere saisie, absence de timestamp, creation offline puis modifications avant premier pull. Une conservation sans possibilite de resolution est une limite de livraison, pas un succes de synchronisation.
3. Conserver le flag absent/`0` sur **toutes** les instances. Le flag est lu au demarrage ; il n'est pas un interrupteur HTTP a chaud. Les imports serveur sont effectues meme off : tous les nouveaux modules importes doivent accompagner une future livraison serveur, notamment `dossierReadQueries`, `guardedMutation`, `nocodbConditionalWrite`, `nocodbScalarValues` et leurs dependances. Le flag n'excuse pas un artefact incomplet.
4. Ne pas preparer/migrer la base distante pour ce seul lot local. Les changements transport du parent actifs hors flag, notamment reprise/timeout MCP/REST, demandent leur propre validation ; ils ne sont pas des protections CAS.
5. Formulation release : "corrections de sauvegarde locale, d'acquittement et de conservation des conflits ; protection conditionnelle serveur non activee ; F05 reste ouvert, protection inter-appareils incomplete". Ni "zero perte", ni "fusion atomique du dossier", ni "F05 termine".

Le mode off permet la coexistence technique des anciens et nouveaux clients, mais un ancien client peut encore ecraser une saisie via le protocole legacy. La gestion operationnelle des editions concurrentes reste donc necessaire pendant cette transition. Les nouvelles protections locales ne corrigent pas retroactivement les anciennes installations.

## Bascule future sans casser les anciens clients

Avec le code actuel, **maintenir des anciens clients pleinement capables d'ecrire les memes lignes tout en imposant les gardes v1 est impossible** : l'ancienne requete ne contient pas sa baseline. Aucun adaptateur ne peut la reconstruire fidelement depuis la seule valeur distante du moment.

Sequence recommandee, a realiser dans un travail de release ulterieur autorise :

1. Conserver off pendant l'inventaire des appareils, OS, numero de build, SHA/artifact, versions PWA en cache, profils et files pending/running/failed/conflict. Identifier les appareils hors ligne et les clients non iPad potentiels. Ne pas deduire la disparition d'un ancien writer de son silence reseau.
2. Livrer puis valider la version de transition compatible off, avec traitement explicite des baselines inconnues. Preserver les anciennes operations et leurs fichiers/coffres ; ne pas vider la file, desinstaller l'app ou fabriquer des valeurs de reference pour accelerer la migration. Une resynchronisation legacy avant bascule n'est pas une fusion sure : examiner les vrais conflits.
3. Definir une migration/negociation de capacites et un traitement des anciennes versions. Si un appareil ne peut etre migre, maintenir son perimetre en legacy et ne pas y revendiquer le CAS, ou organiser un mode lecture seule et une reprise accompagnee de ses saisies. Un 428 brut n'est pas un parcours de migration acceptable. Un routage par version vers deux backends ecrivant les memes lignes n'isole pas la concurrence.
4. Sur environnement jetable et donnees synthetiques, prouver le vrai predicat NocoDB : deux connexions/processus, un seul gagnant sur le meme champ, preservation des champs independants, ligne sentinelle intacte, refus de revision stale, timeout/reponse perdue/apres-ecriture, pas de fallback, FK et types des mappers reels. La preuve sur une table scalaire fictive ne suffit pas aux relations des tables metier.
5. Apres sauvegarde/restauration verifiee et autorisation release distincte, preparer colonnes et revisions de toutes les lignes cibles. Geler/drainer les writers legacy, requetes batch/directes, backfills, taches de rapport et outils. Eviter toute ancienne instance encore en vol ; une file vide sur un seul iPad ne le prouve pas.
6. Activer seulement lorsque parc compatible, anciennes intentions resolues, types/mappers/erreurs valides et couverture des chemins exigee obtenue. Canari sur un perimetre d'ecriture reellement isole, puis bascule coherente des instances. Le flag actuel n'offre pas lui-meme de canari par appareil/table/tenant.
7. Surveiller codes 409/428/503/500, operations non acquittees, conflits sans resolution, doublons de creation et erreurs de pull/backfill. Conserver les UUID au retry et les traces de decisions sans exposer de donnees de dossier.

Retour arriere : repasser off rend les anciens PATCH possibles mais **retire la garantie conditionnelle** ; les nouvelles ecritures legacy ne maintiennent plus les revisions. Apres ce retour, une reactivation exige de nouveau exclusion/drainage et controle des revisions/references. Ne pas supprimer colonnes, historique SQLite ou fichiers pour revenir en arriere. Un ancien binaire ouvrant une base locale migree doit aussi avoir un scenario de rollback valide. Aucune de ces operations n'est executee ici.

## Validation effectuee et restante

Ajout de [server/syncReleaseReadiness.test.mjs](</Users/aidhabitat/Downloads/aid'habitat-manager/server/syncReleaseReadiness.test.mjs:1>), **9 tests reussis** : ancien PATCH refuse, UUID absent refuse, contexte sans garde accepte deux fois avec meme date dossier, ancien patch mixte bloque, contexte garde refuse en 400, preservation des statuts par le middleware, nouveau payload accepte off, rejet stale off, passage scalaire conditionnel prepare.

Ces tests lisent le source de `index.mjs` et executent des fragments exacts dans un harness a dependances injectees. Ils n'importent pas l'entree complete (qui appelle `warmupRuntime` meme a l'import), ne lancent ni Express ni reseau, n'ouvrent aucune base, et emploient exclusivement des identites synthetiques. Ils **caracterisent des blocages existants** et couvrent le correctif concurrent de propagation des statuts ; leur succes ne signifie pas que tous les blocages sont corriges. Les ajuster lors de la correction des modules de production. Le writer du test de route est simule ; aucune preuve de CAS NocoDB n'est fournie par ce fichier.

Commande locale isolee :

```sh
node --test server/syncReleaseReadiness.test.mjs
```

Restent a faire pour release : tests de routes reelles authentifiees et batch/direct avec versions ancienne et nouvelle, finalisation des suites du parent/autre agent, migration SQLite sur copie synthetique, recette iPad physique de reprise et de conflits, et preuves de backend sur environnement jetable autorise. Aucun resultat Flutter, build iOS, schema distant ni test de production n'est revendique par cette sous-tache.

### Empreintes de lecture

Dernier releve local : `2026-09-10T10:24:44Z` (12:24 Europe/Paris). Empreintes SHA-256, relatives a la racine du workspace. Une modification ulterieure de ces fichiers appelle une verification ciblee des conclusions, pas une validation implicite de la nouvelle version.

```text
c278bd51338a7f346145fd5868c3b622228cd2545baa5e5a050baa19e72ecab7  server/index.mjs
18e948b56d8b4211a0ecf5e04f78ce3ea47ee1f39228d8a6c438ab0905d35be2  server/guardedMutation.mjs
fb2ddac747a2b67922cbed04d381bdf8a671cecd40b71701cce7b38185acfe0c  server/nocodbConditionalWrite.mjs
34722219587114e138e643e5401b4cb95814432ea6f12b9943fb9bb83881eb9b  aid_habitat_app/lib/services/nocodb_sync_service.dart
c80f849a42ed00747c89e9bd165d3fd9b9d8e19c37a8e5c2cc023123fcb90309  aid_habitat_app/lib/services/dossier_repository.dart
```

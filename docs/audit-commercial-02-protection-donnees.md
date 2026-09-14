# Audit commercial 02 - Protection des donnees App'Ergo iPad/web

Date de l'audit : 14 septembre 2026  
Perimetre : donnees, flux, stockage local, hors connexion, revocation offline, exploitation, sauvegarde, suppression, incidents et prestataires.  
Hors perimetre : conception des autorisations API et interpretation Apple/RGPD/HDS.

## 1. Methode et niveau de preuve

Audit statique du depot local uniquement. Aucun acces a une console, un secret, une sauvegarde, un dossier reel, Airtable ou un service de production. Aucun test de conformite juridique ou HDS n'est formule.

Legende :

- **Verifie dans le code** : comportement directement visible dans le code ou reproduit par un test synthetique local.
- **Documente, non verifie** : affirmation ou procedure presente dans les documents du depot, sans preuve d'exploitation controlee ici.
- **Information manquante** : element absent du depot ou qui exige un justificatif externe.

Tests synthetiques executes :

```text
TMPDIR=<repertoire isole> bash tool/test_safely.sh \
  test/services/agent3_sync_operation_ownership_test.dart \
  test/services/sync_session_scope_test.dart \
  test/services/offline_persistence_test.dart
Resultat : 24 tests passes, 0 echec.
```

Ces tests prouvent des contrats logiciels simules, pas le chiffrement effectif d'un appareil, la configuration EasyPanel/NocoDB, une restauration reelle ni les garanties d'un prestataire.

## 2. Synthese de decision

**Conclusion technique : non prete en l'etat pour plusieurs entreprises partageant un meme parc ou une meme origine web.** Le chiffrement local natif est une bonne base et la file offline preserve les saisies. En revanche, `organisation_id` est surtout preparatoire : les lectures locales principales ne l'utilisent pas comme frontiere. Une deconnexion conserve volontairement toutes les donnees. Un autre compte utilisant le meme profil navigateur ou iPad peut donc retrouver des donnees mises en cache si la couche d'autorisation d'interface les expose.

Priorites avant pilote multi-entreprises :

1. **P0 - Isolation locale par organisation et utilisateur**, sans suppression de file : partition de base/coffre et caches, puis quarantaine des operations sans proprietaire certain.
2. **P0 - Politique de changement de compte et de sortie d'entreprise** : bloquer l'ouverture d'un autre tenant tant que les donnees du tenant precedent ne sont pas verrouillees ; ne jamais reattribuer ni supprimer automatiquement une file.
3. **P0 - Gouvernance d'hebergement et restauration prouvee** : inventaire des copies, sauvegardes chiffrees, tests de restauration, RPO/RTO, suppression et journal d'incident.
4. **P1 - Reduire les copies secondaires** : rapports PDF, pieces jointes, caches, fichiers temporaires, feedback JSONL/e-mail et logs.
5. **P1 - Politique explicite de revocation offline** : duree maximale hors ligne, reauthentification locale, verrouillage appareil et effacement admin au prochain contact, sans promesse d'instantaneite.

## 3. Cartographie des donnees et flux

| Donnees | Source et copies | Flux sortant / destinataire | Preuve | Etat |
|---|---|---|---|---|
| Dossiers, identite, coordonnees, adresse, entourage, revenus | SQLite local `patients`, `housings`, `dossiers`; NocoDB distant | App -> API EasyPanel -> NocoDB; pull inverse | `local_database.dart:1185-1217`, `1222-1280`, `1285-1307`; `Dockerfile.api:13-24` | Verifie dans le code pour le flux; exploitation non verifiee |
| Sante et autonomie | `patients` (APA, invalidite, aide, dependance), `dossiers.medical_context_json`, tables contexte/mesures/sanitaires | File locale -> API -> NocoDB; parfois generation PDF | `local_database.dart:1203-1211`, `1300-1301`, `1041-1110` | Verifie dans le code |
| Notes ecrites et dessins/plans | `note_pages`, payload chiffre dans `sync_operations`, NocoDB | App -> API; plans inline lors d'un rapport | `local_database.dart:1335-1368`; `note_repository.dart:91-180` | Verifie dans le code |
| Photos et documents | Fichier sandbox iPad ou data URL web, ligne `documents`, cache media, chunks NocoDB | Multipart app -> API -> NocoDB; relecture API/cache | `document_repository.dart:153-248`, `293-360`; `storage.mjs:1-33` | Verifie dans le code |
| Rapports PDF | Genere cote API depuis donnees et pieces inline, puis conserve comme document; copie locale native/web possible | App -> API (donnees + images) -> generateur PDF -> NocoDB -> app/export | `nocodb_api_client.dart:1407-1581`; `document_repository.dart:306-360` | Verifie dans le code |
| Signalements | Message, nom/email utilisateur, page, nom/ID dossier, section, action, URL, user-agent, date et hash IP | App -> API -> volume JSONL + SMTP/e-mail | `feedback_service.dart:15-56`; `feedback.mjs:123-213`, `410-550` | Verifie dans le code |
| Reformulation IA | Note potentiellement medicale; iPad Apple Intelligence local ou API -> Ollama configure | iPad local, ou App -> API -> endpoint Ollama | `ai_rewrite_service.dart:23-130`; `server/ai/rewrite.mjs:1-37`, `159-187` | Code verifie; emplacement et exploitation Ollama manquants |
| Portail ANAH | Navigation WebView vers domaines ANAH, contenu et console WebView | iPad -> ANAH | `anah_screen.dart:900-926` | Verifie dans le code; donnees effectivement saisies/transmises non inventoriees |
| Logs techniques | Console Flutter, stdout/stderr API, logs Docker/EasyPanel probables | Appareil/navigateur et plateforme d'hebergement | `main.dart:45-74`, `476-499`; `index.mjs:9000-9057` | Code verifie; collecte/retention externe manquante |
| E-mail SMTP | Copie integrale du signalement et contexte | API -> serveur SMTP -> boite destinataire et sauvegardes mail | `feedback.mjs:326-358`, `448-498` | Verifie dans le code; fournisseur, localisation et retention manquants |

Dependances sans telemetrie applicative trouvee : aucune integration Sentry, Firebase Analytics, Crashlytics, Datadog, Segment, PostHog, Mixpanel ou Amplitude n'apparait dans `package.json`, `pubspec.yaml`, `server/` ou `lib/`. Cette absence statique ne couvre pas les logs d'infrastructure, SDK transitifs, navigateur, MDM ou reverse proxy.

## 4. Stockage iPad et navigateur

### 4.1 iPad natif

**Verifie dans le code**

- La base `aid_habitat_offline.db` est ouverte avec SQLCipher et une cle aleatoire de 32 octets (`local_database.dart:33-55`, `324-338`; `secure_session_storage.dart:158-191`).
- Cle SQLCipher, jeton d'acces et refresh token sont places dans Keychain avec `unlocked_this_device` (`secure_session_storage.dart:26-59`, `92-136`). La cle n'est pas effacee lors d'une deconnexion.
- Les documents natifs sont copies dans `Application Documents/offline_documents/<patient>/<document>` (`document_repository.dart:31-53`, `345-360`).
- La protection iOS `FileProtectionType.complete` est appliquee via un canal natif (`native_file_protection.dart:22-41`; `AppDelegate.swift:197-224`). Cette operation est toutefois **best effort** : les exceptions sont ignorees et ne bloquent pas l'ecriture (`native_file_protection.dart:30-41`).
- Le cache media natif est dans `Application Documents/media_cache`, protege et exclu de sauvegarde (`media_cache_service.dart:37-50`).
- Les documents metier ne sont pas explicitement exclus de sauvegarde par defaut (`native_file_protection.dart:61-94`; appels de `document_repository.dart`). Ils peuvent donc entrer dans une sauvegarde iPad selon la configuration OS/MDM.
- Les PDF temporaires de rotation utilisent le repertoire temporaire et recoivent `FileProtectionType.complete`, mais aucune suppression immediate explicite n'est faite apres consommation (`AppDelegate.swift:140-156`).

**Information manquante**

- Test sur un vrai iPad verrouille confirmant classe de protection de la DB, WAL/SHM, documents, miniatures, PDF temporaires et sidecars.
- Configuration iCloud Backup/Finder backup/MDM, politique d'effacement a distance, code appareil, delai de verrouillage et statut des appareils jailbreakes.
- Inventaire des fichiers abandonnes apres import, export, partage, rotation, crash ou mise a jour TestFlight.

### 4.2 Web/PWA

**Verifie dans le code**

- SQLite WASM est persiste dans IndexedDB sans SQLCipher (`local_database.dart:75-86`; `main.dart:77-80`).
- Certains gros champs sont chiffres par AES-GCM : contenus de documents, annotations, notes, dessins, payloads de file, images wiki/profil, mots de passe en attente et cache media (`local_database.dart:158-232`; `offline_vault_web.dart:11-99`).
- Les donnees structurees de patients, dossiers, logement, sante, metadonnees et identifiants restent lisibles dans la base web. Le chiffrement applicatif ne couvre donc pas l'ensemble des donnees sensibles (`local_database.dart:1185-1307`).
- La cle du coffre web est obtenue via `flutter_secure_storage` dans la meme origine (`offline_vault_web.dart:80-98`; `secure_session_storage.dart:49-59`). Une execution JavaScript hostile dans cette origine peut appeler les memes APIs et exfiltrer cle et donnees dechiffrees : ce mecanisme protege surtout une copie brute du stockage, pas une compromission XSS/origine.
- Le cache media ignore les headers d'authentification dans sa cle et reste lisible offline independamment de la fraicheur du jeton (`media_cache_service.dart:67-75`, `253-267`).

**Information manquante**

- Test navigateur de la structure IndexedDB reelle, de la migration des anciennes valeurs en clair et du comportement apres suppression des donnees du site.
- Politique de profils navigateur partages, extensions autorisees, CSP effective, service worker/cache HTTP, postes administres et effacement distant.

## 5. Mode hors connexion, comptes et entreprises

### ECART P0-01 - `organisation_id` n'est pas une frontiere locale appliquee

- **Preuve** : la migration ajoute `organisation_id` avec valeur par defaut `org_aidhabitat` a de nombreuses tables et dit explicitement qu'elle ne change pas les filtres (`local_database.dart:466-496`). La lecture principale joint tous les dossiers/patients/logements sans filtre d'organisation (`dossier_repository.dart:726-833`). Les lectures documents filtrent seulement `patient_local_id` (`document_repository.dart:137-150`). Les usages de `organisation_id` dans `lib/` sont principalement schema et utilisateurs, pas les requetes metier.
- **Consequence** : deux entreprises dans le meme stockage local ne sont pas isolees. Une erreur UI, un identifiant local reutilise ou un changement de compte peut exposer les donnees d'un autre tenant.
- **Recommandation** : utiliser une base et une cle distinctes par `organisation_id` (solution preferee), ou imposer `organisation_id` dans toutes les cles, jointures, contraintes et requetes. Associer egalement fichiers et caches a un namespace tenant non devinable. Refuser fail-closed toute session sans tenant certain.
- **Test d'acceptation** : avec deux entreprises synthetiques A/B dans le meme appareil, chaque ecran, recherche, cache, fichier, PDF, note et file ne retourne que son tenant; manipuler un ID de B sous A doit echouer; une requete sans tenant doit echouer.

### ECART P0-02 - Deconnexion sans verrouillage des donnees du compte precedent

- **Preuve** : `signOut()` arrete le moteur et efface uniquement session/tokens; il conserve explicitement dossiers et `sync_operations` (`auth_service.dart:849-910`). Le commentaire UI affirmant que la deconnexion purge le cache est contradictoire (`account_dialog.dart:398-403`).
- **Consequence** : un compte suivant reutilise le meme coffre global. Meme si la propriete de file bloque des envois, les donnees deja synchronisees restent localement presentes et potentiellement visibles.
- **Recommandation** : a la deconnexion, fermer et verrouiller le coffre du tenant; ne pas effacer la file. Au changement de tenant, monter un autre coffre. Si l'identite d'operations historiques est incertaine, les mettre en quarantaine avec revue explicite, jamais les reattribuer.
- **Test d'acceptation** : A cree hors ligne puis se deconnecte; B ne voit aucun contenu A et ne peut envoyer aucune operation A; retour A restaure exactement la file. Un crash a chaque etape ne perd ni ne reattribue le payload.

### Controle positif - Propriete et survie de la file

- **Preuve code/test** : `sync_operation_ownership` conserve proprietaire, candidat et etat d'attribution (`sync_operation_ownership.dart:54-108`, `310-475`). Les 24 tests synthetiques executes confirment : historique non attribue non reclame automatiquement, envoi filtre par proprietaire actif, reponse apres logout ignoree, ancienne operation n'adopte pas le prochain token, gros payload conserve apres redemarrage.
- **Limite** : ce controle protege l'envoi, pas la lecture des tables metier ni des fichiers partages dans le meme coffre.

### Conservation des modifications non synchronisees

- **Preuve** : le moteur envoie la file avant le pull, conserve `pending` a l'arret et retente au redemarrage (`sync_engine.dart:150-185`). La documentation de stabilite affirme une reprise indefinie et push-before-pull (`data-sync-stability.md:57-92`).
- **Recommandation** : afficher par tenant le nombre d'operations en attente avant logout/changement; permettre export chiffre de secours et revue admin; ne proposer aucun bouton de remise a zero tant que la file n'est pas vide ou exportee et verifiee.
- **Test d'acceptation** : panne, fermeture forcee, expiration de session et changement de compte ne suppriment aucune operation; seule une confirmation distante verifiee permet sa purge.

## 6. Revocation d'un appareil hors connexion

### Limite reelle

Une revocation serveur ne peut pas atteindre un appareil sans reseau. Le code conserve une session locale et les donnees lorsque la validation distante est `unreachable`; une revocation detectee retire le jeton distant mais conserve les saisies (`auth_service.dart:804-896`). C'est coherent avec l'offline-first, mais cela signifie que l'utilisateur peut continuer a lire les donnees deja presentes tant que le coffre local est deverrouillable.

### Politique technique a definir

- Duree maximale offline par classe de risque, calculee depuis une attestation serveur signee et monotone; apres echeance, verrouillage de lecture sans effacer la file.
- Reauthentification locale reguliere avec biometrie/code appareil et protection contre le recul d'horloge.
- Registre d'appareils avec identifiant d'installation, organisation, version, dernier contact, statut perdu/revoque et date limite offline.
- Au prochain contact : bloquer tout nouveau pull, authentifier l'identite, mettre les mutations locales en quarantaine puis appliquer la decision metier. Ne pas les envoyer sous un autre compte et ne pas les supprimer automatiquement.
- MDM recommande pour appareils geres : code fort, chiffrement, version minimale, interdiction appareil compromis, effacement a distance. L'effacement MDM reste non garanti tant que l'appareil ne se reconnecte pas.

Tests d'acceptation : appareil revoque online bloque immediatement; appareil revoque offline reste utilisable seulement jusqu'a l'echeance annoncee; apres echeance le coffre est verrouille mais la file subsiste; reconnexion declenche quarantaine et journal d'evenement, jamais un effacement silencieux.

## 7. Ecarts priorises complementaires

### ECART P0-03 - Sauvegarde/restauration et suppression non prouvees en exploitation

- **Preuve** : scripts et commandes de verification sont documentes (`data-sync-stability.md:18-24`, `42-60`; `architecture-commercialisation.md:103-127`). La migration objet n'est qu'un plan (`object-storage-migration.md:15-38`).
- **Consequence** : impossible de garantir RPO/RTO, restauration par entreprise, suppression complete ou recuperation apres incident.
- **Recommandation** : etablir matrice des copies et procedure restauree en staging a partir d'une sauvegarde chiffree; test trimestriel; preuve d'integrite; journal des acces et destructions; restauration selectivement par tenant ou justification de son impossibilite.
- **Test d'acceptation** : restauration chronometree sur environnement isole, comparaison manifeste/hash et controle applicatif; preuve que feedback, fichiers, chunks, NocoDB et volume API sont couverts; test de suppression d'un tenant dans toutes les copies actives puis expiration documentee des sauvegardes.

### ECART P1-04 - Signalements dupliques sur disque et par e-mail sans retention codee

- **Preuve** : rapport complet ecrit dans `feedback/reports.jsonl`, statut mail dans `mail-events.jsonl`, puis contenu adresse par SMTP (`feedback.mjs:269-284`, `478-550`). Le POST accepte aussi un fallback client non authentifie (`feedback.mjs:361-370`, `410-435`).
- **Consequence** : noms, identifiants dossier, message libre et contexte se retrouvent dans volume, sauvegardes et messagerie. La redaction ne masque que quelques motifs de secrets (`feedback.mjs:20-25`), pas les donnees de sante ou identites.
- **Recommandation** : authentification obligatoire des que possible; minimiser le contexte (ID pseudonyme plutot que nom); avertir de ne pas saisir de donnees patient; chiffrer le journal ou utiliser un stockage structure avec ACL; TTL et purge auditee; e-mail contenant un lien interne plutot que le contenu sensible.
- **Test d'acceptation** : aucun nom patient dans objet/corps mail; acces au rapport authentifie et tenant-scope; purge automatique au TTL testee; secrets redactes; fallback non authentifie sans identite ni dossier.

### ECART P1-05 - Fichiers temporaires, exports et partage non inventories

- **Preuve** : PDF de rotation dans le repertoire temporaire (`AppDelegate.swift:140-156`); dependances `share_plus`, `open_filex`, `file_picker`, `image_picker` (`pubspec.yaml:44-79`); documents persistants dans Application Documents (`document_repository.dart:345-360`).
- **Consequence** : export vers Fichiers, partage, application tierce, preview OS ou backup peut sortir la piece du perimetre de controle de l'app.
- **Recommandation** : inventaire de chaque action export/ouvrir/partager; confirmation utilisateur; filigrane et classification si approprie; nettoyage garanti des temporaires; interdiction des destinations non gerees via MDM pour parc interne.
- **Test d'acceptation** : apres succes, annulation et crash, aucun temporaire residuel; export journalise sans contenu; politique MDM empeche une destination interdite; copie autorisee reste lisible uniquement selon la politique retenue.

### ECART P1-06 - Chiffrement web partiel et cle accessible a l'origine

- **Preuve** : SQLite web en clair et seulement certaines colonnes scellees (`local_database.dart:75-86`, `178-232`); AES-GCM et cle chargee par le code de la meme origine (`offline_vault_web.dart:45-99`).
- **Consequence** : extraction IndexedDB expose metadonnees/coordonnees structurees; XSS, extension ou session navigateur compromise peut dechiffrer le reste.
- **Recommandation** : ne pas assimiler ce mecanisme a un coffre independant. Pour postes non geres, limiter le offline web; envisager une cle derivee d'une reauthentification non persistante ou WebAuthn, rotation par tenant et CSP stricte. Preferer l'app native geree pour les donnees de sante offline.
- **Test d'acceptation** : export IndexedDB ne contient aucune donnee patient intelligible; changement de tenant change la cle; CSP bloque scripts non autorises; compromission d'un compte ne permet pas de dechiffrer le coffre d'un autre tenant.

### ECART P1-07 - Journaux susceptibles de contenir contexte, erreurs ou identites

- **Preuve** : le debug journalise exceptions et stacks (`main.dart:45-74`), restauration de session journalise l'e-mail (`main.dart:476-499`), API journalise erreurs completes et promesses non gerees (`index.mjs:9000-9053`), WebView ANAH relaie sa console (`anah_screen.dart:923-926`). En release Flutter les erreurs sont reduites au type, ce qui est positif (`main.dart:60-72`).
- **Consequence** : consoles de developpement, EasyPanel/Docker ou support peuvent retenir identites, URL, payloads inclus dans messages d'erreur et traces.
- **Recommandation** : logger structure, allowlist de champs, identifiants pseudonymes, interdiction des payloads/URLs sensibles, acces restreint, TTL, export d'incident audite. Supprimer l'e-mail des logs de boot.
- **Test d'acceptation** : corpus synthetique avec nom, email, token, dossier et sante ne laisse aucune valeur brute dans logs release API/app; seuls code erreur, correlation ID et tenant pseudonyme restent.

### ECART P1-08 - IA locale au serveur non caracterisee

- **Preuve** : sur iPad, Apple Intelligence est appelee localement par canal natif par defaut (`ai_rewrite_service.dart:23-105`). Le chemin distant transmet la note complete a `/api/ai/rewrite`, puis Ollama `/api/chat`; le prompt reconnait explicitement des donnees de sante (`ai_rewrite_service.dart:107-161`; `server/ai/rewrite.mjs:43-65`, `159-187`).
- **Consequence** : si `OLLAMA_BASE_URL` vise un hote tiers ou journalisant, les notes medicales sortent du perimetre suppose. Le code ne prouve ni emplacement, ni absence de logs, ni retention du modele.
- **Recommandation** : endpoint Ollama prive, local au meme perimetre d'hebergement; aucun acces Internet sortant inutile; logs prompts desactives; timeout et suppression memoire; afficher clairement local/distant; desactiver le distant tant que les garanties ne sont pas documentees.
- **Test d'acceptation** : capture reseau synthetique prouve la destination unique; prompt absent des logs; panne IA ne modifie jamais la note; configuration externe interdite par allowlist.

### ECART P2-09 - Cache media global par URL, non lie au tenant

- **Preuve** : cle SHA-1 de l'URL seulement; headers d'auth exclus de la cle pour lecture offline (`media_cache_service.dart:53-75`, `108-120`).
- **Consequence** : si une URL stable est reutilisee entre tenants ou si l'acces UI est imparfait, les octets du premier tenant peuvent etre servis au second.
- **Recommandation** : cle `tenant + user/dossier + revision + URL`, controle d'appartenance avant chaque lecture et invalidation a la revocation; cache physique par tenant.
- **Test d'acceptation** : meme URL synthetique dans A/B avec contenus differents ne croise jamais les octets; logout verrouille le cache A; retour A conserve son cache si autorise.

### ECART P2-10 - Protection native best effort sans alerte exploitable

- **Preuve** : `MissingPluginException` et `PlatformException` sont absorbees (`native_file_protection.dart:30-41`).
- **Consequence** : un build mal configure peut stocker des fichiers sans la classe attendue sans signal visible.
- **Recommandation** : controle de readiness local non sensible et fail-closed pour nouvelles pieces sensibles si la protection ne peut etre confirmee; telemetrie d'etat sans chemin ni nom patient.
- **Test d'acceptation** : plugin absent ou erreur d'attribut bloque une nouvelle piece sensible et affiche une remediation; aucun contenu n'est ecrit avant confirmation.

## 8. Hebergement, sauvegarde, restauration, suppression et incidents

### Verifie dans le code

- API conteneurisee, volume persistant `/data`, NocoDB comme stockage metier et chunks (`Dockerfile.api:28-65`; `helpers.mjs:37-60`; `storage.mjs:1-33`).
- Le volume API contient notamment auth-store, profils, documents, plans, bibliotheque et journaux de feedback (`helpers.mjs:53-60`; `feedback.mjs:269-284`).
- Le projet prevoit a terme un stockage objet S3 avec double lecture, mais ce n'est pas une implementation prouvee (`object-storage-migration.md:15-38`).

### Documente mais non verifie

- Domaines web/API, EasyPanel et controles de backup decrits dans `data-sync-stability.md:26-60` et `architecture-commercialisation.md:103-127`.
- Backup prod precedemment declare verifie dans l'historique documentaire, sans examen du fichier ni preuve de restauration dans cet audit.

### Information manquante et justificatifs precis a demander

Demander a l'operateur, l'hebergeur et chaque sous-traitant :

1. Raison sociale, role, liste des sous-traitants ulterieurs et localisation exacte des datacenters pour VPS/EasyPanel, NocoDB/PostgreSQL, volumes, snapshots, stockage objet, SMTP, DNS/CDN et supervision.
2. Architecture datee : flux, ports, chiffrement en transit interne et externe, terminaison TLS, reseaux prives, pare-feu, egress, separation prod/staging et separation par client.
3. Attestations/certificats applicables avec perimetre, dates et rapport d'audit associe. Pour toute revendication HDS : certificat HDS valide, activites couvertes, sites/services couverts et chaine de sous-traitance. **HTTPS, AES ou un datacenter en France ne prouvent pas HDS.**
4. Contrats/DPA : finalites, instructions, confidentialite du personnel, assistance incidents/droits/suppression, transfert hors EEE et mecanisme de transfert le cas echeant.
5. Gestion des acces d'exploitation : SSO/MFA, RBAC, comptes nominatifs, bastion/VPN, revues periodiques, acces support, break-glass, rotation/revocation et journalisation inviolable.
6. Gestion des secrets et cles : coffre utilise, proprietaire, rotation, separation par environnement/tenant, sauvegarde des cles, procedure de compromission et impossibilite pour les images/builds de contenir un secret.
7. Sauvegardes : donnees couvertes (DB, volume `/data`, chunks, objets, feedback, configurations et cles), frequence, RPO, retention, immutabilite, chiffrement, regions, acces et alertes d'echec.
8. Restaurations : dernier proces-verbal de test, date, jeu synthetique/anonymise, RTO mesure, integrite verifiee, restauration granulaire par tenant et procedure en cas de cle indisponible.
9. Suppression : delais des donnees actives, corbeilles, versions objet, snapshots, backups, logs, e-mails et appareils; preuve de purge; traitement des legal holds; certificat de destruction en fin de contrat.
10. Logs/supervision : champs collectes par proxy, EasyPanel, conteneur, NocoDB, SMTP et WAF; masquage; retention; localisation; destinataires; alertes d'exfiltration et acces aux journaux.
11. Incidents : plan de reponse, astreinte, delais contractuels, qualification, containment, conservation de preuve, modele de notification, exercice recent et contacts d'urgence.
12. Continuite : redondance, panne de zone, capacite, anti-DDoS, mises a jour, vulnerabilites, sauvegarde avant upgrade et procedure de retour arriere.
13. Destruction/fin de service : export complet et portable, verification du transfert, effacement de toutes les copies et revocation des comptes/cles.
14. SMTP/e-mail : fournisseur reel, chiffrement opportuniste ou impose, journalisation, anti-spam, conservation boite/archives, acces delegues et sauvegarde messagerie.
15. IA : emplacement Ollama/Apple, sous-traitants eventuels, absence d'entrainement, logs de prompts, retention, egress et versions de modele.

## 9. Elements a transmettre aux autres agents

### Agent 1 - Comptes et autorisations API

- Le client stocke `organisation_id`, mais les requetes locales ne l'appliquent pas comme frontiere (`local_database.dart:466-496`; `dossier_repository.dart:726-833`). L'API doit fournir un tenant non ambigu et le client doit refuser toute donnee sans tenant.
- Une deconnexion conserve donnees et file (`auth_service.dart:899-910`). Le contrat d'identite doit inclure organisation, utilisateur et appareil; une nouvelle session ne doit jamais revendiquer une operation historique.
- Le feedback accepte un utilisateur client fallback non authentifie (`feedback.mjs:361-435`). Definir le niveau de contexte autorise sans session.
- Les URLs de contenu prive mises en cache doivent etre autorisees au moment du telechargement et revalidees au changement de tenant.

### Agent 3 - Apple/RGPD/HDS

- Categories techniques traitees : identite, coordonnees, adresse, entourage, revenus, sante/autonomie, photos, documents, notes, dessins, PDF, feedback, logs et prompts IA.
- Copies : SQLCipher/Keychain iPad, fichiers Application Documents, temporaires, cache exclu de backup, IndexedDB web partiellement chiffre, NocoDB/chunks, volume API JSON/JSONL, PDF, SMTP/boite mail et eventuel Ollama.
- La revocation offline n'est pas instantanee et ne peut pas l'etre sans connexion. La politique doit fixer une duree maximale offline et le traitement non destructif des saisies.
- Les justificatifs HDS doivent couvrir concretement services, sites, activites et sous-traitants; aucune conclusion HDS ne peut etre tiree du code, de HTTPS ou du chiffrement seuls.

## 10. Conditions minimales avant pilote multi-entreprises

- Isolation locale automatisee A/B prouvee sur iPad et web, y compris fichiers, caches, PDF et files.
- Changement de compte/tenant sans lecture croisee, perte, suppression ou reattribution de file.
- Politique offline/revocation approuvee et testee sur appareil gere.
- Inventaire des copies et sous-traitants signe; retention et suppression definies pour chaque copie.
- Sauvegarde chiffree et restauration chronometree reussie sur donnees synthetiques.
- Logs, feedback, SMTP et IA minimises et testes contre les fuites.
- Procedure d'incident exercee avec contacts, preuves et retour d'experience.

Le passage de ces controles etablit une readiness technique. Il ne constitue pas, a lui seul, une validation Apple, RGPD ou HDS.

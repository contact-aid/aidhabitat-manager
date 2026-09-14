# Audit commercial 01 - Comptes et isolation

Date : 14 septembre 2026  
Projet audite : `Aid'Habitat Manager / App'Ergo`  
Perimetre : authentification, comptes, entreprises, roles, quotas, sessions et autorisations API.

## Conclusion executive

L'application active dispose de protections utiles pour son usage interne actuel : mots de passe serveur convertis en empreintes scrypt, politique de complexite, jetons signes, distinction access/refresh, controle d'affectation sur la majorite des ressources dossier et refus des jetons locaux non signes par l'API.

Elle n'est cependant **pas prete a accueillir plusieurs entreprises**. Le serveur ne porte aucune identite d'entreprise dans la session et n'applique aucun filtre d'entreprise. Le role `ADMIN` signifie actuellement administrateur global Aid'Habitat. Les acces dossier reposent sur un libelle d'ergotherapeute, mutable et non unique entre entreprises. Les quotas, invitations temporaires et reinitialisations par lien n'existent pas. Enfin, la revocation explicite est volatile et les mots de passe generes peuvent rester consultables sur les appareils administrateurs.

Ces limites permettent notamment a un futur administrateur d'entreprise d'administrer tous les comptes et tous les dossiers si son role est mappe sur l'actuel `ADMIN`. Ajouter seulement une colonne `organisation_id` dans Flutter ou NocoDB ne suffirait donc pas.

**Decision recommandee :** ne pas ouvrir l'application a une seconde entreprise avant la mise en place d'un contexte serveur de tenant obligatoire, de roles distincts, de contraintes d'appartenance sur toutes les ressources privees et de tests d'isolation exhaustifs.

## Methode et niveau de preuve

- Analyse statique des points d'entree reels de `server/index.mjs`, de ses deux routeurs effectivement montes, et du transport Flutter utilise par iPad et web.
- Verification des appels depuis `AuthService`, `NocodbApiClient`, la synchronisation et les tables locales.
- Aucun secret, fichier `.env`, backup ou enregistrement NocoDB n'a ete lu.
- Aucun appel reseau, test de production, test offensif, build ou modification de donnees n'a ete effectue.
- Aucun test sur appareil n'a ete realise. Les conclusions portent sur les chemins de code actifs observes.
- Les modules `server/routes/auth.mjs`, `dossiers.mjs`, `documents.mjs`, `references.mjs` et `sync.mjs` ne sont pas montes par l'application active. `server/index.mjs:8947-8948` ne monte que `aiRouter` et `feedbackRouter`; les routes inline de `server/index.mjs` sont donc la source d'autorite actuelle.

## Architecture active constatee

### Identite et mots de passe

- Le compte serveur est une ligne `ergotherapeutes`, identifiee principalement par email.
- Le champ NocoDB `mot_de_passe` accepte le format `scrypt$v1$salt$hash`. Le sel est aleatoire et la verification utilise une comparaison temporellement sure (`server/passwordCredential.mjs:3-46`).
- Les valeurs historiques en clair sont detectees puis transformees vers ce format au chargement du registre (`server/index.mjs:3144-3161`). Cette migration est opportuniste et non transactionnelle.
- Le role ne vient pas d'un modele d'appartenance. Seules les adresses du dictionnaire code `MEMBER_PROFILES` obtiennent leur role special; toutes les autres deviennent `ERGO` (`server/index.mjs:132-140`, `2805-2851`).
- Flutter maintient un compte local et une empreinte locale pour permettre une connexion hors ligne apres une premiere connexion (`aid_habitat_app/lib/services/auth_service.dart:485-613`).

### Sessions

- Jeton d'acces : HMAC, duree 7 jours. Jeton de renouvellement : HMAC, duree 90 jours (`server/index.mjs:107-109`, `3224-3250`).
- La charge contient email, expiration, type et version de session, mais aucun `user_id`, `organisation_id`, `membership_id` ni audience (`server/index.mjs:3231-3243`).
- Le serveur rejette les jetons locaux `local-auth:` non signes (`server/index.mjs:3252-3263`).
- Flutter conserve les jetons dans Keychain/secure storage natif ou le mecanisme secure storage web (`aid_habitat_app/lib/services/secure_session_storage.dart:26-59`, `75-113`).

### Autorisations

- `requireAuth` prouve seulement qu'une session correspond a un membre courant. `requireAdmin` accepte tout membre dont le role vaut `ADMIN` (`server/index.mjs:3302-3335`).
- Un administrateur a acces a tous les dossiers. Un ergo est compare au texte `dossiers.ergo_id` via son `ergoLabel` (`server/dossierAssignments.mjs:1-12`).
- Les routes dossier, PDF, documents, notes, plans, mesures, sanitaires, observations et recommandations appellent majoritairement ces gardes.
- Les ressources de reference et la bibliotheque sont globales. Plusieurs mutations globales demandent seulement `requireAuth`.

## Classification cible des ressources

| Ressource | Etat actuel | Cible recommandee | Autorisation cible |
|---|---|---|---|
| Entreprises, plans et quotas | Absents | Globale, administree par Aid'Habitat | `AIDHABITAT_ADMIN` uniquement |
| Utilisateurs | Registre global d'ergotherapeutes | Identite globale sans droit implicite | Soi-meme; Aid'Habitat pour support controle |
| Appartenances et roles | Absents | Prives par entreprise | Admin entreprise dans son tenant; Aid'Habitat global |
| Invitations et resets | Absents | Prives par entreprise et utilisateur | Jeton ponctuel scope et expire |
| Dossiers et beneficiaires | Affectation ergo, sans tenant | Strictement prives par entreprise | Appartenance active + droit dossier |
| Documents, notes, plans, photos, rapports PDF | Heritent indirectement du dossier | Strictement prives par entreprise | Meme tenant que le dossier, verifie sur chaque lecture/ecriture |
| Operations de synchronisation | Tenant local par defaut uniquement | Strictement privees par entreprise et utilisateur | Tenant de session obligatoire |
| Bibliotheque wiki | Globale et modifiable par tout utilisateur authentifie | Choix explicite : catalogue Aid'Habitat global en lecture, extensions privees par entreprise | Ecriture globale Aid'Habitat; ecriture locale admin entreprise |
| Caisses, communes, EPCI, listes de reference | Globales | Globales en lecture | Ecriture Aid'Habitat uniquement |
| Statut ANAH | Global | Global en lecture | Ecriture/configuration Aid'Habitat |
| Photos de profil | Liees a l'email | Privees a l'utilisateur | Soi-meme uniquement |
| Administration des mails de feedback | Globale | Globale support Aid'Habitat | `AIDHABITAT_ADMIN` uniquement |
| Reecriture IA | Service partage | Global techniquement, consommation attribuee au tenant | Membre actif + quota tenant |

## Constats detailles

### C01 - Aucun contexte d'entreprise n'est impose par le serveur

- **Gravite : Critique, bloquant commercialisation.**
- **Fichiers et lignes :** `server/index.mjs:2805-2851`, `3231-3243`, `3302-3335`; `aid_habitat_app/lib/models/types.dart:63-105`; `aid_habitat_app/lib/services/auth_service.dart:40-47`.
- **Preuve :** le membre serveur expose un etablissement mais pas d'identifiant d'entreprise. Le token signe ne contient que l'email, l'expiration, la version et le type. Flutter possede `organisationId`, mais utilise par defaut la constante `org_aidhabitat`; ce champ client ne participe pas a l'autorisation serveur.
- **Scenario de risque :** une entreprise B rejoint l'application. Un utilisateur B devine ou recoit l'identifiant d'une ressource A. Aucun invariant serveur general ne permet de verifier `resource.company_id == session.company_id`; la decision depend uniquement des gardes historiques par ergo.
- **Correction recommandee :** creer des identifiants immuables `company_id`, `user_id`, `membership_id`; resoudre le tenant et l'appartenance active a chaque requete; faire porter au contexte d'authentification ces identifiants; interdire toute requete metier sans tenant resolu. Ne jamais accepter le tenant fourni par le body comme preuve.
- **Dependances :** schema NocoDB/PostgreSQL, migration de toutes les tables privees, middleware central, index et contraintes de cle etrangere.
- **Risque de regression :** dossiers historiques sans tenant rendus invisibles; synchronisations iPad anciennes rejetees.
- **Test d'acceptation :** deux entreprises synthetiques avec identifiants de ressources connus; chaque GET/POST/PUT/PATCH/DELETE de B vers A retourne 404/403 et ne fait aucune lecture ou ecriture metier; les memes operations dans B reussissent.

### C02 - `ADMIN` est un super-administrateur global, pas un administrateur d'entreprise

- **Gravite : Critique.**
- **Fichiers et lignes :** `server/index.mjs:3318-3335`, `3364-3378`, `3381-3385`, `3906-3913`, `4464-4468`, `4671-4837`; `server/dossierAssignments.mjs:8-12`.
- **Preuve :** `requireAdmin` ne distingue qu'`ADMIN` et `ERGO`. Un `ADMIN` recoit le wildcard dossier, voit tous les membres, peut creer, modifier, supprimer n'importe quel compte et revoquer ses sessions. Tous les controles dossier retournent vrai pour ce role.
- **Scenario de risque :** le responsable de l'entreprise B est cree comme `ADMIN`; il voit les utilisateurs et dossiers A, peut supprimer un ergo A ou reinitialiser son mot de passe.
- **Correction recommandee :** introduire au minimum `AIDHABITAT_ADMIN`, `COMPANY_ADMIN`, `ERGO`; appliquer une matrice permission/ressource. L'admin entreprise ne peut gerer que les appartenances de son entreprise et ne peut ni changer son quota ni acceder aux fonctions support globales.
- **Dependances :** modele d'appartenance, middleware `requirePlatformAdmin`, `requireCompanyAdmin`, politiques par ressource.
- **Risque de regression :** le compte interne actuellement admin peut perdre des fonctions si son role n'est pas migre explicitement.
- **Test d'acceptation :** l'admin B ne liste, ne modifie et ne revoque que les membres B; l'admin Aid'Habitat peut administrer A et B; un ergo n'accede a aucune route administrative.

### C03 - Les roles et identites privilegiees sont partiellement codes en dur

- **Gravite : Elevee.**
- **Fichiers et lignes :** `server/index.mjs:132-141`, `2805-2851`, `3045-3071`, `4684-4737`.
- **Preuve :** trois profils sont definis dans `MEMBER_PROFILES`; le role est `special?.role || 'ERGO'`. La route de creation accepte `role: ADMIN` et le place dans le store RAM, mais ne persiste aucun role dans la ligne NocoDB creee. Au redemarrage, un compte non special redevient `ERGO`. Le chargement cree ou modifie aussi automatiquement les profils codes en dur.
- **Scenario de risque :** un nouvel admin entreprise fonctionne jusqu'au redemarrage puis perd son role; inversement, un email historique conserve un privilege global independamment du modele commercial attendu.
- **Correction recommandee :** supprimer l'autorite des emails codes en dur apres migration; persister les roles sur l'appartenance, jamais sur l'identite globale; bootstrapper le premier `AIDHABITAT_ADMIN` par migration auditee et non au chargement de chaque requete.
- **Dependances :** tables users/companies/memberships, journal d'audit, procedure de bootstrap.
- **Risque de regression :** perte d'acces du compte interne si la migration n'est pas atomique et verifiee.
- **Test d'acceptation :** redemarrer plusieurs instances avec un registre synthetique; roles et droits restent identiques, sans dependance a un email particulier.

### C04 - L'isolation dossier repose sur un libelle d'ergo mutable et non sur le tenant

- **Gravite : Critique.**
- **Fichiers et lignes :** `server/dossierAssignments.mjs:1-12`; `server/index.mjs:3437-3439`, `3906-3935`.
- **Preuve :** `canAccessDossierAssignment` compare deux chaines exactes : `dossiers.ergo_id` et `appUser.ergoLabel`. Aucun identifiant d'entreprise, utilisateur ou appartenance n'est compare. Le scope `establishment_id` construit a `server/index.mjs:3387-3390` n'est pas utilise par `filterDossiersByScopes`.
- **Scenario de risque :** deux entreprises ont une ergotherapeute appelee « Marie Dupont », ou un libelle est renomme/reutilise. Le compte B peut correspondre aux dossiers A portant le meme texte.
- **Correction recommandee :** stocker `company_id` et `assigned_membership_id` sur le dossier; verifier d'abord le tenant puis l'affectation par identifiant. Garder `ergo_id` uniquement comme libelle historique pendant la migration.
- **Dependances :** mapping fiable des comptes actuels, backfill dossiers, index composites `(company_id, id)` et `(company_id, assigned_membership_id)`.
- **Risque de regression :** dossiers historiques non apparies; changements d'affectation en attente sur iPad.
- **Test d'acceptation :** memes noms d'ergo dans A et B; aucun dossier ne traverse, y compris PDF, documents, notes, plans et endpoints secondaires.

### C05 - Un beneficiaire sans dossier associe peut contourner le controle d'affectation

- **Gravite : Elevee.**
- **Fichiers et lignes :** `server/index.mjs:3504-3540`, `3543-3615`, puis appels documents `7610-8075` et notes `8146-8339`.
- **Preuve :** `_resolveAccessFromBeneficiary` et le slow path ne refusent que si un `dossierRecord` existe et echoue au controle. Si aucun dossier n'est trouve, ils retournent le beneficiaire sans verifier proprietaire ou entreprise. Les routes documents et notes utilisent ce resultat comme autorisation.
- **Scenario de risque :** un identifiant de beneficiaire orphelin est connu ou devine; un utilisateur authentifie d'une autre entreprise lit ou ajoute ses documents/notes.
- **Correction recommandee :** toute ressource privee doit porter son `company_id`. Refuser par defaut un beneficiaire sans tenant; reserver sa recuperation a une procedure support explicite et auditee.
- **Dependances :** colonnes tenant sur beneficiaires/documents/notes, traitement des orphelins historiques.
- **Risque de regression :** anciens beneficiaires virtuels sans dossier deviennent temporairement inaccessibles.
- **Test d'acceptation :** beneficiaire synthetique sans dossier appartenant a A; B obtient 404/403 sur toutes les routes documents/notes, A ou le support autorise suit une procedure explicite.

### C06 - Des ressources globales sont modifiables par tout utilisateur authentifie

- **Gravite : Elevee.**
- **Fichiers et lignes :** `server/index.mjs:5093-5124` (caisse principale), `5145-5299` (bibliotheque), `5307-5509` (caisses complementaires).
- **Preuve :** les POST/PUT/DELETE correspondants utilisent `requireAuth`, pas un role d'administration de plateforme ou d'entreprise. La bibliotheque et les caisses sont servies comme ensembles globaux.
- **Scenario de risque :** un ergo de B modifie ou supprime un element de bibliotheque ou une caisse utilisee dans les rapports de toutes les entreprises.
- **Correction recommandee :** declarer chaque catalogue global ou prive. Pour le global, lecture membre et ecriture `AIDHABITAT_ADMIN`; pour une extension entreprise, ajouter `company_id`, conserver le catalogue global en lecture seule et fusionner les deux espaces cote lecture.
- **Dependances :** decision produit sur la bibliotheque, matrice RBAC, eventuelle table de surcharge tenant.
- **Risque de regression :** les ergos actuels ne pourront plus corriger directement les catalogues globaux.
- **Test d'acceptation :** ergo et admin entreprise recoivent 403 sur une mutation globale; admin Aid'Habitat reussit; une extension B reste invisible ou non modifiable depuis A selon la politique choisie.

### C07 - La revocation explicite et le logout ne sont pas durables

- **Gravite : Elevee.**
- **Fichiers et lignes :** `server/index.mjs:1402-1467`, `4483-4485`, `4793-4837`, `3224-3289`.
- **Preuve :** `auth-store` est uniquement en RAM. La route logout renvoie succes sans invalider le token presente. La revocation incrementant `sessionVersion` n'ecrit que dans ce store RAM. Apres redemarrage ou sur une autre instance, cette valeur peut disparaitre. Une modification de mot de passe est plus robuste car l'empreinte NocoDB contribue a `sv`, mais ce n'est pas le cas d'une revocation sans rotation.
- **Scenario de risque :** un iPad est perdu; l'admin revoque les sessions, puis l'API redemarre ou la requete suivante atteint une autre instance et l'ancien token redevient acceptable jusqu'a expiration.
- **Correction recommandee :** stocker durablement `session_version` ou `revoked_before` par appartenance/utilisateur; verifier cette valeur a chaque session avec cache borne. Le logout doit revoquer au minimum la session/refresh token courant. Preferer des refresh tokens opaques, haches en base, a usage unique et lies a un appareil.
- **Dependances :** table sessions/refresh_tokens, stockage durable, nettoyage periodique.
- **Risque de regression :** deconnexions massives lors du backfill initial ou incoherence de cache multi-instance.
- **Test d'acceptation :** revoquer un token, redemarrer deux instances, puis verifier que l'access token et tous ses refresh tokens restent rejetes partout.

### C08 - La rotation du refresh token n'empeche pas son rejeu

- **Gravite : Elevee.**
- **Fichiers et lignes :** `server/index.mjs:3224-3250`, `3252-3300`, `4424-4444`.
- **Preuve :** la route annonce une rotation, mais les refresh tokens sont des jetons HMAC autonomes sans identifiant persiste ni marque « consomme ». Presenter plusieurs fois le meme refresh token avant expiration genere plusieurs nouvelles paires valides.
- **Scenario de risque :** un refresh token copie depuis un appareil compromis continue a renouveler une session pendant 90 jours, meme apres que l'utilisateur legitime l'a utilise et remplace localement.
- **Correction recommandee :** refresh token aleatoire opaque, empreinte stockee, famille de rotation, consommation atomique, detection de rejeu et revocation de la famille.
- **Dependances :** stockage session durable, transaction/contrainte unique.
- **Risque de regression :** appareils anciens perdant le refresh token lors d'une reponse reseau perdue.
- **Test d'acceptation :** deux utilisations du meme refresh token : une seule reussit; une reponse perdue suit une strategie idempotente bornee; un rejeu revoque la famille selon la politique retenue.

### C09 - Le flux invitation/activation/reinitialisation temporaire n'existe pas

- **Gravite : Elevee, fonctionnalite cible absente.**
- **Fichiers et lignes :** `server/index.mjs:4620-4665`, `4684-4737`; `aid_habitat_app/lib/services/nocodb_api_client.dart:2289-2445`.
- **Preuve :** le provisionnement cree ou genere directement un mot de passe et le renvoie a l'administrateur. Aucun endpoint d'acceptation d'invitation, verification d'email, oubli de mot de passe, token temporaire, expiration ou consommation unique n'est present dans la surface active.
- **Scenario de risque :** l'admin transmet manuellement un secret permanent; le mauvais destinataire peut l'utiliser, et aucune preuve d'activation ni expiration n'existe.
- **Correction recommandee :** invitation hachee en base, expiration courte, usage unique, liee a l'email et a l'entreprise; l'utilisateur definit lui-meme son mot de passe. Meme principe pour reset, sans reveler si l'email existe. Journaliser creation, envoi, consommation et revocation sans journaliser le token.
- **Dependances :** service mail transactionnel, URLs publiques, tables invitations/resets, rate limiting partage.
- **Risque de regression :** comptes historiques sans email valide; liens ouverts dans Safari au lieu de l'app iPad.
- **Test d'acceptation :** lien valide utilisable une fois avant expiration; mauvais email/tenant, lien expire ou rejoue refuses; aucun mot de passe n'apparait dans mail, logs ou reponse API.

### C10 - Les mots de passe generes restent recuperables sur l'appareil administrateur

- **Gravite : Elevee.**
- **Fichiers et lignes :** `server/index.mjs:4653-4659`, `4705-4737`; `aid_habitat_app/lib/services/access_members_repository.dart:98-139`, `188-223`, `336-411`, `435-446`; `aid_habitat_app/lib/services/local_database.dart:1013-1030`.
- **Preuve :** le serveur renvoie le mot de passe en clair lors de la creation/provision. Flutter chiffre reversiblement `generated_password`, `pending_password` et le payload de synchronisation, puis fournit `fetchEffectivePassword` et le remappe dans le modele pour affichage ulterieur. Ce n'est donc pas un affichage unique au sens fonctionnel.
- **Scenario de risque :** toute personne ayant acces a la session admin ou a une sauvegarde/deverrouillage de l'appareil peut reafficher les mots de passe des ergos. Sur web, cette donnee reside dans le stockage local chiffre par une cle du meme contexte navigateur.
- **Correction recommandee :** supprimer le mot de passe genere du modele persistant et de la queue. Remplacer par invitation. Si un secret provisoire reste necessaire pendant la transition, ne l'afficher qu'une fois en memoire, l'expirer, forcer son changement et ne jamais le restituer ensuite.
- **Dependances :** nouveau flux invitation, migration locale supprimant les colonnes et payloads sensibles apres drainage.
- **Risque de regression :** perte de la fonction actuelle de communication manuelle du mot de passe.
- **Test d'acceptation :** apres fermeture de la modale ou redemarrage, aucune API/requete SQLite ne permet de recuperer le secret; recherche de fixtures dans les stockages ne retrouve que des empreintes ou tokens ponctuels haches.

### C11 - Le changement de mot de passe utilisateur est local, pas un changement de credential serveur

- **Gravite : Elevee.**
- **Fichiers et lignes :** `aid_habitat_app/lib/screens/settings_screen.dart:597-627`; `aid_habitat_app/lib/services/auth_service.dart:942-982`; routes actives `server/index.mjs:4358-4485` et `4620-4837`.
- **Preuve :** l'interface annonce explicitement « Changer votre mot de passe local ». Le serveur n'expose pas d'endpoint authentifie permettant a l'utilisateur de changer son propre mot de passe apres verification de l'ancien. Seul un admin peut provisionner/reinitialiser.
- **Scenario de risque :** un utilisateur pense avoir change son mot de passe, mais son credential serveur reste identique; l'ancien secret continue a ouvrir une session distante.
- **Correction recommandee :** endpoint `change-password` pour soi-meme exigeant ancien mot de passe ou reauthentification recente, politique forte, mise a jour atomique de l'empreinte et revocation de toutes les sessions sauf choix explicite de la session courante.
- **Dependances :** stockage durable des versions/session, UI iPad/web et reconciliation du hash offline.
- **Risque de regression :** l'ancien appareil offline ne reconnait plus le nouveau mot de passe tant qu'il n'a pas confirme la rotation en ligne.
- **Test d'acceptation :** apres changement confirme, ancien mot de passe, anciens access tokens et refresh tokens sont rejetes; nouveau mot de passe fonctionne en ligne puis hors ligne apres synchronisation locale reussie.

### C12 - Les quotas d'ergotherapeutes et le cycle de vie des appartenances sont absents

- **Gravite : Elevee, exigence commerciale absente.**
- **Fichiers et lignes :** `server/index.mjs:4684-4737`; recherche des routes actives, aucune verification de quota ou table entreprise/appartenance.
- **Preuve :** la creation ajoute directement une ligne `ergotherapeutes`. Aucun compteur, reservation atomique de siege, statut d'entreprise, date de suspension ou appartenance n'est verifie.
- **Scenario de risque :** une entreprise cree plus de comptes que son contrat; deux creations concurrentes depassent un quota meme si un simple comptage est ajoute plus tard.
- **Correction recommandee :** `companies(seat_quota,status)`, `memberships(company_id,user_id,role,status)` et consommation transactionnelle. Definir si les invitations en attente reservent un siege et comment les comptes multi-entreprises sont comptes.
- **Dependances :** regles commerciales, transaction ou contrainte cote base, administration Aid'Habitat.
- **Risque de regression :** utilisateurs internes historiques comptes par erreur ou bloques lors du backfill.
- **Test d'acceptation :** quota N : N activations reussissent, N+1 echoue sans creer d'utilisateur orphelin; deux activations concurrentes pour le dernier siege ont un seul gagnant.

### C13 - La connexion hors ligne peut prolonger localement un acces revoque

- **Gravite : Moyenne a elevee selon politique contractuelle.**
- **Fichiers et lignes :** `aid_habitat_app/lib/services/auth_service.dart:485-555`, `581-613`; `server/index.mjs:3255-3263`.
- **Preuve :** si le serveur est explicitement joignable et rejette, Flutter refuse le fallback local. S'il est injoignable et que l'empreinte locale correspond, la session locale s'ouvre. L'API rejette bien le token local, mais les donnees deja presentes sur l'appareil restent utilisables hors ligne.
- **Scenario de risque :** un ergo quitte l'entreprise mais conserve un iPad hors ligne et peut consulter les dossiers deja caches jusqu'a la prochaine validation serveur ou suppression locale.
- **Correction recommandee :** definir une duree maximale d'autorisation offline depuis la derniere validation, liee a l'appartenance et au tenant; verrouiller ou purger selon la politique MDM/RGPD; ne jamais supprimer automatiquement des operations non synchronisees sans parcours de recuperation support.
- **Dependances :** decision produit securite/offline, horloge fiable, eventuel MDM, mecanisme de quarantaine des donnees locales.
- **Risque de regression :** blocage d'ergos sur le terrain sans reseau apres expiration de la fenetre offline.
- **Test d'acceptation :** dans la fenetre autorisee, travail offline possible; apres revocation connue ou expiration, reouverture interdite sans connexion; aucune mutation en attente n'est envoyee sous une autre identite.

### C14 - Les controles d'acces sont disperses et les modules dupliques peuvent donner une fausse assurance

- **Gravite : Elevee.**
- **Fichiers et lignes :** `server/index.mjs:6821-6862`, `7610-8410`, `8525-8945`, `8947-8948`; fichiers non montes `server/routes/auth.mjs`, `dossiers.mjs`, `documents.mjs`, `references.mjs`, `sync.mjs`.
- **Preuve :** les routes principales sont implementees inline. Les modules homonymes existent mais ne sont pas branches. Chaque route appelle manuellement un helper d'acces; il n'existe pas de middleware tenant obligatoire applique a tout `/api` metier.
- **Scenario de risque :** une correction est appliquee au module non monte ou une nouvelle route oublie le helper, puis est consideree protegee lors d'une revue superficielle.
- **Correction recommandee :** une seule composition active des routes; middleware central resolvant session et tenant; politiques de ressource obligatoires; test d'inventaire qui echoue si une route privee n'annonce pas sa politique.
- **Dependances :** refactor progressif, manifest des routes/politiques, tests Express reels.
- **Risque de regression :** divergence de forme JSON ou oubli d'une route pendant l'extraction.
- **Test d'acceptation :** inventaire automatique de chaque methode/route active, classification global/prive/admin et matrice 401/403/404/200 executee avec deux tenants.

### C15 - Le rate limiting d'authentification est local au processus

- **Gravite : Moyenne.**
- **Fichiers et lignes :** `server/index.mjs:1094-1116`, `4358-4369`.
- **Preuve :** les echecs sont conserves dans une `Map` en memoire. Le controle disparait au redemarrage et n'est pas partage entre plusieurs instances. L'adresse client utilise `x-forwarded-for` sans preuve visible ici d'une configuration stricte des proxies de confiance.
- **Scenario de risque :** un attaquant repartit ses tentatives entre instances/redemarrages ou manipule l'en-tete selon la topologie proxy.
- **Correction recommandee :** limite partagee durablement, cles compte + IP, proxy de confiance explicitement configure, alertes et delais progressifs; appliquer aussi invitation/reset.
- **Dependances :** Redis ou stockage partage, configuration EasyPanel/Traefik.
- **Risque de regression :** verrouillage excessif d'une entreprise partageant une meme IP publique.
- **Test d'acceptation :** limite coherente sur deux instances et apres redemarrage; une IP partagee ne bloque pas tous les comptes legitimes; headers non fiables ne contournent pas la limite.

## Protections effectivement operationnelles dans le code audite

Les protections suivantes sont branchees sur les chemins actifs, sans que cela constitue une validation de production :

- Politique mot de passe 14 a 128 caracteres avec minuscule, majuscule, chiffre et symbole, appliquee aux creations/reset administrateur (`server/index.mjs:971-1004`, `4624-4627`, `4691-4694`).
- Empreinte scrypt salee et non reversible pour les nouveaux credentials NocoDB (`server/passwordCredential.mjs:3-46`, `server/index.mjs:1028-1037`).
- Rejet API des tokens locaux non signes (`server/index.mjs:3255-3263`).
- Signature temporellement comparee, expiration, separation access/refresh et invalidation lors d'un changement d'empreinte mot de passe (`server/index.mjs:3265-3289`).
- Refus du fallback offline Flutter lorsque le serveur repond explicitement 401 (`aid_habitat_app/lib/services/auth_service.dart:518-535`).
- Stockage des jetons hors SQLite via secure storage (`aid_habitat_app/lib/services/auth_service.dart:586-605`; `secure_session_storage.dart:26-59`).
- Controle de scope avant generation PDF (`server/index.mjs:6821-6862`) et avant la majorite des operations dossiers/documents/notes/plans/diagnostics.

Ces garanties ne prouvent ni une isolation d'entreprise, ni une revocation durable multi-instance, ni l'absence de valeurs historiques en clair dans les donnees reelles, lesquelles n'ont pas ete inspectees conformement aux contraintes.

## Matrice d'autorisation cible

| Action | Aid'Habitat admin | Admin entreprise | Ergo |
|---|---:|---:|---:|
| Creer/suspendre une entreprise, fixer quota | Oui | Non | Non |
| Lister toutes les entreprises | Oui | Non | Non |
| Inviter un membre dans son entreprise | Oui | Oui | Non |
| Changer role/retirer membre de son entreprise | Oui | Oui, sauf garde-fous dernier admin | Non |
| Revoquer sessions d'un membre de son entreprise | Oui | Oui | Non |
| Changer son propre mot de passe | Oui | Oui | Oui |
| Lire dossiers entreprise | Support explicite/audite | Selon politique entreprise | Seulement affectes |
| Modifier dossier | Support explicite/audite | Selon politique entreprise | Seulement affectes |
| Generer/lire PDF et documents | Meme droit que dossier | Meme droit que dossier | Meme droit que dossier |
| Lire catalogue global | Oui | Oui | Oui |
| Modifier catalogue global | Oui | Non | Non |
| Gerer extension de catalogue entreprise | Oui | Oui | Selon politique |
| Consulter diagnostics feedback globaux | Oui | Non | Non |

## Trajectoire de migration progressive

### Phase 0 - Figer les invariants et mesurer

1. Inventorier automatiquement toutes les routes actives et leur politique.
2. Ecrire les tests Express reels a deux tenants avant de modifier le schema.
3. Definir officiellement ressources globales/privees, politique offline, comptage des invitations et acces support Aid'Habitat.
4. Ajouter de la telemetrie non sensible sur les refus d'autorisation et les sessions, sans journaliser tokens, mots de passe ou donnees patient.

Critere de sortie : matrice complete, tests rouges representant chaque lacune C01-C15, et plan de retour arriere.

### Phase 1 - Ajouter le modele sans changer les droits actuels

1. Creer `companies`, `users`, `memberships`, `membership_roles`, `sessions`, `invitations` et `password_resets`.
2. Creer l'entreprise historique `org_aidhabitat` et y rattacher tous les comptes actuels.
3. Ajouter des identifiants immuables aux comptes tout en conservant les emails et `ergoLabel` comme alias de compatibilite.
4. Conserver temporairement les reponses JSON actuelles et y ajouter des champs optionnels; les anciennes apps continuent ainsi a fonctionner.

Critere de sortie : aucun changement visible pour les utilisateurs actuels; redemarrage sans perte de role/session; audit de backfill sans ligne orpheline.

### Phase 2 - Backfill des ressources privees

1. Ajouter `company_id` nullable aux dossiers, beneficiaires, documents, notes, plans, recommandations et donnees de visite.
2. Backfiller uniquement vers `org_aidhabitat`, par lots idempotents et controles.
3. Ajouter les index et verifier les incoherences avant de rendre les colonnes obligatoires.
4. Mettre en quarantaine les beneficiaires sans dossier plutot que de leur attribuer silencieusement un tenant.

Critere de sortie : 100 % des ressources privees ont un tenant prouve; aucune association n'est deduite seulement d'un nom.

### Phase 3 - Introduire le contexte tenant en mode compatibilite

1. Les nouvelles sessions portent `user_id` et `membership_id`; le serveur resout le `company_id` courant depuis la base.
2. Les anciennes sessions restent acceptees uniquement pour les utilisateurs appartenant a l'entreprise historique et pour une fenetre bornee.
3. Ajouter les gardes tenant a toutes les routes avant d'activer une seconde entreprise.
4. Les anciennes apps sans champ tenant sont forcees sur l'appartenance historique unique; si un utilisateur a plusieurs appartenances, elles doivent demander une mise a jour plutot que choisir silencieusement.

Critere de sortie : suite deux tenants verte sur chaque route; anciens clients testes sur l'entreprise historique uniquement.

### Phase 4 - Sessions durables et credentials utilisateur

1. Migrer `session_version`/sessions et refresh tokens haches vers le stockage durable.
2. Ajouter changement de mot de passe pour soi-meme, invitation et reset par lien temporaire.
3. Retirer les mots de passe recuperables de Flutter et des queues, puis purger les colonnes locales apres confirmation qu'aucune operation ancienne n'en depend.
4. Conserver temporairement la lecture des credentials scrypt actuels; les reencoder lors d'une authentification reussie si les parametres changent.

Critere de sortie : rotation, logout, revocation et rejeu testes sur plusieurs instances et apres redemarrage; aucun secret permanent restituable.

### Phase 5 - Roles et quotas

1. Migrer le compte interne vers `AIDHABITAT_ADMIN`.
2. Activer `COMPANY_ADMIN` avec politiques tenant strictes.
3. Appliquer les quotas de sieges transactionnellement a l'activation et aux changements de statut.
4. Ajouter garde du dernier admin d'entreprise, suspension d'entreprise et acces support temporaire audite.

Critere de sortie : tests de concurrence sur dernier siege et dernier admin; admin entreprise incapable d'agir hors tenant.

### Phase 6 - Ouvrir une entreprise pilote

1. Creer une entreprise synthetique en staging, puis une entreprise pilote sans donnee historique.
2. Tester iPad et web : activation, login, offline apres premiere connexion, retour en ligne, changement de mot de passe, revocation, PDF, documents, bibliotheque et exports.
3. Tester explicitement chaque identifiant A depuis une session B.
4. N'ouvrir la deuxieme entreprise en production qu'apres preuve de restauration et validation des journaux d'autorisation.

Critere de sortie : aucune lecture/ecriture inter-tenant dans la matrice automatisee et la recette appareil; limitations offline documentees contractuellement.

## Conditions minimales avant ouverture commerciale

- Aucun `ADMIN` entreprise ne doit utiliser l'actuel privilege global.
- Toute ressource privee doit porter un `company_id` obligatoire et verifie cote serveur.
- Toute autorisation doit utiliser des identifiants immuables, jamais un nom ou email seul.
- Invitations, resets et refresh tokens doivent etre haches, expires, revocables et a usage unique selon leur contrat.
- Le mot de passe permanent ne doit etre visible ni dans NocoDB, ni dans une reponse d'administration, ni recuperable depuis le cache Flutter.
- La revocation doit survivre aux redemarrages et fonctionner sur toutes les instances.
- Les quotas doivent etre appliques atomiquement.
- La compatibilite ancienne doit etre limitee a l'entreprise historique, mesuree et assortie d'une date de retrait.
- Une suite d'acceptation deux tenants doit couvrir toutes les routes actives, y compris PDF, documents, uploads, bibliotheque, exports, IA, feedback et administration.


# Retour agent 1 - Lectures NocoDB ciblees (F09)

## Isolation

- Worktree : `/private/tmp/aid-habitat-agent1.NEulm1`
- Branche : `codex/audit-dossier-queries`
- SHA de base : `10df5d4c289ffe757af6027f0be0f670fa8f97b7`
- Repertoire source laisse sur sa branche et sans modification par cet agent.
- Aucun commit, push, merge, deploiement, acces NocoDB reel ou donnee patient.

## Diagnostic statique

Le constat F09 est confirme sur la base imposee : les GET actifs suivants appelaient
`queryAll()` sans `where`, puis cherchaient la ligne du dossier en JavaScript :

- `GET /api/diagnostic-sanitaires/:dossierId`
- `GET /api/mesures/:dossierId`
- `GET /api/observations/:dossierId`

Les invariants releves et preserves sont :

- `ensureDossierRecord()` resout d'abord l'identifiant demande ;
- `canAccessDossierRecord()` est applique avant la lecture de la table metier ;
- `uuid_source` du dossier est utilise comme identifiant canonique, avec repli sur
  l'identifiant demande ;
- l'absence de ligne produit toujours `null` ;
- plusieurs lignes sont departagees par `UpdatedAt`, puis `updated_at`, puis
  `created_at`, et enfin par l'Id NocoDB decroissant ;
- les projections `FIELD_SETS` et les objets JSON de reponse des routes sont
  inchanges.

## Implementation

Un helper isole effectue maintenant, dans cet ordre :

1. resolution du dossier avec le helper existant ;
2. controle d'acces avec le helper existant ;
3. lecture NocoDB avec `where: (dossier_id,eq,<identifiant JSON>)` et la projection
   existante ;
4. verification locale stricte de `dossier_id` ;
5. application de la regle historique de choix de la ligne la plus recente.

Aucun tri serveur n'a ete ajoute. Les trois tables ne projettent pas toutes les
memes colonnes temporelles et un tri unique aurait pu modifier la priorite de repli
historique. `queryAll()` continue donc a paginer toutes les lignes du dossier, mais
plus toutes les lignes de la table.

## Fichiers modifies ou ajoutes

- `server/index.mjs` : branchement des trois GET actifs sur la lecture ciblee.
- `server/dossierReadQueries.mjs` : construction du filtre, controle d'acces et
  selection compatible de la ligne.
- `server/dossierReadQueries.test.mjs` : simulateur NocoDB et regressions F09.
- `docs/retour-agent-1.md` : present rapport.

## Reproduction automatisee

Le simulateur NocoDB applique le filtre, la projection et la pagination, puis
enregistre tous les parametres de requete. Les tests couvrent :

- les trois tables et leurs projections ;
- plusieurs dossiers ;
- aucune ligne ;
- plusieurs lignes pour un dossier et les egalites de date ;
- 205 lignes filtrees reparties sur trois pages ;
- un identifiant atypique avec espace, slash, accent et guillemets ;
- un alias temporaire resolu vers l'UUID canonique ;
- une reponse distante contenant a tort une ligne hors dossier ;
- un acces refuse avant tout appel de la table metier ;
- l'equivalence fonctionnelle avant/apres.

Mesure simulee, avec une pagination de 100 lignes et 251 lignes synthetiques :

- avant : 3 appels `queryRecords` et 251 lignes lues dans la table metier ;
- apres : 1 appel `queryRecords` et 1 ligne lue dans la table metier ;
- ligne fonctionnelle selectionnee : identique avant/apres.

Cette mesure demontre la reduction d'appels dans le scenario synthetique. Ce n'est
pas une mesure de latence ou de volumetrie de production.

## Commandes et resultats

- `npm ci --no-audit --no-fund` : OK, 257 dependances installees dans le worktree.
- `node --test server/dossierReadQueries.test.mjs` : OK, 12 tests passes.
- `node --test server/*.test.mjs` : OK, 19 tests passes.
- `npm run test:sync-contract` : OK, 10 tests et 11 contrats verifies.
- `npm run check:critical` : OK, 20/20 controles.
- `npm run build` : OK ; avertissement Vite existant sur un chunk superieur a
  500 kB, sans echec.
- `node --check server/index.mjs` : OK.
- `node --check server/dossierReadQueries.mjs` : OK.
- `git diff --check` : OK.

Une premiere execution des regressions existantes a echoue avant les tests car le
worktree neuf n'avait pas encore `node_modules` (`dotenv` introuvable). Apres
`npm ci`, toutes les commandes ci-dessus ont ete relancees avec succes.

## Limites et besoins d'integration

- Analyse statique : effectuee sur le SHA de base et l'audit fourni en lecture
  seule depuis le repertoire source.
- Reproduction automatisee : effectuee uniquement avec donnees synthetiques et
  services simules.
- Validation appareil : non effectuee. Aucun iPad, Flutter ou appareil reel n'est
  concerne par ce patch serveur.
- Validation NocoDB reelle : non effectuee conformement a l'interdiction d'acces
  production. La syntaxe `where` employee est celle deja utilisee par le client et
  les autres lectures ciblees du projet ; le cas atypique est valide par simulateur.
- La resolution historique `ensureDossierRecord()` peut encore parcourir la table
  `dossiers` complete. Elle est partagee par de nombreuses routes et n'a pas ete
  modifiee dans ce chantier limite aux trois tables metier F09.
- Les lectures internes au generateur PDF (`fetchSanitairesForDossier` et
  `fetchObservationsForDossier`) ne sont pas les trois routes GET actives visees et
  restent hors de ce patch.
- Le module duplique inactif `server/routes/documents.mjs` est hors liste des
  fichiers autorises et n'a pas ete modifie ; `server/index.mjs` porte les routes
  effectivement montees dans cette base.
- Les PUT/PATCH, l'authentification, les documents et le protocole de
  synchronisation sont inchanges.

Le coordinateur devra integrer les trois fichiers serveur ensemble, puis relancer
les tests apres combinaison avec F01 et les corrections de vignettes. Une future
mission distincte peut cibler `ensureDossierRecord()` et les deux lectures internes
PDF sans melanger leurs risques avec ce correctif.

## Relecture et integration du coordinateur - 9 septembre 2026

Les trois fichiers serveur et ce rapport ont ete integres localement dans le
repertoire principal. Le diff de index.mjs reste limite a l'import du helper
et aux trois GET : projections, serialisation JSON, controles d'acces et
gestion des erreurs des routes conserves. La regle latestRecord est identique
a celle du serveur existant ; queryAll transmet bien where a chaque page.
Aucun changement de production supplementaire apporte lors de l'integration.

Quatre tests ajoutes : absence d'UUID canonique, priorite des dates et repli
created_at/Id, erreur de resolution avant lecture metier, et propagation
des erreurs/deadlines NocoDB sans retour null ni nouvelle lecture globale.
Le test de deadline emploie la classe du lot agent 2 deja integre.

Validation combinee des lots serveur 1/2/4/5 : 91 tests Node reussis, dont
16 pour les lectures ciblees ; test:sync-contract reussi ; check:critical
20/20 ; node --check sur index.mjs et dossierReadQueries.mjs reussi.
Les tests ciblent le helper avec services simules ; ils ne constituent pas
un test HTTP de bout en bout des trois routes. Le cas atypique de filtre
est valide par simulateur, pas par le parseur d'une instance NocoDB reelle.
La normalisation REST existante des filtres n'a pas ete modifiee.

Flutter non modifie par ce lot : derniere suite combinee, executee apres
agent 3, a 181 tests reussis et analyse statique sans probleme. Aucun nouveau
build Flutter/Vite/Xcode, aucun acces NocoDB de production, aucune mutation
metier, aucun commit, push ou deploiement. Les cinq retours d'agents sont
integres localement ; cela ne clot pas les autres constats de l'audit.

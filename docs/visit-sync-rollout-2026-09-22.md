# Relevé de visite — état du déploiement atomique au 22/09/2026

Ce document complète `sync-context-atomic-2026-09-17.md`. Il décrit des
constats vérifiés sur les bases réelles, mais n'autorise pas l'activation de la
synchronisation conditionnelle en production.

## État du code

- `9de5bec` branche la revue des conflits du contexte de vie, préserve les
  opérations secondaires sans version serveur et borne l'import de photos.
- `00a66fb` rend le backup NocoDB incrémental afin de ne plus construire un
  JSON de plusieurs gigaoctets en mémoire. Le test couvre la pagination, les
  permissions `0600` et la suppression d'un fichier partiel.
- `d8806d4` ajoute la préparation gardée du staging.
- Le serveur accepte désormais `NOCODB_TABLE_IDS_JSON`, un objet strict qui
  remplace les identifiants de tables par environnement. Cette configuration
  est indispensable : les endpoints NocoDB v2 utilisent des identifiants
  globaux et l'ancien service staging conservait ceux de la production.
- Validation locale : 258 tests serveur et 931 tests Flutter passent.

## Sauvegardes vérifiées

- Production :
  `/Users/aidhabitat/Downloads/aid'habitat-manager/backups/visit-sync-2026-09-22.reGtYE/aidhabitat-2026-09-22_13-03-57-572.json.gz`
  (28 tables, environ 948 Mo).
- Staging après ajout des révisions, avant index SQL :
  `/Users/aidhabitat/Downloads/aid'habitat-manager/backups/conditional-sync-staging-2026-09-22/aidhabitat-2026-09-22_13-20-13-788.json.gz`
  (33 tables, environ 25 Mo).
- `gzip -t` et un parsing JSON en flux ont réussi pour les deux archives.

Ce sont des exports API complets, pas des sauvegardes transactionnelles de
PostgreSQL.

Le 22/09/2026, une sauvegarde PostgreSQL quotidienne à 02:00 a été configurée
dans Easypanel pour la base `apps`, avec le fournisseur `Local Disk` et le
chemin `apps/nocodb-db`. Un dump natif immédiat au format custom a également
été créé dans le conteneur PostgreSQL :
`/tmp/apps-before-conditional-sync-20260922.dump` (environ 100 Mo). La liste du
dump est lisible par `pg_restore`.

Ce dump a été restauré sans erreur dans la base isolée
`apps_restore_test_20260922`. La base restaurée contient 578 tables. Cette
preuve lève le blocage « dump PostgreSQL non restaurable », mais la copie reste
sur le même serveur : une copie hors site est encore nécessaire pour la
protection durable contre une perte complète de l'hôte.

## Staging préparé et vérifié

La base autorisée est exclusivement `p7jzofcton1tabh`. La commande appliquée :

```sh
AIDHABITAT_STAGING_MIGRATION=1 \
  node tools/prepare-conditional-sync-staging.mjs \
  --base=p7jzofcton1tabh --apply
```

Résultat : les sept tables métier possèdent une colonne texte
`app_sync_revision`, et les 19 lignes existantes ont un UUID valide. Les quatre
tables enfants n'avaient ni doublon de `dossier_id`, ni référence vide.

L'API NocoDB ignore l'attribut `un: true` lors de la création d'une colonne :
un test isolé a montré qu'un doublon restait accepté. Les protections ont donc
été créées directement dans PostgreSQL, dans une seule transaction :

```sql
CREATE UNIQUE INDEX aidhabitat_contexte_dossier_uidx
  ON p7jzofcton1tabh.contexte_de_vie_22 (dossier_id);
CREATE UNIQUE INDEX aidhabitat_mesures_dossier_uidx
  ON p7jzofcton1tabh.mesures_anthropometriques_25 (dossier_id);
CREATE UNIQUE INDEX aidhabitat_observations_dossier_uidx
  ON p7jzofcton1tabh.observations_24 (dossier_id);
CREATE UNIQUE INDEX aidhabitat_diagnostic_dossier_uidx
  ON p7jzofcton1tabh.diagnostic_sanitaires_17 (dossier_id);
```

Une relecture de `pg_indexes` a confirmé quatre index uniques. Un test avec deux
écritures concurrentes sur une vraie ligne staging de `Beneficiaires` a eu un
seul gagnant et un rejet, sans changer la valeur métier.

Les 24 identifiants nécessaires au serveur ont été résolus par titre puis
contrôlés individuellement : leurs métadonnées déclarent toutes la base
`p7jzofcton1tabh`. Le service API staging doit définir l'objet complet dans
`NOCODB_TABLE_IDS_JSON` avant son prochain déploiement. Une valeur absente garde
le défaut production ; une clé inconnue, un JSON invalide ou un identifiant non
alphanumérique bloque le démarrage.

Le contrôle Easypanel a découvert que `aidhabitat-api-staging` utilisait encore
`NOCODB_BASE_ID=pskgbjythubfzv9` et les identifiants codés en dur de production.
Le service a été corrigé vers la base staging et les 24 identifiants vérifiés.
L'API et le web staging exécutent le SHA `45d5a68d04cf10e4fad43d6b768f9f1972c878bf` ;
le manifeste web référence l'URL de l'API staging. Après cette isolation, les
deux indicateurs conditionnels ont été activés uniquement en staging et l'API
a retrouvé l'état `ready` en HTTP 200.

## Production préparée partiellement

Après restauration réussie du dump et archivage du doublon, la commande gardée
`tools/prepare-conditional-sync-production.mjs` a ajouté la colonne texte
`app_sync_revision` aux sept tables de la base `pskgbjythubfzv9`, puis rempli
et relu chaque UUID. Le rapport `applied-and-verified` couvre 24 bénéficiaires,
13 logements, 24 dossiers, 11 contextes de vie et 13 diagnostics sanitaires ;
les tables mesures et observations sont actuellement vides.

La base production n'a encore aucune des quatre contraintes uniques sur
`dossier_id`. Les deux indicateurs de synchronisation doivent donc rester
désactivés.

`Diagnostic_sanitaires` comporte deux lignes, Id `23` et `24`, pour le même
`dossier_id`. Elles divergent notamment sur les dimensions des portes de salle
de bain et WC, la hauteur de cuvette et les deux JSON d'instances. Ce n'est pas
le dossier de démonstration d'Anne-Gaëlle.

Comparaison minimale : la ligne 23 contient `76 / 53 / 34` pour largeur porte
SDB / largeur porte WC / hauteur cuvette. La ligne 24 contient `70 / 60 / 42`,
avec les mêmes valeurs dans ses JSON structurés. Les deux ont été créées le
04/08/2026 ; seule la ligne 24 porte une mise à jour au 05/08/2026. Cette
chronologie suggérait une correction ultérieure.

Décision métier confirmée le 22/09/2026 : la ligne `24`, avec les mesures
`70 / 60 / 42`, est la version de référence. La ligne `23` (`76 / 53 / 34`)
a été copiée intégralement dans `public.aidhabitat_sync_archives`, avec la
raison et l'horodatage de la décision, puis retirée des données actives dans
une transaction PostgreSQL. La transaction vérifiait les trois mesures des
deux lignes et leur `dossier_id` commun avant toute suppression.

La relecture par l'API NocoDB utilisée par l'application confirme ensuite :

- ligne `23` absente des données actives ;
- ligne `24` présente avec `70 / 60 / 42` ;
- 13 diagnostics sanitaires actifs ;
- aucun doublon de `dossier_id` ;
- aucun `dossier_id` vide.

Il faut également inventorier les opérations en attente et la version des
trois iPad et cinq postes web. Ne jamais forcer une déconnexion, vider le cache
ou réinstaller l'application pour faire disparaître une file locale.

## Suite obligatoire

1. Copier le dump PostgreSQL vérifié hors du serveur Easypanel et conserver la
   preuve de restauration de `apps_restore_test_20260922`.
2. ~~Archiver la ligne sanitaire `23` et conserver la ligne `24`.~~ Terminé et
   vérifié par l'API NocoDB le 22/09/2026.
3. ~~Contrôler les trois autres tables enfants, puis ajouter et remplir
   `app_sync_revision` sur les sept tables de production.~~ Terminé et relu par
   l'API NocoDB le 22/09/2026.
4. Créer les quatre index uniques SQL après un nouveau contrôle des doublons.
5. Déployer le serveur et les clients compatibles en staging avec les deux
   indicateurs activés, puis réaliser le scénario physique à deux iPad décrit
   dans `sync-context-atomic-2026-09-17.md`.
6. Mettre à jour tous les clients et seulement ensuite répéter la migration et
   activer `AIDHABITAT_CONDITIONAL_SYNC=1`, puis
   `AIDHABITAT_UNIQUE_CHILDREN_READY=1`, en production.

Tant que ces étapes ne sont pas terminées, les deux indicateurs de production
doivent rester désactivés.

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
PostgreSQL. Easypanel ne présentait aucune sauvegarde native configurée pour
`nocodb-db`. Une restauration PostgreSQL doit encore être testée avant la
migration de production.

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

## Blocages de production

La base production `pskgbjythubfzv9` n'a toujours aucune des sept colonnes
`app_sync_revision` et aucune des quatre contraintes uniques sur `dossier_id`.

`Diagnostic_sanitaires` comporte deux lignes, Id `23` et `24`, pour le même
`dossier_id`. Elles divergent notamment sur les dimensions des portes de salle
de bain et WC, la hauteur de cuvette et les deux JSON d'instances. Ce n'est pas
le dossier de démonstration d'Anne-Gaëlle. Aucune ligne n'a été supprimée ou
fusionnée. Une décision métier explicite est obligatoire avant l'index unique.

Il faut également inventorier les opérations en attente et la version des
trois iPad et cinq postes web. Ne jamais forcer une déconnexion, vider le cache
ou réinstaller l'application pour faire disparaître une file locale.

## Suite obligatoire

1. Configurer une sauvegarde PostgreSQL hors site et réussir une restauration
   de test de la base `apps`.
2. Comparer les lignes sanitaires `23` et `24`, conserver ou fusionner les
   valeurs avec validation métier, puis archiver la preuve de décision.
3. Ajouter et remplir `app_sync_revision` sur les sept tables de production.
4. Créer les quatre index uniques SQL après un nouveau contrôle des doublons.
5. Déployer le serveur et les clients compatibles en staging avec les deux
   indicateurs activés, puis réaliser le scénario physique à deux iPad décrit
   dans `sync-context-atomic-2026-09-17.md`.
6. Mettre à jour tous les clients et seulement ensuite répéter la migration et
   activer `AIDHABITAT_CONDITIONAL_SYNC=1`, puis
   `AIDHABITAT_UNIQUE_CHILDREN_READY=1`, en production.

Tant que ces étapes ne sont pas terminées, les deux indicateurs de production
doivent rester désactivés.

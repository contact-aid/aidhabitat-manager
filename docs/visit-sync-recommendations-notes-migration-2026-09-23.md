# Migration de synchronisation — préconisations et notes

Date d'exécution : 23 septembre 2026

## Sauvegardes vérifiées

- Dump PostgreSQL custom :
  `backups/pre-recommendations-notes-2026-09-23/apps-before-recommendations-notes-20260923.dump`
  - taille : 1 062 548 017 octets ;
  - SHA-256 : `e8bbfe579248611220f70f08ddaf30919fa5d13534b088cb70457bf052b08578` ;
  - catalogue `pg_restore` lisible : 4 085 objets ;
  - restauration complète validée dans une base isolée : 579 tables,
    166 notes et 24 anciennes lignes de préconisations.
- Export logique NocoDB compressé :
  `backups/pre-recommendations-notes-2026-09-23/aidhabitat-2026-09-23_07-37-11-638.json.gz`
  - SHA-256 : `01ebefcae38c5f9d5fe6b2b9c25262e512120ec870a7978ee99a561ffd1b0887`.

## Changements appliqués en production

- Ajout additif de `app_sync_revision` à `mobile_note_pages`.
- Attribution d'une révision UUID unique aux 166 notes actives.
- Index unique partiel sur `mobile_note_pages.uuid_source` pour les lignes
  actives.
- Création de `mobile_visit_recommendation_snapshots`, une ligne atomique par
  dossier.
- Index unique partiel sur le `dossier_id` actif de cette nouvelle table.
- Conversion des 24 anciennes lignes de préconisations en 9 snapshots, sans
  supprimer ni modifier la table historique.
- Les images `data:` de la bibliothèque ne sont pas dupliquées dans les
  snapshots ; l'API les recharge depuis la bibliothèque à la lecture.

État contrôlé après migration : 166 notes, 9 snapshots et aucune ligne de test
temporaire. Les neuf snapshots passent la vérification de hash.

## Nouveau contrat client–API

Les notes et la liste complète des préconisations utilisent désormais :

- `expectedRevision`, la version lue avant l'édition ;
- `writeId`, un UUID durable conservé pendant les reprises réseau ;
- une écriture conditionnelle atomique côté PostgreSQL/NocoDB ;
- un conflit HTTP 409 si un autre appareil a déjà avancé la version ;
- une confirmation par relecture avant de marquer l'opération synchronisée.

Une ancienne opération locale dépourvue de ces informations est placée en
conflit visible. Elle n'est jamais rejouée comme une écriture inconditionnelle.

## Tests exécutés

- 263 tests serveur : OK.
- 12 tests de contrat de synchronisation : OK.
- 935 tests Flutter : OK.
- Analyse Dart : aucune erreur.
- 20 contrôles de parcours critiques : OK.
- Audit live data/sync : 0 erreur bloquante, 40 contrôles OK.
- Builds React et Flutter PWA de production : OK.
- Test réel notes avec deux appareils simulés : A écrit, B partant de la même
  révision reçoit un conflit 409 ; donnée temporaire supprimée.
- Test réel préconisations avec deux appareils simulés : même résultat ;
  snapshot temporaire supprimé.

## Déploiement et retour arrière

Le schéma est déjà compatible en avance et la table historique est conservée.
Le serveur et le client doivent être publiés ensemble depuis le même commit.
En cas de retour arrière applicatif, l'ancien code peut continuer à utiliser la
table historique ; les nouvelles colonnes et la table de snapshots peuvent
rester présentes, car elles sont additives. Ne pas supprimer la table
historique avant une période d'observation validée sur les iPad et ordinateurs.

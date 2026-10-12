# App’Ergo — candidat web 1.0.0+67 (5 octobre 2026)

## Périmètre et base

Base commune vérifiée après `git fetch origin` :
`96a2a416878aa32a0899c6d5a51061f35a7a833e`, web publiée 1.0.0+66.
Branche d'intégration : `codex/appergo-web-candidate-20261005`.
Chaque intervenant a utilisé son propre worktree. Le checkout historique dans
Downloads est conservé avec ses modifications non publiées.

| Lot | Décision | Changements autorisés |
| --- | --- | --- |
| Assist 1 — Foyer / Occupation | Intégré et relu | Déplacement de personnes présentes, téléphone et email de confiance, envoi du rapport ; mêmes valeurs, validations et sauvegardes |
| Assist 2 — Environnement social | Intégré et relu | Quatrième case médicale, numéro 4, via le stockage existant des notes par occupant et page |
| Main — CARSAT | Exclu du candidat | Préparation additive et simulation dans une branche distincte ; vraie ligne du référentiel partagé requise avant activation |

Commits reçus : Assist 1 `9057029b3c6e799510c8ff0c2ab300df39f60c19`, Assist 2
`635128415f1bf35b86c1b57ad7e5eb0b4bf83e0c`. Cherry-picks sans conflit.

CARSAT : branche `codex/carsat-preparation-20261005`, commit
`286c0d5a028b4f6d678f8f9dfe98126f35a9b385`. Six tests fictifs réussis.
Aucune écriture NocoDB de production, ni adaptateur de production exécuté.
La prévisualisation `local-preview-carsat` reste exclusivement dans la préparation.

## Contrôle du périmètre

La relecture porte sur le diff depuis la base ci-dessus. Seuls les deux écrans,
leurs tests ciblés, la version web et ce document sont autorisés. Aucun import
global des fichiers du checkout historique. Les modèles d'occupants, mandats,
plans, services de synchronisation, schéma NocoDB, code natif et serveur doivent
être strictement identiques à cette base.

## Vérifications

| Vérification | Résultat |
| --- | --- |
| Flutter analyze complet, Flutter 3.38.4 / Dart 3.10.3 | 0 problème |
| Tests Flutter ciblés des deux lots + régressions voisines | 26/26 |
| Suite Flutter complète après intégration | 1025/1025 |
| Suite critique synchronisation (`test_sync_critical.sh`) | 746/746 |
| Suite serveur (`npm run test:server`) | 325/325 |
| Contrats de synchronisation (`test:sync-contract`) | 12 tests et 11 éléments autonomie vérifiés |
| Parcours critiques (`check:critical`) | 20/20 |
| Outillage de traçabilité/publication web | 20/20 |
| Préparation/readiness synchronisation, fixtures seulement | 11/11 |
| TypeScript (`tsc --noEmit`) | Réussi |
| Passerelle vocale existante, sans modification | 3/3 |
| Génération PDF de non-régression | 3 variantes fictives générées ; aucune validation des dossiers réels |

La suite serveur et les scripts métier n'ont aucun fichier modifié par les lots.
Les tests ont été exécutés sans fichier `.env` ni jeton NocoDB/Airtable dans le
worktree. Le test Flutter intégré passe par de vraies bases SQLite temporaires.
Le contrôle des empreintes des 68 fichiers modifiés/non suivis historiques ne
signale aucun changement dans le checkout principal.

## Artefact et traçabilité

Le numéro 67 a été recherché dans les branches/tags locaux et distants, les
constructions web GitHub récentes et la version publiée : aucun usage observé
avant cette préparation (dernier build publié : 66). Ce numéro n'est pas une
réservation globale : vérifier de nouveau avant publication différée.

Le format attendu de l'artefact local contient `version.json` (1.0.0 / 67), `release.json`
(SHA du commit exact et SHA-256 de `main.dart.js`) et être accompagné de son
empreinte SHA-256 et des logs. `check-web-release.mjs` vérifie ces valeurs.
Le bundle utilise l'API habituelle `https://api.aidhabitat.fr` ; sa construction
n'appelle pas cette API. Ne pas ouvrir des dossiers réels pour y faire des essais.

## Prérequis de publication et limites

- Relire le diff et valider les deux petits lots sur l'artefact candidat.
- Vérifier la stabilité de `origin/main`, le numéro de build et les empreintes au
  moment de publier. Toute reconstruction doit fournir sa propre preuve.
- Publication de l'image et déploiement nécessitent une demande explicite ultérieure.
- CARSAT reste exclu jusqu'à autorisation et contrôle de l'ajout réel au référentiel.
- Comportement médical préexistant conservé : un clic propage les coches de
  l’occupant aux pages connues de la note, même si le stockage est par page.
- Les tests de sauvegarde utilisent des données fictives ; ils ne constituent pas
  une nouvelle validation terrain de l'iPad ni des PDF des visites réelles.
- Le build iPad installé 1.0.0 (64) reste inchangé. Aucun build iPad n'est préparé.

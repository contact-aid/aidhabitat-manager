# App’Ergo — candidat web 69 (5 octobre 2026)

## Base et coordination

- Production web68 : `cc9b7ccedf1e0bf0e0eb97d9eb12e7d03a3fc470`, relue dans le bilan et le manifeste public.
- `origin/main` : `96a2a416878aa32a0899c6d5a51061f35a7a833e`, antérieur à la production ; PR21 ouverte. La PR69 est empilée sur `codex/appergo-integration-20261005` afin de ne montrer que ce nouveau travail. Ne pas fusionner sur un main ancien en oubliant la livraison68.
- Main : `codex/appergo-major-web-candidate-20261005`, worktree dédié. Propriétaire exclusif du modèle, repository, adaptations Airtable, mappers serveur et générateur PDF. Repository et Airtable finalement inchangés.
- Assist1 : `codex/mobility-aids-multiple`, livraison `750a7dea15ce68afd15e565564b25e6b3954ca33` relue et intégrée.
- Assist2 : `codex/sanitary-rooms-multiple`, livraison `ab53a858c5e3ec83bb1d8cab4f43f3d05af0eaa3` relue et intégrée ; revue croisée du lot occupants, deux corrections d'alerte intégrées et testées.
- Chaque tâche a utilisé son propre worktree depuis cc9b7cc. Checkout historique préservé (HEAD `5d15e4989ef88bc90bb7959eb1ff5985174560d7`, empreintes des 69 fichiers modifiés/non suivis inchangées).
- Numéro69 absent de toutes les branches/tags inventoriés et des tags GHCR publics ; 67 existe déjà localement, 68 est publié. Preuve dans le dossier d'artefacts externe.

## Fonctionnalités retenues

### Web

Affichage en lecture d'une ligne par occupant, civilité connue et nom de naissance déjà enregistré ; pluriel des titres et en-têtes adaptés. Séparation de noms regroupés uniquement en présentation et uniquement pour les deux formes certaines documentées dans `occupants-build64.md`. Identités contradictoires signalées, valeurs d'origine visibles. Aucune conversion ni sauvegarde déclenchée à l'ouverture/réouverture. Le modèle conserve `maidenName` lors d'une autre modification web ; absence et vide explicite restent distincts.

**Le formulaire d'édition actuel reste celui de68.** Il n'y a pas de nouvelle ligne éditable Nom/Prénom/Civilité ni de bouton d'ajout/retrait dans ce candidat.

### API/PDF — publication API distincte requise

- Lecture de la dépendance : texte existant non vide prioritaire sur un ancien lien de référence ; sinon comportement de repli historique. Écriture/référentiel inchangés.
- PDF mobilité : toutes les aides reçues, inconnues incluses, sont restituées sans déduction par sous-chaîne. Liste courte ajustée dans le champ ; texte long en annexe lisible ; vide explicite reste vide. Symboles non encodables rendus sous forme `[U+…]` plutôt que supprimés ou erreur de génération.
- PDF sanitaires : annexe paginée pour les informations de plusieurs pièces omises par le tableau historique (notamment quatrième pièce et observations secondaires). Toutes les instances conservées dans l'ordre, niveaux/mesures/observations, sans ID technique. Aucun changement de données. Diagnostic absent/null toléré.
- Pagination et page Morbihan conservées, test combiné des deux annexes ; dates/civilités et variantes ergo/technicien testées.

Les appels des deux fichiers `.patch` livrés par les assistants sont **déjà intégrés** dans le générateur ; ces fichiers sont des traces de coordination et ne doivent pas être réappliqués.

## Écarté pour incompatibilité64 démontrée

1. Nouvelle édition multi-occupants, ajout/retrait avec confirmation, saisie du nom de jeune fille, conversion persistée des identités et nouvelle reprise du genre Airtable.
2. Sélection de plusieurs aides à la mobilité.
3. Ajout de plusieurs salles de bain/WC au même niveau.

Les tests historiques passent en caractérisant volontairement les pertes : modèle64 éliminant les champs inconnus ; reconstruction des occupants selon un nombre ancien ; clic monochoix remplaçant une liste d'aides ; sanitaires réduits à la première pièce du niveau. Les vraies routes API testées sur NocoDB simulé acceptent des listes anciennes qui suppriment un ajout web ou rétablissent une suppression volontaire. Une baseline seule, avec priorité à la dernière écriture locale, ne résout pas ce problème. Il faut un futur client iPad et un contrat de fusion/suppression explicite à valider ensemble. Aucun nouveau binaire n'est construit ici.

## Validations effectuées

- Analyse Flutter de l'application : zéro problème.
- Tests ciblés occupants : 17/17 ; tests SQLite et navigation réelle simulée inclus.
- Suite Flutter intégrée : 1 058/1 058.
- Synchronisation critique : 746/746, TMPDIR isolé.
- Suite serveur : 349/349 ; une régression `sanitaires=null` détectée puis corrigée avant ce résultat.
- Contrats synchronisation : 12/12 et 11 éléments vérifiés. Flux critiques : 20/20. TypeScript réussi. Garde-fous publication : 40/40.
- Sources exactes64 exportées sans modification : 3 tests occupants, 9 mobilité, 6 sanitaires. Les scénarios bloquants sont explicitement nommés, ce ne sont pas des validations de la fonctionnalité multiple.
- PDF : 24 tests ciblés des lots et routes, puis scénario combiné réel ; trois PDF fictifs générés. Rendu inspecté des champs mobilité et des annexes, absence de troncature sur les exemples. Aucun rapport de visite réelle généré/validé.
- CI reçoit seulement Poppler pour les nouveaux contrôles PDF ; aucune modification des autorisations de publication/déploiement.

## Diff et publication

Aucun changement des notes indépendantes, CARSAT, mandats, plans, dictée, scan portrait, filtre stylet, schéma NocoDB, moteur de synchronisation ou repository. Aucun nouvel import ni migration de données. Les fichiers serveur de la base cc9b7cc sont identiques à ceux de l'API publiée `0d9728c965ce0ef81cafdb00e40ce949f51e2e74` ; le diff API du candidat est donc isolable.

La construction web69 et la PR sont autorisées ; publication d'image, déploiement API/web et iPad ne le sont pas. L'artefact web seul n'active pas les améliorations PDF. La publication ultérieure exige : revue de cette portée réduite, traitement de la PR21/base de fusion, recette visuelle utilisateur, accord explicite pour les déploiements requis et vérification des SHA/version/digests/retour arrière. Les trois fonctionnalités complètes restent à traiter avec le futur client iPad.

Limites : aucune recette physique sur les iPad de Coralie/Christelle, aucun NocoDB de staging réel utilisé (mocks et SQLite fictifs), aucune preuve nouvelle de synchronisation en production. Police de l'annexe sanitaire limitée à WinAnsi (les glyphes hors jeu deviennent `?`, texte source intact). Les PDF réels restent non validés. Empreintes finales et résultats CI dans le bilan externe du candidat.

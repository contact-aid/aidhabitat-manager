# App’Ergo 1.0.0+71 — candidat complet, 5 octobre 2026

## Base et isolation

Production de départ : web/API69 `e8a4459d5066b8ac4cc5e8a0212a1f29bf97433f`.
Base de cette intégration : candidat récupération `150b555ca2c26a0869ae9e34fa4892c68df944ac` (PR24).
Branche : `codex/appergo-full-delivery-20261005`, worktree dédié `appergo-full-delivery`.
Le checkout principal est préservé. Les prototypes y ont été inventoriés et repris sélectivement.
Le périmètre initial à trois lots a été élargi par la demande humaine adressée à Audit le 5 octobre : intégrer les modifications locales pour web et TestFlight aujourd’hui/demain.

## Fonctionnalités retenues

- Bénéficiaires/occupants : lignes Nom, Prénom, Civilité, nom de naissance ; confirmations d’ajout/retrait ; titres pluriels et identité regroupée lisible. Civilité inconnue affichée vide. Reprise Airtable seulement si explicite ; anciennes identités séparées seulement lorsqu’elles sont certaines. Cas ambigus conservés et signalés. Aucune sauvegarde à la simple ouverture.
- Plusieurs aides à la mobilité, avec conservation des valeurs anciennes et inconnues. Restitution PDF69 conservée, y compris annexe pour les textes longs.
- Plusieurs salles de bain/WC par niveau, identités stables, observations/mesures propres à chaque pièce, retrait par identité. Les associations historiques ambiguës et JSON illisibles sont conservés. Annexe sanitaire PDF69 conservée.
- Notes dossier et Bénéficiaire indépendantes : mêmes textes à l’import initial, initialisation gardée des notes vides, effacement volontaire persistant, conservation des dessins, des textes iPad et des révisions. Outil de préparation séparé ; aucune reprise de dossiers réels exécutée.
- Plans : pages vides, scénarios et duplication complète vers un nouvel identifiant, sans renumérotation ; main/pincement, rectangle et équipements tracés. Pages anciennes partiellement illisibles ou images protégées en lecture seule.
- Mandats : génération locale conditionnelle pour le compte connecté, reconnaissance des mandats historiques ; import immuable par identité dossier/compte. Un document déjà annoté ou différent n’est jamais remplacé automatiquement.
- Dictée web : amélioration du démarrage et des erreurs ; scanner iPad autorisé en portrait ; politique stylet iOS et tests de gestes. Ces modifications nécessitent encore une recette sur appareil.
- Foyer/Occupation, Environnement social, navigation Documents/Relevé et PDF Morbihan déjà publiés sont conservés. Le générateur PDF local plus ancien n’a pas été repris.

## Écartés ou limités

- CARSAT : outils de préparation seulement ; aucune option fictive publiée, aucune création dans le référentiel. Une entrée CNAV/CARSAT existe déjà ; choix métier encore à confirmer avant toute opération additive.
- Suppression de pages de plans : désactivée. Aucun contrat de tombstone protégeant de la résurrection par64 n’est validé ; la renumérotation destructive du prototype n’est pas reprise.
- Plans de format inconnu : conservés, pas convertis automatiquement.
- Aucun transfert de données de test, migration, purge ou réécriture générale des dossiers ; aucune modification du schéma NocoDB.

## Coexistence des clients

Les preuves exécutées sur le code exact64 `a5b4d9fbe40579160a9290688a7707e7a3376c2c` montrent des pertes possibles lors d’édition des collections enrichies. Le build minimal70 hérite de ces anciennes interfaces. La coexistence transparente en écriture n’est donc pas promise.

Le serveur refuse les anciennes mutations d’occupants/mobilité/pièces avec `409 COLLECTION_CLIENT_UPGRADE_REQUIRED`. Le client garde l’opération en attente ; le transport ne lui ajoute jamais rétroactivement la capacité `collections-v2`. Le nouveau client propose une revue explicite du conflit, conserve l’ancien payload et crée une nouvelle écriture identifiée après choix. Les opérations de collection ne sont pas résolues automatiquement par date. Les champs simples, notes et documents restent hors de cette garde.

Les nouveaux clients comparent les valeurs observées et la révision serveur. Les vrais payloads d’un diagnostic sparse ont révélé un conflit injustifié : les colonnes scalaires dérivées sont désormais normalisées de façon identique pour la baseline et la valeur observée ; les JSON restent exacts et le conflit concurrent demeure refusé.

Pièces logement et diagnostic : transaction SQLite commune pour la liaison explicite, mais deux écritures CAS serveur, sans transaction distribuée. Mandats : verrou par identité dans un processus ; conserver un seul processus/replica sans déploiement chevauchant, ou ajouter une exclusion distribuée avant changement de topologie.

## Incident Christelle — séparé et ouvert

Le build70 est le client minimal de récupération, signé et disponible en test interne dans App Store Connect. Cela ne prouve ni sa version installée sur l’iPad ni la sauvegarde de l’appareil.
Le plan et la note Résumé sont encore à récupérer/vérifier. L’erreur500 n’est pas expliquée par un simple refus des gros contenus. La note Résumé locale diffère du contenu et de la révision serveur : aucune reprise automatique sur la nouvelle révision.
Ordre de récupération : sauvegarde chiffrée vérifiée, serveur corrigé, mise à jour sans désinstallation, conservation des contenus locaux, diagnostic des deux opérations, transfert approprié puis comparaison des textes/dessins/empreintes. Ne pas déclarer l’incident clos avant ces preuves.

## Vérifications et publication

Les journaux, PDF fictifs et empreintes sont archivés dans `AppErgo-livraison-complete-20261005` hors dépôt. Les résultats définitifs et artefacts sont consignés dans son bilan après construction.
Tests : analyse Flutter, suite complète et contrôles synchronisation, routes HTTP avec stockage fictif, code exact64, rapports PDF fictifs rendus et inspectés. Aucun rapport réel de Coralie ou Christelle n’est déclaré validé.
Prévol production en lecture seule : protections conditionnelles actives et révisions renseignées sur les sept tables métier. La preuve des quatre index uniques SQL date du22septembre ; le5octobre, leurs métadonnées NocoDB ne remplacent pas une relecture SQL.

Prérequis de bascule : tests/CI du SHA final, serveur protégé avant nouvelles saisies web/iPad, retour arrière identifié pour chaque service, organisation de la revue des files64/70, sauvegarde chiffrée de l’iPad avant installation. Les gestes Pencil, caméra portrait, micro et reprise sur appareil physique restent à contrôler. Aucun effacement de données n’est une procédure de retour arrière.

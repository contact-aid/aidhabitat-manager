# Assist 1 — contrats et conservation des données, 5 octobre 2026

Base convenue avec Main : `150b555ca2c26a0869ae9e34fa4892c68df944ac`.
Branche isolée : `codex/assist1-data-contracts-20261005`.
Aucun changement du checkout principal, de version, de schéma NocoDB,
aucune écriture de production, migration, purge, construction iPad ou livraison.

## Lots transmis

- `f7bb283` : notes indépendantes, initialisation gardée et tests ; conserve les
  verrous d'identité/groupe et les révisions strictes du correctif récupération.
- `b03c680` : contrat `concurrency.collectionContract = collections-v2`, garde
  serveur à intégrer par Main, reprise explicite des anciennes files et helper
  de sélection des aides à la mobilité (chaîne historique conservée).
- `f47b18f` : identité des pièces logement et lien vers les diagnostics sanitaires.
- `1080038` : import initial mandat immuable, sérialisé par identité dans un
  processus ; réponse perdue et concurrence testées sur adaptateur réel/IO fictif.
- `d4d34d7` : lecture isolée des pièces illisibles, signalement et sauvegarde bloquée.
- `1cd9e09` : lecture exhaustive des pages locales, duplication complète à max+1,
  sauvegarde atomique préservant texte/portée/aperçu et transport du texte séparé.
- Dernier complément : liaison sanitaire conservative depuis le snapshot AVANT
  une édition explicite du logement et suppression par identité sur le JSON brut.

## Coexistence 64 / 70 / nouveau client

La preuve antérieure sur le code exact 64 reste applicable : son sélecteur réduit
une aide multiple à une seule ; ses écrans sanitaires réduisent les occurrences.
Une référence fraîche ne rend pas ces éditeurs capables d'éditer ces collections.
Ce lot ne prétend donc pas offrir une coexistence transparente en écriture.

La garde doit refuser les anciennes mutations de collections avec 409
`COLLECTION_CLIENT_UPGRADE_REQUIRED`. Les notes/documents et champs simples
restent hors de cette garde. Main possède son intégration dans les routes ainsi
que les écritures CAS strictes, y compris quand l'ancien mode de synchro est actif.
Le helper seul n'autorise jamais une écriture : le contrôle de version reste requis.

Le transport n'ajoute aucun marqueur à une ancienne file. Une édition fusionnée
avec une ancienne opération ne lui donne pas non plus ce marqueur. Le nouveau
client conserve le payload, lit les valeurs serveur et montre la comparaison.
Le choix explicite crée un nouveau writeId/une référence relue et archive le
payload d'origine dans `sync_conflict_history`. Les mutations de collections
sont exclues de la résolution automatique par horodatage.

## Pièces et diagnostics

L'API conserve les listes de libellés dans `roomsBreakdown` et ajoute `_roomIds`
comme table des identités par niveau. Les JSON SQLite existants peuvent conserver
les objets `{id,label}` ; aucun ajout de colonne. Les libellés historiques restent
lisibles. Les identités legacy déterministes ne sont persistées que lors d'une
édition. Les nouvelles pièces reçoivent un UUID. Les clés second_floor/secondFloor
et third_floor/thirdFloor sont normalisées pour les identités legacy.

Avant une édition explicite du logement, le dépôt peut lier les diagnostics sans
lien aux pièces du snapshot précédent, uniquement si les quantités par type/niveau
correspondent exactement et si les liens existants sont uniques et valides.
Sinon, aucune association n'est devinée. Les deux opérations sont conservées dans
la même transaction SQLite ; leur livraison serveur reste deux écritures CAS,
pas une transaction distribuée logement/diagnostic.

La suppression explicite filtre les identifiants exacts dans le JSON brut, sans
réencoder les objets restants à travers un modèle réduit. Les champs inconnus,
observations et mesures restent intacts. Aucune suppression par compte/position.

## Plans et notes

`fetchLocalNotePages` lit toutes les pages triées, y compris les trous et numéros
supérieurs à 100, sans écriture. `duplicateLocalNotePage` alloue un nouveau numéro
sans modifier les originaux et conserve texte, dessin, phase et aperçu disponible.
La copie d'un aperçu distant sans raster local est refusée avec explication ;
l'interface doit fournir l'aperçu rasterisé. Une page blank garde sa phase null.
Le premier trait après duplication conserve texte, portée et aperçu précédents.

La suppression de plans n'est pas livrée ici : aucun tombstone anti-résurrection
par les clients installés n'a été validé. Main/Assist2 ont convenu d'une désactivation
ciblée du bouton. Aucune renumérotation ni suppression physique n'a été ajoutée.
Le lot notes indépendantes ajoute son marqueur aux vraies sauvegardes, jamais
à la simple ouverture. Un dessin JSON vide legacy est couvert.

## Mandats

Premier import existant conservé : même contenu → même identifiant/URL sans
réécriture ; contenu différent ou annoté → 409 `DOCUMENT_IMPORT_ALREADY_EXISTS`,
sans accusé trompeur qui supprimerait la copie locale. Le stockage vérifie aussi
le dossier. Main possède la validation d'autorisation des trois routes ; Assist2
utilise le hash de l'email canonique du compte dans l'identité déterministe.
Le verrou est limité à un processus, pas distribué. La topologie de production
reste à la charge de Main. Aucune purge des doublons historiques.

## Vérifications fictives

- Serveur complet : 364 tests réussis sur cette branche avant dernier complément
  Flutter (aucun changement serveur après cette exécution).
- Contrats/reprise de file : 44 tests Flutter, puis 6 tests transport/mobilité.
- Pages, notes, données illisibles et transport : 13 tests Flutter réussis.
- Liaison sanitaire avant édition, suppression exacte, aller-retour SQLite et revue
  de conflits : 18 tests Flutter réussis.
- Analyse ciblée des 13 fichiers modifiés du lot pages/notes : aucun problème.
- Mandats : 4 tests de l'adaptateur réel avec toutes les IO substituées, couvrant
  deux appareils, réponse perdue, contenu chunké, annotation et séparation comptes.

Ces résultats ne sont pas des essais physiques sur les iPad ni une validation de
la production. La suite globale intégrée, les routes HTTP et l'interface relèvent
de Main/Assist2. Aucun PDF réel n'a été généré par ce lot et le générateur PDF
n'a pas été modifié ici.

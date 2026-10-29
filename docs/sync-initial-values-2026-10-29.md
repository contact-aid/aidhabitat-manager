# Synchronisation des valeurs initiales, 29 octobre 2026

## Problème et correction

Le build 105 pouvait demander un choix entre une saisie de visite et une valeur
serveur encore initiale, en particulier lorsque la référence ancienne du champ
manquait ou ne correspondait plus au serveur.

La comparaison reconnaît désormais explicitement les valeurs initiales :

- aides techniques vides face à une réponse telle que « Aucune » ;
- détails d’un même occupant vides face à une réponse renseignée (aides,
  informations administratives, retraites, détails APA/invalidité) ;
- présence d’un niveau à `false` face à `true` ;
- pièces par niveau toutes vides face à une liste renseignée, avec conservation
  des pièces répétées et de leurs identifiants.

La valeur renseignée est retenue dans les deux sens. Pour ces seuls champs,
une valeur initiale ne remplace donc pas une réponse renseignée, même si une
ancienne référence manque. « Aucune » est une réponse renseignée.
Les nombres, les choix booléens à trois états, les notes et les autres
collections ne sont pas assimilés à des valeurs initiales.

Les occupants sont comparés par propriétés après vérification de l’identité
complète, de l’ordre, du nombre et de l’absence de doublons. Deux réponses
renseignées différentes restent un conflit sans référence permettant de les
départager. Un changement de composition ou une propriété inconnue ne donne
aucun droit supplémentaire d’écrasement.

## Conflits déjà stockés

Le cycle de synchronisation réexamine les conflits de contenu même lorsque
certaines références de champs manquent. Il relit les valeurs serveur et
applique le même plan. Si la comparaison réussit, les deux versions sont
archivées localement et une nouvelle mutation conditionnelle est créée.
Les anciennes mutations sans contrat de collection restent soumises à une
comparaison explicite. Les écritures logement supplantées restent bloquées.
Aucune opération locale n’est supprimée.

Le serveur applique également la règle sur son chemin conditionnel strict.
Un changement concurrent de révision provoque une nouvelle comparaison.
Les modifications indépendantes mixtes d’occupants passent par la reprise
client pour conserver une copie locale identique à la mutation acquittée.

## Livraison

Correction préparée pour une prochaine mise à jour. Aucun numéro de build
n’est réservé ici. Aucun déploiement API/web ni envoi TestFlight effectué.
La recette du dossier témoin reste nécessaire avant diffusion selon
`docs/protocole-version-stable.md`.

## Validation automatisée

- 965 tests Flutter critiques réussis, dont reprise SQLite de conflits patient
  et logement déjà stockés avec références de champs absentes.
- 545 tests serveur réussis, dont changement concurrent d’une liste de pièces
  pendant la tentative d’enrichissement d’une valeur initiale.
- Contrats de synchronisation et 20 contrôles de flux critiques réussis.
- Analyse statique des trois fichiers Dart concernés sans anomalie.

Les scénarios utilisent exclusivement des identités et données fictives.

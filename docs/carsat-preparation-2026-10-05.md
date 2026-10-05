# CARSAT — préparation indépendante du candidat web

Base : `96a2a416878aa32a0899c6d5a51061f35a7a833e` (web 66).

## État et décision

Le proxy du checkout historique ajoute seulement une option de prévisualisation
`local-preview-carsat`. L'API charge le référentiel `Caisses_de_retraite` et
résout la sélection vers sa clé réelle (`caisses_de_retraite_id`). Un identifiant
fictif ne constitue donc pas une fonctionnalité publiable. Le candidat web 67
n'embarque ni cet ajout fictif ni ces outils : ce lot reste dans sa branche séparée.
Aucune consultation ni écriture NocoDB de production n'a été nécessaire ici.

## Opération préparée

`tools/prepare-carsat.mjs` produit un plan vérifiable pour ajouter uniquement
`{ "nom": "CARSAT" }`. Aucune mise à jour, suppression ou modification de schéma.
Le plan comprend l'empreinte du référentiel ; un changement avant application
bloque l'opération. Une caisse déjà présente (casse/espaces ignorés) conserve sa
clé et toutes ses valeurs ; la réapplication est sans effet. Des doublons ou une
CARSAT régionale ambiguë demandent un examen manuel.

Le simulateur accepte exclusivement un fichier marqué `environment: synthetic`.
Il n'importe pas dotenv, ne lit aucun jeton et ne possède aucun transport réseau.
Un verrou exclusif protège les applications concurrentes sur le fichier, remplacé
atomiquement. Les identifiants créés dans la simulation sont fictifs.

Exécution reproductible, depuis cette branche :

```sh
node --test tools/prepare-carsat.test.mjs
mkdir -p /tmp/appergo-carsat-review
cp tools/fixtures/carsat/principal-funds.synthetic.json /tmp/appergo-carsat-review/funds.json
node tools/prepare-carsat.mjs plan --fixture /tmp/appergo-carsat-review/funds.json > /tmp/appergo-carsat-review/plan.json
cat /tmp/appergo-carsat-review/plan.json
node tools/prepare-carsat.mjs apply --fixture /tmp/appergo-carsat-review/funds.json --plan /tmp/appergo-carsat-review/plan.json
node tools/prepare-carsat.mjs apply --fixture /tmp/appergo-carsat-review/funds.json --plan /tmp/appergo-carsat-review/plan.json
```

Résultat : 6 tests réussis ; premier passage `created: true`, second `false`.
La prévisualisation historique est également testée : ajout unique, tri,
préservation d'une vraie entrée existante et absence de mutation du payload reçu.

## Prérequis pour le référentiel partagé

1. Autorisation explicite d'une écriture additive en production.
2. Lire le référentiel principal réel au moment de l'opération ; vérifier absence,
   doublons et références régionales. Confirmer la cible et conserver son état.
3. Réaliser la même opération contrôlée avec l'API de maintenance autorisée,
   en période sans autre création concurrente. Le verrou du simulateur ne prétend
   pas fournir une transaction distribuée NocoDB ; aucun nouvel index n'est requis.
4. Créer uniquement `nom=CARSAT` si absent, puis relire la clé réelle et vérifier
   que les autres caisses sont inchangées. Ne pas réessayer une création dont
   la réponse est incertaine avant cette relecture.
5. Vérifier en staging la sélection/sauvegarde/réouverture avec cette vraie clé,
   puis le rafraîchissement du référentiel web et sa compatibilité avec l'iPad 64.

L'adaptateur de production et cette vérification sur base réelle restent hors
périmètre de cette préparation. Aucun build iPad, image ou déploiement.

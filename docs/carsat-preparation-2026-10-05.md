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

À ce stade initial, l'adaptateur réel et la vérification sur base réelle
restaient à faire. Aucun build iPad, image ou déploiement.

## Adaptateur réel préparé ensuite

`tools/carsat-nocodb.mjs` est désormais un adaptateur réel, séparé du simulateur.
Il n'importe aucun fichier d'environnement automatiquement : fournir explicitement
`NOCODB_API_URL` et `NOCODB_API_TOKEN`. La commande `plan` lit les métadonnées
et toutes les lignes du référentiel ; la commande `apply` sans `--apply` reste
une lecture de contrôle. Le plan contient la base, la table, l'empreinte et un
UUID d'opération. Un changement du référentiel bloque la création.

```sh
# Exemple staging, sur une base de staging effectivement accessible :
node tools/carsat-nocodb.mjs plan --environment staging --base ID_STAGING > plan-staging.json
node tools/carsat-nocodb.mjs apply --environment staging --base ID_STAGING --plan plan-staging.json
CARSAT_ALLOW_APPLY=1 node tools/carsat-nocodb.mjs apply --environment staging --base ID_STAGING \
  --plan plan-staging.json --apply --exclusive-window-confirmed

# Production, seulement après preuve staging et sauvegarde du référentiel :
node tools/carsat-nocodb.mjs plan --environment production --base pskgbjythubfzv9 \
  --snapshot fonds-prod-avant.json > plan-prod.json
CARSAT_ALLOW_APPLY=1 node tools/carsat-nocodb.mjs apply --environment production --base pskgbjythubfzv9 \
  --plan plan-prod.json --snapshot fonds-prod-avant.json --apply \
  --staging-verified --exclusive-window-confirmed
```

La création utilise exclusivement `{ nom: "CARSAT", uuid_source: <UUID du plan> }`.
Elle relit ensuite le référentiel, vérifie l'ID réel et l'intégrité des lignes
antérieures. La réapplication d'un même plan reconnaît l'UUID sans recréer.
En cas de réponse HTTP incertaine, la relecture confirme ou refuse le résultat.
Le drapeau de fenêtre exclusive est une attestation opérateur : il ne fournit
pas de transaction distribuée ni d'index unique NocoDB.

Lecture seule le 5 octobre 2026 : la production expose `Caisses_de_retraite`
dans la table `mxmsm320nnljdmm` de la base `pskgbjythubfzv9`, avec 13 lignes.
La ligne 3 est `CNAV (Assurance retraite / CARSAT)` ; aucune ligne exacte
`CARSAT` n'existe. Les deux libellés devront rester distincts dans l'interface
tant qu'aucune décision métier de rapprochement n'a été prise. La base staging
historique `p7jzofcton1tabh` renvoie actuellement HTTP 404 avec le jeton local ;
aucune écriture staging ou production n'a été effectuée.

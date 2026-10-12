# Aides à la mobilité : frontière du lot compatible iPad 64

## Sources et décision

- Base commune, web 68 : `cc9b7ccedf1e0bf0e0eb97d9eb12e7d03a3fc470`.
- Code exact iPad `1.0.0+64` : `a5b4d9fbe40579160a9290688a7707e7a3376c2c`.
- La saisie multiple est **différée**. Aucun changement du sélecteur, du modèle,
  du stockage, de la file de synchronisation ou du protocole dans ce lot.
- Livrable sûr : restitution PDF en lecture seule des valeurs déjà présentes,
  conservation des libellés inconnus, suppression des doublons d'affichage,
  annexe lisible si la liste dépasse la place disponible.

## Format réellement utilisé

`Occupant.dependenceTxt` et `Patient.dependenceTxt` sont des chaînes. Le build 64
les relit sans découpage depuis `dependence_txt` et `occupants_json`, puis les
sérialise sans conversion. L'écran conserve `occ.dependenceTxt` dans son état.
Il compare son instantané aux valeurs sauvegardées avant de produire un delta.
La file SQLite conserve les mises à jour destinées au PATCH bénéficiaire.

Le serveur stocke le texte libre dans `dependance_particuliere_txt` et conserve
une relation singulière `dependances_particulieres_id`. Aucun tableau JSON ni
nouveau format de stockage n'est introduit. La séparation virgule/point-virgule/
retour à la ligne est limitée à l'affichage PDF ; le texte source reste intact.

## Preuve sur le build 64 exact

Commande reproductible :

```sh
bash tools/compat/test-mobility-build64.sh
```

Le script exporte les sources de ce SHA dans un dossier temporaire neuf, ajoute
uniquement le test et lance Flutter. Il ne copie pas le code de la web 68 sur le
build 64 et ne construit pas d'application iPad.

Les 9 tests passent **en incluant une reproduction attendue d'incompatibilité** :

| Scénario | Résultat |
| --- | --- |
| Lecture puis sauvegarde sans édition | Aucun delta, chaîne préservée |
| Modification de « Détails » de l'aide à domicile | La dépendance reste intacte dans `occupants_json`; aucun delta `dependence_txt` |
| Canne, liste multiple, inconnue, chaîne vide | Même comportement de conservation |
| Modification hors ligne puis reconnexion simulée | Opération en attente, puis transport du même texte/JSON |
| Réception web simulée puis retour vers SQLite | Texte identique après le cycle |
| Effacement volontaire par le dépôt de données | `dependenceTxt: ''` est émis, distinct de l'omission |
| Clic sur « Canne » avec une liste multiple déjà chargée | **Liste remplacée par `Canne` : perte des autres aides** |

Exemple bloquant : `Canne, Déambulateur, Orthèse spéciale` est affiché par le
sélecteur monochoix sans pill sélectionnée. Un clic réel sur « Canne » produit
`dependence_txt: 'Canne'` et le même texte réduit dans `occupants_json`. Le
protocole reçu ne permet pas de distinguer cette réduction d'un remplacement
volontaire par une seule aide. Aucun mécanisme de fusion automatique n'est
ajouté : il risquerait de réintroduire une aide volontairement retirée.

Les mêmes 9 tests passent sur les sources web 68 de départ. Le transport utilise
SQLite réel et `NocodbSyncService`, avec connectivité et HTTP simulés. Cela ne
prouve pas une écriture NocoDB réelle ni un essai matériel sur iPad.

## Second risque : relation serveur historique

Sur le mapper web 68, une écriture de texte multiple/inconnu ne correspondant
pas à la référence laisse la relation inchangée (`undefined`). La lecture
`refLabel(...) || texte` renvoie alors l'ancien lien « Canne » au lieu du texte
multiple ou inconnu. Ce risque est distinct de celui du sélecteur iPad.

Main possède le correctif partagé de lecture : texte **non vide** prioritaire,
sinon référence historique. `mobilityMappingRead.test.mjs` en fixe le contrat :
10 cas, dont 3 échouent sur la base 68 non corrigée (multiple, inconnue et Aucune
avec lien historique). Les 10 cas passent contre le `helpers.mjs` corrigé par Main
dans son worktree d'intégration, importé en lecture seule depuis une copie du test.
Le test ne modifie ni relation ni texte. Il exige aussi
que le JSON occupant existant ne soit pas réécrit par une simple lecture.

Un texte `null` ou vide avec relation existante reste ambigu : on garde le
fallback historique, sans supposer un effacement. L'effacement volontaire
existant écrit déjà texte **et** relation à `null`; l'omission n'écrit aucun des
deux. Aucune modification du contrat d'écriture n'est demandée pour ce lot.

## Intégration PDF par Main

`server/reports/mobilityAids.mjs` expose :

- `formatMobilityAidsForReport` : conserve les tokens inconnus, dédoublonne les
  tokens identiques sans tenir compte de la casse ; vide reste vide ; les
  anciennes absences exactes « Non / Aucun / Aucune » s'affichent « Aucune ».
  Aucune recherche par sous-chaîne ne transforme un libellé libre en Canne.
- `applyMobilityAidsToReport` : remplit le champ existant à 9,5–8,5 pt. Au-delà,
  inscrit un renvoi et ajoute autant de pages que nécessaire avec le texte
  intégral à 11 pt. Aucun texte n'est tronqué ; la valeur stockée n'est pas touchée.

`mobility-pdf-integration.patch` est fourni **non appliqué** au générateur partagé.
Il délègue l'ancien normalizer et appelle le helper après
`form.updateFieldAppearances(reportTextFont)`, avant `form.flatten()`.
La numérotation normale inclut ensuite l'annexe. L'annexe sanitaire d'Assist 2
peut être ajoutée ensuite, avant la numérotation commune.

Le sandbox de test applique ce patch dans une copie temporaire. Après intégration
par Main, il utilise directement le générateur intégré. Les 8 tests PDF vérifient
les modèles ERGO/TECHNICIAN, les deux dates de naissance, la page Morbihan
originale (flux PDF inchangé, une occurrence), le vide et l'aplatissement.

Commande des exemples fictifs :

```sh
node tools/compat/preview-mobility-pdf.mjs
```

Sortie : `output/pdf/mobility/aides-multiples.pdf` et
`output/pdf/mobility/aides-inconnues-morbihan.pdf`. Contrôle visuel effectué sur
page bénéficiaire, annexe mobilité et page Morbihan : pas de texte coupé ou de
chevauchement ; civilités et dates conservées. Les exemples livrés sont des
artefacts de revue, hors commit. La police du rapport reste Helvetica/WinAnsi :
les libellés français sont couverts ; aucun élargissement des polices du rapport
n'est introduit par ce lot.

## Conditions du lot différé

L'activation d'un sélecteur multiple demande un client iPad capable de représenter
et d'éditer toute la sélection, ainsi qu'un contrat serveur qui ne laisse pas une
ancienne relation masquer les valeurs. Refaire ensuite le cycle web → iPad → web
avec ajout, retrait et effacement explicites, y compris après reconnexion.
Le présent succès des tests de conservation ne vaut pas validation de cette
fonctionnalité différée.

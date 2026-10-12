# Sanitaires multiples — Assist 2 — 5 octobre 2026

## Décision

**Ne pas activer les salles de bain/WC multiples par niveau dans le candidat qui cohabite avec les iPad 64.** Les tests verts de caractérisation reproduisent une perte de données, ils ne constituent pas une validation fonctionnelle de cette coexistence.

- Base production web68 convenue avec Main : `cc9b7ccedf1e0bf0e0eb97d9eb12e7d03a3fc470`.
- Source iPad64 exacte : `a5b4d9fbe40579160a9290688a7707e7a3376c2c`.
- Branche isolée : `codex/sanitary-rooms-multiple`.
- Aucun changement du checkout principal, de version, de données réelles, de schéma ou des onglets sanitaires. Aucun déploiement/build iPad.
- Main conserve `types.dart`, `dossier_repository.dart`, serveur partagé et générateur PDF. Assist 1 informé du helper PDF séparé.

## Contrat existant observé

Les pièces du logement sont des listes de libellés dans les champs `*_rooms_json`. Elles ne portent pas d’identifiant de pièce. Les diagnostics utilisent deux tableaux JSON (`sdbInstances`, `wcInstances`), avec `id`, `levelField`, `levelLabel` et mesures/équipements. Le WC possède `observationEquipementsUtilisation` ; le modèle BathroomInstance de cette base n’a pas de champ d’observation par salle de bain. Les observations globales restent distinctes.

Le stockage SQLite sérialise correctement plusieurs identifiants distincts au même niveau. Le problème est la reconstruction des onglets : `buildSanitaryLevelSelections` utilise `any`, donc une entrée par niveau, puis `_hydrateFromLocal` prend `existing.first`. Le chargement reconstruit aussi les libellés et crée des instances en mémoire à partir du logement. Il ne sauvegarde pas à lui seul, mais l’édition suivante persiste cette projection réduite. Les onglets de web68 sont identiques à ceux du build64 (`git diff` vide sur ces deux fichiers).

`_saveMergedDiagnostic` préserve la famille opposée mais remplace toute la famille éditée. Le repository met le tableau réduit dans la file durable avec la référence du tableau antérieur. Le serveur accepte le remplacement de tableaux, y compris la référence périmée reproduite par le test HTTP.

Le diff ancien du checkout principal remplace le choix `first` par un index d’occurrence. Il n’est pas repris : ce n’est pas une relation stable avec les pièces du logement, le chargement continue de reconstruire des instances, et cela ne corrige pas le code déjà installé sur iPad64. `pruneDiagnosticSanitaireForRooms` raisonne lui aussi en ensembles de niveaux, pas en identités de pièces.

## Preuves exécutées

| Scénario | Résultat |
| --- | --- |
| Ancien dossier, une pièce au RDC, SDB et WC | Identifiant, mesure et observation WC préservés après édition hors ligne et réouverture ; aucun write à la simple ouverture |
| Deux pièces au RDC, SDB et WC | Seule la première est affichée ; après édition, le deuxième identifiant disparaît du tableau sauvegardé |
| RDC + étage, SDB et WC | Deux identifiants conservés ; changements rapides de sélection puis sauvegarde/réouverture passent |
| SQLite sur fichier temporaire réellement fermé/réouvert | Trois instances et données distinctes conservées ; tableau réduit transmis par l’onglet persiste ensuite tel quel, avec baseline antérieure complète |
| Web → iPad avec lecture fraîche → web | Endpoint réel sur NocoDB simulé : réponse 200, deuxième identifiant perdu ; ajout web suivant perdu à nouveau au save iPad frais |
| Édition hors ligne → modification/ajout web → reconnexion | Endpoint réel : réponse 200 au tableau ancien, ajout web perdu dans le cas reproduit |
| Effacement explicite web → ancienne sauvegarde iPad | Endpoint réel : réponse 200 et restauration de la pièce effacée |
| PDF actuel, quatre SDB et quatre WC | Colonnes 1–3 et mesures cohérentes ; quatrième pièce omise, observations des WC suivants omises |

Toutes les données sont fictives. HTTP utilise le vrai routeur serveur, une écoute loopback éphémère et un mock NocoDB strict en processus isolé (environnement sans secrets réels). Les tests widgets utilisent le vrai code des onglets avec repository mémoire, puis le test SQLite vérifie séparément le repository réel. Ce n’est pas un parcours sur iPad physique ni une validation réseau de production.

### Commandes et résultats

```sh
bash aid_habitat_app/tool/test_build64_sanitary.sh
# 6 tests, source complète extraite avec git archive du SHA exact64

TMPDIR=/tmp/assist2-sanitary-tests bash aid_habitat_app/tool/test_safely.sh \
  test/compatibility/build64_sanitary_rooms_test.dart \
  test/services/sanitary_rooms_roundtrip_test.dart
# 7 tests sur base web68 ; après correction du setup synthétique remote_updated_at,
# relance depuis la copie temporaire avec flutter test --no-pub : 7/7

# Dans la copie temporaire sans apostrophe :
flutter analyze --no-pub
# No issues found

node --test server/sanitaryRoomsBuild64.test.mjs \
  server/sanitaryRoomsReport.test.mjs server/sanitaryRoomsAppendix.test.mjs
# 4/4

git apply --check docs/reviews/sanitary-pdf-integration.patch
# Patch applicable, NON APPLIQUÉ
```

## Correctif PDF autonome proposé

`server/reports/sanitaryRoomsAppendix.mjs` exporte `appendSanitaryRoomsAppendix({pdfDoc, sanitaires})`. Il est sans écriture métier et ne modifie ni l’ordre ni les identifiants des données d’entrée. Il ajoute une annexe si une famille contient plusieurs instances et que la table actuelle omet des détails : plus de trois pièces, libellé de niveau précis, observations ou hauteurs d’équipements secondaires. Les dossiers anciens à une seule pièce par type et les tableaux multiples entièrement représentés n’ajoutent pas d’annexe.

L’annexe reprend toutes les instances des deux familles, leur numéro de position (Salle de bain 1 / WC 2), niveau, valeurs connues, mesures et observations. Aucun identifiant technique n’est imprimé. Les valeurs absentes restent absentes ; les booléens explicitement faux sont rendus « Non ». Une mesure existante est conservée même si l’équipement est false, sans correction arbitraire de la donnée. Pagination sans limite de trois pièces, reprise du nom de pièce lors des continuations, texte long testé jusqu’au marqueur final.

Le patch séparé place l’appel sur `numberedDoc` avant `drawGeneratedPageNumbers`, afin que l’annexe participe à la numérotation générale. **Main doit appliquer et tester cet appel dans sa branche ; il n’est pas appliqué ici.** Le helper seul ne change aucun rapport produit par l’application. Publication API nécessaire ultérieurement, pas seulement web.

PDF fictif de revue (non commité) : `output/pdf/sanitaires-fictifs-avec-annexe.pdf`, 17 pages. Il est produit en ajoutant le helper au PDF actuel ; l’appel final avant numérotation reste à intégrer par Main. Contrôle visuel de la page sanitaire d’origine et des pages d’annexe, extraction des valeurs 4e pièces/notes, test séparé d’observation longue sur quatre pages. Les glyphes non supportés par Helvetica sont remplacés par `?` (limite explicite ; accents français supportés). Le PDF utilise le comportement de formulaire existant du générateur.

## Exigences avant un futur build iPad

1. Une identité de pièce durable indépendante du niveau, du libellé, de l’ordre et de l’index de sélection. Relation explicite entre pièce du logement et diagnostic ; création/suppression seulement par action utilisateur.
2. Charger les instances telles qu’enregistrées. Ne pas générer, renommer, fusionner ou supprimer automatiquement, y compris les anciennes instances sans niveau/avec identifiant historique. Résoudre les ambiguïtés anciennes explicitement sans migration destructive.
3. Sélection et callbacks de mesures/observations adressés par ID ; aucune capture d’index périmée pendant changements rapides, réponse réseau tardive ou debounce. Préserver le brouillon local lors d’un refresh.
4. Sauvegarde par identité avec référence/version et suppression explicite. Tester modification simultanée de deux pièces, conflit sur la même pièce, ajout web pendant édition iPad et suppression web pendant offline. L’absence dans un tableau ancien ne doit pas être interprétée implicitement comme suppression, et un ancien client ne doit pas ressusciter une suppression.
5. Si un protocole nouveau devient nécessaire, empêcher les anciens clients d’écrire des dossiers qu’ils ne savent pas représenter, ou différer l’activation jusqu’à mise à jour du parc. Ne pas contourner par union automatique des tableaux (restaurerait les effacements).
6. Associer les observations à la pièce lorsque ce besoin est implémenté, sans réaffecter les observations globales historiques. Mettre à jour le PDF complet et les tests d’identité.
7. Rejouer les tests exacts ci-dessus en assertions de conservation, puis parcours sur appareil physique hors ligne/reconnexion avant activation. Les tests de caractérisation doivent alors évoluer, sans faire passer leurs pertes attendues pour une réussite métier.

# Diagnostic du blocage par attribution - 15 septembre 2026

## Mise a jour : correctif local prepare

Les sections de diagnostic ci-dessous decrivent le constat AVANT correction.
Le worktree contient maintenant un correctif, sans integration dans main ni
deploiement. Aucun acces aux donnees de la collegue.

- Une insertion qui remplace une operation prouvee completed renouvelle son
  attribution dans le meme statement SQLite. Les historiques non confirmes ne
  sont pas effaces. Les operations ambiguës sans preuve de fin restent bloquees.
- La purge des operations completed supprime leurs metadonnees dans la meme
  transaction ; un echec annule les deux suppressions.
- La revue explicite peut maintenant reconstruire des metadonnees absentes,
  apres verification du payload et du statut. Elle reste reservee aux admins
  dans l'interface ; aucun traitement automatique des operations deja bloquees.
- Reessayer ouvre la revue lorsque le blocage concerne l'auteur, plutot que
  relancer aveuglement le reseau. Le refus non-admin explique comment demander
  une intervention dans le meme navigateur et quoi ne pas supprimer.

Verification finale : **739 tests passes**, commande `flutter test --no-pub
test/services test/screens/agent3_sync_ownership_review_screen_test.dart
--reporter expanded`. Analyse des six fichiers Dart modifies/ajoutes : aucun
probleme. `git diff --check` propre. Les nouveaux tests de caracterisation ont
ete convertis en tests de regression pour les comportements corriges ; les
protections entre comptes restent testees. Couverture supplementaire : rollback
de remplacement/purge, metadonnees orphelines non reattribuees, reinstall des
triggers, revue explicite d'une absence de metadonnees et rejet d'un payload
modifie pendant la revue.

Fichiers de fonctionnement modifies :
`aid_habitat_app/lib/services/sync_operation_ownership.dart`,
`aid_habitat_app/lib/services/sync_repository.dart`,
`aid_habitat_app/lib/screens/main_screen.dart`,
`aid_habitat_app/lib/screens/sync_ownership_review_screen.dart`.
Tests : `aid_habitat_app/test/services/sync_ownership_diagnostic_test.dart`
(nouveau) et `aid_habitat_app/test/screens/agent3_sync_ownership_review_screen_test.dart`.

Conditions restantes : integration avec les autres travaux, validation web
Firefox/SQLite WASM et iPad, publication web autorisee, puis revue accompagnee
de la file reelle de la collegue. Une nouvelle version n'attribuera PAS toute
seule ses sauvegardes deja ambiguës. Le parcours existant fait prendre en charge
l'envoi par le compte admin qui confirme (texte explicite) ; il ne permet pas
encore de choisir un autre auteur. Ne confirmer que les operations comprises,
lisibles et autorisees pour cet administrateur. Aucune promesse de resolution
de l'incident reel avant cette verification.

Compatibilite : pas de changement de schema ni de contrat serveur. Les triggers
sont reinstalles par LocalDatabase a l'ouverture. Ne pas maintenir plusieurs
versions de la webapp ouvertes dans le meme profil pendant la bascule : une
ancienne version peut reinstaller les anciens triggers. Rollback par retour
au client precedent possible sans migration inverse, mais reintroduit le defaut
pour les futures reutilisations. Conserver les sauvegardes locales dans tous les cas.

## Cadre

Worktree : `/private/tmp/appergo-sync-attribution`
Branche : `codex/diagnostic-sync-attribution`
Base : `06cf6cff54cbc2cc90bbd869a3f2d75ba9649249`.

Diagnostic du code local et tests synthetiques seulement. Aucun acces aux donnees reelles, aucune modification des sources de fonctionnement ni deploiement. Le SHA effectivement charge dans le navigateur de la collegue n'est pas verifie.

## Cause reproductible

Une nouvelle sauvegarde de preconisations peut heriter de l'attribution inconnue d'une ancienne operation DEJA TERMINEE, sans changement de compte. La saisie reste locale, mais devient non executable et produit le message observe. Cela ne prouve pas encore la cause du cas reel.

### P1 - Attribution historique reutilisee apres fin d'une operation

- `aid_habitat_app/lib/services/sync_operation_ownership.dart:112` : migration de toutes les operations existantes en historiques sans auteur, y compris completed.
- `aid_habitat_app/lib/services/dossier_repository.dart:3541` : identifiant stable visitrec_update par dossier.
- `aid_habitat_app/lib/services/dossier_repository.dart:2186` : les references de mutation excluent correctement les operations terminees.
- `aid_habitat_app/lib/services/dossier_repository.dart:2162` : remplacement de la ligne de file sous le meme identifiant.
- `aid_habitat_app/lib/services/sync_operation_ownership.dart:221` : les metadonnees existantes survivent ; l'auteur inconnu conduit a review_required sans distinguer une intention ancienne terminee.

Preuve automatisee : operation terminee avant migration, compte A, migration, nouvelle note par A via la VRAIE DossierRepository.saveVisitRecommendations. La note est presente en SQLite, mayClaim refuse, le message de verification apparait. Le moteur reseau n'est pas demarre.

Correction recommandee : separer les generations d'intentions. Lorsqu'une ancienne operation est prouvee terminee, creer une nouvelle generation avec son auteur, ou renouveler atomiquement les metadonnees lors du remplacement tout en preservant la trace ancienne. Ne jamais appliquer ce renouvellement aux operations pending/running/failed/conflict. Tester les ACK tardifs.

### P1 - Attribution persistante apres purge

`aid_habitat_app/lib/services/sync_repository.dart:1186` supprime les operations terminees mais pas leurs metadonnees. La table annexe n'a volontairement pas de cascade pour proteger les INSERT OR REPLACE.

Preuve automatisee : purgeCompleted supprime la ligne terminee, son attribution inconnue subsiste, une nouvelle insertion du meme ID est bloquee.

Correction : purge atomique ciblee des metadonnees des operations prouvees terminees. Pas de cascade globale, ni suppression de l'historique non confirme. Une metadonnee deja orpheline ne constitue pas a elle seule une preuve de confirmation serveur.

### P2 - Parcours non-admin inadapte

`aid_habitat_app/lib/screens/main_screen.dart:347` ouvre la revue depuis Details ; `aid_habitat_app/lib/screens/sync_ownership_review_screen.dart:65` exige un admin. Le bouton Reessayer relance la synchro sans decision d'attribution. Les tests existants confirment le refus non-admin et l'absence d'exposition du contenu.

Correction : message specifique de sauvegardes a verifier, diagnostic expurge accessible sans reattribution et action d'assistance. Ne pas presenter Reessayer comme solution au probleme d'auteur. Les restrictions sur la reattribution doivent rester.

Le bandeau est global. Un test confirme qu'une operation valablement attribuee sur un autre dossier reste executable. Ne pas conclure que toutes les sauvegardes du navigateur sont bloquees.

### Attention a la recuperation administrateur

`aid_habitat_app/lib/services/sync_operation_ownership.dart:349` attribue au compte ACTIF, donc a l'administrateur qui confirme dans le parcours actuel, pas automatiquement a l'ergo.

Ne pas recommander une confirmation en masse sous admin. La procedure cible doit distinguer auteur et valideur, verifier la cible, tracer la decision et conserver le compare-and-set sur le contenu et la session. Un candidat seul ne prouve pas l'auteur de tout le contenu fusionne.

## Plan concret

1. Corriger le cycle des operations terminees et leur purge avec tests de regressions : migration, meme compte, autre compte, ACK tardif, concurrence, restart et travaux non confirmes preserves.
2. Preparer un diagnostic local expurge : version client/schema, nombres par categorie, type/statut/date/ID technique, presence d'auteur/candidat/historique. Pas de payload, token, mot de passe ni contenu medical. Ne pas exposer le travail d'autres comptes.
3. Recuperer les blocages existants uniquement sur preuve ou revue explicite. Pas de suppression de la file, reattribution globale ou mise a jour automatique selon le compte connecte.
4. Adapter le parcours non-admin ; tester l'assistance dans le meme profil navigateur.
5. Valider Firefox/SQLite WASM et iPad, puis integrer/deployer apres accord. Rien n'est deploye ici.

## Verification

Dependances installees uniquement dans ce worktree avec flutter pub get. Script test_safely non utilise ; aucun repertoire temporaire fixe partage.

```sh
flutter test --no-pub \
  test/services/sync_ownership_diagnostic_test.dart \
  test/services/agent3_sync_operation_ownership_test.dart \
  test/services/agent4_ownership_migration_test.dart \
  test/screens/agent3_sync_ownership_review_screen_test.dart \
  --reporter expanded
```

Resultat final : 33 tests passes, dont 7 nouveaux tests de caracterisation. Les tests DEFECT passent parce qu'ils reproduisent le defaut actuel, pas parce que le defaut est corrige. Executions preliminaires : erreurs de chemin et de placement de fonctions dans le nouveau test, corrigees avant le resultat final.

Couverture : vraie sauvegarde de preconisations, reutilisation apres historique termine/purge, editions ordinaires successives, retry sans perte, dossier distinct executable, protection entre auteurs et historique conserve, migrations et revue existantes.

Limites : SQLite natif en memoire, pas de reproduction Firefox ou iPad, pas de verification sur la session reelle. Changement de session pendant un debounce, remappage technique wiki et changement d'ID de compte restent des pistes non confirmees, a tester avant correction transversale.

## Livrables et suite terrain

Nouveaux fichiers uniquement : ce rapport et `aid_habitat_app/test/services/sync_ownership_diagnostic_test.dart`. Aucun commit, push, build de livraison ou changement en production.

Conserver le profil navigateur de la collegue et ses donnees. Ne pas vider IndexedDB, abandonner les operations ou confirmer en masse. Recuperer le diagnostic expurge apres preparation de l'outil, puis decider la resolution operation par operation.

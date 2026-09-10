# Retour Agent 4 - Publication fiable et tracable (F19)

## Isolation

- Worktree : `/Users/aidhabitat/Downloads/aid-habitat-manager-agent-4`
- Branche : `codex/audit-release-traceability`
- SHA de base : `10df5d4c289ffe757af6027f0be0f670fa8f97b7`
- Le repertoire source `/Users/aidhabitat/Downloads/aid'habitat-manager` n'a pas ete modifie.
- Aucun changement local du repertoire source (F01, vignettes ou autre) n'a ete copie.
- Aucun commit, push, merge, deploiement, build signe ou acces a des donnees reelles n'a ete effectue.

## Constat verifie

- Le workflow API acceptait un webhook HTTP non-2xx comme un simple warning, puis affichait un resume de deploiement reussi.
- Le workflow Flutter web ajoutait toujours le tag `latest`, y compris pour la publication manuelle par defaut avec `image_tag=staging`.
- Le script natif rangeait les symboles dans `build/debug-symbols/<plateforme>/<sha-court>`, ce qui autorisait l'ecrasement entre deux builds du meme SHA.
- Le script natif ne consignait ni l'etat dirty, ni la version et le numero, ni les SDK, ni la cible API.

## Implementation

### Webhooks bloquants

Les deux workflows utilisent maintenant `tools/release-artifact-check.mjs post-webhook`. Une erreur reseau, un timeout ou un statut hors de la plage 200-299 termine la commande avec un code non nul. Le secret reste lu depuis la variable d'environnement et l'URL n'est pas journalisee.

Le resume API indique seulement que l'image a ete publiee et que la demande de redeploiement a ete acceptee. Il ne pretend plus que le SHA est actif.

### Isolation staging / production

La publication web calcule ses tags avec une decision testee :

- `image_tag=staging` publie `:staging` et `:<sha>`, jamais `:latest` ;
- `image_tag=latest` publie `:latest` et `:<sha>` uniquement lorsque `latest` est demande explicitement ;
- `deploy_staging=true` impose `image_tag=staging` et echoue sinon.

Les entrees manuelles et leurs valeurs par defaut sont conservees.

### Tracabilite native locale

Le script `aid_habitat_app/tool/build_native_release.sh` :

- refuse une distribution depuis un arbre sale par defaut ;
- autorise explicitement ce cas via `--allow-dirty` ou `AIDHABITAT_ALLOW_DIRTY_RELEASE=1` ;
- ne change pas les commandes locales de developpement hors de ce script ;
- cree un identifiant local par execution et reserve un nouveau repertoire ;
- refuse un identifiant ou un dossier de symboles deja existant au lieu de l'ecraser ;
- range manifest et symboles sous `build/native-releases/<plateforme>/<build-id>/` par defaut ;
- preserve `AIDHABITAT_DEBUG_INFO`, mais exige que ce dossier soit nouveau ;
- ecrit un `manifest.json` avec SHA complet, etat dirty et acceptation, version, numero de build, Flutter, Dart, SDK plateforme, plateforme, API plateforme, cible backend sans query/fragment et dossier de symboles ;
- marque le manifest `completed` ou `failed` selon le resultat local.

Le manifest fixe `remoteBuildNumberVerified` a `false` et rappelle la verification restante dans App Store Connect ou le store cible.

## Fichiers modifies ou ajoutes

- `.github/workflows/build-deploy-api.yml`
- `.github/workflows/flutter-web-build.yml`
- `aid_habitat_app/tool/build_native_release.sh`
- `tools/release-artifact-check.mjs` (nouveau)
- `tools/release-artifact-check.test.mjs` (nouveau)
- `docs/retour-agent-4.md` (nouveau)

## Verification

### Analyse statique et syntaxe

- `node --check tools/release-artifact-check.mjs` : succes.
- `node --check tools/release-artifact-check.test.mjs` : succes.
- `bash -n aid_habitat_app/tool/build_native_release.sh` : succes.
- Parsing YAML Ruby des deux workflows : succes.
- `git diff --check` : succes.
- `shellcheck` : non disponible localement.
- `actionlint` : non disponible localement.

### Reproduction automatisee

Commande :

```bash
node --test tools/release-artifact-check.test.mjs
```

Resultat : 9 tests reussis sur 9. Les fixtures et commandes simulees couvrent :

- echec webhook HTTP 503 ;
- echec reseau simule ;
- succes HTTP 204 ;
- absence de `latest` pour staging ;
- disponibilite explicite du parcours manuel `latest` ;
- refus de deployer staging avec un autre tag ;
- reservation exclusive des symboles ;
- manifest sans secret et avec verification distante marquee non faite ;
- refus d'un arbre sale sans acceptation ;
- build natif simule avec faux Flutter/Xcode, puis refus d'une seconde execution avant ecrasement ;
- presence des nouvelles decisions dans les workflows.

Aucun appel HTTP reel, e-mail, synchronisation, webhook, build Flutter, export Xcode, signature, publication ou upload n'a ete declenche. Le script `tool/test_safely.sh` n'a pas ete lance car aucun fichier Dart/Flutter n'est modifie ; sa contrainte `TMPDIR` n'etait donc pas applicable.

### Validation sur appareil

Non realisee et non requise pour ces changements de chaine de publication. Aucun gain de performance ni absence totale de regression n'est revendique.

## Limites et besoins d'integration

- Un HTTP 2xx du webhook prouve seulement l'acceptation de la demande. Aucun endpoint actuel n'expose le SHA actif. Si cette preuve devient obligatoire, le coordinateur doit faire ajouter un endpoint de version cote serveur, hors perimetre de cette mission, puis comparer sa valeur a `${{ github.sha }}` apres deploiement.
- Le controle des dossiers et manifests empeche les collisions locales connues. Il ne peut pas garantir que le numero de build TestFlight est unique sans consulter App Store Connect. Cette verification distante reste obligatoire avant upload.
- `shellcheck` et `actionlint` devraient etre executes par le coordinateur ou la CI s'ils sont disponibles dans l'environnement d'integration.
- Le script natif depend maintenant de Node.js pour produire et valider la tracabilite locale. Il ne change pas la version Node du projet.

## Revue et integration du coordinateur - 9 septembre 2026

Les six fichiers ont ete integres localement, avec les changements des agents
2 et 5 deja presents. Corrections supplementaires lors de la revue :

- Webhook : plafond de temps maintenu pendant la lecture du corps, course
  explicite avec la deadline, aucune redirection suivie, aucun contenu de
  reponse ou message reseau brut recopie dans les erreurs. L'URL invalide
  n'est pas recopiee non plus. Aucun retry ajoute.
- Tags : staging publie maintenant staging et staging-<sha>, pas le tag
  <sha> partage avec un bundle de production du meme commit. latest conserve
  latest et <sha> pour compatibilite. Les autres canaux ont canal-<sha>.
  Cela remplace la decision staging + <sha> decrite dans le rapport initial.
- CLI : reconnaissance du programme principal par chemins reels. Sans cela,
  les chemins symboliques macOS /var ou /tmp pouvaient faire sauter toutes
  les commandes de controle sans erreur. Regression explicite par symlink.
- Script natif : echec explicite si git status echoue ; suppression de
  l'affichage brut de la cible API invalide.
- Tests du script natif dans une copie temporaire minimale avec Git,
  Flutter et Xcode simules ; independance de l'etat dirty du vrai depot,
  verification des etats completed/failed et nettoyage des fixtures.
- Les deux workflows executent les tests de publication avant publication.

Verification assemblee : 75 tests Node reussis, dont 13 tests de publication ;
test:sync-contract et check:critical (20/20) reussis ; bash -n et parsing
YAML Ruby reussis ; git diff --check reussi. shellcheck et actionlint absents.

Aucun webhook, processus Flutter/Xcode reel, build signe, commit, push ou
deploiement. La verification du SHA actif et du numero TestFlight distant
reste a faire avant une vraie distribution. Les versions Node sont inchangees.

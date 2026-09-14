# Publication web et API - preparation du 14 septembre 2026

## Etat verifie

Base de preparation : `9c6a9cfa813686c972c667aa80ae5192e402ffaa`,
branche `codex/preparation-publication-web-api`.

- `https://app.aidhabitat.fr/version.json` sert encore `1.0.0+10`.
- Son `main.dart.js` a pour SHA-256
  `088dc274348f8a65490b4b1b437471c3975295b713588280d8cc769031477d6e`.
- Le workflow web du SHA de base a construit `1.0.0+19` et publie les tags
  `release-19` et `release-19-9c6a9cfa...`. Son artefact GitHub temporaire a
  expire le 13 septembre ; l'image GHCR ne doit pas etre confondue avec une
  version deployee. Le push des deux tags est confirme par le journal du run ;
  leur inventaire GHCR n'a pas pu etre relu car le jeton local ne possede pas
  la permission `read:packages`.
- L'API publique est live et ready au SHA
  `7b47dca77a780780661ccc56c1b0f018d60cd0d1`.
- Le dernier workflow API correspondant a publie son image, puis a echoue au
  webhook. Le seul secret Actions liste est celui du staging web ;
  `EASYPANEL_API_WEBHOOK` est absent.
- Aucun des controles ci-dessus n'a ecrit de donnee, appele un webhook ou
  modifie EasyPanel.

Le paquet 19 ne doit pas etre publie maintenant : deux autres corrections sont
encore en cours. Apres leur integration, le coordinateur doit choisir un numero
de build unique. Reutiliser `19` pour un contenu different rendrait la recette
et le retour arriere ambigus.

## Conservation du stockage web

La mise a jour web ne doit jamais demander d'effacer les donnees du navigateur.
Le code actuel retire seulement les anciens service workers et caches
d'app-shell. Il ne supprime ni IndexedDB, ni `localStorage`.

La base locale est migree additivement jusqu'a v24. Le scellement du coffre web
traite aussi `sync_operations` et son historique ; son marqueur v2 n'est ecrit
qu'apres succes. Une erreur ferme la base et conserve les donnees pour une
nouvelle tentative. Les tests `web_vault_migration_test.dart` et
`offline_persistence_test.dart` confirment sur SQLite synthetique que les
payloads, conflits, echecs et operations interrompues restent recuperables.

Limite : cette preuve automatisee ne remplace pas une mise a jour reelle dans
Safari avec IndexedDB/WASM. La recette staging doit partir d'un profil de test
contenant une operation hors ligne synthetique, sans dossier reel.

## Changements de publication

Le workflow API execute maintenant validation et construction sur chaque push,
mais ne publie aucune image automatiquement. Une publication et un deploiement
doivent etre demandes manuellement. Si `deploy_api=true`, l'absence du secret
arrete le job avant la connexion GHCR et avant la publication de l'image.
Les runs de publication ne sont plus annules par l'arrivee d'un autre run.

Le workflow web genere `release.json` dans le bundle avec le SHA Git complet,
le numero de build, la cible API et l'empreinte de `main.dart.js`. Une
publication d'image exige `expected_build_number`. Les artefacts sont nommes
avec le SHA complet et conserves 14 jours. Le controle live peut ainsi verifier
le build, le commit et l'empreinte exacte, pas seulement la presence de la page.
Un deploiement staging sans publication ou sans son secret verifie echoue avant
le push de l'image.

## Prerequis manquants

1. Integrer les deux lots en cours, relancer toutes leurs validations et figer
   le SHA candidat.
2. Choisir un nouveau numero de build non reutilise si le contenu differe du
   paquet 19 deja prepare.
3. Pour un deploiement API automatise, creer le secret Actions
   `EASYPANEL_API_WEBHOOK` uniquement depuis le webhook du service API qui sert
   reellement `api.aidhabitat.fr`.
4. Avant d'ajouter ce secret, verifier dans EasyPanel l'image et le tag suivis
   par ce service. Aucun webhook web ou staging ne doit etre reutilise par
   supposition.
5. Conserver l'image/tag/digest actuellement actifs avant toute bascule.

## Procedure finale

### Candidat web sans publication

```bash
gh workflow run "Build Flutter Web" \
  --ref <sha-candidat> \
  -f api_base_url=https://api.aidhabitat.fr \
  -f expected_build_number=<numero> \
  -f upload_artifact=true \
  -f publish_image=false \
  -f image_tag=release-<numero> \
  -f deploy_staging=false
```

Attendre le run, telecharger l'artefact nomme avec son SHA, puis verifier :

```bash
node tools/check-web-release.mjs \
  --dir <dossier-artifact> \
  --expected-build-number <numero> \
  --expected-git-sha <sha-candidat>
```

Recetter ensuite sur staging l'ouverture d'un profil web existant, une saisie
hors connexion, le rechargement, la reconnexion et l'envoi. IndexedDB et
`localStorage` doivent rester presents ; aucune commande de nettoyage n'est une
solution acceptable.

### Publication web

Relancer le meme workflow avec `publish_image=true` et un tag immuable
`release-<numero>`. Ne basculer EasyPanel qu'apres verification du digest de
l'image et de l'ancienne reference de rollback. Le workflow ne deploie pas la
production web, faute de destination de production verifiee.

Apres bascule :

```bash
node tools/check-web-release.mjs \
  --url https://app.aidhabitat.fr \
  --expected-build-number <numero> \
  --expected-git-sha <sha-candidat>
npm run release:live-check
```

Terminer par la recette avec le meme profil : operation offline toujours
visible, reprise de synchronisation, absence de doublon et aucune demande de
vider le navigateur.

### Publication API

Sans secret verifie, executer uniquement une validation/construction :

```bash
gh workflow run "Build & Deploy API" \
  --ref <sha-candidat> \
  -f publish_image=false \
  -f deploy_api=false \
  -f image_tag=candidate
```

Une fois le webhook et le tag EasyPanel verifies, demander explicitement
`publish_image=true` et `deploy_api=true`. Le run n'est valide que si les deux
healthchecks servent exactement le SHA candidat apres le webhook.

## Retour arriere

- Avant toute ouverture du nouveau web par un utilisateur, repointer EasyPanel
  sur l'ancien digest immuable puis verifier le build 10 et le live check.
- Apres ouverture et migration de la base locale v24, ne pas revenir aveuglement
  a un frontend plus ancien : son support d'une base deja migree doit etre teste.
  Preferer un correctif en avant. Ne jamais supprimer IndexedDB, `localStorage`
  ou les operations en attente pour rendre un ancien build ouvrable.
- Pour l'API, repointer sur le digest actif consigne avant bascule, puis exiger
  live et ready avec son SHA attendu. Une simple reponse 2xx du webhook ne suffit
  pas.
- Si la version attendue n'est pas servie, arreter la recette et ne pas publier
  le second composant. Web et API se basculent et se valident separement.

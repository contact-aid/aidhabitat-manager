# Retour agent 5 - F07 dependances serveur

Date : 2026-09-09.

## Isolation et livraison

- Worktree : /Users/aidhabitat/Downloads/aid-habitat-manager-agent-5
- Branche : codex/audit-server-dependencies
- Base et HEAD : 10df5d4c289ffe757af6027f0be0f670fa8f97b7
- Modifies : package.json (versions/overrides uniquement), package-lock.json.
- Ajoutes : server/dependencyCompatibility.test.mjs, docs/retour-agent-5.md.
- Aucun commit, push, merge, deploiement ou changement du repertoire source.
- Audit source lu en entier, non modifie. Aucun travail F01 ou vignettes copie.
- Aucun secret charge ou service de production contacte pour les tests. Aucun SMTP,
  webhook ou port d'ecoute. Les seuls acces reseau de cette mission concernent
  les registres de paquets et la documentation officielle.

## Constat et changement cible

Audit avant sur la base commune : 5 paquets affectes, 3 high et 2 moderate.
Cela correspond a 17 avis dans le JSON, et non a des incidents observes.
Audit apres : vulnerabilities vide, 0 a tous les niveaux, 257 dependances
recensees. Ce resultat depend de la base d'avis npm au moment du controle.

| Paquet | Version verrouillee avant | Apres | Motif |
| --- | --- | --- | --- |
| multer | 2.2.0 | 2.3.0 | multipart, interruptions, limites |
| nodemailer | 9.0.3 | 9.1.1 | parsing adresses et politique acces fichiers/URL |
| fast-uri | 4.1.2 | 4.1.3 | canonicalisation URI |
| hono | 4.13.2 | 4.13.5 | query, parseBody, SSG |
| qs | 6.15.2 | 6.16.0 | limites tableau et isBuffer |
| side-channel | 1.1.0 | 1.1.1 | minimum requis par qs 6.16.0 |
| side-channel-list | 1.0.0 | 1.0.1 | minimum requis par side-channel 1.1.1 |

Express 5.2.1 et SDK MCP 1.29.0 restent identiques. Pas de migration majeure.
Les overrides fast-uri/hono sont fixes aux premieres versions corrigees pour
eviter une resolution plus large. Les autres nouvelles bornes suivent le style
existant. npm a place fast-uri sous ajv/node_modules : le test resout ce paquet
depuis AJV, sans supposer son hoisting. Les autres entrees du lockfile sont
conservees ; es-object-atoms et hasown, initialement actualises par npm, ont
ete remis a leurs entrees de base avant un nouveau npm ci reussi.

## Sources officielles verifiees

- [Multer 2.3.0](https://github.com/expressjs/multer/releases/tag/v2.3.0) :
  GHSA-wc9g-mqfw-jrwm, GHSA-qfvm-cv95-jqjf, GHSA-qvfw-j98x-7q72,
  GHSA-535w-7cp7-47q4.
- [Nodemailer 9.1.1](https://github.com/nodemailer/nodemailer/releases/tag/v9.1.1) :
  corrections de politique resolveContent. Le registre signale aussi les avis
  GHSA-8m3c-c648-2xjj, GHSA-wmmp-3585-3rmp, GHSA-2x7j-588g-ccc2 et
  GHSA-cc9r-2j5m-2m83 ; la borne requise la plus haute est 9.1.1.
- [fast-uri 4.1.3](https://github.com/fastify/fast-uri/releases/tag/v4.1.3) :
  GHSA-5jgf-p345-68v8, GHSA-f65p-4m7j-42xc, GHSA-fph4-wmhf-6fwf,
  GHSA-jqff-g426-hqxp.
- [Hono 4.13.5](https://github.com/honojs/hono/releases/tag/v4.13.5) :
  GHSA-gqvv-2mrq-wpjv, GHSA-g6gw-c38x-mqfc, GHSA-crvj-82cr-hjcx.
- [qs isBuffer](https://github.com/ljharb/qs/security/advisories/GHSA-4mjr-xmp4-gh2g)
  : version corrigee 6.16.0.
- [qs limite tableau](https://github.com/ljharb/qs/security/advisories/GHSA-x5fp-wj9c-mxmx).
- [Tag qs 6.16.0](https://github.com/ljharb/qs/releases/tag/v6.16.0).

Analyse statique : server/index.mjs utilise memoryStorage, single(file),
single(chunk) et any() pour les rapports. server/routes/feedback.mjs utilise
createTransport. fast-uri est consomme par AJV et qs par Express/body-parser ;
Hono appartient a la chaine MCP. Le fichier de test n'importe pas index.mjs.

## Verification automatisee

Environnement : Node 24.11.0 local. Commandes depuis le worktree :

| Commande | Resultat |
| --- | --- |
| npm audit --json (avant) | Code 1, 3 high / 2 moderate |
| npm install --package-lock-only --ignore-scripts --no-fund | Resolution ciblee reussie |
| npm ci --ignore-scripts --no-fund | Installation isolee reussie, 257 paquets |
| npm ls fast-uri hono qs ajv multer nodemailer | Arbre valide, versions attendues |
| node --test server/dependencyCompatibility.test.mjs | 9/9 |
| node --test test/*.test.mjs shared/*.test.mjs server/*.test.mjs | 33/33 |
| npm run test:sync-contract | 10/10 (deja comptes), controle de contrat OK |
| npm run build | Vite OK ; avertissement chunk > 500 kB |
| npx --no-install tsc --noEmit | Code 2 : F20, VisitReportView.tsx:4985, X absent |
| npm audit --json (apres) | Code 0, aucune vulnerabilite signalee |
| git diff --check | OK |

Le premier essai du nouveau test importait fast-uri a la racine et a echoue
apres la resolution imbriquee npm. Correction du test pour resoudre via AJV,
puis succes. La suite ciblee a ete relancee apres l'ajout de la regression qs.

Couverture : multipart single et multi-fichiers avec octets/metadonnees,
boundary absent, payload tronque, fichier inattendu, limite exacte et depassee,
fileFilter asynchrone, nombre de fichiers, valeur de champ, nombre de parties,
index de tableau borne. Interruption simulee sur flux natif Node en memoire
et sur stockage disque temporaire : presence du fichier partiel avant coupure,
retour d'erreur, absence d'erreur de nettoyage et repertoire vide apres retour.
Requete valide ensuite. Le test disque utilise un dossier mkdtemp propre.

E-mail : MIME texte/HTML/piece jointe en memoire et rejet d'acces fichier ;
aucun transport SMTP. QS : parsing Express, stringify, prototype et regression
constructor.isBuffer. AJV : references URI et validation valide/invalide.
Hono : requete locale avec parseBody. MCP : handshake/listTools via transports
InMemoryTransport relies, sans processus externe ni reseau.

## Limites et integration

Point restant precis pour le coordinateur : dans Multer 2.3.0,
fieldArrayIndexLimit est OPT-IN. Le code server/index.mjs:267 et :278 ne le
configure pas. La mise a jour seule ne borne donc pas les indices de tableaux
multipart. Une limite compatible avec les noms de champs metier doit etre
definie dans ces deux configurations ; ce changement hors fichiers autorises
n'a pas ete applique. Le test demontre le rejet quand la limite est configuree,
pas son activation dans l'application. Examiner aussi fieldNestingDepth et
les plafonds de champs/parties selon les vrais contrats d'upload.

Multer accepte desormais un fichier exactement egal a fileSize et decode
les sequences WHATWG %0A/%0D/%22 du nom original : comportement annonce en
release a prendre en compte lors du test d'integration des noms de documents.

Ces tests de compatibilite ne reproduisent pas tous les exploits des 17 avis
et ne demarrent pas les routes metier completes. L'interruption utilise des
flux simules ; pas de mesure de descripteurs OS sous charge, ni de test TCP
ou proxy. Aucune validation sur appareil, SMTP reel, conteneur ou TestFlight.
Le runtime Node 20 Docker/workflows reste a migrer separement. F20 reste
present et hors perimetre. Pas de gain de performance mesure.

Integrer les quatre fichiers puis executer npm ci et les suites Node/build
sur l'ensemble assemble. Refaire les checks avec le runtime Node cible choisi
par le coordinateur et ajouter le test dans la CI si elle ne globbe pas
server/*.test.mjs. Aucun audit npm propre ne prouve une securite complete.

## Verification du coordinateur apres integration

Les quatre fichiers ont ete integres dans le repertoire principal le 9 septembre
2026, sans commit ou deploiement. Le test d'interruption disque y attend maintenant
un fichier partiel non vide avec une attente bornee au lieu d'un delai fixe de 20 ms.

Controles repetes : installation npm ci --ignore-scripts, 33 tests Node,
test:sync-contract, check:critical (20/20), build Vite et git diff --check reussis ;
npm audit ne signale aucune vulnerabilite. TypeScript reste en echec sur F20.
Les limites Multer et la migration Node restent explicitement non integrees.

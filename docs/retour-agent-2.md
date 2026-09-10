# Retour Agent 2 - Delais d'abandon NocoDB (F17)

## Isolation

- Worktree : `/Users/aidhabitat/Downloads/aid-habitat-manager-agent-2`
- Branche : `codex/audit-nocodb-timeouts`
- SHA de base : `10df5d4c289ffe757af6027f0be0f670fa8f97b7`
- Aucun commit, push, deploiement ou acces a NocoDB reel.
- Le repertoire source est reste sur `main` au meme SHA. Ses modifications locales F01, vignettes et travaux paralleles n'ont pas ete copiees ni modifiees.

## Constat verifie

`restRequest()` appelait directement `fetch()`, puis `response.text()`, sans signal d'annulation ni limite applicative. Un blocage pouvait donc survenir avant les en-tetes ou pendant la lecture du corps.

Le fallback MCP appelait REST apres une erreur de transport recuperable pour toutes les operations. Pour une mutation dont le resultat est ambigu (`deadline`, timeout ou connexion fermee), ce fallback pouvait envoyer une seconde ecriture alors que la premiere avait potentiellement ete appliquee.

## Modifications

### `server/nocodbRequestDeadline.mjs` (nouveau)

- Ajout d'une deadline couvrant `fetch()` et la lecture complete du corps.
- Annulation effective par `AbortController` lorsque la deadline expire.
- Course explicite avec la deadline pour que l'appelant soit libere meme si une implementation de `fetch` ne reagit pas correctement au signal.
- Nettoyage du timer dans `finally` sur succes, erreur reseau, erreur de corps et timeout.
- Erreur de timeout explicite : `NocodbRestTimeoutError`, code `NOCODB_REST_TIMEOUT`, avec methode, chemin et duree.
- Validation de `NOCODB_REST_TIMEOUT_MS` : entier entre 1 000 et 900 000 ms.
- Valeur par defaut : 120 000 ms. Elle borne les pannes lentes tout en laissant une marge aux lots de chunks volumineux.
- Regle pure interdisant le fallback REST apres une erreur MCP de transport recuperable pour `createRecords`, `updateRecords` et `deleteRecords`.

### `server/nocodbMcpClient.mjs`

- Passage de tous les appels REST existants par la nouvelle deadline, sans modifier la signature de `callNocoTool()`, `getMcpClient()` ou `closeMcpClient()`.
- Conservation de la lecture et du parsing existants des payloads.
- Conservation des erreurs HTTP avec leurs proprietes `status` et `payload`.
- Conservation des erreurs reseau d'origine lorsqu'elles ne proviennent pas de la deadline.
- Aucun retry REST ajoute.
- Les fallbacks de lecture MCP vers REST sont conserves.
- Une mutation MCP abandonnee sur erreur de transport recuperable est maintenant remontee telle quelle, sans seconde mutation REST.

### `server/nocodbRequestDeadline.test.mjs` (nouveau)

Tests uniquement avec URLs invalides et fonctions `fetch` simulees. Aucun reseau reel n'est utilise.

Cas couverts :

- reponse normale ;
- `fetch` bloque ;
- lecture du corps bloquee ;
- erreur HTTP et payload conserve ;
- erreur reseau inchangee ;
- erreur pendant la lecture du corps ;
- configuration absente, valide et invalide ;
- nettoyage du timer sur tous les chemins ;
- nombre exact de tentatives ;
- absence de fallback REST pour une mutation MCP au resultat ambigu.

## Fichiers modifies ou ajoutes

- `server/nocodbMcpClient.mjs`
- `server/nocodbRequestDeadline.mjs`
- `server/nocodbRequestDeadline.test.mjs`
- `docs/retour-agent-2.md`

Tous sont dans le perimetre d'ecriture autorise.

## Verifications

### Analyse statique

- `node --check server/nocodbRequestDeadline.mjs` : reussi.
- `node --check server/nocodbRequestDeadline.test.mjs` : reussi.
- `node --check server/nocodbMcpClient.mjs` : reussi.
- `git diff --check` : reussi.

### Reproduction automatisee

- `node --test server/nocodbRequestDeadline.test.mjs` : 10/10 tests reussis.
- `node --test test/*.test.mjs shared/*.test.mjs server/*.test.mjs` : 34/34 tests reussis.
- `npm run test:sync-contract` : 10/10 tests et 11 elements de contrat reussis.
- `npm run check:critical` : 20/20 controles reussis.

Dependances installees avec `npm ci` uniquement dans le worktree. Le lockfile n'a pas ete modifie. `npm ci` a rappele les 5 vulnerabilites deja inventoriees par l'audit (2 moderate, 3 high) ; aucun `npm audit fix` n'a ete execute.

### Validation sur appareil

Non effectuee. Cette mission ne modifie pas Flutter et aucun appel a un serveur reel n'a ete realise.

## Limites et integration

- Un timeout de mutation reste un resultat ambigu : il ne faut pas le transformer en succes ni le rejouer automatiquement. La couche appelante doit conserver l'erreur et, si necessaire, verifier l'etat distant avant une action manuelle.
- `deleteRecords` traite toujours plusieurs lignes sequentiellement. Un timeout en milieu de lot peut donc suivre des suppressions deja reussies. Aucun retry interne n'a ete ajoute ; une reconciliation metier reste necessaire si l'appelant veut reprendre un lot partiel.
- Le fallback REST reste actif pour une erreur MCP non classee comme erreur de transport recuperable, afin de ne pas changer davantage le mecanisme existant. Les timeouts, deadlines, connexions et transports fermes sont bien bloques pour les mutations.
- Integration recommandee : reprendre les quatre fichiers ci-dessus. La variable `NOCODB_REST_TIMEOUT_MS` est optionnelle ; sans configuration, la valeur validee de 120 000 ms s'applique.
- Aucun gain de performance n'est revendique : le changement borne une attente anormale. La latence normale n'est pas modifiee.

## Verification du coordinateur apres integration - 9 septembre 2026

Les quatre fichiers ont ete integres dans le repertoire principal, avec les
dependances corrigees de l'agent 5. Aucun commit ou deploiement.

La regle de fallback a ete renforcee pendant la revue. Le filtrage initial par
messages d'erreur laissait notamment passer request timeout, socket hang up,
ECONNRESET et une erreur inconnue. La decision depend maintenant de la phase :
si client.callTool a pu etre appele pour une mutation, aucune exception ne
declenche un second transport REST. Si getMcpClient echoue avant cet appel,
le fallback reste permis. Les lectures conservent leur fallback.
Cette regle remplace la limite decrite plus haut sur les seules erreurs MCP
classees recuperables ; elle ne depend plus du texte de l'erreur pour une ecriture.

Ajout de tests executant callNocoTool avec les methodes du SDK simulees : trois
mutations et quatre messages d'erreur, echec avant envoi, lecture en erreur et
succes MCP. Aucun processus MCP ni appel NocoDB reel n'est lance. Un autre test
verifie la liberation de l'appelant si fetch ignore le signal et rejette tardivement.

Resultats repetes sur l'ensemble integre : 62 tests Node reussis (dont 29 pour
la deadline/fallback, sous-tests inclus), test:sync-contract reussi,
check:critical 20/20 et git diff --check reussis.

Le plafond concerne chaque appel REST et son corps, pas la duree totale d'une
operation metier comportant plusieurs appels. Annuler cote client ne garantit
pas l'annulation d'une mutation deja appliquee chez NocoDB. Les retries metier
et la reconciliation des operations ambigues restent a verifier separement.

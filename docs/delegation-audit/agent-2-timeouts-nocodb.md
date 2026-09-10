# Agent 2 - Delais d'abandon NocoDB (F17)

# Cadre commun obligatoire

Projet source : /Users/aidhabitat/Downloads/aid'habitat-manager
Audit a lire, sans le modifier : /Users/aidhabitat/Downloads/aid'habitat-manager/docs/audit-conception-performance-2026-09-09.md

Tu es un agent d'implementation sur un chantier parallele precis, pas le coordinateur. Commence par verifier le constat dans le code. Implemente et teste uniquement dans le perimetre ci-dessous.

## Isolation

- Travaille dans un worktree dedie sur une branche codex/ correspondant a ta mission. Base commune : 10df5d4c289ffe757af6027f0be0f670fa8f97b7. Ne change jamais la branche du repertoire source et n'y edite aucun fichier.
- Si tu as deja un worktree, verifie sa base et ses modifications avant de travailler ; ne reinitialise rien. Si l'isolation n'est pas possible, rends un diagnostic sans modifier le repertoire partage.
- Le repertoire source contient des modifications non commitees, dont le correctif F01 (sauvegarde/fermeture) et des corrections de vignettes. Elles ne sont PAS dans cette base. Lis-les si necessaire, mais ne les copie pas, ne les remplace pas et ne les reimplemente pas. Le coordinateur integrera ton changement puis testera l'ensemble.
- Les fichiers autorises ci-dessous sont relatifs a TON worktree. Tous les autres sont en lecture seule. Ne cree pas de dependance sur le travail non termine d'un autre agent.
- Si un changement hors perimetre est indispensable, ne le fais pas : indique le besoin precis au coordinateur. Aucune modification de contrat public, migration ou refonte transversale non prevue.
- Pas de commit, push, merge, deploiement, build TestFlight ou modification de donnees reelles. Aucun acces aux dossiers patients, Airtable, Gmail, NocoDB de production ou secrets pour les tests.
- Pas de nettoyage global, pas de git reset/checkout destructif, pas de formatage hors perimetre. N'affaiblis pas les tests existants pour les faire passer.

## Verification et livraison

- Donnees synthetiques et services simules. Aucun test ne doit declencher un e-mail, une vraie synchronisation, un webhook ou une ecriture distante.
- Installe et teste les dependances seulement dans ton worktree. Pour Flutter, le script tool/test_safely.sh utilise un dossier temporaire fixe sous TMPDIR : donne-lui un TMPDIR propre a ta mission, cree avec mktemp -d, afin de ne pas effacer les tests d'un autre agent. Ne modifie pas le script partage.
- Livrable : modifications locales dans ton worktree, tests de regression, et rapport dans le fichier autorise ci-dessous. Indique le chemin absolu du worktree, la branche, le SHA de base, les fichiers modifies/ajoutes, les commandes et resultats, les limites et besoins d'integration.
- Distingue analyse statique, reproduction automatisee et validation sur appareil. Ne promets ni absence totale de regression ni gain de performance non mesure.

## Fichiers autorises en ecriture

- server/nocodbMcpClient.mjs
- server/nocodbRequestDeadline.mjs (nouveau module facultatif)
- server/nocodbRequestDeadline.test.mjs (nouveau)
- docs/retour-agent-2.md

## Mission

Branche proposee : codex/audit-nocodb-timeouts.

Ajoute une limite de temps explicite aux appels REST NocoDB, sans changer les signatures publiques utilisees par les routes. La limite doit couvrir fetch ET la lecture du corps, annuler effectivement la requete et liberer timers/listeners sur tous les chemins. Prevois une configuration optionnelle validee avec valeur par defaut expliquee et compatible avec les gros uploads.

Preserve les statuts, payloads d'erreur et mecanismes de transport existants. Ne transforme pas une erreur ou un timeout en liste vide. N'ajoute aucun retry automatique d'ecriture : une requete abandonnee peut deja avoir ete appliquee cote serveur. Examine aussi les fallbacks existants pour qu'un timeout ne declenche pas une seconde mutation ; si une correction exige un autre fichier, signale-la au coordinateur.

Tests sans reseau reel : reponse normale, fetch bloque, corps bloque, erreur HTTP, erreur reseau, configuration invalide, nettoyage des timers et nombre exact de tentatives. Ne modifie pas server/index.mjs, reserve a l'agent 1.

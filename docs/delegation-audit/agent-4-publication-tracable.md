# Agent 4 - Publication fiable et tracable (F19)

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

- .github/workflows/build-deploy-api.yml
- .github/workflows/flutter-web-build.yml
- aid_habitat_app/tool/build_native_release.sh
- tools/release-artifact-check.mjs (nouveau module facultatif)
- tools/release-artifact-check.test.mjs (nouveau)
- docs/retour-agent-4.md

## Mission

Branche proposee : codex/audit-release-traceability.

Corrige les faux succes de publication : un webhook en erreur reseau ou non-2xx doit faire echouer le job ; une publication staging ne doit pas mettre a jour latest/production. Preserve les parcours manuels et les valeurs par defaut legitimes apres lecture des usages.

Ajoute une tracabilite locale des builds natifs : manifest avec SHA, etat dirty, version/numero, SDK et cible API sans secrets ; symboles ranges par build pour ne pas ecraser ceux d'un autre binaire. Rends explicite l'acceptation d'un arbre sale pour une distribution ; ne supprime pas silencieusement la possibilite de builds locaux de developpement. Ne pretend pas garantir l'unicite TestFlight sans consulter un service distant : distingue controles locaux et verification distante restante.

Ne change ni le numero de build, ni pubspec, ni la version Node, ni Docker, ni un endpoint serveur. Si une preuve du SHA actif exige un endpoint absent, rends cette dependance au coordinateur au lieu de l'inventer.

Teste syntaxe et decisions avec fixtures et commandes simulees. N'execute aucun workflow distant, webhook, export Xcode, signature, publication ou upload. Les tests doivent prouver echec non-2xx, isolation staging/production et absence d'ecrasement des symboles.

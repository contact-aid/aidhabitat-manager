# Agent 3 - Compression d'images hors interface (partie F12)

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

- aid_habitat_app/lib/services/image_compressor.dart
- aid_habitat_app/lib/services/image_compression_worker.dart (nouveau module facultatif)
- aid_habitat_app/test/services/image_compressor_worker_test.dart (nouveau)
- docs/retour-agent-3.md

## Mission

Branche proposee : codex/audit-image-compression.

Deporte le decodage/redimensionnement/encodage CPU de compressImageForUpload hors de l'isolate d'interface sur les cibles natives. Preserve la signature, CompressedImage, les options, seuils, dimensions, qualite, noms, MIME et comportements de repli actuels. Utilise les bibliotheques deja presentes ; pas de changement de pubspec ou lockfile.

Conserve un chemin web compilable et explique sa limite : compute ne garantit pas un travail hors du thread principal sur web. Ne touche pas a la rotation, aux annotations, aux previews, a PDFKit ou aux repositories. Ne profite pas de cette mission pour modifier la politique de compression ou corriger un changement de format : note ces besoins separement.

Tests sur images synthetiques : fichier sous seuil, grande image, PNG, fastResize, donnees invalides/format non decode, resultat plus gros que l'original, coherence bytes/MIME/extension. Compare le comportement de sortie avant/apres avec les memes entrees. Mesure separement temps total et reactivite native quand l'environnement le permet ; ne conclus pas a la fluidite iPad sur la seule base de tests unitaires. Utilise un TMPDIR isole pour les tests Flutter.

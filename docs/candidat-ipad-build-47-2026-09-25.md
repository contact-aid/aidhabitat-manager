# Candidat iPad TestFlight 1.0.0+47 — 25 septembre 2026

## Périmètre

- Build TestFlight actuellement installé, confirmé par capture : `1.0.0 (29)`.
- Web et API de production vérifiés le 25 septembre : build web `1.0.0+46`, SHA `9ac86f9b982efe4ba06e1851cbdec60ab3fa0964`, API `https://api.aidhabitat.fr` au même SHA.
- Candidat natif : le code applicatif du SHA de production, avec le numéro de build iOS porté à `47` dans `aid_habitat_app/pubspec.yaml`.
- Aucune modification du contrat API, des données de production ni du comportement de synchronisation dans cette préparation.

## Vérifications effectuées

- `npm run test:server` : 288/288 réussis.
- `npm run test:sync-contract` : 12/12 réussis et contrôle des contrats réussi.
- `npm run check:critical` : 20/20 réussis.
- `bash aid_habitat_app/tool/test_sync_critical.sh` dans un répertoire temporaire sans apostrophe : 741/741 réussis.
- `flutter analyze --no-pub` dans la copie temporaire : aucune anomalie.
- `AIDHABITAT_API_BASE_URL=https://api.aidhabitat.fr bash aid_habitat_app/tool/release_preflight.sh --ios-only` : Xcode 26.6, SDK iOS 26.5, configuration iPad et espace disque OK ; **certificat Apple Distribution absent du trousseau**, donc préflight en échec.

## Avant archive et diffusion

1. Confirmer dans App Store Connect que le numéro `47` est disponible pour la version `1.0.0`.
2. Installer ou rendre accessible un certificat Apple Distribution valide et relancer le préflight iOS.
3. Construire depuis un checkout propre de ce candidat avec `AIDHABITAT_API_BASE_URL=https://api.aidhabitat.fr` et conserver le manifeste de build ainsi que les symboles Dart. Le script de distribution refuse normalement un arbre Git modifié : ne pas utiliser `--allow-dirty` pour ce candidat.
4. Vérifier l'archive et la signature dans Xcode, puis envoyer à TestFlight. Aucun build ni upload n'a été effectué pendant cette préparation.
5. Sur un dossier témoin sans données réelles : contrôler la conservation des données après mise à jour de l'iPad, le mode hors ligne, la reprise de synchronisation, les notes, les documents, les préconisations et le PDF ; comparer ensuite avec la webapp.

Les deux écrans de caisses de retraite modifiés dans le répertoire de travail avant cette préparation sont hors de ce candidat et ne doivent pas être ajoutés par mégarde à son commit ou à son archive.

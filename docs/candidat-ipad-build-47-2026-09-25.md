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
- `bash aid_habitat_app/tool/test_sync_critical.sh` depuis une copie propre du commit candidat, dans un répertoire temporaire sans apostrophe : 741/741 réussis.
- `flutter analyze --no-pub` dans cette copie propre : aucune anomalie.
- Le préflight local reconnaît Xcode 26.6, le SDK iOS 26.5, la configuration iPad et l'espace disque. Son contrôle de trousseau ne voit pas de certificat Apple Distribution local ; Xcode a néanmoins exporté l'IPA avec un certificat **Cloud Managed Apple Distribution** valide pour l'équipe `HRFWLL68V9` (voir `DistributionSummary.plist`). Ce contrôle du préflight est donc trop strict pour la signature gérée par Xcode.
- Archive et IPA construites depuis le checkout propre `6499519faeec743c83277baf35001116b68cddc4` avec `AIDHABITAT_API_BASE_URL=https://api.aidhabitat.fr`. Le manifeste indique `status: completed`, `dirty: false`, Flutter 3.38.4 et Dart 3.10.3.
- La signature du paquet exporté passe `codesign --verify --deep --strict` ; version `1.0.0`, build `47`, identifiant `com.aidhabitat.manager` et équipe `HRFWLL68V9` contrôlés dans l'IPA.
- SHA-256 de l'IPA : `fa363496b2d960e11fd92a5364f5c0bb47e85614ef2b85087d5b7bb9aa0a3d59`.
- Flutter signale une image de lancement encore générique ; cet avertissement n'a pas bloqué l'archive.

## Livrables locaux

`/Users/aidhabitat/Downloads/AppErgo-TestFlight-1.0.0-47/` contient l'IPA, `Runner.xcarchive`, le manifeste, les symboles Dart, les options et le résumé d'export, ainsi que `SHA256.txt`. Conserver les symboles pour pouvoir décoder les rapports de crash.

## Avant diffusion TestFlight

1. Confirmer dans App Store Connect que le numéro `47` est disponible pour la version `1.0.0`.
2. Envoyer l'IPA via Xcode Organizer ou Transporter, puis vérifier son état de traitement dans App Store Connect. Aucun upload n'a été effectué pendant cette préparation.
3. Sur un dossier témoin sans données réelles : contrôler la conservation des données après mise à jour de l'iPad, le mode hors ligne, la reprise de synchronisation, les notes, les documents, les préconisations et le PDF ; comparer ensuite avec la webapp.

Les deux écrans de caisses de retraite modifiés dans le répertoire de travail avant cette préparation sont hors de ce candidat et ne doivent pas être ajoutés par mégarde à son commit ou à son archive.

# Rotation et sauvegarde documents - livraison locale

## Isolation

Worktree : `/private/tmp/appergo-fix-rotation-documents`.
Branche : `codex/fix-rotation-documents`.
Base : `772eb86f52a30fbe28ca8c31bd4540ea3890bd2c`.
Patch repris : `/tmp/appergo-rotation-wip-20260914.patch`, preimages verifies,
`git apply --check` puis application dans le worktree propre.
Le commit de livraison est celui contenant ce rapport (`git log -1`).
Aucune modification du repertoire principal, aucun push/deploiement, aucun
acces aux dossiers patients ni ecriture distante. Compilation debug du banc
synthetique uniquement, pas de build de livraison.

## Causes et corrections

1. **Export image confirme** : le patch initial capturait encore le viewport
   pour les images annotees. Sur le meme banc Playwright, une source 480x320
   devient 1173x1760 au premier quart de tour, au lieu de 320x480.
   Reproduction avant correctif dans `/private/tmp/appergo-rotation-before`,
   base commune + patch initial + fixture synthetique identique.
   `document_image_export.dart` compose maintenant les pixels source et les
   annotations normalisees, clippe au rectangle image, puis applique la rotation.
   Ni marges, ni zoom, ni densite ecran ne definissent les dimensions exportees.
   Huit rotations/sauvegardes/reouvertures gardent les dimensions et les pixels
   attendus. Cela demontre le defaut de resolution, pas a lui seul tous les cas
   de retrecissement observes sur un iPad reel.
2. **Faux conflit lors d'un ACK** : comparer l'URL distante a celle de l'ouverture
   rejetait une sauvegarde alors que seule la publication du meme contenu local
   avait termine. Le patch reprend l'identite de revision locale ; extension aux
   data URLs web et aux chemins relocalises. Les controles avant et apres
   preparation restent actifs sur le contenu local, le dossier et les annotations.
   Les tests injectent un ACK avant/pendant preparation et un vrai changement
   concurrent. Une nouvelle revision locale ou de nouveaux octets restent refuses.
   Cette distinction suppose des revisions fichiers immuables ; elle ne detecte
   pas une modification externe en place du meme fichier par un autre programme.
3. **Chemin ancien conteneur** : resolution de la meme cle sous le Documents
   courant pour `document_revisions` et `offline_documents`, uniquement si le
   fichier exact existe. Utilisee en lecture repository, preparation des sidecars
   et upload. Pas de recherche par basename ni de remplacement par une autre
   revision. Si le fichier a reellement disparu, l'operation reste en erreur avec
   son payload original ; aucune suppression pour masquer l'incident.
   TestFlight changeant effectivement le conteneur reste a tester sur appareil.
4. **Apercu web** : le chemin Documents ouvre `DocumentPreview` dans
   `documents_screen.dart`; rotation presente sans condition web et toolbar hors
   transformation. Icone harmonisee en `LucideIcons.rotateCw`. Photos utilise
   `_PhotoFullscreenDialog`, un composant distinct sans ce bouton. L'ancien
   composant React `DocumentsView.tsx` a encore un autre apercu.
   Verification HTTP publique en lecture seule : version 20, release SHA de base
   ci-dessus ; SHA256 main.dart.js
   `edeb5e5d689722bd0f847121bb627730bf3bcba2cb45470c8f541e7306ae3ab1`,
   coherent avec release.json ; racine Flutter et non React.
   Cela ne prouve PAS la version deja chargee dans l'onglet utilisateur.
   Le parcours exact sans bouton reste non reproduit et attend une capture/URL.
   Aucun effacement de cache ni rechargement de navigateur de production.

Le pipeline image ne refait plus une capture ecran suivie d'un decodage/rotation
PNG supplementaire. Aucun gain de latence chiffre revendique : grandes images,
pression memoire et gels sur appareil ne sont pas mesures ici.

## Validation reproductible

Depuis `aid_habitat_app`, `flutter analyze --no-pub` : aucune remarque.
Suites `flutter test --no-pub --reporter expanded` : 92 tests passes ensemble.

- `test/services/document_relocation_upload_test.dart`
- `test/services/document_relocation_test.dart`
- `test/services/document_storage_path_test.dart` (tests existants conserves)
- `test/services/document_image_export_test.dart`
- `test/services/document_revision_save_test.dart`
- `test/services/pdf_ink_test.dart`
- `test/screens/document_preview_revision_test.dart`
- `test/screens/document_preview_save_test.dart`
- `test/screens/document_preview_ink_test.dart`
- `test/services/document_remote_revision_test.dart`
- `test/screens/document_viewport_test.dart`
- `test/components/doc_thumbnail_cache_test.dart`

Upload via MockClient uniquement : fichier relocalise publie, fichier absent
non publie, identite/payload de l'operation conserves. Les tests PDF natifs
utilisent un MethodChannel simule, pas PDFKit sur iPad.

Compilation du banc :
`flutter build web --debug --no-pub --no-web-resources-cdn --no-wasm-dry-run --target tool/web_pdf_preview_smoke.dart --output build/rotation-qa`.
Puis, depuis la racine :
`node tools/rotation-image-smoke.mjs aid_habitat_app/build/rotation-qa` et
`node tools/web-pdf-preview-smoke.mjs aid_habitat_app/build/rotation-qa`.
Chrome par defaut ; `PLAYWRIGHT_CHROMIUM_EXECUTABLE` accepte un Chromium local.
Execution finale avec Chromium Playwright 151 : les deux scripts passent.
Serveur loopback, contextes ephemeres synthetiques, jamais de stockage utilisateur.
Images : annotations, huit rotations offline, reouverture, pixels/dimensions,
toolbar fixe, zoom/pan sans sauvegarde. Le pas exact de 10 % est teste en widget,
pas deduit d'une capture potentiellement clippee.
PDF : vrai worker navigateur, toutes les pages, annotation ancienne sur page non
visitee, dessin, undo, rollback SQLite/retry, sauvegardes, callback de partage.
Captures inspectees desktop 1280x900/tablette 820x1180 et fichiers generes dans
`aid_habitat_app/build/rotation-qa/` (non commites).

## Fichiers livres

Production : `documents_screen.dart`, `document_repository.dart`,
`nocodb_sync_service.dart`, `pdf_ink_geometry.dart`, nouveaux services
`document_image_export.dart` et `document_storage_path.dart`.
Tests : nouveaux export/relocation/upload, extensions revision_save/pdf_ink.
Banc : `tool/web_pdf_preview_smoke.dart`, `tools/rotation-image-smoke.mjs`,
option executable Chromium dans `tools/web-pdf-preview-smoke.mjs`, ce rapport.
Pas de changement backend, authentification, schema ou audits Apple.

## Recette iPad et conditions restantes

1. Sur dossier de test, image paysage/portrait et PDF multipage : annoter,
   tourner, sauvegarder huit fois, fermer/reouvrir. Comparer miniature, apercu
   et fichier partage ; aucune page ni annotation perdue.
2. Mode avion : sauver, tuer puis relancer l'app ; verifier contenu local,
   operation pending et reprise online. Observer la pastille sans quitter Documents
   et verifier que les autres documents ne se rechargent pas inutilement.
3. Faire terminer une sync pendant preparation puis entre deux sauvegardes.
   L'ACK du meme contenu ne doit pas afficher de conflit. Injecter une vraie
   revision concurrente sur environnement de test : refus et saisie recuperable.
4. Mise a jour TestFlight avec upload pending : verifier fichier exact relocalise.
   Pour un fichier reellement absent, conserver erreur et operation pour diagnostic.
5. Valider gestes iPad, grandes photos/PDF et temps de sauvegarde sous pression
   memoire. Les simulations ne certifient ni absence de freeze ni performance native.
6. Identifier l'apercu web sans rotation et sa version chargee ; ne pas attribuer
   le probleme au cache par elimination. Tester le partage OS et les pastilles
   sur appareils reels apres integration.

Livraison locale exploitable, mais ces points de recette restent necessaires
avant de declarer tous les incidents terrain resolus.

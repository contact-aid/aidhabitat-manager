# Integration build 28

## Perimetre

Worktree : /private/tmp/appergo-integration-build28.
Branche : codex/integration-build28. Base : 06cf6cff54cbc2cc90bbd869a3f2d75ba9649249.
Les worktrees sources sont conserves sans modification ni suppression.

Integre :
- Les correctifs web 26/27 d'attribution locale (base de comparaison a115aaa..c6b3f99).
- Les descriptions de preconisations a deux lignes, defilement et confinement
  du fantome de deplacement dans son onglet ; drag depuis l'image seulement.
- L'identite canonique des documents importes pour les remplacements apres rotation.
  Application des hunks par fusion trois voies, sans remplacer les protections
  de suppression/revision deja presentes dans main.
- La hauteur commune des photos visite et de leurs pages de suite dans le PDF.
- La famille iPad uniquement dans les trois configurations Xcode.
- Le registre de conservation administrateur, sans aucune suppression automatique,
  et les routes Nginx de confidentialite qui retournent 404 sans notice validee.
- Version unifiee 1.0.0+28 et tests de regression ajoutes au controle CI Flutter.

## Inventaire des autres travaux

Les modifications de notes, suppression de documents, cache media, client API,
synchro et reecriture du worktree appergo-document-deletion-fix sont deja
identiques a main. Ses variantes de build/worker IA sont plus anciennes : elles
retireraient des tests et des instructions de conservation d'identifiants.
Elles ne sont pas reprises. Les tests/recherche wiki de rotation-build20 sont
egalement identiques a main. Les variantes candidate20/rotation-before sont
des etapes de diagnostic anciennes, avec leurs tests deja presents dans main.

Hors livraison : worktrees de preparation des sessions v2/multi-entreprises,
migrations, notices Apple/confidentialite non validees, dossiers output, caches,
secrets, modeles et binaires non suivis. Ce ne sont pas des correctifs autonomes
prets a activer. Le brouillon de notice est explicitement marque non publiable.
Aucune nouvelle activation de sessions, migration ou changement NocoDB.

## Verification locale

- `npm run test:server` : 197 tests reussis, donnees synthetiques.
- `TMPDIR=<dossier isole> bash aid_habitat_app/tool/test_safely.sh test` :
  863 tests Flutter reussis.
- `flutter analyze` : aucune anomalie.
- `npm run test:sync-contract` et `npm run check:critical` : reussis.
- Tests privacy-route (avec vrai Nginx Docker), release-artifact-check,
  publication-workflows et api-health-version : 24 tests reussis.
- Tests wait-api-readiness : 18 reussis dans un dossier hors /private.
  Le premier passage dans /private/tmp echoue a cause du mot private dans la
  stack locale ; test et implementation inchanges pour le second passage.
- Tests local_ai config/offline-worker/worker : 14 reussis.
- `plutil -lint` : projet valide ; `xcodebuild -showBuildSettings` confirme
  TARGETED_DEVICE_FAMILY=2. Minimum iPadOS existant 26.5 conserve, non abaisse.
- Photos PDF : reproduction sur l'ancien generateur et controle visuel de
  28 images synthetiques sur plusieurs pages, decrits dans le rapport dedie.

Ces verifications ne remplacent pas un test terrain iPad. Les avertissements
XRef deja presents dans le gabarit PDF ne sont pas corriges ici.

## Publication et rollback

Construire et verifier les artefacts au SHA exact du commit ; utiliser les
digests immuables dans EasyPanel. Verifier /api/health/live et /api/health/ready
ainsi que release.json et le hash du bundle web apres deploiement.
Le code serveur de main avant integration est identique a celui de l'API
live 772eb86 pour server/shared/package*. La mise a jour API porte donc sur
le PDF et le registre de conservation, pas sur un nouveau contrat client.

Conserver les digests precedents des services pour rollback. Aucune suppression
de file locale, ni mutation patient pour tester la production. Une image ancienne
ignore le registre supplementaire ; ne pas effacer ce fichier au rollback.
L'envoi TestFlight est distinct des publications web/API et requiert la
confirmation du perimetre et la verification de signature avant upload.

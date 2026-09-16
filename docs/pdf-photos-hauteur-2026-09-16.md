# Hauteur uniforme des photos du rapport

- Worktree : /private/tmp/appergo-pdf-photos-hauteur
- Branche : codex/pdf-photos-hauteur, base 06cf6cf.
- Aucun changement dans le repertoire principal, aucune donnee reelle utilisee.
- Cause : le contain-fit ajuste chaque image independamment aux colonnes.
- Correctif : hauteur commune calculee sur toutes les photos visite resolues,
  bornee par la hauteur du gabarit et la largeur disponible de chaque colonne.
  Proportions, ordre, categories, etiquettes et pagination sont conserves.
  Un panorama extreme peut reduire la hauteur commune ; aucun recadrage impose.
- Perimetre : Photos du logement, Accessibilite, Sanitaires et pages de suite.
  Les plans et les images de preconisations ne sont pas modifies.
- Tests : `node --test server/photoLayout.test.mjs test/precoPhotoCatalog.test.mjs`
  : 9 reussis. Le test du vrai generateur couvre 28 images synthetiques sur
  plusieurs pages, les hauteurs, proportions et limites de page.
  Le meme test echoue sur le generateur de base pour des hauteurs differentes.
- Controle visuel : pages 9 et 10 du PDF synthetique rendues avec Poppler.
  Des avertissements XRef sont emis par Poppler : reproduits aussi sur le
  generateur de base, non corriges dans ce patch de mise en page.
- Fichiers : server/reports/generateVisitReport.mjs,
  server/reports/photoLayout.mjs, server/photoLayout.test.mjs, ce document.
- Pas de commit, push ou deploiement. Integration et deploiement API necessaires
  pour rendre le changement visible dans les nouveaux rapports de production.

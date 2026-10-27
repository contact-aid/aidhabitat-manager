# Scanner Apple en plein écran portrait et en français

## Retour terrain et changement

Le build 104 pouvait afficher des commandes coupées lors du scan. VisionKit était intégré avec `addChild` et sa vue était redimensionnée manuellement dans un contrôleur portrait. Cette intégration est remplacée par la présentation modale native recommandée par Apple. Le retour terrain reste à revérifier sur l’appareil ; la compilation seule ne valide pas le cadrage réel de la caméra.

Le nouveau parcours ouvre un écran de transition plein écran en portrait, puis présente `VNDocumentCameraViewController` en plein écran une fois que la scène et ses dimensions sont en portrait, hors transition UIKit. Le scanner est créé à ce moment-là. Il ne s’agit pas de lancer une application Apple séparée : VisionKit est présenté dans App’Ergo.

L’utilisateur peut tenir l’iPad en portrait pendant toute la capture et la relecture. À l’enregistrement ou à l’annulation, l’ensemble du parcours natif est fermé, l’orientation paysage précédente est demandée à nouveau sur iPad, puis le résultat suit le circuit PDF/import existant. Si le parcours a été ouvert en portrait sur iPad, le retour demandé est aussi en paysage. La politique iPhone reste inchangée.

Si iPadOS refuse la rotation, le scanner ne s’ouvre pas dans une zone mal dimensionnée. L’écran « Tournez l’iPad en portrait pour scanner le document. » reste annulable et attend un changement de géométrie. Le mode plein écran système reste nécessaire pour que l’OS honore la rotation ; une fenêtre redimensionnable peut imposer ses propres restrictions.

## Langue

Le projet Xcode déclarait `developmentRegion = en` et le bundle ne déclarait aucune localisation française. La région de développement devient `fr` et `CFBundleLocalizations` déclare `fr`. UIKit/VisionKit disposent ainsi du français comme langue de l’application pour leurs commandes natives (notamment la validation du scan). Aucun renommage par exploration des sous-vues privées d’Apple, aucune modification de la langue de l’iPad.

## Validation

- Les six tests existants du service Flutter passent : PDF multipage, annulation, photo et erreurs.
- Contrôle des fichiers plist et du diff.
- Compilation iOS Release sans signature réussie avec Xcode 27.1.
- Inspection du bundle compilé : `CFBundleDevelopmentRegion = fr`, `CFBundleLocalizations = [fr]`. Foundation sélectionne `[fr]`, y compris avec des préférences `[en, fr]`. Cela contrôle la configuration de langue, sans remplacer la vérification visuelle des boutons VisionKit.

La recette caméra et rotation sur appareil physique reste à effectuer. Aucun déploiement ni remplacement de l’application installée dans le cadre de cette PR.

Recette : partir de Documents en paysage ; toucher Scanner ; tourner l’iPad ; vérifier que toute la hauteur est utilisée et que les boutons Apple sont visibles en français ; scanner deux pages, recadrer et enregistrer ; contrôler le PDF dans le dossier et le retour paysage. Refaire avec Annuler, une deuxième ouverture immédiate, un démarrage en portrait, ainsi qu’une photo classique. Vérifier aussi que l’écran de rotation s’annule lorsque le système empêche le portrait.

Références : [présentation native VisionKit](https://developer.apple.com/documentation/visionkit/vndocumentcameraviewcontroller), [langue par défaut du bundle](https://developer.apple.com/documentation/bundleresources/information-property-list/cfbundledevelopmentregion).

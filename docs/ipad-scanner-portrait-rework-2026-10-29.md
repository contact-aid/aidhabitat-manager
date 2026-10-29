# Scan et photo : ouverture portrait sans écran d’attente bloqué

La capture terrain du 29 octobre montre l’écran « Tournez l’iPad en portrait… » déjà affiché dans une vue verticale. L’ancien hôte exigeait simultanément une orientation de scène `.portrait`, des dimensions verticales et l’absence de coordinateur de transition. Une géométrie de scène décalée ou la fin de la présentation modale sans nouvelle passe de layout pouvait empêcher toute ouverture de VisionKit. Une rotation refusée par iPadOS laissait aussi cet écran affiché indéfiniment.

## Comportement

- Le scan PDF et la photo utilisent le même hôte natif plein écran avec préférence portrait, sans verrouillage d’orientation pendant la transition vers la caméra.
- L’ouverture se base sur les dimensions réellement affichées, sans attendre une valeur d’orientation de scène concordante. Une transition UIKit en cours est suivie jusqu’à sa fin avant de présenter la caméra.
- En cas de rotation refusée, ou après deux secondes sans géométrie portrait, la caméra est présentée nativement dans la fenêtre disponible. Cette solution évite un écran d’attente infini. UIKit dimensionne la caméra et ses commandes, sans intégration manuelle de ses sous-vues.
- Annuler invalide les ouvertures différées. La fermeture du scan ou de la photo retire l’ensemble des écrans natifs, demande le retour au paysage précédent sur iPad et protège le résultat contre une double fermeture.
- Le scan vérifie désormais explicitement l’autorisation caméra, comme la photo. Le circuit existant de production du PDF et d’import des fichiers est conservé.

Le portrait reste une demande système : une fenêtre iPadOS redimensionnable peut la refuser. La disposition des commandes appartient au scanner/appareil photo Apple. Leur position exacte à droite et leur visibilité doivent être validées sur le modèle d’iPad utilisé. Ce correctif ne dessine pas de commandes caméra personnalisées.

## Validation automatisée

Résultats : **6 tests Flutter réussis et 6 tests UIKit réussis** sur simulateur iPad Pro 13 pouces, iOS 27.0, avec Xcode 27.1. Les tests UIKit vérifient notamment la fermeture unique et la demande de restauration du paysage. La rotation physique n’est pas simulée : une première assertion sur l’orientation effective a échoué lorsque le système a refusé la rotation en mode fenêtré ; le test final vérifie explicitement la demande envoyée au système.

Les tests Flutter du service couvrent photo, refus caméra, annulation, résultat PDF multipage et plateformes non iOS.

Les tests UIKit dans `ios/RunnerTests/RunnerTests.swift` utilisent une caméra factice, et exécutent le vrai code Swift de présentation. Le lanceur `tool/test_document_scanner_native.rb` crée une application native de test séparée dans `build/scanner-harness`, avec le framework Flutter du SDK local et les mêmes sources de scanner. Il permet de tester les transitions sans lancer le moteur Flutter ni dépendre du démarrage de l’application métier :

```sh
flutter test test/services/document_scanner_service_test.dart
ruby tool/test_document_scanner_native.rb SIMULATOR_UUID
```

La compilation de l’application complète par Xcode a abouti avant le lancement des tests. Le lancement de l’application complète sur le simulateur iOS 27 a échoué sur un problème préexistant de cycle de vie UIScene : le manifeste ne fournit aucune configuration de scène. La migration de ce démarrage reste hors du correctif scanner. Les tests natifs isolés ne constituent donc pas une validation de bout en bout de l’application complète.

## Recette physique requise avant diffusion

Sur un iPad de test, depuis Documents en paysage : ouvrir Scanner, vérifier le passage portrait, le flux caméra et les commandes entièrement visibles, notamment celles attendues à droite ; prendre deux pages, recadrer, enregistrer ; contrôler le PDF et le retour paysage. Refaire avec Annuler, Photo, une réouverture immédiate, un refus d’autorisation caméra, puis en fenêtre iPadOS et avec le verrouillage système de rotation. Vérifier aussi la persistance et la synchronisation du document importé.

Aucun upload TestFlight ni déploiement de production n’est effectué pour ce correctif avant cette recette.

Références : [orientations prises en charge](https://developer.apple.com/documentation/uikit/uiviewcontroller/supportedinterfaceorientations), [demande de géométrie](https://developer.apple.com/documentation/uikit/uiwindowscene/requestgeometryupdate(_:errorhandler:)), [verrouillage de l’orientation](https://developer.apple.com/documentation/uikit/uiviewcontroller/prefersinterfaceorientationlocked).

## Application physique de recette

Une application indépendante **Scan Test** (`com.aidhabitat.scannertest`, version 1.0, build 2) a été compilée, signée, installée et lancée sur l’iPad de test connecté sous iPadOS 26.6.1. App’Ergo (`com.aidhabitat.manager`, build 106) reste installée à côté.

Cette application exécute le même `DocumentScannerPlugin.swift`, avec un écran d’accueil paysage, deux boutons scan/photo, l’aperçu local du PDF ou de l’image et un export système facultatif. Elle n’initialise pas le moteur Flutter et n’appelle aucun serveur. Elle sert à valider la caméra et les transitions natives ; elle ne valide pas l’import ou la synchronisation des dossiers dans App’Ergo. La recette manuelle du parcours scan a été effectuée sur l’iPad de test : aperçu dans le bon sens en portrait, PDF enregistré dans le bon sens et retour à l’écran paysage, confirmés par Renan. Les autres cas de la recette restent à vérifier.

Construction : `ruby aid_habitat_app/tool/scanner_device_test/build.rb DEVICE_UDID`, depuis la racine du dépôt. Les sources et le lanceur sont dans `aid_habitat_app/tool/scanner_device_test/` ; le bundle signé est produit dans `aid_habitat_app/build/scanner-device-test/DerivedData/Build/Products/Release-iphoneos/ScanTest.app`.


## Correction du décalage de 90 degrés, validée sur appareil

Le premier essai physique ouvrait le scanner dans un écran portrait, mais le flux caméra restait tourné de 90 degrés avec des bandes noires. La préférence `prefersInterfaceOrientationLocked = true` de l’hôte a été retirée : elle pouvait conserver l’ancienne géométrie paysage pendant le passage à VisionKit. Le masque portrait et la présentation plein écran sont conservés ; la scène peut maintenant terminer sa rotation pendant la transition caméra.

Le build 2 de Scan Test a été recompilé, signé, installé et lancé sur l’iPad de test. Renan a confirmé l’aperçu dans le bon sens, puis le PDF enregistré dans le bon sens et le retour en paysage. Une capture directe de l’iPad montre le flux caméra remplissant l’écran portrait, avec les commandes à droite. Les six tests natifs ont été relancés avec succès après ce changement, dont le contrôle que l’hôte ne verrouille plus l’orientation. Cela valide le parcours natif sur cet appareil ; l’import et la synchronisation dans l’application Flutter complète restent hors de cette application de recette.

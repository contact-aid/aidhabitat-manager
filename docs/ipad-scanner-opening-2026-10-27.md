# Ouverture du scanner iPad en portrait

## Diagnostic

Le message `scan_portrait_unavailable` vient du gestionnaire d’erreur de `requestGeometryUpdate`, ajouté par la PR #50. Toute erreur de rotation provoquait la fermeture de VisionKit et le message générique « Ouvrez l’app en plein écran ». L’erreur native était ignorée : la capture seule ne permet pas d’identifier son code ni de conclure que l’app était en mode fenêtre.

Trois points rendaient la demande fragile : le contrôleur demandait le verrouillage avant d’avoir atteint le portrait, le masque de l’application restait piloté par Flutter, et `UIRequiresFullScreen` était désactivé. Apple peut aussi refuser la rotation selon le mode de fenêtrage.

## Correctif

- Le masque de l’application autorise le portrait pendant le scanner, puis revient à la politique Flutter à sa fermeture.
- Le verrouillage iPadOS 26 ne s’active qu’une fois la scène en portrait. Les notifications de changement sont limitées aux changements effectifs.
- Le mode plein écran est demandé dans la configuration iOS. Cela retire Split View sur les versions qui honorent encore cette option. Les versions récentes d’iPadOS peuvent la traiter différemment.
- Un refus de rotation laisse VisionKit ouvert et journalise l’erreur native, sans abandonner la capture.
- L’orientation précédente est demandée à nouveau après fermeture. La capture reste occupée jusqu’à la fin de la fermeture, pour éviter une deuxième ouverture concurrente.

Le scan Apple, son recadrage et son export PDF multipage restent utilisés. Le portrait de l’interface n’impose pas un format papier A4 au PDF : les dimensions des pages suivent celles des images recadrées par VisionKit.

## Vérification

La compilation iOS Release sans signature réussit avec Xcode 27.1 (`flutter build ios --release --no-codesign --no-pub`). Le fichier Info.plist est valide et `git diff --check` passe.

Les six tests existants de `document_scanner_service_test.dart` passent. Ils contrôlent le contrat Flutter et ne vérifient pas la rotation UIKit.

Recette physique nécessaire : ouvrir Documents en paysage, Scanner, vérifier l’ouverture en portrait, scanner deux pages, enregistrer, vérifier le PDF et le retour en paysage. Refaire avec Annuler, avec rotation physique et verrouillage système activé, puis rouvrir le scanner. Si le fenêtrage refuse le portrait, vérifier que la capture reste utilisable. Contrôler également la prise de photo classique.

Aucun appareil physique n’est disponible pendant cette vérification. Aucune installation, publication TestFlight ou modification de dossier métier n’est effectuée.

Références : [orientations UIKit](https://developer.apple.com/documentation/uikit/uiviewcontroller/supportedinterfaceorientations), [rotation de scène](https://developer.apple.com/documentation/uikit/uiwindowscene/requestgeometryupdate(_:errorhandler:)), [évolution du mode plein écran](https://developer.apple.com/documentation/technotes/tn3192-migrating-your-app-from-the-deprecated-uirequiresfullscreen-key).

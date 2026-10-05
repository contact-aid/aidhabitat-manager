# Livraison minimale de récupération — préparation du 5 octobre 2026

## Références et responsabilité

Production web/API : `e8a4459d5066b8ac4cc5e8a0212a1f29bf97433f` (web 1.0.0+69).
Correctif source de l’agent incident : `f6da7d4`, parent `0d9728c965ce0ef81cafdb00e40ce949f51e2e74`.
Tests du vrai adaptateur livrés séparément par cet agent : `6da70ff`.
Main est le seul intégrateur de la récupération. L’agent incident travaille dans son propre worktree ; le nouveau coordinateur reste en lecture seule. Aucun service n’est modifié pendant cette préparation.

Deux candidats distincts :

- Serveur et vérification web69 : `codex/appergo-recovery-candidate-20261005`, basé sur la production69. Aucun lot fonctionnel supplémentaire.
- iPad minimal : `codex/appergo-ipad-recovery-64-20261005`, basé exactement sur `a5b4d9fbe40579160a9290688a7707e7a3376c2c`. Uniquement récupération et diagnostic, sans reprendre les changements d’interface web65–69. Version locale candidate70 ; disponibilité App Store Connect à confirmer avant toute distribution.

Aucun upload TestFlight, aucune publication, installation, migration ni écriture NocoDB autorisé par cette préparation.

## Correctif retenu et relecture

- Une opération `NOTE_PAGE_RECORD_MISSING` peut être remise en file sur choix explicite « Conserver ma note locale », après GET authentifié réussi avec liste vide valide. Configuration absente, erreur, réponse malformée ou identité différente ne prouvent jamais une absence.
- Texte et dessin locaux restent présents ; nouveau writeId pour la résolution, révision attendue nulle. L’accusé de réception normal reste requis.
- Serveur : identité logique contrôlée, doublons signalés sans suppression, révision exacte requise même avec l’ancien réglage preferLocal. Une sauvegarde64 obsolète reçoit un conflit au lieu d’écraser une version concurrente.
- Rejeu du même writeId et des mêmes contenus ; URL d’aperçu canonique conservée. Une réponse perdue se confirme par relecture.
- Création et upsert partagent un verrou par groupe de pages : les tests ont reproduit puis corrigé deux créations recevant le même numéro.
- Aucun nettoyage automatique des doublons ou des notes vides dans ces écritures. Une décompression impossible provoque une erreur ; elle ne devient pas une note vide.
- Compression sans perte. Un dépassement après gzip/base64 est refusé en413, avec conservation locale. **Ce refus ne transfère pas le contenu.**

## Limite de concurrence avant publication

Le verrou est local au processus. Il faut vérifier un unique processus écrivain/une seule réplique API, et l’absence d’un autre écrivain NocoDB sur les pages pendant la récupération. Une bascule avec ancien et nouveau processus simultanés nécessite une fenêtre coordonnée. Aucune garantie d’unicité inter-instances n’est affirmée ; en cas de plusieurs écrivains, arrêter cette étape et préparer un verrou distribué ou une unicité transactionnelle validée. Ne pas changer le schéma en production dans le cadre présent.

## Notes indépendantes : non intégrées

La fusion virtuelle avec `899bb2e` produit un conflit dans `server/mobileSyncStore.mjs`. Au-delà du conflit Git, ce lot réintroduit une priorité locale et ajoute le marqueur `noteTextInitialized`, son initialisation et un verrou limité à certaines notes. Le client minimal64 conserve la sémantique64 des notes : il ne corrige pas la réapparition d’un ancien texte sur une page secondaire après effacement. **Ne pas publier le lot notes indépendantes avec cette récupération.**

Son intégration future devra préserver les protections de récupération, garder le marqueur lors d’une écriture d’ancien client, et rejouer les tests d’import, effacement, réponse perdue et concurrence. Aucun import Airtable ou initialisation d’anciennes notes n’est effectué ici.

## Deux opérations, deux dossiers de preuve

1. Plan : page technique1 absente à la dernière lecture, opération en conflit. La page affichée1/2 ne désigne pas nécessairement l’index technique1. L’absence constatée ne prouve pas l’origine de la perte distante.
2. Opération500 : onglet, identité et cause toujours inconnus. Le refus LongText historique d’un autre bénéficiaire ne permet aucune attribution.

Le nouveau client propose « Toucher pour le diagnostic » dans les sauvegardes en attente. Le diagnostic individuel, autorisé seulement au propriétaire courant, lit sans modifier : operationId, identité locale, dates, état/tentatives, writeId/révision, portée/page, taille et SHA256 du dessin en file et du dessin local, égalité des deux copies. Aucun texte, trait, image, jeton ou corps d’erreur brut n’est exporté. Les erreurs nouvelles gardent code HTTP, code structuré et requestId.

Le serveur journalise requestId, writeId/identité technique, dates, statut, taille brute/compressée et SHA256, sans le contenu. Une erreur500 d’avant ce correctif n’acquiert pas rétrospectivement ces métadonnées. Une erreur survenant avant le middleware applicatif doit être corrélée dans les journaux du proxy.

### Si la seconde opération dépasse réellement la limite

Conserver la file, la note locale, la sauvegarde chiffrée et les empreintes. Ne pas tronquer, rasteriser, simplifier les traits, vider la file ou créer une page vide. Préparer séparément un transfert sans perte, avec fragments chiffrés ou stockage objet : identités stables, numéro/total, empreinte par fragment et globale, reprise idempotente, contrôle d’accès, assemblage vérifié, puis écriture de référence sous révision et relecture. Maintenir l’original jusqu’à comparaison complète. Ce mécanisme de stockage n’est pas implémenté ni déclaré compatible64 dans ce candidat ; il faudra le valider avant nouvelle tentative de cette opération. Si la cause500 est différente, corriger sa cause démontrée sans modifier arbitrairement le contenu.

## Sauvegarde : prérequis bloquant d’installation

État observé : Finder voit l’iPad de Christelle, chiffrement local désactivé, dernière sauvegarde iCloud indiquée10:08. Mac ~11,5Go libres, iPad ~12,6Go de documents/données. Espace suffisant non démontré. Appareil ensuite déconnecté. Aucune sauvegarde locale réussie revendiquée.

L’utilisateur doit dégager suffisamment d’espace ou choisir un emplacement externe avant la sauvegarde ; aucun dossier personnel ni sauvegarde existante n’est supprimé. Le disque AIDHABITAT a de la place mais n’a pas été configuré comme destination ; ne pas déplacer le stockage système de sauvegarde sans accord.

Dans Finder : sélectionner l’iPad, sauvegarde complète sur Mac, cocher « Chiffrer la sauvegarde locale ». L’utilisateur saisit et conserve le mot de passe lui-même, jamais dans le chat. Attendre la fin ; vérifier date/heure récente, absence d’erreur, puis « Gérer les sauvegardes » : bon appareil et cadenas. Archiver la sauvegarde pour empêcher qu’une prochaine sauvegarde l’écrase. Si un contrôle de manifeste devient possible avec accès autorisé : IsEncrypted=true, SnapshotState=finished, date et identité cohérentes. La seule case cochée ne prouve pas la fin réussie.

La clé SQLCipher existante utilise `KeychainAccessibility.unlocked_this_device`. Ne pas promettre une restauration sur un autre iPad. Préserver le même appareil, bundleID et trousseau ; ne pas désinstaller, réinitialiser ou réinstaller64 en guise de rollback. Les essais de récupération d’une sauvegarde se font uniquement sur un environnement explicitement autorisé, jamais en réinitialisant l’iPad incident.

Références Apple : [sauvegarde Mac](https://support.apple.com/en-us/108796), [chiffrement/cadenas/date](https://support.apple.com/en-mt/108353), [clé liée à l’appareil](https://developer.apple.com/documentation/security/ksecattraccessiblewhenunlockedthisdeviceonly).

## Ordre après autorisation distincte

1. Confirmer sauvegarde chiffrée terminée et conservée ; relevé des deux opérations et copies serveur privées en fichiers distincts. Geler les éditions du dossier durant la comparaison.
2. Vérifier topologie d’écriture ; publier seulement le serveur corrigé, image épinglée, conserver l’image69 actuelle. Contrôler SHA/live/ready et comportement ancien64 sans écriture de test en production.
3. Distribuer et installer le client minimal sur le même iPad **comme mise à jour**, sans désinstallation. BundleID `com.aidhabitat.manager`, mêmes groupes trousseau, même SQLCipher et schéma local. Vérifier date/version, connexion au bon compte, présence de la base et des deux opérations avant toute résolution.
4. Relever diagnostic et empreintes locales avant envoi. Si dessin en file et dessin local diffèrent, arrêter et conserver les deux versions ; ne pas choisir automatiquement une copie.
5. Pour le plan seulement : choix local explicite une fois, synchronisation, conserver writeId/requestId de l’essai, relecture du dessin complet. Ne pas demander au build64 de répéter une résolution déjà démontrée inopérante.
6. Identifier et traiter séparément l’opération500, avec la cause corrélée. Un simple413 reste un blocage de transfert.
7. Comparer texte et dessin complets locaux/NocoDB/web (décompression éventuelle, empreintes et revue visuelle), vérifier les pages voisines et un effacement volontaire. Confirmer que les deux opérations exactes sont traitées et qu’aucun contenu en attente n’a été simplement abandonné.

## Clôture et retour arrière

`tools/verify-note-recovery.mjs` vérifie un dossier de métadonnées hors ligne ; il refuse une clôture sans sauvegarde vérifiée, sans les deux identités distinctes, empreintes concordantes, accusés, relectures et comparaison visuelle. Il ne récupère rien et n’accède à aucun service.

L’incident reste ouvert jusqu’à ces preuves. Les PDF réels restent non validés.

Rollback serveur : image69 `ghcr.io/contact-aid/aidhabitat-api@sha256:ede0c2497d20bce9337d4f2b383d9f606139ccafafe19c876becf37b725e4929`, SHA e8a4459. Attention : revenir à l’ancien serveur rétablit aussi sa politique de priorité locale ; suspendre les tentatives de récupération avant rollback. Ne jamais utiliser un rollback de code pour écraser des données. Aucune bascule web69 nécessaire à la récupération minimale. Aucun downgrade/désinstallation iPad de secours ; conserver le client et ses données si un problème apparaît.

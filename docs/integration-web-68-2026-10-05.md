# App’Ergo web 1.0.0+68 — intégration du 5 octobre 2026

Base : `96a2a416878aa32a0899c6d5a51061f35a7a833e` (`origin/main`, web 66).
Les deux lots du candidat 67 sont repris dans un worktree isolé : déplacement
des champs de visite vers Foyer/Occupation et quatrième case médicale
« Environnement social ». Le numéro 68 évite de confondre ce nouveau commit
avec l’archive locale du candidat 67. Le checkout historique reste intact.

## Périmètre

Seuls `beneficiary_tab.dart`, `context_tab.dart`, leurs deux tests ciblés,
`pubspec.yaml` et la documentation changent. Aucun changement du serveur,
du protocole de synchronisation, du schéma NocoDB, des mandats ou des plans.

Le lot « indépendance et synchronisation des notes » est exclu : le code exact
du build iPad 64 reproduit une réapparition d’ancien texte après effacement
partiellement synchronisé ; un iPad plus ancien possède encore des saisies non
synchronisées. Le verrou de création préparé est local à un seul processus et
le nettoyage de lignes anciennes peut entraîner des suppressions. Aucune
initialisation ou reprise des notes n’est autorisée dans cette publication.

CARSAT reste distinct : le référentiel réel contient déjà « CNAV (Assurance
retraite / CARSAT) » mais aucune ligne `CARSAT` exacte. L’accès staging vérifié
ne permet pas encore de tester l’ajout réel. Aucun identifiant synthétique ne
doit entrer dans la publication.

## Publication et retour arrière

Construire un artefact neuf depuis le SHA exact de cette branche. Vérifier
`version.json`, `release.json`, l’URL API, le SHA-256 de `main.dart.js` et de
l’archive. La publication web doit cibler l’image correspondant à ce SHA,
puis contrôler la version réellement servie et le fonctionnement public de
l’API. Le serveur reste sur son image actuelle puisque le diff n’y touche pas.

En cas d’échec de santé ou de version, repointer le service web vers l’image
66 correspondant à `96a2a416878aa32a0899c6d5a51061f35a7a833e`, puis
revérifier `version.json`, `release.json` et les endpoints API live/ready.
Aucune opération de données n’est incluse dans cette bascule.

Les PDF des visites réelles nécessitent encore l’identification des dossiers
prêts et un contrôle dédié avant toute génération.

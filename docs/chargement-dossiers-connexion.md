# Chargement des dossiers apres connexion

Correction locale, 14 septembre 2026. Aucun acces aux donnees reelles.

## Defauts identifies

- Une lecture locale vide liberait le dashboard avant confirmation distante.
- Les catalogues bibliotheque/caisses etaient demandes au montage, puis encore
  pendant le rafraichissement du workspace, en concurrence avec les dossiers.
- Une liste distante vide ne produisait aucun evenement de fin de lecture.
- Des lectures locales concurrentes pouvaient publier leurs resultats dans
  un ordre different de leur lancement.

## Modifications

- Affichage des dossiers locaux sans attendre le reseau ; pas de masquage
  d'une liste disponible pendant une actualisation ou une panne.
- Sans dossier local : chargement explicite jusqu'a confirmation distante,
  et messages distincts pour erreur/hors connexion avec action de reprise.
- Publication de la disponibilite des dossiers avant la fin du prechargement
  des catalogues, notes et details. Une liste distante vide est un resultat
  confirme, sans effacement des dossiers locaux ou de la file offline.
- Suppression des trois prechargements redondants au montage. Ils restent
  executes apres les dossiers par le parcours workspace existant.
- Les anciennes lectures locales terminees tardivement ne remplacent pas
  une lecture plus recente. Les evenements distants verifies respectent
  l'epoque de session.
- Configuration absente, reponse HTTP en erreur ou liste malformee ne sont
  pas interpretees comme une liste de dossiers vide reussie.

L'ordre envoi local puis lecture distante reste inchange. Les permissions
et le filtrage des dossiers ne sont pas assouplis.

## Verification et limites

Tests cibles : etats cache/chargement/vide/erreur/offline, action de reprise,
reponse HTTP differee, liste vide valide, payload invalide et echec serveur.
Les tests existants de reprise de session et d'ordre push/pull sont conserves.
Analyse Flutter complete sans anomalie.

Le gain de temps reel n'est pas mesure sur l'iPad. Cette correction supprime
des requetes concurrentes inutiles et le faux etat vide ; elle ne garantit
pas une duree reseau maximale. L'origine du cache vide sur l'appareil signale
n'a pas ete constatee dans sa base locale. Un essai du prochain build reste
necessaire, notamment reconnexion avec cache et arrivee sans cache.

Aucun push, deploiement ou build de livraison dans cette etape.

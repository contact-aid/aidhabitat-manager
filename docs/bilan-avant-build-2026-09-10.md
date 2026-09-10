# Bilan avant build - 10 septembre 2026

## Perimetre local integre

- Sauvegarde et rotation : revision exacte au retour du commit, apercu invalide
  uniquement pour le document concerne, refus des remplacements depuis une
  reference perimee ; rotation d'image executee dans un isolate sur natif.
- Formulaires : preservation des modifications et du conflit si un pull change
  le meme champ pendant la saisie ; absence de blocage pour un champ independant.
- File offline : chargement des payloads par worker actif, reprise sans effacement,
  acquittement de l'intention exacte, creation sans horodatage serveur invente.
- Wiki : remappage de l'ID et des references dans la transaction d'acquittement,
  preservation des editions/suppressions intervenues pendant la requete.
- Rapport : aucune suppression implicite a partir d'une liste partielle de photos.
- Comptes : epoques de session et attribution durable des operations ; protection
  avant envoi, au claim et a la lecture des reponses ; historique intercompte conserve.
- Migration locale v24 additive. La migration du coffre web utilise un marqueur
  v2 valide uniquement apres succes ; un echec ne cree pas une base vide.

## Effet visible lors de la mise a jour

Une ancienne operation sans auteur certain reste conservee et attend une revue
administrateur, via Details dans le bandeau de synchronisation. La revue est
individuelle, liee au contenu exact et au compte administrateur qui l'a ouverte.
Un changement de compte/contenu invalide la decision. Elle ne supprime aucune
donnee et ne resout pas implicitement un conflit de contenu deja existant.
Une operation appartenant a un autre auteur connu attend sa reconnexion.

## Verifications

- Suite Flutter globale : 720 tests passes. Le dernier raccord de notification
  apres revue est aussi couvert par les tests cibles de cet ecran.
- 234 tests Node passes, incluant routes Express reelles sur fixtures isolees.
- TypeScript sans erreur ; analyse Flutter sans erreur au dernier passage.
- 20 controles de parcours critiques et contrat autonomie passes.
- PDFKit natif macOS : rotations, pixels, sauvegardes repetees, effacement,
  preservation du texte et de l'original passes.
- Sept controles live en lecture seule passes ; pas de retour des erreurs 500
  sur GET/HEAD / et /openapi.json ; readiness et PWA accessibles.

Les tests SQLite utilisent FFI et des donnees synthetiques. Ils ne prouvent pas
une migration SQLCipher sur un iPad reel ni la performance du stockage de celui-ci.
Le test de migration du coffre injecte un chiffreur ; il verifie le controle
d'erreurs et la reprise, pas WebCrypto dans Safari.

## Ne pas activer avec ce build de transition

La protection conditionnelle serveur doit rester desactivee. Les composants
contexte et publication atomique de preconisations sont testes mais non raccordes.
Leur mise en service demande une migration NocoDB, des contraintes d'unicite,
des revisions valides et une verification des anciennes versions du parc.
Les gardes timestamp des fiches secondaires restent non atomiques. Le rejeu d'un
POST Wiki dont la reponse est perdue avant le commit local n'est pas encore
couvert par une idempotence serveur globale.

## Recette du prochain binaire de test

1. Mettre a jour sans desinstaller, avec des operations synthetiques en attente.
   Verifier que les fichiers, la file et les conflits restent disponibles.
2. Sur iPad : rotation, annotation, sauvegarde, reouverture et AirDrop. Verifier
   le nom du document, la miniature, la fluidite et l'absence de rechargement global.
3. Couper le reseau, modifier deux documents, fermer/reouvrir, puis reconnecter.
   Les etats doivent progresser sans quitter l'espace Documents.
4. Changer de compte pendant une sauvegarde et revenir au compte auteur ; verifier
   l'absence d'envoi sous le second compte et la reprise sous le premier.
5. Recetter une ancienne intention via Details avec un administrateur ; aucun
   envoi automatique des autres intentions ambiguës ne doit se produire.

Aucun commit, push, build de publication ou deploiement dans cette integration.
Le push sur main declenche des workflows de publication : ne pas le confondre
avec une simple sauvegarde locale du travail. Ne pas executer le script d'import
Airtable pour preparer cette livraison.

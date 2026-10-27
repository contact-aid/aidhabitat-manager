# Version 105 : pilote assistant de visite

Renan autorise le déploiement web, API et TestFlight le 28 octobre 2026 pour
un premier dossier réel avec Coralie ou Christelle. Le build 104 reste le repli.

## Contenu

- Assistant de visite : capture native hors ligne, quatre barres réactives,
  segments conservés, transfert HTTPS, transcription, notes manuscrites,
  faits sourcés, rédaction ajoutée sans remplacement et chat horodaté.
- Profils rédactionnels Coralie/Christelle, fichiers privés côté serveur,
  issus du corpus local analysé et des autrices vérifiées.
- Reformulation distante OpenRouter ; dictée et modèles locaux masqués
  dans cette variante. Activation explicite dans les builds de distribution.
- Bandeau sans adresse, statut Anah visible avant les commandes, enregistrement
  avant la date du dossier et le raccourci Documents de la VAD.
- Suppression du parcours « Signaler » et de son système d’envoi.
- Scanner Apple présenté après rotation plein écran en portrait, français,
  retour paysage. Inclut la dernière correction de la PR 79.
- Les correctifs SDB/WC, précos et PDF du build 104 restent inclus.

## Exploitation

La clé OpenRouter est injectée uniquement dans l’environnement du serveur.
Les profils sont dans le volume privé persistant `/data`, distinct des routes
publiques de documents. Les jobs et segments sont dans `/data/visit-assistant`.
Les requêtes IA exigent ZDR, refus de collecte et absence de repli fournisseur.
Ces options techniques ne constituent pas une attestation HDS/RGPD.

Pour transférer et ajouter les textes, l’application doit être ouverte au
retour du réseau. La capture native peut continuer écran verrouillé ; iPadOS
peut interrompre la capture. L’application conserve alors les fichiers pour
récupération. Ne pas désinstaller pour faire la mise à jour.

## Validation et portée du pilote

963 tests Flutter critiques, 33 tests avec assistant activé, 528 tests serveur,
contrats de synchronisation et 20 contrôles critiques réussis avant livraison.
La compilation et les tests ne remplacent pas une visite complète :
le cycle physique d’une heure, le nouveau cadrage du scanner, les manuscrits
réels et la fidélité rédactionnelle restent à évaluer avec les ergothérapeutes.
Le cycle témoin complet iPad/Mac/photo/dessin/PDF et les trois connexions
séparées n’ont pas été refaits pour cette livraison ; la diffusion demandée
est un pilote sur les validations ciblées et un premier dossier réel.

Le manifeste opérationnel local conserve les SHA des images, la réception
Apple, les contrôles publics et les commandes de retour vers le build 104.

# Copie de secours des notes par API — candidat client

Contrat : POST /api/note-backups {patientId,snapshotJson}, puis
GET /api/note-backups/:backupId/content. Le serveur doit être activé et configuré
avec un stockage durable chiffré indépendant des notes métier.

## Garantie client

- Action explicite « Sauvegarder par API » dans les opérations note_page, y compris
  celles en conflit. Elle ne choisit pas une version et ne relance pas la sync.
- Transaction SQLite en lecture seule, accès limité au propriétaire de l’opération
  dans la session actuelle. Statuts pending/running/failed/conflict autorisés,
  completed exclu. Ni attribution incertaine ni autre compte ne peut exporter.
- Instantané complet du payload déchiffré de l’opération et de la note locale.
  Les deux contenus sont conservés même s’ils diffèrent. Aucune clé ni jeton
  de session inclus. Ce n’est pas une sauvegarde complète de la base iPad.
- Session réseau figée pour tout le parcours ; un changement de compte invalide
  le résultat et ne lance pas l’étape suivante sous une autre identité.
- Reçu validé sur SHA-256 UTF-8, octets, source et storedVerified ; téléchargement
  immédiat de l’instantané, comparaison exacte et second reçu vérifié avant
  confirmation affichée. Pas de mutation des notes ou de la file, même en succès.
- Limites : instantané20MiB, requête JSON totale30MiB. Le doublage du contenu
  local/en attente et l’échappement JSON comptent dans cette enveloppe.

## Dépendance native vérifiée

Le code exact des builds64 (a5b4d9f),70(ae1785e4) et71(b7d054d) ne dispose pas
ce chemin. fetchRunnableOperations exclut conflict ; resetFailedToPending ne
remet quefailed enpending. La capture passive serveur d’un nouveau PUT peut
sauvegarder le Résumé réessayé ; elle ne peut pas obtenir le Plan déjà en conflit.
Le diagnostic existant ne contient pas les dessins. « Conserver ma note locale »
n’est pas une commande de sauvegarde et ne doit pas servir de contournement.

Le bouton exige donc une nouvelle version cliente pour l’iPad concerné.
Aucun build, envoi TestFlight ou installation n’est réalisé dans cette préparation.
L’envoi de71 à TestFlight a été déclaré par l’utilisateur ; la version physique
installée n’est pas connue. On ne promet pas sauvegardeAPI du Plan avant
installation d’un client doté d’export. La procédure API seule nécessite de
trancher cette dépendance avant l’intervention physique.

## Mise en service à vérifier

Server first, clé récupérable horsvolume et configuration durable, TLS/auth,
limitesproxy, test de restauration indépendant et recette de bout en bout avant
activation. Pas de publication dans ce commit. Aucune récupération de l’incident
n’est déclarée acquise sur la base des tests fictifs.

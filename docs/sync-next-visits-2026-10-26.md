# Synchronisation logement des prochaines visites, candidat 99

Demande : première remontée des saisies logement de la prochaine visite iPad,
puis modifications successives web/iPad, sans reprise automatique des conflits
déjà présents. Les dates de connexion ne servent pas à départager les valeurs.

## Périmètre exact

- Enrôlement iPad à l'ouverture via « Démarrer le relevé » ou à la première
  modification logement, le jour de la visite planifiée. Un dossier existant
  est éligible. Un rapport passé, une préparation de visite future ou une date
  absente ne sont pas automatiquement considérés comme une nouvelle visite.
- Repère SQLite par dossier et jour de visite. Changer seulement l'heure du
  rendez-vous ou rouvrir l'application ne réactive pas la priorité.
- Aucune opération logement déjà en attente, en conflit ou en échec n'est
  enrôlée. Les anciens identifiants logement sont également vérifiés.
- La priorité porte sur les champs effectivement saisis, pas sur une copie
  complète du dossier. Les références initiales sont archivées localement.
- Une première requête définitivement refusée peut être rebasée une fois sur
  une lecture serveur vérifiée. La transaction conserve les deux versions dans
  `sync_conflict_history`, renouvelle la mutation et consomme cette priorité.
- Une réponse incertaine ne donne pas le droit de forcer une seconde fois : le
  droit de première tentative est enregistré avant l'appel réseau. Après un
  acquittement, y compris en présence d'une nouvelle saisie pendant l'envoi, le
  repère et l'opération suivante passent au mode normal dans la transaction.
- Les nouvelles écritures logement web et iPad utilisent des comparaisons de
  références, y compris pour les champs simples. Les corrections successives
  s'appliquent à la référence reçue. Deux modifications incompatibles sans
  ordre démontrable restent à comparer dans la fenêtre lisible du build 98.

## Protection serveur des renvois

Le protocole `housing-visit-v1` utilise un journal durable dans
`AIDHABITAT_DATA_DIR_PATH/housing-write-journal`. Chaque écriture conserve son
identité, son contenu, la version attendue et la photographie précédente. Le
journal est publié atomiquement et synchronisé sur disque avant le PATCH NocoDB.
Il doit rester sur le volume persistant et être inclus dans ses sauvegardes.

Une ancienne écriture ne peut pas rafraîchir sa référence au moment d'un renvoi.
Cela protège aussi le cas où une correction web remet un champ à sa valeur
initiale. Une identité réutilisée avec un autre contenu, un journal illisible
ou un résultat indéterminé ne déclenche aucun écrasement de secours. Aucun
effacement automatique des journaux n'est prévu dans cette livraison.

Les anciens clients et anciennes opérations conservent leur protocole. Le
journal ne constitue pas une preuve rétrospective pour leurs écritures.
Aucune migration de données NocoDB n'est nécessaire.

## Validation et livraison

Tests ajoutés : cycle première remontée puis correction web, reprise réseau,
redémarrage du journal, retour à la valeur initiale, tentative d'identité
réutilisée, conservation de l'ancienne file, dossiers isolés, acquittement
concurrent avec une nouvelle saisie et archivage des versions.

La diffusion TestFlight reste conditionnée au dossier témoin prévu dans
`docs/protocole-version-stable.md`. Les tests automatisés ne constituent pas
une validation du cycle complet photo, document, dessin et PDF sur iPad réel.
Le build 98 reste la référence de retour arrière avant validation du 99.

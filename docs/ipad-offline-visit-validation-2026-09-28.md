# Validation du relevé de visite hors ligne sur iPad

## Portée

Cette recette vise le prochain build iPad de Coralie. Le build 57 installé ne
contient pas les corrections de cette branche. Les tests automatisés prouvent
les règles du code avec des données fictives ; ils ne remplacent pas un essai
sur l'iPad, son stockage réel et son réseau.

## Préparation

1. Utiliser un dossier fictif contenant déjà une valeur dans chacun des dix
   onglets, deux pages de dessin, une photo et un document ouvrable.
2. Ouvrir le dossier en ligne. Vérifier que les notes et les médias sont
   effectivement visibles. Attendre la fin du téléchargement des fichiers
   avant de passer en mode avion ; la liste des fichiers seule ne le prouve pas.
3. Noter les valeurs initiales et le nombre de sauvegardes locales en attente.

## Hors ligne

1. Passer en mode avion, sans se déconnecter de l'application.
2. Modifier et vérifier une donnée dans chaque onglet : Bénéficiaire, Contexte
   de vie, Mesures, Accessibilité, Salle de bain, WC, Plans, Photos, Résumé et
   Préconisations. Inclure du texte, une case, un dessin, une photo et un
   document. Revenir sur chaque onglet immédiatement après l'édition.
3. Fermer complètement l'application et la rouvrir toujours hors ligne.
   Contrôler les dix onglets, les deux pages de dessin et l'ouverture locale
   de la photo et du document. Aucune valeur initiale ni nouvelle saisie ne
   doit disparaître.
4. Cliquer « Générer » : une génération différée doit rejoindre la file. Le
   PDF n'est pas disponible tant que le serveur ne l'a pas produit.
5. « Actualiser » doit rester indisponible. « Forcer la sync » doit expliquer
   immédiatement qu'il faut attendre le réseau, sans vider le cache.

## Reconnexion

1. Rétablir la connexion sans forcer la synchronisation. Observer l'envoi des
   sauvegardes locales ; ne pas les abandonner en cas de conflit.
2. Vérifier que les opérations en attente arrivent à zéro, puis relire le
   dossier dans la webapp et, pour la recette technique, via l'API/NocoDB.
   Le compteur zéro sur l'iPad ne certifie pas à lui seul la relecture web.
3. Vérifier toutes les valeurs, notes, dessins, photos, préconisations,
   documents et le rapport PDF. Comparer aussi les valeurs initiales pour
   détecter tout effacement ou retour à une ancienne version.
4. Refaire un cycle court avec Wi-Fi connecté mais API indisponible : la file
   doit rester intacte, puis repartir lorsque l'API redevient accessible.

## Condition de diffusion

Ne diffuser le nouveau build TestFlight qu'après cette recette complète et la
vérification des contrôles automatiques définis dans
`docs/protocole-version-stable.md`. Conserver la base locale et les opérations
en attente durant tout diagnostic ; ne pas réinstaller l'application pour
faire disparaître un compteur.

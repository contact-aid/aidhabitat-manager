# Préparation de la mise à jour App’Ergo 1.0.0+74

Date : 8 octobre 2026. Source : branche `codex/appergo-next-update-20261008`.

Lecture seule des services actifs le même jour : la webapp annonce `1.0.0+73` ; `/api/health/live` et `/api/health/ready` répondent HTTP 200 avec le SHA API `c757288ac03965c785dd14f82aadccd0f5a8a57b`. Le `main` distant pointe vers `96a2a416878aa32a0899c6d5a51061f35a7a833e`, ancêtre de la branche candidate. La candidate n'est donc pas la version actuellement servie.

## Vérifications effectuées

- La suite serveur passe sur données fictives : 408 tests. Elle couvre notamment le statut Airtable « En attente », la conservation des occupants et RFR, la suppression de « dépendance » du PDF, les détails APA/invalidité, la référence « Pacsé(e) » et les pages de continuation des notes.
- La suite Flutter passe : 1 184 tests. L'analyse Flutter ne signale aucune erreur. Les tests couvrent entre autres le masquage réversible des dossiers Airtable, les enregistrements des occupants, le zoom des documents et la mise en page étroite.
- La chaîne locale `aid_habitat_app/tool/build_web.sh` a produit un bundle `1.0.0+74` avec l'API `https://api.aidhabitat.fr`. `tools/check-web-release.mjs` a validé ses 17 contrôles. Ce bundle est local et n'a pas été publié.
- Les PDF de test ont été générés à partir de données fictives ; l'identité des occupants, leurs détails santé et les suites de notes y sont présents. La note écrite du panneau Bénéficiaire en est absente.

Ces vérifications ne remplacent pas une recette sur iPad physique ni une synchronisation entre deux appareils réels.

## Référentiel NocoDB

Après autorisation explicite de l'utilisateur le 8 octobre, la table `situation_proprietaire` a été relue puis sauvegardée localement avant l'ajout. Elle contenait cinq valeurs et aucune correspondance « Pacsé(e) ». Une seule ligne `libelle = Pacsé(e)` a été créée, identifiant NocoDB `6`. La relecture donne six valeurs et exactement une correspondance. Le mapper serveur résout le libellé vers l'identifiant `6`. Aucun dossier bénéficiaire n'a été modifié. La sauvegarde préalable des cinq lignes et de leurs champs d'identification est conservée dans `/tmp/appergo-situations-before-pacse-20261008.json` (permissions `0600`).

La validation sur un dossier fictif après synchronisation complète et rechargement sur un second appareil reste à effectuer avant diffusion. Ne pas choisir « Marié(e) » comme substitut.

L'ancienne colonne de dépendance reste présente dans NocoDB pour préserver les données historiques et les anciens clients. Sa suppression physique doit attendre l'inventaire des versions iPad, la sauvegarde vérifiée, l'épuisement des files de synchronisation et une migration distincte. Elle est déjà masquée dans le relevé et le PDF.

## Préparation iPad

Le contrôle `release_preflight.sh --ios-only` a échoué sur deux points : 4,7 Gio libres pour un minimum requis de 20 Gio, et aucun certificat Apple Distribution accessible dans le trousseau. Flutter 3.38.4, Xcode 26.6, le SDK iOS 26.5, la cible iPad et les fichiers de confidentialité sont valides. Aucune archive iOS ni aucun envoi TestFlight n'a été lancé.

Le numéro candidat est `1.0.0+74`. Avant un build, confirmer dans App Store Connect qu'il est libre et que les iPad cibles peuvent installer la version iOS minimale configurée. Conserver les symboles d'obfuscation du build natif avec l'archive.

## Recette à faire avant diffusion

Ordre retenu avec l'utilisateur : tester d'abord la candidate dans une webapp isolée, puis sur iPad. L'URL active `app.aidhabitat.fr` sert encore `1.0.0+73` et ne permet pas de valider la candidate `+74`. Les services Easypanel portant le nom « staging » servent les domaines de production ; ils ne constituent pas un environnement de test. Une simple prévisualisation du bundle web raccordée à l'API actuelle serait également incomplète, car les nouvelles fonctions utilisent la candidate API. Préparer un couple web/API isolé avec des données fictives avant la recette interactive, ou obtenir une décision explicite de diffusion sur les services actifs après examen du plan de retour arrière.

Utiliser uniquement des dossiers et documents fictifs :

1. Créer, modifier puis supprimer un occupant ; vérifier RFR, année et catégorie de revenu après fermeture et réouverture.
2. Sélectionner « Pacsé(e) », synchroniser, recharger sur web et iPad, puis vérifier le PDF.
3. Mettre un dossier Airtable en attente, actualiser web et iPad, vérifier son masquage sans suppression de données ; enlever l'attente et vérifier sa réapparition. Répéter après suppression d'un dossier Airtable fictif.
4. Sur web, remplir un relevé fictif, utiliser « Valider » puis « Prévisualiser », corriger les champs signalés et vérifier que « Générer » produit le PDF attendu. Refaire ensuite le parcours hors ligne sur iPad après validation web.
5. Sur un PDF ou une image de plusieurs pages, zoomer, changer de page et revenir, puis double-taper pour recentrer. Vérifier l'absence de scintillement visible.
6. Comparer les notes longues, les occupants et les cases d'occupation du PDF généré avec le relevé. Vérifier que la note Bénéficiaire reste hors du rapport.

## Ordre de livraison proposé

1. Rendre le couple web/API candidat accessible sur un environnement isolé avec des données fictives, puis effectuer la recette web, notamment du changement manuel d'état et de la référence « Pacsé(e) ».
2. Résoudre les deux blocages du contrôle iPad et terminer la recette sur appareil physique après validation web.
3. Diffuser l'API compatible avec les anciens clients, puis la webapp, puis le build iPad après vérification des versions et des sauvegardes.
4. Après diffusion, l'utilisateur remettra lui-même à leur bonne place, ajoutera ou supprimera les dossiers notés sur son post-it et sa feuille blanche, en utilisant notamment le changement manuel d'état. Ces documents ne sont pas une entrée attendue pour le développement de la version `+74`.

Aucune publication web/API, migration, modification de dossier réel ou opération TestFlight n'a été effectuée dans cette préparation.

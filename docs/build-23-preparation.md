# Preparation du build 23

Date : 14 septembre 2026. Version : 1.0.0+23.
Base : f813402 (inclut les changements precedents des builds web 21 et 22).

## Changements inclus

- Rotation des images exportee aux dimensions source, sans marges de l'interface.
- Distinction entre confirmation de synchronisation et remplacement concurrent
  dans les editeurs image/PDF.
- Protection contre le retour d'un ancien contenu distant apres upload.
- Recuperation du fichier exact lorsque le conteneur iOS a change de chemin.
- Refus des confirmations d'upload sans success=true, remotePath et publicUrl
  non vides, pour les envois simples et par morceaux. Le fichier local et
  l'operation restent conserves pour une nouvelle tentative.
- Formulaires de connexion, bibliotheque et caisses de retraite defilables
  lorsque la hauteur disponible diminue avec le clavier.
- Fermeture du clavier de connexion par toucher hors du champ.
- Chargement prioritaire des dossiers avant les catalogues ; distinction entre
  chargement, absence de donnees, indisponibilite hors ligne et erreur.
- Retrait d'une valeur de finalite invalide du manifeste de confidentialite iOS.

## Perimetre exclu

Les branches de preparation Apple, comptes multi-entreprises et securite v2
ne sont pas integrees. Aucune migration ni modification de donnees reelles.
Aucune ecriture Airtable. La cible minimale iOS 26.5 est inchangee.
Cette preparation ne vaut pas validation App Store ou conformite globale.

## Verification sur appareil avant diffusion elargie

Validation locale : 794 tests Flutter passes, analyse Flutter sans anomalie,
git diff --check et validation des finalites du manifeste iOS reussis.

Utiliser des documents et dossiers de test :

- Tourner une image puis un PDF, enregistrer, attendre plusieurs cycles de
  synchronisation et rouvrir : orientation persistante et dimensions correctes.
- Modifier hors ligne, fermer/rouvrir puis reconnecter : reprise sans perte.
- Ouvrir les formulaires en portrait/paysage avec clavier : champs et actions
  accessibles par defilement, sans debordement.
- Se connecter avec cache vide et reseau lent : pas de faux "aucun dossier"
  pendant le chargement ; erreur et nouvelle tentative accessibles.
- Verifier les performances sur gros documents et le bouton rotation sur web.

L'archive iOS et les publications TestFlight/web sont des etapes distinctes.

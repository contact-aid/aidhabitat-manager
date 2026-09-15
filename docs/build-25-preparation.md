# Preparation du build 25

Version : 1.0.0+25. Date : 15 septembre 2026.

## Changements depuis le build iPad 23

- Reformulation locale dans les notes : modele systeme sur iPad compatible,
  modele telecharge explicitement dans les navigateurs compatibles sur web.
  Proposition a relire et accepter ; aucun repli vers une IA serveur.
- Suppression des documents distants : operation conservee en attente,
  confirmation serveur controlee et protection contre les anciennes relectures.
- Filtres par tags de la bibliotheque dans le choix des preconisations.
- Authentification des medias utilisant l'adresse historique de notre API,
  limitee a son origine HTTPS exacte et aux chemins de medias connus.
  Verification stricte des origines ; aucun changement des cles de cache.
- Sept illustrations generiques de bibliotheque incluses dans le build web.

## Publication

Le web 24 contient deja les trois premiers changements. La version 25 ajoute
les correctifs de medias. Aucun changement serveur, de base de donnees ou
d'Airtable. Aucun changement de cible minimale iOS.

L'archive iPad n'est pas encore produite : 4,3 Gio libres au controle initial,
contre les 20 Gio demandes par le preflight du projet. Ne pas supprimer de
donnees ou d'archives pour contourner ce blocage sans accord de l'utilisateur.
Apres liberation d'espace, utiliser tool/build_native_release.sh ios avec
AIDHABITAT_API_BASE_URL=https://api.aidhabitat.fr depuis un arbre Git propre.
Conserver les symboles et le manifeste produits. Verifier le numero disponible
sur App Store Connect avant upload ; cette preparation ne publie pas sur Apple.

## Recette avant diffusion iPad

- Supprimer un document de test puis attendre la synchronisation et rouvrir.
- Rotation image/PDF, sauvegarde, attente et reouverture sans retour en arriere.
- Reprise d'une modification et d'une suppression effectuees hors ligne.
- Ancien lien de document : telechargement authentifie et lecture hors ligne.
- Recherche et filtres de preconisations, y compris sans connexion.
- Reformulation sur iPad compatible, sans reseau, avec validation explicite.
- Absence de proposition IA sur iPad non compatible ; usage normal preserve.

La recette sur iPad reel reste a effectuer apres installation du nouveau build.

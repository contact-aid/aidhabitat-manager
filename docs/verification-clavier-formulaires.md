# Verification des formulaires et du clavier

Signalement du 14 septembre 2026, iPad build 20 : le fond de la connexion
et de la creation bibliotheque retrecit mais les champs debordent.

## Corrections locales

- Connexion : formulaire defilant, fond dimensionne avec son contenu,
  selecteur de compte contraint a la largeur disponible.
- Bibliotheque : creation et edition defilantes ; creation contenue dans
  la forme du dialogue ; libelle du choix d'image adaptable sur plusieurs lignes.
- Creation des caisses principales et complementaires : meme correction de
  defilement sur la structure Column non defilante retrouvee a la lecture.
- Aucun changement des regles de sauvegarde ou des comptes.

## Verification

Dix tests de widgets verifient clavier ouvert, portrait/paysage, acces aux
actions par defilement et conservation du texte. Connexion et creation sont
aussi exercees avec texte agrandi a 150 %. L'edition est testee a taille normale.
Les caisses ont ete verifiees par lecture de leur structure, sans recette
physique ni test de widget specifique dans ce lot.

La suite Flutter complete a passe 755 tests apres correction de la fixture
sync_acknowledgement : sa base simplifiee manquait de kv_store, table existant
deja dans le schema de l'application et utilisee par le correctif de rotation.
Les deux tests d'edition bibliotheque ont ete ajoutes ensuite ; la suite ciblee
finale de dix tests passe. Aucun echec n'a ete masque par un skip.

Lecture complementaire des dialogues compte, selecteurs beneficiaire et
preconisations, et reformulation de notes : structures differentes deja munies
de zones flexibles/defilantes. Cette lecture ne certifie pas tous leurs etats,
notamment clavier flottant, Split View ou accessibilite extreme.

## Limites

Tests locaux avec insets clavier simules, pas un essai sur iPad reel.
Aucun build, push ou deploiement. Le build 20 reste inchange.
Il ne s'agit pas d'une garantie d'absence de bugs dans toute l'application.

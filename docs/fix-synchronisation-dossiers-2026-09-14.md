# Synchronisation des dossiers - correctif A05 et suite A03

## Contexte d'isolation

- Worktree : `/Users/aidhabitat/Downloads/aid-habitat-manager-fix-synchronisation-dossiers`
- Branche : `codex/fix-synchronisation-dossiers`
- Base : `origin/main` au commit `9c6a9cfa813686c972c667aa80ae5192e402ffaa`
- Audit lu dans le repertoire source : `docs/audit-ipad-web-2026-09-14.md`, points A03 et A05

## Correction terminee : affectations A05

La consultation de `/api/dossiers` ne migre plus les dossiers dont `ergo_id` est vide, `E1` ou `user` vers Coralie. Ces valeurs historiques sont interpretees comme non attribuees sans modifier NocoDB.

Regles conservees :

- un administrateur voit tous les dossiers, y compris ceux qui ne sont pas attribues ;
- un ergotherapeute ne voit que les dossiers portant exactement son affectation ;
- un scope generique ou un identifiant de dossier explicite ne rend pas un dossier non attribue visible a un compte non administrateur ;
- une affectation nominative existante reste inchangee ;
- une creation explicitement attribuee conserve `ergo_id` ;
- la creation implicite d'un dossier pendant une lecture n'ecrit plus `ergo_id`.

## Concurrence A03 : protection non activee

Le chemin historique compare `expectedUpdatedAt` avant un PATCH NocoDB inconditionnel. Cette verification n'est pas atomique : deux appareils peuvent lire la meme version puis ecrire successivement. Quand la version attendue est absente, ce chemin reste compatible avec les anciens clients et ne fournit aucune protection contre l'ecrasement concurrent.

Le depot contient une ecriture conditionnelle testee derriere `AIDHABITAT_CONDITIONAL_SYNC`, mais l'activer sans preparation serait une protection partielle. Aucun changement n'a donc ete apporte au flag, aux contrats publics ou au comportement des anciens clients.

### Migration et prerequis necessaires

1. Inventorier tous les producteurs d'ecriture sur dossiers, beneficiaires, logements et sous-ressources : applications installees, web, API, NocoDB, imports et automatisations.
2. Sauvegarder puis ajouter une colonne de revision compatible avec le filtre conditionnel sur chaque table concernee. Backfiller chaque ligne avec une revision opaque unique et verifier metadonnees, lecture, filtre et mise a jour en staging.
3. Faire avancer cette revision dans la meme mutation atomique que les champs metier. Toute ecriture externe incapable de respecter ce contrat doit etre retiree, adaptee ou interdite avant activation.
4. Mettre a jour tous les clients pour conserver la revision lue et un `writeId` durable par mutation, sans fabriquer de baseline depuis l'etat courant. Ils doivent traiter explicitement les reponses 409, 428 et 503.
5. Traiter les operations multi-tables avec des revisions independantes ou une transaction serveur reelle. Une revision du dossier parent ne protege pas une ligne enfant.
6. Tester en staging deux appareils concurrents sur le meme champ et sur des champs differents, une reponse perdue et rejouee, une ecriture externe et une baseline absente ou invalide.
7. Verifier que le parc obligatoire est a jour, puis activer progressivement la protection avec supervision et procedure de retour arriere. Ne pas activer uniquement la variable d'environnement.

Un verrou en memoire cote serveur n'est pas une solution acceptable : il ne couvre ni plusieurs instances ni les ecritures directes dans NocoDB. Exiger immediatement une version casserait les clients existants. Aucune de ces protections partielles n'a ete introduite.

## Verification

- `node --check server/index.mjs` : succes.
- `node --test server/dossierAssignments.test.mjs` : 6 tests passes.
- `npm run test:server` : 170 tests passes, 0 echec.
- Tests avec donnees synthetiques et services simules uniquement. Aucune donnee reelle ni service de production n'a ete utilise.

La concurrence conditionnelle est couverte par les tests simules existants, mais n'est pas garantie en production tant que la migration, l'inventaire des ecrivains et la mise a jour du parc ne sont pas realises.

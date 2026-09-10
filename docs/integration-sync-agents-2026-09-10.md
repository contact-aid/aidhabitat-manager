# Contrat commun pour integration des cinq agents

Etat : travail local non publie. Le flag conditionnel reste desactive en production.
Les livraisons des agents sont a relire et tester dans le workspace principal,
pas a fusionner automatiquement depuis leurs branches.

## Proprietaires

- Integrateur : fichiers existants partages, coordinateur/writer, migrations
  finales, transports, ecrans, integration et verification de publication.
- Agent 1 : modules contexte de vie et tests agent1_.
- Agent 2 : modules preconisations et tests agent2_.
- Agent 3 : modules de compatibilite, matrice et tests agent3_.
- Agent 4 : tests de resistance agent4_, sans changements de production.
- Agent 5 : revue independante, sans changements de production.

## Deux representations distinctes

Le payload client conserve les noms API et les valeurs structurees de la saisie :
`concurrency: {version: 1, writeId, expectedUpdatedAt, baseValues}`. Une reference
historique inconnue reste absente. `localReference` ne prouve pas la disponibilite
d'une version distante et ne doit pas devenir automatiquement une garde reseau.

Le coordinateur `createGuardedMutation` recoit des champs DEJA mappes vers les
colonnes NocoDB : `fields` et `baseFields`. Les objets/listes sont serialises par
le meme mapper pour les deux representations. A ce niveau, seules les valeurs
scalaires JSON finies ou null sont acceptees ; absence et null restent distincts.
Depuis cette integration, le coordinateur valide aussi les requetes avant ses
raccourcis sans modification/rejeu. Les cles Id/revision/prototype sont refusees.

## Acquittements et erreurs

- 400 : mutation mal formee ; ne pas l'acquitter ni la forcer.
- 403 : autorisation insuffisante ; ne pas la contourner au retry.
- 409 : conflit conserve avec les deux versions disponibles, resolution explicite.
- 428 : reference/protocole requis ; pas de reference inventee ni de retry sans garde.
- 503 : etat temporairement indisponible ou ecriture non confirmee ; conserver
  l'intention et son writeId, car l'ecriture peut avoir reussi.

`ConditionalWriteUncertainError` porte maintenant `statusCode = 503`, y compris
lorsqu'elle traverse le middleware sans l'adaptateur de route conditionnelle.
Un succes HTTP/compteur seul ne constitue pas une preuve d'ecriture. La revision
et les valeurs doivent etre confirmees ; une reponse tardive ne valide que le
payload exact qui l'a declenchee, pas une edition plus recente.

## Limites a conserver explicites

- La comparaison d'horodatage suivie d'un PATCH ordinaire n'est pas atomique.
- Le writer protege une ligne preparee. Il ne rend pas transactionnelle une liste
  de suppressions/creations ni plusieurs tables liees.
- Aucune mutation de production ni activation du flag sans validation du parc,
  des anciennes files, de tous les writers et des revisions de toutes les lignes.
- Le formulaire beneficiaire transmet maintenant son snapshot de lecture a la
  sauvegarde ; un pull concurrent du meme champ produit un conflit local durable.

## Verification de cette integration

205 tests Node reussis, dont 10 nouveaux sur la validation avant no-op/rejeu et
la classification temporaire d'une ecriture incertaine. Aucun changement Flutter
dans ce lot commun ; les 619 tests Flutter sont le resultat du lot precedent,
pas une nouvelle execution revendiquee ici. Aucun push, build ou deploiement.

## Integration ulterieure dans le principal

Les compteurs ci-dessus decrivent le lot commun initial. Voir les etapes 7K et
7L de l'audit pour l'integration suivante : corrections de formulaire, rotation,
acquittement Wiki/remappage, creation hors ligne et controle de session.

Le schema local v24 attribue les nouvelles intentions a la session locale et
conserve une copie avant remplacement intercompte. Les intentions historiques
ne sont PAS attribuees a l'utilisateur connecte pendant la migration. Le bouton
Details du bandeau conduit a une revue individuelle administrateur ; il faut
confirmer la prise en charge de l'envoi, sans pretendre connaitre l'auteur
historique. Une intention d'un autre auteur connu attend sa reconnexion.
Un contenu illisible ou une operation running ne peut pas etre attribue.

Les modules contexte et publication atomique de preconisations sont livres et
testes comme composants, mais NON raccordes aux routes actives. Leur activation
necessite les revisions, l'unicite et la qualification distante indiquees plus
haut. La protection atomique globale inter-appareils reste ouverte ; un build
de transition ne doit pas etre presente comme la fermeture de ce chantier.

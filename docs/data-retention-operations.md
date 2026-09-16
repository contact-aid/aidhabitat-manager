# Conservation App'Ergo : exploitation du registre

## Statut et limites

Le registre est implemente dans le code, pas encore deploye en production. Il ne prouve pas une application exhaustive de la politique ni la conformite HDS. La proposition validee concerne l'usage interne Aid'Habitat : 24 mois apres dernier contact pour les dossiers clos, 6 mois apres resolution pour les signalements, desactivation des comptes au depart. Les exceptions juridiques doivent etre examinees avant tout traitement.

Aucune suppression automatique, route DELETE ou connexion a NocoDB n'est ajoutee par ce module. Il ne migre aucune piece jointe et ne lit aucun dossier. Il ne s'agit pas d'un nouvel archivage des contenus de sante.

## Enregistrer une date metier

Les routes suivantes utilisent l'authentification administrateur existante :

- `GET /api/admin/data-retention` : etat courant et echeances, sans cache HTTP.
- `POST /api/admin/data-retention` : enregistrement d'un etat complet, avec revision attendue.

Exemple synthetique de corps JSON pour un dossier :

```json
{
  "kind": "dossier",
  "id": "synthetic-dossier-1",
  "expectedRevision": 0,
  "lastContactOn": "2024-09-15",
  "closedOn": "2024-09-16",
  "hold": false,
  "holdReference": null,
  "exceptionsReviewed": false
}
```

Pour un signalement, utiliser `kind: "feedback"`, son identifiant existant et `resolvedOn`; ne pas fournir de contact ou de cloture de dossier. Pour rouvrir un signalement, remettre `resolvedOn` a null. Pour rouvrir un dossier, remettre `closedOn` a null. Les mises a jour portent l'etat complet et la derniere revision lue. Une revision obsolete ou un acces concurrent renvoie 409 sans ecraser l'historique.

Ne saisir ni nom, ni note de sante, ni contenu d'e-mail. `holdReference` est une reference opaque vers le justificatif conserve dans son espace autorise. `exceptionsReviewed: true` signifie que le responsable a reellement examine les obligations et exceptions, pas qu'il souhaite accelerer la suppression.

Le module ne verifie pas l'existence de l'identifiant dans NocoDB : l'administrateur doit le rapprocher de la source. Il ne detecte pas les dossiers manquants dans le registre. Ne jamais importer une date de modification technique comme dernier contact avec un beneficiaire. Une date historique inconnue reste null et bloque le traitement.

## Lire les echeances

Calcul en mois calendaires, en bornant au dernier jour du mois si necessaire (29 fevrier, fin de mois). La journee de reference est celle de Paris.

- `blocked` : date absente, dossier non clos, exception non examinee ou blocage de conservation.
- `not_due` : echeance future.
- `review_due` : echeance atteinte, dossier a examiner ; ce statut n'autorise jamais l'effacement.

Tous les rapports portent `deletionEnabled: false`, `copiesVerified: false` et `coverage: registered-records-only`. Une liste vide n'atteste pas que tous les dossiers sont conformes.

Lecture hors ligne, sur une copie protegee du registre :

```sh
node tools/data-retention-report.mjs /chemin/protege/retention-events.jsonl
```

Le rapport contient des identifiants internes. Ne pas le publier ou le joindre a la page de confidentialite. L'outil n'ouvre pas de connexion reseau et n'ecrit pas de fichier.

## Persistance, audit et reprise

Le fichier `retention-events.jsonl` se trouve dans le repertoire persistant API configure par `AIDHABITAT_DATA_DIR_PATH`. Chaque evenement enregistre l'auteur administrateur, l'horodatage, la revision et l'etat. Creation avec mode 0600, verrou exclusif et fsync apres ajout. Les erreurs de lecture et revisions incoherentes bloquent les modifications.

Un verrou laisse apres un arret brutal n'est pas supprime automatiquement. L'exploitant doit verifier qu'aucun processus n'ecrit, sauvegarder le fichier, controler son integrite, puis retirer uniquement le verrou orphelin. Ne jamais tronquer un registre corrompu pour faire disparaitre une erreur.

Ce stockage convient au deploiement API actuel a volume persistant unique. Plusieurs instances avec des volumes distincts ne partageraient pas ce registre : une telle configuration exige un stockage commun adapte avant activation.

## Examen manuel avant effacement (aucun effacement active ici)

1. Rapprocher l'identifiant, la derniere date de contact et la cloture/resolution de la source metier.
2. Examiner obligations MaPrimeAdapt', assurance, contentieux, financeurs et eventuelles archives publiques. Poser un blocage documente si necessaire. Separer les pieces ayant des exigences differentes.
3. Inventorier NocoDB, fichiers/chunks, rapports, caches iPad/web, synchronisations en attente, e-mails et sauvegardes. Une deconnexion n'efface pas les copies locales.
4. Verifier les droits d'acces aux archives et la possibilite d'un effacement coordonne sans perte de saisies en attente.
5. Faire valider une liste precise d'objets et de copies par le responsable avant toute operation destructive separee ; conserver une preuve minimale de traitement.
6. Apres restauration d'une sauvegarde, reappliquer les decisions d'effacement deja executees avant de rouvrir le service. La restauration du seul registre ne prouve pas la restauration des dossiers et documents.

## Sauvegardes a verifier sur le serveur

Relever la tache planifiee effective, ses dernieres executions, le repertoire/volume cible, `RETENTION_DAYS`, les dates des sauvegardes, leur localisation et les alertes d'echec. Ne pas lancer `backup-nocodb.mjs` simplement pour auditer : ce script peut purger d'anciennes sauvegardes.

Verifier une copie locale avec `tools/verify-nocodb-backup.mjs`, puis preparer le plan via `tools/plan-nocodb-restore.mjs`. Ces deux outils ne restaurent rien. L'exercice reel doit utiliser une base isolee et des donnees fictives : creation, pieces jointes et chunks, sauvegarde, restauration, comparaison, puis preuve datee. Aucune base de production ne doit servir de cible d'exercice.

L'option Hetzner facturee ne prouve ni la couverture des volumes ni la validite d'une restauration. Le certificat HDS et son perimetre restent une preuve externe a obtenir ou une migration a organiser.

## Avant la publication de la notice

Deployer et verifier ce module selon le processus API existant, inventorier les dossiers historiques et leurs dates fiables, confirmer le traitement manuel effectivement organise et les copies concernees. Une purge automatique n'est pas necessaire pour decrire une procedure manuelle reelle, mais l'existence du registre seul ne prouve pas que cette procedure est appliquee.

La page doit distinguer les regles adoptees, les traitements reels et les points encore en cours ; ne pas revendiquer HDS, une retention effective exhaustive ou une suppression instantanee sans preuves. Aucun engagement nouveau ni certificat ne peut etre cree par le code.

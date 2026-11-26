# Étape 0 : état des lieux de la synchronisation

Plan de référence : [plan-sync-hors-ligne-2026-11-26.md](plan-sync-hors-ligne-2026-11-26.md).
But : savoir exactement ce qui attend d'être envoyé, et tout mettre à l'abri, avant de modifier le moindre code.
Toutes les actions de cette étape sont en lecture seule, sauf la création du fichier de sauvegarde.

## 1. Sauvegarde NocoDB (à faire en premier)

À lancer sur le serveur, là où tournent déjà les outils de sauvegarde (`tools/backup-and-upload.sh`). Le fichier contient des données de santé : il reste sur le serveur et sur le stockage de sauvegarde habituel, jamais sur un poste personnel.

**Constat du 26/11 :** aucune sauvegarde automatique n'existe. Il n'y a ni tâche cron, ni conteneur de sauvegarde, ni fichier `aidhabitat-*.json.gz` sur le serveur. Les scripts sont présents dans `/etc/easypanel/projects/apps/aidhabitat-api-staging/code/tools/`, mais l'image de l'API ne les embarque pas.

**Sauvegarde manuelle du 26/11 à 10 h 43 (UTC) : réussie et vérifiée.**
- Fichier : `/root/backups-nocodb/aidhabitat-2026-11-26_10-43-08-700.json.gz` (1,3 Go compressé, 1,8 Go décompressé, accès root seul).
- 29 tables, 22 585 lignes. Le nombre de lignes relu est identique, table par table, à celui lu dans NocoDB (95 bénéficiaires, 97 dossiers, 92 logements, 43 contextes de vie, 44 diagnostics sanitaires, 1 053 pages de notes, 698 documents, 19 210 morceaux de photos).
- 91 morceaux de photos ne sont rattachés à aucun document. Ce n'est pas un défaut de la sauvegarde : c'est l'état actuel de la base. On ne supprime rien pendant l'étape 0, on regardera ce point à part.
- Espace disque après la sauvegarde : 7,7 Go libres sur 38 Go. **Chaque sauvegarde pèse 1,3 Go** : une sauvegarde quotidienne gardée 30 jours sur le serveur remplirait le disque en moins d'une semaine. Il faut donc garder au plus 3 sauvegardes sur le serveur et copier les autres ailleurs.
- Le dossier de code d'Easypanel (`/etc/easypanel/projects/apps/aidhabitat-api-staging/code`) contient une version plus ancienne que l'image déployée. Pour la sauvegarde, on envoie donc les outils à jour depuis le Mac dans `/root/aidhabitat-tools`.

Pour relancer une sauvegarde manuelle depuis le Mac : Le script utilise l'image de l'API et ses accès NocoDB, sans les afficher. Il refuse de tourner s'il reste moins de 3 Go libres, écrit dans `/root/backups-nocodb/` puis vérifie le fichier :
   ```bash
   COPYFILE_DISABLE=1 tar -C tools -cf - backup-nocodb.mjs nocodbBackupLib.mjs verify-nocodb-backup-stream.mjs | ssh root@157.180.20.97 'rm -rf /root/aidhabitat-tools && mkdir -p /root/aidhabitat-tools && tar -C /root/aidhabitat-tools -xf -'
   ssh root@157.180.20.97 'bash -s' < tools/run-nocodb-backup-on-server.sh
   ```
2. Copie hors serveur sur le NAS UGREEN, et sauvegarde quotidienne automatique : voir ci-dessous.

### Sauvegarde quotidienne et copie sur le NAS

Principe :
- Chaque nuit à 2 h 30, le serveur sauvegarde NocoDB, vérifie le fichier, puis le dépose dans `/srv/nocodb-backups`. Il n'en garde que 2, soit 2,6 Go.
- À 5 h (heure de Paris), le NAS vient chercher les nouvelles sauvegardes, en lecture seule. Il garde les 30 dernières, plus celle du 1er de chaque mois pendant 12 mois.
- Le serveur n'a aucun accès au NAS. Le compte `nasbackup` du serveur ne sait faire qu'une chose : lire ce dossier.
- Un fichier non vérifié n'est jamais déposé, et une sauvegarde déjà sur le NAS n'est jamais réécrite ni effacée par le serveur.

Fichiers : [tools/run-nocodb-backup-on-server.sh](../tools/run-nocodb-backup-on-server.sh), [tools/setup-nas-backup-on-server.sh](../tools/setup-nas-backup-on-server.sh), [tools/nas-backup-pull/](../tools/nas-backup-pull/).

Mise en place, dans l'ordre :

1. **Envoyer les outils à jour au serveur** (depuis le Mac, à la racine du dépôt) :
   ```bash
   COPYFILE_DISABLE=1 tar -C tools -cf - backup-nocodb.mjs nocodbBackupLib.mjs verify-nocodb-backup-stream.mjs run-nocodb-backup-on-server.sh | ssh root@157.180.20.97 'rm -rf /root/aidhabitat-tools && mkdir -p /root/aidhabitat-tools && tar -C /root/aidhabitat-tools -xf -'
   ```
2. **Sur le NAS** :
   - créer un dossier partagé réservé à l'administrateur, par exemple `Sauvegardes/aidhabitat-nocodb` ;
   - copier `compose.yaml` et `pull.sh` dans un dossier du NAS ;
   - dans `compose.yaml`, remplacer `/volume1/Sauvegardes/aidhabitat-nocodb` par le vrai chemin ;
   - dans l'application Docker, créer un **Projet** à partir de ce `compose.yaml` et le démarrer ;
   - ouvrir le journal du conteneur `aidhabitat-backup-pull` et copier la ligne qui commence par `ssh-ed25519`. La première récupération échoue à ce moment-là : c'est normal, la clé n'est pas encore installée.
3. **Installer la clé et la sauvegarde quotidienne sur le serveur** (depuis le Mac, avec la ligne copiée) :
   ```bash
   ssh root@157.180.20.97 "NAS_PUBLIC_KEY='ssh-ed25519 AAAA... aidhabitat-nas' bash -s" < tools/setup-nas-backup-on-server.sh
   ```
   Le script doit finir par `INSTALLATION OK`. Il dépose aussi la sauvegarde du 26/11.
4. **Redémarrer le conteneur du NAS.** Il récupère tout de suite la sauvegarde du 26/11 (1,3 Go). Le journal doit afficher « Récupération réussie ».
5. **Le lendemain matin** : le journal du serveur doit contenir `SAUVEGARDE OK`, et le NAS une sauvegarde datée du jour.
   ```bash
   ssh root@157.180.20.97 'tail -3 /var/log/aidhabitat-nocodb-backup.log; ls -lh /srv/nocodb-backups'
   ```

| Contrôle | Résultat | Date |
|---|---|---|
| Outils à jour envoyés au serveur | Oui (4 fichiers) | 26/11/2026 |
| NAS préparé sans Docker (non installé) : script dans `~/aidhabitat-nocodb/`, clé créée, destination `/volume1/Backups_AidHabitat/NocoDB` (accès Aidhabitat seul) | Oui | 26/11/2026 |
| Droits de `~/.ssh` du NAS refermés (étaient modifiables par tous les comptes) | Oui | 26/11/2026 |
| Tâche quotidienne **5 h** sur le NAS (cron du compte Aidhabitat, UGOS n'a pas de planificateur graphique) | Oui | 26/11/2026 |
| `INSTALLATION OK` sur le serveur (compte `nasbackup`, cron 2 h 30 UTC, soit 3 h 30 ou 4 h 30 à Paris) | Oui | 26/11/2026 |
| Sauvegarde du 26/11 présente sur le NAS (même taille qu'au serveur, 1 388 991 354 octets) | Oui | 26/11/2026 |
| Compte du NAS sur le serveur : écriture et terminal refusés (contrôlé) | Oui | 26/11/2026 |
| Première sauvegarde automatique (`SAUVEGARDE OK`) | | |
| Sauvegarde automatique présente sur le NAS | | |

| Contrôle | Résultat | Date |
|---|---|---|
| Sauvegarde automatique active | Non, à mettre en place | 26/11/2026 |
| Sauvegarde manuelle créée (nom du fichier) | `aidhabitat-2026-11-26_10-43-08-700.json.gz` | 26/11/2026 |
| Vérification réussie | Oui, 29 tables, 22 585 lignes | 26/11/2026 |
| Copie hors serveur présente | Non, destination à choisir | |

## 2. Relevé des conflits côté serveur (pendant deux semaines)

Script en lecture seule : [tools/collect-sync-conflicts.sh](../tools/collect-sync-conflicts.sh). Il ne lit que le type de conflit et les noms de champs, jamais le contenu des dossiers. Il garde l'historique dans `/var/log/aidhabitat-sync-conflicts.log` sur le serveur, car les journaux Docker sont effacés au fil de l'eau.

Depuis le Mac :
```bash
ssh root@157.180.20.97 'bash -s' < tools/collect-sync-conflicts.sh
```

À relancer tous les 2 ou 3 jours jusqu'au 10/12/2026. Coller ici le résumé de chaque passage.

| Date | Total | Principaux types | Principaux champs |
|---|---|---|---|
| 26/11/2026 | 0 | aucun (ni champs, ni notes, ni contexte, ni anciens builds) | aucun |

**Lecture du premier relevé (26/11) :**
- La période couverte par les journaux actuels n'est pas encore connue. Si le conteneur API a été redéployé récemment, ce zéro ne couvre que quelques jours.
- Les conflits que l'iPad crée lui-même ne passent jamais par le serveur, donc ils n'apparaissent pas ici. C'est le cas de « la fiche locale a changé pendant que le formulaire était ouvert » et de « la référence de la sauvegarde précédente doit être vérifiée ». Seul l'inventaire des appareils (section 3) les montre.
- Les conflits de notes sont bien journalisés (`[note-sync]`) et sont couverts par le relevé : aucun dans la période.

## 3. Inventaire de chaque iPad et de chaque navigateur

À faire sur **chaque** appareil utilisé (iPad de chaque ergothérapeute, Mac, autres postes web), réseau actif, app ouverte.

**Ne pas faire pendant l'inventaire :**
- supprimer ou réinstaller l'app, vider les données du navigateur, se déconnecter ;
- toucher « Abandonner » sur une opération ;
- choisir « version locale » ou « version serveur » dans une fenêtre de conflit. On note d'abord, on résout ensuite ensemble.

**Marche à suivre :**
1. Ouvrir la fenêtre du compte, puis **Sauvegardes en attente**.
2. Noter le nombre affiché et, pour chaque ligne : le type (par exemple `patient · update`), le statut (En attente, Échec, Conflit), l'auteur et l'erreur affichée.
3. Pour chaque ligne en **Conflit** : toucher la ligne pour ouvrir le diagnostic, et faire une capture d'écran. Noter le dossier concerné.
4. Si la liste est vide : noter « 0 » et la date.

| Appareil | Utilisateur | Build | En attente | Échec | Conflit | Dossiers concernés | Date |
|---|---|---|---|---|---|---|---|
| iPad de Coralie | Coralie | ? | 12 au total | 0 vu | 6 | D. J., P. E. (×2), A. B., foyer R. (prénom double « X et Y »), 1 non vu | 26/11/2026 |
| iPad de Christelle | Christelle | ? | 2 | 0 | 0 | 1 document (dossier non identifié) | 26/11/2026 |

**iPad de Coralie, constats du 26/11 :**
- **Les 6 conflits visibles portent tous sur le Logement :** cases « Rez-de-chaussée » et « Premier étage », et « Pièces par niveau ». À chaque fois, l'iPad a la saisie réelle (cases cochées, liste des pièces), et le serveur n'a **rien** : « Non » et « Aucun élément » partout.
- **Cause trouvée dans le code : ce sont de faux conflits.** Le serveur affiche une case jamais remplie comme « Non » (`toBool` de `null` donne `false`, [server/index.mjs:699](../server/index.mjs:699)), et une liste de pièces vide comme 5 niveaux « Aucun élément ». Ces champs sont contrôlés en mode strict (liste `changesCollection`, [server/index.mjs:529](../server/index.mjs:529)). L'iPad envoie comme valeur de départ « non renseigné », le serveur voit « Non » ou une structure vide : les deux ne sont pas égaux, donc conflit. Personne n'a rien saisi sur le web.
- **Conséquence :** à chaque premier remplissage des niveaux ou des pièces d'un logement, il y a conflit, et la saisie n'arrive jamais au serveur tant que personne ne choisit. Les rapports générés côté serveur pour ces dossiers n'ont donc pas les pièces.
- **Correctif à prévoir (au début de l'étape 2) :** traiter « non renseigné », « Non » par défaut et « liste vide » comme une même valeur de départ dans la comparaison.
- **Documents bloqués (aussi sur l'iPad de Christelle, envoi du 14/10) :** une opération `document · upload_file` du **23/10/2026** n'a jamais été tentée (0 tentative), et la mise à jour des informations de ce document attend derrière (147 tentatives). Ce document n'existe que sur cet iPad. Ne rien abandonner, diagnostic à ouvrir.
- **Cause des documents bloqués, trouvée dans le code : blocage en boucle.** Quand un fichier est remplacé (rotation, annotation) alors qu'une mise à jour de ses informations attend déjà, l'app supprime l'ancien envoi et en crée un nouveau, daté de ce moment ([document_repository.dart:1010](../aid_habitat_app/lib/services/document_repository.dart:1010)). Les opérations d'un document partent par date de création ([sync_repository.dart:134](../aid_habitat_app/lib/services/sync_repository.dart:134)). La mise à jour, plus ancienne, part donc la première, voit l'envoi en attente, s'arrête ([nocodb_sync_service.dart:1723](../aid_habitat_app/lib/services/nocodb_sync_service.dart:1723)) et bloque tout le document. L'envoi du fichier n'est jamais tenté. « Relancer » ne débloque rien, et « Résoudre les blocages » ne le détecte pas (« Aucun blocage dans la file locale »). Les fichiers sont intacts sur les iPad, mais absents du serveur. Correctif à prévoir : envoyer le fichier avant la mise à jour de ses informations, quel que soit l'ordre de création.


Un appareil qui affiche « Auteur à confirmer » ou « Autre compte » doit rester tel quel : ses saisies appartiennent peut-être à un autre ergothérapeute.

## 4. Résolution des conflits en cours (après l'inventaire)

Pour chaque conflit relevé, dossier par dossier, avec Renan :
1. Garder la capture du diagnostic (valeur locale et valeur serveur).
2. Décider de la bonne valeur ensemble.
3. Seulement ensuite, faire le choix dans l'app.
4. Contrôler sur le web que le dossier affiche la bonne valeur.

| Dossier | Appareil | Champ(s) | Valeur gardée | Valeur écartée (copie) | Fait le |
|---|---|---|---|---|---|
| | | | | | |

## 5. Condition pour passer à l'étape 1

- Sauvegarde vérifiée et copiée hors serveur.
- Inventaire rempli pour tous les appareils.
- Plus aucun conflit non noté.
- Premier relevé serveur fait (les suivants continuent pendant l'étape 1, qui ne change aucune règle).

## Points relevés en passant (hors synchronisation)

- **NAS, risque de prise de contrôle : corrigé le 26/11.** Le script de la sauvegarde Drive, lancé chaque nuit par root, était modifiable par tous les comptes du NAS. Il est maintenant dans `/volume1/@aidhabitat-scripts/` (root seul, hors partages), copie vérifiée identique. La tâche de 3 h pointe vers cette copie. L'ancien fichier est renommé `backup_gdrive.sh.ancien-non-utilise` et plus rien ne le lance. À vérifier le 27/11 : la sauvegarde Drive de 3 h est bien passée.
- **NAS, journal Drive :** `backup.log` pèse 3 Go et grossit chaque nuit (une ligne par fichier copié). À limiter.
- **NAS, adresse :** le NAS a déjà changé d'adresse (`192.168.31.53`, `192.168.10.125`, maintenant `192.168.10.126`). Lui réserver une adresse fixe dans la box.
- **Base NocoDB :** 91 morceaux de photos sans document rattaché. À examiner à part, sans rien supprimer pendant l'étape 0.

## Corrections des deux défauts trouvés à l'inventaire (26/11)

Commit `b6153ae` sur la branche `claude/sync-faux-conflits-documents`, préparé dans une copie séparée du dépôt (`.claude/worktrees/sync-fixes`) pour ne pas se mélanger avec les modifications en cours d'une autre session. Pas encore fusionné ni déployé.

- **Faux conflits sur le logement (serveur) :** une liste de pièces entièrement vide est maintenant égale à « jamais rempli » ([server/nocodbScalarValues.mjs](../server/nocodbScalarValues.mjs)). Une seule pièce renseignée garde le contrôle strict. Après déploiement de l'API, il suffit de toucher « Réessayer sans remplacer » sur l'iPad : pas besoin de nouvelle version de l'app.
- **Documents bloqués (app iPad) :** pour un même document, l'envoi du fichier passe toujours avant la mise à jour de ses informations ([sync_repository.dart](../aid_habitat_app/lib/services/sync_repository.dart)). La file locale n'est pas réécrite, donc les envois déjà bloqués partiront d'eux-mêmes. Il faut une nouvelle version de l'app iPad.
- **Tests :** 429 sur 429 côté serveur, 930 sur 930 côté app (services), analyse sans remarque. Le nouveau test serveur échoue bien avec l'ancien code.

### Mise à jour : ce qui est réellement à déployer

- **La production ne tourne pas sur `main`.** L'image API active (`agenda-visit-fix-6963aeb…`) correspond au commit `6963aeb` de la branche `fix/agenda-dossier-selection` (23/11). Elle contient 266 commits absents de `main`. Toute correction doit partir de cette version, sinon on retire des corrections en production.
- **Faux conflits du logement : déjà corrigés en production depuis le 14/10** (commit `c48163b`, fonction `isEmptyRoomBreakdown`). Rien à déployer côté serveur. Les conflits de Coralie sont restés en attente d'un choix. « Réessayer sans remplacer » renvoie la saisie, et le serveur doit maintenant l'accepter.
- **Documents bloqués : pas encore corrigé en production.** La correction est appliquée sur la version de production : commit `0b5cce4` sur la branche `claude/sync-fixes-sur-prod` (copie `.claude/worktrees/sync-fixes-prod`). 1 062 tests de services sur 1 062, analyse sans remarque. Il reste à publier une version iPad (dernière connue : 1.0.0+114).
- La branche `claude/sync-faux-conflits-documents` (commit `b6153ae`) part d'une base trop ancienne : **ne pas la déployer**. À supprimer après accord.

### Résolution des conflits de l'iPad de Coralie (26/11)

- Le bouton « Réessayer sans remplacer » n'existe que pour les conflits d'occupants. Pour le logement, la seule voie est « Choisir la version à garder » puis « Valider mes choix ».
- 5 dossiers sur 6 sont résolus en gardant la version de l'iPad (le serveur n'avait aucune valeur réelle) : D. J., P. E. (×2), A. B., et un sixième dossier.
- **foyer R. (prénom double « X et Y ») reste en conflit** après validation. À examiner.

### foyer R. (prénom double « X et Y ») : conflit qui revient (26/11)

- Section « Bénéficiaire », sans aucun champ affiché à choisir. « Valider mes choix » et « Réessayer sans remplacer » font disparaître le conflit, qui revient à la relecture.
- Journaux serveur : 5 refus `SYNC_FIELD_CONFLICT`, tous sur `date_naissance_madame` (relevé `tools/collect-sync-conflicts.sh`).
- Fiche serveur (Id 144, diagnostic `tools/diagnose-occupant-birthdates.sh`, sans afficher de date) : pas de liste d'occupants (`occupants_json` vide), date de Monsieur remplie, date de Madame vide.
- Lecture : l'iPad envoie pour Madame une valeur de départ non vide, alors que le serveur n'a rien. Comme l'écran de l'iPad compare la liste des occupants et non la colonne, il ne montre aucune différence. Cause exacte à confirmer : probablement le découpage du prénom double « X et Y » en deux occupants, sans liste d'occupants côté serveur. À reproduire par un test avant toute correction. Ce cas rejoint l'étape 3 du plan (identifiants stables des occupants).
- Les saisies restent sur l'iPad. Ne pas abandonner l'opération.

**Cause foyer R. trouvée et corrigée (26/11), commit `6d8ad1f` sur `claude/sync-fixes-sur-prod`.** Le serveur n'expose qu'un occupant pour ce foyer importé (« X et Y », date de Monsieur seule, pas de liste d'occupants). Quand l'iPad ajoute la date de Madame, la valeur de départ « un seul occupant » faisait **disparaître** les colonnes du 2ᵉ occupant au lieu de les mettre à vide ([server/index.mjs](../server/index.mjs), `mapBeneficiaryBaselineToFields`). La date de Madame était donc comparée à une valeur de départ inconnue et refusée à chaque essai. Désormais, une liste de départ de moins de deux occupants vaut « vide » pour les trois colonnes qui font apparaître un 2ᵉ occupant. Une date réellement saisie ailleurs entre-temps reste un conflit, sans écriture. Le cas est reproduit dans `server/beneficiarySecondOccupantBaseline.test.mjs`. Résultats : 609 tests serveur sur 609, contrats de synchronisation 12 sur 12, parcours critiques 20 sur 20. **Pas encore déployé.** Après déploiement de l'API, toucher « Réessayer sans remplacer » sur foyer R..

### Déploiement de l'API (26/11, vers 14 h 10)

- Branche `claude/sync-fixes-sur-prod` poussée sur GitHub. Workflow « Build & Deploy API » ([run 45825511035](https://github.com/contact-aid/aidhabitat-manager/actions/runs/45825511035)) : tous les tests rejoués, image publiée `ghcr.io/contact-aid/aidhabitat-api:sync-fixes-6d8ad1fb1e2febb09d63f2d672fa6ef9af4f9d54`.
- Service Easypanel `apps/aidhabitat-api-staging` (l'API de production malgré son nom) pointé sur cette image, puis redéployé avec la CLI `ep`.
- Contrôle : `https://api.aidhabitat.fr/api/health` répond `ready` avec `buildSha` `6d8ad1f…`, 20 secondes après le déploiement. `check-live-stack` : `live` et `ready` OK. Les 404 sur `/` et `/openapi.json` sont voulus pour une API sans surface publique. `check-data-sync-stability` ne peut pas tourner depuis le Mac (identifiants NocoDB absents en local) : ce n'est pas lié au déploiement.
- **Retour arrière si besoin :**
  ```bash
  ep app update-source-image apps/aidhabitat-api-staging --image ghcr.io/contact-aid/aidhabitat-api:agenda-visit-fix-6963aeb84a26d755f5b71663eece3c1df1dfcd4c --yes
  ep app deploy apps/aidhabitat-api-staging --yes
  ```
- La production tourne désormais sur `6d8ad1f` = `6963aeb` (ancienne production) + correction documents (app iPad, sans effet sur l'API) + correction foyer R. (serveur). Tout nouveau correctif doit partir de `claude/sync-fixes-sur-prod`.

- **Vérifié sur l'iPad de Coralie après déploiement : foyer R. est passé** avec « Réessayer sans remplacer » et ne réapparaît plus. Coralie n'a plus aucun conflit. Restent sur son iPad : les documents bloqués, qui attendent la nouvelle version de l'app.

### Correction d'une erreur d'analyse (26/11)

La copie locale de `main` était en retard de plusieurs semaines. Comparée au vrai `origin/main` (24/11), la production `6963aeb` y est **entièrement incluse**, et `origin/main` a 15 commits de plus (build iPad 115 : plans, scan, qualité d'image). La phrase « la production ne tourne pas sur `main` » plus haut est donc fausse. Le déploiement API du jour reste correct (version de production + 2 correctifs, rien retiré). Le build iPad doit partir de `origin/main`, avec le numéro **116**.

### Version iPad 1.0.0+116 (26/11)

- Branche `claude/ipad-116-sync-fixes` = `origin/main` (contient la 115) + correction documents + correction foyer R. + numéro 116. Tests : 615 serveur, 12 contrats, 20 parcours critiques, 1 414 app. Analyse : une seule remarque, déjà présente dans `main`.
- Archive construite et copiée dans `~/Downloads/AppErgo-TestFlight-1.0.0-116/` (archive Xcode, manifeste, symboles à conserver pour lire les rapports de plantage). Version 1.0.0, build 116, `com.aidhabitat.manager`.
- L'export automatique de l'IPA a échoué pour deux raisons extérieures au code : un **nouvel accord de licence Apple** est à accepter sur le compte développeur, et il n'y a pas de certificat de distribution local (la signature gérée par Xcode suffit, comme pour la 47).
- Reste à faire par Renan : accepter l'accord sur developer.apple.com, puis Xcode, Organizer, Distribute App, TestFlight.
- **Envoyée à App Store Connect le 26/11 à 14 h 25** (accord de licence accepté par Renan, export signé par Xcode avec la signature gérée par Apple, upload terminé). À faire : attendre le traitement Apple, activer le build 116 pour les testeurs, installer par-dessus sur chaque iPad via TestFlight (sans supprimer l'app), puis vérifier que les lignes `document · upload_file` disparaissent chez Coralie et Christelle.
- **Vérifié le 26/11 après installation de la 116 sur l'iPad de Coralie :** file locale vide (0 sauvegarde en attente). Côté serveur (`tools/check-documents-on-server.sh`), le document `doc_1792760666569820` est mis à jour le 26/11 à 13 h 31 UTC, avec 381 morceaux de fichier : la version bloquée depuis le 23/10 est arrivée. Le document de Christelle (`doc_1791986649318776`) est encore dans sa version du 14/10 sur le serveur : il attend la 116 sur son iPad.
- **Vérifié le 26/11 après installation de la 116 sur l'iPad de Christelle :** file locale vide (0 sauvegarde en attente). Côté serveur, le document `doc_1791986649318776` est mis à jour le 26/11 à 13 h 41 UTC (190 morceaux, même nombre qu'avant, cohérent avec une rotation). **Les deux documents bloqués sont réglés.**

### Reste à faire après le 26/11

- **Fusionner `claude/ipad-116-sync-fixes` dans `main`** : [pull request #133](https://github.com/contact-aid/aidhabitat-manager/pull/133), ouverte le 26/11. Sinon, le prochain build iPad partirait de `main` sans les deux correctifs et avec un numéro déjà utilisé.
- Redéployer l'API depuis `main` après la fusion : elle ajoutera le journal durable des refus (`syncRejectionLog`), utile pour la mesure de l'étape 0.
- Vérifier le 27/11 au matin : sauvegarde NocoDB de 3 h 30 (`SAUVEGARDE OK`), récupération du NAS à 5 h, sauvegarde Drive de 3 h passée par le nouveau chemin.
- Inventaire des autres appareils (autres iPad, navigateurs web).
- Supprimer la branche `claude/sync-faux-conflits-documents` (base périmée) et les copies de travail `.claude/worktrees/` quand tout est fusionné.
- Commit final du plan, de la fiche et des outils de sauvegarde.

## Étape 1 : archive des valeurs écrasées (commencée le 26/11)

Commit `e6bdfbe` sur la branche `claude/sync-archive-etape1` (partie de `claude/ipad-116-sync-fixes`, donc de la PR #133). Copie de travail : `.claude/worktrees/sync-archive`. **Non poussé, non déployé.**

- **Fait :** avant qu'un envoi remplace une valeur que l'appareil n'avait pas vue, le serveur en garde une copie dans la table NocoDB `sync_archive` (champ, ancienne et nouvelle valeur, table, fiche, dossier, identifiant d'envoi, auteur). Couvre les champs simples et les sections du contexte de vie. Les notes restent strictes ; les préconisations sont traitées par l'autre session. Si l'archive est impossible, l'écriture est refusée (503, réessai automatique) et rien n'est écrasé.
- **Interrupteur :** `AIDHABITAT_SYNC_ARCHIVE=1`. Éteint par défaut : déployer le code ne change rien tant qu'il n'est pas allumé.
- **Table :** `tools/create-sync-archive-table.mjs` (lecture seule sans `--apply`, ne modifie jamais une table existante), lancé sur le serveur par `tools/run-sync-archive-setup-on-server.sh`.
- **Tests :** 8 tests unitaires de l'archive, 1 test de bout en bout sur la vraie route (archive impossible = refus et aucune écriture), 1 test du script de création. 624 tests serveur sur 624, contrats 12 sur 12, parcours critiques 20 sur 20.
- **Écran admin (commit `926e44b`) :** « Valeurs archivées » dans la fenêtre du compte, visible des seuls administrateurs. Chaque entrée montre le bénéficiaire, la fiche, le champ, la valeur remplacée et celle qui l'a remplacée, qui et quand. « Restaurer cette valeur » demande confirmation. Côté serveur, la restauration archive d'abord la valeur qu'elle remplace (elle est donc réversible), puis écrit avec la condition de révision : si la fiche change entre-temps, rien n'est écrit. Routes réservées aux administrateurs (vérifié : 401 sans connexion, 403 pour un compte non administrateur). Tests : 629 serveur, 12 contrats, 20 parcours critiques, 1 419 app.
- **Reste dans l'étape 1 :** envoi au serveur des historiques de conflits déjà stockés sur les iPad (facultatif). L'écran arrivera dans l'app avec la prochaine version iPad et la prochaine publication web.
- **Ordre de mise en service :** (1) déployer l'API avec l'interrupteur éteint, (2) créer la table et vérifier, (3) allumer l'interrupteur, (4) vérifier qu'une écriture normale passe et qu'un écrasement produit une ligne d'archive.

### Mise en service de l'étape 1 (26/11)

- API déployée depuis `claude/sync-archive-etape1` (commit `926e44b`, image `sync-archive-926e44b…`), archive **éteinte** : `/api/health` prêt sur ce commit, route admin refusée sans connexion (401).
- Table NocoDB `sync_archive` créée et vérifiée (id `msislm6oxaedggl`, 14 colonnes).
- Retour arrière API : `ep app update-source-image apps/aidhabitat-api-staging --image ghcr.io/contact-aid/aidhabitat-api:sync-fixes-6d8ad1fb1e2febb09d63f2d672fa6ef9af4f9d54 --yes` puis `ep app deploy apps/aidhabitat-api-staging --yes`.
- Archive **allumée** le 26/11 : `AIDHABITAT_SYNC_ARCHIVE=1` ajouté par Renan dans Easypanel, API redéployée. Conteneur démarré à 14 h 41 UTC, variable présente, `AIDHABITAT_CONDITIONAL_SYNC=1` toujours présent. Pour éteindre : retirer la ligne et redéployer.
- App web publiée en **1.0.0+116** (image `aidhabitat-web:sync-archive-926e44b…`), avec l'écran « Valeurs archivées ». Retour arrière web : image `aidhabitat-web:release115-plan-quality-007edb5dcf9b61fa31f13ebb07b1ccf2dd6e200b`.

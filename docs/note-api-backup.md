# Sauvegarde de secours des notes par API

État : implémentation préparée, désactivée par défaut. Aucune donnée réelle n'a été sauvegardée par ces tests. Aucun déploiement ni montage de production n'est validé ici.

## Contrat et garanties

- `POST /api/note-backups`, session authentifiée, corps `{patientId, snapshotJson}`. Le snapshot JSON version 1 contient l'opération locale déchiffrée et la note locale, séparément, même si leurs dessins diffèrent. Le serveur conserve exactement les octets UTF-8 de snapshotJson ; il vérifie les identités patient et note, y compris les colonnes SQLite `patient_local_id` et `local_id`.
- Réponse 201 (création) ou 200 (même copie déjà présente) : `{success:true,data:{receipt}}`. Le reçu contient `backupId`, `sha256`, `bytes`, `createdAt`, `source:local-operation`, `storedVerified:true`.
- `GET /api/note-backups/:backupId` relit et vérifie l'archive avant de rendre son reçu. `GET /api/note-backups/:backupId/content` rend `{success:true,data:{patientId,snapshotJson,receipt}}` après la même vérification.
- Propriétaire dérivé exclusivement du compte serveur authentifié (`ergo:<ergoRecordId>`). Lecture réservée à ce propriétaire avec vérification de son accès actuel au bénéficiaire. Réponses `private, no-store`.
- AES-256-GCM avec nonce aléatoire et identité propriétaire/archive/clé liée par AAD. Fichiers immuables, publication atomique sans remplacement, permissions 0600, répertoires 0700. Synchronisation fichier et répertoires, puis relecture et déchiffrement complets avant reçu. Une répétition identique retrouve la même archive.
- Aucun effacement ou acquittement de file, aucune résolution de conflit, aucune écriture de note métier par les endpoints de sauvegarde. Un reçu n'est jamais une confirmation de synchronisation. Le client doit relire `/content` et comparer la copie exacte avant d'afficher sa confirmation.

## Activation explicite du stockage

Variables nécessaires :

| Variable | Valeur attendue |
| --- | --- |
| `AIDHABITAT_NOTE_BACKUP_ENABLED` | `1`, sinon service indisponible |
| `AIDHABITAT_NOTE_BACKUP_DIR` | Chemin absolu canonique d'un volume durable existant, permissions 0700 |
| `AIDHABITAT_NOTE_BACKUP_DURABLE` | `1`, attestation de configuration par l'opérateur |
| `AIDHABITAT_NOTE_BACKUP_KEY_ID` | Identifiant de la clé active, alphanumérique, `_` ou `-` |
| `AIDHABITAT_NOTE_BACKUP_KEYS_JSON` | Objet secret : identifiant vers clé aléatoire de 32 octets encodée en base64 canonique |

Ne jamais placer de clé dans un dépôt, une ligne de commande, un log ou un compte rendu. Conserver une copie de secours des clés séparément de l'hôte et des archives. Garder les anciennes clés lors des rotations : elles restent nécessaires à la lecture des copies existantes.

Un chemin sous `/tmp` ne constitue pas un stockage durable en production. Le code exige un chemin canonique sans alias symbolique et un répertoire privé ; la variable DURABLE n'apporte pas la preuve physique de persistance. Le montage réel, sa capacité, sa sauvegarde externe et une restauration après redémarrage doivent être vérifiés avant activation. `fsync` ne prouve pas à lui seul la durabilité du matériel.

## Capture passive facultative et ciblée

Elle est indépendante des exports explicites et reste désactivée même si le stockage est activé. Pour l'activer, il faut aussi :

- `AIDHABITAT_NOTE_BACKUP_CAPTURE_ENABLED=1` ;
- `AIDHABITAT_NOTE_BACKUP_CAPTURE_TARGETS_JSON`, tableau de cibles exactes `{owner,patientId,tabKey,pageNumber}` (32 au maximum). Propriétaire obligatoire, aucune correspondance générique. Liste vide : aucune capture. Configuration invalide : aucune capture, aucun faux reçu.

Exemple de cible **fictive** : `[{"owner":"ergo:fiction","patientId":"fiction-patient","tabKey":"Plans","pageNumber":1}]`.

La capture intervient après authentification et autorisation du bénéficiaire, avant l'écriture conditionnelle de la note. Elle conserve seulement le PUT reçu, avec `source:sync-request`, pas la note locale distincte ni toute la file de l'iPad. Elle ne change pas les codes 409/413 et ne force aucune écriture. Une erreur de sauvegarde laisse la synchronisation suivre son comportement existant ; aucun reçu n'est ajouté. Sur erreur métier, `backupStatus:unavailable` peut signaler l'échec de copie.

Pour cet incident, configurer uniquement les deux cibles autorisées et le compte concerné, après vérification de son identifiant serveur. Les versions iPad actuelles n'envoient pas les opérations déjà en conflit via la relance globale : la capture passive seule ne protège donc pas le plan déjà bloqué. Le bouton d'export explicite nécessite le nouveau client. Ne pas résoudre un conflit pour déclencher une sauvegarde.

## Limites et capacité

Snapshot UTF-8 : 20 Mio maximum ; corps HTTP global existant : 30 Mio. Le double encodage JSON augmente la taille du corps et de l'archive ; une archive peut approcher 54 Mio pour un snapshot de 20 Mio. Lecture d'archive limitée à 64 Mio. Les limites du proxy doivent aussi être vérifiées. Les erreurs 413 antérieures au gestionnaire HTTP ou les copies au-delà de ces limites ne sont pas sauvegardées.

Aucune compression, aucune purge automatique et aucune limite globale de volume ajoutée. Une nouvelle version produit une nouvelle archive : surveiller espace libre, quota, coût et taux d'écriture avant activation. La capture ciblée limite le périmètre mais conserve les changements de ces cibles ; ne pas activer globalement pour chaque frappe. Définir la durée de conservation avant un usage durable. Cette fonction ne constitue pas une sauvegarde complète de l'iPad (pièces jointes, clés du coffre local et autres données ne sont pas incluses).

## Restauration indépendante

Copier les archives chiffrées et récupérer le trousseau de secours par des canaux autorisés distincts. Sur une machine de restauration sécurisée :

```sh
node tools/verify-note-backup.mjs --archive /secure/archive.json --keys-file /secure/keyring.json --owner ergo:fiction --out /secure/restored-snapshot.json
```

Le trousseau est un fichier JSON secret au même format que KEYS_JSON. L'outil déchiffre et vérifie l'identité, l'authentification GCM, la taille et le hash. Il crée un fichier 0600 sans écraser de destination existante. Il ne contacte pas l'API et ne réinjecte aucune note. La sortie restaurée contient des données en clair : la conserver dans le périmètre sécurisé de restauration. La réinjection métier doit être décidée séparément après comparaison des versions.

Avant activation réelle : tester un aller-retour avec données fictives, redémarrer le service avec le volume conservé, relire l'archive puis réaliser la restauration indépendante avec les clés de secours. Les tests automatisés vérifient le protocole et la restauration locale ; ils ne remplacent pas cette vérification d'exploitation.

## Désactivation et retour arrière

Désactiver d'abord CAPTURE_ENABLED, puis éventuellement BACKUP_ENABLED. Préserver le volume et toutes les clés ; désactiver l'API ne supprime aucune archive. Garder l'outil de récupération compatible disponible. Le retour arrière du fractionnement des notes obéit aux contraintes distinctes de `note-content-chunks.md`.

## Vérifications automatisées

`node --test server/noteBackup.test.mjs server/noteBackupCapture.test.mjs` couvre : octets exacts (avec UTF-8 et note locale différente), forme SQLite du client, chiffrement, dédoublonnage et concurrence, corruption, propriétaire et droits, rotation, fichiers symboliques/répertoire non privé, contrôle HTTP réel des conflits et limites, absence de faux reçu si clé/volume indisponible, sélection exacte des cibles et restauration indépendante sans écrasement.

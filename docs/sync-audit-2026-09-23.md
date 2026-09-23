# Audit synchronisation offline-first — 23 septembre 2026

## État observé avant correction

- `main` et `origin/main` : `de12ba34565647263ec2ee495c6a1355d5bf62a1`.
- correctif inspecté : `12efe33cb67c36876b8fe7927b51b1bf63ea1862` sur
  `codex/prevent-note-write-on-open` ; build Flutter `1.0.0+34`.
- Web live : `version.json` = build 33 et `release.json.gitSha` = `de12ba3`.
- API live : `/api/health/ready` = `ready`, mais `buildSha` = `65464c1`.
  L'API et le manifeste Web ne sont donc pas traçables au même commit, même
  si aucun fichier serveur n'a changé entre ces deux révisions.
- La file IndexedDB de la session Coralie et la base SQLite de l'iPad n'étaient
  pas accessibles depuis la session d'audit isolée. Aucun état de file réel
  n'a été modifié ou supposé.

## Diagnostic confirmé

L'ancien `_seedQuickNoteFromProjectComment()` était appelé depuis
`DossierScreen.initState`. Un cache vide était traité comme l'absence d'une
note serveur ; le commentaire projet était alors envoyé par
`saveNoteDrawingJson`. Pour une note serveur déjà existante, cette écriture
sans geste utilisateur partait d'une révision absente et pouvait produire le
409 observé sur `nocodb-beneficiaire-62 / notes_rapides / 0`.

Le commit `12efe33` retire cette écriture et ne fait plus qu'un
`refreshNotePageFromRemote`, dont le merge local ne crée aucune
`sync_operations`.

## Autres écritures automatiques trouvées et corrigées

1. `NotesWidget._switchPage` affectait directement
   `TextEditingController.text`. Le listener interprétait l'hydratation comme
   une frappe et programmait une autosauvegarde. Les changements et
   suppressions de page utilisent maintenant `_setControllerSilently`.
2. L'hydratation des flags médicaux pouvait être renvoyée vers toutes les
   pages. La persistance exige maintenant un jeton
   `medicalFlagsUserEditRevision`, incrémenté uniquement par le callback du
   toggle utilisateur.
3. `RecommendationsTab._load` masquait les anciens brouillons vides puis
   appelait `_scheduleSave`. L'ouverture/reconstruction ne sauvegarde plus ;
   les lignes restent conservées localement jusqu'à une action ou migration
   explicite.

## Règle appliquée

- Lecture, navigation, hydratation, pull et reconstruction : merge du cache
  seulement, aucune mutation sortante.
- Modification utilisateur : mutation avec `mutationOrigin=user_edit`,
  révision de départ, `writeId` stable et prédécesseurs éventuels.
- Migration : chemin distinct avec `mutationOrigin=data_migration`.
- Résolution de conflit : choix utilisateur explicite ; aucune suppression
  automatique d'une opération historique sans provenance.

Les anciennes opérations ne portant pas `mutationOrigin` restent d'origine
inconnue. Elles ne peuvent pas être classées automatiquement comme faux
conflit sans risquer de supprimer une vraie saisie. Pour le conflit historique
ANDASSE, l'action sûre est d'ouvrir le conflit et de comparer : « Prendre la
note du serveur » restaure le snapshot canonique et retire atomiquement
l'opération ; « Conserver ma note locale » rebase la saisie sur la révision
serveur. Aucune purge globale ne doit être utilisée.

## Scénarios automatisés observés

- Cache vide + note serveur existante : 1 ligne `note_pages`, état `synced`,
  révision `server-revision-7`, 0 ligne `sync_operations`.
- Relecture/réhydratation : toujours 1 ligne note et 0 mutation.
- Trois saisies rapides `A → AB → ABC` : 1 seule opération `pending`, contenu
  final `ABC`, `expectedRevision=revision-base`, un `writeId` UUID, 2
  `predecessorWriteIds`, `mutationOrigin=user_edit`.
- Redémarrage avec opération `running` : retour en `pending`, payload conservé.
- Réponse perdue : rejeu idempotent couvert par les tests serveur POST/PUT/
  DELETE et par le CAS des notes.
- Deux clients, même champ : un succès gardé et un 409 visible.
- Deux clients, champs distincts : fusion sans faux conflit.
- Anciennes mutations sans métadonnées : conservées et non rejouées en boucle.

Validations exécutées depuis `/tmp/aidhabitat-note-sync-test` :

- `flutter analyze` : 0 problème ;
- tests ciblés synchronisation : 98 réussis ;
- `tool/test_sync_critical.sh` : 713 réussis ;
- contrats Node : 12 réussis ;
- tests serveur : 266 réussis.

## Blocages avant fusion/déploiement

Les critères de production ne sont pas encore démontrés : il manque deux
clients authentifiés réellement isolés, l'accès à la file Coralie/iPad, le
contrôle PostgreSQL/NocoDB avant/après et la vérification Easypanel de l'image
effective. En conséquence, aucun push, merge, nettoyage de conflit ou
déploiement n'a été effectué pendant cet audit.

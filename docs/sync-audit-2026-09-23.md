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
  pas accessibles depuis la session d'audit isolée. Le demandeur a ensuite
  confirmé que toutes les données étaient fictives et a ouvert une session
  Admin, ce qui a permis un essai réel sur une origine locale isolée.

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

## Défauts de transport révélés par l'essai réel

Le premier vrai changement utilisateur a révélé un second défaut, distinct de
l'écriture à l'ouverture : SQLite utilise un identifiant local synthétique
`note_<patient>_<onglet>_<page>`, mais le client l'envoyait comme
`notePageId` distant. L'adaptateur NocoDB cherchait alors cet identifiant dans
`uuid_source`, ne trouvait pas la ligne existante et répondait
`NOTE_PAGE_RECORD_MISSING`.

La correction adresse désormais une note versionnée par sa clé canonique
`patientId + scopeType + scopeId + tabKey + subTabKey + pageNumber`. Un
`notePageId` local stable n'est envoyé que pour une création sans révision.

Ce premier 409 historique ne contenait pas de révision distante ; l'ancien
bouton « Conserver ma note locale » refusait donc avant tout appel HTTP. La
résolution relit maintenant la note canonique sans cache, récupère sa révision
courante, rebase explicitement l'opération puis déclenche le PUT gardé.

Enfin, les lectures de notes portent un paramètre `_syncRead` unique et les
routes GET serveur déclarent `Cache-Control: private, no-store, no-cache,
must-revalidate` (plus `Pragma` et `Expires`). Une lecture de concurrence ne
peut ainsi plus recevoir un `304` fondé sur un snapshot obsolète.

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

## Essai réel Admin contre l'API live

Build local 34 servi sur `http://127.0.0.1:8088`, avec stockage navigateur
isolé et API `https://api.aidhabitat.fr` :

1. ouverture du dossier fictif ANDASSE Martine, attente puis navigation entre
   « Note écrite » et « Note dessin » : GET ciblé uniquement, aucun PUT ;
2. ajout volontaire du marqueur `TEST-SYNC-B34-20260923-A` : le conflit a
   reproduit l'erreur d'identifiant distant décrite ci-dessus ;
3. après correction, choix explicite « Conserver ma note locale » : relecture
   canonique en 200, réémission gardée, disparition de la bannière et
   « Aucun blocage dans la file locale » ;
4. retour à la liste puis réouverture du dossier : marqueur relu, aucune
   nouvelle écriture ni nouveau conflit.

Seule cette note fictive a été modifiée par l'essai. Le conflit homologue de
l'onglet de production déjà ouvert n'a pas été manipulé.

Validations exécutées depuis `/tmp/aidhabitat-note-sync-test` :

- `flutter analyze` : 0 problème ;
- tests ciblés synchronisation : 106 réussis ;
- `tool/test_sync_critical.sh` : 715 réussis ;
- contrats Node : 12 réussis ;
- tests serveur : 266 réussis.

## Restant avant fusion/déploiement

Le chemin ouverture → vraie saisie → conflit → rebase → ACK → relecture est
maintenant démontré sur un client isolé contre l'API live. Il reste à valider
un conflit réellement concurrent avec un second client/origine, puis à
contrôler le SHA de l'image Easypanel après déploiement. La divergence de
traçabilité actuelle (`de12ba3` Web contre `65464c1` API) doit aussi être
résolue. Aucun push, merge ou déploiement n'a été effectué pendant cet audit.

## Parcours fonctionnels Admin supplémentaires

Essais effectués le même jour dans la session Web locale connectée à l'API
live. Les données de test sont fictives ; les éléments laissés en place sont
énumérés pour permettre un nettoyage ultérieur explicite.

- Documents ANDASSE Martine : import de `TEST-ADMIN-PARCOURS-20260923.txt`,
  renommage en `TEST-ADMIN-PARCOURS-20260923-V2`, puis contrôle de persistance
  après redémarrage à chaud. Le premier renommage a déclenché l'assertion
  Flutter « TextEditingController was used after being disposed ». Le dialogue
  utilise maintenant `TextFormField.initialValue` et le renommage a été rejoué
  avec succès. Document de test conservé dans le dossier.
- Relevé de visite ANDASSE : ajout de la note explicite
  `TEST ADMIN 23/09/2026 — note de vérification VAD.` sans remplacer le texte
  existant ; tracé sur les pages Plans et Mesures ; occupants passés de 1 à 2
  puis rétablis à 1. Les saisies sont visibles localement, mais le plan reste
  en conflit de synchronisation (voir ci-dessous) ; sa persistance distante
  n'est donc pas validée.
- Bibliothèque : création de
  `TEST ADMIN 23/09/2026 — élément bibliothèque`, recherche, ouverture puis
  suppression par l'interface après confirmation expresse. Le résultat de
  recherche est redevenu vide ; l'application annonce un masquage local puis
  une suppression à la prochaine synchronisation. Les autres éléments n'ont
  pas été touchés.
- Caisses de retraite : création et ouverture de
  `TEST ADMIN 23/09/2026 — caisse fictive`. Ni la fiche ni la fenêtre d'édition
  ne proposent « Supprimer » ; les routes serveur inspectées n'exposent que
  GET/POST/PUT. La suppression demandée n'a donc pas pu être validée dans
  l'interface. Cette caisse de test est toujours présente.
- Rapport PDF : génération depuis ANDASSE bloquée par le conflit de plan,
  avec message explicite. Génération réussie sur le dossier fictif
  `FICTIF DEMONSTRATION Anne-Gaëlle` malgré l'avertissement de champs
  incomplets, après validation dans l'interface. Le rapport figure dans ses
  Documents, s'ouvre en aperçu et se télécharge. PDF A4 de 16 pages, non
  chiffré ; couverture et pages de plan contrôlées visuellement. Les deux
  pages de plan sont vierges dans ce dossier qui n'a pas de tracé. Le fichier
  téléchargé est dans `~/Downloads/Rapport - FICTIF DEMONSTRATION Anne-Gaëlle.pdf`.

## Nouveau défaut bloquant : confirmation d'écriture de plan

La console réseau montre un `PUT /api/note-pages` répondant d'abord 503
`NOTE_PAGE_WRITE_UNCONFIRMED`, puis un rejeu du même `writeId` répondant 409
`NOTE_PAGE_WRITE_ID_REUSED`. La réponse 409 contient pourtant la révision
`415eeace-1c73-4dad-8409-930eb36e25e9`, égale au `writeId`, et le dessin
attendu. L'écriture initiale a donc eu lieu ; c'est sa confirmation serveur
qui échoue. `upsertNotePage` ajoute `plan_phase` à `desiredFields` lorsque la
colonne existe, mais `getNotePageFields` ne la lisait pas. La comparaison
`matchesDesired` voyait systématiquement ce champ absent et concluait à tort
à une écriture non confirmée. Le correctif local inclut `plan_phase` dans les
lectures de confirmation si la colonne existe, avec tests pour les schémas
anciens et nouveaux. Il n'est pas déployé : le conflit visible dans la session
Admin ne doit pas être déclaré résolu avant essai réel après déploiement.

Le correctif client de l'accusé de réception des sauvegardes successives de
notes (rebase automatique uniquement si la révision distante est l'un des
`predecessorWriteIds` locaux) et ses tests sont également encore locaux.
Ne pas cliquer « Prendre la note du serveur » pour effacer le plan de test.

Validations de cette extension : test Node `mobileSyncStore.noteFields.test.mjs`
(2 réussis), contrôle PDF `pdfinfo`/`pdftotext` et rendu des pages 9 à 11.
Les tests Flutter ciblés (57 réussis), la suite Flutter (951 réussis) et
`flutter analyze` (0 problème) ont été exécutés après les corrections client.
Le correctif serveur nouveau nécessite encore un test sur l'API déployée.
Toujours aucun commit, push ou déploiement.

## Relevé de visite : parcours des onglets restants

Sur le dossier fictif `FICTIF DEMONSTRATION Anne-Gaëlle`, avec accord exprès
pour les saisies `TEST ADMIN 23/09/2026`, les onglets non encore exercés ont
été parcourus dans la session Admin. Vérification visuelle effectuée après
fermeture accidentelle d'Arc, redémarrage du serveur Flutter local et
rechargement de la session :

- **Contexte de vie** : note médicale de test retrouvée. La note d'autonomie
  saisie auparavant n'apparaît plus : les sous-vues Médicale et Autonomie
  affichent le même champ de note et la dernière valeur saisie l'a remplacée.
  Les trois rubriques médicales et les mesures taille/poids préexistantes
  n'ont pas été modifiées.
- **Accessibilité** : navigation des sous-vues Général, Niveaux, Équipements et
  Extérieur ; note générale et localisation de volets manuels
  `TEST ADMIN 23/09/2026` retrouvées dans Équipements.
- **Salle de bain** et **WC** : note sanitaire commune retrouvée dans les deux
  onglets ; largeur de porte SDB `80 cm` et hauteur de cuvette `45 cm`
  retrouvées après rechargement.
- **Photos** : ajout d'une photo générique de porte depuis les assets du dépôt
  dans la section Logement ; vignette retrouvée après rechargement. Une photo
  plus ancienne de la section Accessibilité affiche toujours une vignette
  cassée. Le logo Aid'Habitat déjà présent en photo Logement a été conservé.
- **Résumé** : textes de test ajoutés sans supprimer les valeurs préexistantes
  dans les deux sous-vues Rapport (Préconisations et Projet de l'usager) et
  retrouvés après rechargement. La sous-vue Relevé montre toujours les traits
  de dessin préexistants ; aucun nouveau trait n'y a été ajouté.
- **Préconisations** : ajout depuis la bibliothèque wiki d'une carte
  `Accoudoirs rabattables WC`, retrouvée en deuxième position après
  rechargement. Son illustration ne s'affiche pas (icône d'image manquante).
  Une tentative ultérieure de préfixer son titre avec le marqueur de test a
  été interrompue par une bascule/fermeture de la fenêtre Arc : le titre
  marqué n'a **pas** été confirmé et ne doit pas être considéré comme
  enregistré. La carte se reconnaît donc par son intitulé et sa position.

Les onglets Bénéficiaire, Mesures et Plans avaient déjà été exercés sur le
dossier fictif ANDASSE Martine (note, occupants, tracés/mesures). Le parcours
couvre ainsi les dix onglets de premier niveau du relevé, mais pas toutes les
combinaisons de champs et de sous-vues. Les constats ci-dessus prouvent la
persistance **dans ce navigateur après rechargement**, pas encore l'absence
de conflit sur un second client. La bannière globale « Synchronisation en
échec » reste affichée à cause du conflit de plan ANDASSE, et l'API live ne
contient pas encore le correctif serveur `plan_phase`.

Incident d'environnement pendant ce contrôle : après fermeture inattendue
d'Arc, le serveur Flutter debug continuait à servir les fichiers mais la page
restait blanche, sans exception applicative visible dans la console. Le
redémarrage à chaud a expiré (`received 0/2 responses`) et a arrêté le
serveur ; un nouveau `flutter run -d web-server` a rétabli l'application et
la session Admin. L'origine exacte de la fermeture d'Arc n'est pas établie.
Une seconde bascule s'est produite pendant une tentative d'édition de titre ;
ne pas attribuer ce comportement à la webapp sans reproduction instrumentée.

## Reprise ciblée synchronisation avant déploiement

Session du 23 septembre 2026 sur la branche
`codex/prevent-note-write-on-open`, application locale
`http://127.0.0.1:8088/?audit=live-20260923-1`, compilée avec
`AIDHABITAT_API_BASE_URL=https://api.aidhabitat.fr`. Une première exécution
avait omis ce `dart-define` et tentait uniquement `localhost:3001` ; elle a été
arrêtée avant toute écriture, puis le build correct a été relancé avec un
paramètre anti-cache. Tous les nouveaux contenus ci-dessous concernent
exclusivement `FICTIF DEMONSTRATION Anne-Gaëlle` (`nocodb-beneficiaire-86`,
scope `demo-technicien-20260917-annegaelle`). Le réseau du navigateur a été
rétabli sur « No throttling » à la fin du scénario.

### Note écrite et reprise hors ligne

- **Ouverture sans modification, confirmée par le réseau** : l'ouverture du
  dossier et les bascules Note écrite/Note dessin ont produit des GET ciblés
  `/api/note-pages/...` en 200 (OPTIONS en 204), sans PUT ni POST.
- **Sauvegardes rapprochées, confirmées par l'API** : saisie en trois étapes de
  `TEST AUDIT SYNC 23/09/2026 — NOTE CRITE S1 | S2 | S3`, puis ajout
  ` | API-OK`. Les quatre PUT `/api/note-pages` observés ont répondu 200. La
  valeur était toujours visible après rechargement.
- **Hors ligne, confirmé localement** : avec le profil DevTools « Offline »,
  ajout de ` | OFFLINE`. Le texte est resté visible après retour à la liste et
  réouverture du dossier. Les lectures réseau ont bien échoué avec
  `net::ERR_INTERNET_DISCONNECTED` ; aucun succès distant n'a été revendiqué
  pendant cette phase.
- **Reprise, confirmée après rechargement et par le service** : au retour à
  « No throttling », la file a lancé automatiquement le PUT en attente
  (préflight 204), l'indicateur orange local a disparu, puis un rechargement et
  un GET ciblé 200 ont restitué la valeur complète avec ` | OFFLINE`. Aucune
  action manuelle sur le conflit ANDASSE n'a été utilisée.

### Note dessin, mesures et plans

- **Note dessin** : ajout d'un petit trait horizontal de test sur la première
  page du même dossier fictif. Des PUT `/api/note-pages` ont répondu 200 et
  les GET ciblés suivants ont répondu 200. Le trait est revenu après
  rechargement : local, rechargement et API sont donc concordants.
- **Mesures** : ajout d'un petit trait diagonal de test, isolé en bas au centre
  de la planche anthropométrique. Il est revenu après rechargement ; les GET
  `tabKey=Mesures` ont répondu 200. Le corps JSON de ce GET n'a pas été ouvert
  dans DevTools : la persistance après rechargement est confirmée dans ce
  navigateur et la lecture API est saine, mais l'inclusion exacte de ce trait
  dans le corps distant n'est pas revendiquée comme vérifiée octet par octet.
- **Plans** : ouverture de « Plan avant travaux », navigation et rechargement
  sans modification. Les tracés fictifs préexistants sont revenus et aucune
  écriture n'a été déclenchée par l'ouverture. Une nouvelle écriture live n'a
  volontairement pas été créée : l'API publique ne contient pas encore le
  correctif `plan_phase` et provoquer un second conflit n'apporterait rien à
  la preuve déjà capturée sur ANDASSE.

Les nouvelles données de test laissées en place sont donc la note écrite
préfixée `TEST AUDIT SYNC 23/09/2026`, le petit trait horizontal de Note dessin
et le petit trait diagonal de Mesures, tous dans le dossier fictif Anne-Gaëlle.

### Conclusion causale : défauts distincts malgré une surface commune

L'hypothèse d'une cause identique n'est **pas** confirmée. Les deux familles
d'erreurs passent par le même endpoint de pages de notes, utilisent la même
révision CAS et finissent par alimenter le même bandeau de conflit, ce qui les
fait se ressembler dans l'interface. Le déclencheur et la séquence serveur
sont toutefois différents :

1. Le défaut historique des notes écrites était client : hydratation qui
   pouvait écrire à l'ouverture, identité locale/canonique divergente, puis
   course entre l'ACK d'une sauvegarde et l'autosave suivante. Le correctif
   rend l'hydratation en lecture seule et ne rebase automatiquement qu'une
   révision distante présente dans les `predecessorWriteIds` de cette même
   file locale. Une révision étrangère reste un vrai 409.
2. Le défaut du plan est serveur : `desiredFields` contient `plan_phase`, puis
   `matchesDesired` compare chaque champ écrit. La projection historique de
   relecture omettait pourtant `plan_phase`. L'écriture NocoDB réussissait,
   mais la confirmation concluait à tort à
   `503 NOTE_PAGE_WRITE_UNCONFIRMED`; le rejeu du même `writeId`, face à la
   ligne déjà écrite mais toujours relue sans ce champ, devenait
   `409 NOTE_PAGE_WRITE_ID_REUSED`. Le helper local `notePageReadFields`
   inclut désormais `plan_phase` uniquement lorsque le schéma l'expose.

Cette conclusion s'appuie à la fois sur la réponse live déjà capturée (dessin
et révision attendus présents malgré 503 puis 409), sur les branches de code
ci-dessus et sur deux tests de projection avec et sans colonne `plan_phase`.
Les 409 de vraie concurrence ou de révision manquante rencontrés avec les
notes écrites ne sont donc pas la même panne que la fausse non-confirmation
du plan.

### Concurrence et vérifications automatisées

Une concurrence live entre deux sessions n'a pas été lancée : aucune seconde
session authentifiée et isolée n'était disponible sans partager l'IndexedDB
ou manipuler des données existantes. La variante contrôlée reste couverte par
les tests : deux écritures du même champ ont un seul gagnant et un 409, deux
champs indépendants sont fusionnés, et une autosave locale qui dépasse son
ACK est rebasée seulement si la révision distante appartient à ses
prédécesseurs.

Vérifications de cette reprise :

- tests Flutter ciblés hydratation/transport/mutations/ACK/écran dossier :
  92 réussis ;
- test Node ciblé `mobileSyncStore.noteFields.test.mjs` : 2 réussis ;
- `flutter analyze` : aucun problème ;
- `npm run test:server` : 268 réussis, 0 échec après `npm ci`. La première
  tentative avait échoué uniquement parce que `node_modules` était absent
  (`express`, `dotenv`, `pdf-lib`, etc.) ; l'installation verrouillée n'a
  modifié aucun fichier suivi ;
- `git diff --check` : propre.

### État de décision

**PAS PRÊT POUR DÉPLOIEMENT GÉNÉRAL.** Les correctifs serveur `plan_phase` et
client sont cohérents et couverts localement, mais ils ne sont pas encore en
service. Le bandeau « Synchronisation en échec » reste celui du plan ANDASSE
Martine ; ni « Prendre la note du serveur », ni suppression de la saisie
locale, ni purge de file n'ont été utilisés. Ce conflit n'est pas déclaré
résolu.

Étapes restantes, dans cet ordre : décision explicite de déploiement ;
déploiement contrôlé du serveur puis du client ; contrôle des SHA réellement
servis ; rejeu de la file existante ANDASSE avec conservation de la saisie
locale ; vérification du PUT/ACK et d'un GET frais incluant `plan_phase` ;
rechargement sans bannière ; enfin concurrence réelle depuis deux stockages
authentifiés isolés sur un dossier fictif. Aucun commit, push ou déploiement
n'a été effectué pendant cette reprise.

## Focalisation sur le conflit ANDASSE encore présent

Dans l'application locale `http://127.0.0.1:8088`, l'ouverture du bandeau
« Synchronisation en échec » montre **une seule opération** : `note_page ·
note_nocodb-beneficiaire-62_Plans_0`, « Conflit de note pour Plans, page 0 ».
La boîte de résolution a été inspectée puis annulée. Ni le choix serveur ni
le choix local n'ont été activés ; le dessin et l'opération demeurent intacts.

La disparition durable du bandeau requiert deux actions distinctes, dans cet
ordre : (1) servir le correctif de relecture `plan_phase` côté API, qui évite
le faux `503 NOTE_PAGE_WRITE_UNCONFIRMED` et le `409 NOTE_PAGE_WRITE_ID_REUSED`
au rejeu ; (2) **reprendre explicitement la seule opération déjà en conflit**
via « Conserver ma note locale ». Le client relit alors la révision canonique
sans cache, conserve `drawingJson` et `planPhase`, affecte cette révision à
`expectedRevision`, génère un nouveau `writeId`, et remet l'opération en
attente. Un correctif serveur seul ne dépile pas une opération `conflict` ;
une disparition du bandeau avant ACK ne prouverait pas non plus la persistance.

Un test de régression ciblé `plan write-id conflict keeps the drawing until a
fresh ACK` reproduit un conflit `NOTE_PAGE_WRITE_ID_REUSED` sur un plan
entièrement fictif. Il vérifie que le dessin et `planPhase=avant` survivent à
la remise en file, que la révision fraîche et un nouveau `writeId` sont
employés, puis que l'état `synced` n'arrive qu'après l'ACK. Le fichier
`sync_acknowledgement_test.dart` passe : 58 tests. Le correctif de projection
serveur reste couvert par les 2 tests `mobileSyncStore.noteFields.test.mjs`.
Ce test Node a été relancé avec succès (2/2), et `git diff --check` reste
propre. `/api/health/ready` annonce encore le 23/09/2026 le SHA
`65464c190f15e6245a1a49e06e673f9f25e2705e` : le correctif local
`plan_phase` n'est pas en service.

**État actuel : pas prêt à déclarer le conflit résolu.** Aucune API mise à
jour, aucun PUT/ACK sur l'opération ANDASSE existante, aucun GET frais
confirmant le plan, et aucune disparition du bandeau après rechargement ne
sont encore constatés. Aucun commit, push ou déploiement n'a été effectué.

## Déploiement contrôlé du correctif serveur — autorisé ensuite

Après accord explicite de l'utilisateur, seul le correctif serveur a été
commité : `fba6cd094400a69f320e944da13501748467cc63` (`Fix plan phase
readback in note sync`), contenant `mobileSyncStore.mjs`,
`notePageFields.mjs` et `mobileSyncStore.noteFields.test.mjs`. Les modifications
client et le présent journal restent non commitées. La branche
`codex/prevent-note-write-on-open` a été poussée ; `main` n'a pas été modifiée.

Contrôles locaux avant publication : contrats de synchronisation 12/12,
tests serveur 268/268, flux critiques 20/20, vérification syntaxique et
`git diff --check` propres. Le groupe de tests de publication local compte
39/40 réussites : le seul échec est un faux positif du test de confidentialité
qui cherche le mot `private` dans une stack trace ; ce mot provient du chemin
de travail `/private/tmp/...`, non d'une URL ou d'un secret. La validation
GitHub Actions, exécutée sur un autre chemin, est entièrement verte :
[run sans publication](https://github.com/contact-aid/aidhabitat-manager/actions/runs/35877544116).

Le [run de publication](https://github.com/contact-aid/aidhabitat-manager/actions/runs/35877687553)
a ensuite publié l'image API `latest`, appelé le webhook Easypanel et réussi
son attente de version/readiness. Une vérification indépendante des endpoints
publics `/api/health/live` et `/api/health/ready` renvoie dans les deux cas
le SHA complet `fba6cd094400a69f320e944da13501748467cc63` avec état sain.

**Limite à ce stade :** cela confirme le binaire API actif, pas encore la
persistance d'un plan par le nouvel endpoint ni la résolution de la file
ANDASSE. L'opération locale n'a pas été relancée et aucune donnée de plan
n'a été écrite pendant cette étape de déploiement.

### Essai applicatif commencé après déploiement

Dans la session Arc authentifiée sur `http://127.0.0.1:8088`, le dossier
`FICTIF DEMONSTRATION Anne-Gaëlle` a été ouvert sur « Plans / Plan avant
travaux ». Un tracé manuscrit `TEST` a été ajouté dans la partie supérieure
de la planche. La session Arc s'est fermée pendant l'inspection réseau :
aucun PUT/ACK ni GET de ce tracé n'a encore été confirmé, et son retour après
rechargement reste à vérifier. Le bandeau montrait toujours l'unique conflit
ANDASSE ; aucune résolution n'a été sélectionnée. Ne pas présenter cet essai
interrompu comme une preuve de persistance.

### Reprise du conflit ANDASSE et anomalie d'ouverture de plan

Après le déploiement serveur confirmé ci-dessus, la session Arc authentifiée
montrait toujours exactement une opération bloquée :
`note_page · note_nocodb-beneficiaire-62_Plans_0` (ANDASSE Martine). Sur accord
de l'utilisateur pour reprendre ce conflit en conservant la saisie locale,
le choix **« Conserver ma note locale »** a été activé. L'application a affiché
« Note locale conservée et remise en synchronisation », puis « Aucun blocage
dans la file locale » ; le bandeau rouge a disparu dans cette session.
**Confirmé localement uniquement :** ni le PUT/ACK correspondant, ni un GET
frais, ni l'absence du bandeau après rechargement ne sont encore établis.
« Prendre la note du serveur » n'a pas été choisi et aucune purge de données
locales n'a été faite.

Le test du dossier `FICTIF DEMONSTRATION Anne-Gaëlle` a révélé un défaut client
distinct : ouvrir sans modification son scénario après travaux existant
(Plans, page 1) a émis un `PUT /api/note-pages` reçu avec HTTP 200. La réponse
portait `patientId=nocodb-beneficiaire-86`, `pageNumber=1`,
`planPhase=apres` et la révision
`3023f4d0-19d6-4854-81a9-1f78782d7335`. Le code expliquait cette écriture
non sollicitée : `PlansTab` activait `refreshPreviewOnLoad` pour **toute**
page `apres`, et `PlanCanvas._loadStrokes` déclenchait alors une sauvegarde.
Une migration d'anciens traits gomme pouvait également déclencher une écriture
à l'ouverture. La lecture d'une page ne doit pas modifier sa révision.

Correctif client **local, non commité et non déployé** : la régénération de
prévisualisation est limitée au scénario que l'utilisateur vient explicitement
de créer ; le décodage des anciens traits gomme ne sauvegarde plus
automatiquement à l'ouverture. Deux tests widget ciblés vérifient l'absence
d'écriture lors de l'ouverture d'un scénario existant et la sauvegarde unique
de prévisualisation du nouveau scénario. Ils passent (2/2) et
`flutter analyze --no-pub` ne signale aucun problème. Ce défaut d'ouverture
est une cause client distincte du défaut serveur de relecture `plan_phase`.

La session Arc a ensuite affiché une page blanche après changement de fenêtre.
Le serveur de développement local répond HTTP 200 et DevTools a chargé les
scripts Flutter sans erreur JavaScript explicite, mais l'application n'a pas
encore rendu son interface après rechargement. La vérification « visible après
rechargement » et la confirmation effective par l'API du plan ANDASSE restent
donc **en attente**. Un essai de compilation web locale est en cours pour
isoler le serveur de développement ; il ne constitue pas un déploiement.

### Contrôle final du plan ANDASSE après rechargement

La compilation `flutter build web` a réussi. Le build **local** est servi sur
`http://127.0.0.1:8088` par un serveur HTTP statique, sur le même origin et
donc avec le stockage Arc conservé ; ce n'est pas un déploiement. Cette
version s'affiche correctement, contrairement à la session de développement
Flutter restée blanche. Après plusieurs rechargements, le bandeau rouge est
absent. L'ouverture en lecture seule du dossier ANDASSE puis de « Plans / Plan
avant travaux » montre toujours les deux éléments du dessin (élément libre et
porte). Aucun choix « Prendre la note du serveur » ni effacement local n'a été
fait.

**Confirmé par l'API en service :** le GET frais
`/api/note-pages/nocodb-beneficiaire-62?_syncRead=1790176940675000` a répondu
HTTP 200 (24,4 kB effectivement transférés, cache DevTools désactivé). Sa
réponse contient la page `note_nocodb-beneficiaire-62_Plans_0`,
`tabKey=Plans`, `pageNumber=0`, `planPhase=avant`, la révision
`e77bab8e-1ebb-46d8-9ac4-deae4cd89652` et un `drawingJson` de format
`plan_canvas_v1` avec exactement les deux traits `freeElement` et `door`
affichés. La version d'API active est le SHA serveur `fba6cd0944…` vérifié
ci-dessus. L'état observé satisfait la vérification de persistance du plan et
la disparition du conflit bloquant après rechargement. **Limite :** Arc s'est
fermé pendant la première capture réseau ; le PUT/ACK exact du rejeu initial
n'a pas été enregistré, même si le GET frais, la révision et l'absence de
blocage confirment l'état serveur final.

Les tests client ciblés couvrent maintenant aussi l'ouverture d'un ancien
dessin contenant un trait gomme : **3/3 réussis** ; `flutter analyze --no-pub`
reste sans anomalie et `git diff --check` est propre. Le correctif client
d'ouverture sans écriture reste **local, non commité, non poussé, non déployé**.

**Décision de déploiement :** le correctif serveur déjà autorisé est en
service et le conflit ANDASSE n'est plus bloquant sur le poste vérifié. La
branche client n'est **pas encore prête pour un déploiement général** : il
reste à examiner/valider ce nouveau correctif client, puis à décider
explicitement de son commit, push et déploiement. Les sauvegardes rapprochées
et la concurrence sur deux sessions isolées demandées dans l'audit initial ne
sont pas encore validées par le contrôle ciblé ANDASSE.

### Clarification du périmètre web (retour utilisateur)

La création d'un scénario **reprend volontairement le plan avant travaux**, qui
reste éditable pour y ajouter les modifications proposées. Ce comportement est
attendu et n'était pas l'anomalie signalée : celle-ci était le `PUT` déclenché
par la simple **ouverture d'un scénario déjà existant**, sans modification de
l'utilisateur. Le correctif local conserve la copie initiale et la sauvegarde
liées à une création explicite, tout en rendant la réouverture en lecture seule.

Les essais hors ligne sont retirés du périmètre de validation demandé pour la
webapp. Ils ne sont donc ni un prérequis à cette livraison web ni considérés
comme réussis. Restent pertinents sur le web : ouverture sans modification,
sauvegardes rapprochées, rechargement/relecture API et, si réalisable sans
risque pour des données existantes, concurrence contrôlée sur dossier fictif.

### Retour des essais manuels utilisateur

L'utilisateur précise avoir effectué les essais manuels dans la webapp locale
sur le dossier réel **HEURTEL Sylvie**, scénario 1 / plan avec travaux, sans
bandeau rouge ni page blanche. Ces gestes ont été réalisés par l'utilisateur,
pas par l'agent ; ils ne constituent pas le test sur dossier fictif demandé
initialement. **Observation visuelle déclarée par l'utilisateur uniquement** :
le détail de la dernière modification après rechargement et les réponses API
de cette série n'ont pas été capturés. Ne pas présenter ces modifications
comme confirmées par l'API ; ne pas refaire d'écriture sur ce dossier réel.
Aucun nouveau geste n'a été fait sur ANDASSE.

Après ce retour, les tests ciblés `plan_canvas_read_only_load_test.dart` et
`sync_acknowledgement_test.dart` ont été relancés : **61/61 réussis** ;
`flutter analyze --no-pub` : **aucune anomalie**. Le client demeure local,
non commité, non poussé et non déployé.

### Rectangle du scénario fictif : relecture API confirmée

Sur demande, l'utilisateur a ajouté un rectangle au **scénario 1** du dossier
`FICTIF DEMONSTRATION Anne-Gaëlle`, puis a rechargé : il déclare le rectangle
toujours visible. L'agent a constaté à son tour la présence du rectangle en
haut à droite après navigation/rechargement dans la session Arc locale.

La capture réseau Arc avec cache désactivé montre un `GET` frais
`/api/note-pages/nocodb-beneficiaire-86?_syncRead=1790178023394000`, **HTTP
200**, 115 kB transférés. Dans sa réponse JSON, la page `tabKey=Plans`,
`pageNumber=1`, `planPhase=apres`, révision
`027e6063-54d8-44e2-b310-71018b03577c` contient dans `drawingJson`
(`plan_canvas_v1`) un élément `freeElement` avec les points
`[[1278.0625,212.93359375],[1333.0625,247.93359375]]`, correspondant au
rectangle visible en haut à droite. **La présence dans l'API en service est
ainsi confirmée**, au-delà du seul cache local et de l'affichage après
rechargement. La réponse exacte du PUT initial de l'utilisateur n'a pas été
capturée ; ne pas prétendre avoir observé cet ACK. Les requêtes capturées lors
de la relecture en lecture seule ne montraient pas de PUT pour ce dossier.

Le test de concurrence entre deux sessions reste non exécuté : il est
facultatif dans le périmètre initial uniquement si réalisable sans risque. La
preuve ci-dessus ne couvre pas ce cas. Aucun nouveau geste n'a été fait sur
ANDASSE ou HEURTEL par l'agent.

**Bilan à ce stade :** le parcours plan fictif est validé visuellement après
rechargement et par relecture API ; les tests ciblés et l'analyse Flutter
passent. **Pas prêt pour un déploiement client immédiat** : le correctif client
est encore mêlé à d'autres modifications non commitées dans l'arbre de
travail, qui doivent être préservées et délimitées avant préparation du commit.
La concurrence entre deux sessions et l'ACK exact du dernier PUT n'ont pas
été observés. Toute publication client requiert une décision explicite de
l'utilisateur ; l'autorisation antérieure ne concernait que le serveur.

### Préparation du périmètre client, sans publication

Revue du diff local : le correctif client proposé comprend
`lib/components/plan_canvas.dart`, `lib/screens/visit_report/plans_tab.dart`,
`lib/services/sync_repository.dart`, les tests
`test/components/plan_canvas_read_only_load_test.dart` et
`test/services/sync_acknowledgement_test.dart`, ainsi que ce journal d'audit.
La modification de `lib/screens/documents_screen.dart` (renommage de document)
et `docs/TEST-ADMIN-PARCOURS-20260923.txt` sont **hors périmètre** et restent
intacts. Aucun fichier n'a été ajouté à l'index Git.

Vérifications sur l'arbre de travail actuel (qui contient toujours le
renommage de document hors périmètre) : `flutter test --no-pub` **955/955 réussis** ;
`flutter analyze --no-pub` **aucune anomalie** ; `flutter build web --no-pub
--dart-define=AIDHABITAT_API_BASE_URL=https://api.aidhabitat.fr` **réussi** ;
`git diff --check` **propre**. Le build JavaScript est utilisable ; le contrôle
facultatif de compatibilité WebAssembly émet des avertissements pour
`dart:html`/`dart:js` et certaines dépendances, sans échec du build standard.
La CI devra revérifier le commit limité aux fichiers retenus avant tout
déploiement client.
Le code client demeure **non commité, non poussé et non déployé**. Étape
suivante : décision explicite de l'utilisateur sur le commit/push puis un
déploiement client contrôlé de ce seul périmètre.

### Diagnostic WebAssembly (hors correctif de synchronisation)

Le pipeline actif `aid_habitat_app/tool/build_web.sh` lance `flutter build web
--release` **sans** `--wasm` ; avec Flutter 3.38.4, le build JavaScript réussit
et lance automatiquement un contrôle Wasm non bloquant. Pour lever l'ambiguïté,
un `flutter build web --wasm --no-pub` a été lancé vers un répertoire temporaire
distinct : **échec réel de `dart2wasm`**, sans toucher au bundle web local.

Blocages identifiés :

- code applicatif : imports `dart:html` dans le drag-and-drop de fichiers,
  sélecteur de fichiers, téléchargement et ouverture de liens externes ;
- dépendance `flutter_secure_storage` verrouillée en 9.2.4
  (`flutter_secure_storage_web` 1.2.1) : `dart:html`, `dart:js_util` et
  `package:js` incompatibles Wasm ; la série 10.x annonce un backend web
  compatible Wasm, mais comporte des changements de sécurité/migration ;
- `pdfx` verrouillé en 2.9.2 : avertissements d'interop statique ; la version
  2.10.0 annonce des corrections Wasm, à valider sur les fonctions PDF réelles ;
- plusieurs imports conditionnels basés sur `dart.library.html` sélectionnent
  en Wasm des stubs prévus pour le natif. En particulier, `OfflineVault`
  sélectionnerait `offline_vault_stub.dart`, dont `sealString` ne chiffre pas.
  **Ne jamais publier un build Wasm obtenu par simple contournement de la
  compilation sans corriger et tester ce routage de sécurité.**

Conclusion : ces avertissements **ne bloquent pas la livraison web JavaScript
actuelle** et n'expliquent pas le conflit `plan_phase`. Une vraie compatibilité
Wasm est résolvable mais constitue un chantier séparé : migration du code
navigateur vers `package:web`/`dart:js_interop`, revue des imports conditionnels
(`dart.library.js_interop`), montée progressive et testée de
`flutter_secure_storage` (notamment conservation des sessions/clefs existantes)
et de `pdfx`, puis builds JS+Wasm et essais navigateur des flux de stockage,
plans, fichiers, PDF et fenêtres de notes. Ne pas se contenter de
`--no-wasm-dry-run`, qui ne ferait que masquer le diagnostic.

### Préparation de la publication client autorisée

Reprise dans `/private/tmp/aidhabitat-note-sync-test` sur
`codex/prevent-note-write-on-open`, à partir de `fba6cd094400a69f320e944da13501748467cc63`.
L'état Git initial contient les cinq fichiers client/tests retenus et le
présent journal, ainsi que `lib/screens/documents_screen.dart` et
`docs/TEST-ADMIN-PARCOURS-20260923.txt` hors périmètre. Ces deux derniers
fichiers sont conservés sans modification ni mise à l'index.

Contrôles locaux de cette reprise : tests ciblés Flutter **61/61**, analyse
Flutter **0 problème**, contrats de synchronisation **12/12**, flux critiques
**20/20**, tests des contrôles de publication **20/20**, génération des trois
rapports PDF de test réussie. Le build Flutter web JavaScript `--release`
avec `AIDHABITAT_API_BASE_URL=https://api.aidhabitat.fr` a réussi. Le
diagnostic Wasm reste affiché et non bloquant ; Wasm n'est pas activé. Le
contrôle live initial voit encore `app.aidhabitat.fr/release.json` au SHA
`de12ba34565647263ec2ee495c6a1355d5bf62a1`, build 33. Ce n'est pas la
version candidate.
Le script `aid_habitat_app/tool/test_sync_critical.sh` passe aussi avec
**718/718 tests**. `npm run release:live-check` réussit pour le site et l'API
actuellement en service ; ce contrôle ne prouve pas le nouveau bundle.

Le workflow actif `.github/workflows/flutter-web-build.yml` valide le bundle
et peut publier l'image GHCR. Son seul déclencheur de déploiement cible
`EASYPANEL_WEB_STAGING_DEPLOY_URL` et exige le tag `staging`. Le workflow de
déploiement web production historique est désactivé. Le secret
`EASYPANEL_WEB_WEBHOOK` existe dans GitHub Actions, mais aucun workflow actif
ne l'utilise. Avant toute publication, la cible Easypanel et le mécanisme de
bascule de `app.aidhabitat.fr` doivent donc être confirmés ; publier un tag
`latest` ou appeler le webhook staging sans cette preuve ne validerait pas un
déploiement contrôlé de production.

### Résultat du commit client et arrêt avant déploiement

Après `git diff --cached --check`, `git diff --cached --name-status` et revue
du diff, le commit `1fcb1e05c1d66f3ac40d204f278b66c464a6efb9`
(`Keep existing plan loads read-only and guard note ACK retry`) a été créé et
poussé sur `origin/codex/prevent-note-write-on-open`. Il contient exactement
les trois fichiers Dart de production retenus, les deux fichiers de tests
retenus et ce journal. `lib/screens/documents_screen.dart` et
`docs/TEST-ADMIN-PARCOURS-20260923.txt` sont toujours locaux et hors commit.

Un second checkout propre, détaché sur ce SHA, a exécuté `flutter pub get`
puis `flutter test --no-pub --reporter compact` : **955/955 réussis**, sans la
modification Documents. La CI [Build Flutter Web, run
35885697549](https://github.com/contact-aid/aidhabitat-manager/actions/runs/35885697549)
a également réussi sur ce SHA : job natif macOS et job bundle web tous deux
verts. `npm run release:ci-check -- --branch codex/prevent-note-write-on-open
--sha 1fcb1e05c1d66f3ac40d204f278b66c464a6efb9` est OK. L'artefact
CI `aidhabitat-web-1fcb1e05c1d66f3ac40d204f278b66c464a6efb9` a été
téléchargé et contrôlé avec
`node tools/check-web-release.mjs --dir /private/tmp/aidhabitat-web-ci-1fcb1e0
--expected-build-number 34 --expected-git-sha
1fcb1e05c1d66f3ac40d204f278b66c464a6efb9` : **20 contrôles OK**.
Son `release.json` annonce `1.0.0+34`, API
`https://api.aidhabitat.fr`, SHA client ci-dessus et empreinte
`main.dart.js` `5cae56b41852474fc08de18743b4d11d10ea0d61c53eb719a4f5678bcf9cc3f2`.

Le déploiement web **n'a pas été déclenché**. Le workflow de production
`build-deploy-web.yml` est désactivé. Le workflow actif ne peut déclencher que
le secret `EASYPANEL_WEB_STAGING_DEPLOY_URL` avec un tag `staging` ; aucun
mécanisme actif ne relie le secret production `EASYPANEL_WEB_WEBHOOK` à un
déploiement. Les domaines `app.aidhabitat.fr` et
`apps-aidhabitat-web-staging.z5avx1.easypanel.host` renvoient actuellement le
même manifeste build 33, la même empreinte et le même ETag. Cela ne prouve ni
que le webhook staging est isolé, ni qu'il pointe vers le service voulu.
Déclencher ce webhook ou publier `latest` serait contourner l'exigence de
cible contrôlée et de retour arrière vérifiable. Il faut une voie de
déploiement production documentée et vérifiée dans Easypanel pour reprendre.

Le contrôle final de `https://app.aidhabitat.fr/release.json` renvoie toujours
`de12ba34565647263ec2ee495c6a1355d5bf62a1`, `1.0.0+33`.
**Aucune vérification après déploiement du candidat n'est possible** : ouverture
de l'interface, persistance après rechargement et réponse API d'un nouveau
parcours Plans restent non testées pour le build 34. Les preuves antérieures
sur le dossier fictif Anne-Gaëlle concernent le client local, pas le web
public. ANDASSE et les dossiers réels n'ont fait l'objet d'aucune nouvelle
écriture. Aucun build ni publication TestFlight.

**Bilan : pas prêt pour la recette utilisateur sur app.aidhabitat.fr.** Le
correctif est commité, poussé, testé et empaqueté par la CI, mais le site
public sert encore l'ancien build. La prochaine action requiert une
confirmation technique de la cible et du mécanisme de déploiement Easypanel,
puis le déploiement de l'image construite depuis le SHA testé et la recette
web demandée.

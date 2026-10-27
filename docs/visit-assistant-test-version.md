# Assistant de visite : version de test

Branche : `codex/ergo-visit-ai-v1`, à partir du build 104 publié.
Livraison 105 autorisée pour un pilote Coralie/Christelle le 28 octobre 2026.
La preuve de déploiement et les limites de recette figurent dans `release-105-visit-assistant.md`.

## Parcours implémenté

- Bouton microphone dans les en-têtes du dossier, du relevé VAD et des documents.
- Pendant l’enregistrement : niveau sonore réel, durée et bouton Stop.
- Capture native iPad en M4A mono, segments de 60 secondes, jusqu’à 4 heures.
- Les segments restent dans Application Support, exclus de la sauvegarde iCloud,
  avec protection iOS disponible après le premier déverrouillage. Le mode audio
  autorise la capture lorsque l’app passe en arrière-plan ou l’écran se verrouille.
- Une interruption audio arrête la capture. Les fichiers existants restent
  conservés, y compris lorsqu’une récupération nécessite une intervention.
- File locale persistante, liée au compte qui a commencé la visite. Le retour
  du réseau, le retour au premier plan et une vérification périodique relancent
  les opérations. Une déconnexion de compte arrête la capture active.
- Upload séquentiel avec SHA-256 et reprises idempotentes. Le serveur stocke
  les fichiers dans un volume privé persistant, distinct des documents publics.
- Traitement par étapes persistées : transcription des segments, lecture des
  images de notes, extraction de faits sourcés, rédaction, ajout dans les notes.
- Contexte : textes existants, pages manuscrites rasterisées, profil utile,
  contexte médical et autonomie, sanitaires, préconisations déjà sélectionnées.
  Les champs par défaut non cochés ne constituent pas des négations cliniques.
- Rubriques : bénéficiaire, environnement, autonomie, accès, observation
  sanitaire commune SDB/WC, projet de l’usager et résumé des préconisations.
- Ajout automatique après deux retours à la ligne. Le texte existant et les
  dessins sont préservés. Reçus transactionnels pour ne pas dupliquer les
  ajouts. Un ancien snapshot d’éditeur transporte les insertions qu’il n’avait
  pas encore vues ; une correction humaine informée, y compris une suppression,
  reste possible. Le reçu voyage dans les notes synchronisées.
- Onglet « Transcription et IA » après Préconisations : extraits horodatés,
  points à vérifier, questions et réponses avec références aux extraits.
- Dans cette variante, les micros de dictée locale des notes sont masqués et
  les reformulations passent par OpenRouter. Le fonctionnement historique reste
  inchangé dans les builds qui n’activent pas le flag.

## Activation et configuration

Le serveur exige `VISIT_ASSISTANT_ENABLED=true`. Flutter exige
`--dart-define=AIDHABITAT_VISIT_ASSISTANT=true`. Le flag Flutter est désactivé
par défaut. Utiliser une API de test explicitement configurée pour une recette
connectée, jamais l’URL de production par défaut.

Copier les paramètres de `visit-assistant.env.example` dans un fichier privé
`.env.visit-ai.local` (permissions 0600, ignoré par Git), puis lancer :

```sh
node --env-file=.env.visit-ai.local server/index.mjs
```

Le compte NocoDB et la configuration d’authentification de la cible de test
doivent aussi être préparés selon le déploiement existant. Ce fichier seul ne
constitue pas une instance métier complète.

La clé OpenRouter est utilisée uniquement côté serveur. Les requêtes imposent
`provider.zdr=true`, `data_collection=deny` et désactivent les replis. Un modèle
sans fournisseur compatible échoue sans élargir ces critères. Ces réglages ne
constituent pas une validation HDS/RGPD du parcours métier.

## Profils rédactionnels

Le fichier privé `VISIT_STYLE_PROFILES_PATH` est un objet indexé par intervenante.
Chaque profil comporte `version`, `aliases`, `sourceReview.authorVerified`,
`generalRules`, `sections` et éventuellement `styleExamplesOnly`. Les exemples
décrivent la forme et ne sont jamais des faits à réutiliser dans un autre dossier.

Inventaire Airtable effectué le 27 octobre 2026 : 121 PDF pour Coralie,
192 pour Christelle. Tous ont été téléchargés et extraits localement.
Le premier profil utilise les documents distincts dont l’autrice apparaît dans
le texte : 67 et 142 respectivement. Les autres sont exclus en attendant une
vérification. Aucun rapport ni texte de bénéficiaire n’est inclus dans le dépôt.
Les profils initiaux comportent des règles et exemples fictifs issus de l’analyse
locale, sans envoi du corpus clinique à OpenRouter. Leur adéquation doit être
évaluée avec les ergothérapeutes sur des visites tests.

## Vérification automatisée

```sh
node --test server/visitAssistant.test.mjs
npm run test:server
npm run test:sync-contract
npm run check:critical
cd aid_habitat_app
flutter test test/services/visit_ai_notes_test.dart test/components/visit_ai_note_editor_test.dart
```

Un test OpenRouter facultatif génère son propre audio fictif et une image de
texte imprimé. Il vérifie les négations, mesures, rubriques et références :

```sh
VISIT_AI_LIVE_TEST=true node --env-file=.env.visit-ai.local tools/test-visit-assistant-openrouter.mjs
```

L’image imprimée valide le transport multimodal. Elle ne démontre pas la
reconnaissance de l’écriture manuscrite réelle des intervenantes.

## Recette iPad séparée

`tool/visit_ai_device_preview.dart` exige le bundle
`com.aidhabitat.manager.visitaitest`. Elle conserve des données fictives dans
son propre conteneur et permet de tester capture, mode avion et verrouillage
sans toucher à App’Ergo. Les quatre barres sont des points au silence ; leur
sensibilité visuelle fait monter une voix faible sans modifier l’audio enregistré.

La recette connectée utilise `tools/visit-ai-preview-server.mjs`, lancé sur
l’adresse privée du Mac et le port 3308. Il ne fournit que les routes de
l’assistant pour le dossier fictif, avec une session de test limitée à douze
heures. Il ne se connecte pas à NocoDB et n’expose aucune route métier de
production. La clé OpenRouter reste sur le Mac. L’iPad contient uniquement
une session limitée à cette API fictive.

Au démarrage de cette app, tout envoi est désactivé. L’appui explicite sur
« Traiter les enregistrements fictifs » prépare les textes et images des notes,
active la connexion de test et lance la file existante. L’onglet Transcription
et IA montre alors les transcripts et permet les questions. Les nouvelles
rédactions apparaissent dans les rubriques de notes, à la suite des saisies.
Il faut garder l’iPad et le Mac sur le même réseau Wi-Fi et le Mac allumé.
Après fermeture complète de l’app, l’appui sur le bouton réactive la recette.

La configuration de compilation privée utilise `VISIT_PREVIEW_URL`,
`VISIT_PREVIEW_TOKEN`, `AIDHABITAT_VISIT_ASSISTANT=true` et
`AIDHABITAT_PREVIEW_LOCAL_HTTP=true`. Ce dernier flag autorise uniquement les
adresses IPv4 privées/loopback dans le client séparé de recette. Il est désactivé
par défaut et les builds métier conservent HTTPS obligatoire. L’exception ATS
et l’autorisation réseau local sont ajoutées seulement à la copie iOS portant
le bundle de test, jamais au fichier Info.plist de l’app métier.

Tester avant toute diffusion :

1. Refus puis autorisation du microphone ; silence puis parole et arrêt.
2. Une capture d’au moins 65 secondes pour traverser une frontière de segment.
3. Une visite d’une heure : écran verrouillé, changements d’écran et mode avion.
4. Un appel/interruption : signalement clair et récupération de l’audio existant.
5. Fermeture puis réouverture : récupération des segments. Une terminaison
   forcée peut rendre le segment courant illisible ; aucun fichier n’est supprimé.
6. Sur la cible métier de test : reprise Wi-Fi, génération, ajout aux rubriques
   déjà remplies, modification pendant le traitement, relance sans doublon.
7. Lecture croisée Mac/iPad, et changement de compte sans transfert entre comptes.
8. Écoute et comparaison avec plusieurs voix, bruit de fond, noms et mesures.

La capture et la reprise en arrière-plan nécessitent cette recette physique.
L’envoi et les traitements reprennent quand l’app est active ; la version actuelle
ne promet pas une synchronisation avec l’app complètement fermée. Les extraits
sont horodatés par segment, sans identification garantie des locuteurs. Le passage
entre segments doit être contrôlé sur une vraie conversation. L’audio est conservé
sans purge automatique dans cette version de test.

## Bandeau et pilote intégré (28 octobre 2026)

- Le bandeau partagé affiche le nom, le type d’accompagnement et les revenus,
  sans adresse. Les champs d’adresse du dossier restent disponibles.
- Le statut Anah reste visible, immédiatement avant les commandes.
- Page dossier : enregistrement puis date de visite.
- VAD : statut Anah, enregistrement, raccourci Documents, génération du rapport.
- Sous 1 000 points disponibles, les commandes passent sur une seconde ligne.
  Le bandeau ne nécessite plus de défilement horizontal.
- Une variante métier séparée `com.aidhabitat.manager.visitpilot`, intitulée
  « App’Ergo Pilote », permet de vérifier les vrais écrans et la capture avec
  l’API HTTPS habituelle. Son stockage est distinct de l’app habituelle et de
  « Ergo IA Test » ; elle demande une connexion au compte de l’ergothérapeute.
- Cette installation ne signifie pas que le traitement IA est activé sur le
  serveur. Tant qu’il ne l’est pas, les captures restent conservées et les
  requêtes sont refusées sans supprimer la file locale. Ne pas considérer
  cette variante comme prête pour une recette complète sur une visite réelle.
- L’iPad de Coralie est disponible pour l’installation directe. Celui de
  Christelle est indisponible ; son installation physique reste à effectuer.

## Retrait de « Signaler » pour la prochaine mise à jour

Le bouton flottant, son formulaire, les services de collecte du contexte,
le suivi des changements de page/onglet et les routes d’envoi/diagnostic SMTP
sont supprimés. La dépendance Nodemailer, utilisée uniquement par cette
fonction, est retirée. Les textes d’aide orientent vers l’administrateur.
Le style partagé des boutons reste utilisé par les autres commandes.
Les anciens signalements stockés et leur gestion de conservation ne sont pas
supprimés par cette modification. Les documents d’audit datés décrivent l’état
historique du système. Ce changement attend la prochaine diffusion iPad/API.
